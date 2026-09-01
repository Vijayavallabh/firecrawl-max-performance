#!/usr/bin/env bash
# ======================================================================
# patch-firecrawl.sh — Applies performance, compatibility, and persistence patches
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

require_file() {
  if [ ! -f "$1" ]; then
    echo "Error: expected Firecrawl file is missing: $1"
    exit 1
  fi
}

echo "Patching Firecrawl at: $FIRECRAWL_DIR"
echo "========================================"

require_file "$FIRECRAWL_DIR/apps/api/src/config.ts"
require_file "$FIRECRAWL_DIR/apps/api/src/db/connection.ts"
require_file "$FIRECRAWL_DIR/apps/api/src/controllers/v2/types.ts"

# ── 1. Rate limiter: remove all rate limits ──────────────────────────
echo "[1/10] Patching rate-limiter.ts (preserve auth semantics)..."
cat > "$FIRECRAWL_DIR/apps/api/src/services/rate-limiter.ts" << 'RATELIMITER'
import { RateLimiterRedis } from "rate-limiter-flexible";
import { config } from "../config";
import { RateLimiterMode } from "../types";
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
  crawl: 15,
  scrape: 100,
  search: 100,
  map: 100,
  extract: 100,
  preview: 25,
  extractStatus: 25000,
  crawlStatus: 25000,
  extractAgentPreview: 10,
  scrapeAgentPreview: 10,
  browser: 2,
  browserExecute: 1000,
  browserReplay: 500,
  account: 1000,
  supportAsk: 3,
  supportDocsSearch: 3,
  research: 100,
  developerSearch: 100,
  labs: 1000,
};

const BASE_RATE_LIMITS: Partial<Record<RateLimiterMode, number>> = {
  [RateLimiterMode.Scrape]: 10,
  [RateLimiterMode.Map]: 10,
  [RateLimiterMode.Crawl]: 2,
  [RateLimiterMode.Search]: 10,
  [RateLimiterMode.Extract]: 2,
  [RateLimiterMode.Browser]: 2,
  [RateLimiterMode.BrowserExecute]: 10,
  [RateLimiterMode.CrawlStatus]: 500,
  [RateLimiterMode.ExtractStatus]: 500,
};

export function getRateLimiter(mode: RateLimiterMode): RateLimiterRedis {
  const rateLimit = fallbackRateLimits?.[mode] ?? 500;
  return createRateLimiter(`${mode}`, rateLimit);
}

export function getAutumnRateLimiter(
  mode: RateLimiterMode,
  multiplier: number = 1,
): RateLimiterRedis {
  const base = BASE_RATE_LIMITS[mode];
  let rateLimit: number;
  if (base !== undefined) {
    const safeMultiplier = multiplier > 0 ? multiplier : 1;
    rateLimit = base * safeMultiplier;
  } else {
    rateLimit = fallbackRateLimits?.[mode] ?? 500;
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
if ! grep -q "^  DB_POOL_MAX:" "$FIRECRAWL_DIR/apps/api/src/config.ts"; then
  sed -i '/^  DATABASE_URL: z.string().optional(),$/a\  DB_POOL_MAX: z.coerce.number().int().positive().default(8),' \
    "$FIRECRAWL_DIR/apps/api/src/config.ts"
fi
python3 - "$FIRECRAWL_DIR/apps/api/src/config.ts" << 'PYCONFIG'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
lines = [line for line in lines if "DB_POOL_MAX:" not in line]
for index, line in enumerate(lines):
    if line.strip() == "DATABASE_URL: z.string().optional(),":
        lines.insert(index + 1, "  DB_POOL_MAX: z.coerce.number().int().positive().default(8),")
        break
else:
    raise SystemExit("DATABASE_URL config entry not found")
open(p, "w").write("\n".join(lines) + "\n")
PYCONFIG
if ! grep -q "SELF_HOSTED_CONCURRENCY_LIMIT" "$FIRECRAWL_DIR/apps/api/src/config.ts"; then
  sed -i '/MAX_CONCURRENT_JOBS: z.coerce.number()/a\  SELF_HOSTED_CONCURRENCY_LIMIT: z.coerce.number().int().positive().default(50),' \
    "$FIRECRAWL_DIR/apps/api/src/config.ts" 2>/dev/null || true
  if ! grep -q "SELF_HOSTED_CONCURRENCY_LIMIT" "$FIRECRAWL_DIR/apps/api/src/config.ts"; then
    sed -i '/NUQ_WORKER_COUNT: z.coerce.number()/i\  SELF_HOSTED_CONCURRENCY_LIMIT: z.coerce.number().int().positive().default(50),' \
      "$FIRECRAWL_DIR/apps/api/src/config.ts"
  fi
fi
echo "  Done."

# ── 2b. System monitor: retain host-level CPU/RAM backpressure ───────
echo "[2b/10] Patching system-monitor.ts (retain host CPU/RAM gate)..."
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

  public async acceptConnection() {
    const [cpuUsage, memoryUsage] = await Promise.all([
      this.checkCpuUsage(),
      this.checkMemoryUsage(),
    ]);
    return cpuUsage < MAX_CPU && memoryUsage < MAX_RAM;
  }

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
python3 - "$TYPES" << 'PYMAPLIMIT'
import re
import sys
p = sys.argv[1]
s = open(p).read()
s, count = re.subn(r"export const MAX_MAP_LIMIT = \d+;", "export const MAX_MAP_LIMIT = 1000000;", s, count=1)
if count != 1:
    raise SystemExit("MAX_MAP_LIMIT declaration not found")
open(p, "w").write(s)
PYMAPLIMIT
sed -i 's/waitFor: z.int().nonnegative().max(60000).prefault(0)/waitFor: z.int().nonnegative().max(300000).prefault(0)/' "$TYPES"
sed -i 's/timeout: z.int().positive().finite().prefault(60000)/timeout: z.int().positive().finite().prefault(300000)/' "$TYPES"
TYPES_TEST="$FIRECRAWL_DIR/apps/api/src/__tests__/snips/v2/types-validation.test.ts"
if [ -f "$TYPES_TEST" ]; then
  python3 - "$TYPES_TEST" << 'PYTYPESTEST'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('should reject more than 10 URLs', 'should reject more than 100 URLs')
s = s.replace('Array.from({ length: 11 }, (_, i) => `https://example${i}.com`)', 'Array.from({ length: 101 }, (_, i) => `https://example${i}.com`)')
s = s.replace('Maximum of 10 URLs allowed per request while in beta', 'Maximum of 100 URLs allowed per request')
s = s.replace('should accept up to 10 URLs', 'should accept up to 100 URLs')
s = s.replace('Array.from({ length: 10 }, (_, i) => `https://example${i}.com`)', 'Array.from({ length: 100 }, (_, i) => `https://example${i}.com`)')
s = s.replace('toHaveLength(10)', 'toHaveLength(100)')
s = s.replace('limit: 200000,', 'limit: 1000001,')
s = re.sub(r'should reject limit exceeding \d+', 'should reject limit exceeding 1000000', s)
s = s.replace('limit: 150,', 'limit: 1000001,')
open(p, "w").write(s)
PYTYPESTEST
fi
echo "  Done."

# ── 4. Research proxy: increase timeout ───────────────────────────────
echo "[4/11] Patching research-upstream.ts (timeout 120s -> 600s)..."
sed -i 's/const TIMEOUT_MS = 120_000/const TIMEOUT_MS = 600_000/' \
  "$FIRECRAWL_DIR/apps/api/src/lib/research-upstream.ts"
RESEARCH_PROXY="$FIRECRAWL_DIR/apps/api/src/controllers/v2/research-proxy.ts"
python3 - "$RESEARCH_PROXY" << 'PYRESEARCHPROXY'
import re, sys
p = sys.argv[1]
s = open(p).read()
for name, limit in (
    ("searchPapersSchema", 10000),
    ("paperSchema", 500),
    ("similarPapersSchema", 500),
    ("githubSearchSchema", 1000),
    ("developerSearchSchema", 1000),
):
    pattern = rf"(const {name}\s*=.*?\bk:\s*kSchema\()\d+"
    s, count = re.subn(pattern, rf"\g<1>{limit}", s, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"{name} limit entry not found")
open(p, "w").write(s)
PYRESEARCHPROXY
echo "  Done."

# ── 4b. Map: remove unsafe direct-fetch fallback ─────────────────────
echo "[4b/11] Patching map-utils.ts (retain SSRF-safe map fetches)..."
MAP_UTILS="$FIRECRAWL_DIR/apps/api/src/lib/map-utils.ts"
python3 - "$MAP_UTILS" << 'PYMAPFALLBACK'
import re
import sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"\n\s*// firecrawl-map-direct-fallback-v1:.*?\n\s*mapResults = mapResults", "\n\n  mapResults = mapResults", s, count=1, flags=re.S)
if 'import { config } from "../config";' in s and 'config.' not in s:
    s = s.replace('import { config } from "../config";\n', '')
open(p, "w").write(s)
PYMAPFALLBACK
echo "  Done."

# ── 5. Copy research-service into Firecrawl apps dir ─────────────────
echo "[5/10] Copying research-service into Firecrawl apps directory..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/research-service" ]; then
  mkdir -p "$FIRECRAWL_DIR/apps/research-service"
  mkdir -p "$FIRECRAWL_DIR/config"
  for file in Dockerfile requirements.txt main.py test_main.py; do
    require_file "$SCRIPT_DIR/research-service/$file"
    cp -f "$SCRIPT_DIR/research-service/$file" "$FIRECRAWL_DIR/apps/research-service/$file"
  done
  require_file "$SCRIPT_DIR/config/empty-cookies.txt"
  cp -f "$SCRIPT_DIR/config/empty-cookies.txt" "$FIRECRAWL_DIR/config/empty-cookies.txt"
  echo "  Copied to $FIRECRAWL_DIR/apps/research-service"
