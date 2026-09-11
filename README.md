# aws-site-chatbot-kb

Repeatable Terraform template for a small-business website with an AI assistant on AWS:
WordPress on Lightsail, served through CloudFront with WAF, plus a knowledge-base chatbot
(Bedrock Knowledge Bases on S3 Vectors, Lambda, any Converse-capable Bedrock model). One
`terraform.tfvars` per site; everything else is shared.

Design goals, in order: lowest steady-state cost that still runs real WordPress, a basic
security floor with nothing public that does not need to be, and model choice as a config
value rather than a code change.

## What gets built

```
visitor ──HTTPS──▶ CloudFront (ACM cert, WAF, security headers)
                     │  X-Origin-Verify: <secret>
                     ├── /api/*          ──▶ API Gateway (HTTP) ──▶ Lambda chat ──▶ Bedrock Retrieve + Converse (+ Guardrail)
                     ├── /chat-widget/*  ──▶ S3 (private, OAC)                          │
                     └── /*              ──▶ Lightsail WordPress (origin.<domain>)       ▼
                                             Apache refuses requests without the secret   Bedrock Knowledge Base
                                                                                          └─ S3 Vectors index ◀── ingestion ◀── S3 docs bucket
                                                                                                                                  ▲
                                                                                                          kb-sync Lambda (S3 event) ─┘
```

| Layer | Resources | Why this choice |
|---|---|---|
| Site | Lightsail `wordpress_ls_1_0` instance (micro_3_0, 1 GB, $7/mo), static IP, firewall, daily snapshots | Cheapest real WordPress on AWS. Local MariaDB; no RDS/Aurora. Lightsail-packaged image (Bitnami blueprint is deprecated, no new instances after 2026-11-19). |
| Edge | Route 53, ACM, CloudFront (HTTP/3, PriceClass_100), custom cache policies, WAF (managed rule groups, rate limits, wp-admin allowlist, xmlrpc block) | 1 TB/month CloudFront egress is always-free. WAF is the one paid security line item (~$8/mo). |
| Origin lock | Random secret sent by CloudFront as `X-Origin-Verify`; Apache `Require expr` on the instance, header check in the Lambda | Nothing can reach WordPress or the chat API around CloudFront/WAF, even though the Lightsail IP is public. |
| Origin TLS | Let's Encrypt cert on `origin.<domain>` obtained by the instance at first boot, CloudFront `https-only` origin | Admin logins don't cross the CloudFront-to-origin hop in plaintext. `origin_tls = false` falls back to HTTP with the same header lock. |
| KB | S3 docs bucket (versioned, private), S3 Vectors bucket + index, Bedrock KB (Titan V2 embeddings), S3 data source, kb-sync Lambda | S3 Vectors is the cheapest vector store AWS sells ($0.06/GB-mo, no idle compute). Uploads trigger ingestion automatically. |
| Site sync | Lambda + EventBridge Scheduler, daily | Mirrors published WordPress pages and posts into the knowledge base, so the assistant answers from the website itself as well as uploaded documents. |
| Chat | Lambda (Python 3.13, arm64), HTTP API with throttling, optional Guardrail, optional DynamoDB log | `Retrieve` + `Converse` instead of `RetrieveAndGenerate` so OpenAI models on Bedrock work too. Primary model with automatic fallback. |
| Cost guard | AWS Budget with 80% actual / 100% forecast alerts | Cheap insurance. |

## Cost (steady state, one low-traffic site, us-east-1)

Prices verified on aws.amazon.com 2026-09-11.

