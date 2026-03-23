#!/bin/bash
# db-init.sh — runs once at first boot to apply migrations
# Uses a sentinel file to prevent re-running on subsequent boots.

SENTINEL="/data/n8n-claw/.initialized"

if [ -f "$SENTINEL" ]; then
    echo "db-init: already initialized (sentinel found), skipping."
    exit 0
fi

echo "db-init: starting first-boot initialization..."

. /app/n8n-exports.sh

export PGPASSWORD="$DB_POSTGRESDB_PASSWORD"
PSQL_CMD="psql -h $DB_POSTGRESDB_HOST -p $DB_POSTGRESDB_PORT -U $DB_POSTGRESDB_USER -d $DB_POSTGRESDB_DATABASE"

# ── Wait for TimescaleDB addon to be ready ───────────────────
echo "db-init: waiting for TimescaleDB addon at ${DB_POSTGRESDB_HOST}:${DB_POSTGRESDB_PORT}..."
MAX_WAIT=120
WAITED=0
until $PSQL_CMD -c '\q' 2>/dev/null; do
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "db-init: ERROR — timed out waiting for database after ${MAX_WAIT}s"
        echo "db-init: Check that the Expaso TimescaleDB addon is running and port ${DB_POSTGRESDB_PORT} is exposed."
        exit 1
    fi
    echo "  waiting for DB... (${WAITED}s elapsed)"
    sleep 5
    WAITED=$((WAITED + 5))
done
echo "db-init: database is ready."

# ── Run migrations in order ──────────────────────────────────
echo "db-init: running migrations..."
for f in /app/migrations/000_extensions.sql \
          /app/migrations/001_schema.sql \
          /app/migrations/002_seed.sql; do
    if [ -f "$f" ]; then
        echo "  applying $(basename $f)..."
        if ! $PSQL_CMD -f "$f" 2>&1; then
            echo "db-init: WARNING — migration $(basename $f) reported errors (may be safe if idempotent)"
        else
            echo "  ✅ $(basename $f) applied"
        fi
    else
        echo "  SKIP: $f not found"
    fi
done

echo "db-init: migrations complete."

# ── Mark as initialized ──────────────────────────────────────
mkdir -p /data/n8n-claw
touch "$SENTINEL"
echo "db-init: sentinel written to ${SENTINEL}"
echo "db-init: done."
