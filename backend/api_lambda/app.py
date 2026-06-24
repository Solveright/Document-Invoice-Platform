import json
import boto3
import os
import uuid
from datetime import datetime

sqs = boto3.client("sqs")

QUEUE_URL = os.environ["QUEUE_URL"]

def lambda_handler(event, context):

    document_id = str(uuid.uuid4())

    message = {
        "documentId": document_id,
        "timestamp": datetime.utcnow().isoformat()
    }

    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message)
    )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "documentId": document_id,
            "status": "QUEUED"
        })
    }