else
  echo "  WARNING: research-service directory not found alongside this script."
fi
cp -f "$SCRIPT_DIR/db-init.js" "$FIRECRAWL_DIR/db-init.js"
if [ -f "$SCRIPT_DIR/browser-session-adapter.ts" ]; then
  require_file "$FIRECRAWL_DIR/apps/playwright-service-ts/api.ts"
  cp -f "$SCRIPT_DIR/browser-session-adapter.ts" \
    "$FIRECRAWL_DIR/apps/playwright-service-ts/browser-session-adapter.ts"
  if ! grep -q "installBrowserSessionRoutes" "$FIRECRAWL_DIR/apps/playwright-service-ts/api.ts"; then
    sed -i '1a import { installBrowserSessionRoutes } from "./browser-session-adapter";' \
      "$FIRECRAWL_DIR/apps/playwright-service-ts/api.ts"
    sed -i '/^const start = async () => {/i\
installBrowserSessionRoutes(app, {\
  getBrowser: () => browser,\
  createContext: async () => ({ context: (await createContext()).context }),\
  acquire: () => pageSemaphore.acquire(),\
  release: () => pageSemaphore.release(),\
  publicBaseUrl: process.env.BROWSER_SERVICE_PUBLIC_URL,\
});\
' "$FIRECRAWL_DIR/apps/playwright-service-ts/api.ts"
  fi
  echo "  Added local browser-session adapter to Playwright."
fi
echo "  Done."

# ── 6. Patch docker-compose.yaml with max performance + new services ─
echo "[6/10] Patching docker-compose.yaml..."
COMPOSE="$FIRECRAWL_DIR/docker-compose.yaml"
python3 - "$COMPOSE" << 'PYCOMPOSEBASE'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("POSTGRES_PASSWORD: \"${POSTGRES_PASSWORD:-postgres}\"", "POSTGRES_PASSWORD: \"${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}\"")
s = s.replace("POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-postgres}", "POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}")
s = s.replace("BULL_AUTH_KEY: ${BULL_AUTH_KEY}", "BULL_AUTH_KEY: ${BULL_AUTH_KEY:?Set BULL_AUTH_KEY in .env}")
s = s.replace("BROWSER_SERVICE_API_KEY: ${BROWSER_SERVICE_API_KEY:-}", "BROWSER_SERVICE_API_KEY: ${BROWSER_SERVICE_API_KEY:?Set BROWSER_SERVICE_API_KEY in .env}")
s = s.replace("SEARXNG_SECRET=${SEARXNG_SECRET:-firecrawl-secret-key}", "SEARXNG_SECRET=${SEARXNG_SECRET:?Set SEARXNG_SECRET in .env}")
s = s.replace("./searxng-settings.yml", "./searxng/settings.yml")
s = s.replace("image: searxng/searxng:latest", "image: searxng/searxng@sha256:11a9b34cdc0b1ec2b991470a2762ecb5a1a531898289fb51dcd015260450729e")
s = s.replace('      - "${PORT:-3002}:${INTERNAL_PORT:-3002}"', '      - "${HOST_BIND_ADDRESS:-127.0.0.1}:${PORT:-3002}:${INTERNAL_PORT:-3002}"')
if not any(line.startswith("  DATABASE_URL:") for line in s.splitlines()):
    s = s.replace("  POSTGRES_PORT: ${POSTGRES_PORT:-5432}\n", "  POSTGRES_PORT: ${POSTGRES_PORT:-5432}\n  DATABASE_URL: ${DATABASE_URL:-}\n")
open(p, "w").write(s)
PYCOMPOSEBASE

# Performance env vars (use sed only if the old default is found)
sed -i 's/NUM_WORKERS_PER_QUEUE: ${NUM_WORKERS_PER_QUEUE:-8}/NUM_WORKERS_PER_QUEUE: ${NUM_WORKERS_PER_QUEUE:-32}/' "$COMPOSE" || true
if ! grep -q "NUQ_WORKER_COUNT" "$COMPOSE"; then
  sed -i 's/NUM_WORKERS_PER_QUEUE: ${NUM_WORKERS_PER_QUEUE:-32}/NUM_WORKERS_PER_QUEUE: ${NUM_WORKERS_PER_QUEUE:-32}\n  NUQ_WORKER_COUNT: ${NUQ_WORKER_COUNT:-32}/' "$COMPOSE"
fi
sed -i 's/CRAWL_CONCURRENT_REQUESTS: ${CRAWL_CONCURRENT_REQUESTS:-10}/CRAWL_CONCURRENT_REQUESTS: ${CRAWL_CONCURRENT_REQUESTS:-50}/' "$COMPOSE" || true
sed -i 's/MAX_CONCURRENT_JOBS: ${MAX_CONCURRENT_JOBS:-5}/MAX_CONCURRENT_JOBS: ${MAX_CONCURRENT_JOBS:-50}/' "$COMPOSE" || true
if ! grep -q "SELF_HOSTED_CONCURRENCY_LIMIT" "$COMPOSE"; then
  sed -i '/MAX_CONCURRENT_JOBS:/a\  SELF_HOSTED_CONCURRENCY_LIMIT: ${SELF_HOSTED_CONCURRENCY_LIMIT:-50}' "$COMPOSE"
fi
if ! grep -q "DB_POOL_MAX" "$COMPOSE"; then
  sed -i '/POSTGRES_PORT:/a\  DB_POOL_MAX: ${DB_POOL_MAX:-8}' "$COMPOSE"
fi
sed -i 's/BROWSER_POOL_SIZE: ${BROWSER_POOL_SIZE:-5}/BROWSER_POOL_SIZE: ${BROWSER_POOL_SIZE:-20}/' "$COMPOSE" || true

# SearXNG env default
sed -i 's|SEARXNG_ENDPOINT: ${SEARXNG_ENDPOINT}|SEARXNG_ENDPOINT: ${SEARXNG_ENDPOINT:-http://searxng:8080}|' "$COMPOSE" || true

# Add RESEARCH_PROXY_URL env if not present (default to in-stack service)
if ! grep -q "RESEARCH_PROXY_URL" "$COMPOSE"; then
  sed -i '/SEARXNG_CATEGORIES: ${SEARXNG_CATEGORIES}/a\  RESEARCH_PROXY_URL: ${RESEARCH_PROXY_URL:-http://research-service:8000}' "$COMPOSE"
fi
if ! grep -q "BROWSER_SERVICE_URL" "$COMPOSE"; then
  sed -i '/RESEARCH_PROXY_URL:/a\  BROWSER_SERVICE_URL: ${BROWSER_SERVICE_URL:-http://playwright-service:3000}\n  BROWSER_SERVICE_API_KEY: ${BROWSER_SERVICE_API_KEY:-}' "$COMPOSE"
fi
sed -i 's/FDB_CLUSTER_FILE: ${NUQ_BACKEND:+\/var\/fdb\/fdb.cluster}/FDB_CLUSTER_FILE: ${FDB_CLUSTER_FILE:-}/' "$COMPOSE" || true

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

# Add SearXNG + research-service services and searxng volume if not present
if ! grep -q "  searxng:" "$COMPOSE"; then
    sed -i '/^networks:/i\  searxng:\n    image: searxng/searxng@sha256:11a9b34cdc0b1ec2b991470a2762ecb5a1a531898289fb51dcd015260450729e\n    environment:\n      - SEARXNG_BASE_URL=http://searxng:8080\n      - SEARXNG_SECRET=${SEARXNG_SECRET}\n    networks:\n      - backend\n    volumes:\n      - ./searxng/settings.yml:/etc/searxng/settings.yml:ro\n    logging:\n      driver: "json-file"\n      options:\n        max-size: "5m"\n        max-file: "2"\n        compress: "true"\n\n  research-service:\n    build: apps/research-service\n    environment:\n      S2_API_KEY: ${S2_API_KEY}\n      GITHUB_TOKEN: ${GITHUB_TOKEN}\n      MAILTO: ${MAILTO:-research@firecrawl.local}\n      INSTITUTIONAL_ACCESS_ENABLED: ${INSTITUTIONAL_ACCESS_ENABLED:-false}\n      INSTITUTIONAL_COOKIE_FILE: /run/secrets/institutional_cookies\n      INSTITUTIONAL_ALLOWED_DOMAINS: ${INSTITUTIONAL_ALLOWED_DOMAINS:-}\n      INSTITUTIONAL_MAX_DOWNLOAD_BYTES: ${INSTITUTIONAL_MAX_DOWNLOAD_BYTES:-52428800}\n      INSTITUTIONAL_MAX_PDF_PAGES: ${INSTITUTIONAL_MAX_PDF_PAGES:-100}\n    networks:\n      - backend\n    mem_limit: 16G\n    memswap_limit: 16G\n    volumes:\n      - ${INSTITUTIONAL_COOKIE_FILE:-./config/empty-cookies.txt}:/run/secrets/institutional_cookies:ro\n    logging:\n      driver: "json-file"\n      options:\n        max-size: "5m"\n        max-file: "2"\n        compress: "true"\n' "$COMPOSE"
  sed -i '/^  fdb-cluster-file:/a\  searxng-data:' "$COMPOSE"
fi

