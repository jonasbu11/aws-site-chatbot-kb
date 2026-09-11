"""Start a Bedrock Knowledge Base ingestion job when documents change in S3.

Triggered by S3 ObjectCreated / ObjectRemoved notifications. If a job is
already running, Bedrock returns ConflictException; we re-raise so Lambda's
async retry (two attempts, roughly 1 and 2 minutes later) picks up the change
once the running job finishes. A document that lands during a run is therefore
indexed within a few minutes, without any queue or scheduler.
"""

import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

KB_ID = os.environ["KNOWLEDGE_BASE_ID"]
DS_ID = os.environ["DATA_SOURCE_ID"]

_agent = boto3.client("bedrock-agent")


def lambda_handler(event, _context):
    keys = [
        r.get("s3", {}).get("object", {}).get("key")
        for r in event.get("Records", [])
    ]
    log.info(json.dumps({"msg": "kb change", "keys": keys}))

    try:
        resp = _agent.start_ingestion_job(
            knowledgeBaseId=KB_ID,
            dataSourceId=DS_ID,
            description=f"auto-sync: {', '.join(k for k in keys if k)[:200]}",
        )
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code == "ConflictException":
            log.warning("ingestion job already running; will retry")
            raise  # let the async retry re-run us after the current job
        raise

    job = resp["ingestionJob"]
    log.info(json.dumps({"msg": "ingestion started", "jobId": job["ingestionJobId"], "status": job["status"]}))
    return {"jobId": job["ingestionJobId"], "status": job["status"]}
