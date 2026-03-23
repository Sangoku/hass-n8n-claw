#!/bin/bash
# workflow-import.sh — imports n8n-claw workflows into n8n on first boot
# Uses jq for all JSON operations (no python3 required on Alpine).
# Runs after n8n is fully up. Idempotent: upserts workflows by name.

SENTINEL="/data/n8n-claw/.workflows_imported"
CONFIG_PATH="/data/options.json"
N8N_BASE="http://localhost:5678"
WORKDIR="/tmp/wf-deploy"

# ── Read config ──────────────────────────────────────────────
TELEGRAM_BOT_TOKEN="$(jq -r '.telegram_bot_token // empty' $CONFIG_PATH)"
TELEGRAM_CHAT_ID="$(jq -r '.telegram_chat_id // empty' $CONFIG_PATH)"
ANTHROPIC_API_KEY="$(jq -r '.anthropic_api_key // empty' $CONFIG_PATH)"
DB_HOST="$(jq -r '.db_host // "172.30.32.1"' $CONFIG_PATH)"
DB_PORT="$(jq -r '.db_port // 5432' $CONFIG_PATH)"
DB_NAME="$(jq -r '.db_name // "n8n-claw"' $CONFIG_PATH)"
DB_USER="$(jq -r '.db_user // "postgres"' $CONFIG_PATH)"
DB_PASSWORD="$(jq -r '.db_password // empty' $CONFIG_PATH)"
WEBHOOK_URL_OPT="$(jq -r '.n8n_webhook_url // empty' $CONFIG_PATH)"

# ── Wait for n8n API ─────────────────────────────────────────
echo "workflow-import: waiting for n8n API at ${N8N_BASE}..."
MAX_WAIT=300
WAITED=0
while true; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${N8N_BASE}/healthz" 2>/dev/null)
    if [ "$STATUS" = "200" ]; then
        echo "workflow-import: n8n is up (healthz OK)"
        break
    fi
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "workflow-import: ERROR — n8n did not start within ${MAX_WAIT}s"
        exit 1
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    echo "  waiting for n8n... (${WAITED}s)"
done

# ── Get or create n8n API key ────────────────────────────────
# Works with n8n v1 and v2 via session-based REST API
N8N_API_KEY_FILE="/data/n8n-claw/.n8n_api_key"
N8N_OWNER_EMAIL="$(jq -r '.n8n_owner_email // "admin@n8n-claw.local"' $CONFIG_PATH)"
N8N_OWNER_PASSWORD="$(jq -r '.n8n_owner_password // "n8nclaw123"' $CONFIG_PATH)"

if [ -f "$N8N_API_KEY_FILE" ]; then
    N8N_API_KEY=$(cat "$N8N_API_KEY_FILE")
    echo "workflow-import: using stored API key"
