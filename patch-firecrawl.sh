#!/usr/bin/env bash
# ======================================================================
# patch-firecrawl.sh — Applies all performance & limit-removal patches
# to a cloned Firecrawl repository.
#
# Usage:  ./patch-firecrawl.sh /path/to/firecrawl
# ======================================================================
set -euo pipefail

FIRECRAWL_DIR="${1:-./firecrawl}"

if [ ! -d "$FIRECRAWL_DIR" ]; then
  echo "Error: Firecrawl directory not found at $FIRECRAWL_DIR"
  echo "Usage: $0 /path/to/firecrawl"
  exit 1
fi

echo "Patching Firecrawl at: $FIRECRAWL_DIR"
echo "========================================"

# ── 1. Rate limiter: remove all rate limits ──────────────────────────
echo "[1/10] Patching rate-limiter.ts (remove all rate limits)..."
cat > "$FIRECRAWL_DIR/apps/api/src/services/rate-limiter.ts" << 'RATELIMITER'
import { RateLimiterRedis } from "rate-limiter-flexible";
import { config } from "../config";
import { RateLimiterMode } from "../types";
import type { TeamFlags } from "../controllers/v1/types";
import Redis from "ioredis";

export const redisRateLimitClient = new Redis(config.REDIS_RATE_LIMIT_URL!, {
  enableAutoPipelining: true,
});

const createRateLimiter = (keyPrefix, points) =>
  new RateLimiterRedis({
    storeClient: redisRateLimitClient,
    keyPrefix,
    points,
    duration: 60,
  });

const fallbackRateLimits: Record<RateLimiterMode, number> = {
  crawl: 100000,
  scrape: 100000,
  search: 100000,
  map: 100000,
  extract: 100000,
  preview: 100000,
  extractStatus: 100000,
  crawlStatus: 100000,
  extractAgentPreview: 100000,
  scrapeAgentPreview: 100000,
  browser: 100000,
  browserExecute: 100000,
  browserReplay: 100000,
  account: 100000,
  supportAsk: 100000,
  supportDocsSearch: 100000,
  research: 100000,
  developerSearch: 100000,
  labs: 100000,
};

const BASE_RATE_LIMITS: Partial<Record<RateLimiterMode, number>> = {
  [RateLimiterMode.Scrape]: 100000,
  [RateLimiterMode.Map]: 100000,
  [RateLimiterMode.Crawl]: 100000,
  [RateLimiterMode.Search]: 100000,
  [RateLimiterMode.Extract]: 100000,
  [RateLimiterMode.Browser]: 100000,
  [RateLimiterMode.BrowserExecute]: 100000,
  [RateLimiterMode.CrawlStatus]: 100000,
  [RateLimiterMode.ExtractStatus]: 100000,
};

export function getRateLimiter(mode: RateLimiterMode): RateLimiterRedis {
  const rateLimit = fallbackRateLimits?.[mode] ?? 100000;
  return createRateLimiter(`${mode}`, rateLimit);
}

export function getRateLimitOverride(
  mode: RateLimiterMode,
  overrides: unknown,
): number | undefined {
  if (typeof overrides !== "object" || overrides === null) return undefined;
  const value = (overrides as Record<string, unknown>)[mode];
  if (typeof value !== "number") return undefined;
  if (!Number.isInteger(value) || value <= 0) return undefined;
  return value;
}

export function getAutumnRateLimiter(
  mode: RateLimiterMode,
  multiplier: number = 1,
  _flags?: TeamFlags | null,
): RateLimiterRedis {
  const base = BASE_RATE_LIMITS[mode];
  let rateLimit: number;
  if (base !== undefined) {
    rateLimit = base;
  } else {
    rateLimit = fallbackRateLimits?.[mode] ?? 100000;
  }
  return createRateLimiter(`${mode}`, rateLimit);
}

const PLAN_PRIORITY_TIERS: {
  minMultiplier: number;
  bucketLimit: number;
  planModifier: number;
}[] = [
  { minMultiplier: 1, bucketLimit: 25, planModifier: 0.5 },
  { minMultiplier: 10, bucketLimit: 100, planModifier: 0.3 },
  { minMultiplier: 50, bucketLimit: 200, planModifier: 0.2 },
  { minMultiplier: 500, bucketLimit: 400, planModifier: 0.1 },
  { minMultiplier: 1000, bucketLimit: 400, planModifier: 0.1 },
  { minMultiplier: 2500, bucketLimit: 1000, planModifier: 0.05 },
];

export function inferPlanPriorityFromMultiplier(multiplier: number): {
  bucketLimit: number;
  planModifier: number;
} {
  let chosen = PLAN_PRIORITY_TIERS[0];
  for (const tier of PLAN_PRIORITY_TIERS) {
    if (multiplier >= tier.minMultiplier) chosen = tier;
  }
  return { bucketLimit: chosen.bucketLimit, planModifier: chosen.planModifier };
}
RATELIMITER
echo "  Done."

