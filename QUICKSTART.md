# Quick Start — Firecrawl Self-Host

```bash
# 1. Run setup (clones a pinned Firecrawl revision and applies all patches)
./setup.sh

# 2. Edit .env with your API keys
nano .env
#   Required: OPENAI_API_KEY (or Ollama), POSTGRES_PASSWORD
#   setup.sh generates local service secrets and protects .env with mode 0600

# 3. Build and start all services; PostgreSQL schema is a startup dependency
./setup.sh --start

# 4. Merge config/opencode.json into the active
#    ~/.config/opencode/opencode.json or opencode.jsonc (do not overwrite it)

# 5. Restart opencode, then patch MCP server limits
./patch-mcp.sh

# 6. Restart opencode again; verify with `opencode debug config` and
#    `opencode mcp list`
```

See `README.md` for full documentation, the tool capability matrix, optional
IITM journal-access safeguards, troubleshooting, and performance tuning.
