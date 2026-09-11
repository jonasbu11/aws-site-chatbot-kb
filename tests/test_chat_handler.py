"""Unit tests for the chat Lambda. Run: python3 -m pytest tests/ (or python3 -m unittest).

Bedrock clients are replaced with fakes; no AWS credentials or network needed.
"""

import importlib
import json
import os
import sys
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
LAMBDA_DIR = os.path.join(HERE, "..", "modules", "chatbot", "lambda")
sys.path.insert(0, LAMBDA_DIR)


class FakeClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code, "Message": code}}


class FakeAgentRuntime:
    def __init__(self):
        self.calls = []

    def retrieve(self, **kw):
        self.calls.append(kw)
        return {
            "retrievalResults": [
                {
                    "content": {"text": "We are open Monday to Friday, 9am to 5pm."},
                    "location": {"s3Location": {"uri": "s3://bucket/hours-and-location.pdf"}},
                    "score": 0.81,
                },
                {
                    "content": {"text": "Call 555-0100 to book."},
                    "location": {"s3Location": {"uri": "s3://bucket/booking.md"}},
                    "score": 0.66,
                },
            ]
        }


class FakeRuntime:
    def __init__(self, fail_codes=None, answer="We're open 9-5 weekdays [1]."):
        self.fail_codes = dict(fail_codes or {})
        self.answer = answer
        self.calls = []

    def converse(self, **kw):
        self.calls.append(kw)
        code = self.fail_codes.get(kw["modelId"])
        if code:
            raise FakeClientError(code)
        return {
            "output": {"message": {"role": "assistant", "content": [{"text": self.answer}]}},
            "stopReason": "end_turn",
            "usage": {"inputTokens": 120, "outputTokens": 20},
        }


def load_handler(env, runtime=None, agent=None):
    """Import handler.py fresh with the given env and fake clients."""
    runtime = runtime or FakeRuntime()
    agent = agent or FakeAgentRuntime()

    fake_boto3 = types.ModuleType("boto3")

    def client(name, **_):
        return {"bedrock-runtime": runtime, "bedrock-agent-runtime": agent}[name]

    fake_boto3.client = client
    fake_boto3.resource = lambda *_a, **_k: None

    fake_botocore = types.ModuleType("botocore")
    fake_config = types.ModuleType("botocore.config")
    fake_config.Config = lambda **_k: None
    fake_exc = types.ModuleType("botocore.exceptions")
    fake_exc.ClientError = FakeClientError

    with mock.patch.dict(sys.modules, {
        "boto3": fake_boto3,
        "botocore": fake_botocore,
        "botocore.config": fake_config,
        "botocore.exceptions": fake_exc,
    }), mock.patch.dict(os.environ, env, clear=False):
        sys.modules.pop("handler", None)
        mod = importlib.import_module("handler")
    return mod, runtime, agent


BASE_ENV = {
    "KNOWLEDGE_BASE_ID": "KB123",
    "MODEL_PRIMARY": "primary-model",
    "MODEL_FALLBACK": "fallback-model",
    "SYSTEM_PROMPT": "You help customers of Acme.",
    "ORIGIN_VERIFY_SECRET": "s3cret",
    "GUARDRAIL_ID": "gr-1",
    "GUARDRAIL_VERSION": "1",
    "MAX_HISTORY_TURNS": "2",
}


def event(body=None, method="POST", path="/api/chat", secret="s3cret"):
    headers = {"content-type": "application/json"}
    if secret is not None:
        headers["X-Origin-Verify"] = secret
    return {
        "rawPath": path,
        "requestContext": {"http": {"method": method, "path": path}},
        "headers": headers,
        "body": json.dumps(body) if body is not None else None,
        "isBase64Encoded": False,
    }


