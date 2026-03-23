#!/bin/bash
# PostgREST entrypoint — reads DB config from n8n-exports.sh and starts PostgREST on :3000

. /app/n8n-exports.sh

export PGRST_DB_URI="postgres://${DB_POSTGRESDB_USER}:${DB_POSTGRESDB_PASSWORD}@${DB_POSTGRESDB_HOST}:${DB_POSTGRESDB_PORT}/${DB_POSTGRESDB_DATABASE}"
export PGRST_DB_SCHEMA="public"
export PGRST_DB_ANON_ROLE="anon"
export PGRST_SERVER_PORT="3000"
export PGRST_DB_USE_LEGACY_GUCS="false"
# Allow PostgREST to serve all tables in the public schema
export PGRST_DB_EXTRA_SEARCH_PATH="public"

# JWT secret from options (used by n8n workflows to authenticate to PostgREST)
# If empty, PostgREST runs without JWT auth (safe since it's internal-only)
JWT_SECRET="$(jq --raw-output '.postgrest_jwt_secret // empty' /data/options.json)"
if [ -n "$JWT_SECRET" ]; then
    export PGRST_JWT_SECRET="$JWT_SECRET"
    echo "postgrest: JWT auth enabled"
else
    echo "postgrest: JWT auth disabled (internal-only mode)"
fi

echo "postgrest: connecting to ${DB_POSTGRESDB_HOST}:${DB_POSTGRESDB_PORT}/${DB_POSTGRESDB_DATABASE}"
echo "postgrest: listening on :3000"

exec /usr/local/bin/postgrest
