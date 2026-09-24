"""API Lambda (producer).

Routes (HTTP API v2, payload format 2.0):
    POST /documents  -> mint a presigned S3 PUT URL, register a placeholder row
    GET  /documents  -> list the caller's documents from DynamoDB

As of Phase 10 this function no longer touches SQS. Processing is triggered by
the S3 ObjectCreated event, which only fires once the upload has actually
landed. See backend/consumer_lambda/app.py.

The browser never streams file bytes through API Gateway or Lambda. It asks
this function for a short-lived presigned URL and PUTs straight to S3. That
keeps us under API Gateway's 10 MB payload cap and off Lambda's clock.
"""

import base64
import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
RAW_BUCKET = os.environ["RAW_BUCKET"]
TABLE_NAME = os.environ["TABLE_NAME"]

UPLOAD_URL_TTL = int(os.environ.get("UPLOAD_URL_TTL_SECONDS", "900"))
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", str(20 * 1024 * 1024)))

ALLOWED_CONTENT_TYPES = {"application/pdf"}
SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]")

# Force SigV4 so the presigned URL is valid in every region, including the
# ones that never supported SigV2.
s3 = boto3.client("s3", region_name=REGION, config=Config(signature_version="s3v4"))
table = boto3.resource("dynamodb").Table(TABLE_NAME)


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _respond(status_code, body):
    # API Gateway HTTP API applies its own CORS configuration and ignores
    # CORS headers returned by the integration, so we do not set them here.
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def _claims(event):
    """Pull the verified Cognito JWT claims injected by the API Gateway authorizer."""
    try:
        return event["requestContext"]["authorizer"]["jwt"]["claims"]
    except (KeyError, TypeError):
        return {}


def _sanitize_filename(name):
    """Reduce an arbitrary client filename to something safe for an S3 key."""
    name = (name or "upload.pdf").rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    name = SAFE_NAME.sub("_", name).lstrip(".")
    if not name:
        name = "upload.pdf"
    # Normalise the extension to lowercase ".pdf". The S3 ObjectCreated
    # notification that drives Phase 10 filters on a case-sensitive ".pdf"
    # suffix, so an "Invoice.PDF" key would upload fine but never trigger
    # processing.
    if name.lower().endswith(".pdf"):
        name = f"{name[:-4]}.pdf"
    else:
        name = f"{name}.pdf"
    return name[:120]


def _parse_body(event):
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


# --------------------------------------------------------------------------
# POST /documents
# --------------------------------------------------------------------------

def create_document(event, context, user_id):
    body = _parse_body(event)
    if body is None:
        return _respond(400, {"error": "Request body must be a JSON object."})

    filename = _sanitize_filename(body.get("filename"))
    content_type = body.get("contentType") or "application/pdf"
    size_bytes = body.get("sizeBytes")

    if content_type not in ALLOWED_CONTENT_TYPES:
        return _respond(415, {"error": f"Unsupported contentType: {content_type}"})

    if isinstance(size_bytes, (int, float)) and size_bytes > MAX_UPLOAD_BYTES:
        return _respond(413, {
            "error": "File too large.",
            "maxBytes": MAX_UPLOAD_BYTES,
        })

    document_id = str(uuid.uuid4())
    s3_key = f"uploads/{user_id}/{document_id}/{filename}"
    now = datetime.now(timezone.utc).isoformat()

    logger.info(json.dumps({
        "event": "request_received",
        "request_id": context.aws_request_id,
        "user_id": user_id,
        "document_id": document_id,
        "s3_key": s3_key,
    }))

    try:
        # The signature covers the key AND the Content-Type, so the browser
        # must send exactly this Content-Type on the PUT or S3 returns 403.
        upload_url = s3.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": RAW_BUCKET,
                "Key": s3_key,
                "ContentType": content_type,
            },
            ExpiresIn=UPLOAD_URL_TTL,
        )
    except Exception:
        logger.exception(json.dumps({
            "event": "presign_failed",
            "request_id": context.aws_request_id,
            "document_id": document_id,
        }))
        return _respond(500, {"error": "Could not create upload URL."})

    # Write the placeholder row directly rather than enqueueing.
    #
    # Phase 7 sent an SQS message here, which fired before the browser had
    # finished uploading. As of Phase 10 the processing trigger is the S3
    # ObjectCreated event instead, so this write exists purely so the document
    # shows up in the list immediately with an honest status. The consumer
    # upserts over it once Textract has run.
    item = {
        "userId": user_id,
        "documentId": document_id,
        "status": "AWAITING_UPLOAD",
        "filename": filename,
        "contentType": content_type,
        "s3Bucket": RAW_BUCKET,
        "s3Key": s3_key,
        "uploadedAt": now,
    }

    if isinstance(size_bytes, (int, float)):
        item["sizeBytes"] = int(size_bytes)

    try:
        table.put_item(Item=item)
    except Exception:
        logger.exception(json.dumps({
            "event": "dynamodb_write_failed",
            "request_id": context.aws_request_id,
            "document_id": document_id,
        }))
        return _respond(500, {"error": "Could not record document."})

    logger.info(json.dumps({
        "event": "document_registered",
        "request_id": context.aws_request_id,
        "document_id": document_id,
        "s3_key": s3_key,
    }))

    return _respond(200, {
        "documentId": document_id,
        "status": "AWAITING_UPLOAD",
        "uploadUrl": upload_url,
        "uploadMethod": "PUT",
        "uploadHeaders": {"Content-Type": content_type},
        "expiresIn": UPLOAD_URL_TTL,
        "s3Key": s3_key,
    })


