# Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the already-complete backend and frontend for production on the user's existing VPS — Docker Compose for the backend/database, the user's existing host nginx fronting everything, a one-command deploy script, automated migrations, and a Postgres backup job — plus the documentation for the one-time manual steps (Google OAuth production client, first VPS setup) that only the user can do.

**Architecture:** Two Docker Compose services (`backend`, `db`); no frontend container — the Flutter web build is static output synced onto the VPS and served directly by the existing host nginx, which also reverse-proxies `/api/` (prefix stripped) to the backend container over `127.0.0.1:8000`. Migrations run automatically in the backend container's entrypoint before Uvicorn starts. A `deploy/deploy.sh` script run from the developer's own machine builds the Flutter release bundle locally, rsyncs it to the VPS, and SSHes in to `git pull` + rebuild the backend container — no CI/CD.

**Tech Stack:** Docker Compose; `python:3.13-slim` (matches local dev's Python 3.13.9) for the backend image; `postgres:16-alpine` for the database; the existing host nginx (not containerized); `rsync`/`ssh` for the deploy script; `pg_dump` + cron for backups.

**Spec:** `docs/superpowers/specs/2026-11-08-personal-finance-tracker-design.md` (see especially the "Deployment (decided during Plan 5)" section).

## Global Constraints

- Docker Compose has exactly two services: `backend` and `db`. No frontend container.
- `db` is `postgres:16-alpine` with a named volume (`pgdata`) for `/var/lib/postgresql/data`.
- `backend` is built from `python:3.13-slim`, runs `alembic upgrade head` then `exec uvicorn app.main:app --host 0.0.0.0 --port 8000` via its entrypoint, and binds only `127.0.0.1:8000:8000` on the host — nothing else is exposed beyond localhost.
- Uploaded screenshot images (`UPLOAD_DIR`, default `./data/uploads` per `backend/app/config.py:Settings.upload_dir`) live on a named volume (`uploads`) mounted into the `backend` container, so they survive a container rebuild/recreation — required by the spec's screenshot-retention decision.
- All secrets (`DATABASE_URL`, `JWT_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `AZURE_OPENAI_*`, `DEEPSEEK_API_KEY`, `FX_API_KEY`) come from one git-ignored `.env` file via Compose's `env_file:` — never committed, never hardcoded.
- The Flutter web production build is produced with `flutter build web --release --dart-define=API_BASE_URL=https://finance.itluobo.com/api --dart-define=GOOGLE_CLIENT_ID=<prod client id>` (exact flag names verified against `frontend/lib/main.dart:26-27` and `frontend/lib/auth/google_auth_service.dart:39`) — run on the developer's machine, not the VPS; the VPS does not need the Flutter SDK installed.
- nginx (already running on the VPS host, outside Docker) owns TLS termination and is the only thing the internet reaches. It proxies `location /api/ { proxy_pass http://127.0.0.1:8000/; }` (stripping the `/api` prefix so backend route code needs zero changes) and falls through to the Flutter build with `try_files $uri $uri/ /index.html;` for everything else.
- No CI/CD. Deployment is manual and SSH-triggered via one `deploy/deploy.sh` script.
- **This plan's executor has no SSH/root credentials to `proxy.itluobo.com`/`finance.itluobo.com` and must never attempt to connect to, modify, or deploy onto that host.** Every task's verification runs against a local Docker Compose stack and local files only. The actual first production deployment, the nginx config installation, the cron installation, and the Google Cloud Console steps are manual actions documented for the user to perform themselves (Task 6) — building that documentation is in scope; executing it against the real VPS is not.

## Review Focus

- **Postgres data must survive a container restart/rebuild**, not get silently wiped by `docker compose down && up` or an image rebuild — the whole point of a named volume. (Task 2)
- **A missing or malformed required environment variable must fail the backend container fast and loudly** (a clear validation error in the container's logs, non-zero exit) at startup, not start successfully and then 500 on first request, and not silently fall back to some default the user never set. (Task 1)
- **The nginx `/api/` split must actually resolve the real path collision**, not just look right: the Flutter app's own client-side routes (`/dashboard`, `/insights`) are the literal same strings as backend API paths. A direct browser load/refresh of a deep client route must still serve `index.html` (SPA fallback), and a same-named API call must still reach the backend — not 404 or mis-route. (Task 3)
- **Uploaded screenshot images must survive a backend container recreation** (rebuild/redeploy), not just a restart — this is the spec's explicit screenshot-retention requirement, and it's easy to get backwards (e.g. a volume that's recreated along with the container instead of persisted). (Task 2)
- **A failed backup run must not masquerade as success or destroy good backups** — if `pg_dump` fails (e.g. the `db` container is briefly down), the script must exit non-zero and must not create a zero-byte/corrupt dump file, and its rotation step must never prune existing good backups on a run that itself failed. (Task 5)

## File Structure

```
backend/
  Dockerfile                              # Task 1
  docker-entrypoint.sh                    # Task 1

docker-compose.yml                        # Task 2
.env.example                              # Task 2

deploy/
  nginx-finance.itluobo.com.conf           # Task 3
  deploy.config.sh.example                # Task 4
  deploy.sh                               # Task 4
  backup-postgres.sh                      # Task 5
  DEPLOYMENT.md                           # Task 6
```

---

### Task 1: Backend Dockerfile and entrypoint

**Files:**
- Create: `backend/Dockerfile`, `backend/docker-entrypoint.sh`, `backend/.dockerignore`

**Interfaces:**
- Produces: a buildable image tagged however the implementer chooses locally for testing (Task 2's compose file builds it as the `backend` service via `build: ./backend`). The entrypoint always runs `alembic upgrade head` before starting Uvicorn — later tasks rely on migrations being automatic, not a separate manual step.
- Consumes: `backend/requirements.txt` (already pinned, includes `psycopg[binary]==3.3.6`), `backend/app/config.py`'s `Settings` (fails on construction if a required field's env var is missing — this is what Step 4 below exercises).

- [ ] **Step 1: Write `backend/Dockerfile`**

```dockerfile
FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY alembic ./alembic
COPY alembic.ini .
COPY docker-entrypoint.sh .
RUN chmod +x docker-entrypoint.sh

EXPOSE 8000
ENTRYPOINT ["./docker-entrypoint.sh"]
```

- [ ] **Step 2: Write `backend/docker-entrypoint.sh`**

```sh
#!/bin/sh
set -e
alembic upgrade head
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
```

- [ ] **Step 3: Write `backend/.dockerignore`**

```
.venv
__pycache__
*.pyc
.pytest_cache
tests
.env
```

- [ ] **Step 4: Build the image**

Run: `docker build -t personfin-backend:test backend/`
Expected: build succeeds.

- [ ] **Step 5: Verify `.env` is excluded from the build context**

Run: `docker run --rm personfin-backend:test find / -maxdepth 2 -name ".env" 2>/dev/null`
Expected: no output — `.env` (if one happens to exist locally in `backend/` during the build) never reaches the image.

- [ ] **Step 6: Verify a missing required env var fails fast and clearly (Review Focus)**

Run: `docker run --rm personfin-backend:test`
Expected: the container exits non-zero (no `DATABASE_URL`/`JWT_SECRET`/etc. set means `Settings()` raises a Pydantic `ValidationError` before `alembic upgrade head` even runs, since `app.config.get_settings()` is imported transitively by `alembic/env.py`). Confirm the error output in `docker logs` (or the captured stderr from the `run`) names the missing fields clearly, not a bare traceback with no indication of which setting is missing.

- [ ] **Step 7: Commit**

```bash
git add backend/Dockerfile backend/docker-entrypoint.sh backend/.dockerignore
git commit -m "feat: add backend Dockerfile with automatic migrations on startup"
```

---

### Task 2: Docker Compose stack (backend + db) and `.env.example`

**Files:**
- Create: `docker-compose.yml`, `.env.example`

**Interfaces:**
- Consumes: `backend/Dockerfile` (Task 1).
- Produces: a runnable local stack (`docker compose up`) that later tasks (3, 4, 6) build on — the backend reachable at `127.0.0.1:8000`, Postgres data on a named volume, uploaded files on a named volume.

- [ ] **Step 1: Write `.env.example`**

List every field `backend/app/config.py`'s `Settings` reads, with placeholder values and a one-line comment each (`DATABASE_URL`, `JWT_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `FX_API_KEY` (optional), `UPLOAD_DIR`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_DEPLOYMENT`, `DEEPSEEK_API_KEY` (optional)), plus `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` for the `db` service. `DATABASE_URL`'s placeholder should already point at the compose service name: `postgresql://personfin:changeme@db:5432/personfin`. `UPLOAD_DIR`'s placeholder should be the in-container mount path used in Step 2 (e.g. `/data/uploads`), not the local-dev-relative `./data/uploads` default.

- [ ] **Step 2: Write `docker-compose.yml`**

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    logging: *default-logging

  backend:
    build: ./backend
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:8000:8000"
    volumes:
      - uploads:/data/uploads
    logging: *default-logging

volumes:
  pgdata:
  uploads:
```

(`x-logging`'s `max-size`/`max-file` is the decided "size-based rotation" from the spec's Deployment section — the default `json-file` driver has no rotation limit at all unless configured, so this isn't optional polish.)

- [ ] **Step 3: Verify the stack comes up and migrations run**

```bash
cp .env.example .env
# edit .env: fill POSTGRES_USER/PASSWORD/DB and a matching DATABASE_URL,
# any non-empty placeholder values for the other required fields (real
# Azure/DeepSeek keys aren't needed for this check — the backend must
# still *start*, even if those integrations would fail on actual use)
docker compose up -d
```

Run: `curl -s http://127.0.0.1:8000/health`
Expected: `{"status":"ok"}` — confirms the container started, migrations ran (an import-time failure or a failed `alembic upgrade head` would have stopped `uvicorn` from ever starting), and the published port works.

- [ ] **Step 4: Verify Postgres data survives a restart (Review Focus)**

Checking `alembic_version`'s `version_num` before and after is not sufficient
on its own: that table only ever holds the current head revision ID, so a
silently wiped-and-remigrated volume would produce the identical value as a
genuinely persisted one. Prove persistence with data no migration would ever
create:

```bash
docker compose exec db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "CREATE TABLE IF NOT EXISTS _persistence_probe (marker text); INSERT INTO _persistence_probe VALUES ('verify-restart-$(date +%s)');"
docker compose exec db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT * FROM _persistence_probe;"
docker compose down       # no -v — volumes must survive this
docker compose up -d
curl -s http://127.0.0.1:8000/health   # confirm it comes back up
docker compose exec db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT * FROM _persistence_probe;"
docker compose exec db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP TABLE _persistence_probe;"
```
Expected: the inserted row is still present after the restart — the volume
persisted actual data, not just a migration state marker. (The
`alembic_version` `version_num` check may still be run as supplementary
color, but the row-based check above is the one that actually proves the
Review Focus item.)

- [ ] **Step 5: Verify uploaded files survive a container recreation (Review Focus)**

```bash
docker compose exec backend sh -c "echo test-persistence > /data/uploads/_verify.txt"
docker compose up -d --force-recreate backend
docker compose exec backend cat /data/uploads/_verify.txt
docker compose exec backend rm /data/uploads/_verify.txt
```
Expected: `test-persistence` is printed after the recreate — the `uploads` volume, not the container's own filesystem, is what's holding the file.

- [ ] **Step 6: Clean up the local verification stack**

Run: `docker compose down -v` (this time *with* `-v` — it's disposable local test data, not the real deployment) and remove the local `.env` used only for this check (or leave it `.gitignore`d; don't commit it).

- [ ] **Step 7: Commit**

```bash
git add docker-compose.yml .env.example
git commit -m "feat: add Docker Compose stack for backend and Postgres"
```

---

### Task 3: nginx reverse-proxy configuration

**Files:**
- Create: `deploy/nginx-finance.itluobo.com.conf`

**Interfaces:**
- Consumes: the path-space split decided in the spec (`/api/` → backend on `127.0.0.1:8000`, stripped; everything else → the Flutter build with SPA fallback).
- Produces: a config file Task 6's documentation tells the user to splice into their existing TLS-terminating server block for `finance.itluobo.com` (see the comment this step writes into the file — this plan's executor doesn't know this VPS's existing certbot/cert-path conventions, so the TLS directives are left as a clearly marked placeholder for the user to fill in from whatever pattern their other nginx sites already use, not guessed).

- [ ] **Step 1: Write `deploy/nginx-finance.itluobo.com.conf`**

```nginx
# Splice the `location` blocks below into your existing TLS server block
# for finance.itluobo.com — this file intentionally does NOT include
# `listen 443 ssl`/`ssl_certificate`/etc., since those already exist on
# this VPS in whatever pattern your other sites use (see
# /etc/nginx/sites-available/ for an example to copy from). This file is
# the part that's actually new.

# Flutter web app's own JS calls the backend at /api/... (see
# API_BASE_URL in deploy.sh) — strip the prefix, the backend's own route
# paths are unprefixed.
location /api/ {
    proxy_pass http://127.0.0.1:8000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Everything else is the Flutter web build. try_files' SPA fallback is
# what makes a direct browser load of /dashboard or /insights (the
# Flutter app's own client-side routes — note these are the same path
# strings as some backend API routes above, which is exactly why the
# /api/ prefix split exists) serve index.html instead of 404ing, so
# go_router can take over client-side.
location / {
    root /var/www/finance-frontend;
    try_files $uri $uri/ /index.html;
}
```

- [ ] **Step 2: Verify the config is syntactically valid nginx**

nginx isn't installed on this machine; use the official image to check syntax without installing anything locally:

```bash
mkdir -p /tmp/nginx-test
cat > /tmp/nginx-test/nginx.conf <<'EOF'
events {}
http {
  server {
    listen 80;
    include /etc/nginx/conf.d/finance.conf;
  }
}
EOF
cp deploy/nginx-finance.itluobo.com.conf /tmp/nginx-test/finance.conf
docker run --rm \
  -v /tmp/nginx-test/nginx.conf:/etc/nginx/nginx.conf:ro \
  -v /tmp/nginx-test/finance.conf:/etc/nginx/conf.d/finance.conf:ro \
  nginx:alpine nginx -t
```
Expected: `nginx: configuration file /etc/nginx/nginx.conf test is successful`.

- [ ] **Step 3: Commit**

```bash
git add deploy/nginx-finance.itluobo.com.conf
git commit -m "feat: add nginx config for the API/SPA path split"
```

---

### Task 4: `deploy.sh` — the one-command deploy script

**Files:**
- Create: `deploy/deploy.sh`, `deploy/deploy.config.sh.example`

**Interfaces:**
- Consumes: Task 1/2's Docker Compose stack (the remote-deploy phase runs `git pull && docker compose up -d --build backend` on the VPS), the exact `--dart-define` flags from Global Constraints.
- Produces: `deploy/deploy.sh`, run from the developer's own machine, reading its target (VPS host/user/paths, production dart-define values) from a git-ignored `deploy/deploy.config.sh` that each developer creates locally from the committed `.example` file — mirrors the `.env`/`.env.example` pattern, so no VPS specifics or secrets are ever committed.

- [ ] **Step 1: Write `deploy/deploy.config.sh.example`**

```sh
# Copy to deploy.config.sh (git-ignored) and fill in real values.
VPS_USER=root
VPS_HOST=proxy.itluobo.com
VPS_REPO_DIR=/opt/personfin
VPS_FRONTEND_WEBROOT=/var/www/finance-frontend
API_BASE_URL=https://finance.itluobo.com/api
GOOGLE_CLIENT_ID=
```

- [ ] **Step 2: Write `deploy/deploy.sh`**

```sh
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
```

- [ ] **Step 3: Verify the syntax is valid**

Run: `sh -n deploy/deploy.sh` and `sh -n deploy/deploy.config.sh.example`
Expected: no output, exit 0.

- [ ] **Step 4: Verify the local-build-and-sync phase actually works, against a local stand-in for the VPS**

This plan's executor has no access to the real VPS (Global Constraints) — exercise the script's build+rsync logic for real by pointing it at a local directory instead of a remote host, which `rsync` supports without any SSH connection:

```bash
cp deploy/deploy.config.sh.example deploy/deploy.config.sh
# edit deploy/deploy.config.sh: set VPS_FRONTEND_WEBROOT to a local temp
# dir (e.g. /tmp/fake-vps-webroot), and comment out/skip the ssh line's
# effect for this check — easiest is to run the build+rsync commands
# from deploy.sh directly in a shell rather than invoking the whole
# script, confirming:
mkdir -p /tmp/fake-vps-webroot
cd frontend && flutter build web --release --dart-define=API_BASE_URL=https://example.com/api --dart-define=GOOGLE_CLIENT_ID=test
rsync -avz --delete build/web/ /tmp/fake-vps-webroot/
ls /tmp/fake-vps-webroot/index.html
```
Expected: `index.html` exists in the fake webroot — the build-and-sync phase's commands are correct. Document in the commit message / PR description that the `ssh`/remote-`git pull`/`docker compose` phase is verified by code review only (it genuinely cannot be tested without the real VPS) and that the very first real run of `deploy.sh` against production is the user's own manual action (Task 6 documents it).

Clean up: `rm -rf /tmp/fake-vps-webroot deploy/deploy.config.sh` (the config file is git-ignored and local-only; don't leave the fake-webroot temp dir around).

- [ ] **Step 5: Add `deploy/deploy.config.sh` to `.gitignore`**

- [ ] **Step 6: Commit**

```bash
git add deploy/deploy.sh deploy/deploy.config.sh.example .gitignore
git commit -m "feat: add one-command deploy script"
```

---

### Task 5: Postgres backup script

**Files:**
- Create: `deploy/backup-postgres.sh`

**Interfaces:**
- Consumes: Task 2's `docker-compose.yml` (runs `docker compose exec` against the `db` service) and Task 2's `.env` (sourced directly for `POSTGRES_USER`/`POSTGRES_DB` — `docker compose exec` runs on the host, so Compose's `env_file:` doesn't reach this script).
- Produces: `.sql.gz` dump files in a `backups/` directory (created if missing) alongside wherever the script is run from on the VPS; Task 6 documents the cron entry that runs this daily (installing the cron job itself is the user's manual action, same as everywhere else in this plan).

- [ ] **Step 1: Write `deploy/backup-postgres.sh`**

```sh
#!/bin/sh
set -eu

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
```

- [ ] **Step 2: Verify a successful backup**

Against Task 2's local compose stack (bring it back up if it was torn down: `docker compose up -d`, loading the same `.env` used there):

```bash
bash deploy/backup-postgres.sh   # the script sources .env itself now
gzip -t backups/personfin-*.sql.gz
```
Expected: the script prints the backup path, and `gzip -t` reports no error (the dump is a valid, non-corrupt gzip file).

- [ ] **Step 3: Verify a failed backup does not masquerade as success or touch existing backups (Review Focus)**

```bash
ls backups/   # note the existing good backup from Step 2
docker compose stop db
set +e
bash deploy/backup-postgres.sh
echo "exit code: $?"
set -e
ls backups/   # the good backup from Step 2 must still be there, unchanged
```
Expected: the script exits non-zero (because `pg_dump` fails without live Compose service output when the pipeline's `set -e` catches it — actually verify `pipefail` isn't silently needed: `sh` doesn't support `set -o pipefail`, so confirm this script is run under a shell that catches the `pg_dump` failure correctly, or switch the shebang to `#!/bin/bash` with `set -eo pipefail` if `sh`'s plain `set -e` doesn't catch a failed left side of a pipe on this system — test this explicitly, don't assume), no `personfin-*.sql.gz` file dated from this failed run appears in `backups/`, and the Step 2 backup is untouched. Restart the db: `docker compose start db`.

- [ ] **Step 4: Clean up test backup files**

Run: `rm -rf backups/` (these are local verification artifacts, not meant to be committed) and confirm `backups/` is listed in `.gitignore` (add it if not).

- [ ] **Step 5: Commit**

```bash
git add deploy/backup-postgres.sh .gitignore
git commit -m "feat: add Postgres backup script with safe-failure rotation"
```

---

### Task 6: Production setup documentation (Google OAuth, VPS first-deploy, smoke test)

**Files:**
- Create: `deploy/DEPLOYMENT.md`

**Interfaces:**
- Consumes: every file path and script name from Tasks 1-6 (verify each reference below actually matches what those tasks created — this is a documentation-accuracy check, not new code).
- Produces: nothing further in this plan depends on it; this is the terminal task.

This task writes documentation only. It does not run `deploy.sh` against the real VPS, does not SSH anywhere, and does not create anything in Google Cloud Console — per the Global Constraints, those are the user's own actions. The verification step is a self-review of the document's accuracy, not an execution of its steps.

- [ ] **Step 1: Write the Google OAuth production client section**

Document the exact manual steps in Google Cloud Console: go to APIs & Services → Credentials, create an OAuth 2.0 Client ID of type "Web application", add `https://finance.itluobo.com` as an Authorized JavaScript origin (no redirect URI needed — the frontend's sign-in flow is origin-based, per `frontend/lib/auth/google_auth_service.dart`'s use of `GoogleSignIn.instance.authenticationEvents`/`renderButton`, not a redirect flow), and copy the resulting Client ID into both `deploy/deploy.config.sh`'s `GOOGLE_CLIENT_ID` (used at Flutter build time) and the VPS's `.env`'s `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` (used by the backend to verify ID tokens server-side).

- [ ] **Step 2: Write the one-time VPS setup section**

Document, in order: clone the repo to `VPS_REPO_DIR` (matching whatever path the user puts in their own `deploy/deploy.config.sh`); copy `.env.example` to `.env` and fill in every value (the real Azure OpenAI/DeepSeek keys, the real Google OAuth credentials from Step 1, a strong random `JWT_SECRET`, real Postgres credentials); create `VPS_FRONTEND_WEBROOT` (e.g. `mkdir -p /var/www/finance-frontend`); splice `deploy/nginx-finance.itluobo.com.conf`'s location blocks into the existing TLS server block for `finance.itluobo.com` (reference the exact file Task 3 created), then `nginx -t && systemctl reload nginx`; set up the daily backup cron entry calling `deploy/backup-postgres.sh` (reference the exact file Task 5 created) — e.g. `0 3 * * * cd /opt/personfin && deploy/backup-postgres.sh >> /var/log/personfin-backup.log 2>&1`.

- [ ] **Step 3: Write the first-deploy section**

Document running `deploy/deploy.sh` (Task 4) from the developer's own machine for the very first time, after copying `deploy/deploy.config.sh.example` to `deploy/deploy.config.sh` and filling in the real VPS host/paths and the real `GOOGLE_CLIENT_ID` from Step 1.

- [ ] **Step 4: Write the post-deploy manual smoke-test checklist**

A short numbered list mirroring Plan 4's own final walkthrough, but against the real production URL: visit `https://finance.itluobo.com`, confirm the login screen renders with a working Google sign-in button, sign in with a real account, confirm the dashboard loads (empty state if no data yet), upload a real screenshot through the camera FAB and confirm it reaches the review screen and confirms successfully, visit Insights, sign out and confirm the app returns to `/login`.

- [ ] **Step 5: Self-review for accuracy**

Re-read the document against the actual repo: confirm every file path named (`deploy/nginx-finance.itluobo.com.conf`, `deploy/deploy.sh`, `deploy/deploy.config.sh.example`, `deploy/backup-postgres.sh`, `.env.example`) matches exactly what Tasks 1-6 created, and that every env var name named matches `backend/app/config.py`'s `Settings` fields and `deploy/deploy.config.sh.example`'s fields exactly (a drifted variable name here is the kind of error nothing else in this plan would catch, since this file is never executed by anything).

- [ ] **Step 6: Commit**

```bash
git add deploy/DEPLOYMENT.md
git commit -m "docs: add production deployment and Google OAuth setup guide"
```
