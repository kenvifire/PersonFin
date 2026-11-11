#!/bin/sh
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG="$SCRIPT_DIR/deploy.config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "Missing $CONFIG — copy deploy.config.sh.example and fill it in." >&2
  exit 1
fi
. "$CONFIG"

REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

echo "==> Building Flutter web release bundle"
(cd "$REPO_ROOT/frontend" && flutter build web --release \
  --dart-define=API_BASE_URL="$API_BASE_URL" \
  --dart-define=GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID")

echo "==> Syncing frontend build to $VPS_HOST:$VPS_FRONTEND_WEBROOT"
rsync -avz --delete "$REPO_ROOT/frontend/build/web/" \
  "$VPS_USER@$VPS_HOST:$VPS_FRONTEND_WEBROOT/"

echo "==> Deploying backend on $VPS_HOST"
ssh "$VPS_USER@$VPS_HOST" \
  "cd $VPS_REPO_DIR && git pull && docker compose up -d --build backend"

echo "==> Done"
