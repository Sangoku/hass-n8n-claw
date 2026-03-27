# Changelog

All notable changes to this project will be documented in this file.

## [1.0.2] - 2026-03-27

### Changed
- **LLM provider is now OpenAI-compatible** — no longer locked to Anthropic/Claude
  - `anthropic_api_key` config option replaced with `llm_api_key` + `llm_base_url` + `llm_model`
  - Works with OpenAI, LiteLLM, Ollama, OpenRouter, or any OpenAI-compatible endpoint
  - n8n LangChain nodes changed from `lmChatAnthropic` to `lmChatOpenAi` with configurable `baseUrl`
  - Heartbeat and Memory Consolidation code nodes now call `{base_url}/chat/completions` (OpenAI format)
  - `tools_config` DB entry renamed from `anthropic` to `llm` with `{api_key, base_url, model}` shape
- DB migration `003_llm_config.sql` added — upgrades existing installs automatically

## [1.0.1] - 2026-03-27

### Changed
- Telegram is now optional and configured inside the n8n workflow UI (n8n → Credentials → Telegram Bot). `telegram_bot_token` and `telegram_chat_id` have been removed from the addon config options.

### Removed
- `postgrest_jwt_secret` option — PostgREST is internal-only; JWT auth is not needed
- `telegram_bot_token` and `telegram_chat_id` addon config options — configure Telegram directly in the n8n workflow

## [1.0.0] - 2026-03-23

### Added
- Initial release of hass-n8n-claw Home Assistant addon
- n8n workflow automation engine with HA Ingress support (port 5690)
- PostgREST REST API over PostgreSQL (internal, port 3000)
- Automatic database migration on first boot (db-init)
- Automatic workflow import on first boot (11 n8n-claw workflows)
- Automatic Home Assistant integration (creates automations + notification)
- Credential auto-creation (Telegram, Anthropic, PostgREST, HA)
- Webhook port 8081 for external integrations (Telegram, etc.)
- MCP (Model Context Protocol) SSE support via nginx
- Community n8n nodes: homeassistantws, litellm
- Sentinel-based idempotent boot sequence
- Dev environment with docker-compose for local testing

### Workflows included
- n8n-claw-agent (main AI agent)
- ha-bridge (HA ↔ agent bridge)
- heartbeat (proactive check-ins)
- memory-consolidation (daily memory summarization)
- reminder-factory + reminder-runner (reminder system)
- mcp-builder + mcp-client + mcp-library-manager (MCP tools)
- workflow-builder (self-modification)
- credential-form (API key management)
