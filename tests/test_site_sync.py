"""Tests for the site-sync Lambda against a local fake WordPress REST API and in-memory S3.

Run: python3 -m unittest tests/test_site_sync.py
"""

import hashlib
import importlib
import json
import os
import sys
import threading
import types
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
LAMBDA_DIR = os.path.join(HERE, "..", "modules", "site-sync", "lambda")

WP = {"pages": [], "posts": []}
SEEN_UA = []


class FakeWP(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        SEEN_UA.append(self.headers.get("User-Agent"))
        u = urlparse(self.path)
        kind = u.path.rsplit("/", 1)[-1]
        q = parse_qs(u.query)
        per, page = int(q["per_page"][0]), int(q["page"][0])
        items = WP.get(kind)
        if items is None:
            self.send_response(404); self.end_headers(); return
        total_pages = max(1, -(-len(items) // per))
        if page > total_pages:
            self.send_response(400); self.end_headers(); self.wfile.write(b'{"code":"rest_post_invalid_page_number"}'); return
        body = json.dumps(items[(page - 1) * per: page * per]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-WP-TotalPages", str(total_pages))
        self.end_headers()
        self.wfile.write(body)


class FakeClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


CLOCK = [0]


def tick():
    CLOCK[0] += 1
    return CLOCK[0]


class FakeS3:
    def __init__(self):
        self.objects = {}
        self.mtimes = {}
        self.puts = 0

    def put_object(self, Bucket, Key, Body, ContentType):
        self.objects[Key] = Body
        self.mtimes[Key] = tick()
        self.puts += 1

    def delete_objects(self, Bucket, Delete):
        for o in Delete["Objects"]:
            self.objects.pop(o["Key"], None)

    def get_paginator(self, name):
        s3 = self

        class P:
            def paginate(self, Bucket, Prefix):
                yield {"Contents": [{"Key": k, "ETag": '"%s"' % hashlib.md5(v).hexdigest(), "LastModified": s3.mtimes.get(k, 0)}
                                    for k, v in sorted(s3.objects.items()) if k.startswith(Prefix)]}
        return P()


class FakeAgent:
    def __init__(self, conflicts=0):
        self.conflicts = conflicts
        self.calls = 0
        self.jobs = []  # (startedAt, status), newest first

    def start_ingestion_job(self, **kw):
        self.calls += 1
        if self.conflicts:
            self.conflicts -= 1
            raise FakeClientError("ConflictException")
        self.jobs.insert(0, (tick(), "COMPLETE"))
        return {"ingestionJob": {"ingestionJobId": "job-%d" % self.calls}}

    def list_ingestion_jobs(self, **kw):
        return {"ingestionJobSummaries": [{"startedAt": t, "status": st} for t, st in self.jobs]}


def item(i, kind, title, html, protected=False):
    return {"id": i, "type": kind[:-1], "link": f"https://acme.example/{kind}/{i}/", "status": "publish",
            "title": {"rendered": title}, "content": {"rendered": html, "protected": protected}}


class SiteSyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeWP)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def load(self, s3, agent):
        fake_boto3 = types.ModuleType("boto3")
        fake_boto3.client = lambda name, **_: {"s3": s3, "bedrock-agent": agent}[name]
        fake_exc = types.ModuleType("botocore.exceptions")
        fake_exc.ClientError = FakeClientError
        env = {"SITE_BASE_URL": self.base, "SITE_PUBLIC_URL": "https://acme.example", "DOCS_BUCKET": "b", "POST_TYPES": "pages,posts",
               "KNOWLEDGE_BASE_ID": "KB", "DATA_SOURCE_ID": "DS"}
        with mock.patch.dict(sys.modules, {"boto3": fake_boto3, "botocore": types.ModuleType("botocore"),
                                           "botocore.exceptions": fake_exc}), \
             mock.patch.dict(os.environ, env), mock.patch.object(sys, "path", [LAMBDA_DIR] + sys.path):
            sys.modules.pop("handler", None)
            mod = importlib.import_module("handler")
        mod.time.sleep = lambda s: None
        return mod

    def setUp(self):
        WP["pages"] = [item(i, "pages", f"Page {i}", f"<p>Body {i}</p>") for i in range(1, 151)]  # 2 REST pages
        WP["pages"][0] = item(1, "pages", "Heating &amp; Cooling",
                              "<h2>Emergency</h2><p>Call us <strong>24/7</strong>.</p><ul><li>Furnaces</li><li>AC</li></ul>"
                              "<script>track()</script><style>p{}</style>")
        WP["posts"] = [item(900, "posts", "News", "<p>We moved.</p>"),
                       item(901, "posts", "Members only", "", protected=True)]

    def test_full_cycle(self):
        s3, agent = FakeS3(), FakeAgent()
        h = self.load(s3, agent)

        r1 = h.sync()
        self.assertEqual(r1["items"], {"pages": 150, "posts": 1})  # protected post skipped, pagination followed
        self.assertEqual(len(s3.objects), 152 * 2)  # .md + .metadata.json per item, plus the page list
        smap = s3.objects["site/_sitemap.md"].decode()
        self.assertIn("- Heating & Cooling: https://acme.example/pages/1/", smap)
        self.assertEqual(r1["ingestion_job"], "job-1")
        self.assertTrue(all(ua.startswith("site-kb-sync/") for ua in SEEN_UA))

        md = s3.objects["site/page-1.md"].decode()
        self.assertTrue(md.startswith("# Heating & Cooling\n\nSource: https://acme.example/pages/1/"))
        self.assertIn("## Emergency", md)
        self.assertIn("Call us 24/7.", md)
        self.assertIn("- Furnaces", md)
        self.assertNotIn("track()", md)
        meta = json.loads(s3.objects["site/page-1.md.metadata.json"])
        self.assertEqual(meta, {"metadataAttributes": {"title": "Heating & Cooling", "url": "https://acme.example/pages/1/"}})

        puts_before = s3.puts
        r2 = h.sync()  # nothing changed
        self.assertEqual((r2["written"], r2["deleted"], r2["ingestion_job"]), (0, 0, None))
        self.assertEqual(s3.puts, puts_before)
        self.assertEqual(agent.calls, 1)

        WP["pages"] = WP["pages"][:-1]  # unpublish one page
        WP["posts"][0] = item(900, "posts", "News", "<p>We moved to Main St.</p>")  # edit one post
        r3 = h.sync()
        self.assertEqual(r3["deleted"], 2)
        self.assertEqual(r3["written"], 2)  # the edited post's .md and the page list; metadata unchanged
        self.assertNotIn("site/page-150.md", s3.objects)
        self.assertEqual(r3["ingestion_job"], "job-2")

    def test_waits_out_a_running_ingestion_job(self):
        s3, agent = FakeS3(), FakeAgent(conflicts=3)
        h = self.load(s3, agent)
        self.assertEqual(h.sync()["ingestion_job"], "job-4")

    def test_gives_up_quietly_when_ingestion_stays_busy(self):
        s3, agent = FakeS3(), FakeAgent(conflicts=100)
        h = self.load(s3, agent)
        self.assertIsNone(h.sync()["ingestion_job"])
        self.assertEqual(agent.calls, 8)

    def test_busy_run_is_caught_up_by_the_next_run(self):
        s3, agent = FakeS3(), FakeAgent(conflicts=8)
        h = self.load(s3, agent)
        self.assertIsNone(h.sync()["ingestion_job"])  # changes written, ingestion never started
        r = h.sync()  # nothing new, but the backlog is detected
        self.assertEqual(r["written"], 0)
        self.assertEqual(r["ingestion_job"], "job-9")
        self.assertIsNone(h.sync()["ingestion_job"])  # and then it settles

    def test_objects_outside_site_prefix_are_untouched(self):
        s3, agent = FakeS3(), FakeAgent()
        s3.objects["docs/pricing.pdf"] = b"%PDF"
        h = self.load(s3, agent)
        h.sync()
        self.assertIn("docs/pricing.pdf", s3.objects)


if __name__ == "__main__":
    unittest.main()
