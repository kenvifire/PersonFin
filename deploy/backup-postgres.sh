#!/bin/bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BACKUP_DIR="$REPO_ROOT/backups"
RETENTION_DAYS=14

# docker compose exec runs on the host, not inside a container, so
# Compose's own `env_file:` (which only reaches containers) doesn't get
# POSTGRES_USER/POSTGRES_DB into *this* shell — read .env directly. This
# matters most for the real cron job (see DEPLOYMENT.md), which starts
# with none of a login shell's environment.
set -a
. "$REPO_ROOT/.env"
set +a

mkdir -p "$BACKUP_DIR"

STAMP=$(date +%Y%m%d-%H%M%S)
TMP_FILE="$BACKUP_DIR/.tmp-$STAMP.sql.gz"
FINAL_FILE="$BACKUP_DIR/personfin-$STAMP.sql.gz"

# Write to a .tmp name first and only rename to the final name on success,
# so a failed/partial dump never looks like a completed backup and a
# failed run never reaches the prune step below.
cd "$REPO_ROOT"
docker compose exec -T db pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$TMP_FILE"
mv "$TMP_FILE" "$FINAL_FILE"
echo "Backup written to $FINAL_FILE"

find "$BACKUP_DIR" -name "personfin-*.sql.gz" -mtime "+$RETENTION_DAYS" -delete
