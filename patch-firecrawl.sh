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
echo "[1/8] Patching rate-limiter.ts (remove all rate limits)..."
cat > "$FIRECRAWL_DIR/apps/api/src/services/rate-limiter.ts" << 'RATELIMITER'
import { RateLimiterRedis } from "rate-limiter-flexible";
import { config } from "../config";
import { RateLimiterMode } from "../types";
import Redis from "ioredis";
import type { AuthCreditUsageChunk } from "../controllers/v1/types";

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

const fallbackRateLimits: AuthCreditUsageChunk["rate_limits"] = {
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
};

export function getRateLimiter(
  mode: RateLimiterMode,
  rate_limits: AuthCreditUsageChunk["rate_limits"] | null,
): RateLimiterRedis {
  let rateLimit = rate_limits?.[mode] ?? fallbackRateLimits?.[mode] ?? 500;
  if (mode === RateLimiterMode.Search || mode === RateLimiterMode.Scrape) {
    rateLimit = Math.max(rateLimit, 100);
  }
  return createRateLimiter(`${mode}`, rateLimit);
}
RATELIMITER
echo "  Done."

# ── 2. Config: max CPU/RAM, longer worker timeouts, more retries ─────
echo "[2/8] Patching config.ts (MAX_CPU, MAX_RAM, worker timeouts, retry limits)..."
sed -i 's/MAX_CPU: z.coerce.number().default(0.8)/MAX_CPU: z.coerce.number().default(0.99)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/MAX_RAM: z.coerce.number().default(0.8)/MAX_RAM: z.coerce.number().default(0.99)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/WORKER_LOCK_DURATION: z.coerce.number().default(60000)/WORKER_LOCK_DURATION: z.coerce.number().default(300000)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
sed -i 's/WORKER_STALLED_CHECK_INTERVAL: z.coerce.number().default(30000)/WORKER_STALLED_CHECK_INTERVAL: z.coerce.number().default(120000)/' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"
# Increase retry limits
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
echo "[2b/8] Patching system-monitor.ts (disable host CPU/RAM gate)..."
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
    if (SystemMonitor.instance) {
      return SystemMonitor.instance;
    }
    await this.instanceMutex.runExclusive(async () => {
      if (!SystemMonitor.instance) {
        SystemMonitor.instance = new SystemMonitor();
      }
    });
    return SystemMonitor.instance;
  }

  public async checkMemoryUsage() {
    if (IS_KUBERNETES) {
      return this._checkMemoryUsageKubernetes();
    }
    return this._checkMemoryUsage();
  }

  private readMemoryCurrent(): number {
    const data = fs.readFileSync("/sys/fs/cgroup/memory.current", "utf8");
    return parseInt(data.trim(), 10);
  }

  private readMemoryMax(): number {
    const data = fs.readFileSync("/sys/fs/cgroup/memory.max", "utf8").trim();
    if (data === "max") {
      return Infinity;
    }
    return parseInt(data, 10);
  }

  private async _checkMemoryUsageKubernetes() {
    try {
      const currentMemoryUsage = this.readMemoryCurrent();
      const memoryLimit = this.readMemoryMax();
      let memoryUsagePercentage: number;
      if (memoryLimit === Infinity) {
        const totalMemory = os.totalmem();
        memoryUsagePercentage = currentMemoryUsage / totalMemory;
      } else {
        memoryUsagePercentage = currentMemoryUsage / memoryLimit;
      }
      return memoryUsagePercentage;
    } catch (error) {
      logger.error(`Error calculating memory usage: ${error}`);
      return 0;
    }
  }

  private async _checkMemoryUsage() {
    const now = Date.now();
    if (
      this.memoryUsageCache !== null &&
      now - this.lastMemoryCheck < CACHE_DURATION
    ) {
      return this.memoryUsageCache;
    }
    const memoryData = await si.mem();
    const totalMemory = memoryData.total;
    const availableMemory = memoryData.available;
    const usedMemory = totalMemory - availableMemory;
    const usedMemoryPercentage = usedMemory / totalMemory;
    this.memoryUsageCache = usedMemoryPercentage;
    this.lastMemoryCheck = now;
    return usedMemoryPercentage;
  }

  public async checkCpuUsage() {
    if (IS_KUBERNETES) {
      return this._checkCpuUsageKubernetes();
    }
    return this._checkCpuUsage();
  }

  private readCpuUsage(): number {
    const data = fs.readFileSync("/sys/fs/cgroup/cpu.stat", "utf8");
    const match = data.match(/^usage_usec (\d+)$/m);
    if (match) {
      return parseInt(match[1], 10);
    }
    throw new Error("Could not read usage_usec from cpu.stat");
  }

  private getNumberOfCPUs(): number {
    let cpus: number[] = [];
    try {
      const cpusetPath = "/sys/fs/cgroup/cpuset.cpus.effective";
      const data = fs.readFileSync(cpusetPath, "utf8").trim();
      if (!data) {
        throw new Error(`${cpusetPath} is empty.`);
      }
      cpus = this.parseCpuList(data);
      if (cpus.length === 0) {
        throw new Error("No CPUs found in cpuset.cpus.effective");
      }
    } catch (error) {
      logger.warn(
        `Unable to read cpuset.cpus.effective, defaulting to OS CPUs: ${error}`,
      );
      cpus = os.cpus().map((cpu, index) => index);
    }
    return cpus.length;
  }

  private parseCpuList(cpuList: string): number[] {
    const ranges = cpuList.split(",");
    const cpus: number[] = [];
    ranges.forEach(range => {
      const [startStr, endStr] = range.split("-");
      const start = parseInt(startStr, 10);
      const end = endStr !== undefined ? parseInt(endStr, 10) : start;
      for (let i = start; i <= end; i++) {
        cpus.push(i);
      }
    });
    return cpus;
  }

  private async _checkCpuUsageKubernetes() {
    try {
      const usage = this.readCpuUsage();
      const now = Date.now();
      if (this.previousCpuUsage === 0) {
        this.previousCpuUsage = usage;
        this.previousTime = now;
        return 0;
      }
      const deltaUsage = usage - this.previousCpuUsage;
      const deltaTime = (now - this.previousTime) * 1000;
      const numCPUs = this.getNumberOfCPUs();
      const cpuUsagePercentage = deltaUsage / deltaTime / numCPUs;
      this.previousCpuUsage = usage;
      this.previousTime = now;
      return cpuUsagePercentage;
    } catch (error) {
      logger.error(`Error calculating CPU usage: ${error}`);
      return 0;
    }
  }

  private async _checkCpuUsage() {
    const now = Date.now();
    if (
      this.cpuUsageCache !== null &&
      now - this.lastCpuCheck < CACHE_DURATION
    ) {
      return this.cpuUsageCache;
    }
    const cpuData = await si.currentLoad();
    const cpuLoad = cpuData.currentLoad / 100;
    this.cpuUsageCache = cpuLoad;
    this.lastCpuCheck = now;
    return cpuLoad;
  }

  public async acceptConnection() {
    // Always accept — max performance mode
    return true;
  }

  public clearCache() {
    this.cpuUsageCache = null;
    this.memoryUsageCache = null;
    this.lastCpuCheck = 0;
    this.lastMemoryCheck = 0;
  }
}