# ── 2. Config: max CPU/RAM, longer worker timeouts, more retries ─────
echo "[2/10] Patching config.ts (MAX_CPU, MAX_RAM, worker timeouts, retry limits)..."
sed -i 's/MAX_CPU: z.coerce.number().default(0.8)/MAX_CPU: z.coerce.number().default(0.99)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/MAX_RAM: z.coerce.number().default(0.8)/MAX_RAM: z.coerce.number().default(0.99)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/WORKER_LOCK_DURATION: z.coerce.number().default(60000)/WORKER_LOCK_DURATION: z.coerce.number().default(300000)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/WORKER_STALLED_CHECK_INTERVAL: z.coerce.number().default(30000)/WORKER_STALLED_CHECK_INTERVAL: z.coerce.number().default(120000)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/SCRAPE_MAX_ATTEMPTS: z.coerce.number().int().positive().default(6)/SCRAPE_MAX_ATTEMPTS: z.coerce.number().int().positive().default(20)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/SCRAPE_MAX_FEATURE_TOGGLES: z.coerce.number().int().positive().default(3)/SCRAPE_MAX_FEATURE_TOGGLES: z.coerce.number().int().positive().default(10)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/SCRAPE_MAX_FEATURE_REMOVALS: z.coerce.number().int().positive().default(3)/SCRAPE_MAX_FEATURE_REMOVALS: z.coerce.number().int().positive().default(10)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/SCRAPE_MAX_PDF_PREFETCHES: z.coerce.number().int().positive().default(2)/SCRAPE_MAX_PDF_PREFETCHES: z.coerce.number().int().positive().default(10)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/SCRAPE_MAX_DOCUMENT_PREFETCHES: z.coerce.number().int().positive().default(2)/SCRAPE_MAX_DOCUMENT_PREFETCHES: z.coerce.number().int().positive().default(10)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
echo "  Done."

# ── 2b. System monitor: disable host-level CPU/RAM gate ──────────────
echo "[2b/10] Patching system-monitor.ts (disable host CPU/RAM gate)..."
cat > "$FIRECRAWL_DIR/apps/api/src/services/system-monitor.ts" << 'SYSMON'
import si from "systeminformation";
import { config } from "../config";
import { Mutex } from "async-mutex";
import os from "os";
import fs from "fs";
import { logger } from "../lib/logger";

const IS_KUBERNETES = config.IS_KUBERNETES;
const MAX_CPU = config.MAX_CPU;
const MAX_RAM = config.MAX_RAM;
const CACHE_DURATION = config.SYS_INFO_MAX_CACHE_DURATION;

class SystemMonitor {
  private static instance: SystemMonitor;
  private static instanceMutex = new Mutex();
  private cpuUsageCache: number | null = null;
  private memoryUsageCache: number | null = null;
  private lastCpuCheck: number = 0;
  private lastMemoryCheck: number = 0;
  private previousCpuUsage: number = 0;
  private previousTime: number = Date.now();

  private constructor() {}

  public static async getInstance(): Promise<SystemMonitor> {
    if (SystemMonitor.instance) return SystemMonitor.instance;
    await this.instanceMutex.runExclusive(async () => {
      if (!SystemMonitor.instance) SystemMonitor.instance = new SystemMonitor();
    });
    return SystemMonitor.instance;
  }

  public async checkMemoryUsage() {
    if (IS_KUBERNETES) return this._checkMemoryUsageKubernetes();
    return this._checkMemoryUsage();
  }

  private readMemoryCurrent(): number {
    return parseInt(fs.readFileSync("/sys/fs/cgroup/memory.current", "utf8").trim(), 10);
  }

  private readMemoryMax(): number {
    const data = fs.readFileSync("/sys/fs/cgroup/memory.max", "utf8").trim();
    return data === "max" ? Infinity : parseInt(data, 10);
  }

  private async _checkMemoryUsageKubernetes() {
    try {
      const cur = this.readMemoryCurrent();
      const max = this.readMemoryMax();
      return max === Infinity ? cur / os.totalmem() : cur / max;
    } catch (e) { logger.error(`Error calculating memory: ${e}`); return 0; }
  }

  private async _checkMemoryUsage() {
    const now = Date.now();
    if (this.memoryUsageCache !== null && now - this.lastMemoryCheck < CACHE_DURATION)
      return this.memoryUsageCache;
    const m = await si.mem();
    const pct = (m.total - m.available) / m.total;
    this.memoryUsageCache = pct; this.lastMemoryCheck = now;
    return pct;
  }

  public async checkCpuUsage() {
    if (IS_KUBERNETES) return this._checkCpuUsageKubernetes();
    return this._checkCpuUsage();
  }

  private readCpuUsage(): number {
    const d = fs.readFileSync("/sys/fs/cgroup/cpu.stat", "utf8");
    const match = d.match(/^usage_usec (\d+)$/m);
    if (match) return parseInt(match[1], 10);
    throw new Error("Could not read usage_usec from cpu.stat");
  }

  private getNumberOfCPUs(): number {
    try {
      const data = fs.readFileSync("/sys/fs/cgroup/cpuset.cpus.effective", "utf8").trim();
      if (!data) throw new Error("cpuset empty");
      const cpus = this.parseCpuList(data);
      if (cpus.length === 0) throw new Error("no CPUs");
      return cpus.length;
    } catch (e) {
      logger.warn(`cpuset fallback: ${e}`);
      return os.cpus().length;
    }
  }