else
    # Create API key via session-based REST API
    # Step 1: Login to get session cookie
    COOKIE_JAR="/tmp/n8n-session-cookies.txt"
    LOGIN_RESP=$(curl -s -c "$COOKIE_JAR" -X POST "${N8N_BASE}/rest/login" \
        -H "Content-Type: application/json" \
        -d "{\"emailOrLdapLoginId\":\"${N8N_OWNER_EMAIL}\",\"password\":\"${N8N_OWNER_PASSWORD}\"}" 2>/dev/null)
    LOGIN_ID=$(echo "$LOGIN_RESP" | jq -r '.data.id // ""' 2>/dev/null)

    if [ -z "$LOGIN_ID" ]; then
        echo "workflow-import: WARNING — could not login to n8n (email: ${N8N_OWNER_EMAIL})"
        echo "workflow-import: trying env var N8N_API_KEY..."
        if [ -z "$N8N_API_KEY" ]; then
            echo "workflow-import: ERROR — no API key available. Check n8n_owner_email/password in addon config."
            exit 1
        fi
    else
        # Step 2: Create API key via session
        # n8n v2 requires scopes and expiresAt; n8n v1 uses /rest/api-key without scopes
        EXPIRES_AT=$(( $(date +%s) * 1000 + 315360000000 ))  # 10 years from now
        ALL_SCOPES='["workflow:read","workflow:write","workflow:create","workflow:delete","workflow:execute","credential:read","credential:write","credential:create","credential:delete","credential:list","credential:move","tag:read","tag:create","tag:update","tag:delete","tag:list","user:read","user:create","user:update","user:delete","user:list","user:changeRole","variable:read","variable:write","variable:create","variable:delete","variable:list","sourceControl:pull","securityAudit:generate","project:read","project:create","project:update","project:delete","project:list"]'

        # Delete any existing key with the same label (n8n v2 doesn't allow duplicates)
        EXISTING_KEY_ID=$(curl -s -b "$COOKIE_JAR" "${N8N_BASE}/rest/api-keys" 2>/dev/null | \
            jq -r '.data[] | select(.label=="workflow-import") | .id' 2>/dev/null | head -1)
        if [ -n "$EXISTING_KEY_ID" ]; then
            curl -s -b "$COOKIE_JAR" -X DELETE "${N8N_BASE}/rest/api-keys/${EXISTING_KEY_ID}" > /dev/null 2>&1
            echo "workflow-import: deleted existing API key (id: ${EXISTING_KEY_ID})"
        fi

        # Try n8n v2 endpoint first (/rest/api-keys with scopes)
        APIKEY_RESP=$(curl -s -b "$COOKIE_JAR" -X POST "${N8N_BASE}/rest/api-keys" \
            -H "Content-Type: application/json" \
            -d "{\"label\":\"workflow-import\",\"scopes\":${ALL_SCOPES},\"expiresAt\":${EXPIRES_AT}}" 2>/dev/null)
        N8N_API_KEY=$(echo "$APIKEY_RESP" | jq -r '.data.rawApiKey // .data.apiKey // ""' 2>/dev/null)

        if [ -z "$N8N_API_KEY" ] || [ "$N8N_API_KEY" = "null" ]; then
            # Fallback: n8n v1 endpoint (/rest/api-key without scopes)
            APIKEY_RESP=$(curl -s -b "$COOKIE_JAR" -X POST "${N8N_BASE}/rest/api-key" \
                -H "Content-Type: application/json" \
                -d '{"label":"workflow-import"}' 2>/dev/null)
            N8N_API_KEY=$(echo "$APIKEY_RESP" | jq -r '.data.apiKey // .apiKey // ""' 2>/dev/null)
        fi

        if [ -n "$N8N_API_KEY" ] && [ "$N8N_API_KEY" != "null" ]; then
            echo "$N8N_API_KEY" > "$N8N_API_KEY_FILE"
            chmod 600 "$N8N_API_KEY_FILE"
            echo "workflow-import: API key created and stored"
        else
            echo "workflow-import: WARNING — could not create API key via session REST API"
            echo "workflow-import: v2 response: $(echo "$APIKEY_RESP" | head -c 200)"
            if [ -z "$N8N_API_KEY" ] || [ "$N8N_API_KEY" = "null" ]; then
                echo "workflow-import: ERROR — no API key available."
                exit 1
            fi
        fi
    fi
fi

# Verify API key works
API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    "${N8N_BASE}/api/v1/workflows" 2>/dev/null)
if [ "$API_STATUS" != "200" ]; then
    echo "workflow-import: ERROR — API key invalid (status: ${API_STATUS})"
    echo "workflow-import: Set N8N_API_KEY in env_vars_list and restart the addon"
    exit 1
fi
echo "workflow-import: API key verified (status: ${API_STATUS})"

# ── Check sentinel ───────────────────────────────────────────
if [ -f "$SENTINEL" ]; then
    echo "workflow-import: already imported (sentinel found), skipping."
    exit 0
fi

echo "workflow-import: starting workflow import..."

# ── Prepare working directory ────────────────────────────────
mkdir -p "$WORKDIR"

# ── Determine SUPABASE_URL (PostgREST internal) ──────────────
SUPABASE_URL="http://localhost:3000"

# ── Determine N8N_URL ────────────────────────────────────────
N8N_URL="${WEBHOOK_URL_OPT:-http://localhost:5678}"

# ── Extract credential-form webhookId (used by Library Manager) ──
CREDENTIAL_FORM_WEBHOOK_ID=""
if [ -f "/app/workflows/credential-form.json" ]; then
    CREDENTIAL_FORM_WEBHOOK_ID=$(jq -r '[.nodes[] | select(.webhookId != null) | .webhookId][0] // ""' \
        /app/workflows/credential-form.json 2>/dev/null)
fi
echo "workflow-import: credential-form webhookId = ${CREDENTIAL_FORM_WEBHOOK_ID}"

# ── Step 1: Create credentials ───────────────────────────────
echo "workflow-import: creating credentials..."