export default SystemMonitor.getInstance();
SYSMON
echo "  Done."

# ── 3. Types: increase search limit, extract URL limit, map limit, waitFor ─
echo "[3/8] Patching types.ts (search/extract/map/waitFor limits)..."
TYPES="$FIRECRAWL_DIR/apps/api/src/controllers/v2/types.ts"

# Search result limit: 100 -> 1000
sed -i 's/limit: z.int().positive().finite().max(100).optional().prefault(10)/limit: z.int().positive().finite().max(1000).optional().prefault(10)/' \
  "$TYPES"

# Extract URL limit: 10 -> 100
sed -i 's/\.max(10, "Maximum of 10 URLs allowed per request while in beta.")/.max(100, "Maximum of 100 URLs allowed per request.")/' \
  "$TYPES"

# Map limit: 100000 -> 1000000
sed -i 's/export const MAX_MAP_LIMIT = 100000/export const MAX_MAP_LIMIT = 1000000/' \
  "$TYPES"

# waitFor max: 60000 -> 300000
sed -i 's/waitFor: z.int().nonnegative().max(60000).prefault(0)/waitFor: z.int().nonnegative().max(300000).prefault(0)/' \
  "$TYPES"

# Search timeout default: 60000 -> 300000
sed -i 's/timeout: z.int().positive().finite().prefault(60000)/timeout: z.int().positive().finite().prefault(300000)/' \
  "$TYPES"