  private parseCpuList(list: string): number[] {
    const cpus: number[] = [];
    for (const range of list.split(",")) {
      const [s, e] = range.split("-");
      const start = parseInt(s, 10), end = e ? parseInt(e, 10) : start;
      for (let i = start; i <= end; i++) cpus.push(i);
    }
    return cpus;
  }

  private async _checkCpuUsageKubernetes() {
    try {
      const usage = this.readCpuUsage(); const now = Date.now();
      if (this.previousCpuUsage === 0) { this.previousCpuUsage = usage; this.previousTime = now; return 0; }
      const pct = (usage - this.previousCpuUsage) / ((now - this.previousTime) * 1000) / this.getNumberOfCPUs();
      this.previousCpuUsage = usage; this.previousTime = now;
      return pct;
    } catch (e) { logger.error(`CPU: ${e}`); return 0; }
  }

  private async _checkCpuUsage() {
    const now = Date.now();
    if (this.cpuUsageCache !== null && now - this.lastCpuCheck < CACHE_DURATION) return this.cpuUsageCache;
    const load = (await si.currentLoad()).currentLoad / 100;
    this.cpuUsageCache = load; this.lastCpuCheck = now;
    return load;
  }

  public async acceptConnection() { return true; }

  public clearCache() {
    this.cpuUsageCache = null; this.memoryUsageCache = null;
    this.lastCpuCheck = 0; this.lastMemoryCheck = 0;
  }
}
export default SystemMonitor.getInstance();
SYSMON
echo "  Done."

# ── 3. Types: increase search limit, extract URL limit, map limit, waitFor ─
echo "[3/10] Patching types.ts (search/extract/map/waitFor limits)..."
TYPES="$FIRECRAWL_DIR/apps/api/src/controllers/v2/types.ts"
sed -i 's/limit: z.int().positive().finite().max(100).optional().prefault(10)/limit: z.int().positive().finite().max(1000).optional().prefault(10)/' "$TYPES"
sed -i 's/\.max(10, "Maximum of 10 URLs allowed per request while in beta.")/.max(100, "Maximum of 100 URLs allowed per request.")/' "$TYPES"
sed -i 's/export const MAX_MAP_LIMIT = 100000/export const MAX_MAP_LIMIT = 1000000/' "$TYPES"
sed -i 's/waitFor: z.int().nonnegative().max(60000).prefault(0)/waitFor: z.int().nonnegative().max(300000).prefault(0)/' "$TYPES"
sed -i 's/timeout: z.int().positive().finite().prefault(60000)/timeout: z.int().positive().finite().prefault(300000)/' "$TYPES"
echo "  Done."

# ── 4. Research proxy: increase timeout ───────────────────────────────
echo "[4/11] Patching research-upstream.ts (timeout 120s -> 600s)..."
sed -i 's/const TIMEOUT_MS = 120_000/const TIMEOUT_MS = 600_000/' \
  "$FIRECRAWL_DIR/apps/api/src/lib/research-upstream.ts"
echo "  Done."

# ── 4b. Map: add direct HTML link extraction fallback ────────────────
echo "[4b/11] Patching map-utils.ts (add direct HTML scraping fallback)..."
MAP_UTILS="$FIRECRAWL_DIR/apps/api/src/lib/map-utils.ts"
# Add config import if not present
if ! grep -q 'import { config } from "../config"' "$MAP_UTILS"; then
  sed -i 's|import { Logger } from "winston";|import { Logger } from "winston";\nimport { config } from "../config";|' "$MAP_UTILS"
fi
# Add the direct scraping fallback after the cosine similarity block
if ! grep -q "map-fallback" "$MAP_UTILS"; then
  sed -i '/if (search) {$/,/^  }$/{
    /^  }$/a\
\
    // Direct HTML scraping fallback: when search-based approaches return\
    // empty or very few results, scrape the page directly and extract links.\
    // This handles JS-rendered sites (GitHub, SPAs) and sites without sitemaps.\
    if (mapResults.length <= 1 \&\& crawlerOptions.sitemap !== "only") {\
      try {\
        const directUrl = resolvedUrl || url;\
        const controller = new AbortController();\
        const timeout = setTimeout(() => controller.abort(), 30000);\
        const resp = await fetch(directUrl, {\
          signal: controller.signal,\
          headers: {\
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",\
            Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",\
            ...headers,\
          },\
          redirect: "follow",\
        });\
        clearTimeout(timeout);\
        if (resp.ok) {\
          const html = await resp.text();\
          const contentType = resp.headers.get("content-type") || "";\
          const extractedLinks = await crawler.extractLinksFromContent(html, directUrl, contentType);\
          for (const link of extractedLinks) {\
            mapResults.push({ url: link });\
          }\
        }\
      } catch (e) {\
        // Direct scraping failed, continue with whatever we have\
      }\
    }
  }' "$MAP_UTILS"
fi
echo "  Done."

# ── 5. Copy research-service into Firecrawl apps dir ─────────────────
echo "[5/10] Copying research-service into Firecrawl apps directory..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/research-service" ]; then
  cp -r "$SCRIPT_DIR/research-service" "$FIRECRAWL_DIR/apps/research-service"
  echo "  Copied to $FIRECRAWL_DIR/apps/research-service"
