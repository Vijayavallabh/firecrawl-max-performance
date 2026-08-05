# Quick Start — Firecrawl Self-Host

```bash
# 1. Run setup (clones Firecrawl, applies all patches, creates .env)
./setup.sh

# 2. Edit .env with your API keys
nano .env
#   Required: OPENAI_API_KEY, SEARXNG_SECRET, POSTGRES_PASSWORD

# 3. Build and start all services
./setup.sh --start

# 4. Copy opencode MCP config
cp config/opencode.json ~/.config/opencode/config.json

# 5. Restart opencode, then patch MCP server limits
./patch-mcp.sh

# 6. Restart opencode again — all 13 features are ready
```

See `README.md` for full documentation, troubleshooting, and performance tuning.
