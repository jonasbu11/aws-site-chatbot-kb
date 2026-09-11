"""Website chat: Bedrock Knowledge Base retrieval + Converse.

Flow per request:
  1. Verify the CloudFront origin secret header (requests around CloudFront are refused).
  2. Validate the body: {"message": str, "history": [{"role","content"}], "session_id": str?}
  3. Retrieve top-K passages from the knowledge base.
  4. Build a system prompt with numbered passages and call Converse on the
     primary model; on throttling / availability errors, retry once on the
     fallback model. Any Converse-capable Bedrock model works (Anthropic,
     OpenAI on Bedrock, Amazon Nova, ...), which is why this does Retrieve +
     Converse rather than RetrieveAndGenerate (the latter only supports a
     subset of models).
  5. Return {"answer", "sources": [...], "model"}.

Configuration is entirely via environment variables set by Terraform.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import re
import time
import uuid
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

# ---- configuration -------------------------------------------------------

KB_ID = os.environ.get("KNOWLEDGE_BASE_ID", "")
MODEL_PRIMARY = os.environ.get("MODEL_PRIMARY", "")
MODEL_FALLBACK = os.environ.get("MODEL_FALLBACK", "") or None
SYSTEM_PROMPT = os.environ.get("SYSTEM_PROMPT", "You are a helpful website assistant.")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "600"))
TEMPERATURE = float(os.environ.get("TEMPERATURE", "0.2"))
RETRIEVAL_RESULTS = int(os.environ.get("RETRIEVAL_RESULTS", "6"))
MAX_HISTORY_TURNS = int(os.environ.get("MAX_HISTORY_TURNS", "8"))
GUARDRAIL_ID = os.environ.get("GUARDRAIL_ID", "") or None
GUARDRAIL_VERSION = os.environ.get("GUARDRAIL_VERSION", "") or None
CHAT_LOG_TABLE = os.environ.get("CHAT_LOG_TABLE", "") or None
ORIGIN_VERIFY_SECRET = os.environ.get("ORIGIN_VERIFY_SECRET", "") or None

MAX_MESSAGE_CHARS = 2000
MAX_HISTORY_CHARS = 12000
CHAT_LOG_TTL_DAYS = 90

# Errors on which we try the fallback model.
FALLBACK_ERROR_CODES = {
    "ThrottlingException",
    "ServiceUnavailableException",
    "ModelNotReadyException",
    "ModelTimeoutException",
    "ModelErrorException",
    "InternalServerException",
    "AccessDeniedException",  # model access not enabled in this account/region
    "ResourceNotFoundException",
    "ValidationException",  # e.g. an ID that is not a valid model in this region
}

_cfg = Config(retries={"max_attempts": 2, "mode": "standard"}, read_timeout=55)
_runtime = boto3.client("bedrock-runtime", config=_cfg)
_agent_runtime = boto3.client("bedrock-agent-runtime", config=_cfg)
_ddb = boto3.resource("dynamodb") if CHAT_LOG_TABLE else None


# ---- helpers -------------------------------------------------------------

def _response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _header(event: dict[str, Any], name: str) -> str | None:
    headers = event.get("headers") or {}
    for k, v in headers.items():
        if k.lower() == name.lower():
            return v
    return None


def _authorized(event: dict[str, Any]) -> bool:
    """CloudFront adds x-origin-verify; direct hits to the API URL lack it."""
    if not ORIGIN_VERIFY_SECRET:
        return True
    return _header(event, "x-origin-verify") == ORIGIN_VERIFY_SECRET


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64

        raw = base64.b64decode(raw).decode("utf-8", errors="replace")
    try:
        data = json.loads(raw) if raw else {}
    except json.JSONDecodeError as e:
        raise ValueError("body must be JSON") from e
    if not isinstance(data, dict):
        raise ValueError("body must be a JSON object")
    return data


def _clean_history(history: Any) -> list[dict[str, Any]]:
    """Keep the last N well-formed turns, alternating user/assistant, ending with assistant."""
    if not isinstance(history, list):
        return []
    turns: list[dict[str, Any]] = []
    for item in history:
        if not isinstance(item, dict):
            continue
        role = item.get("role")
        content = item.get("content")
        if role not in ("user", "assistant") or not isinstance(content, str):
            continue
        content = content.strip()
        if not content:
            continue
        # Converse requires strictly alternating roles; merge same-role runs.
        if turns and turns[-1]["role"] == role:
            turns[-1]["content"][0]["text"] += "\n" + content
        else:
            turns.append({"role": role, "content": [{"text": content}]})
    # Must start with user and end with assistant so the new user message alternates.
    while turns and turns[0]["role"] != "user":
        turns.pop(0)
    while turns and turns[-1]["role"] != "assistant":
        turns.pop()
    turns = turns[-(MAX_HISTORY_TURNS * 2):]
    # Char budget, dropping oldest first.
    while turns and sum(len(t["content"][0]["text"]) for t in turns) > MAX_HISTORY_CHARS:
        turns = turns[2:]
    return turns


def _retrieve(query: str) -> list[dict[str, Any]]:
    if not KB_ID:
        return []
    resp = _agent_runtime.retrieve(
        knowledgeBaseId=KB_ID,
        retrievalQuery={"text": query},
        retrievalConfiguration={
            "vectorSearchConfiguration": {"numberOfResults": RETRIEVAL_RESULTS}
        },
    )
    passages = []
    for r in resp.get("retrievalResults", []):
        text = (r.get("content") or {}).get("text") or ""
        if not text.strip():
            continue
        loc = r.get("location") or {}
        uri = (loc.get("s3Location") or {}).get("uri") or (loc.get("webLocation") or {}).get("url") or ""
        meta = r.get("metadata") or {}
        title = meta.get("title") or meta.get("x-amz-bedrock-kb-source-uri") or uri
        passages.append(
            {
                "text": text.strip(),
                "uri": uri,
                "title": _display_title(title),
                "score": round(float(r.get("score") or 0.0), 4),
            }
        )
    return passages


def _display_title(uri_or_title: str) -> str:
    if not uri_or_title:
        return "Reference"
    name = uri_or_title.rsplit("/", 1)[-1]
    name = re.sub(r"\.(pdf|docx?|txt|md|html?|csv|xlsx?|pptx?)$", "", name, flags=re.I)
    return name.replace("_", " ").replace("-", " ").strip() or "Reference"


def _build_system(passages: list[dict[str, Any]]) -> str:
    if not passages:
        return SYSTEM_PROMPT + "\n\nNo reference passages were found for this question."
    blocks = []
    for i, p in enumerate(passages, start=1):
        blocks.append(f"[{i}] (source: {p['title']})\n{p['text']}")
    return SYSTEM_PROMPT + "\n\nReference passages:\n\n" + "\n\n".join(blocks)


def _converse(model_id: str, system: str, messages: list[dict[str, Any]]) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "modelId": model_id,
        "system": [{"text": system}],
        "messages": messages,
        "inferenceConfig": {"maxTokens": MAX_TOKENS, "temperature": TEMPERATURE},
    }
    if GUARDRAIL_ID and GUARDRAIL_VERSION:
        kwargs["guardrailConfig"] = {
            "guardrailIdentifier": GUARDRAIL_ID,
            "guardrailVersion": GUARDRAIL_VERSION,
            "trace": "disabled",
        }
    return _runtime.converse(**kwargs)


def _answer_with_fallback(system: str, messages: list[dict[str, Any]]) -> tuple[str, str, dict[str, Any]]:
    models = [m for m in (MODEL_PRIMARY, MODEL_FALLBACK) if m]
    last_err: Exception | None = None
    for i, model_id in enumerate(models):
        try:
            resp = _converse(model_id, system, messages)
            text = "".join(
                block.get("text", "")
                for block in resp.get("output", {}).get("message", {}).get("content", [])
            ).strip()
            usage = resp.get("usage") or {}
            if resp.get("stopReason") == "guardrail_intervened" and not text:
                text = "I can't help with that request."
            return text, model_id, usage
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            last_err = e
            log.warning(json.dumps({"msg": "converse failed", "model": model_id, "code": code}))
            if code in FALLBACK_ERROR_CODES and i < len(models) - 1:
                continue
            raise
    raise last_err or RuntimeError("no model configured")


def _log_exchange(session_id: str, question: str, answer: str, model: str, sources: list[dict[str, Any]], usage: dict[str, Any]) -> None:
    if not _ddb or not CHAT_LOG_TABLE:
        return
    try:
        now = dt.datetime.now(dt.timezone.utc)
        _ddb.Table(CHAT_LOG_TABLE).put_item(
            Item={
                "session_id": session_id,
                "ts": now.isoformat(),
                "expires_at": int(time.time()) + CHAT_LOG_TTL_DAYS * 86400,
                "question": question[:MAX_MESSAGE_CHARS],
                "answer": answer[:8000],
                "model": model,
                "sources": [s["title"] for s in sources],
                "input_tokens": int(usage.get("inputTokens", 0)),
                "output_tokens": int(usage.get("outputTokens", 0)),
            }
        )
    except Exception as e:  # logging must never break the answer
        log.warning(json.dumps({"msg": "chat log write failed", "error": str(e)}))


# ---- entry point ---------------------------------------------------------

def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    ctx = (event.get("requestContext") or {}).get("http") or {}
    method = (ctx.get("method") or "").upper()
    path = ctx.get("path") or event.get("rawPath") or ""

    if not _authorized(event):
        return _response(403, {"error": "forbidden"})

    if method == "GET" and path.endswith("/health"):
        return _response(200, {"ok": True, "model": MODEL_PRIMARY, "kb": bool(KB_ID)})

    if method != "POST":
        return _response(405, {"error": "method not allowed"})

    try:
        data = _parse_body(event)
    except ValueError as e:
        return _response(400, {"error": str(e)})

    message = data.get("message")
    if not isinstance(message, str) or not message.strip():
        return _response(400, {"error": "message is required"})
    message = message.strip()
    if len(message) > MAX_MESSAGE_CHARS:
        return _response(400, {"error": f"message exceeds {MAX_MESSAGE_CHARS} characters"})

    session_id = data.get("session_id")
    if not isinstance(session_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", session_id):
        session_id = uuid.uuid4().hex

    history = _clean_history(data.get("history"))
    messages = history + [{"role": "user", "content": [{"text": message}]}]

    started = time.time()
    try:
        passages = _retrieve(message)
    except ClientError as e:
        log.error(json.dumps({"msg": "retrieve failed", "error": str(e)}))
        passages = []

    system = _build_system(passages)

    try:
        answer, model_used, usage = _answer_with_fallback(system, messages)
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        log.error(json.dumps({"msg": "model call failed", "code": code, "error": str(e)}))
        status = 429 if code == "ThrottlingException" else 502
        return _response(status, {"error": "The assistant is temporarily unavailable. Please try again shortly."})

    # Only surface sources the model actually cited, in citation order; fall
    # back to the top passages when it cited none but passages existed.
    cited = [int(n) for n in re.findall(r"\[(\d+)\]", answer)]
    seen: list[int] = []
    for n in cited:
        if 1 <= n <= len(passages) and n not in seen:
            seen.append(n)
    sources = [
        {"n": n, "title": passages[n - 1]["title"], "uri": passages[n - 1]["uri"]}
        for n in seen
    ]

    _log_exchange(session_id, message, answer, model_used, sources, usage)

    log.info(
        json.dumps(
            {
                "msg": "chat",
                "session": session_id,
                "model": model_used,
                "passages": len(passages),
                "input_tokens": usage.get("inputTokens"),
                "output_tokens": usage.get("outputTokens"),
                "ms": int((time.time() - started) * 1000),
            }
        )
    )

    return _response(
        200,
        {
            "answer": answer,
            "sources": sources,
            "model": model_used,
            "session_id": session_id,
        },
    )