else
  echo "  WARNING: research-service directory not found alongside this script."
fi
echo "  Done."

# ── 6. Patch docker-compose.yaml with max performance + new services ─
echo "[6/10] Patching docker-compose.yaml..."
COMPOSE="$FIRECRAWL_DIR/docker-compose.yaml"

# Performance env vars (use sed only if the old default is found)
sed -i 's/NUM_WORKERS_PER_QUEUE: ${NUM_WORKERS_PER_QUEUE:-8}/NUM_WORKERS_PER_QUEUE: ${NUM_WORKERS_PER_QUEUE:-32}/' "$COMPOSE" || true
sed -i 's/CRAWL_CONCURRENT_REQUESTS: ${CRAWL_CONCURRENT_REQUESTS:-10}/CRAWL_CONCURRENT_REQUESTS: ${CRAWL_CONCURRENT_REQUESTS:-50}/' "$COMPOSE" || true
sed -i 's/MAX_CONCURRENT_JOBS: ${MAX_CONCURRENT_JOBS:-5}/MAX_CONCURRENT_JOBS: ${MAX_CONCURRENT_JOBS:-50}/' "$COMPOSE" || true
sed -i 's/BROWSER_POOL_SIZE: ${BROWSER_POOL_SIZE:-5}/BROWSER_POOL_SIZE: ${BROWSER_POOL_SIZE:-20}/' "$COMPOSE" || true

# SearXNG env default
sed -i 's|SEARXNG_ENDPOINT: ${SEARXNG_ENDPOINT}|SEARXNG_ENDPOINT: ${SEARXNG_ENDPOINT:-http://searxng:8080}|' "$COMPOSE" || true

# Add RESEARCH_PROXY_URL env if not present
if ! grep -q "RESEARCH_PROXY_URL" "$COMPOSE"; then
  sed -i '/SEARXNG_CATEGORIES: ${SEARXNG_CATEGORIES}/a\  RESEARCH_PROXY_URL: ${RESEARCH_PROXY_URL}' "$COMPOSE"
fi

# Playwright: increase concurrent pages + resources
sed -i 's/MAX_CONCURRENT_PAGES: ${CRAWL_CONCURRENT_REQUESTS:-10}/MAX_CONCURRENT_PAGES: ${CRAWL_CONCURRENT_REQUESTS:-50}/' "$COMPOSE" || true
sed -i 's/    cpus: 2.0/    # cpus: 2.0/' "$COMPOSE" || true
sed -i 's/    mem_limit: 4G/    mem_limit: 32G/' "$COMPOSE" || true
sed -i 's/    memswap_limit: 4G/    memswap_limit: 32G/' "$COMPOSE" || true
sed -i 's/      - \/tmp\/.cache:noexec,nosuid,size=1g/      - \/tmp\/.cache:noexec,nosuid,size=4g/' "$COMPOSE" || true

# API container: increase resources
sed -i 's/    cpus: 4.0/    # cpus: 4.0/' "$COMPOSE" || true
sed -i 's/    mem_limit: 8G/    mem_limit: 64G/' "$COMPOSE" || true
sed -i 's/    memswap_limit: 8G/    memswap_limit: 64G/' "$COMPOSE" || true

# Startup timeout
sed -i 's/HARNESS_STARTUP_TIMEOUT_MS: ${HARNESS_STARTUP_TIMEOUT_MS:-60000}/HARNESS_STARTUP_TIMEOUT_MS: ${HARNESS_STARTUP_TIMEOUT_MS:-120000}/' "$COMPOSE" || true

# Restart policy: keep all long-running services up across reboots
# (foundationdb-init stays one-shot).
perl -0777 -pi -e 's/^  (playwright-service|api|redis|rabbitmq|nuq-postgres|foundationdb|searxng|research-service):\n(?![ \t]*restart:)/  ${1}:\n    restart: unless-stopped\n/gm' "$COMPOSE"

# Add SearXNG + research-service services and searxng volume if not present
if ! grep -q "  searxng:" "$COMPOSE"; then
  sed -i '/^networks:/i\  searxng:\n    image: searxng/searxng:latest\n    environment:\n      - SEARXNG_BASE_URL=http://searxng:8080\n      - SEARXNG_SECRET=${SEARXNG_SECRET:-firecrawl-secret-key}\n    networks:\n      - backend\n    volumes:\n      - ./searxng-settings.yml:/etc/searxng/settings.yml:ro\n    logging:\n      driver: "json-file"\n      options:\n        max-size: "5m"\n        max-file: "2"\n        compress: "true"\n\n  research-service:\n    build: apps/research-service\n    environment:\n      S2_API_KEY: ${S2_API_KEY}\n      GITHUB_TOKEN: ${GITHUB_TOKEN}\n      MAILTO: ${MAILTO:-research@firecrawl.local}\n    networks:\n      - backend\n    mem_limit: 16G\n    memswap_limit: 16G\n    logging:\n      driver: "json-file"\n      options:\n        max-size: "5m"\n        max-file: "2"\n        compress: "true"\n' "$COMPOSE"
  sed -i '/^  fdb-cluster-file:/a\  searxng-data:' "$COMPOSE"
