"""Start a Bedrock Knowledge Base ingestion job unless one is already running.

Triggered by EventBridge on S3 object create/delete in the docs bucket and on a schedule.
Bursts of uploads collapse into one job because we skip while a job is in progress.
"""

import logging
import os

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

KB_ID = os.environ["KNOWLEDGE_BASE_ID"]
DS_ID = os.environ["DATA_SOURCE_ID"]
agent = boto3.client("bedrock-agent")


def handler(event, context):
    jobs = agent.list_ingestion_jobs(
        knowledgeBaseId=KB_ID,
        dataSourceId=DS_ID,
        filters=[{"attribute": "STATUS", "operator": "EQ", "values": ["IN_PROGRESS"]}],
        maxResults=1,
    ).get("ingestionJobSummaries", [])
    starting = agent.list_ingestion_jobs(
        knowledgeBaseId=KB_ID,
        dataSourceId=DS_ID,
        filters=[{"attribute": "STATUS", "operator": "EQ", "values": ["STARTING"]}],
        maxResults=1,
    ).get("ingestionJobSummaries", [])
    if jobs or starting:
        log.info("ingestion already running; skipping")
        return {"started": False}
    job = agent.start_ingestion_job(knowledgeBaseId=KB_ID, dataSourceId=DS_ID, description="auto")
    job_id = job["ingestionJob"]["ingestionJobId"]
    log.info("started ingestion job %s", job_id)
    return {"started": True, "job_id": job_id}