# Give the bundled PostgreSQL durable storage and a readiness signal, then run
# the idempotent application-schema bootstrap before the API starts. This is
# what makes monitor, feedback, interact, request logging, and durable agent
# jobs genuinely available with USE_DB_AUTHENTICATION=false.
python3 - "$COMPOSE" << 'PYLOCALDBSERVICE'
import re
import sys

p = sys.argv[1]
s = open(p).read()
service_pattern = re.compile(
    r"(?ms)(^  nuq-postgres:\n.*?)(?=^  [a-zA-Z0-9_-]+:\n|^networks:\n)",
)
match = service_pattern.search(s)
if not match:
    raise SystemExit("nuq-postgres service not found")
block = match.group(1)
if "      - pg-data:/var/lib/postgresql/data" not in block:
    marker = "    networks:\n      - backend\n"
    if marker not in block:
        raise SystemExit("nuq-postgres network anchor not found")
    block = block.replace(
        marker,
        marker + "    volumes:\n      - pg-data:/var/lib/postgresql/data\n",
        1,
    )
if "pg_isready" not in block:
    marker = "    logging:\n"
    health = '''    healthcheck:
      test: ["CMD-SHELL", 'pg_isready -U "$${POSTGRES_USER}" -d "$${POSTGRES_DB}"']
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 10s
'''
    if marker not in block:
        raise SystemExit("nuq-postgres logging anchor not found")
    block = block.replace(marker, health + marker, 1)
s = s[:match.start(1)] + block + s[match.end(1):]

if "\n  db-init:\n" not in s:
    db_init = '''
  db-init:
    restart: "no"
    <<: *common-service
    environment:
      <<: *common-env
      ENV: local
    depends_on:
      nuq-postgres:
        condition: service_healthy
    volumes:
      - ./db-init.js:/tmp/db-init.js:ro
    command: ["node", "/tmp/db-init.js"]

'''
    if "\nnetworks:\n" not in s:
        raise SystemExit("compose networks anchor not found")
    s = s.replace("\nnetworks:\n", db_init + "networks:\n", 1)

if not re.search(r"(?m)^  pg-data:\s*$", s):
    s = s.replace("\nvolumes:\n", "\nvolumes:\n  pg-data:\n", 1)

api = re.search(r"(?ms)(^  api:\n.*?)(?=^  [a-zA-Z0-9_-]+:\n|^networks:\n)", s)
if not api:
    raise SystemExit("api service not found")
api_block = api.group(1)
if "      db-init:\n        condition: service_completed_successfully" not in api_block:
    anchor = "    depends_on:\n"
    if anchor not in api_block:
        raise SystemExit("api depends_on anchor not found")
    api_block = api_block.replace(
        anchor,
        anchor + "      db-init:\n        condition: service_completed_successfully\n",
        1,
    )
    s = s[:api.start(1)] + api_block + s[api.end(1):]

open(p, "w").write(s)
PYLOCALDBSERVICE

# Copy SearXNG settings into the path used by the patched Compose file.
if [ -f "$SCRIPT_DIR/searxng/settings.yml" ]; then
  mkdir -p "$FIRECRAWL_DIR/searxng"
  cp -f "$SCRIPT_DIR/searxng/settings.yml" "$FIRECRAWL_DIR/searxng/settings.yml"
fi

# Restart policy: keep all long-running services up across reboots
# (foundationdb-init and db-init stay one-shot). Rewrite each complete service
# block so rerunning the patcher cannot accumulate duplicate YAML keys.
python3 - "$COMPOSE" << 'PYRESTARTPOLICY'
import re
import sys

p = sys.argv[1]
s = open(p).read()
services = {
    "playwright-service", "api", "redis", "rabbitmq", "nuq-postgres",
    "foundationdb", "searxng", "research-service",
}
pattern = re.compile(r"(?ms)^  ([a-zA-Z0-9_-]+):\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|^networks:\n|^volumes:\n|\Z)")

def normalize(match):
    name, body = match.group(1), match.group(2)
    if name not in services:
        return match.group(0)
    body = re.sub(r"(?m)^    restart:.*\n", "", body)
    return f"  {name}:\n    restart: unless-stopped\n{body}"

s = pattern.sub(normalize, s)
open(p, "w").write(s)
PYRESTARTPOLICY
python3 - "$COMPOSE" << 'PYFDBCOMPOSE'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("database.*already exists", "database already exists")
open(p, "w").write(s)
PYFDBCOMPOSE
echo "  Done."

# ── 7. Patch every MCP server installed via npx cache ─────────────────
echo "[7/10] Patching MCP server limits and reliability..."
MCP_BUNDLE_FOUND=""
for cache_root in "${HOME:-/home}/.npm" "${HOME:-/home}/.cache" "${HOME:-/home}/.local" /usr/local/lib/node_modules; do
  if [ -d "$cache_root" ] && find "$cache_root" -path "*/firecrawl-mcp/dist/index.js" -print -quit 2>/dev/null | grep -q .; then
    MCP_BUNDLE_FOUND=1
    break
  fi
done
if [ -n "$MCP_BUNDLE_FOUND" ]; then
  # A transformer failure is a real error and must stop the parent patcher.
  bash "$SCRIPT_DIR/patch-mcp.sh"
  echo "  Patched every cached MCP bundle."
else
  echo "  MCP server not found — run patch-mcp.sh after installing firecrawl-mcp."
fi
echo "  Done."

# ── 8. Patch Firecrawl JS SDK timeout ────────────────────────────────
echo "[8/10] Patching JS SDK HTTP timeout (if installed)..."
SDK_JS=""
for cache_root in "${HOME:-/home}/.npm" "${HOME:-/home}/.cache" "${HOME:-/home}/.local" /usr/local/lib/node_modules; do
  if [ -d "$cache_root" ]; then
    SDK_JS=$(find "$cache_root" -path "*/@mendable/firecrawl-js/dist/index.js" -print -quit 2>/dev/null || true)
  fi
  [ -n "$SDK_JS" ] && break
done
if [ -n "$SDK_JS" ]; then
  echo "  Found JS SDK at: $SDK_JS"
  node "$SCRIPT_DIR/patch-mcp.js" --sdk "$SDK_JS"
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
  const effectiveProvider =\
    config.OLLAMA_BASE_URL && provider === "openai" ? "ollama" : provider;\
  if (fastModel) {\
    return providerList[effectiveProvider](fastModel);\
  }\
  return getModel(name, effectiveProvider);\
}\
' "$GENERIC_AI"
fi
python3 - "$GENERIC_AI" << 'PYGENERICAI'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "  const fastModel = config.MODEL_NAME_FAST;\n  if (fastModel) {\n    return providerList[provider](fastModel);\n  }\n  return getModel(name, provider);",
    "  const fastModel = config.MODEL_NAME_FAST;\n  const effectiveProvider =\n    config.OLLAMA_BASE_URL && provider === \"openai\" ? \"ollama\" : provider;\n  if (fastModel) {\n    return providerList[effectiveProvider](fastModel);\n  }\n  return getModel(name, effectiveProvider);",
)
open(p, "w").write(s)
PYGENERICAI
if ! grep -q "getConfiguredProvider" "$GENERIC_AI"; then
  sed -i '/^export function getEmbeddingModel/i\
export function getConfiguredProvider(): Provider {\
  return config.OLLAMA_BASE_URL ? "ollama" : "openai";\
}\
\
export function getConfiguredModelName(fallback: string): string {\
  return config.MODEL_NAME_FAST || config.MODEL_NAME || fallback;\
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
sed -i 's/import { getModel, getModelFast } from "..\/..\/generic-ai";/import { getModel, getModelFast, getConfiguredProvider, getConfiguredModelName } from "..\/..\/generic-ai";/' "$DJ_CLIENT"
sed -i 's/record(costTracking, "codegen", "vertex", CODEGEN_MODEL,/record(costTracking, "codegen", getConfiguredProvider(), getConfiguredModelName(CODEGEN_MODEL),/' "$DJ_CLIENT"
sed -i 's/record(costTracking, "anchor", "groq", ANCHOR_MODEL,/record(costTracking, "anchor", getConfiguredProvider(), getConfiguredModelName(ANCHOR_MODEL),/' "$DJ_CLIENT"
sed -i 's/record(costTracking, "askLlm", "groq", LIGHT_MODEL,/record(costTracking, "askLlm", getConfiguredProvider(), getConfiguredModelName(LIGHT_MODEL),/' "$DJ_CLIENT"

# 9j. Add MODEL_NAME_FAST to docker-compose.yaml
if ! grep -q "MODEL_NAME_FAST" "$COMPOSE"; then
  sed -i '/MODEL_NAME: ${MODEL_NAME}/a\  MODEL_NAME_FAST: ${MODEL_NAME_FAST}' "$COMPOSE"
fi
if ! grep -q "EXTRACT_ANCHOR_MODEL:" "$COMPOSE"; then
  sed -i '/MODEL_NAME_FAST: ${MODEL_NAME_FAST}/a\  EXTRACT_ANCHOR_MODEL: ${EXTRACT_ANCHOR_MODEL:-accounts/fireworks/models/deepseek-v4-flash-0731}\n  EXTRACT_LIGHT_MODEL: ${EXTRACT_LIGHT_MODEL:-accounts/fireworks/models/deepseek-v4-flash-0731}' "$COMPOSE"
fi

