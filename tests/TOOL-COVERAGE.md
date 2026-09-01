# Firecrawl tool stress-test coverage

All live probes use public BUB1B and mosaic-variegated-aneuploidy material. No
subject VCF, phenotype narrative, or other gated competition data is sent to a
service.

| Tool group | Result after fixes | Regression evidence |
|---|---|---|
| `search` | Non-empty grouped web results; provider outages return 503 rather than false success | `live-smoke.mjs`, `mcp-search-response.mjs` |
| `scrape` | Public genetics page returns substantive BUB1B content; access interstitials are rejected | `live-smoke.mjs`, `defect-regressions.mjs` |
| `map` | Returns non-empty genetics links | `live-smoke.mjs` |
| `crawl`, `check_crawl_status` | One-page crawl completes and never reports negative credits | `live-smoke.mjs` |
| paper search/inspect | Returns real MVA/BUB1B papers; OpenAlex throttling retries then falls back to Crossref | `live-smoke.mjs`, `test_main.py` |
| paper read | Open-access retrieval works; institutional retrieval is opt-in, cookie-scoped, byte/page-bounded, and rejects login HTML | `live-smoke.mjs`, `test_main.py` |
| related papers | Routed through the healthy research service; upstream quotas remain external | `live-smoke.mjs` |
| GitHub/developer search | Healthy research service returns results | `live-smoke.mjs`, initial MCP stress probe |
| `agent`, `agent_status` | Structured public-source job completes on `accounts/fireworks/models/deepseek-v4-flash-0731` with real credit accounting | `mcp-live-tools.mjs`, API TypeScript build |
| `extract` | Deprecated upstream and hidden rather than advertised as working | capability regression |
| `parse` | In-memory public HTML fixture parses to BUB1B markdown; some clients may filter local-file tools | `live-smoke.mjs`, capability regression |
| feedback and search feedback | Both persist against local PostgreSQL and return feedback IDs | `mcp-live-tools.mjs` |
| interact and interact stop | Public BUB1B page opens, returns its live title, and tears down cleanly | `mcp-live-tools.mjs` |
| all eight monitor tools | Create/list/get/update/run/check/list-checks/delete lifecycle completes with a retained page result | `mcp-live-tools.mjs` |
| screenshot/actions/branding | Screenshot/actions require Fire Engine in this stack; branding is unavailable without it | capability documentation and initial MCP stress probe |

`run-mcp-regressions.sh` tests every cached MCP installation in both persistence
modes. `mcp-live-tools.mjs` then executes every one of the 26 tools advertised
by the persistent local stack; deprecated `extract` remains intentionally hidden.