fi

# Copy searxng settings file next to docker-compose if not present
if [ ! -f "$FIRECRAWL_DIR/searxng-settings.yml" ] && [ -f "$SCRIPT_DIR/searxng/settings.yml" ]; then
  cp "$SCRIPT_DIR/searxng/settings.yml" "$FIRECRAWL_DIR/searxng-settings.yml"
fi
echo "  Done."

# ── 7. Patch MCP server (if installed via npx cache) ─────────────────
echo "[7/10] Patching MCP server limits (if installed)..."
MCP_JS=$(find /home -path "*/firecrawl-mcp/dist/index.js" 2>/dev/null | head -1 || true)
if [ -n "$MCP_JS" ]; then
  echo "  Found MCP server at: $MCP_JS"
  sed -i 's/k: z2.number().int().min(1).max(500).optional().describe("Number of ranked papers to return (default 40).")/k: z2.number().int().min(1).max(10000).optional().describe("Number of ranked papers to return (default 40).")/' "$MCP_JS"
  sed -i 's/seed_ids: z2.array(z2.string()).min(1).max(10)/seed_ids: z2.array(z2.string()).min(1).max(20)/' "$MCP_JS"
  sed -i 's/k: z2.number().int().min(1).max(50).optional().describe("Number of passages to return (default 4).")/k: z2.number().int().min(1).max(500).optional().describe("Number of passages to return (default 4).")/' "$MCP_JS"
  sed -i 's/k: z2.number().int().min(1).max(100).optional()/k: z2.number().int().min(1).max(1000).optional()/' "$MCP_JS" || true
  echo "  Patched MCP server limits."
else
  echo "  MCP server not found — run patch-mcp.sh after installing firecrawl-mcp."
fi
echo "  Done."

# ── 8. Patch Firecrawl JS SDK timeout ────────────────────────────────
echo "[8/10] Patching JS SDK HTTP timeout (if installed)..."
SDK_JS=$(find /home -path "*/@mendable/firecrawl-js/dist/index.js" 2>/dev/null | head -1 || true)
if [ -n "$SDK_JS" ]; then
  echo "  Found JS SDK at: $SDK_JS"
  sed -i 's/timeout: options.timeoutMs ?? 3e5/timeout: options.timeoutMs ?? 6e5/' "$SDK_JS"
  echo "  Patched SDK timeout (300s -> 600s)."
else
  echo "  JS SDK not found — will be patched when firecrawl-mcp is installed."
fi
echo "  Done."

# ── 9. Dual-model: add getModelFast() and route fast tasks to it ──────
echo "[9/10] Patching dual-model support (heavy + fast model)..."

# 9a. Add MODEL_NAME_FAST to config.ts (if not present)
if ! grep -q "MODEL_NAME_FAST" "$FIRECRAWL_DIR/apps/api/src/config.ts"; then
  sed -i '/MODEL_NAME: z.string().optional(),/a\  MODEL_NAME_FAST: z.string().optional(),' \
    "$FIRECRAWL_DIR/apps/api/src/config.ts"
fi

# 9b. Add getModelFast() to generic-ai.ts (if not present)
GENERIC_AI="$FIRECRAWL_DIR/apps/api/src/lib/generic-ai.ts"
if ! grep -q "getModelFast" "$GENERIC_AI"; then
  sed -i '/^export function getEmbeddingModel/i\
export function getModelFast(name: string, provider: Provider = defaultProvider) {\
  const fastModel = config.MODEL_NAME_FAST;\
  if (fastModel) {\
    return providerList[provider](fastModel);\
  }\
  return getModel(name, provider);\
}\
' "$GENERIC_AI"
fi

# 9c. Route fast tasks to getModelFast in llmExtract.ts
LLM_EXTRACT="$FIRECRAWL_DIR/apps/api/src/scraper/scrapeURL/transformers/llmExtract.ts"
sed -i 's/import { getModel } from "..\/..\/..\/lib\/generic-ai";/import { getModel, getModelFast } from "..\/..\/..\/lib\/generic-ai";/' "$LLM_EXTRACT" 2>/dev/null || true
sed -i '0,/const model = getModel("gpt-4o-mini", "openai");/s//const model = getModelFast("gpt-4o-mini", "openai");/' "$LLM_EXTRACT" 2>/dev/null || true
sed -i '0,/const retryModel = getModel("gpt-4.1-mini", "openai");/s//const retryModel = getModelFast("gpt-4.1-mini", "openai");/' "$LLM_EXTRACT" 2>/dev/null || true
sed -i '0,/const model = getModel("gpt-4o-mini", "openai");/s//const model = getModelFast("gpt-4o-mini", "openai");/' "$LLM_EXTRACT" 2>/dev/null || true
sed -i '0,/const retryModel = getModel("gpt-4.1-mini", "openai");/s//const retryModel = getModelFast("gpt-4.1-mini", "openai");/' "$LLM_EXTRACT" 2>/dev/null || true
sed -i 's/return getModel(selection.modelName, "openai");/return getModelFast(selection.modelName, "openai");/g' "$LLM_EXTRACT" 2>/dev/null || true
sed -i 's/retryModel: getModel("gpt-4.1-mini", "openai"),/retryModel: getModelFast("gpt-4.1-mini", "openai"),/g' "$LLM_EXTRACT" 2>/dev/null || true