# Keep the fast path provider-neutral so an Ollama deployment does not silently
# call the OpenAI-compatible remote endpoint. The helper still accepts an
# explicit provider for upstream call sites that genuinely need one.
for fast_file in "$LLM_EXTRACT" "$DIFF_TS" "$F0_LLM" "$F0_CHECK" "$F0_URL" "$F0_RERANK" "$RESEARCH_MGR" "$LLMSTXT" "$ENGPICKER" "$DJ_CLIENT"; do
  if [ -f "$fast_file" ]; then
    sed -i 's/getModelFast(\([^,)]*\), "openai")/getModelFast(\1)/g' "$fast_file"
  fi
done

BROWSER_AGENT="$FIRECRAWL_DIR/apps/api/src/lib/scrape-interact/browser-agent.ts"
if [ -f "$BROWSER_AGENT" ]; then
  sed -i 's/import { getModel } from "..\/generic-ai";/import { getModelFast } from "..\/generic-ai";/' "$BROWSER_AGENT"
  sed -i 's/getModel("gemini-3.5-flash", "google")/getModelFast("gemini-3.5-flash")/' "$BROWSER_AGENT"
fi
echo "  Done."

# ── 9.5. Patch self-hosted local persistence and model routing ─────────
echo "[9.5/10] Patching self-hosted local runtime features..."
node "$SCRIPT_DIR/patch-local-runtime.js" "$FIRECRAWL_DIR"
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
import { getModelFast } from "../../lib/generic-ai";
import { sql } from "drizzle-orm";
import { db } from "../../db/connection";
import { generateObject, generateText, jsonSchema } from "ai";

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
  creditsUsed: number;
}>();

const AGENT_MAX_URLS = 10;
const AGENT_MAX_CONTENT_CHARS = 400_000;

function updateAgentJob(job: any, patch: Record<string, unknown>) {
  Object.assign(job, patch);
  void persistAgentJob(job);
}

async function persistAgentJob(job: any): Promise<void> {
  if (!job || !config.DATABASE_URL) return;
  try {
    await db.execute(sql`
      INSERT INTO agent_jobs
        (id, team_id, status, prompt, urls, request_schema, data, error, model, credits_used, created_at, updated_at)
      VALUES
        (${job.id}, ${job.team_id}, ${job.status}, ${job.prompt},
         ${job.urls ? JSON.stringify(job.urls) : null}::jsonb,
         ${job.schema ? JSON.stringify(job.schema) : null}::jsonb,
         ${job.data ? JSON.stringify(job.data) : null}::jsonb,
         ${job.error ?? null}, ${job.model}, ${job.creditsUsed ?? 0},
         to_timestamp(${job.created_at} / 1000.0), now())
      ON CONFLICT (id) DO UPDATE SET
        status = excluded.status,
        data = excluded.data,
        error = excluded.error,
        credits_used = excluded.credits_used,
        updated_at = now()
    `);
  } catch (error) {
    _logger.warn("Failed to persist agent job", { error, agentId: job.id });
  }
}

export async function loadAgentJob(id: string, teamId: string): Promise<any | null> {
  if (!config.DATABASE_URL) return null;
  try {
    const result: any = await db.execute(sql`
      SELECT id, team_id, status, prompt, urls, request_schema, data, error,
             model, credits_used, extract(epoch from created_at) * 1000 AS created_at
      FROM agent_jobs
      WHERE id = ${id} AND team_id = ${teamId}
      LIMIT 1
    `);
    const row = result.rows?.[0];
    if (!row) return null;
    const interrupted = row.status === "processing";
    if (interrupted) {
      await db.execute(sql`
        UPDATE agent_jobs
        SET status = 'failed', error = 'Agent interrupted by API restart', updated_at = now()
        WHERE id = ${id}
      `);
    }
    return {
      id: row.id,
      team_id: row.team_id,
      status: interrupted ? "failed" : row.status,
      prompt: row.prompt ?? "",
      urls: row.urls ?? undefined,
      schema: row.request_schema ?? undefined,
      data: row.data ?? undefined,
      error: interrupted ? "Agent interrupted by API restart" : row.error ?? undefined,
      created_at: Number(row.created_at),
      model: row.model,
      cancelled: row.status === "failed" && row.error === "Agent cancelled by user",
      creditsUsed: Number(row.credits_used ?? 0),
    };
  } catch (error) {
    _logger.warn("Failed to load agent job", { error, agentId: id });
    return null;
  }
}

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
    created_at: Date.now(),
    model: config.MODEL_NAME_FAST ?? config.MODEL_NAME ?? req.body.model ?? "gpt-4o-mini",
    cancelled: false, creditsUsed: 0,
  });
  void persistAgentJob(agentJobs.get(agentId));

  runAgentAsync(agentId, req.body, req.auth.team_id, logger).catch(err => {
    logger.error("Agent failed", { error: err });
    const job = agentJobs.get(agentId);
    if (job && job.status === "processing") {
      updateAgentJob(job, {
        status: "failed",
        error: err instanceof Error ? err.message : String(err),
      });
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

  for (const url of urls.slice(0, AGENT_MAX_URLS)) {
    if (job.cancelled) { updateAgentJob(job, { status: "failed", error: "Cancelled" }); return; }
    try {
      const r = await fetch(`http://localhost:${config.PORT}/v2/scrape`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer bypass" },
        body: JSON.stringify({ url, formats: ["markdown"], onlyMainContent: true, origin: "agent" }),
      });
      if (r.ok) {
        const d = await r.json();
        job.creditsUsed += Number(d.data?.metadata?.creditsUsed ?? 0);
        const md = d.data?.markdown;
        if (md) scrapedContent.push(`## Content from ${url}\n\n${md}`);
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
        job.creditsUsed += Number(sd.creditsUsed ?? 0);
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
              job.creditsUsed += Number(d.data?.metadata?.creditsUsed ?? 0);
              const md = d.data?.markdown;
              if (md) scrapedContent.push(`## Content from ${result.url}\n\n${md}`);
            }
          } catch {}
        }
      }
    } catch (e) { logger.warn("Agent search failed", { error: e }); }
  }

  if (job.cancelled) { updateAgentJob(job, { status: "failed", error: "Cancelled" }); return; }
  if (scrapedContent.length === 0) { updateAgentJob(job, { status: "failed", error: "No content gathered" }); return; }
  const allContent = scrapedContent.join("\n\n---\n\n").slice(0, AGENT_MAX_CONTENT_CHARS);

  try {
    const model = getModelFast("gpt-4o-mini");
    if (schema) {
      const result = await generateObject({
        model,
        schema: jsonSchema(schema),
        system: `You are a research agent. Answer: ${prompt}`,
        prompt: allContent,
        temperature: 0,
      });
      if (job.cancelled) { updateAgentJob(job, { status: "failed", error: "Cancelled" }); return; }
      job.data = result.object;
    } else {
      const result = await generateText({ model, system: `You are a research agent. Answer comprehensively: ${prompt}`, prompt: allContent, temperature: 0 });
      if (job.cancelled) { updateAgentJob(job, { status: "failed", error: "Cancelled" }); return; }
      job.data = { summary: result.text };
    }
    updateAgentJob(job, { status: "completed", error: undefined });
  } catch (err) {
    updateAgentJob(job, { status: "failed", error: err instanceof Error ? err.message : String(err) });
  }
}
AGENTTS
sed -i 's/urls: URL.array().optional()/urls: URL.array().max(10, "Maximum of 10 URLs per agent request.").optional()/' \
  "$FIRECRAWL_DIR/apps/api/src/controllers/v2/types.ts"

cat > "$FIRECRAWL_DIR/apps/api/src/controllers/v2/agent-status.ts" << 'AGENTSTATUSTS'
import { Response } from "express";
import { AgentStatusResponse, RequestWithAuth } from "./types";
import { agentJobs, loadAgentJob } from "./agent";
import { config } from "../../config";
import {
  supabaseGetAgentByIdDirect,
  supabaseGetAgentRequestByIdDirect,
} from "../../lib/supabase-jobs";
import { getJobFromGCS } from "../../lib/gcs-jobs";

export async function agentStatusController(
  req: RequestWithAuth<{ jobId: string }, AgentStatusResponse, any>,
  res: Response<AgentStatusResponse>,
) {
  let job = agentJobs.get(req.params.jobId);
  if (job && job.team_id !== req.auth.team_id) job = undefined;
  if (!job && config.DATABASE_URL) {
    job = await loadAgentJob(req.params.jobId, req.auth.team_id);
  }
  if (!job && config.USE_DB_AUTHENTICATION) {
    const request = await supabaseGetAgentRequestByIdDirect(req.params.jobId);
    if (request?.team_id === req.auth.team_id) {
      const agent = await supabaseGetAgentByIdDirect(req.params.jobId);
      const data = agent?.is_successful
        ? await getJobFromGCS(agent.id)
        : undefined;
      return res.status(200).json({
        success: true,
        status: !agent ? "processing" : agent.is_successful ? "completed" : "failed",
        error: agent?.error || undefined,
        data,
        model: agent?.options?.model ?? config.MODEL_NAME_FAST ?? config.MODEL_NAME,
        expiresAt: new Date(
          new Date(agent?.created_at ?? request.created_at).getTime() + 1000 * 60 * 60 * 24,
        ).toISOString(),
        creditsUsed: agent?.credits_cost,
      });
    }
  }
  if (!job) {
    return res.status(404).json({ success: false, error: "Agent job not found" });
  }
  const now = Date.now();
  for (const [id, j] of agentJobs) {
    if (now - j.created_at > 24 * 60 * 60 * 1000) agentJobs.delete(id);
  }
  return res.status(200).json({
    success: true, status: job.status, error: job.error || undefined,
    data: job.status === "completed" ? job.data : undefined,
    model: job.model as any,
    expiresAt: new Date(job.created_at + 1000 * 60 * 60 * 24).toISOString(),
    creditsUsed: job.creditsUsed ?? 0,
  });
}
AGENTSTATUSTS