| Item | Monthly |
|---|---|
| Lightsail micro_3_0 (WordPress + MariaDB) | $7.00 (nano_3_0 is $5 but swaps under load) |
| Lightsail snapshots (~40 GB disk, incremental) | ~$1-2 |
| Route 53 hosted zone | $0.50 |
| CloudFront | $0 within always-free 1 TB / 10M requests |
| WAF web ACL + 4 managed groups + 3 rules | ~$8 (set `enable_waf = false` to drop it) |
| API Gateway + Lambda + daily scheduler | $0 at small-business volumes (Lambda always-free tier) |
| S3 Vectors | cents (storage $0.06/GB, queries $2.50/M) |
| S3 docs + widget buckets | cents |
| Bedrock embeddings (Titan V2) | $0.02 per 1M tokens, effectively $0 |
| Bedrock chat tokens | usage-driven; the only line that scales. Sonnet-class ≈ $0.01-0.02 per answer with 6 retrieved passages, Opus/Fable-class 3-5× that. |
| Guardrail | ~$0.25 per 1,000 answers (content filters) |
| **Floor** | **≈ $9/mo without WAF, ≈ $17/mo with it, plus tokens** |

## Prerequisites

1. Terraform ≥ 1.9 and AWS CLI with credentials for the target account.
2. **Bedrock model access**: serverless models are enabled automatically. Anthropic models need the
   one-time first-use form per account (see below); OpenAI models on Bedrock need nothing. Until it's done,
   chat returns 502 and the Lambda log shows `AccessDeniedException`.
3. A domain you control. Either let the template create the Route 53 zone (then repoint your
   registrar at the output name servers) or pass an existing `route53_zone_id`.
4. Region must have Lightsail, Bedrock Knowledge Bases, and S3 Vectors. us-east-1, us-east-2,
   us-west-2, eu-central-1, ap-southeast-2 are safe; S3 Vectors is in 31 commercial regions as of
   2026-03.

## Build time and what's still manual

The target is one `terraform apply` and about an hour of elapsed time, after which the site is live with
the assistant on it and the remaining effort is WordPress work with the client. Three things sit outside
Terraform:

- **DNS delegation.** If the client's domain is already in Route 53 in the target account, pass its
  `route53_zone_id` and there is nothing to do. Otherwise the registrar has to point at the new zone's
  name servers, and the certificate step waits on that.
- **Anthropic first-use form.** Bedrock enables serverless models automatically, but Anthropic models
  need a one-time use-case form per AWS account before the first call. Submitted from the management
  account of an AWS Organization through the API, it covers every member account, so a build account
  under one org never sees it again.
- **Knowledge-base documents** beyond the website (price sheets, policies, manuals). The website itself is
  picked up nightly with no action; extra documents go in with `scripts/upload-docs.sh` during client hours.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit: name, domain, business_name, emails, admin_cidrs
cp backend.tf.example backend.tf               # optional but recommended: S3 remote state
terraform init
terraform plan
terraform apply
```

About 60 resources. CloudFront takes 5-10 minutes; ACM validation waits on DNS, so if the zone
is new, point the registrar at `route53_name_servers` first (or apply with `-target=module.edge.aws_route53_zone.this`
to get the name servers, repoint, then apply everything).

### After apply

1. **DNS**: confirm `dig +short <domain>` resolves to CloudFront and `dig +short origin.<domain>` to the
   Lightsail IP.
2. **Origin certificate** (when `origin_tls = true`): the instance retries Let's Encrypt every 15
   minutes until `origin.<domain>` resolves. Until then the site returns CloudFront 502. Progress is in
   `/var/log/site-bootstrap.log` on the instance; `sudo /usr/local/sbin/site-origin-cert.sh` forces an attempt.
3. **WordPress admin**: `https://<domain>/wp-admin/`, user from `terraform output wp_admin_user`
   (default `siteadmin`), password from `terraform output -raw wp_admin_password`. The bootstrap creates
   this account, removes the blueprint's default `user` account, sets the site title to `business_name`,
   and turns on `/%postname%/` permalinks. If any of that fails, the log says so and the blueprint's own
   credentials in `~/application_credentials` on the instance still work.
4. **Chat widget**: nothing to do. The bootstrap installs a must-use plugin
   (`wp-content/mu-plugins/site-chat-widget.php`) that loads the widget on every public page, whatever
   theme the client picks. Must-use plugins can't be deactivated from wp-admin, so a theme change or a
   plugin cleanup can't remove the assistant by accident. To turn it off, add
   `define('SITE_CHAT_DISABLED', true);` to `wp-config.php`. Title, greeting, color and side come from
   the `widget` variable; change them and `terraform apply` (about a minute, no WordPress change).
