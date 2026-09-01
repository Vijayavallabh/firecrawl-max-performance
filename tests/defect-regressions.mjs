#!/usr/bin/env node

import assert from "node:assert/strict";

const base = (process.env.FIRECRAWL_BASE_URL || "http://127.0.0.1:3002").replace(/\/$/, "");
const allowedSearchHosts = new Set([
  "pubmed.ncbi.nlm.nih.gov",
  "pmc.ncbi.nlm.nih.gov",
  "nature.com",
  "www.nature.com",
]);

async function post(path, body, timeout = 30_000) {
  const response = await fetch(`${base}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeout),
  });
  return { response, body: await response.json() };
}

const constrained = await post("/v2/search", {
    query: '"mosaic variegated aneuploidy" (BUB1B OR CEP57 OR TRIP13)',
    categories: ["research"],
    includeDomains: [...allowedSearchHosts],
    limit: 10,
    highlights: true,
});
assert.equal(constrained.response.status, 200, JSON.stringify(constrained.body));
assert.equal(constrained.body.success, true, JSON.stringify(constrained.body));
assert.ok(constrained.body.data?.web?.length > 0, "biomedical search returned no results");

const leaked = constrained.body.data.web
  .map(result => result.url)
  .filter(url => !allowedSearchHosts.has(new URL(url).hostname));
assert.deepEqual(leaked, [], `includeDomains leaked disallowed URLs: ${leaked.join(", ")}`);
assert.ok(
  constrained.body.data.web.every(result => result.category === "research"),
  "research category returned unclassified generic web results",
);

const excluded = await post("/v2/search", {
  query: "BUB1B mosaic variegated aneuploidy",
  excludeDomains: ["wikipedia.org", "britannica.com"],
  limit: 10,
});
assert.equal(excluded.response.status, 200, JSON.stringify(excluded.body));
assert.ok(excluded.body.data?.web?.length > 0, "excluded-domain search returned no results");
assert.ok(
  excluded.body.data.web.every(result => !/(^|\.)(wikipedia\.org|britannica\.com)$/.test(new URL(result.url).hostname)),
  "excludeDomains leaked blocked hosts",
);

const pdf = await post("/v2/search", {
  query: "BUB1B mosaic variegated aneuploidy",
  categories: ["pdf"],
  limit: 5,
});
assert.equal(pdf.response.status, 200, JSON.stringify(pdf.body));
assert.ok(pdf.body.data?.web?.length > 0, "PDF category returned no results");
assert.ok(pdf.body.data.web.every(result => new URL(result.url).pathname.toLowerCase().endsWith(".pdf")), "PDF category leaked non-PDF results");

const interstitial = await post("/v2/scrape", {
  url: "https://pubmed.ncbi.nlm.nih.gov/15475955/",
  formats: ["markdown"],
  onlyMainContent: true,
}, 120_000);
assert.equal(interstitial.response.status, 502, JSON.stringify(interstitial.body));
assert.equal(interstitial.body.success, false, JSON.stringify(interstitial.body));
assert.equal(interstitial.body.code, "SCRAPE_ACCESS_INTERSTITIAL", JSON.stringify(interstitial.body));

console.log("PASS: search constraints and scrape interstitial rejection hold at the API boundary");
