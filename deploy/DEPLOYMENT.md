# Production Deployment Guide

This is the walkthrough for taking PersonFin from "builds and passes tests
locally" to "running at `https://finance.itluobo.com`". The VPS
(`proxy.itluobo.com`) runs nginx for several other sites, each with its own
Certbot-issued certificate (see `/etc/nginx/sites-available/`), and has
Docker/Docker Compose installed — but it has no existing site, DNS record,
or certificate for `finance.itluobo.com`. Both need to be created from
scratch as part of this deploy (Section 2.4).

Everything below is a manual, one-time (or first-deploy) set of steps. None
of it is automated by this repo.

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
   https://finance.itluobo.com
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

Run once, the first time this app is deployed to `proxy.itluobo.com`. All of
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

**Git remote authentication:** both this initial clone and every later
`git pull` (run by `deploy/deploy.sh` over SSH — see Section 3) need the
VPS to be able to authenticate to the git remote non-interactively. If
the repo is private, set this up before the first deploy: either a
dedicated deploy key (an SSH key pair generated on the VPS, with the
public half added as a GitHub/GitLab "Deploy Key") for an `ssh://`/`git@`
remote, or a personal access token embedded in (or supplied via a stored
credential helper for) an `https://` remote. Without one of these, `git
pull` will either fail outright or hang waiting for a credential prompt
that never comes (there's no interactive terminal when it's invoked from
`deploy.sh`'s `ssh` command).

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
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Real Postgres credentials for the `db` container. Pick a strong password — this is the production database. **Note:** `POSTGRES_PASSWORD` is only used by the official Postgres image to *initialize* the database on its very first startup (i.e. the first time the `pgdata` volume is created). Changing it in `.env` later does **not** change the running database's actual password — the two will drift, and the backend's `DATABASE_URL` connection will start failing. To actually rotate it, change the password inside Postgres itself (e.g. `ALTER USER ... PASSWORD ...`) and update `DATABASE_URL` to match, or wipe and recreate the volume (destroying existing data) if that's acceptable. |
| `DATABASE_URL` | SQLAlchemy connection string the backend uses. Keep the host as `db` (the Compose service name), e.g. `postgresql://personfin:<your password>@db:5432/personfin`, matching whatever you set above. **Note:** this is a URL — if the password contains characters like `@`, `:`, `/`, or `%`, they must be percent-encoded (e.g. `p@ss/word` → `p%40ss%2Fword`) or the connection string will parse incorrectly. |
| `JWT_SECRET` | Secret key the backend signs/verifies its own JWTs with. Generate a strong random value, e.g. `openssl rand -hex 32` — do not reuse a value from local development. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | The real production OAuth client from Section 1. |
| `UPLOAD_DIR` | Leave as `/data/uploads` — this is the in-container path backed by the `uploads` named volume in `docker-compose.yml`; don't repoint it. |
| `FX_API_KEY` | Optional — leave blank if the FX-rate feature isn't needed. |
| `OPENAI_API_KEY` | **Required** — a real OpenAI API key. Used for screenshot vision extraction (the `gpt-4o-mini` model; the backend won't start without this), and optionally for insight narration (`/insights` degrades gracefully with `narrative_unavailable=True` if that feature's own call ever fails, but the key itself is mandatory). |

Never commit this file — it's git-ignored, and `.env.example` is the only
version tracked.

**A caution about special characters:** this one `.env` file is parsed by
two independent tools — Docker Compose's own dotenv parser, and (for
`deploy/backup-postgres.sh`) your login shell, which sources it directly
as a shell script (`. .env`). The two don't necessarily agree on how to
handle shell-special characters. To avoid any value being interpreted
differently by the two, avoid `$`, backticks, `#`, and unescaped quotes
in any value here — especially `POSTGRES_PASSWORD` and the other secrets
— or quote the value carefully (single-quoting the whole value is
usually safest) if one of those characters is unavoidable.

### 2.3 Create the frontend webroot

```bash
mkdir -p /var/www/finance-frontend
```

This must match `VPS_FRONTEND_WEBROOT` in `deploy/deploy.config.sh`
(Section 3) — `deploy/deploy.sh` rsyncs the Flutter web build here, and
`deploy/nginx-finance.itluobo.com.conf`'s `location /` block serves straight
out of this same path (`root /var/www/finance-frontend;`). If you use a
different path, update it consistently in all three places.

### 2.4 Create the DNS record, the site, and the TLS cert

Unlike this VPS's other sites, `finance.itluobo.com` has no DNS record, no
nginx site file, and no certificate yet — all three need to be created,
following the same Certbot pattern this VPS's other sites already use
(see e.g. `/etc/nginx/sites-available/pca.itluobo.com`).

