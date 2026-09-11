#!/usr/bin/env bash
# Ask the deployed chatbot a question from the terminal. Usage: scripts/chat.sh "When are you open?"
set -euo pipefail
Q="${1:?usage: chat.sh \"question\"}"
cd "$(dirname "$0")/.."
URL=$(terraform output -raw chat_api_url)
curl -sS -X POST "$URL" -H 'Content-Type: application/json' \
  --data "$(python3 -c 'import json,sys; print(json.dumps({"message": sys.argv[1]}))' "$Q")" | python3 -m json.tool