echo "  Done."

# ── 4. Research proxy: increase timeout ───────────────────────────────
echo "[4/8] Patching research-proxy.ts (timeout 120s -> 600s)..."
sed -i 's/const TIMEOUT_MS = 120_000/const TIMEOUT_MS = 600_000/' \
  "$FIRECRAWL_DIR/apps/api/src/controllers/v2/research-proxy.ts"
echo "  Done."

# ── 5. Copy research-service into Firecrawl apps dir ─────────────────
echo "[5/8] Copying research-service into Firecrawl apps directory..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/research-service" ]; then
  cp -r "$SCRIPT_DIR/research-service" "$FIRECRAWL_DIR/apps/research-service"
  echo "  Copied to $FIRECRAWL_DIR/apps/research-service"
else
  echo "  WARNING: research-service directory not found alongside this script."
  echo "  Make sure to copy it manually into $FIRECRAWL_DIR/apps/research-service"
fi
echo "  Done."

# ── 6. Patch docker-compose.yaml with max performance + new services ─
echo "[6/8] Patching docker-compose.yaml..."
COMPOSE="$FIRECRAWL_DIR/docker-compose.yaml"

# Performance env vars
sed -i 's/NUM_WORKERS_PER_QUEUE: ${NUM_WORKERS_PER_QUEUE:-8}/NUM_WORKERS_PER_QUEUE: ${NUM_WORKERS_PER_QUEUE:-32}/' "$COMPOSE"
sed -i 's/CRAWL_CONCURRENT_REQUESTS: ${CRAWL_CONCURRENT_REQUESTS:-10}/CRAWL_CONCURRENT_REQUESTS: ${CRAWL_CONCURRENT_REQUESTS:-50}/' "$COMPOSE"
sed -i 's/MAX_CONCURRENT_JOBS: ${MAX_CONCURRENT_JOBS:-5}/MAX_CONCURRENT_JOBS: ${MAX_CONCURRENT_JOBS:-50}/' "$COMPOSE"
sed -i 's/BROWSER_POOL_SIZE: ${BROWSER_POOL_SIZE:-5}/BROWSER_POOL_SIZE: ${BROWSER_POOL_SIZE:-20}/' "$COMPOSE"

# SearXNG env
sed -i 's|SEARXNG_ENDPOINT: ${SEARXNG_ENDPOINT}|SEARXNG_ENDPOINT: ${SEARXNG_ENDPOINT:-http://searxng:8080}|' "$COMPOSE"

# Add RESEARCH_PROXY_URL env if not present
if ! grep -q "RESEARCH_PROXY_URL" "$COMPOSE"; then
  sed -i '/SEARXNG_CATEGORIES: ${SEARXNG_CATEGORIES}/a\  RESEARCH_PROXY_URL: ${RESEARCH_PROXY_URL}' "$COMPOSE"
fi

# Playwright: increase concurrent pages + resources
sed -i 's/MAX_CONCURRENT_PAGES: ${CRAWL_CONCURRENT_REQUESTS:-10}/MAX_CONCURRENT_PAGES: ${CRAWL_CONCURRENT_REQUESTS:-50}/' "$COMPOSE"
sed -i 's/    cpus: 2.0/    # cpus: 2.0/' "$COMPOSE"
sed -i 's/    mem_limit: 4G/    mem_limit: 32G/' "$COMPOSE" | true
sed -i 's/    memswap_limit: 4G/    memswap_limit: 32G/' "$COMPOSE" | true
sed -i 's/      - \/tmp\/.cache:noexec,nosuid,size=1g/      - \/tmp\/.cache:noexec,nosuid,size=4g/' "$COMPOSE"

# API container: increase resources
sed -i 's/    cpus: 4.0/    # cpus: 4.0/' "$COMPOSE"
sed -i 's/    mem_limit: 8G/    mem_limit: 64G/' "$COMPOSE" | true
sed -i 's/    memswap_limit: 8G/    memswap_limit: 64G/' "$COMPOSE" | true

