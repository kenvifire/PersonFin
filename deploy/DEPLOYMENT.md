# Production Deployment Guide

This is the walkthrough for taking PersonFin from "builds and passes tests
locally" to "running at `https://finance.itlubo.com`". It assumes the VPS
(`proxy.itlubo.com`) already runs nginx with TLS configured for
`finance.itlubo.com` for some other purpose, and that Docker/Docker Compose
are installed on it.

Everything below is a manual, one-time (or first-deploy) set of steps. None
of it is automated by this repo, and none of it has been executed against
the real VPS or Google Cloud Console while writing this doc — see the
plan's Global Constraints.

## 1. Create the Google OAuth production client

The frontend's sign-in flow is origin-based, not redirect-based (see
`frontend/lib/auth/google_auth_service.dart`, which drives
`GoogleSignIn.instance` and renders Google's own button via
`authenticationEvents`/`renderButton` — there's no OAuth redirect URI to
register).

1. In [Google Cloud Console](https://console.cloud.google.com/), go to
   **APIs & Services → Credentials**.
2. Click **Create Credentials → OAuth client ID**.
3. Application type: **Web application**.
4. Under **Authorized JavaScript origins**, add:
   ```
   https://finance.itlubo.com
   ```
   Leave **Authorized redirect URIs** empty — this flow doesn't use one.
5. Save, then copy the generated **Client ID** (and **Client secret**).

This one Client ID is needed in two different places, for two different
reasons:

- **`deploy/deploy.config.sh`'s `GOOGLE_CLIENT_ID`** — baked into the
  Flutter web bundle at *build time* via `--dart-define=GOOGLE_CLIENT_ID=...`
  (see `deploy/deploy.sh`), so the browser-side Google Sign-In button
  initializes with the right client.
- **The VPS's `.env`'s `GOOGLE_CLIENT_ID`** — read by the backend
  (`backend/app/config.py`'s `Settings.google_client_id`) and used in
  `backend/app/auth/google_oauth.py`'s `verify_google_id_token` to check a
  signed-in user's ID token `aud` claim against this client, as part of
  verifying the token server-side.
- **The VPS's `.env`'s `GOOGLE_CLIENT_SECRET`** — a required `Settings`
  field (`Settings.google_client_secret`) that must be set for the backend
  to start, even though no code path in `backend/app/` currently reads it
  — ID-token verification above only checks `google_client_id`. Fill it in
  with the real Client Secret anyway, in case that changes.

Both copies must be the same OAuth client. Keep the Client Secret only in
the VPS's `.env` — the frontend build never needs it.

## 2. One-time VPS setup

Run once, the first time this app is deployed to `proxy.itlubo.com`. All of
the following happens *on the VPS*, over an SSH session you start yourself
— this repo's deploy tooling never does this part for you.

### 2.1 Clone the repo

```bash
git clone <this repo's URL> /opt/personfin
```

Use whatever path you intend to put in `VPS_REPO_DIR` in
`deploy/deploy.config.sh` (Section 3) — `/opt/personfin` is just the
example used throughout this doc and in
`deploy/deploy.config.sh.example`'s own default.

### 2.2 Create and fill in `.env`

```bash
cd /opt/personfin
cp .env.example .env
```

Edit `.env` and fill in every value for real. Compose reads this file in
two different ways: `backend` gets the whole file as environment
variables via its own `env_file: .env` declaration in
`docker-compose.yml`, while `db` has no `env_file:` key at all — it only
gets the three Postgres variables it needs, through Compose's separate,
automatic `${VAR}` substitution (Compose always reads a `.env` file in the
project directory for this, independent of any service's `env_file:`),
via the `environment: POSTGRES_USER: ${POSTGRES_USER}` etc. lines in
`docker-compose.yml`. Every field here is listed, with its purpose, in
`.env.example` itself; the required ones are:

| Variable | Purpose |
|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Real Postgres credentials for the `db` container. Pick a strong password — this is the production database. |
| `DATABASE_URL` | SQLAlchemy connection string the backend uses. Keep the host as `db` (the Compose service name), e.g. `postgresql://personfin:<your password>@db:5432/personfin`, matching whatever you set above. |
| `JWT_SECRET` | Secret key the backend signs/verifies its own JWTs with. Generate a strong random value, e.g. `openssl rand -hex 32` — do not reuse a value from local development. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | The real production OAuth client from Section 1. |
| `AZURE_OPENAI_ENDPOINT` / `AZURE_OPENAI_API_KEY` / `AZURE_OPENAI_DEPLOYMENT` | Real Azure OpenAI resource details, used for screenshot extraction. |
| `UPLOAD_DIR` | Leave as `/data/uploads` — this is the in-container path backed by the `uploads` named volume in `docker-compose.yml`; don't repoint it. |
| `FX_API_KEY` | Optional — leave blank if the FX-rate feature isn't needed. |
| `DEEPSEEK_API_KEY` | Optional — leave blank to run without insight narration (`/insights` degrades gracefully with `narrative_unavailable=True` instead of failing). |

Never commit this file — it's git-ignored, and `.env.example` is the only
version tracked.

### 2.3 Create the frontend webroot

```bash
mkdir -p /var/www/finance-frontend
```

This must match `VPS_FRONTEND_WEBROOT` in `deploy/deploy.config.sh`
(Section 3) — `deploy/deploy.sh` rsyncs the Flutter web build here, and
`deploy/nginx-finance.itlubo.com.conf`'s `location /` block serves straight
out of this same path (`root /var/www/finance-frontend;`). If you use a
different path, update it consistently in all three places.

### 2.4 Splice in the nginx config

`deploy/nginx-finance.itlubo.com.conf` (from this repo) contains only the
two `location` blocks PersonFin needs — it deliberately does **not**
include `listen 443 ssl` / `ssl_certificate` / etc., since those already
exist on this VPS in whatever pattern its other sites use.

1. Open the existing TLS server block for `finance.itlubo.com` (check
   `/etc/nginx/sites-available/` for the file to edit, or wherever this
   VPS's other sites are configured).
2. Copy the `location /api/` and `location /` blocks from
   `deploy/nginx-finance.itlubo.com.conf` into that server block.
3. Validate and reload:
   ```bash
   nginx -t && systemctl reload nginx
   ```

### 2.5 Set up the daily backup cron job

`deploy/backup-postgres.sh` dumps Postgres with `pg_dump | gzip`, writes it
atomically (so a failed dump never masquerades as a successful backup),
and prunes backups older than 14 days. It sources `.env` itself, so it
doesn't depend on any variables already being present in the calling
shell's environment — which matters, because cron starts a job with none
of a login shell's environment.

Add a crontab entry (`crontab -e`) that invokes the script **directly**:

```cron
0 3 * * * cd /opt/personfin && deploy/backup-postgres.sh >> /var/log/personfin-backup.log 2>&1
```

**Do not** prefix this with an explicit interpreter, e.g. `sh
deploy/backup-postgres.sh`. The script's shebang is `#!/bin/bash` and it
relies on `bash`'s `set -eo pipefail` to catch a failed `pg_dump` even when
only the downstream `gzip` in the pipe appears to succeed. Invoking it via
`sh` would silently run it under a shell that doesn't support
`pipefail`, defeating that safety check — a dump that fails midway could
then be written out and kept as if it were a good backup. Always let the
script's own shebang pick its interpreter.

Also confirm `git`, `docker`, and `docker compose` are all usable
non-interactively by whatever user cron runs this as (typically `root`, if
that's who owns `/opt/personfin`).

## 3. First deploy

Run from the developer's own machine (not the VPS) — this requires the
Flutter SDK locally, which the VPS itself never needs.

1. Copy the example deploy config and fill it in with real values:
   ```bash
   cp deploy/deploy.config.sh.example deploy/deploy.config.sh
   ```
   Edit `deploy/deploy.config.sh` (it's git-ignored, so this stays local):

   | Variable | Value |
   |---|---|
   | `VPS_USER` | The SSH user for `proxy.itlubo.com` (e.g. `root`). |
   | `VPS_HOST` | `proxy.itlubo.com` |
   | `VPS_REPO_DIR` | The path you cloned the repo to in Section 2.1 (e.g. `/opt/personfin`). |
   | `VPS_FRONTEND_WEBROOT` | The path you created in Section 2.3 (e.g. `/var/www/finance-frontend`). |
   | `API_BASE_URL` | `https://finance.itlubo.com/api` |
   | `GOOGLE_CLIENT_ID` | The real production Client ID from Section 1. |

2. Run the deploy script:
   ```bash
   deploy/deploy.sh
   ```
   This builds the Flutter web release bundle locally
   (`flutter build web --release` with the `API_BASE_URL` and
   `GOOGLE_CLIENT_ID` above baked in via `--dart-define`), `rsync`s it to
   `VPS_FRONTEND_WEBROOT` on the VPS, then SSHes in to `git pull` and
   `docker compose up -d --build backend` — which also runs
   `alembic upgrade head` automatically via the backend container's
   entrypoint before it starts serving.

3. Confirm the backend container is healthy:
   ```bash
   ssh "$VPS_USER@$VPS_HOST" "cd $VPS_REPO_DIR && docker compose ps"
   ```
   (Substitute the real values, or just run it by hand on the VPS.)

## 4. Post-deploy smoke test

A short manual checklist against the real production URL — mirrors the
same end-to-end walkthrough used when the frontend was first wired
together, but now against `https://finance.itlubo.com` instead of a local
backend.

1. Visit `https://finance.itlubo.com` and confirm the login screen renders,
   with a working Google sign-in button (not an error/unavailable state).
2. Sign in with a real Google account.
3. Confirm the dashboard loads (empty state is fine if there's no data
   yet).
4. Tap the camera FAB, upload a real account-screenshot image, confirm it
   reaches the review screen with extracted fields, and submit it
   successfully.
5. Confirm the new snapshot appears on the dashboard.
6. Visit the **Insights** tab and confirm it renders (allocation bars, and
   either a narrative or the graceful `narrative_unavailable` fallback if
   `DEEPSEEK_API_KEY` wasn't set).
7. Sign out and confirm the app returns to `/login`.

If any step fails, check `docker compose logs backend` on the VPS first —
most first-deploy issues are a missing/incorrect value in `.env` (Section
2.2) or a `GOOGLE_CLIENT_ID` mismatch between the Flutter build and the
backend's `.env` (Section 1).
