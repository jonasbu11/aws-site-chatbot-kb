"""Nightly sync of the site's own WordPress content into the knowledge base.

Reads published pages and posts from the WordPress REST API (through
CloudFront, like any visitor), converts each to Markdown, and mirrors them
under site/ in the knowledge-base documents bucket with a .metadata.json
sidecar carrying the page title and canonical URL. Unchanged pages are not
rewritten; pages that were unpublished or deleted are removed. If anything
changed, a knowledge-base ingestion job is started.

Why not the Bedrock web crawler: it only works with OpenSearch Serverless
vector stores, and it would index every page's menus and footer. The REST
API gives just the content, with the real title and link.
"""

from __future__ import annotations

import hashlib
import html
import json
import logging
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from typing import Any, Iterable

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

SITE_BASE_URL = os.environ.get("SITE_BASE_URL", "").rstrip("/")
DOCS_BUCKET = os.environ.get("DOCS_BUCKET", "")
PREFIX = os.environ.get("SITE_PREFIX", "site/")
POST_TYPES = [t.strip() for t in os.environ.get("POST_TYPES", "pages,posts").split(",") if t.strip()]
KB_ID = os.environ.get("KNOWLEDGE_BASE_ID", "")
DS_ID = os.environ.get("DATA_SOURCE_ID", "")
SITE_URL_FOR_MAP = os.environ.get("SITE_PUBLIC_URL", "").rstrip("/") + "/"
USER_AGENT = "site-kb-sync/1.0 (+aws-site-chatbot-kb)"
PER_PAGE = 100
MAX_ITEMS_PER_TYPE = 5000

_s3 = boto3.client("s3")
_agent = boto3.client("bedrock-agent")


# ---- HTML -> Markdown ----------------------------------------------------