# Startup timeout
sed -i 's/HARNESS_STARTUP_TIMEOUT_MS: ${HARNESS_STARTUP_TIMEOUT_MS:-60000}/HARNESS_STARTUP_TIMEOUT_MS: ${HARNESS_STARTUP_TIMEOUT_MS:-120000}/' "$COMPOSE"

# Add SearXNG service, research-service, and searxng volume
# We check if they already exist to avoid duplicates
if ! grep -q "searxng:" "$COMPOSE"; then
  # Insert before "networks:" at the end
  sed -i '/^networks:/i\  searxng:\n    image: searxng/searxng:latest\n    environment:\n      - SEARXNG_BASE_URL=http://searxng:8080\n      - SEARXNG_SECRET=${SEARXNG_SECRET:-firecrawl-secret-key}\n    networks:\n      - backend\n    volumes:\n      - searxng-data:/etc/searxng\n    logging:\n      driver: "json-file"\n      options:\n        max-size: "5m"\n        max-file: "2"\n        compress: "true"\n\n  research-service:\n    build: apps/research-service\n    environment:\n      S2_API_KEY: ${S2_API_KEY}\n      GITHUB_TOKEN: ${GITHUB_TOKEN}\n    networks:\n      - backend\n    mem_limit: 16G\n    memswap_limit: 16G\n    logging:\n      driver: "json-file"\n      options:\n        max-size: "5m"\n        max-file: "2"\n        compress: "true"\n' "$COMPOSE"
  # Add searxng-data volume
  sed -i '/^  fdb-cluster-file:/a\  searxng-data:' "$COMPOSE"
fi
echo "  Done."

# ── 7. Patch MCP server (if installed via npx cache) ─────────────────
echo "[7/8] Patching MCP server limits (if installed)..."
MCP_JS=$(find /home -path "*/firecrawl-mcp/dist/index.js" -o -path "$HOME/.npm/_npx/*/node_modules/firecrawl-mcp/dist/index.js" 2>/dev/null | head -1 || true)
if [ -n "$MCP_JS" ]; then
  echo "  Found MCP server at: $MCP_JS"
  # search_papers k.max: 500 -> 10000
  sed -i 's/k: z2.number().int().min(1).max(500).optional().describe("Number of ranked papers to return (default 40).")/k: z2.number().int().min(1).max(10000).optional().describe("Number of ranked papers to return (default 40).")/' "$MCP_JS"
  # related_papers seed_ids.max: 10 -> 20
  sed -i 's/seed_ids: z2.array(z2.string()).min(1).max(10)/seed_ids: z2.array(z2.string()).min(1).max(20)/' "$MCP_JS"
  # related_papers k.max: 500 -> 10000
  sed -i 's/k: z2.number().int().min(1).max(500).optional(),\n      rerank/k: z2.number().int().min(1).max(10000).optional(),\n      rerank/' "$MCP_JS" || true
  # read_paper k.max: 50 -> 500
  sed -i 's/k: z2.number().int().min(1).max(50).optional().describe("Number of passages to return (default 4).")/k: z2.number().int().min(1).max(500).optional().describe("Number of passages to return (default 4).")/' "$MCP_JS"
  # search_github k.max: 100 -> 1000
  sed -i 's/k: z2.number().int().min(1).max(100).optional()/k: z2.number().int().min(1).max(1000).optional()/' "$MCP_JS" || true
  echo "  Patched MCP server limits."
else
  echo "  MCP server not found — run patch-mcp.sh after installing firecrawl-mcp."
fi
echo "  Done."

# ── 8. Patch Firecrawl JS SDK timeout ────────────────────────────────
echo "[8/8] Patching JS SDK HTTP timeout (if installed)..."
SDK_JS=$(find /home -path "*/@mendable/firecrawl-js/dist/index.js" -o -path "$HOME/.npm/_npx/*/node_modules/@mendable/firecrawl-js/dist/index.js" 2>/dev/null | head -1 || true)
if [ -n "$SDK_JS" ]; then
  echo "  Found JS SDK at: $SDK_JS"
  sed -i 's/timeout: options.timeoutMs ?? 3e5/timeout: options.timeoutMs ?? 6e5/' "$SDK_JS"
  echo "  Patched SDK timeout (300s -> 600s)."