# Helper: create credential if it doesn't already exist
create_cred_if_missing() {
    local cred_type="$1"
    local cred_name="$2"
    local cred_data="$3"

    # Check if already exists
    EXISTING_ID=$(curl -s "${N8N_BASE}/api/v1/credentials" \
        -H "X-N8N-API-KEY: ${N8N_API_KEY}" | \
        jq -r --arg t "$cred_type" '.data[] | select(.type==$t) | .id' 2>/dev/null | head -1)

    if [ -n "$EXISTING_ID" ]; then
        echo "  ✅ ${cred_name} → ${EXISTING_ID} (existing)"
        echo "$EXISTING_ID"
        return
    fi

    RESP=$(curl -s -X POST "${N8N_BASE}/api/v1/credentials" \
        -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${cred_name}\",\"type\":\"${cred_type}\",\"data\":${cred_data}}")
    NEW_ID=$(echo "$RESP" | jq -r '.id // ""' 2>/dev/null)
    if [ -n "$NEW_ID" ]; then
        echo "  ✅ ${cred_name} → ${NEW_ID} (created)"
    else
        echo "  ⚠️  ${cred_name}: failed — $(echo "$RESP" | jq -r '.message // "unknown error"' 2>/dev/null)"
    fi
    echo "$NEW_ID"
}

# Telegram credential
TELEGRAM_CRED_ID=""
if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    TELEGRAM_CRED_ID=$(create_cred_if_missing "telegramApi" "Telegram Bot" \
        "{\"accessToken\":\"${TELEGRAM_BOT_TOKEN}\"}" | tail -1)
fi

# Postgres credential (points to TimescaleDB addon via host gateway)
POSTGRES_CRED_ID=$(create_cred_if_missing "postgres" "Supabase Postgres" \
    "{\"host\":\"${DB_HOST}\",\"database\":\"${DB_NAME}\",\"user\":\"${DB_USER}\",\"password\":\"${DB_PASSWORD}\",\"port\":${DB_PORT},\"ssl\":\"disable\",\"allowUnauthorizedCerts\":true,\"sshTunnel\":false}" | tail -1)

# Anthropic credential
ANTHROPIC_CRED_ID=""
if [ -n "$ANTHROPIC_API_KEY" ]; then
    ANTHROPIC_CRED_ID=$(create_cred_if_missing "anthropicApi" "Anthropic API" \
        "{\"apiKey\":\"${ANTHROPIC_API_KEY}\"}" | tail -1)
fi

echo "workflow-import: credentials done."
echo "  Telegram:  ${TELEGRAM_CRED_ID:-not set}"
echo "  Postgres:  ${POSTGRES_CRED_ID:-not set}"
echo "  Anthropic: ${ANTHROPIC_CRED_ID:-not set}"

# ── Step 2: Prepare workflow files (placeholder replacement) ──
echo "workflow-import: preparing workflow files..."

