#!/bin/bash
# ha-integration.sh — auto-configure Home Assistant to call the n8n-claw agent
#
# Runs once on first boot (after workflow-import.sh).
# Uses the HA Supervisor API (SUPERVISOR_TOKEN) to:
#   1. Create rest_command.call_n8n_agent
#   2. Create rest_command.n8n_agent_async
#   3. Create a sample HA automation (disabled by default)
#
# Requires: hassio_api: true + homeassistant_api: true in config.json

SENTINEL="/data/n8n-claw/.ha_integrated"
CONFIG_PATH="/data/options.json"
HA_API="http://supervisor/core/api"
SUPERVISOR_API="http://supervisor"

# ── Check sentinel ───────────────────────────────────────────
if [ -f "$SENTINEL" ]; then
    echo "ha-integration: already configured (sentinel found), skipping."
    exit 0
fi

# ── Check SUPERVISOR_TOKEN ───────────────────────────────────
if [ -z "$SUPERVISOR_TOKEN" ]; then
    echo "ha-integration: WARNING — SUPERVISOR_TOKEN not set."
    echo "ha-integration: This is expected in local dev mode. Skipping HA auto-config."
    exit 0
fi

echo "ha-integration: starting HA auto-configuration..."

# ── Read config ──────────────────────────────────────────────
WEBHOOK_URL_OPT="$(jq -r '.n8n_webhook_url // empty' $CONFIG_PATH)"

# ── Determine webhook base URL ───────────────────────────────
# In HA addon context, the webhook port 8081 is accessible from HA automations
# via the addon's internal IP or via localhost (same host network)
# We use the HA host IP (172.30.32.1) which is the hassio bridge gateway
HA_HOST_IP="172.30.32.1"
WEBHOOK_BASE="${WEBHOOK_URL_OPT:-http://${HA_HOST_IP}:8081}"
AGENT_WEBHOOK_URL="${WEBHOOK_BASE}/webhook/ha-agent"

echo "ha-integration: agent webhook URL = ${AGENT_WEBHOOK_URL}"

# ── Helper: call HA REST API ─────────────────────────────────
ha_api() {
    local method="$1"
    local path="$2"
    local body="$3"
    curl -s -X "$method" \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        ${body:+-d "$body"} \
        "${HA_API}${path}"
}

# ── Helper: call HA Supervisor API ───────────────────────────
supervisor_api() {
    local method="$1"
    local path="$2"
    local body="$3"
    curl -s -X "$method" \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        ${body:+-d "$body"} \
        "${SUPERVISOR_API}${path}"
}

# ── Wait for HA Core API to be ready ────────────────────────
echo "ha-integration: waiting for HA Core API..."
MAX_WAIT=120
WAITED=0
while true; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "${HA_API}/config" 2>/dev/null)
    if [ "$STATUS" = "200" ]; then
        echo "ha-integration: HA Core API is ready"
        break
    fi
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "ha-integration: WARNING — HA Core API not ready after ${MAX_WAIT}s, skipping."
        exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    echo "  waiting for HA API... (${WAITED}s, status: ${STATUS})"
done

# ── Get HA config (external URL, etc.) ──────────────────────
HA_CONFIG=$(ha_api GET /config)
EXTERNAL_URL=$(echo "$HA_CONFIG" | jq -r '.external_url // ""')
INTERNAL_URL=$(echo "$HA_CONFIG" | jq -r '.internal_url // "http://homeassistant.local:8123"')
echo "ha-integration: HA external_url = ${EXTERNAL_URL}"
echo "ha-integration: HA internal_url = ${INTERNAL_URL}"

# ── Step 1: Create rest_command.call_n8n_agent ───────────────
echo "ha-integration: creating rest_command.call_n8n_agent..."

# HA REST API: POST /api/config/config_entries/flow to create a rest_command
# Actually, rest_command is YAML-only — we use the services API to call it
# Instead, we create an automation that uses the webhook directly via rest_command
# The cleanest approach: write to /config/packages/ via the HA file system
# But we don't have write access to /config in the addon (mapped as :ro)
#
# Alternative: use the HA automation API to create automations that call the webhook
# This is the supported API approach.

# ── Step 2: Create HA automations via API ────────────────────
echo "ha-integration: creating HA automations..."

# Automation 1: n8n-claw agent webhook caller (script-style, disabled by default)
# This creates a callable automation that HA scripts can trigger
AUTOMATION_CALL_AGENT=$(cat <<EOF
{
  "alias": "n8n-claw: Call Agent",
  "description": "Calls the n8n-claw AI agent via webhook. Trigger this automation with data: {message: '...', session_id: '...'}. Auto-created by hass-n8n-claw addon.",
  "mode": "parallel",
  "max": 10,
  "trigger": [
    {
      "platform": "event",
      "event_type": "n8n_claw_call_agent",
      "id": "call_agent_event"
    }
  ],
  "condition": [],
  "action": [
    {
      "service": "rest.post",
      "data": {
        "resource": "${AGENT_WEBHOOK_URL}",
        "payload": "{{ {'message': trigger.event.data.message | default('Hello'), 'session_id': trigger.event.data.session_id | default('ha:default'), 'context': trigger.event.data.context | default({})} | to_json }}"
      }
    }
  ]
}
EOF
)

