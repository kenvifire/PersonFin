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

echo "==> Checking local working tree is clean and pushed"
(
  cd "$REPO_ROOT"

  if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree has uncommitted changes. Commit (or stash) them before deploying — otherwise the Flutter bundle built below won't match what the VPS's 'git pull' fetches for the backend." >&2
    exit 1
  fi

  UPSTREAM_REV=$(git rev-parse '@{u}' 2>/dev/null) || UPSTREAM_REV=""
  if [ -z "$UPSTREAM_REV" ]; then
    echo "WARNING: no upstream branch configured for the current branch — skipping the push-sync check. Make sure your commits are actually pushed before relying on this deploy." >&2
  else
    LOCAL_REV=$(git rev-parse HEAD)
    if [ "$LOCAL_REV" != "$UPSTREAM_REV" ]; then
      echo "ERROR: local HEAD ($LOCAL_REV) differs from its upstream ($UPSTREAM_REV). Push your commits before deploying — otherwise the Flutter bundle built below (from your local tree) won't match the backend the VPS's 'git pull' fetches." >&2
      exit 1
    fi
  fi
)

echo "==> Deploying backend on $VPS_HOST"
ssh "$VPS_USER@$VPS_HOST" \
  "cd $VPS_REPO_DIR && git pull && docker compose up -d --build backend"

echo "==> Building Flutter web release bundle"
(cd "$REPO_ROOT/frontend" && flutter build web --release \
  --dart-define=API_BASE_URL="$API_BASE_URL" \
  --dart-define=GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID")

echo "==> Syncing frontend build to $VPS_HOST:$VPS_FRONTEND_WEBROOT"
rsync -avz --delete "$REPO_ROOT/frontend/build/web/" \
  "$VPS_USER@$VPS_HOST:$VPS_FRONTEND_WEBROOT/"

echo "==> Done"
