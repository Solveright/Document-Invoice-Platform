"""Consumer Lambda — Textract invoice extraction.

Triggered by S3 ObjectCreated events delivered through SQS:

    S3 (uploads/*.pdf) -> SQS -> this function -> Textract -> DynamoDB

This replaces the Phase 7 arrangement where the API enqueued a message at
presign time. That fired before the browser had finished uploading, so items
were written as PENDING_UPLOAD and never progressed. An S3 event only fires
once the object genuinely exists, which removes the race entirely.

Region note: Textract is not available in ap-northeast-1, where this function
and the bucket live. Textract also requires that any S3Object it reads be in
the same region as the Textract endpoint — so we cannot simply point Seoul at
the Tokyo bucket. Instead this function reads the object itself and passes the
raw bytes, which carry no region constraint. Cost is a little cross-region
transfer; the ceiling is Textract's 10 MB synchronous limit.
"""

import json
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]
TEXTRACT_REGION = os.environ.get("TEXTRACT_REGION", "ap-northeast-2")
MAX_TEXTRACT_BYTES = int(os.environ.get("MAX_TEXTRACT_BYTES", str(10 * 1024 * 1024)))

s3 = boto3.client("s3")
textract = boto3.client("textract", region_name=TEXTRACT_REGION)
table = boto3.resource("dynamodb").Table(TABLE_NAME)

# Textract SummaryField types we care about, mapped to our own names.
# The full set is much larger; these are the ones that make an invoice useful.
FIELD_MAP = {
    "VENDOR_NAME": "vendor",
    "RECEIVER_NAME": "billTo",
    "INVOICE_RECEIPT_ID": "invoiceNumber",
    "INVOICE_RECEIPT_DATE": "invoiceDate",
    "DUE_DATE": "dueDate",
    "SUBTOTAL": "subtotal",
    "TAX": "tax",
    "TOTAL": "total",
    "PO_NUMBER": "poNumber",
}


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _parse_key(key):
    """uploads/{userId}/{documentId}/{filename} -> (userId, documentId, filename).

    Returns None for anything that does not match, so unrelated objects in the
    bucket are ignored rather than crashing the batch.
    """
    parts = key.split("/")
    if len(parts) < 4 or parts[0] != "uploads":
        return None
    user_id, document_id = parts[1], parts[2]
    filename = "/".join(parts[3:])
    if not user_id or not document_id or not filename:
        return None
    return user_id, document_id, filename


def _summary_fields(response):
    """Flatten Textract SummaryFields into a plain dict of {name: {...}}."""
    extracted = {}

    for document in response.get("ExpenseDocuments", []):
        for field in document.get("SummaryFields", []):
            type_text = field.get("Type", {}).get("Text")
            our_name = FIELD_MAP.get(type_text)
            if not our_name or our_name in extracted:
                continue

            value = field.get("ValueDetection", {})
            text = (value.get("Text") or "").strip()
            if not text:
                continue

            entry = {
                "value": text,
                # Decimal, not float — DynamoDB rejects floats outright.
                "confidence": Decimal(str(round(value.get("Confidence", 0), 2))),
            }

            currency = field.get("Currency", {}).get("Code")
            if currency:
                entry["currency"] = currency

            extracted[our_name] = entry

    return extracted


def _line_items(response, limit=25):
    """Pull line items, capped so a huge invoice cannot blow the 400 KB item limit."""
    items = []

    for document in response.get("ExpenseDocuments", []):
        for group in document.get("LineItemGroups", []):
            for line in group.get("LineItems", []):
                row = {}
                for field in line.get("LineItemExpenseFields", []):
                    type_text = field.get("Type", {}).get("Text")
                    text = (field.get("ValueDetection", {}).get("Text") or "").strip()
                    if not type_text or not text:
                        continue
                    if type_text == "ITEM":
                        row["description"] = text
                    elif type_text == "PRICE":
                        row["price"] = text
                    elif type_text == "QUANTITY":
                        row["quantity"] = text
                    elif type_text == "UNIT_PRICE":
                        row["unitPrice"] = text
                if row:
                    items.append(row)
                if len(items) >= limit:
                    return items

    return items


