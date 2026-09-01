#!/usr/bin/env node

const base = (process.env.FIRECRAWL_BASE_URL || "http://localhost:3002").replace(/\/$/, "");

async function request(path, init = {}) {
  let lastError;
  for (let attempt = 0; attempt < 10; attempt += 1) {
    try {
      const response = await fetch(`${base}${path}`, {
        signal: AbortSignal.timeout(120_000),
        ...init,
        headers: { "content-type": "application/json", ...(init.headers || {}) },
      });
      const body = await response.json().catch(() => ({}));
      return { response, body };
    } catch (error) {
      lastError = error;
      await new Promise(resolve => setTimeout(resolve, 2_000));
    }
  }
  throw lastError;
}

function check(value, message) {
  if (!value) throw new Error(message);
}

const root = await request("/");
check(root.response.ok && root.body.message === "Firecrawl API", "API root is unhealthy");

const search = await request("/v2/search", {
  method: "POST",
  body: JSON.stringify({ query: "BUB1B mosaic variegated aneuploidy", limit: 5 }),
});
check(search.response.ok && search.body.success, "search failed");
check(search.body.data?.web?.length > 0, "search silently returned no web results");

const scrape = await request("/v2/scrape", {
  method: "POST",
  body: JSON.stringify({
    url: "https://medlineplus.gov/genetics/gene/bub1b/",
    formats: ["markdown"],
  }),
});
check(scrape.response.ok && scrape.body.success, "scrape failed");
check(/BUB1B/i.test(scrape.body.data?.markdown || ""), "scrape returned unrelated/empty content");
check((scrape.body.data?.metadata?.creditsUsed ?? -1) >= 0, "scrape reported negative credits");

const map = await request("/v2/map", {
  method: "POST",
  body: JSON.stringify({ url: "https://medlineplus.gov/genetics/", limit: 5 }),
});
check(map.response.ok && map.body.success, "map failed");
check(map.body.links?.length > 0, "map silently returned no links");

const parseForm = new FormData();
parseForm.append(
  "file",
  new Blob(
    ["<html><body><h1>BUB1B public fixture</h1><p>Mosaic variegated aneuploidy.</p></body></html>"],
    { type: "text/html" },
  ),
  "mva-public.html",
);
parseForm.append("options", JSON.stringify({ formats: ["markdown"] }));
const parseResponse = await fetch(`${base}/v2/parse`, {
  method: "POST",
  body: parseForm,
  signal: AbortSignal.timeout(120_000),
});
const parsed = await parseResponse.json();
check(parseResponse.ok && parsed.success && /BUB1B/.test(parsed.data?.markdown || ""), "parse failed");

const crawl = await request("/v2/crawl", {
  method: "POST",
  body: JSON.stringify({
    url: "https://medlineplus.gov/genetics/gene/bub1b/",
    limit: 1,
    scrapeOptions: { formats: ["markdown"] },
  }),
});
check(crawl.response.ok && crawl.body.success && crawl.body.id, "crawl did not start");
let crawlStatus;
for (let attempt = 0; attempt < 30; attempt += 1) {
  crawlStatus = await request(`/v2/crawl/${crawl.body.id}`);
  if (["completed", "failed", "cancelled"].includes(crawlStatus.body.status)) break;
  await new Promise(resolve => setTimeout(resolve, 2_000));
}
check(crawlStatus?.response.ok && crawlStatus.body.status === "completed", "crawl did not complete");
check((crawlStatus.body.creditsUsed ?? -1) >= 0, "crawl reported negative credits");

const papers = await request(
  "/v2/research/papers?query=BUB1B%20mosaic%20variegated%20aneuploidy&k=3",
);
check(papers.response.ok && papers.body.success, "paper search failed");
check(papers.body.results?.length > 0, "paper search silently returned no results");

const inspect = await request("/v2/research/papers/doi%3A10.1038%2Fng1449");
check(inspect.response.ok && inspect.body.success && inspect.body.paper?.title, "paper inspection failed");

const read = await request(
  "/v2/research/papers/pmid%3A35804254?query=BUB1B%20variant&k=2",
);
check(read.response.ok && read.body.success && read.body.passages?.length > 0, "open-access paper read failed");

const related = await request(
  "/v2/research/papers/doi%3A10.1038%2Fng1449/similar?intent=mosaic%20variegated%20aneuploidy&k=3",
);
check(related.response.ok && related.body.success && related.body.results?.length > 0, "related-paper search failed");

const github = await request(
  "/v2/research/github?query=BUB1B&k=3",
);
check(github.response.ok && github.body.success && github.body.results?.length > 0, "GitHub research failed");

const developer = await request(
  "/v2/developer/search?query=BUB1B%20variant%20prioritization&k=3",
);
check(developer.response.ok && developer.body.success && developer.body.results?.length > 0, "developer search failed");

console.log("PASS: core crawl/parse tools plus paper search/inspect/read/related and GitHub/developer research");