# 9d. Route diff.ts LLM diff to fast model
DIFF_TS="$FIRECRAWL_DIR/apps/api/src/scraper/scrapeURL/transformers/diff.ts"
if ! grep -q "getModelFast" "$DIFF_TS"; then
  sed -i 's/import { generateCompletions } from "\.\/llmExtract";/import { generateCompletions } from ".\/llmExtract";\nimport { getModelFast } from "..\/..\/..\/lib\/generic-ai";/' "$DIFF_TS" 2>/dev/null || true
  sed -i 's/previousWarning: document.warning,/previousWarning: document.warning,\n              model: getModelFast("gpt-4o-mini", "openai"),/' "$DIFF_TS" 2>/dev/null || true
fi

# 9e. Route Fire-0 extract fast tasks to getModelFast
F0_LLM="$FIRECRAWL_DIR/apps/api/src/lib/extract/fire-0/llmExtract-f0.ts"
if ! grep -q "getModelFast" "$F0_LLM"; then
  sed -i 's/import { getModel } from "..\/..\/..\/lib\/generic-ai";/import { getModel, getModelFast } from "..\/..\/..\/lib\/generic-ai";/' "$F0_LLM" 2>/dev/null || true
  sed -i 's/const model = getModel("gpt-4o-mini");/const model = getModelFast("gpt-4o-mini");/' "$F0_LLM" 2>/dev/null || true
fi

F0_CHECK="$FIRECRAWL_DIR/apps/api/src/lib/extract/fire-0/completions/checkShouldExtract-f0.ts"
if ! grep -q "getModelFast" "$F0_CHECK"; then
  sed -i 's/import { getModel } from "..\/..\/..\/..\/lib\/generic-ai";/import { getModel, getModelFast } from "..\/..\/..\/..\/lib\/generic-ai";/' "$F0_CHECK" 2>/dev/null || true
  sed -i 's/model: getModel("gpt-4o-mini"),/model: getModelFast("gpt-4o-mini"),/' "$F0_CHECK" 2>/dev/null || true
fi

F0_URL="$FIRECRAWL_DIR/apps/api/src/lib/extract/fire-0/url-processor-f0.ts"
if ! grep -q "getModelFast" "$F0_URL"; then
  sed -i 's/import { getModel } from "..\/..\/generic-ai";/import { getModel, getModelFast } from "..\/..\/generic-ai";/' "$F0_URL" 2>/dev/null || true
  sed -i 's/model: getModel("gpt-4o-mini"),/model: getModelFast("gpt-4o-mini"),/' "$F0_URL" 2>/dev/null || true
fi

F0_RERANK="$FIRECRAWL_DIR/apps/api/src/lib/extract/fire-0/reranker-f0.ts"
if ! grep -q "getModelFast" "$F0_RERANK"; then
  sed -i 's/import { generateCompletions } from "..\/..\/..\/scraper\/scrapeURL\/transformers\/llmExtract";/import { generateCompletions } from "..\/..\/..\/scraper\/scrapeURL\/transformers\/llmExtract";\nimport { getModelFast } from "..\/..\/..\/lib\/generic-ai";/' "$F0_RERANK" 2>/dev/null || true
  sed -i 's/isExtractEndpoint: true,/isExtractEndpoint: true,\n            model: getModelFast("gpt-4o-mini", "openai"),/' "$F0_RERANK" 2>/dev/null || true
fi

# 9f. Route deep research queries/planning to fast model
RESEARCH_MGR="$FIRECRAWL_DIR/apps/api/src/lib/deep-research/research-manager.ts"
if ! grep -q "getModelFast" "$RESEARCH_MGR"; then
  sed -i 's/import { getModel } from "..\/generic-ai";/import { getModel, getModelFast } from "..\/generic-ai";/' "$RESEARCH_MGR" 2>/dev/null || true
  # Insert a model line after the first two `markdown: "",` option sites,
  # preserving indentation. A single pass avoids duplicate-key errors.
  perl -0777 -pi -e 'BEGIN{$c=0} s/^([ \t]*)markdown: "",\n/$c++; $c <= 2 ? "${1}markdown: \"\",\n${1}model: getModelFast(\"gpt-4o-mini\", \"openai\"),\n" : $&/gme' "$RESEARCH_MGR" 2>/dev/null || true
fi

# 9g. Route llms.txt generation to fast model
LLMSTXT="$FIRECRAWL_DIR/apps/api/src/lib/generate-llmstxt/generate-llmstxt-service.ts"
if ! grep -q "getModelFast" "$LLMSTXT"; then
  sed -i 's/import { getModel } from "..\/generic-ai";/import { getModel, getModelFast } from "..\/generic-ai";/' "$LLMSTXT" 2>/dev/null || true
  sed -i 's/model: getModel("gpt-4o-mini", "openai"),/model: getModelFast("gpt-4o-mini", "openai"),/' "$LLMSTXT" 2>/dev/null || true
