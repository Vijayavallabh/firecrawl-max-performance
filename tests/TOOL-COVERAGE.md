# Firecrawl tool stress-test coverage

All live probes use public BUB1B and mosaic-variegated-aneuploidy material. No
subject VCF, phenotype narrative, or other gated competition data is sent to a
service.

| Tool group | Result after fixes | Regression evidence |
|---|---|---|
| `search` | Non-empty grouped web results; provider outages return 503 rather than false success | `live-smoke.mjs`, `mcp-search-response.mjs` |
| `scrape` | Public genetics page returns substantive BUB1B content; access interstitials are rejected | `live-smoke.mjs`, reliability transformer test |
| `map` | Returns non-empty genetics links | `live-smoke.mjs` |
| `crawl`, `check_crawl_status` | One-page crawl completes and never reports negative credits | `live-smoke.mjs` |
| paper search/inspect | Returns real MVA/BUB1B papers; OpenAlex throttling retries then falls back to Crossref | `live-smoke.mjs`, `test_main.py` |
| paper read | Open-access retrieval works; institutional retrieval is opt-in, cookie-scoped, byte/page-bounded, and rejects login HTML | `live-smoke.mjs`, `test_main.py` |
| related papers | Routed through the healthy research service; upstream quotas remain external | `live-smoke.mjs` |
| GitHub/developer search | Healthy research service returns results | `live-smoke.mjs`, initial MCP stress probe |
| `agent`, `agent_status` | Public-source job completed with real `creditsUsed: 1`, replacing the hard-coded 20 | live post-fix probe plus API TypeScript build |
| `extract` | Deprecated upstream and hidden rather than advertised as working | capability regression |
| `parse` | In-memory public HTML fixture parses to BUB1B markdown; some clients may filter local-file tools | `live-smoke.mjs`, capability regression |
| feedback, search feedback, interact, monitor tools | Require self-hosted database infrastructure and are hidden by default instead of failing at call time | `mcp-local-capabilities.mjs` |
| screenshot/actions/branding | Screenshot/actions require Fire Engine in this stack; branding is unavailable without it | capability documentation and initial MCP stress probe |

`run-mcp-regressions.sh` tests every cached MCP installation and asserts the
complete 14-tool local surface, not merely a sample.