5. **Knowledge base**: two sources feed it, both automatic.
   - **The website.** Every night (3:00 America/Chicago by default) the site sync reads published pages and
     posts through the WordPress REST API, stores each as a clean Markdown copy with its title and URL,
     removes anything unpublished, and re-indexes only if something changed. Answers cite the page and
     link to it. Run it on demand after a round of edits with
     `aws lambda invoke --function-name $(terraform output -raw site_sync_function) /dev/stdout`.
     WordPress's sample post and page are deleted at first boot so the assistant never learns them.
   - **Documents.** `scripts/upload-docs.sh ./docs` syncs a folder to `docs/` in the bucket; ingestion
     starts automatically. `scripts/kb-status.sh` shows recent jobs, `scripts/kb-status.sh --sync` forces
     one. Supported: PDF, DOCX, HTML, Markdown, TXT, CSV, XLSX (max 50 MB per file). Don't write under
     `site/`; the sync owns it and deletes anything it didn't put there.
6. **Test**: `scripts/chat.sh "What are your hours?"`.

## Choosing models

`chat_model_primary` and `chat_model_fallback` take any Bedrock model ID or inference-profile ID that
supports the Converse API. IDs below were read from the Bedrock model cards on 2026-09-11; confirm in
your region with `aws bedrock list-inference-profiles`.

| Tier | Anthropic | OpenAI on Bedrock |
|---|---|---|
| Top | `global.anthropic.claude-fable-5-1`, `global.anthropic.claude-opus-5` | `us.openai.gpt-5.6-terra` |
| Second | `global.anthropic.claude-sonnet-5` (default) | `openai.gpt-oss-120b-1:0` |
| Budget / fallback | `global.anthropic.claude-haiku-4-5-20251001-v1:0` (default fallback) | `openai.gpt-oss-20b-1:0` |

GPT-5.5 and GPT-5.4 are exposed only through Bedrock's OpenAI-compatible "mantle" Responses API, not
Converse, so they do not work here. Changing a model is a `terraform apply` that updates one Lambda
environment variable; nothing else moves.

## Security floor

- CloudFront-only ingress. The Lightsail IP is public but Apache returns 403 to anything without the
  secret header; the API Gateway URL returns 403 the same way. WAF therefore covers every request.
- WAF: Amazon IP reputation, Common Rule Set (three body-size/RFI rules set to count because the WordPress
  editor trips them), Known Bad Inputs, WordPress rule set, `xmlrpc.php` blocked, `/wp-admin` and
  `/wp-login.php` restricted to `admin_cidrs` (admin-ajax.php stays open), per-IP rate limits for the
  site and the API.
- SSH only from `admin_cidrs` and the Lightsail browser console.
- WordPress: `DISALLOW_FILE_EDIT`, `FORCE_SSL_ADMIN`, unattended-upgrades on the OS. Keep WordPress core
  and plugins updated from wp-admin; the template does not do that for you.
- Buckets private with public access blocked; widget bucket readable only by this distribution (OAC).
- Lambda IAM scoped to `Retrieve` on this KB, `InvokeModel` on foundation models and inference profiles,
  and `ApplyGuardrail` on this guardrail.
- Guardrail: hate/insults/sexual/violence/misconduct at MEDIUM, prompt-attack at HIGH, SSN / card /
  bank-account numbers blocked, profanity list on.
- Chat input capped at 2,000 chars and 8 history turns; server rebuilds the history so the client cannot
  inject system or assistant content.

Not in the floor, by design: no Cognito/login for the chatbot (it is a public site widget), no VPC (Lightsail
and Lambda are outside one), no secrets rotation for the origin header (rotate with
`terraform taint random_password.origin_verify` then apply; the instance script needs re-running).

## Operating notes