cat > "$FIRECRAWL_DIR/apps/api/src/controllers/v2/agent-cancel.ts" << 'AGENTCANCELTS'
import { Response } from "express";
import { AgentCancelResponse, RequestWithAuth } from "./types";
import { agentJobs } from "./agent";
import { config } from "../../config";
import { sql } from "drizzle-orm";
import { db } from "../../db/connection";

export async function agentCancelController(
  req: RequestWithAuth<{ jobId: string }, AgentCancelResponse, any>,
  res: Response<AgentCancelResponse>,
) {
  const job = agentJobs.get(req.params.jobId);
  if (job && job.team_id !== req.auth.team_id) {
    return res.status(404).json({ success: false, error: "Agent job not found" });
  }
  if (job && job.status !== "processing") {
    return res.status(409).json({ success: false, error: "Agent already finished" });
  }
  if (job) {
    job.cancelled = true;
    Object.assign(job, { status: "failed", error: "Agent cancelled by user" });
  }
  if (config.DATABASE_URL) {
    const result: any = await db.execute(sql`
      UPDATE agent_jobs
      SET status = 'failed', error = 'Agent cancelled by user', updated_at = now()
      WHERE id = ${req.params.jobId}
        AND team_id = ${req.auth.team_id}
        AND status = 'processing'
      RETURNING id
    `);
    if (!job && !result.rows?.[0]) {
      return res.status(404).json({ success: false, error: "Agent job not found" });
    }
  } else if (!job) {
    return res.status(404).json({ success: false, error: "Agent job not found" });
  }
  return res.status(200).json({ success: true });
}
AGENTCANCELTS
echo "  Done."

# ── 11. SearXNG per-source search (news/images buckets) ───────────────
echo "[11/13] Patching SearXNG source-type support..."
SEARXNG_SOURCES="$FIRECRAWL_DIR/apps/api/src/search/v2/searxng-sources.ts"
cat > "$SEARXNG_SOURCES" << 'SEARXNGSOURCES'
import axios from "axios";
import { config } from "../../config";
import { SearchV2Response, SearchResultType } from "../../lib/entities";
import { logger } from "../../lib/logger";

const CATEGORY_BY_TYPE: Record<SearchResultType, string> = {
  web: "general",
  news: "news",
  images: "images",
};