# --------------------------------------------------------------------------
# GET /documents
# --------------------------------------------------------------------------

def list_documents(event, context, user_id):
    try:
        # The sort key is documentId (a UUID), so DynamoDB's own ordering is
        # effectively random. We fetch a page and sort by uploadedAt below.
        # A GSI on (userId, uploadedAt) is the proper fix once this outgrows
        # a single page — noted for Phase 13.
        result = table.query(
            KeyConditionExpression=Key("userId").eq(user_id),
            Limit=50,
        )
    except Exception:
        logger.exception(json.dumps({
            "event": "dynamodb_query_failed",
            "request_id": context.aws_request_id,
            "user_id": user_id,
        }))
        return _respond(500, {"error": "Could not list documents."})

    items = []
    for item in result.get("Items", []):
        # Textract confidences come back as Decimal, which json.dumps cannot
        # serialise. Flatten to the value text plus a rounded float.
        extracted = {}
        for name, field in (item.get("extracted") or {}).items():
            if not isinstance(field, dict):
                continue
            extracted[name] = {
                "value": field.get("value"),
                "confidence": float(field["confidence"]) if field.get("confidence") is not None else None,
                "currency": field.get("currency"),
            }

        items.append({
            "documentId": item.get("documentId"),
            "filename": item.get("filename"),
            "status": item.get("status"),
            "sizeBytes": int(item["sizeBytes"]) if item.get("sizeBytes") is not None else None,
            "uploadedAt": item.get("uploadedAt"),
            "processedAt": item.get("processedAt"),
            "failureReason": item.get("failureReason"),
            "statusDetail": item.get("statusDetail"),
            "pageCount": int(item["pageCount"]) if item.get("pageCount") is not None else None,
            "extracted": extracted,
            "lineItemCount": len(item.get("lineItems") or []),
        })

    items.sort(key=lambda d: d.get("uploadedAt") or "", reverse=True)

    return _respond(200, {"documents": items, "count": len(items)})


# --------------------------------------------------------------------------
# entrypoint
# --------------------------------------------------------------------------

ROUTES = {
    "POST /documents": create_document,
    "GET /documents": list_documents,
}


def lambda_handler(event, context):
    claims = _claims(event)
    user_id = claims.get("sub")

    if not user_id:
        # Should be unreachable: the route is behind a JWT authorizer.
        logger.warning(json.dumps({
            "event": "missing_jwt_claims",
            "request_id": context.aws_request_id,
        }))
        return _respond(401, {"error": "Unauthorized."})

    route_key = event.get("routeKey", "")
    handler = ROUTES.get(route_key)

    if handler is None:
        return _respond(404, {"error": f"No handler for route {route_key}"})

    return handler(event, context, user_id)
