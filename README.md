# Firecrawl Self-Host — Max Performance + Research + SearXNG

Complete self-hosting package for [Firecrawl](https://github.com/firecrawl/firecrawl) with:

- **No rate limits** on any of the 13 working features
- **Custom research service** (5 endpoints: search_papers, inspect_paper, read_paper, related_papers, search_github)
- **SearXNG** meta-search backend (Google + Bing + DuckDuckGo + Wikipedia)
- **Dual LLM model strategy** — heavy model (gpt-oss-120b) for extraction, fast model (deepseek-v4-flash) for schema generation, summaries, reranking, and codegen
- **Fireworks AI** as the LLM backend for JSON extraction (or any OpenAI-compatible API)
- **Maxed-out Docker resources** (32 workers, 50 concurrent crawls, 20 browser instances)

## Quick Start

```bash
# 1. Run setup (clones Firecrawl, applies patches)
./setup.sh

# 2. Edit .env with your API keys
nano .env

# 3. Build and start
./setup.sh --start
```

## Prerequisites

- Docker + Docker Compose
- git, curl
- A Fireworks AI API key (or any OpenAI-compatible API key)
- Recommended: 16+ CPU cores, 64GB+ RAM

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
│   └── opencode.json        # opencode MCP config (copy to ~/.config/opencode/config.json)
├── research-service/
│   ├── main.py              # FastAPI research proxy (OpenAlex + arXiv + GitHub)
│   ├── Dockerfile           # Python 3.12 container
│   └── requirements.txt     # fastapi, httpx, PyPDF2
├── searxng/
│   └── settings.yml         # SearXNG config (JSON API enabled, no rate limiting)
└── firecrawl/               # Cloned Firecrawl repo (created by setup.sh)
```

## What's Included

### 13 Working Features (all unlimited)

| # | Feature | Backend | Limits Removed |
|---|---------|---------|----------------|
| 1 | `scrape` (markdown) | Playwright | Rate limit 100k/min, timeout 300s |
| 2 | `scrape` (JSON extract) | Fireworks AI | Rate limit 100k/min |
| 3 | `scrape` (query format) | Fireworks AI | Rate limit 100k/min |
| 4 | `crawl` | Playwright + queue | 50 concurrent, 32 workers, 10000 page limit |
| 5 | `map` | Playwright | 1M URL limit, 100k/min rate |
| 6 | `search` | SearXNG | 1000 results, 100k/min rate |
| 7 | `extract` | Fireworks AI | 100 URLs, 100k/min rate |
| 8 | `parse` | Firecrawl API | No limit |
| 9 | `research_search_papers` | OpenAlex | 10,000 results per query |
| 10 | `research_inspect_paper` | arXiv + OpenAlex | No limit |
| 11 | `research_read_paper` | arXiv PDF download | All PDF pages, 500 passages |
| 12 | `research_related_papers` | OpenAlex citations | 10,000 results, 20 seed IDs |
| 13 | `research_search_github` | GitHub API | 1,000 results |

### 6 Features NOT Available (require cloud infrastructure)

| Feature | Reason |
|---------|--------|
| `interact` | Requires Supabase database for stored scrape context |
| `monitor_*` | Requires database for monitor persistence |
| `feedback` / `search_feedback` | Requires database |

**Agent** (`agent` / `agent_status`) now works locally — it scrapes provided URLs (or searches the web if no URLs), then uses the LLM to synthesize a research report. Uses in-memory storage instead of Supabase.

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
4. Create a `.env` file from the template

### Step 3: Edit .env

```bash
nano .env
```

**Required values to change:**
- `OPENAI_API_KEY` — Your Fireworks AI API key (get one at https://fireworks.ai)
- `SEARXNG_SECRET` — Any random string
- `POSTGRES_PASSWORD` — Any random password

**Optional but recommended:**
- `GITHUB_TOKEN` — GitHub personal access token (raises API limit from 60 to 5000 req/hr)
- `MAILTO` — Your email (gives higher OpenAlex API rate limits)

**LLM Backend options:**
- Fireworks AI (recommended): `OPENAI_BASE_URL=https://api.fireworks.ai/inference/v1`, `MODEL_NAME=accounts/fireworks/models/gpt-oss-120b`
- Ollama (local, free): Uncomment the OLLAMA_* lines, set `MODEL_NAME=deepseek-r1:7b`
- OpenAI: `OPENAI_BASE_URL=https://api.openai.com/v1`, `MODEL_NAME=gpt-4o-mini`

**Dual-model setup (recommended for Fireworks AI):**
- `MODEL_NAME` = heavy model for accurate structured data extraction (gpt-oss-120b)
- `MODEL_NAME_FAST` = fast/cheap model for schema generation, summaries, reranking, codegen (deepseek-v4-flash)
- DeepSeek-V4-Flash: 284B MoE, $0.14/1M tokens, low latency, 1M context, strong reasoning+coding — ideal for high-volume fast tasks
- GPT-OSS-120B: 120B, good structured output — ideal for accurate data extraction
- If `MODEL_NAME_FAST` is not set, all tasks use `MODEL_NAME` (single-model mode)

### Step 4: Build and start

```bash
./setup.sh --start
```

Or manually:
```bash
docker compose build
docker compose up -d
```

Build takes 10-20 minutes. After starting, verify:
```bash
curl http://localhost:3002/
# Should return HTML

docker exec firecrawl-api-1 node -e "
  fetch('http://research-service:8000/health')
    .then(r => r.json())
    .then(d => console.log(d))
"
# Should print {"status":"ok"}
```

### Step 5: Configure opencode

1. Copy the config:
```bash
cp config/opencode.json ~/.config/opencode/config.json
```

2. Restart opencode. It will auto-install `firecrawl-mcp` via npx.

3. Patch the MCP server limits:
```bash
./patch-mcp.sh
```

4. Restart opencode again for the MCP patches to take effect.

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
CRAWL_CONCURRENT_REQUESTS=10
MAX_CONCURRENT_JOBS=10
BROWSER_POOL_SIZE=5
```

### Medium machines (16 cores / 64GB RAM)
```env
NUM_WORKERS_PER_QUEUE=16
CRAWL_CONCURRENT_REQUESTS=20
MAX_CONCURRENT_JOBS=20
BROWSER_POOL_SIZE=10
```

### Large machines (32+ cores / 128GB+ RAM)
```env
NUM_WORKERS_PER_QUEUE=32
CRAWL_CONCURRENT_REQUESTS=50
MAX_CONCURRENT_JOBS=50
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

Firecrawl's research endpoints (`/v2/search/research/papers`, etc.) are a **proxy** — they forward requests to `RESEARCH_PROXY_URL`. Without that URL set, the routes aren't even registered (404).

This package includes a custom FastAPI service (`research-service/`) that implements all 5 research endpoints:

| Endpoint | Upstream API | Purpose |
|----------|-------------|---------|
| `/v2/research/papers` | OpenAlex | Search 250M+ papers by topic |
| `/v2/research/papers/:id` | arXiv + OpenAlex | Get paper metadata by ID |
| `/v2/research/papers/:id` (with `query=`) | arXiv PDF download | Extract relevant passages from full text |
| `/v2/research/papers/:id/similar` | OpenAlex citation graph | Find related papers |
| `/v2/research/github` | GitHub Search API | Search repos, issues, and PRs |

### SearXNG

Firecrawl's `/search` endpoint uses DuckDuckGo by default, which gets IP-banned after a few searches. SearXNG is a self-hosted meta-search engine that aggregates results from Google, Bing, DuckDuckGo, and Wikipedia — no rate limits, no bans.

### Patches Applied

The `patch-firecrawl.sh` script modifies these Firecrawl source files:

1. **`rate-limiter.ts`** — All rate limits set to 100,000/min (effectively unlimited)
2. **`config.ts`** — `MAX_CPU` and `MAX_RAM` set to 0.99; worker lock duration 300s; stalled check 120s
3. **`types.ts`** — Search limit 1000; extract URLs 100; map limit 1M; `waitFor` 300s; search timeout 300s
4. **`research-proxy.ts`** — Proxy timeout 600s
5. **`docker-compose.yaml`** — 32 workers, 50 concurrent, 20 browser pool, increased memory
6. **MCP server** (`index.js`) — k.max limits increased to 10000/500/1000
7. **JS SDK** (`index.js`) — HTTP timeout 600s

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
docker exec firecrawl-api-1 node -e "
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
- Check the API can reach it: `docker exec firecrawl-api-1 node -e "fetch('http://research-service:8000/health').then(r=>r.text()).then(console.log)"`

### Research: arXiv papers return 404
- The arXiv API uses HTTPS. The service is configured for `https://export.arxiv.org/api`
- If arXiv is down, try using DOI-based lookups instead

### MCP tools not appearing in opencode
1. Verify config: `cat ~/.config/opencode/config.json`
2. Restart opencode
3. Run `./patch-mcp.sh` to patch the MCP server limits
4. Restart opencode again

### DuckDuckGo anti-bot errors in logs
This is expected — SearXNG handles search now. DuckDuckGo errors are only in the fallback path. If SearXNG returns results, DuckDuckGo is never called.

## Updating

To update Firecrawl to a newer version:
```bash
cd firecrawl
git pull
cd ..
./patch-firecrawl.sh ./firecrawl
docker compose build
docker compose up -d --force-recreate
```

## License

The Firecrawl source is licensed under AGPL-3.0 (see firecrawl/LICENSE).
The research-service and configuration files in this package are provided as-is.