async function searchCategory(
  q: string,
  category: string,
  limit: number,
  lang?: string,
  options: {
    tbs?: string;
    filter?: string;
    country?: string;
    location?: string;
    safe?: boolean;
  } = {},
): Promise<any[]> {
  const base = (config.SEARXNG_ENDPOINT ?? "").replace(/\/+$/, "");
  if (!base) return [];
  const results: any[] = [];
  const pages = Math.min(Math.ceil(Math.max(limit, 1) / 10), 100);
  const language = lang && options.country ? `${lang}-${options.country}` : lang;
  const timeRange = options.tbs?.match(/qdr:([hdwmy])(?:\b|$)/i)?.[1];
  const timeRangeMap: Record<string, string> = { h: "day", d: "day", w: "week", m: "month", y: "year" };
  try {
    for (let page = 1; page <= pages && results.length < limit; page += 1) {
      const response = await axios.get(base + "/search", {
        headers: { "Content-Type": "application/json" },
        params: {
          q,
          language,
          country: options.country,
          location: options.location,
          filter: options.filter,
          tbs: options.tbs,
          time_range: timeRange ? timeRangeMap[timeRange.toLowerCase()] : undefined,
          safesearch: options.safe === undefined ? undefined : options.safe ? 2 : 0,
          // A configured engine list is safe for general results only. News
          // and images must use their category-specific engine set.
          engines: category === "general" ? config.SEARXNG_ENGINES ?? undefined : undefined,
          categories:
            category === "general"
              ? config.SEARXNG_CATEGORIES ?? category
              : category,
          pageno: page,
          format: "json",
        },
      });
      const pageResults = Array.isArray(response.data?.results) ? response.data.results : [];
      results.push(...pageResults);
      if (pageResults.length < 10) break;
    }
    const seen = new Set<string>();
    return results.filter(item => {
      const key = item.url || `${item.title}:${item.content}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }).slice(0, limit);
  } catch (error) {
    logger.error(`SearXNG ${category} search failed`, { error });
    return [];
  }
}

/**
 * Extracts a publication date from common URL patterns (/2026/03/,
 * /2026-03-15/, /20260305/, ?date=2026-03-15) as a fallback when the
 * engine does not supply one — most news engines omit publishedDate.
 */
function dateFromUrl(url?: string): string | undefined {
  if (!url) return undefined;
  let m =
    url.match(/\/(20\d{2})\/(0?[1-9]|1[0-2])\/(0?[1-9]|[12]\d|3[01])(?=\/|\b)/) ||
    url.match(/(20\d{2})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])/) ||
    url.match(/\/(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\//);
  if (!m) {
    // minimal forms: /YYYY/MM/ or YYYY-MM (no day available)
    m = url.match(/(20\d{2})\/(0[1-9]|1[0-2])\//) ||
        url.match(/(20\d{2})-(0[1-9]|1[0-2])(?!-\d)/);
    if (m) return `${m[1]}-${m[2]}`;
    return undefined;
  }
  return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
}

/**
 * Lexical relevance ordering: ranks results by query-token overlap in
 * title/snippet and drops zero-overlap noise (e.g. unrelated SEO pages that
 * general SearXNG engines sometimes inject). Falls back to original order
 * when nothing overlaps, so unusual queries never empty out.
 */
function relevanceOrder(q: string, items: any[]): any[] {
  const tokens = new Set(
    ((q ?? "").toLowerCase().match(/[a-z0-9]+/g) ?? []).filter(t => t.length > 2),
  );
  if (tokens.size === 0 || !Array.isArray(items)) return items;
  const scored = items.map((item, idx) => {
    const text = `${item.title ?? ""} ${item.content ?? ""}`.toLowerCase();
    let score = 0;
    for (const t of tokens) {
      if (text.includes(t)) score += 1;
    }
    return { item, score, idx };
  });
  scored.sort((a, b) => b.score - a.score || a.idx - b.idx);
  // Never turn a provider outage, poisoned cache entry, or anti-bot result
  // into a successful but unrelated search response. An empty result lets the
  // caller try its next provider instead.
  return scored.filter(s => s.score > 0).map(s => s.item);
}

/**
 * Runs one SearXNG query per requested source type (web/news/images), each
 * with its own SearXNG category, and buckets the results accordingly.
 */
export async function searxngSearchV2(
  q: string,
  numResults: number,
  types?: SearchResultType[],
  lang?: string,
  sourceOptions?: Array<{
    type: SearchResultType;
    tbs?: string;
    filter?: string;
    lang?: string;
    country?: string;
    location?: string;
  }>,
  options: {
    tbs?: string;
    filter?: string;
    country?: string;
    location?: string;
    safe?: boolean;
  } = {},
): Promise<SearchV2Response> {
  const sourceRequests = sourceOptions?.filter(source =>
    source.type === "web" || source.type === "news" || source.type === "images",
  );
  const requested: SearchResultType[] = sourceRequests?.length
    ? sourceRequests.map(source => source.type)
    : types && types.length > 0
      ? types.filter(t => t === "web" || t === "news" || t === "images")
      : ["web"];
  const capped = Math.max(1, Math.min(numResults, 1000));

  const buckets = await Promise.all(
    requested.map(async (t, index) => {
      const source = sourceRequests?.[index];
      return {
        type: t,
        items: await searchCategory(
          q,
          CATEGORY_BY_TYPE[t],
          capped,
          source?.lang ?? lang,
          {
            ...options,
            tbs: source?.tbs ?? options.tbs,
            filter: source?.filter ?? options.filter,
            country: source?.country ?? options.country,
            location: source?.location ?? options.location,
          },
        ),
      };
    }),
  );

  const out: SearchV2Response = {};
  for (const { type, items } of buckets) {
    if (!Array.isArray(items)) continue;
    if (type === "images") {
      const images: SearchV2Response["images"] = items
        .slice(0, capped)
        .map((a: any, index) => ({
          title: a.title,
          imageUrl: a.img_src ?? a.thumbnail_src ?? a.url,
          url: a.url,
          position: index + 1,
        }));
      out.images = images;
    } else if (type === "news") {
      const news: SearchV2Response["news"] = relevanceOrder(q, items)
        .slice(0, capped)
        .map((a: any, index) => ({
          title: a.title,
          url: a.url,
          snippet: a.content ?? "",
          date: a.publishedDate ?? dateFromUrl(a.url),
          position: index + 1,
        }));
      out.news = news;
    } else {
      const web: SearchV2Response["web"] = relevanceOrder(q, items)
        .slice(0, capped)
        .map((a: any) => ({
          url: a.url,
          title: a.title,
          description: typeof a.content === "string" ? a.content : "",
        }));
      out.web = web;
    }
  }
  return out;
}
SEARXNGSOURCES

V2_SEARCH_INDEX="$FIRECRAWL_DIR/apps/api/src/search/v2/index.ts"
python3 - "$V2_SEARCH_INDEX" << 'PYSERAXINDEX3'
import re
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    'import { searxng_search } from "./searxng";',
    'import { searxngSearchV2 } from "./searxng-sources";',
)
if "sourceOptions = undefined" not in s:
    s = s.replace(
        "  type = undefined,\n  enterprise = undefined,",
        "  type = undefined,\n  sourceOptions = undefined,\n  enterprise = undefined,",
        1,
    )
if "  sourceOptions?: Array" not in s:
    s = s.replace(
        "  type?: SearchResultType | SearchResultType[];\n",
        "  type?: SearchResultType | SearchResultType[];\n  sourceOptions?: Array<{ type: SearchResultType; tbs?: string; filter?: string; lang?: string; country?: string; location?: string }>;\n",
        1,
    )

replacement = '''if (config.SEARXNG_ENDPOINT) {
    try {
      logger.info("Using searxng search");
      const requestedTypes = Array.isArray(type)
        ? type
        : type
          ? [type]
          : undefined;
      const results = await searxngSearchV2(
        query,
        num_results,
        requestedTypes,
        lang,
        sourceOptions,
        { tbs, filter, country, location, safe },
      );
      const hasResults =
        results.web?.length || results.news?.length || results.images?.length;
      if (hasResults) return results;
      const webRequested = !requestedTypes || requestedTypes.includes("web");
      if (!webRequested) {
        return requestedTypes?.reduce((empty, resultType) => {
          if (resultType === "news") empty.news = [];
          if (resultType === "images") empty.images = [];
          return empty;
        }, {} as SearchV2Response) ?? {};
      }
    } catch (error) {
      providerFailures.push("searxng");
      logger.error("SearXNG search failed", { error });
    }
  }

  '''
pattern = re.compile(
    r'if \(config\.SEARXNG_ENDPOINT\) \{.*?\n  \}\n\n  (?=try \{\n    logger\.info\("Using DuckDuckGo search"\))',
    re.S,
)
s, count = pattern.subn(replacement, s, count=1)
if count != 1:
    raise SystemExit("SearXNG provider block not found")
open(p, "w").write(s)
PYSERAXINDEX3
python3 - "$FIRECRAWL_DIR/apps/api/src/search/execute.ts" << 'PYSEARCHEXECUTE'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "  const num_results_buffer = Math.floor(limit * 2);",
    '  const constrainedSearch = Boolean(options.includeDomains?.length || options.excludeDomains?.length || categories?.some(category => (typeof category === "string" ? category : category.type) !== "developer"));\n  const num_results_buffer = constrainedSearch\n    ? Math.min(100, Math.max(limit * 10, 20))\n    : Math.floor(limit * 2);',
)
helper = r'''
async function searchResearchIndex(
  query: string,
  limit: number,
  logger: Logger,
): Promise<SearchV2Response | undefined> {
  if (!config.RESEARCH_PROXY_URL) return undefined;
  try {
    const endpoint = new URL("v2/research/papers", `${config.RESEARCH_PROXY_URL.replace(/\/$/, "")}/`);
    endpoint.searchParams.set("query", query);
    endpoint.searchParams.set("k", String(limit));
    const response = await fetch(endpoint, { signal: AbortSignal.timeout(30_000) });
    if (!response.ok) throw new Error(`research index returned HTTP ${response.status}`);
    const payload = (await response.json()) as { results?: any[] };
    const web = (payload.results ?? []).flatMap(paper => {
      const pmid = paper.ids?.pmid?.[0];
      const primaryId = typeof paper.primaryId === "string" ? paper.primaryId : "";
      const url = typeof pmid === "string"
        ? (pmid.startsWith("http") ? pmid : `https://pubmed.ncbi.nlm.nih.gov/${encodeURIComponent(pmid)}/`)
        : primaryId.startsWith("doi:")
          ? `https://doi.org/${primaryId.slice(4)}`
          : primaryId.startsWith("arxiv:")
            ? `https://arxiv.org/abs/${primaryId.slice(6)}`
            : undefined;
      return url ? [{
        url,
        title: paper.title ?? "(untitled research paper)",
        description: paper.abstract ?? "",
      }] : [];
    });
    return web.length > 0 ? { web } : undefined;
  } catch (error) {
    logger.warn("Dedicated research-index search failed; using web providers", { error });
    return undefined;
  }
}
'''
if "async function searchResearchIndex(" not in s:
    anchor = "\nexport async function executeSearch("
    if anchor not in s:
        raise SystemExit("research-index helper insertion point not found")
    s = s.replace(anchor, helper + anchor, 1)
s = s.replace(
    "  const { query: searchQuery, categoryMap } = buildSearchQuery(\n    query,",
    "  const { categoryMap } = buildSearchQuery(\n    query,",
)
s = s.replace("    query: searchQuery,", "    // Local SearXNG engines are unreliable with site:/filetype: operators.\n    // Fetch broadly, then enforce every constraint below at the API boundary.\n    query,", 1)
s = s.replace(
    "  const searchResponse = (await search({",
    '''  const researchCategoryRequested = (categories ?? []).some(
    category => (typeof category === "string" ? category : category.type) === "research",
  );
  let searchResponse = researchCategoryRequested
    ? await searchResearchIndex(query, num_results_buffer, logger)
    : undefined;
  searchResponse ??= await search({''',
    1,
)
s = s.replace("  })) as SearchV2Response;", "  }) as SearchV2Response;", 1)
s = s.replace(
    "        type: searchTypes,\n        enterprise: options.enterprise,",
    "        type: searchTypes,\n        sourceOptions: sources as any,\n        enterprise: options.enterprise,",
    1,
)
anchor = "\n  if (developerResults) {"
guard = r'''
  // Providers are advisory; the API contract is authoritative. SearXNG (and
  // especially Bing) can ignore operators or return poisoned cached results,
  // so enforce domain/category constraints before counting, billing, scraping,
  // tracking, or returning anything.
  const normalizedDomains = (values?: string[]) =>
    (values ?? []).map(value => value.trim().toLowerCase().replace(/^\.+|\.+$/g, "")).filter(Boolean);
  const includeDomains = normalizedDomains(options.includeDomains);
  const excludeDomains = normalizedDomains(options.excludeDomains);
  const matchesDomain = (url: string | undefined, domain: string): boolean => {
    if (!url) return false;
    try {
      const hostname = new URL(url).hostname.toLowerCase();
      return hostname === domain || hostname.endsWith(`.${domain}`);
    } catch {
      return false;
    }
  };
  const requestedCategories = new Set(
    (categories ?? [])
      .map(category => typeof category === "string" ? category : category.type)
      .filter(category => category !== "developer"),
  );
  // The research service may identify a paper only by DOI or return a direct
  // PMC full-text URL. Both are scholarly results even though older upstream
  // defaults omitted these hosts.
  if (requestedCategories.has("research")) {
    categoryMap.set("doi.org", "research");
    categoryMap.set("pmc.ncbi.nlm.nih.gov", "research");
  }
  const resultAllowed = (url: string | undefined): boolean => {
    if (!url) return false;
    if (includeDomains.length > 0 && !includeDomains.some(domain => matchesDomain(url, domain))) return false;
    if (excludeDomains.some(domain => matchesDomain(url, domain))) return false;
    if (requestedCategories.size === 0) return true;
    const category = getCategoryFromUrl(url, categoryMap);
    return category !== undefined && requestedCategories.has(category);
  };
  if (searchResponse.web) searchResponse.web = searchResponse.web.filter(item => resultAllowed(item.url));
  if (searchResponse.news) searchResponse.news = searchResponse.news.filter(item => resultAllowed(item.url));
  if (searchResponse.images) searchResponse.images = searchResponse.images.filter(item => resultAllowed(item.url));
'''
if "Providers are advisory; the API contract is authoritative" not in s:
    if anchor not in s:
        raise SystemExit("executeSearch constraint insertion point not found")
    s = s.replace(anchor, guard + anchor, 1)
open(p, "w").write(s)
PYSEARCHEXECUTE
echo "  Done."

# ── 12. Enforce agent content truncation ──────────────────────────────
echo "[12/13] Applying bounded agent content policy (400k chars)..."
AGENT_TS="$FIRECRAWL_DIR/apps/api/src/controllers/v2/agent.ts"
sed -i -E 's/const AGENT_MAX_CONTENT_CHARS = [0-9_]+;/const AGENT_MAX_CONTENT_CHARS = 400_000;/' "$AGENT_TS"
sed -i -E 's/const allContent = scrapedContent\.join\("\\\\n\\\\n---\\\\n\\\\n"\)(\.slice\(0, [A-Z0-9_]+\))?;/const allContent = scrapedContent.join("\\\\n\\\\n---\\\\n\\\\n").slice(0, AGENT_MAX_CONTENT_CHARS);/' "$AGENT_TS"
echo "  Done."


# ── 13. Hybrid local-PG persistence (monitors/feedback/interact/telemetry) ──
echo "[13/13] Enabling hybrid local Postgres persistence..."
DB_CONN="$FIRECRAWL_DIR/apps/api/src/db/connection.ts"
python3 - "$DB_CONN" << 'PYCONN'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
"""const mainDb = useDbAuthentication
  ? makeDb(config.DATABASE_URL, "firecrawl-api")
  : null;
const replicaDb = useDbAuthentication
  ? makeDb(
      config.DATABASE_REPLICA_URL ?? config.DATABASE_URL,
      "firecrawl-api-rr",
    )
  : null;""",
"""// Hybrid mode: even when hosted-style DB auth is disabled, initialize the
// drizzle clients whenever DATABASE_URL exists so self-hosted deployments can
// persist monitors, feedback, browser sessions and request telemetry against
// their own local Postgres.
const dbPersistence = useDbAuthentication || !!config.DATABASE_URL;

const mainDb = dbPersistence
  ? makeDb(config.DATABASE_URL, "firecrawl-api")
  : null;
const replicaDb = dbPersistence
  ? makeDb(
      config.DATABASE_REPLICA_URL ?? config.DATABASE_URL,
      "firecrawl-api-rr",
    )
  : null;""")
s = s.replace("if (useDbAuthentication && !mainDb) {", "if (dbPersistence && !mainDb) {")
s = s.replace("max: sizing.max ?? 20,", "max: sizing.max ?? config.DB_POOL_MAX ?? 8,")
open(p, "w").write(s)
PYCONN

CONCURRENCY="$FIRECRAWL_DIR/apps/api/src/lib/concurrency-limit.ts"
python3 - "$CONCURRENCY" << 'PYCONCURRENCY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'from "../config"' not in s:
    s = s.replace('import { autumnService } from "../services/autumn/autumn.service";', 'import { autumnService } from "../services/autumn/autumn.service";\nimport { config } from "../config";')
needle = "  const autumnValue = await autumnService.getConcurrencyLimit(teamId, orgId);\n  return autumnValue ?? DEFAULT_CONCURRENCY_LIMIT;"
replacement = "  if (config.USE_DB_AUTHENTICATION !== true) {\n    return config.SELF_HOSTED_CONCURRENCY_LIMIT ?? 50;\n  }\n  const autumnValue = await autumnService.getConcurrencyLimit(teamId, orgId);\n  return autumnValue ?? DEFAULT_CONCURRENCY_LIMIT;"
if needle in s and "config.SELF_HOSTED_CONCURRENCY_LIMIT" not in s:
    s = s.replace(needle, replacement)
open(p, "w").write(s)
PYCONCURRENCY

LOG_JOB="$FIRECRAWL_DIR/apps/api/src/services/logging/log_job.ts"
perl -0777 -pi -e 's/if \(config\.USE_DB_AUTHENTICATION !== true\) \{
    logger\.info\(
      "Skipping database insertion due to USE_DB_AUTHENTICATION being off",
    \);
    return;
  \}/if (config.USE_DB_AUTHENTICATION !== true \&\& !config.DATABASE_URL) {
    logger.info(
      "Skipping database insertion due to USE_DB_AUTHENTICATION being off",
    );
    return;
  }/' "$LOG_JOB"

BROWSER_TS="$FIRECRAWL_DIR/apps/api/src/controllers/v2/scrape-browser.ts"
perl -0777 -pi -e 's/if \(config\.USE_DB_AUTHENTICATION !== true\) \{
    return res\.status\(501\)\.json\(\{
      success: false,
      error:
        "Scrape interact requires stored scrape context and is not available when database authentication is disabled\.",
    \}\);
  \}/if (config.USE_DB_AUTHENTICATION !== true \&\& !config.DATABASE_URL) {
    return res.status(501).json({
      success: false,
      error:
        "Scrape interact requires stored scrape context and is not available when database authentication is disabled.",
    });
  }/' "$BROWSER_TS"

FEEDBACK_TS="$FIRECRAWL_DIR/apps/api/src/controllers/v2/feedback/record.ts"
perl -0777 -pi -e 's/if \(config\.USE_DB_AUTHENTICATION !== true\) \{
    return feedbackFailure\(
      503,
      "DB_DISABLED",/if (config.USE_DB_AUTHENTICATION !== true \&\& !config.DATABASE_URL) {
    return feedbackFailure(
      503,
      "DB_DISABLED",/' "$FEEDBACK_TS"

CRAWL_STATUS="$FIRECRAWL_DIR/apps/api/src/controllers/v2/crawl-status.ts"
sed -i 's|creditsUsed: creditsBilled?.\[0\]?.credits_billed ?? -1,|creditsUsed: creditsBilled?.[0]?.credits_billed ?? numericStats.completed ?? 0,|' "$CRAWL_STATUS"

V2_ROUTES="$FIRECRAWL_DIR/apps/api/src/routes/v2.ts"
sed -i '/deprecationMiddleware("v2_extract"),/d; /deprecationMiddleware("v2_extract_status"),/d' "$V2_ROUTES"

QW_TS="$FIRECRAWL_DIR/apps/api/src/services/queue-worker.ts"
python3 - "$QW_TS" << 'PYQW'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
  "if (config.USE_DB_AUTHENTICATION && !config.DISABLE_MONITORING) {",
  "if (\n    (config.USE_DB_AUTHENTICATION || config.DATABASE_URL) &&\n    !config.DISABLE_MONITORING\n  ) {")
open(p, "w").write(s)
PYQW

python3 - "$QW_TS" << 'PYQWACTIVITY'
import sys
p = sys.argv[1]
s = open(p).read()
if "processBrowserSessionActivityJobs" not in s:
    s = s.replace(
        'import { enqueueDueMonitorChecks } from "./monitoring/scheduler";',
        'import { enqueueDueMonitorChecks } from "./monitoring/scheduler";\nimport { processBrowserSessionActivityJobs } from "../lib/browser-session-activity";',
    )
    s = s.replace(
        'let monitorSchedulerInterval: NodeJS.Timeout | null = null;',
        'let monitorSchedulerInterval: NodeJS.Timeout | null = null;\nlet browserActivityInterval: NodeJS.Timeout | null = null;',
    )
    needle = "  await Promise.all([\n    workerFun(getDeepResearchQueue(), processDeepResearchJobInternal),"
    replacement = "  if (config.DATABASE_URL) {\n    browserActivityInterval = setInterval(() => {\n      processBrowserSessionActivityJobs().catch(error => {\n        _logger.error(\"Failed to persist browser session activity\", { error });\n      });\n    }, 1000);\n    processBrowserSessionActivityJobs().catch(error => {\n      _logger.error(\"Failed to persist browser session activity\", { error });\n    });\n  }\n\n  await Promise.all([\n    workerFun(getDeepResearchQueue(), processDeepResearchJobInternal),"
    if needle not in s:
        raise SystemExit("queue worker activity anchor not found")
    s = s.replace(needle, replacement, 1)
open(p, "w").write(s)
PYQWACTIVITY

HARNESS="$FIRECRAWL_DIR/apps/api/src/harness.ts"
python3 - "$HARNESS" << 'PYHARNESS'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("const indexWorker = (config.USE_DB_AUTHENTICATION || !!config.DATABASE_URL)", "const indexWorker = config.USE_DB_AUTHENTICATION")
open(p, "w").write(s)
PYHARNESS

cat > "$FIRECRAWL_DIR/apps/api/src/lib/scrape-content-quality.ts" << 'SCRAPEQUALITY'
type ScrapeContent = {
  markdown?: unknown;
  html?: unknown;
  rawHtml?: unknown;
  summary?: unknown;
};

/** Detect provider interstitials that carry HTTP 200 but no requested content. */
export function detectAccessInterstitial(doc: ScrapeContent | null): string | undefined {
  if (!doc) return undefined;
  const content = [doc.markdown, doc.html, doc.rawHtml, doc.summary]
    .filter((value): value is string => typeof value === "string")
    .join("\n")
    .toLowerCase();
  if (!content) return undefined;

  if (
    content.includes("cookies must be enabled") &&
    content.includes("enable cookies for") &&
    content.includes("reload this page")
  ) {
    return "The origin returned a cookie access interstitial instead of page content.";
  }
  if (
    content.includes("enable javascript and cookies to continue") &&
    (content.includes("just a moment") || content.includes("cloudflare"))
  ) {
    return "The origin returned an anti-bot interstitial instead of page content.";
  }
  if (
    content.includes("attention required") &&
    content.includes("cloudflare ray id")
  ) {
    return "The origin returned an anti-bot challenge instead of page content.";
  }
  return undefined;
}
SCRAPEQUALITY

python3 - "$FIRECRAWL_DIR/apps/api/src/lib/error.ts" << 'PYQUALITYERROR'
import sys
p = sys.argv[1]
s = open(p).read()
code = '  | "SCRAPE_ACCESS_INTERSTITIAL"\n'
if code not in s:
    anchor = '  | "SCRAPE_MEDIA_ACCESS_DENIED"\n'
    if anchor not in s:
        raise SystemExit("scrape error-code anchor not found")
    s = s.replace(anchor, anchor + code, 1)
open(p, "w").write(s)
PYQUALITYERROR

python3 - "$FIRECRAWL_DIR/apps/api/src/lib/error-serde.ts" << 'PYQUALITYSERDE'
import sys
p = sys.argv[1]
s = open(p).read()
entry = '  // Access interstitials are rejected synchronously by the HTTP controller.\n  SCRAPE_ACCESS_INTERSTITIAL: null,\n'
if "SCRAPE_ACCESS_INTERSTITIAL:" not in s:
    anchor = '  SCRAPE_MEDIA_ACCESS_DENIED: MediaAccessDeniedError,\n'
    if anchor not in s:
        raise SystemExit("scrape error-serde anchor not found")
    s = s.replace(anchor, anchor + entry, 1)
open(p, "w").write(s)
PYQUALITYSERDE

SCRAPE_TS="$FIRECRAWL_DIR/apps/api/src/controllers/v2/scrape.ts"
python3 - "$SCRAPE_TS" << 'PYSCRAPEQUALITY'
import sys
p = sys.argv[1]
s = open(p).read()
import_line = 'import { detectAccessInterstitial } from "../../lib/scrape-content-quality";'
if import_line not in s:
    anchor = 'import { getEffectiveConcurrencyLimit } from "../../lib/concurrency-limit";'
    if anchor not in s:
        raise SystemExit("scrape content-quality import anchor not found")
    s = s.replace(anchor, anchor + "\n" + import_line, 1)
snippet = '''
      const accessInterstitial = detectAccessInterstitial(doc);
      if (accessInterstitial) {
        logger.warn("Rejecting scrape access interstitial", {
          url: req.body.url,
          scrapeId: jobId,
          reason: accessInterstitial,
        });
        return res.status(502).json({
          success: false,
          code: "SCRAPE_ACCESS_INTERSTITIAL",
          error: accessInterstitial,
        });
      }
'''
if snippet.strip() not in s:
    anchor = '''      if (reservedKeylessCredits > 0 && !reconciledKeylessCredits) {'''
    position = s.rfind(anchor)
    if position < 0:
        raise SystemExit("scrape content-quality response anchor not found")
    s = s[:position] + snippet + "\n" + s[position:]
open(p, "w").write(s)
PYSCRAPEQUALITY

ACTIVITY="$FIRECRAWL_DIR/apps/api/src/lib/browser-session-activity.ts"
python3 - "$ACTIVITY" << 'PYACTIVITY'
import re, sys
p = sys.argv[1]
s = open(p).read()
pattern = r"export async function processBrowserSessionActivityJobs\(\) \{.*?\n\}"
replacement = '''export async function processBrowserSessionActivityJobs() {
  const raw = await redisEvictConnection.lrange(QUEUE_KEY, 0, BATCH_SIZE - 1);
  if (raw.length === 0) return;

  const rows: BrowserSessionActivityEvent[] = [];
  for (const value of raw) {
    try {
      rows.push(JSON.parse(value) as BrowserSessionActivityEvent);
    } catch (err) {
      logger.error("Dropping malformed browser session activity", { err });
    }
  }

  try {
    if (rows.length > 0) {
      await db.insert(schema.browser_session_activities).values(rows);
    }
    // Acknowledge only after the database write. New events appended while the
    // insert runs remain after the first raw.length entries.
    await redisEvictConnection.ltrim(QUEUE_KEY, raw.length, -1);
  } catch (err) {
    // Leave the batch at the head of the queue so a transient DB outage is
    // retried instead of silently losing activity and billing evidence.
    logger.error("Error inserting browser session activities; batch retained", {
      err,
      count: rows.length,
    });
  }
}'''
s, count = re.subn(pattern, replacement, s, count=1, flags=re.S)
if count != 1:
    raise SystemExit("browser activity function not found")
open(p, "w").write(s)
PYACTIVITY

BROWSER_SESSIONS="$FIRECRAWL_DIR/apps/api/src/lib/browser-sessions.ts"
python3 - "$BROWSER_SESSIONS" << 'PYBROWSERSESSIONS'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''  } catch (error) {
    logger.warn("Failed to claim browser session destroyed", { error, id });
    return false;
  }
}'''
new = '''  } catch (error) {
    logger.error("Failed to claim browser session destroyed", { error, id });
    throw new Error(
      `Failed to claim browser session destroyed: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}'''
if old in s:
    s = s.replace(old, new, 1)
open(p, "w").write(s)
PYBROWSERSESSIONS

SCRAPE_JOBS="$FIRECRAWL_DIR/apps/api/src/lib/supabase-jobs.ts"
python3 - "$SCRAPE_JOBS" << 'PYSCRAPEJOBS'
import sys
p = sys.argv[1]
s = open(p).read()
needle = '''export const supabaseGetScrapesById = async ('''
helper = '''/**
 * A skipNuq scrape writes its durable row in the worker just before the API
 * responds. Interact can arrive in the small gap between those operations, so
 * retry the lookup here without slowing ordinary callers.
 */
export const supabaseGetScrapeByIdWithRetry = async (
  scrapeId: string,
  attempts = 8,
  delayMs = 250,
): Promise<any> => {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const data = await supabaseGetScrapeById(scrapeId);
    if (data) return data;
    if (attempt + 1 < attempts) {
      await new Promise(resolve => setTimeout(resolve, delayMs));
    }
  }
  return null;
};

export const supabaseGetScrapesById = async ('''
if needle in s and "supabaseGetScrapeByIdWithRetry" not in s:
    s = s.replace(needle, helper, 1)
open(p, "w").write(s)
PYSCRAPEJOBS

SCRAPE_BROWSER="$FIRECRAWL_DIR/apps/api/src/controllers/v2/scrape-browser.ts"
python3 - "$SCRAPE_BROWSER" << 'PYSCRAPEBROWSER'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "import { supabaseGetScrapeById } from \"../../lib/supabase-jobs\";",
    "import { supabaseGetScrapeByIdWithRetry } from \"../../lib/supabase-jobs\";",
)
s = s.replace(
    "  const scrape = (await supabaseGetScrapeById(\n    scrapeId,\n  )) as ScrapeContextRow | null;",
    "  const scrape = (await supabaseGetScrapeByIdWithRetry(\n    scrapeId,\n  )) as ScrapeContextRow | null;",
)
s = s.replace(
    'code: `await page.goto(${JSON.stringify(replayContext.targetUrl)}, { waitUntil: "networkidle0" });`,\n          language: "node",',
    'code: `agent-browser goto ${replayContext.targetUrl}`,\n          language: "bash",',
)
open(p, "w").write(s)
PYSCRAPEBROWSER

SCRAPE_WORKER="$FIRECRAWL_DIR/apps/api/src/services/worker/scrape-worker.ts"
python3 - "$SCRAPE_WORKER" << 'PYSCRAPEWORKER'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "if (job.data.skipNuq && !config.DATABASE_URL) {\n       throw error;",
    "if (job.data.skipNuq) {\n       throw error;",
)
s = s.replace(
    "if (job.data.skipNuq) {\n        // doesn't use GCS",
    "if (job.data.skipNuq && !config.DATABASE_URL) {\n        // doesn't use GCS",
)
open(p, "w").write(s)
PYSCRAPEWORKER

EXTRACT_STATUS="$FIRECRAWL_DIR/apps/api/src/controllers/v2/extract-status.ts"
python3 - "$EXTRACT_STATUS" << 'PYEXTRACTSTATUS'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "  const extractRequest = config.USE_DB_AUTHENTICATION\n    ? await supabaseGetExtractRequestByIdDirect(req.params.jobId)\n    : null;",
    "  const dbPersistence = config.USE_DB_AUTHENTICATION || !!config.DATABASE_URL;\n  const extractRequest = dbPersistence\n    ? await supabaseGetExtractRequestByIdDirect(req.params.jobId)\n    : null;",
)
s = s.replace("if (config.USE_DB_AUTHENTICATION) {", "if (dbPersistence) {")
guard = "    if (!extractRequest) {\n      return res.status(404).json({\n        success: false,\n        error: \"Extract job not found\",\n      });\n    }\n\n"
if "if (!extractRequest)" not in s:
    s = s.replace(
        "    // Fall back to extractRequest info\n    return res.status(200).json({",
        guard + "    // Fall back to extractRequest info\n    return res.status(200).json({",
    )
