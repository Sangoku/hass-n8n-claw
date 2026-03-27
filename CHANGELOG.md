# Changelog

All notable changes to this project will be documented in this file.

## [1.0.1] - 2026-03-27

### Removed
- `postgrest_jwt_secret` option — PostgREST is internal-only; JWT auth is not needed

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
