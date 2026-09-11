#!/usr/bin/env bash
# Show recent knowledge-base ingestion jobs, or start one: scripts/kb-status.sh [--sync]
set -euo pipefail
cd "$(dirname "$0")/.."
KB=$(terraform output -raw knowledge_base_id)
DS=$(terraform output -raw kb_data_source_id)
REGION=$(terraform output -raw region 2>/dev/null || aws configure get region || echo us-east-1)

if [ "${1:-}" = "--sync" ]; then
  aws bedrock-agent start-ingestion-job --region "$REGION" --knowledge-base-id "$KB" --data-source-id "$DS" \
    --query 'ingestionJob.{id:ingestionJobId,status:status}' --output table
fi

aws bedrock-agent list-ingestion-jobs --region "$REGION" --knowledge-base-id "$KB" --data-source-id "$DS" --max-results 5 \
  --query 'ingestionJobSummaries[].{started:startedAt,status:status,scanned:statistics.numberOfDocumentsScanned,indexed:statistics.numberOfNewDocumentsIndexed,failed:statistics.numberOfDocumentsFailed}' \
  --output table