class ChatHandlerTests(unittest.TestCase):
    def test_rejects_missing_origin_secret(self):
        h, _, _ = load_handler(BASE_ENV)
        resp = h.lambda_handler(event({"message": "hi"}, secret=None), None)
        self.assertEqual(resp["statusCode"], 403)

    def test_health(self):
        h, _, _ = load_handler(BASE_ENV)
        resp = h.lambda_handler(event(method="GET", path="/api/health"), None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertTrue(json.loads(resp["body"])["ok"])

    def test_validates_body(self):
        h, _, _ = load_handler(BASE_ENV)
        self.assertEqual(h.lambda_handler(event({}), None)["statusCode"], 400)
        self.assertEqual(h.lambda_handler(event({"message": "x" * 2001}), None)["statusCode"], 400)
        bad = event(None)
        bad["body"] = "{not json"
        self.assertEqual(h.lambda_handler(bad, None)["statusCode"], 400)

    def test_happy_path_retrieves_and_answers_with_cited_sources(self):
        h, rt, ag = load_handler(BASE_ENV)
        resp = h.lambda_handler(event({"message": "When are you open?"}), None)
        self.assertEqual(resp["statusCode"], 200)
        body = json.loads(resp["body"])
        self.assertEqual(body["model"], "primary-model")
        self.assertIn("9-5", body["answer"])
        self.assertEqual([s["n"] for s in body["sources"]], [1])
        self.assertEqual(body["sources"][0]["title"], "hours and location")
        self.assertRegex(body["session_id"], r"^[0-9a-f]{32}$")

        self.assertEqual(ag.calls[0]["knowledgeBaseId"], "KB123")
        call = rt.calls[0]
        self.assertIn("Reference passages", call["system"][0]["text"])
        self.assertIn("[1] (source: hours and location)", call["system"][0]["text"])
        self.assertEqual(call["messages"][-1]["content"][0]["text"], "When are you open?")
        self.assertEqual(call["guardrailConfig"]["guardrailIdentifier"], "gr-1")

    def test_site_page_metadata_gives_title_and_link(self):
        agent = FakeAgentRuntime()
        agent.retrieve = lambda **kw: {
            "retrievalResults": [
                {
                    "content": {"text": "Emergency calls 24/7."},
                    "location": {"s3Location": {"uri": "s3://bucket/site/page-12.md"}},
                    "metadata": {"title": "Heating / Cooling", "url": "https://acme.example/heating-cooling/"},
                    "score": 0.9,
                },
                {
                    "content": {"text": "x"},
                    "location": {"s3Location": {"uri": "s3://bucket/site/page-13.md"}},
                    "metadata": {"title": "Bad link", "url": "javascript:alert(1)"},
                    "score": 0.5,
                },
            ]
        }
        h, _, _ = load_handler(BASE_ENV, runtime=FakeRuntime(answer="Yes, 24/7 [1] and more [2]."), agent=agent)
        body = json.loads(h.lambda_handler(event({"message": "emergency?"}), None)["body"])
        self.assertEqual(body["sources"][0], {"n": 1, "title": "Heating / Cooling", "url": "https://acme.example/heating-cooling/"})
        self.assertEqual(body["sources"][1]["url"], "")

    def test_falls_back_on_throttle(self):
        h, rt, _ = load_handler(BASE_ENV, runtime=FakeRuntime(fail_codes={"primary-model": "ThrottlingException"}))
        resp = h.lambda_handler(event({"message": "hi"}), None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(json.loads(resp["body"])["model"], "fallback-model")
        self.assertEqual([c["modelId"] for c in rt.calls], ["primary-model", "fallback-model"])

    def test_both_models_fail_returns_502(self):
        h, _, _ = load_handler(
            BASE_ENV,
            runtime=FakeRuntime(fail_codes={"primary-model": "AccessDeniedException", "fallback-model": "ServiceUnavailableException"}),
        )
        resp = h.lambda_handler(event({"message": "hi"}), None)
        self.assertEqual(resp["statusCode"], 502)

    def test_history_is_cleaned_and_alternates(self):
        h, rt, _ = load_handler(BASE_ENV)
        history = [
            {"role": "assistant", "content": "dropped leading assistant"},
            {"role": "user", "content": "a"},
            {"role": "user", "content": "b"},  # merged into previous user turn
            {"role": "assistant", "content": "c"},
            {"role": "system", "content": "ignored"},
            {"role": "user", "content": "d"},
            {"role": "assistant", "content": "e"},
            {"role": "user", "content": "f"},
            {"role": "assistant", "content": "g"},
            {"role": "user", "content": "dangling user turn dropped"},
        ]
        resp = h.lambda_handler(event({"message": "new", "history": history}), None)
        self.assertEqual(resp["statusCode"], 200)
        msgs = rt.calls[0]["messages"]
        roles = [m["role"] for m in msgs]
        # MAX_HISTORY_TURNS=2 -> last 2 user/assistant pairs + new user message
        self.assertEqual(roles, ["user", "assistant", "user", "assistant", "user"])
        self.assertEqual(msgs[0]["content"][0]["text"], "d")
        self.assertEqual(msgs[-1]["content"][0]["text"], "new")

    def test_uses_client_session_id_when_valid(self):
        h, _, _ = load_handler(BASE_ENV)
        resp = h.lambda_handler(event({"message": "hi", "session_id": "ws_abc123XYZ"}), None)
        self.assertEqual(json.loads(resp["body"])["session_id"], "ws_abc123XYZ")
        resp = h.lambda_handler(event({"message": "hi", "session_id": "bad id!"}), None)
        self.assertNotEqual(json.loads(resp["body"])["session_id"], "bad id!")

    def test_no_secret_configured_allows_all(self):
        env = dict(BASE_ENV, ORIGIN_VERIFY_SECRET="")
        h, _, _ = load_handler(env)
        resp = h.lambda_handler(event({"message": "hi"}, secret=None), None)
        self.assertEqual(resp["statusCode"], 200)


if __name__ == "__main__":
    unittest.main()