for src in /app/workflows/*.json; do
    name=$(basename "$src" .json)
    dst="${WORKDIR}/${name}.json"
    cp "$src" "$dst"

    # Replace all placeholders using sed (safe for string values in JSON)
    sed -i \
        -e "s|{{N8N_URL}}|${N8N_URL}|g" \
        -e "s|{{N8N_INTERNAL_URL}}|http://localhost:5678|g" \
        -e "s|{{N8N_API_KEY}}|${N8N_API_KEY}|g" \
        -e "s|{{SUPABASE_URL}}|${SUPABASE_URL}|g" \
        -e "s|{{SUPABASE_SERVICE_KEY}}||g" \
        -e "s|{{SUPABASE_ANON_KEY}}||g" \
        -e "s|{{TELEGRAM_CHAT_ID}}|${TELEGRAM_CHAT_ID}|g" \
        -e "s|{{CREDENTIAL_FORM_WEBHOOK_ID}}|${CREDENTIAL_FORM_WEBHOOK_ID}|g" \
        "$dst"

    # Replace credential ID placeholders — use real ID if available, else clear placeholder
    # (leaving REPLACE_WITH_YOUR_CREDENTIAL_ID causes activation failure in n8n)
    TELE_REPLACE="${TELEGRAM_CRED_ID:-}"
    PG_REPLACE="${POSTGRES_CRED_ID:-}"
    ANTH_REPLACE="${ANTHROPIC_CRED_ID:-}"
    sed -i "s|REPLACE_WITH_YOUR_CREDENTIAL_ID\", \"name\": \"Telegram Bot\"|${TELE_REPLACE}\", \"name\": \"Telegram Bot\"|g" "$dst"
    sed -i "s|REPLACE_WITH_YOUR_CREDENTIAL_ID\", \"name\": \"Supabase Postgres\"|${PG_REPLACE}\", \"name\": \"Supabase Postgres\"|g" "$dst"
    sed -i "s|REPLACE_WITH_YOUR_CREDENTIAL_ID\", \"name\": \"Anthropic API\"|${ANTH_REPLACE}\", \"name\": \"Anthropic API\"|g" "$dst"
    # Catch-all: clear any remaining REPLACE_WITH_YOUR_CREDENTIAL_ID placeholders
    sed -i "s|REPLACE_WITH_YOUR_CREDENTIAL_ID||g" "$dst"
done
echo "workflow-import: placeholder replacement done."

# ── Step 3: Import workflows (upsert by name) ────────────────
echo "workflow-import: importing workflows..."

# Import order matters — dependencies first
# ha-bridge must come after n8n-claw-agent (needs agent ID for patching)
IMPORT_ORDER="mcp-client reminder-factory reminder-runner mcp-weather-example workflow-builder mcp-builder mcp-library-manager credential-form memory-consolidation heartbeat n8n-claw-agent ha-bridge"

# Fetch existing workflows once
EXISTING_WFS=$(curl -s "${N8N_BASE}/api/v1/workflows?limit=100" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}")

declare -A WF_IDS

for wf_name in $IMPORT_ORDER; do
    f="${WORKDIR}/${wf_name}.json"
    [ -f "$f" ] || continue

    # Get workflow display name from JSON
    display_name=$(jq -r '.name // "?"' "$f" 2>/dev/null)

    # Check if workflow already exists by name
    existing_id=$(echo "$EXISTING_WFS" | \
        jq -r --arg n "$display_name" '.data[] | select(.name==$n) | .id' 2>/dev/null | head -1)

    if [ -n "$existing_id" ]; then
        # UPDATE existing workflow (PUT) — preserves ID, no duplicates
        UPDATE_BODY=$(jq '{name: .name, nodes: (.nodes // []), connections: (.connections // {}), settings: (.settings // {})}' "$f" 2>/dev/null)
        curl -s -X PUT "${N8N_BASE}/api/v1/workflows/${existing_id}" \
            -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$UPDATE_BODY" > /dev/null
        WF_IDS[$wf_name]="$existing_id"
        echo "  ✅ ${display_name} → ${existing_id} (updated)"
    else
        # CREATE new workflow (POST) — strip to only accepted fields
        CREATE_BODY=$(jq '{name: .name, nodes: (.nodes // []), connections: (.connections // {}), settings: (.settings // {})}' "$f" 2>/dev/null)
        resp=$(curl -s -X POST "${N8N_BASE}/api/v1/workflows" \
            -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$CREATE_BODY")
        wf_id=$(echo "$resp" | jq -r '.id // ""' 2>/dev/null)
        if [ -n "$wf_id" ]; then
            WF_IDS[$wf_name]="$wf_id"
            echo "  ✅ ${display_name} → ${wf_id} (created)"
        else
            err=$(echo "$resp" | jq -r '.message // "unknown error"' 2>/dev/null)
            echo "  ❌ ${display_name}: ${err}"
        fi
    fi
done

echo "workflow-import: all workflows imported."

# ── Step 4: Patch cross-workflow ID references in agent ──────
echo "workflow-import: patching cross-workflow references..."

AGENT_WF_ID="${WF_IDS[n8n-claw-agent]}"
if [ -n "$AGENT_WF_ID" ]; then
    AGENT_JSON=$(curl -s "${N8N_BASE}/api/v1/workflows/${AGENT_WF_ID}" \
        -H "X-N8N-API-KEY: ${N8N_API_KEY}")

    # Use sed to replace placeholder IDs in the raw JSON (more portable than jq gsub with vars)
    REMINDER_FACTORY_ID="${WF_IDS[reminder-factory]}"
    WORKFLOW_BUILDER_ID="${WF_IDS[workflow-builder]}"
    MCP_BUILDER_ID="${WF_IDS[mcp-builder]}"
    LIBRARY_MANAGER_ID="${WF_IDS[mcp-library-manager]}"

    PATCHED=$(echo "$AGENT_JSON" \
        | sed "s|REPLACE_REMINDER_FACTORY_ID|${REMINDER_FACTORY_ID}|g" \
        | sed "s|REPLACE_WORKFLOW_BUILDER_ID|${WORKFLOW_BUILDER_ID}|g" \
        | sed "s|REPLACE_MCP_BUILDER_ID|${MCP_BUILDER_ID}|g" \
        | sed "s|REPLACE_LIBRARY_MANAGER_ID|${LIBRARY_MANAGER_ID}|g" \
        | jq '{name: .name, nodes: (.nodes // []), connections: (.connections // {}), settings: (.settings // {})}' 2>/dev/null)

    if [ -n "$PATCHED" ]; then
        curl -s -X PUT "${N8N_BASE}/api/v1/workflows/${AGENT_WF_ID}" \
            -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$PATCHED" > /dev/null
        echo "  ✅ Agent cross-refs patched"
        echo "     reminder-factory:  ${REMINDER_FACTORY_ID}"
        echo "     workflow-builder:  ${WORKFLOW_BUILDER_ID}"
        echo "     mcp-builder:       ${MCP_BUILDER_ID}"
        echo "     mcp-library-mgr:   ${LIBRARY_MANAGER_ID}"
    else
        echo "  ⚠️  Agent patch failed — patch cross-refs manually in n8n UI"
    fi
fi

# ── Step 5: Patch agent ID in reminder-runner ────────────────
REMINDER_RUNNER_WF_ID="${WF_IDS[reminder-runner]}"
if [ -n "$REMINDER_RUNNER_WF_ID" ] && [ -n "$AGENT_WF_ID" ]; then
    RUNNER_JSON=$(curl -s "${N8N_BASE}/api/v1/workflows/${REMINDER_RUNNER_WF_ID}" \
        -H "X-N8N-API-KEY: ${N8N_API_KEY}")

    PATCHED_RUNNER=$(echo "$RUNNER_JSON" \
        | sed "s|REPLACE_AGENT_WORKFLOW_ID|${AGENT_WF_ID}|g" \
        | jq '{name: .name, nodes: (.nodes // []), connections: (.connections // {}), settings: (.settings // {})}' 2>/dev/null)

    if [ -n "$PATCHED_RUNNER" ]; then
        curl -s -X PUT "${N8N_BASE}/api/v1/workflows/${REMINDER_RUNNER_WF_ID}" \
            -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$PATCHED_RUNNER" > /dev/null
        echo "  ✅ Reminder Runner → Agent: ${AGENT_WF_ID}"
    fi
fi

# ── Step 6: Activate workflows ───────────────────────────────
echo "workflow-import: activating workflows..."

activate_wf() {
    local wf_id="$1"
    local wf_label="$2"
    if [ -z "$wf_id" ]; then return; fi
    for attempt in 1 2 3; do
        RESP=$(curl -s -X POST "${N8N_BASE}/api/v1/workflows/${wf_id}/activate" \
            -H "X-N8N-API-KEY: ${N8N_API_KEY}")
        ERR=$(echo "$RESP" | jq -r '.message // ""' 2>/dev/null)
        if [ -z "$ERR" ]; then
            echo "  ✅ ${wf_label} activated"
            return
        elif echo "$ERR" | grep -qi "too many\|retry"; then
            sleep 2
        else
            echo "  ⚠️  ${wf_label}: ${ERR} — activate manually in n8n UI"
            return
        fi
    done
}

activate_wf "${WF_IDS[ha-bridge]}"          "HA Bridge"
activate_wf "${WF_IDS[n8n-claw-agent]}"    "n8n-claw Agent"
activate_wf "${WF_IDS[heartbeat]}"          "Heartbeat"
activate_wf "${WF_IDS[memory-consolidation]}" "Memory Consolidation"
activate_wf "${WF_IDS[credential-form]}"   "Credential Form"
activate_wf "${WF_IDS[reminder-runner]}"   "Reminder Runner"

# ── Done ─────────────────────────────────────────────────────
touch "$SENTINEL"
echo "workflow-import: sentinel written to ${SENTINEL}"
echo "workflow-import: done. n8n-claw is ready."
echo ""
echo "  Workflow IDs:"
for key in "${!WF_IDS[@]}"; do
    echo "    ${key}: ${WF_IDS[$key]}"
done