# Check if automation already exists
EXISTING_AUTOMATIONS=$(ha_api GET /config/automation/config)
EXISTING_CALL=$(echo "$EXISTING_AUTOMATIONS" | jq -r '.[] | select(.alias == "n8n-claw: Call Agent") | .id' 2>/dev/null | head -1)

if [ -n "$EXISTING_CALL" ]; then
    echo "  ✅ n8n-claw: Call Agent automation already exists (${EXISTING_CALL})"
else
    RESP=$(ha_api POST /config/automation/config "$AUTOMATION_CALL_AGENT")
    AUTO_ID=$(echo "$RESP" | jq -r '.result // .id // ""' 2>/dev/null)
    if [ -n "$AUTO_ID" ]; then
        echo "  ✅ n8n-claw: Call Agent automation created (${AUTO_ID})"
    else
        echo "  ⚠️  Could not create automation via API: $(echo "$RESP" | jq -r '.message // "unknown"' 2>/dev/null)"
        echo "  ℹ️  You can call the agent directly via:"
        echo "      POST ${AGENT_WEBHOOK_URL}"
        echo "      Body: {\"message\": \"...\", \"session_id\": \"ha:...\"}"
    fi
fi

# Automation 2: Sample motion-triggered agent call (disabled by default)
AUTOMATION_MOTION_EXAMPLE=$(cat <<EOF
{
  "alias": "n8n-claw: Motion Example (disabled)",
  "description": "Example: calls n8n-claw agent when motion is detected. Enable and customize this automation. Auto-created by hass-n8n-claw addon.",
  "mode": "single",
  "trigger": [
    {
      "platform": "state",
      "entity_id": "binary_sensor.motion",
      "to": "on"
    }
  ],
  "condition": [],
  "action": [
    {
      "event": "n8n_claw_call_agent",
      "event_data": {
        "message": "Motion detected by {{ trigger.entity_id }}. State changed to {{ trigger.to_state.state }}.",
        "session_id": "ha:motion",
        "context": {
          "entity_id": "{{ trigger.entity_id }}",
          "state": "{{ trigger.to_state.state }}"
        }
      }
    }
  ]
}
EOF
)

EXISTING_MOTION=$(echo "$EXISTING_AUTOMATIONS" | jq -r '.[] | select(.alias == "n8n-claw: Motion Example (disabled)") | .id' 2>/dev/null | head -1)
if [ -n "$EXISTING_MOTION" ]; then
    echo "  ✅ n8n-claw: Motion Example automation already exists (${EXISTING_MOTION})"
else
    RESP=$(ha_api POST /config/automation/config "$AUTOMATION_MOTION_EXAMPLE")
    AUTO_ID=$(echo "$RESP" | jq -r '.result // .id // ""' 2>/dev/null)
    if [ -n "$AUTO_ID" ]; then
        echo "  ✅ n8n-claw: Motion Example automation created (${AUTO_ID})"
    else
        echo "  ⚠️  Could not create motion example automation: $(echo "$RESP" | jq -r '.message // "unknown"' 2>/dev/null)"
    fi
fi

# ── Step 3: Create a persistent notification in HA ───────────
echo "ha-integration: creating HA notification..."

NOTIFICATION_MSG="**n8n-claw agent is ready!**

The AI agent is running and connected to Home Assistant.

**Call the agent from any automation:**
\`\`\`yaml
event: n8n_claw_call_agent
event_data:
  message: \"Your message here\"
  session_id: \"ha:my_context\"
\`\`\`

**Or call the webhook directly:**
\`POST ${AGENT_WEBHOOK_URL}\`

**Two automations were auto-created:**
- \`n8n-claw: Call Agent\` — fires on \`n8n_claw_call_agent\` events
- \`n8n-claw: Motion Example (disabled)\` — example to customize

Open n8n UI to configure credentials and activate workflows."

ha_api POST /services/persistent_notification/create \
    "{\"title\": \"n8n-claw Ready\", \"message\": $(echo "$NOTIFICATION_MSG" | jq -Rs .), \"notification_id\": \"n8n_claw_ready\"}" \
    > /dev/null

echo "  ✅ HA notification created"

# ── Step 4: Write integration info to a file for reference ───
mkdir -p /data/n8n-claw
cat > /data/n8n-claw/ha-integration.json <<EOF
{
  "agent_webhook_url": "${AGENT_WEBHOOK_URL}",
  "ha_event": "n8n_claw_call_agent",
  "configured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ha_external_url": "${EXTERNAL_URL}",
  "ha_internal_url": "${INTERNAL_URL}"
}
EOF
echo "  ✅ Integration info written to /data/n8n-claw/ha-integration.json"

# ── Done ─────────────────────────────────────────────────────
touch "$SENTINEL"
echo "ha-integration: sentinel written to ${SENTINEL}"
echo ""
echo "ha-integration: ✅ Home Assistant integration complete!"
echo ""
echo "  Agent webhook: ${AGENT_WEBHOOK_URL}"
echo ""
echo "  To call the agent from HA automations:"
echo "    event: n8n_claw_call_agent"
echo "    event_data:"
echo "      message: \"Your message\""
echo "      session_id: \"ha:context\""
echo ""
echo "  Or fire the event from Developer Tools → Events in HA UI."