1. **DNS:** at your domain's DNS provider, create an `A` record for
   `finance.itluobo.com` pointing at this VPS's public IP (the same IP
   `proxy.itluobo.com` resolves to). Wait for it to resolve
   (`dig +short finance.itluobo.com`) before continuing — Certbot's HTTP-01
   challenge in the next step will fail otherwise.
2. **Minimal HTTP site**, so Certbot has a server block to extend:
   ```bash
   cat > /etc/nginx/sites-available/finance-itluobo << 'EOF'
   server {
       listen 80;
       listen [::]:80;
       server_name finance.itluobo.com;
       root /var/www/finance-frontend;
   }
   EOF
   ln -s /etc/nginx/sites-available/finance-itluobo /etc/nginx/sites-enabled/finance-itluobo
   nginx -t && systemctl reload nginx
   ```
3. **Issue the certificate** (adds the `listen 443 ssl` block and the
   HTTP→HTTPS redirect automatically, the same way it did for this VPS's
   other sites):
   ```bash
   certbot --nginx -d finance.itluobo.com
   ```
4. **Add PersonFin's `location` blocks.** Open
   `/etc/nginx/sites-available/finance-itluobo` and copy every `location`
   block from this repo's `deploy/nginx-finance.itluobo.com.conf` (the
   `/api/` proxy, the `/` SPA fallback, and the no-cache headers for the
   Flutter PWA's own versioning files) into the `server { }` block
   Certbot just added the `listen 443 ssl` directives to (the plain `:80`
   block Certbot leaves in place is just the redirect — leave it alone).
5. Validate and reload:
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
relies on `bash`'s `set -euo pipefail` to catch a failed `pg_dump` even when
only the downstream `gzip` in the pipe appears to succeed (and to fail
loudly on an unset variable, e.g. a `.env` missing `POSTGRES_USER`, instead
of silently passing an empty value to `pg_dump`). Invoking it via `sh`
would silently run it under a shell that doesn't support `pipefail`,
defeating that safety check — a dump that fails midway could then be
written out and kept as if it were a good backup. Always let the script's
own shebang pick its interpreter.

Also confirm `docker` and `docker compose` are usable non-interactively by
whatever user cron runs this as (typically `root`, if that's who owns
`/opt/personfin`).

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
   | `VPS_USER` | The SSH user for `proxy.itluobo.com` (e.g. `root`). |
   | `VPS_HOST` | `proxy.itluobo.com` |
   | `VPS_REPO_DIR` | The path you cloned the repo to in Section 2.1 (e.g. `/opt/personfin`). |
   | `VPS_FRONTEND_WEBROOT` | The path you created in Section 2.3 (e.g. `/var/www/finance-frontend`). |
   | `API_BASE_URL` | `https://finance.itluobo.com/api` |
   | `GOOGLE_CLIENT_ID` | The real production Client ID from Section 1. |

2. Run the deploy script:
   ```bash
   deploy/deploy.sh
   ```
   This first checks that your local working tree is clean and (if an
   upstream is configured) pushed — it refuses to proceed otherwise, since
   the frontend bundle built below comes from your local tree while the
   backend comes from whatever the VPS's `git pull` fetches, and those
   must match. It then SSHes in to `git pull` and
   `docker compose up -d --build backend` on the VPS first (which also
   runs `alembic upgrade head` automatically via the backend container's
   entrypoint before it starts serving), and only *after* that succeeds
   builds the Flutter web release bundle locally (`flutter build web
   --release` with the `API_BASE_URL` and `GOOGLE_CLIENT_ID` above baked
   in via `--dart-define`) and `rsync`s it to `VPS_FRONTEND_WEBROOT` on the
   VPS. Backend-before-frontend is deliberate: if the backend deploy fails,
   the script stops before the live frontend is ever touched, rather than
   leaving a new frontend talking to a backend that never finished
   upgrading.

3. Confirm the backend container is healthy:
   ```bash
   ssh "$VPS_USER@$VPS_HOST" "cd $VPS_REPO_DIR && docker compose ps"
   ```
   (Substitute the real values, or just run it by hand on the VPS.)

## 4. Post-deploy smoke test

A short manual checklist against the real production URL — mirrors the
same end-to-end walkthrough used when the frontend was first wired
together, but now against `https://finance.itluobo.com` instead of a local
backend.

1. Visit `https://finance.itluobo.com` and confirm the login screen renders,
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
   `OPENAI_API_KEY` wasn't set).
7. Sign out and confirm the app returns to `/login`.

If any step fails, check `docker compose logs backend` on the VPS first —
most first-deploy issues are a missing/incorrect value in `.env` (Section
2.2) or a `GOOGLE_CLIENT_ID` mismatch between the Flutter build and the
backend's `.env` (Section 1).