else
  echo "  JS SDK not found — will be patched when firecrawl-mcp is installed."
fi
echo "  Done."

# ── 9. Dual-model: add getModelFast() and route fast tasks to it ──────
echo "[9/9] Patching dual-model support (gpt-oss-120b heavy + deepseek-v4-flash fast)..."

# 9a. Add MODEL_NAME_FAST to config.ts
sed -i '/MODEL_NAME: z.string().optional(),/a\  MODEL_NAME_FAST: z.string().optional(),' \
  "$FIRECRAWL_DIR/apps/api/src/config.ts"

# 9b. Add getModelFast() to generic-ai.ts
GENERIC_AI="$FIRECRAWL_DIR/apps/api/src/lib/generic-ai.ts"
# Add getModelFast after getModel
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
sed -i 's/import { getModel } from "..\/..\/..\/lib\/generic-ai";/import { getModel, getModelFast } from "..\/..\/..\/lib\/generic-ai";/' "$LLM_EXTRACT"
# generateSchemaFromPrompt: use fast model
sed -i '0,/const model = getModel("gpt-4o-mini", "openai");/s//const model = getModelFast("gpt-4o-mini", "openai");/' "$LLM_EXTRACT"
sed -i '0,/const retryModel = getModel("gpt-4.1-mini", "openai");/s//const retryModel = getModelFast("gpt-4.1-mini", "openai");/' "$LLM_EXTRACT"
# generateCrawlerOptionsFromPrompt: use fast model (second occurrence)
sed -i '0,/const model = getModel("gpt-4o-mini", "openai");/s//const model = getModelFast("gpt-4o-mini", "openai");/' "$LLM_EXTRACT"
sed -i '0,/const retryModel = getModel("gpt-4.1-mini", "openai");/s//const retryModel = getModelFast("gpt-4.1-mini", "openai");/' "$LLM_EXTRACT"
# performSummary: use fast model for model and retryModel
sed -i 's/return getModel(selection.modelName, "openai");/return getModelFast(selection.modelName, "openai");/g' "$LLM_EXTRACT"
sed -i 's/retryModel: getModel("gpt-4.1-mini", "openai"),/retryModel: getModelFast("gpt-4.1-mini", "openai"),/g' "$LLM_EXTRACT"

# 9d. Route diff.ts LLM diff to fast model
DIFF_TS="$FIRECRAWL_DIR/apps/api/src/scraper/scrapeURL/transformers/diff.ts"
sed -i 's/import { generateCompletions } from "\.\/llmExtract";/import { generateCompletions } from ".\/llmExtract";\nimport { getModelFast } from "..\/..\/..\/lib\/generic-ai";/' "$DIFF_TS"
sed -i 's/previousWarning: document.warning,/previousWarning: document.warning,\n              model: getModelFast("gpt-4o-mini", "openai"),/' "$DIFF_TS"

# 9e. Route Fire-0 extract fast tasks to getModelFast
F0_LLM="$FIRECRAWL_DIR/apps/api/src/lib/extract/fire-0/llmExtract-f0.ts"
sed -i 's/import { getModel } from "..\/..\/..\/lib\/generic-ai";/import { getModel, getModelFast } from "..\/..\/..\/lib\/generic-ai";/' "$F0_LLM"
# generateSchemaFromPrompt_F0
sed -i 's/const model = getModel("gpt-4o-mini");/const model = getModelFast("gpt-4o-mini");/' "$F0_LLM"

# checkShouldExtract_F0
F0_CHECK="$FIRECRAWL_DIR/apps/api/src/lib/extract/fire-0/completions/checkShouldExtract-f0.ts"
sed -i 's/import { getModel } from "..\/..\/..\/..\/lib\/generic-ai";/import { getModel, getModelFast } from "..\/..\/..\/..\/lib\/generic-ai";/' "$F0_CHECK"
sed -i 's/model: getModel("gpt-4o-mini"),/model: getModelFast("gpt-4o-mini"),/' "$F0_CHECK"