class _MarkdownWriter(HTMLParser):
    """Small, dependency-free HTML to Markdown converter for WordPress content."""

    BLOCK = {"p", "div", "section", "article", "header", "footer", "figure", "table", "tr", "blockquote", "br", "hr"}
    SKIP = {"script", "style", "noscript", "iframe", "svg", "form", "button"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self.skip_depth = 0
        self.list_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in self.SKIP:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if re.fullmatch(r"h[1-6]", tag):
            self.out.append("\n\n" + "#" * int(tag[1]) + " ")
        elif tag in ("ul", "ol"):
            self.list_depth += 1
            self.out.append("\n")
        elif tag == "li":
            self.out.append("\n" + "  " * max(self.list_depth - 1, 0) + "- ")
        elif tag in ("td", "th"):
            self.out.append(" | ")
        elif tag in self.BLOCK:
            self.out.append("\n\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in self.SKIP:
            self.skip_depth = max(self.skip_depth - 1, 0)
            return
        if self.skip_depth:
            return
        if tag in ("ul", "ol"):
            self.list_depth = max(self.list_depth - 1, 0)
            self.out.append("\n")
        elif re.fullmatch(r"h[1-6]", tag) or tag in self.BLOCK:
            self.out.append("\n\n")

    def handle_data(self, data: str) -> None:
        if not self.skip_depth:
            self.out.append(re.sub(r"\s+", " ", data))

    def markdown(self) -> str:
        text = "".join(self.out)
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n[ \t]+(?=[^- ])", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()


def html_to_markdown(fragment: str) -> str:
    w = _MarkdownWriter()
    w.feed(fragment or "")
    w.close()
    return w.markdown()


# ---- WordPress REST ------------------------------------------------------

def _get_json(url: str) -> tuple[Any, dict[str, str]]:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        headers = {k.lower(): v for k, v in resp.headers.items()}
        return json.loads(resp.read().decode("utf-8")), headers


def fetch_items(post_type: str) -> Iterable[dict[str, Any]]:
    fields = "id,link,title,content,modified_gmt,status,type"
    page, fetched = 1, 0
    while fetched < MAX_ITEMS_PER_TYPE:
        qs = urllib.parse.urlencode({"per_page": PER_PAGE, "page": page, "status": "publish", "_fields": fields})
        url = f"{SITE_BASE_URL}/wp-json/wp/v2/{post_type}?{qs}"
        try:
            items, headers = _get_json(url)
        except urllib.error.HTTPError as e:
            if e.code == 400 and page > 1:  # past the last page
                return
            raise
        if not isinstance(items, list) or not items:
            return
        for item in items:
            fetched += 1
            yield item
        if page >= int(headers.get("x-wp-totalpages", "1") or 1):
            return
        page += 1


def render_item(item: dict[str, Any]) -> tuple[str, str, dict[str, Any]] | None:
    """Return (key, markdown body, metadata) or None if the item has no usable content."""
    content = item.get("content") or {}
    if content.get("protected"):
        return None  # password-protected post
    title = html.unescape(re.sub(r"<[^>]+>", "", (item.get("title") or {}).get("rendered", ""))).strip()
    body = html_to_markdown(content.get("rendered", ""))
    if not body and not title:
        return None
    link = item.get("link") or ""
    md = f"# {title}\n\nSource: {link}\n\n{body}\n" if title else f"Source: {link}\n\n{body}\n"
    key = f"{PREFIX}{item.get('type', 'item')}-{item['id']}.md"
    meta = {"metadataAttributes": {"title": title[:200] or "Untitled", "url": link[:500]}}
    return key, md, meta


# ---- S3 mirror -----------------------------------------------------------

def existing_objects() -> tuple[dict[str, str], Any]:
    """(key -> MD5 ETag, newest LastModified) for everything under the prefix."""
    keys: dict[str, str] = {}
    newest = None
    paginator = _s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=DOCS_BUCKET, Prefix=PREFIX):
        for obj in page.get("Contents", []):
            keys[obj["Key"]] = obj["ETag"].strip('"')
            if newest is None or obj["LastModified"] > newest:
                newest = obj["LastModified"]
    return keys, newest


def last_ingestion_start() -> Any:
    """Start time of the most recent ingestion job that did not fail, or None."""
    resp = _agent.list_ingestion_jobs(
        knowledgeBaseId=KB_ID,
        dataSourceId=DS_ID,
        sortBy={"attribute": "STARTED_AT", "order": "DESCENDING"},
        maxResults=10,
    )
    for job in resp.get("ingestionJobSummaries", []):
        if job.get("status") in ("STARTING", "IN_PROGRESS", "COMPLETE"):
            return job.get("startedAt")
    return None


def put_if_changed(key: str, body: str, content_type: str, current: dict[str, str]) -> bool:
    data = body.encode("utf-8")
    if current.get(key) == hashlib.md5(data).hexdigest():
        return False
    _s3.put_object(Bucket=DOCS_BUCKET, Key=key, Body=data, ContentType=content_type)
    return True


def start_ingestion(attempts: int = 8, wait_seconds: int = 30) -> str | None:
    """Start an ingestion job, waiting out one that is already running (e.g. a document upload)."""
    for attempt in range(attempts):
        try:
            resp = _agent.start_ingestion_job(knowledgeBaseId=KB_ID, dataSourceId=DS_ID, description="site sync")
            return resp["ingestionJob"]["ingestionJobId"]
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") != "ConflictException":
                raise
            if attempt < attempts - 1:
                time.sleep(wait_seconds)
    log.warning("an ingestion job stayed busy; these changes will be indexed on the next sync")
    return None


def sitemap(entries: list[tuple[str, str]]) -> str:
    lines = ["# Site pages", "", "Every published page on this website, with its address.", ""]
    lines += [f"- {title}: {url}" for title, url in sorted(entries, key=lambda e: e[0].lower())]
    return "\n".join(lines) + "\n"


def sync() -> dict[str, Any]:
    current, newest_before = existing_objects()
    wanted: set[str] = set()
    written = 0
    counts: dict[str, int] = {}
    entries: list[tuple[str, str]] = []

    for post_type in POST_TYPES:
        n = 0
        for item in fetch_items(post_type):
            rendered = render_item(item)
            if not rendered:
                continue
            key, md, meta = rendered
            meta_key = key + ".metadata.json"
            wanted.update((key, meta_key))
            written += put_if_changed(key, md, "text/markdown; charset=utf-8", current)
            written += put_if_changed(meta_key, json.dumps(meta, ensure_ascii=False), "application/json", current)
            entries.append((meta["metadataAttributes"]["title"], meta["metadataAttributes"]["url"]))
            n += 1
        counts[post_type] = n

    # A page list document: answers "what's on the site / where do I find X",
    # and changes whenever pages are added or removed.
    map_key = f"{PREFIX}_sitemap.md"
    wanted.update((map_key, map_key + ".metadata.json"))
    written += put_if_changed(map_key, sitemap(entries), "text/markdown; charset=utf-8", current)
    written += put_if_changed(
        map_key + ".metadata.json",
        json.dumps({"metadataAttributes": {"title": "Site pages", "url": SITE_URL_FOR_MAP}}),
        "application/json",
        current,
    )

    stale = sorted(k for k in current if k not in wanted)
    for i in range(0, len(stale), 1000):
        _s3.delete_objects(Bucket=DOCS_BUCKET, Delete={"Objects": [{"Key": k} for k in stale[i:i + 1000]], "Quiet": True})

    job = None
    if KB_ID and DS_ID:
        needed = bool(written or stale)
        if not needed and newest_before is not None:
            # Nothing new this run, but a previous run may have written changes
            # and then failed to start ingestion because a job was busy.
            last = last_ingestion_start()
            needed = last is None or newest_before > last
        if needed:
            job = start_ingestion()

    result = {"items": counts, "written": written, "deleted": len(stale), "ingestion_job": job}
    log.info(json.dumps({"msg": "site sync", **result}))
    return result


def lambda_handler(_event: Any, _context: Any) -> dict[str, Any]:
    if not SITE_BASE_URL or not DOCS_BUCKET:
        raise RuntimeError("SITE_BASE_URL and DOCS_BUCKET must be set")
    return sync()
