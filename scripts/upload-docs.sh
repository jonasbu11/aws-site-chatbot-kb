#!/usr/bin/env bash
# Upload a folder of documents to the knowledge-base bucket. Ingestion starts
# automatically (S3 event -> kb-sync Lambda). Usage: scripts/upload-docs.sh ./docs
set -euo pipefail
SRC="${1:?usage: upload-docs.sh <local-folder>}"
cd "$(dirname "$0")/.."
BUCKET=$(terraform output -raw kb_docs_bucket)
PROFILE=$(terraform output -raw aws_profile 2>/dev/null || true)
aws s3 sync "$SRC" "s3://$BUCKET/" --delete --exclude ".*" ${PROFILE:+--profile "$PROFILE"}
echo "Synced $SRC -> s3://$BUCKET/. Check ingestion with scripts/kb-status.sh"