fi

# 9h. Route engpicker to fast model
ENGPICKER="$FIRECRAWL_DIR/apps/api/src/lib/engpicker.ts"
if ! grep -q "getModelFast" "$ENGPICKER"; then
  sed -i 's/import { getModel } from ".\/generic-ai";/import { getModel, getModelFast } from ".\/generic-ai";/' "$ENGPICKER" 2>/dev/null || true
  sed -i 's/model: getModel("gpt-4o-mini", "openai"),/model: getModelFast("gpt-4o-mini", "openai"),/' "$ENGPICKER" 2>/dev/null || true
fi

# 9i. Route deterministic JSON to fast model via openai provider
DJ_CLIENT="$FIRECRAWL_DIR/apps/api/src/lib/deterministicJson/llm/client.ts"
if ! grep -q "getModelFast" "$DJ_CLIENT"; then
  sed -i 's/import { getModel } from "..\/..\/generic-ai";/import { getModel, getModelFast } from "..\/..\/generic-ai";/' "$DJ_CLIENT" 2>/dev/null || true
  sed -i 's/model: getModel(CODEGEN_MODEL, "vertex"),/model: getModelFast(CODEGEN_MODEL, "openai"),/' "$DJ_CLIENT" 2>/dev/null || true
  sed -i 's/model: getModel(ANCHOR_MODEL, "groq"),/model: getModelFast(ANCHOR_MODEL, "openai"),/' "$DJ_CLIENT" 2>/dev/null || true
  sed -i 's/model: getModel(LIGHT_MODEL, "groq"),/model: getModelFast(LIGHT_MODEL, "openai"),/' "$DJ_CLIENT" 2>/dev/null || true
fi

# 9j. Add MODEL_NAME_FAST to docker-compose.yaml
if ! grep -q "MODEL_NAME_FAST" "$COMPOSE"; then
  sed -i '/MODEL_NAME: ${MODEL_NAME}/a\  MODEL_NAME_FAST: ${MODEL_NAME_FAST}' "$COMPOSE"
fi
echo "  Done."

# ── 10. Agent: replace external proxy with local in-memory agent ──────
echo "[10/10] Patching agent controllers (local in-memory agent)..."

cat > "$FIRECRAWL_DIR/apps/api/src/controllers/v2/agent.ts" << 'AGENTTS'
import { v7 as uuidv7 } from "uuid";
import { Response } from "express";
import {
  AgentRequest,
  AgentResponse,
  RequestWithAuth,
  agentRequestSchema,
} from "./types";
import { logger as _logger } from "../../lib/logger";
import { logRequest } from "../../services/logging/log_job";
import { config } from "../../config";
import { getScrapeZDR } from "../../lib/zdr-helpers";
import { getModel } from "../../lib/generic-ai";
import { generateText } from "ai";

export const agentJobs = new Map<string, {
  id: string;
  team_id: string;
  status: "processing" | "completed" | "failed";
  prompt: string;
  urls?: string[];
  schema?: any;
  data?: any;
  error?: string;
  created_at: number;
  model: string;
  cancelled: boolean;
}>();

export async function agentController(
  req: RequestWithAuth<{}, AgentResponse, AgentRequest>,
  res: Response<AgentResponse>,
) {
  const agentId = uuidv7();
  const logger = _logger.child({
    agentId, extractId: agentId, jobId: agentId,
    teamId: req.auth.team_id, team_id: req.auth.team_id,
    module: "api/v2", method: "agentController",
    zeroDataRetention: getScrapeZDR(req.acuc?.flags) === "forced",
  });

  req.body = agentRequestSchema.parse(req.body);
  _logger.info("Agent starting...", { request: req.body });

  await logRequest({
    id: agentId, kind: "agent", api_version: "v2",
    team_id: req.auth.team_id, origin: req.body.origin ?? "api",
    integration: req.body.integration,
    target_hint: req.body.urls?.[0] ?? req.body.prompt ?? "",
    zeroDataRetention: false, api_key_id: req.acuc?.api_key_id ?? null,
  });

  agentJobs.set(agentId, {
    id: agentId, team_id: req.auth.team_id, status: "processing",
    prompt: req.body.prompt ?? "", urls: req.body.urls, schema: req.body.schema,
    created_at: Date.now(), model: req.body.model ?? "spark-1-pro", cancelled: false,
  });

  runAgentAsync(agentId, req.body, req.auth.team_id, logger).catch(err => {
    logger.error("Agent failed", { error: err });
    const job = agentJobs.get(agentId);
    if (job && job.status === "processing") {
      job.status = "failed";
      job.error = err instanceof Error ? err.message : String(err);
    }
  });

  return res.status(200).json({ success: true, id: agentId });
}