# url-processor-f0
F0_URL="$FIRECRAWL_DIR/apps/api/src/lib/extract/fire-0/url-processor-f0.ts"
sed -i 's/import { getModel } from "..\/generic-ai";/import { getModel, getModelFast } from "..\/generic-ai";/' "$F0_URL"
sed -i 's/model: getModel("gpt-4o-mini"),/model: getModelFast("gpt-4o-mini"),/' "$F0_URL"

# reranker-f0
F0_RERANK="$FIRECRAWL_DIR/apps/api/src/lib/extract/fire-0/reranker-f0.ts"
sed -i 's/import { generateCompletions } from "..\/..\/..\/scraper\/scrapeURL\/transformers\/llmExtract";/import { generateCompletions } from "..\/..\/..\/scraper\/scrapeURL\/transformers\/llmExtract";\nimport { getModelFast } from "..\/..\/..\/lib\/generic-ai";/' "$F0_RERANK"
sed -i 's/isExtractEndpoint: true,/isExtractEndpoint: true,\n            model: getModelFast("gpt-4o-mini", "openai"),/' "$F0_RERANK"

# 9f. Route deep research queries/planning to fast model
RESEARCH_MGR="$FIRECRAWL_DIR/apps/api/src/lib/deep-research/research-manager.ts"
sed -i 's/import { getModel } from "..\/generic-ai";/import { getModel, getModelFast } from "..\/generic-ai";/' "$RESEARCH_MGR"
# Add model: getModelFast() to generateSearchQueries and analyzeAndPlan
sed -i '0,/markdown: "",$/s//markdown: "",\n      model: getModelFast("gpt-4o-mini", "openai"),/' "$RESEARCH_MGR"
sed -i '0,/markdown: "",$/s//markdown: "",\n        model: getModelFast("gpt-4o-mini", "openai"),/' "$RESEARCH_MGR"

# 9g. Route llms.txt generation to fast model
LLMSTXT="$FIRECRAWL_DIR/apps/api/src/lib/generate-llmstxt/generate-llmstxt-service.ts"
sed -i 's/import { getModel } from "..\/generic-ai";/import { getModel, getModelFast } from "..\/generic-ai";/' "$LLMSTXT"
sed -i 's/model: getModel("gpt-4o-mini", "openai"),/model: getModelFast("gpt-4o-mini", "openai"),/' "$LLMSTXT"

# 9h. Route engpicker to fast model
ENGPICKER="$FIRECRAWL_DIR/apps/api/src/lib/engpicker.ts"
sed -i 's/import { getModel } from ".\/generic-ai";/import { getModel, getModelFast } from ".\/generic-ai";/' "$ENGPICKER"
sed -i 's/model: getModel("gpt-4o-mini", "openai"),/model: getModelFast("gpt-4o-mini", "openai"),/' "$ENGPICKER"

# 9i. Route deterministic JSON to fast model via openai provider
DJ_CLIENT="$FIRECRAWL_DIR/apps/api/src/lib/deterministicJson/llm/client.ts"
sed -i 's/import { getModel } from "..\/generic-ai";/import { getModel, getModelFast } from "..\/generic-ai";/' "$DJ_CLIENT"
sed -i 's/model: getModel(CODEGEN_MODEL, "vertex"),/model: getModelFast(CODEGEN_MODEL, "openai"),/' "$DJ_CLIENT"
sed -i 's/model: getModel(ANCHOR_MODEL, "groq"),/model: getModelFast(ANCHOR_MODEL, "openai"),/' "$DJ_CLIENT"
sed -i 's/model: getModel(LIGHT_MODEL, "groq"),/model: getModelFast(LIGHT_MODEL, "openai"),/' "$DJ_CLIENT"

# 9j. Add MODEL_NAME_FAST to docker-compose.yaml
COMPOSE="$FIRECRAWL_DIR/docker-compose.yaml"
if ! grep -q "MODEL_NAME_FAST" "$COMPOSE"; then
  sed -i '/MODEL_NAME: ${MODEL_NAME}/a\  MODEL_NAME_FAST: ${MODEL_NAME_FAST}' "$COMPOSE"
fi

echo "  Done."

# ── 10. Agent: replace external proxy with local in-memory agent ──────
echo "[10/10] Patching agent controllers (local in-memory agent)..."

# Replace agent.ts with local implementation
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

# Replace agent-status.ts
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

# Replace agent-cancel.ts
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
