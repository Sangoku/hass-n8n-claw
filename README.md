# hass-n8n-claw

**n8n-claw AI agent as a Home Assistant addon.**

This addon packages the [n8n-claw](../n8n-claw/) AI agent stack into a single Home Assistant addon container. It includes:

- **n8n** — workflow automation engine (via HA Ingress on port 5690)
- **PostgREST** — REST API over PostgreSQL (internal, port 3000)
- **db-init** — one-shot migration runner (runs on first boot)
- **workflow-import** — auto-imports all n8n-claw workflows on first boot

Database is provided by the **Expaso TimescaleDB** HA addon (peer addon — separate container).

---

## Prerequisites

1. **Expaso TimescaleDB addon** must be installed and running
   - Install from: `ghcr.io/expaso/timescaledb`
   - Configure a database named `n8n-claw` (or use `postgres`)
   - Ensure `pgvector` and `uuid-ossp` extensions are available
   - Expose port `5432` on the host
   - Allow connections from `172.30.32.0/24` in `pg_hba_config`

2. **Anthropic API key** (for Claude AI — the agent's brain)

3. **Telegram Bot token + chat ID** (for the Telegram interface)

---

## Installation

### Option A: Local addon (recommended for development)

1. Copy this `hass-n8n-claw/` directory to your HA `/addons/` folder (via Samba or SSH)
2. In HA → Settings → Add-ons → Add-on Store → ⋮ → Check for updates
3. Find "n8n-claw" under Local add-ons and install it

### Option B: Repository

Add this repository URL to HA → Settings → Add-ons → Add-on Store → ⋮ → Repositories.

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `timezone` | `Europe/Berlin` | Timezone for n8n scheduler |
| `db_host` | `172.30.32.1` | TimescaleDB addon host (HA gateway IP) |
| `db_port` | `5432` | TimescaleDB addon port |
| `db_name` | `n8n-claw` | Database name |
| `db_user` | `postgres` | Database user |
| `db_password` | _(required)_ | Database password |
| `postgrest_jwt_secret` | _(optional)_ | JWT secret for PostgREST auth. If empty, PostgREST runs without auth (safe — internal only) |
| `telegram_bot_token` | _(optional)_ | Telegram bot token for the agent interface |
| `telegram_chat_id` | _(optional)_ | Your Telegram chat ID |
| `anthropic_api_key` | _(optional)_ | Anthropic API key (Claude) |
| `n8n_encryption_key` | _(optional)_ | n8n encryption key. Auto-generated if empty (persisted in `/data/n8n-claw/.n8n/`) |
| `n8n_webhook_url` | _(optional)_ | External webhook URL (e.g. `https://your-ha.duckdns.org:8081`) |
| `env_vars_list` | `[]` | Additional environment variables in `KEY: value` format |
| `cmd_line_args` | _(optional)_ | Extra CLI args passed to `n8n` |

### Important: N8N_API_KEY

The workflow import script needs an n8n API key to import workflows. Set it via `env_vars_list`:

```yaml
env_vars_list:
  - "N8N_API_KEY: your-n8n-api-key-here"
```

You can generate an API key in n8n UI → Settings → API → Create API Key, then restart the addon.

Alternatively, the import script will attempt to create one via `n8n api-key:create` on first boot.

---

## First Boot Sequence

On first start, the addon runs these steps automatically:

1. **db-init** — waits for TimescaleDB, runs SQL migrations (`000_extensions.sql`, `001_schema.sql`, `002_seed.sql`), writes sentinel `/data/n8n-claw/.initialized`
2. **PostgREST** — starts on `:3000`, connects to TimescaleDB
3. **n8n** — starts on `:5678`, connects to TimescaleDB for its own tables
4. **nginx** — starts on `:5690`, proxies to n8n (HA Ingress)
5. **workflow-import** — waits for n8n API, creates credentials, imports 11 workflows, patches cross-references, activates workflows, writes sentinel `/data/n8n-claw/.workflows_imported`

Subsequent boots skip db-init and workflow-import (sentinels present).

On first boot, step 6 also runs:

6. **ha-integration** — calls the HA Supervisor API to auto-configure Home Assistant (see below), writes sentinel `/data/n8n-claw/.ha_integrated`

---

## Home Assistant Integration

On first boot, the addon **automatically configures Home Assistant** to call the n8n-claw agent. No manual YAML editing required.

### What gets auto-created

| HA Entity | Purpose |
|-----------|---------|
| `automation.n8n_claw_call_agent` | Fires on `n8n_claw_call_agent` events — routes them to the agent webhook |
| `automation.n8n_claw_motion_example` | Sample motion-triggered automation (disabled by default — enable and customize) |
| Persistent notification | Confirms the agent is ready and shows the webhook URL |

### Calling the agent from any HA automation

After install, fire the `n8n_claw_call_agent` event from any automation or script:

```yaml
# In any HA automation action:
- event: n8n_claw_call_agent
  event_data:
    message: "Motion detected in kitchen. Should I turn on the lights?"
    session_id: "ha:kitchen_motion"
    context:
      entity_id: "binary_sensor.kitchen_motion"
      state: "on"
```

Or from **Developer Tools → Events** in the HA UI — fire `n8n_claw_call_agent` with the above data to test it immediately.

### Webhook interface (direct)

The agent also listens directly at `http://[HA_HOST]:8081/webhook/ha-agent`:

```bash
curl -X POST http://192.168.0.26:8081/webhook/ha-agent \
  -H "Content-Type: application/json" \
  -d '{"message": "What is the weather like?", "session_id": "ha:test"}'
```

The agent processes the message and replies via Telegram (or the configured channel).

### Re-run HA integration

To re-apply the HA auto-config (e.g. after HA restart):

```bash
# In HA terminal / SSH addon:
rm /data/addon_configs/hass-n8n-claw/n8n-claw/.ha_integrated
# Then restart the addon
```

---

## Ports

| Port | Purpose |
|---|---|
| `5690` | HA Ingress (nginx → n8n) — use this to access n8n UI |
| `8081` | n8n webhook/API port for external traffic (Telegram webhooks, etc.) |
| `3000` | PostgREST (internal only — not exposed outside the container) |

---

## Architecture

```
Home Assistant OS
  ├── Expaso TimescaleDB Addon  (peer addon)
  │     └── PostgreSQL :5432 on 172.30.32.1
  │           ├── n8n internal tables
  │           └── n8n-claw tables (soul, agents, conversations, memory, etc.)
  │
  └── hass-n8n-claw Addon (this addon)
        ├── supervisord
        │     ├── db-init (one-shot, priority 10)
        │     ├── postgrest :3000 (priority 20)
        │     ├── n8n :5678 (priority 30)
        │     ├── nginx :5690 (priority 40)
        │     ├── workflow-import (one-shot, priority 50)
        │     └── ha-integration (one-shot, priority 60)
        │
        └── /data/n8n-claw/
              ├── .n8n/          (n8n config, credentials, encryption key)
              ├── .initialized        (db-init sentinel)
              ├── .workflows_imported (workflow-import sentinel)
              └── .ha_integrated      (ha-integration sentinel)
```

---

## Troubleshooting

### db-init fails / times out
- Check that the Expaso TimescaleDB addon is running
- Verify `db_host` is `172.30.32.1` (or the correct HA gateway IP)
- Verify `db_port`, `db_user`, `db_password` match the TimescaleDB addon config
- Check TimescaleDB addon logs for connection errors

### workflow-import fails with "API key invalid"
- Set `N8N_API_KEY` in `env_vars_list` (generate in n8n UI → Settings → API)
- Restart the addon

### Workflows not activating
- Some workflows require credentials to be set before activation
- Set `telegram_bot_token`, `anthropic_api_key` in the addon config
- Restart the addon to re-run workflow-import (delete `/data/n8n-claw/.workflows_imported` first)

### Re-run workflow import
To force re-import of workflows (e.g. after updating):
```bash
# In HA terminal / SSH addon:
rm /data/addon_configs/hass-n8n-claw/n8n-claw/.workflows_imported
# Then restart the addon
```

### Re-run db migrations
To force re-run of migrations (e.g. after schema update):
```bash
rm /data/addon_configs/hass-n8n-claw/n8n-claw/.initialized
# Then restart the addon
```

---

## Optional Services

These services from the original n8n-claw stack are **not included** in this addon but can run as separate Docker containers on the HA host:

- **crawl4ai** — web scraping for the agent
- **searxng** — private search engine
- **email-bridge** — SMTP/IMAP bridge

See [n8n-claw README](../n8n-claw/README.md) for setup instructions.