- **Site sync scope**: pages and posts by default; set `site_sync_post_types = ["pages", "posts", "product"]`
  for WooCommerce. It reads the REST API through CloudFront's own hostname, so it works before the client's
  DNS is cut over. Security plugins that switch off the public REST API break it (the Lambda log shows the
  HTTP error). Page builders that render content only in the browser won't be captured, since the sync reads
  what WordPress stores. `enable_site_sync = false` removes it. The Bedrock-managed web crawler was not used:
  it only works with OpenSearch Serverless, which costs more than this entire stack, and it would index
  every page's menus and footer.

- **Snapshots**: daily Lightsail auto-snapshots at `lightsail_snapshot_time` UTC, seven retained.
- **Page cache**: CloudFront caches anonymous page HTML for `page_cache_default_ttl` seconds (300).
  Cookies are not in the cache key, so visitors carrying only analytics or consent cookies share cached
  pages. A CloudFront Function (`modules/edge/functions/wp-cache-key.js`) gives any request carrying a
  WordPress session cookie (logged in, WooCommerce cart, password-protected post, commenter) a random
  cache-key header, so those requests always go to the origin and are never shared. The origin marks any
  response that sets a cookie `Cache-Control: no-cache="Set-Cookie"` so CloudFront never replays one
  visitor's cookie to another. Static assets under `/wp-content` and `/wp-includes` are cached a day,
  keyed on the `?ver=` query string. A plugin that keeps per-visitor state in a cookie not on the bypass
  list needs its prefix added to `BYPASS_PREFIXES` in the function.
- **Chat logs**: `enable_chat_logs = true` writes question, answer, model, sources and token counts to
  DynamoDB with a 90-day TTL. Off by default.
- **Re-running the instance bootstrap**: `sudo /usr/local/sbin/site-bootstrap.sh`. It is idempotent.
- **Multiple sites**: one directory per site (or one workspace per site) with its own tfvars and state key.
  Resource names are prefixed with `name`, and bucket names include the account ID, so several sites
  coexist in one account.
- **Teardown**: `terraform destroy`. Buckets have `force_destroy`; the Lightsail snapshots are deleted
  with the instance; the Route 53 zone is deleted if the template created it.

## Layout

```
main.tf / variables.tf / outputs.tf   root wiring, one tfvars per site
modules/site-lightsail/               instance, static IP, firewall, first-boot bootstrap (templates/bootstrap.sh.tftpl)
modules/edge/                         Route 53, ACM, CloudFront, WAF, widget bucket, widget/widget.js.tftpl
modules/kb/                           docs bucket, S3 Vectors, Bedrock KB + data source, kb-sync Lambda
modules/chatbot/                      Guardrail, chat Lambda (lambda/handler.py), HTTP API, optional DynamoDB
modules/site-sync/                    nightly WordPress -> knowledge base mirror (lambda/handler.py), EventBridge schedule
scripts/                              upload-docs.sh, kb-status.sh, chat.sh
tests/                                python3 -m unittest tests/test_chat_handler.py tests/test_site_sync.py; node tests/test_wp_cache_key.js
```

## Verification status

- `terraform validate` and `terraform fmt -check`: clean (Terraform 1.16.1, AWS provider 6.x).
- `terraform plan` against a live account: 60 resources, no errors.
- Chat handler: 10 unit tests pass (auth header, validation, retrieval + citation with page links, fallback, history hygiene).
- Cache-key function: 6 unit tests pass (`node tests/test_wp_cache_key.js`).
- Site sync: 5 tests against a local fake WordPress REST API and in-memory S3 (pagination, Markdown
  conversion, change detection, deletions, protected posts, busy-ingestion retry and catch-up).
- Instance bootstrap: rendered template passes `bash -n` for both the outer and inner script. The origin-lock
  `Require expr` and the conditional `no-cache="Set-Cookie"` rule were exercised on a local Apache 2.4
  (403 without the header, Cache-Control added only when a response sets a cookie).
- Not yet exercised end to end: a real `apply` (Lightsail blueprint first-boot timing, Let's Encrypt on the
  origin, CloudFront 421 avoidance via `ServerAlias *`). The first apply of this template should be treated
  as a shakedown; `/var/log/site-bootstrap.log` on the instance is where to look.