async function runAgentAsync(agentId: string, body: AgentRequest, teamId: string, logger: any) {
  const job = agentJobs.get(agentId);
  if (!job) return;
  const prompt = body.prompt ?? "";
  const urls = body.urls ?? [];
  const schema = body.schema;
  const scrapedContent: string[] = [];

  for (const url of urls.slice(0, 10)) {
    if (job.cancelled) { job.status = "failed"; job.error = "Cancelled"; return; }
    try {
      const r = await fetch(`http://localhost:${config.PORT}/v2/scrape`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer bypass" },
        body: JSON.stringify({ url, formats: ["markdown"], onlyMainContent: true, origin: "agent" }),
      });
      if (r.ok) {
        const d = await r.json();
        const md = d.data?.markdown;
        if (md) scrapedContent.push(`## Content from ${url}\n\n${md.slice(0, 8000)}`);
      }
    } catch (e) { logger.warn("Agent scrape failed", { url, error: e }); }
  }

  if (scrapedContent.length === 0 && prompt) {
    try {
      const sr = await fetch(`http://localhost:${config.PORT}/v2/search`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer bypass" },
        body: JSON.stringify({ query: prompt.slice(0, 200), limit: 5, origin: "agent" }),
      });
      if (sr.ok) {
        const sd = await sr.json();
        const results = sd.data?.web ?? [];
        for (const result of results.slice(0, 3)) {
          if (job.cancelled) break;
          try {
            const r = await fetch(`http://localhost:${config.PORT}/v2/scrape`, {
              method: "POST",
              headers: { "Content-Type": "application/json", Authorization: "Bearer bypass" },
              body: JSON.stringify({ url: result.url, formats: ["markdown"], onlyMainContent: true, origin: "agent" }),
            });
            if (r.ok) {
              const d = await r.json();
              const md = d.data?.markdown;
              if (md) scrapedContent.push(`## Content from ${result.url}\n\n${md.slice(0, 8000)}`);
            }
          } catch {}
        }
      }
    } catch (e) { logger.warn("Agent search failed", { error: e }); }
  }

  if (job.cancelled) { job.status = "failed"; job.error = "Cancelled"; return; }
  if (scrapedContent.length === 0) { job.status = "failed"; job.error = "No content gathered"; return; }
  const allContent = scrapedContent.join("\n\n---\n\n").slice(0, 50000);

  try {
    const model = getModel("gpt-4o-mini", "openai");
    if (schema) {
      const { generateObject } = await import("ai");
      const result = await generateObject({ model, schema, system: `You are a research agent. Answer: ${prompt}`, prompt: allContent, temperature: 0 });
      job.data = result.object;
    } else {
      const result = await generateText({ model, system: `You are a research agent. Answer comprehensively: ${prompt}`, prompt: allContent, temperature: 0 });
      job.data = { summary: result.text };
    }
    job.status = "completed";
  } catch (err) {
    job.status = "failed";
    job.error = err instanceof Error ? err.message : String(err);
  }
}
AGENTTS

cat > "$FIRECRAWL_DIR/apps/api/src/controllers/v2/agent-status.ts" << 'AGENTSTATUSTS'
import { Response } from "express";
import { AgentStatusResponse, RequestWithAuth } from "./types";
import { agentJobs } from "./agent";

export async function agentStatusController(
  req: RequestWithAuth<{ jobId: string }, AgentStatusResponse, any>,
  res: Response<AgentStatusResponse>,
) {
  const job = agentJobs.get(req.params.jobId);
  if (!job || job.team_id !== req.auth.team_id) {
    return res.status(404).json({ success: false, error: "Agent job not found" });
  }
  const now = Date.now();
  for (const [id, j] of agentJobs) {
    if (now - j.created_at > 24 * 60 * 60 * 1000) agentJobs.delete(id);
  }
  return res.status(200).json({
    success: true, status: job.status, error: job.error || undefined,
    data: job.status === "completed" ? job.data : undefined,
    model: job.model as "spark-1-pro" | "spark-1-mini",
    expiresAt: new Date(job.created_at + 1000 * 60 * 60 * 24).toISOString(),
    creditsUsed: 20,
  });
}
AGENTSTATUSTS

cat > "$FIRECRAWL_DIR/apps/api/src/controllers/v2/agent-cancel.ts" << 'AGENTCANCELTS'
import { Response } from "express";
import { AgentCancelResponse, RequestWithAuth } from "./types";
import { agentJobs } from "./agent";

export async function agentCancelController(
  req: RequestWithAuth<{ jobId: string }, AgentCancelResponse, any>,
  res: Response<AgentCancelResponse>,
) {
  const job = agentJobs.get(req.params.jobId);
  if (!job || job.team_id !== req.auth.team_id) {
    return res.status(404).json({ success: false, error: "Agent job not found" });
  }
  if (job.status !== "processing") {
    return res.status(409).json({ success: false, error: "Agent already finished" });
  }
  job.cancelled = true;
  job.status = "failed";
  job.error = "Agent cancelled by user";
  return res.status(200).json({ success: true });
}
AGENTCANCELTS
echo "  Done."

echo ""
echo "========================================"
echo "All patches applied successfully!"
echo ""
echo "Next steps:"
echo "  1. Copy .env.example to .env and fill in your values"
echo "  2. Set MODEL_NAME (heavy) and MODEL_NAME_FAST (fast) in .env"
echo "  3. Run: docker compose build"
echo "  4. Run: docker compose up -d"
echo "  5. Run: ./patch-mcp.sh (after installing firecrawl-mcp via opencode)"
echo ""
echo "See README.md for full instructions."