else:
    s = re.sub(r"(?:" + re.escape(guard) + r"){2,}", guard, s)
open(p, "w").write(s)
PYEXTRACTSTATUS

KEYLESS="$FIRECRAWL_DIR/apps/api/src/lib/keyless.ts"
python3 - "$KEYLESS" << 'PYKEYLESS'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "if (config.USE_DB_AUTHENTICATION !== true) return;",
    "if (config.USE_DB_AUTHENTICATION !== true && !config.DATABASE_URL) return;",
    1,
)
s = s.replace("if (creditsUsed <= 0) {", "if (creditsUsed <= 0 && !config.DATABASE_URL) {", 1)
open(p, "w").write(s)
PYKEYLESS

LLMS_TEXT="$FIRECRAWL_DIR/apps/api/src/lib/generate-llmstxt/generate-llmstxt-supabase.ts"
python3 - "$LLMS_TEXT" << 'PYLLMSTEXT'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("if (config.USE_DB_AUTHENTICATION !== true) {", "if (config.USE_DB_AUTHENTICATION !== true && !config.DATABASE_URL) {", 2)
open(p, "w").write(s)
PYLLMSTEXT

DEPREC="$FIRECRAWL_DIR/apps/api/src/lib/deprecations.ts"
python3 - "$DEPREC" << 'PYDEP'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(
  r"""  v2_extract: \{.*?\},
  v2_extract_status: \{.*?\},""",
  "  // v2 extract deprecation notices intentionally removed for self-hosted\n"
  "  // deployments: the firecrawl-mcp client still uses /v2/extract and the\n"
  "  // warning surfaces as noise in every MCP tool result.",
  s, flags=re.S)
open(p, "w").write(s)
PYDEP

for check in \
  "$FIRECRAWL_DIR/apps/api/src/db/connection.ts|dbPersistence" \
  "$FIRECRAWL_DIR/apps/api/src/controllers/v2/types.ts|export const MAX_MAP_LIMIT = 1000000;" \
  "$FIRECRAWL_DIR/apps/api/src/controllers/v2/agent.ts|AGENT_MAX_CONTENT_CHARS" \
  "$FIRECRAWL_DIR/apps/api/src/search/v2/searxng-sources.ts|time_range" \
  "$FIRECRAWL_DIR/apps/playwright-service-ts/api.ts|installBrowserSessionRoutes"; do
  file=${check%%|*}
  marker=${check#*|}
  if ! grep -Fq "$marker" "$file"; then
    echo "Error: patch postcondition failed for $file (missing $marker)"
    exit 1
  fi
done

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
