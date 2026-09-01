# Firecrawl Self-Host — Max Performance + Research + SearXNG

Complete self-hosting package for [Firecrawl](https://github.com/firecrawl/firecrawl) with:

- **Self-hosted throughput** with explicit safety bounds and no hosted API quota
- **Custom research service** (6 endpoints: search_papers, inspect_paper, read_paper, related_papers, search_github, developer_search)
- **SearXNG** meta-search backend (Google + Bing + DuckDuckGo + Wikipedia)
- **Dual LLM model strategy** — heavy model for extraction, fast model for schema generation, summaries, reranking, and codegen
- **DeepSeek-V4-Flash-0731** as default LLM (284B MoE, $0.14/1M tokens, 1M context, fast+cheap)
- **Fireworks AI** as the LLM backend for JSON extraction (or any OpenAI-compatible API)
- **Tuned Docker resources** (32 NuQ workers, 50 local concurrency, 20 browser sessions)

## Quick Start

```bash
# 1. Run setup (clones a pinned Firecrawl revision and applies patches)
./setup.sh

# 2. Edit .env with your API keys
nano .env

# 3. Build and start; schema initialization is a startup dependency
./setup.sh --start
```

## Prerequisites

- Docker + Docker Compose
- git, curl
- A Fireworks AI API key (or any OpenAI-compatible API key)
- Recommended: 16+ CPU cores, 64GB+ RAM
- Host tools: `curl`, `python3`, `perl`, `openssl`, and Node.js 18+ for MCP patching

The API is published on `127.0.0.1` by default because self-host mode sets
`USE_DB_AUTHENTICATION=false`. If the API must be reachable remotely, put it
behind an authenticated reverse proxy/firewall and set `HOST_BIND_ADDRESS`
deliberately; do not expose the default unauthenticated API directly.

## Directory Structure

```
firecrawl-selfhost/
├── setup.sh                 # One-command setup script
├── patch-firecrawl.sh       # Patches Firecrawl source (rate limits, timeouts, etc.)
├── patch-mcp.sh             # Patches firecrawl-mcp npm package (k.max limits)
├── docker-compose.yaml      # Docker Compose with all services
├── .env.example             # Configuration template
├── README.md                # This file
├── config/
│   └── opencode.json        # MCP snippet (merge into ~/.config/opencode/opencode.json[c])
├── research-service/
│   ├── main.py              # FastAPI research proxy (OpenAlex + arXiv + GitHub)
│   ├── Dockerfile           # Python 3.12 container
│   └── requirements.txt     # fastapi, httpx, PyPDF2
├── searxng/
│   └── settings.yml         # SearXNG config (JSON API enabled, no rate limiting)
└── firecrawl/               # Cloned Firecrawl repo (created by setup.sh)
```

## What's Included

### Working Features

| # | Feature | Backend | Self-hosted bound |
|---|---------|---------|----------------|
| 1 | `scrape` (markdown) | Playwright | 300s request timeout |
| 2 | `scrape` (JSON extract) | Configured LLM | Provider/model context |
| 3 | `scrape` (query format) | Configured LLM | Provider/model context |
| 4 | `crawl` | Playwright + queue | 10,000 pages/request, 50 local concurrency |
| 5 | `map` | Playwright | 1,000,000 URLs/request |
| 6 | `search` | SearXNG | 1,000 results/source/request |
| 7 | `extract` | Configured LLM | 100 URLs/request in v2 |
| 8 | `parse` | Firecrawl API | 50 MB upload limit |
| 9 | `research_search_papers` | OpenAlex | 10,000 results/request |
| 10 | `research_inspect_paper` | arXiv + OpenAlex | One paper/request |
| 11 | `research_read_paper` | arXiv/PMC PDF download | 500 passages/request |
| 12 | `research_related_papers` | OpenAlex citations + S2 | 500 results, 20 seed IDs |
| 13 | `research_search_github` | GitHub API | 1,000 results/request |
| 14 | `developer_search` | GitHub code, issues, and repositories | 1,000 results/request |

### Features Requiring Additional Infrastructure

| Feature | Reason |
|---------|--------|
| `interact` | Uses the local browser-session adapter layered onto Playwright |
| `monitor_*` | Uses the local PostgreSQL schema and durable volume |
| `feedback` / `search_feedback` | Uses the local PostgreSQL schema |
| Screenshot | Uses the local Playwright renderer and returns a data URL |
| Scrape actions/branding | Require a compatible Fire Engine endpoint via `FIRE_ENGINE_BETA_URL` |

The local agent patch scrapes up to 10 supplied URLs (or searches when no URLs
are provided), caps synthesis input at 400,000 characters, and persists job
state in PostgreSQL when `DATABASE_URL` is configured. Jobs interrupted by an
API restart are reported as failed rather than silently remaining “processing”.

The MCP configuration caps every Firecrawl tool result at 400,000 characters
(roughly 100,000 typical English/Markdown tokens). Oversized results retain
their beginning and end with a truncation notice, leaving most of a 1M-token
model context available for the conversation and follow-up analysis.

## Step-by-Step Installation

### Step 1: Clone this package

```bash
# If you received this as a folder, cd into it
cd /path/to/firecrawl-selfhost
```

### Step 2: Run setup

```bash
./setup.sh
```

This will:
1. Clone the Firecrawl repository into `./firecrawl/`
2. Apply all patches (rate limits, timeouts, max performance settings)
3. Copy the research-service into the Firecrawl apps directory
4. Create or preserve `.env`, generate local service secrets, and enforce mode `0600`
5. Pin the source revision to `FIRECRAWL_REF` (override it explicitly when upgrading)

### Step 3: Edit .env

```bash
nano .env
```

**Required values to change:**
- `OPENAI_API_KEY` — Your Fireworks AI API key (get one at https://fireworks.ai)
- `POSTGRES_PASSWORD` — Any random password

`setup.sh` generates `SEARXNG_SECRET`, `BULL_AUTH_KEY`, and
`BROWSER_SERVICE_API_KEY` when they are missing or still contain a template
value. Do not commit `.env`.

**Optional but recommended:**
- `GITHUB_TOKEN` — GitHub personal access token (raises API limit from 60 to 5000 req/hr)
- `MAILTO` — Your email (gives higher OpenAlex API rate limits)

### Optional IITM institutional full-text access

Institutional access is disabled by default. Authenticate interactively in a
browser on the IITM network, then export only the required publisher cookies in
Netscape cookie-jar format to `config/institutional-cookies.txt`. Never put
credentials or cookie contents in `.env` or Git.

```env
INSTITUTIONAL_ACCESS_ENABLED=true
INSTITUTIONAL_COOKIE_FILE=./config/institutional-cookies.txt
```

Cookie-bearing requests are restricted to `INSTITUTIONAL_ALLOWED_DOMAINS`.
Downloads and PDF parsing are bounded by `INSTITUTIONAL_MAX_DOWNLOAD_BYTES` and
`INSTITUTIONAL_MAX_PDF_PAGES`. Use this only in accordance with IITM and
publisher license terms.

**LLM Backend options:**
- Fireworks AI (recommended): `OPENAI_BASE_URL=https://api.fireworks.ai/inference/v1`, `MODEL_NAME=accounts/fireworks/models/gpt-oss-120b`
- Ollama (local, free): Uncomment the OLLAMA_* lines, set `MODEL_NAME=deepseek-r1:7b`
- OpenAI: `OPENAI_BASE_URL=https://api.openai.com/v1`, `MODEL_NAME=gpt-4o-mini`

**Dual-model setup (recommended for Fireworks AI):**
- `MODEL_NAME` = heavy model for accurate structured data extraction (e.g. `gpt-oss-120b`)
- `MODEL_NAME_FAST` = fast/cheap model for schema generation, summaries, reranking, codegen (e.g. `deepseek-v4-flash-0731`)
- DeepSeek-V4-Flash-0731: 284B MoE, $0.14/1M tokens, low latency, 1M context, strong reasoning+coding
- GPT-OSS-120B: 120B, good structured output — ideal for accurate data extraction
- If `MODEL_NAME_FAST` is not set, all tasks use `MODEL_NAME` (single-model mode)
- **Simplest setup**: set both to `deepseek-v4-flash-0731` — it handles both extraction and fast tasks well

### Step 4: Build and start

```bash
./setup.sh --start
```

Or manually:
```bash
# Refresh the in-stack DATABASE_URL after changing PostgreSQL credentials.
./setup.sh
docker compose build
docker compose up -d --wait --wait-timeout 300
```

Build takes 10-20 minutes. After starting, verify:
```bash
curl -fsS http://127.0.0.1:${PORT:-3002}/
# Should return the Firecrawl JSON health response

docker compose exec -T api node -e "
  fetch('http://research-service:8000/health')
    .then(r => r.json())
    .then(d => console.log(d))
"
# Should print {"status":"ok"}
```

### Step 5: Configure opencode

The file is a minimal MCP snippet. Do not overwrite an existing global
configuration; merge its `mcp.firecrawl` entry into the active file:
`~/.config/opencode/opencode.json` or `~/.config/opencode/opencode.jsonc`.

```json
{
  "mcp": {
    "firecrawl": {
      "type": "local",
      "command": ["npx", "-y", "firecrawl-mcp@3.22.2"],
      "environment": {
        "FIRECRAWL_API_URL": "http://localhost:3002",
        "FIRECRAWL_MCP_MAX_OUTPUT_CHARS": "400000"
      }
    }
  }
}
```

After merging:

1. Create the config directory if needed:
```bash
mkdir -p ~/.config/opencode
```

2. Restart opencode. It will auto-install `firecrawl-mcp` via npx.

3. Patch the installed MCP bundle and add the developer-search tool:
```bash
./patch-mcp.sh
```

4. Restart opencode again. Verify configuration with `opencode debug config`
   and `opencode mcp list`.

### Step 6: Verify everything works

In opencode, test all features:
```
# Search the web
> search for "artificial intelligence 2026" with firecrawl

# Scrape a page with JSON extraction
> scrape https://en.wikipedia.org/wiki/Artificial_intelligence and extract the title and definition

# Crawl a site
> crawl https://openai.com/research with 5 page limit

# Research: search papers
> search for papers on "transformer attention mechanism" with firecrawl research

# Research: inspect a paper
> inspect paper arxiv:1706.03762 with firecrawl research

# Research: read a paper
> read paper arxiv:1706.03762 asking "how does self-attention work?"

# Research: related papers
> find papers related to arxiv:1706.03762 about "deep learning"

# Research: search GitHub
> search GitHub for "artificial intelligence framework"
```

## Performance Tuning

The defaults are tuned for a **64-core / 512GB RAM** machine. Adjust in `.env`:

### Smaller machines (8 cores / 16GB RAM)
```env
NUM_WORKERS_PER_QUEUE=8
NUQ_WORKER_COUNT=8
CRAWL_CONCURRENT_REQUESTS=10
MAX_CONCURRENT_JOBS=10
SELF_HOSTED_CONCURRENCY_LIMIT=10
BROWSER_POOL_SIZE=5
```

### Medium machines (16 cores / 64GB RAM)
```env
NUM_WORKERS_PER_QUEUE=16
NUQ_WORKER_COUNT=16
CRAWL_CONCURRENT_REQUESTS=20
MAX_CONCURRENT_JOBS=20
SELF_HOSTED_CONCURRENCY_LIMIT=20
BROWSER_POOL_SIZE=10
```

### Large machines (32+ cores / 128GB+ RAM)
```env
NUM_WORKERS_PER_QUEUE=32
NUQ_WORKER_COUNT=32
CRAWL_CONCURRENT_REQUESTS=50
MAX_CONCURRENT_JOBS=50
SELF_HOSTED_CONCURRENCY_LIMIT=50
BROWSER_POOL_SIZE=20
```

Also adjust memory limits in `docker-compose.yaml`:
- `playwright-service`: `mem_limit`
- `api`: `mem_limit`
- `research-service`: `mem_limit`

## How It Works

### Dual-Model Architecture

Firecrawl uses LLM models for different tasks. Not all tasks need the same model power. This setup uses two models strategically:

| Task | Model | Why |
|------|-------|-----|
| JSON extraction (scrape `json` format) | **gpt-oss-120b** (heavy) | Needs accurate structured output |
| Extract API (Fire-0 batch/single) | **gpt-oss-120b** (heavy) | Needs accurate data extraction |
| Extract schema analysis | **gpt-oss-120b** (heavy) | Complex schema understanding |
| Deep research final analysis | **gpt-oss-120b** (heavy) | Complex reasoning for final report |
| Change tracking with schema | **gpt-oss-120b** (heavy) | Structured extraction from both versions |
| Schema generation from prompt | **deepseek-v4-flash** (fast) | Simple JSON generation, high volume |
| Summary generation | **deepseek-v4-flash** (fast) | Text summarization, high volume |
| Clean content classification | **deepseek-v4-flash** (fast) | Binary decision, fast |
| Crawler options generation | **deepseek-v4-flash** (fast) | Simple JSON |
| Extract "should extract" check | **deepseek-v4-flash** (fast) | Binary classification |
| URL reranking | **deepseek-v4-flash** (fast) | Ranking, high volume |
| URL processor / basic completions | **deepseek-v4-flash** (fast) | Simple text |
| Deep research query generation + planning | **deepseek-v4-flash** (fast) | Generating search queries |
| llms.txt generation | **deepseek-v4-flash** (fast) | Titles/descriptions, high volume |
| Engine picker | **deepseek-v4-flash** (fast) | Evaluating scrape quality |
| Change tracking LLM diff | **deepseek-v4-flash** (fast) | Text comparison |
| Deterministic JSON codegen | **deepseek-v4-flash** (fast) | **Coding is deepseek's specialty** |
| Deterministic JSON askLlm | **deepseek-v4-flash** (fast) | Field value extraction |

This is implemented via `getModel()` (uses `MODEL_NAME`) and `getModelFast()` (uses `MODEL_NAME_FAST`) in `generic-ai.ts`.

### Research Service

Firecrawl's research endpoints (`/v2/search/research/papers`, etc.) are a
**proxy** — they forward requests to `RESEARCH_PROXY_URL`. This package sets
that URL to the in-stack research service by default.

This package includes a custom FastAPI service (`research-service/`) that implements all 5 research endpoints:

| Endpoint | Upstream API | Purpose |
|----------|-------------|---------|
| `/v2/research/papers` | OpenAlex | Search 250M+ papers by topic |
| `/v2/research/papers/:id` | arXiv + OpenAlex | Get paper metadata by ID |
| `/v2/research/papers/:id` (with `query=`) | arXiv PDF download | Extract relevant passages from full text |
| `/v2/research/papers/:id/similar` | OpenAlex citation graph | Find related papers |
| `/v2/research/github` | GitHub Search API | Search repos, issues, and PRs |
| `/v2/search/developer` | GitHub code/history APIs | Search code, docs, READMEs, issues, and PRs |

### SearXNG

Firecrawl's `/search` endpoint uses SearXNG first. SearXNG aggregates Google,
Bing, DuckDuckGo, Wikipedia, and category-specific news/image engines. It
reduces direct-provider bans but cannot remove upstream provider rate limits;
DuckDuckGo is retained only as a type-safe web fallback.

### Patches Applied

The `patch-firecrawl.sh` script modifies these Firecrawl source files:

1. **`rate-limiter.ts`** — Preserve upstream multiplier/override semantics; self-host auth bypasses hosted rate limiting
2. **`config.ts`** — `MAX_CPU` and `MAX_RAM` set to 0.99; worker lock duration 300s; stalled check 120s
3. **`types.ts`** — Search limit 1000; extract URLs 100; map limit 1M; `waitFor` 300s; search timeout 300s
4. **`research-proxy.ts`** — Proxy timeout 600s
5. **`docker-compose.yaml`** — 32 NuQ workers, 50 local concurrency, durable services, health gates, and local schema bootstrap
6. **MCP server** (`index.js`) — validated k.max limits, a 400k-character result cap, and a developer-search bridge when the package lacks it
7. **JS SDK** (`index.js`) — HTTP timeout 600s
8. **Playwright service** — local browser-session compatibility adapter for `browser`/`interact`
9. **Research service** — canonical IDs, filters, scored passages, citation modes, and GitHub code search

## Troubleshooting

### Services won't start
```bash
docker compose logs api --tail 50
docker compose logs research-service --tail 50
docker compose logs searxng --tail 50
```

### Search returns empty results
Check SearXNG is running and accessible:
```bash
docker compose exec -T api node -e "
  fetch('http://searxng:8080/search?q=test&format=json')
    .then(r => r.json())
    .then(d => console.log('Results:', d.results?.length))
"
```
If 0 results, SearXNG engines may be blocked. Edit `searxng/settings.yml` to add/remove engines.

### JSON extraction returns null
- Check that `OPENAI_API_KEY` and `MODEL_NAME` are correct in `.env`
- Check that the model name exists on your LLM provider
- For Fireworks AI, verify model IDs at https://fireworks.ai/models
- Check logs: `docker compose logs api --tail 50 | grep -i "LLM\|error"`

### Research endpoints return 404
- Verify `RESEARCH_PROXY_URL` is set in `.env`: `http://research-service:8000`
- Check the research service is running: `docker compose logs research-service`
- Check the API can reach it: `docker compose exec -T api node -e "fetch('http://research-service:8000/health').then(r=>r.text()).then(console.log)"`

### Research: arXiv papers return 404
- The arXiv API uses HTTPS. The service is configured for `https://export.arxiv.org/api`
- If arXiv is down, try using DOI-based lookups instead

### MCP tools not appearing in opencode
1. Verify config: `opencode debug config`
2. Restart opencode
3. Run `./patch-mcp.sh` to patch the MCP server limits and developer search
4. Restart opencode again

### Database or interact state is missing
Run the idempotent schema repair against the running stack:
```bash
./init-db.sh
```
It honors a custom `DATABASE_URL`, creates the local persistence indexes, and
fails nonzero if any required DDL cannot be applied.

### Browser view links
The local adapter supports `agent-browser` commands only. Its view URLs are
safe HTML snapshots, not a remote live-streaming UI. Use `stdout` and `result`
for automation; configure a dedicated browser service if a real live view or
arbitrary Node execution is required.

### DuckDuckGo or upstream anti-bot errors
SearXNG is tried first and ordinary web search may fall back to DuckDuckGo.
Provider-level throttling and CAPTCHA responses are still possible; tune the
engine list in `searxng/settings.yml`.

## Updating

To update Firecrawl to a newer version:
```bash
FIRECRAWL_REF=<tested-commit> ./setup.sh
docker compose build
docker compose up -d --wait --wait-timeout 300
./init-db.sh
```
Back up PostgreSQL before an upstream update. The Firecrawl checkout is
patched in place, so do not `git pull` over local changes; use a fresh clone or
set `FIRECRAWL_REF` and re-run setup. The PostgreSQL, Redis, and RabbitMQ
named volumes survive container recreation.

### Backups
```bash
docker compose exec -T nuq-postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > firecrawl-backup.sql
```
Restore into a stopped disposable stack first, then run `./init-db.sh` to apply
any schema additions.

## License

The Firecrawl source is licensed under AGPL-3.0 (see firecrawl/LICENSE).
The research-service and configuration files in this package are provided as-is.