def _mark(user_id, document_id, status, **attributes):
    """Upsert the document item.

    update_item rather than put_item so we never clobber fields written by the
    API at presign time, and so this still works if that write never happened.
    'status' is a DynamoDB reserved word, hence the expression attribute name.
    """
    names = {"#s": "status"}
    values = {":s": status, ":u": datetime.now(timezone.utc).isoformat()}
    sets = ["#s = :s", "processedAt = :u"]
    removes = []

    for index, (key, value) in enumerate(attributes.items()):
        names[f"#a{index}"] = key
        # An explicit None means "clear this attribute" — e.g. wiping a stale
        # failureReason when a previously FAILED document is reprocessed and
        # now succeeds. Skipping it (the old behaviour) left the old reason
        # sitting on a PROCESSED row.
        if value is None:
            removes.append(f"#a{index}")
            continue
        placeholder = f":a{index}"
        values[placeholder] = value
        sets.append(f"#a{index} = {placeholder}")

    expression = "SET " + ", ".join(sets)
    if removes:
        expression += " REMOVE " + ", ".join(removes)

    table.update_item(
        Key={"userId": user_id, "documentId": document_id},
        UpdateExpression=expression,
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


# --------------------------------------------------------------------------
# per-object processing
# --------------------------------------------------------------------------

def process_object(bucket, key, size, context):
    parsed = _parse_key(key)
    if parsed is None:
        logger.warning(json.dumps({
            "event": "key_ignored",
            "request_id": context.aws_request_id,
            "s3_key": key,
        }))
        return

    user_id, document_id, filename = parsed

    logger.info(json.dumps({
        "event": "processing_started",
        "request_id": context.aws_request_id,
        "user_id": user_id,
        "document_id": document_id,
        "s3_key": key,
        "size_bytes": size,
    }))

    base = {
        "filename": filename,
        "s3Bucket": bucket,
        "s3Key": key,
        "sizeBytes": Decimal(str(size)) if size is not None else None,
    }

    if size is not None and size > MAX_TEXTRACT_BYTES:
        # Fail loudly in the record rather than letting Textract reject it.
        _mark(user_id, document_id, "FAILED",
              failureReason=f"File exceeds Textract's {MAX_TEXTRACT_BYTES} byte synchronous limit.",
              **base)
        logger.warning(json.dumps({
            "event": "too_large_for_textract",
            "document_id": document_id,
            "size_bytes": size,
        }))
        return

    _mark(user_id, document_id, "PROCESSING", **base)

    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    except ClientError:
        logger.exception(json.dumps({
            "event": "s3_get_failed",
            "document_id": document_id,
            "s3_key": key,
        }))
        raise

    try:
        response = textract.analyze_expense(Document={"Bytes": body})
    except ClientError as error:
        code = error.response.get("Error", {}).get("Code", "")

        # Permanent failures: retrying just burns the queue down to the DLQ.
        if code in ("UnsupportedDocumentException", "BadDocumentException",
                    "DocumentTooLargeException", "InvalidParameterException"):
            _mark(user_id, document_id, "FAILED",
                  failureReason=f"Textract rejected the document ({code}).",
                  **base)
            logger.warning(json.dumps({
                "event": "textract_rejected_document",
                "document_id": document_id,
                "error_code": code,
            }))
            return

        # Account/permission problems are permanent too. The common one is
        # SubscriptionRequiredException — Amazon Textract is not activated for
        # this AWS account (every region, every Textract API). Retrying it just
        # marches the message into the DLQ and leaves the row stuck at
        # PROCESSING forever. Fail the row with an actionable reason instead.
        if code in ("SubscriptionRequiredException", "AccessDeniedException",
                    "UnrecognizedClientException"):
            _mark(user_id, document_id, "FAILED",
                  failureReason=(
                      f"Textract is not available to this account in "
                      f"{TEXTRACT_REGION} ({code}). Activate Amazon Textract "
                      f"for the account, then re-upload."),
                  **base)
            logger.error(json.dumps({
                "event": "textract_not_subscribed",
                "document_id": document_id,
                "error_code": code,
                "textract_region": TEXTRACT_REGION,
            }))
            return

        # Throttling and 5xx are worth another attempt — let SQS redeliver.
        logger.exception(json.dumps({
            "event": "textract_call_failed",
            "document_id": document_id,
            "error_code": code,
        }))
        raise

    extracted = _summary_fields(response)
    line_items = _line_items(response)
    pages = response.get("DocumentMetadata", {}).get("Pages")

    _mark(
        user_id, document_id, "PROCESSED",
        extracted=extracted,
        lineItems=line_items,
        pageCount=Decimal(str(pages)) if pages is not None else None,
        textractRegion=TEXTRACT_REGION,
        failureReason=None,
        **base
    )

    logger.info(json.dumps({
        "event": "document_processed",
        "request_id": context.aws_request_id,
        "user_id": user_id,
        "document_id": document_id,
        "fields_found": sorted(extracted.keys()),
        "line_item_count": len(line_items),
        "pages": pages,
    }))


# --------------------------------------------------------------------------
# entrypoint
# --------------------------------------------------------------------------

def lambda_handler(event, context):
    records = event.get("Records", [])

    logger.info(json.dumps({
        "event": "batch_received",
        "request_id": context.aws_request_id,
        "record_count": len(records),
    }))

    processed = 0

    for record in records:
        body = json.loads(record["body"])

        # S3 sends one of these when the bucket notification is first
        # configured. Without this guard it poisons the queue into the DLQ.
        if body.get("Event") == "s3:TestEvent":
            logger.info(json.dumps({"event": "s3_test_event_skipped"}))
            continue

        for s3_record in body.get("Records", []):
            s3_info = s3_record.get("s3", {})
            bucket = s3_info.get("bucket", {}).get("name")
            raw_key = s3_info.get("object", {}).get("key")
            size = s3_info.get("object", {}).get("size")

            if not bucket or not raw_key:
                continue

            # S3 event keys are URL-encoded: spaces arrive as '+'.
            process_object(bucket, unquote_plus(raw_key), size, context)
            processed += 1

    logger.info(json.dumps({
        "event": "batch_completed",
        "request_id": context.aws_request_id,
        "objects_processed": processed,
    }))

    return {"statusCode": 200}
