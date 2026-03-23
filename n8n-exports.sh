#!/bin/bash
# n8n-claw exports — extends hass-n8n base with PostgreSQL + PostgREST vars

export N8N_SECURE_COOKIE=false
export N8N_HIRING_BANNER_ENABLED=false
export N8N_PERSONALIZATION_ENABLED=false
export N8N_VERSION_NOTIFICATIONS_ENABLED=false
export N8N_RUNNERS_ENABLED=true
export N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# Community nodes — baked into /app/custom-nodes at Docker build time
# Includes: n8n-nodes-homeassistantws, @berriai/n8n-nodes-litellm
export N8N_CUSTOM_EXTENSIONS="/app/custom-nodes"
export N8N_COMMUNITY_PACKAGES_ENABLED=true

CONFIG_PATH="/data/options.json"
export GENERIC_TIMEZONE="$(jq --raw-output '.timezone // "Europe/Berlin"' $CONFIG_PATH)"
export N8N_CMD_LINE="$(jq --raw-output '.cmd_line_args // empty' $CONFIG_PATH)"

#####################
## USER PARAMETERS ##
#####################

# Extract the values from env_vars_list
values=$(jq -r '.env_vars_list | .[]' "$CONFIG_PATH")

# Convert the values to an array
IFS=$'\n' read -r -d '' -a array <<< "$values"

# Export keys and values
for element in "${array[@]}"
do
    key="${element%%:*}"
    value="${element#*:}"
    value=$(echo "$value" | xargs) # Remove leading and trailing whitespace
    export "$key"="$value"
    echo "exported ${key}=${value}"
done

# IF NODE_FUNCTION_ALLOW_EXTERNAL is set, install the required packages
if [ -n "${NODE_FUNCTION_ALLOW_EXTERNAL}" ]; then
    echo "Installing external packages..."
    IFS=',' read -r -a packages <<< "${NODE_FUNCTION_ALLOW_EXTERNAL}"
    for package in "${packages[@]}"
    do
        echo "Installing ${package}..."
        npm install -g "${package}"
    done
fi

##########################
## POSTGRESQL (TimescaleDB addon)
##########################
export DB_TYPE=postgresdb
export DB_POSTGRESDB_HOST="$(jq --raw-output '.db_host // "172.30.32.1"' $CONFIG_PATH)"
export DB_POSTGRESDB_PORT="$(jq --raw-output '.db_port // 5432' $CONFIG_PATH)"
export DB_POSTGRESDB_DATABASE="$(jq --raw-output '.db_name // "n8n-claw"' $CONFIG_PATH)"
export DB_POSTGRESDB_USER="$(jq --raw-output '.db_user // "postgres"' $CONFIG_PATH)"
export DB_POSTGRESDB_PASSWORD="$(jq --raw-output '.db_password // empty' $CONFIG_PATH)"

##########################
## n8n ENCRYPTION KEY
##########################
# If set in options, use it; otherwise n8n will auto-generate and persist in N8N_USER_FOLDER
N8N_ENCRYPTION_KEY_OPT="$(jq --raw-output '.n8n_encryption_key // empty' $CONFIG_PATH)"
if [ -n "$N8N_ENCRYPTION_KEY_OPT" ]; then
    export N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY_OPT"
fi

##########################
## n8n OWNER ACCOUNT
##########################
# Used for auto-creating the owner account on first boot and for workflow-import login
export N8N_OWNER_EMAIL="$(jq --raw-output '.n8n_owner_email // "admin@n8n-claw.local"' $CONFIG_PATH)"
export N8N_OWNER_PASSWORD="$(jq --raw-output '.n8n_owner_password // "n8nclaw123"' $CONFIG_PATH)"
export N8N_OWNER_FIRST_NAME="n8n"
export N8N_OWNER_LAST_NAME="claw"

##########################
## n8n USER FOLDER (HA managed volume)
##########################
export N8N_USER_FOLDER="/data/n8n-claw"
echo "N8N_USER_FOLDER: ${N8N_USER_FOLDER}"

##########################
## HA SUPERVISOR INFO
##########################
INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" http://supervisor/info || echo '{}')
INFO=${INFO:-'{}'}
echo "Fetched Info from Supervisor: ${INFO}"

CONFIG=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" http://supervisor/core/api/config || echo '{}')
CONFIG=${CONFIG:-'{}'}
echo "Fetched Config from Supervisor: ${CONFIG}"

ADDON_INFO=$(curl -s -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" http://supervisor/addons/self/info || echo '{}')
ADDON_INFO=${ADDON_INFO:-'{}'}
echo "Fetched Add-on Info from Supervisor: ${ADDON_INFO}"

INGRESS_PATH=$(echo "$ADDON_INFO" | jq -r '.data.ingress_url // "/"')
echo "Extracted Ingress Path from Supervisor: ${INGRESS_PATH}"

# Get the port from the configuration
LOCAL_HA_PORT=$(echo "$CONFIG" | jq -r '.port // "8123"')

# Get the Home Assistant hostname from the supervisor info
LOCAL_HA_HOSTNAME=$(echo "$INFO" | jq -r '.data.hostname // "localhost"')
LOCAL_N8N_PORT=${LOCAL_N8N_PORT:-5690}
LOCAL_N8N_URL="http://$LOCAL_HA_HOSTNAME:$LOCAL_N8N_PORT"
echo "Local Home Assistant n8n URL: ${LOCAL_N8N_URL}"

# Get the external URL if configured, otherwise use the hostname and port
EXTERNAL_N8N_URL=${EXTERNAL_URL:-$(echo "$CONFIG" | jq -r ".external_url // \"$LOCAL_N8N_URL\"")}
EXTERNAL_HA_HOSTNAME=$(echo "$EXTERNAL_N8N_URL" | sed -e "s/https\?:\/\///" | cut -d':' -f1)
echo "External Home Assistant n8n URL: ${EXTERNAL_N8N_URL}"

export N8N_PATH=${N8N_PATH:-"${INGRESS_PATH}"}
export N8N_EDITOR_BASE_URL=${N8N_EDITOR_BASE_URL:-"${EXTERNAL_N8N_URL}${N8N_PATH}"}

# Webhook URL: prefer explicit option, then HA external URL on port 8081
N8N_WEBHOOK_URL_OPT="$(jq --raw-output '.n8n_webhook_url // empty' $CONFIG_PATH)"
if [ -n "$N8N_WEBHOOK_URL_OPT" ]; then
    export WEBHOOK_URL="$N8N_WEBHOOK_URL_OPT"
else
    export WEBHOOK_URL=${WEBHOOK_URL:-"http://${LOCAL_HA_HOSTNAME}:8081"}
fi
echo "WEBHOOK_URL: ${WEBHOOK_URL}"
