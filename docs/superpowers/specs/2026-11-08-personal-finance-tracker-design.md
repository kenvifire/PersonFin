# Personal Finance Tracker — Design

## Intent and why

The user holds assets scattered across four jurisdictions (Canada, China,
Hong Kong, Singapore) in different account types (brokerage, cash, RRSP,
crypto), each reachable only through its own app/portal with no shared
API. There is currently no single place to see total net worth or how it's
allocated. Manually reading every account and doing the math is tedious
and he's not going to do it regularly.

The fix: a web app where the user (and, in principle, other users) uploads
screenshots from their various accounts. A vision model reads each
screenshot and extracts structured balance/holding data. The app rolls
everything up into one dashboard: net worth in a currency of choice,
allocation breakdown by asset class and by country, trend over time, and
flags when the current allocation drifts from a target the user has set
(or from a reasonable default the system suggests).

The system never acts on the user's money — no brokerage integration, no
automated trades or transfers. It observes (via screenshots), computes,
and advises. When an allocation looks off, the user creates their own
manual to-do to go fix it themselves.

## Goals

- Ingest screenshots of financial accounts (stocks, cash, RRSP, crypto) and
  extract structured data via a vision-capable LLM — down to the
  individual holding/line item inside an account (e.g. the specific
  stocks, cash balance, and bonds inside an RRSP), not just an account
  total. This is what lets allocation insights see through a wrapper
  account (RRSP, brokerage) to what it's actually invested in.
- Treat each account as a persistent entity the user can upload against
  repeatedly over time, building a history for that specific account
  rather than an unlabeled pile of numbers per upload.
- Roll up holdings across currencies (at minimum CAD, USD, CNY, HKD, SGD,
  plus crypto) into one total, in a display currency the user can switch.
- Show a breakdown of holdings by asset class and by country/currency.
- Suggest a reasonable default target allocation (e.g. max % in crypto,
  minimum cash buffer) that the user can edit to their own targets.
- Flag when actual allocation has drifted from the user's target.
- Let the user create and check off manual to-do items tied to a flagged
  drift (e.g. "trim crypto to get back under 10%").
- Support multiple users via Google sign-in, each user's data fully
  isolated from every other user's.
- Deploy as a containerized app behind the user's existing nginx reverse
  proxy on his VPS, reachable at `finance.itluobo.com`.

## Non-goals

- No live brokerage/bank API integrations (Plaid, bank OAuth, etc.) in
  this iteration — screenshot upload is the only ingestion path.
- No automated trading, transfers, or rebalancing actions taken by the
  system. Flags produce a manual to-do, never an automatic trade.
- No budgeting/spending tracking (categorized transactions, recurring
  bills) — this is an asset/net-worth tracker, not a budgeting app.
- No native mobile app packaging in this iteration — Flutter targets web
  only for now (the framework choice leaves a path open to mobile later,
  but building/signing/shipping a mobile app is out of scope).
- No admin console for managing other users; user management is limited
  to what Google sign-up naturally gives you.

## Anti-goals

(Things that would make this a failure even if it technically runs.)

- Any user's financial data visible to another user, even partially.
- Screenshots or extracted financial data leaving the user's own VPS to
  a third party beyond the two LLM API calls required (vision extraction,
  insight generation) and the FX-rate lookup.
- Silent misreads: if the vision model extracts a number wrong and the
  user never notices, the dashboard quietly lies to them. The extraction
  step must show the user what it read before committing it to history,
  not just save it straight to the database.
- A target allocation the system invented being presented as if the user
  set it themselves.

## Constraints

- Must run on the user's existing VPS: Docker + nginx already present.
  New services should fit that pattern (own Docker container(s), fronted
  by the existing nginx as reverse proxy at `finance.itluobo.com`).
- Vision extraction and text-based insight generation (allocation
  commentary, target suggestions) both use DeepSeek — originally vision
  used Azure OpenAI, switched to DeepSeek's `deepseek-flash` vision model
  after the user's Azure subscription had no usable Cognitive Services
  quota in any region.
- Auth is Google Sign-In (OAuth), open to any Google account signing up,
  not restricted to the user's own account.
- Multi-currency: at minimum CAD, USD, CNY, HKD, SGD, plus crypto
  (BTC/ETH-style assets valued via a market price feed, not FX).
- Data sensitivity is high (financial data across four jurisdictions) —
  secrets (API keys, OAuth client secret, DB credentials) must be
  environment-configured, never committed; container-to-container traffic
  should stay on an internal Docker network, only the web app port
  exposed through nginx.

## Decisions already made (not open to the builder)

- **Frontend:** Flutter, built for web, served as static assets.
- **Backend:** Python + FastAPI.
- **Database:** PostgreSQL (not SQLite) — multi-user, concurrent writes.
- **Deployment:** Docker Compose on the existing VPS; nginx (already
  running on the host) reverse-proxies `finance.itluobo.com` to the app
  container(s). The app does not manage its own TLS termination — that
  stays with the existing nginx/cert setup.
- **Vision extraction provider:** DeepSeek (`deepseek-flash`).
- **Insight-generation provider:** DeepSeek.
- **Auth:** Google OAuth sign-in, multi-user, data isolated per user by a
  `user_id` on every record.
- **Account identity and matching:** an account is a persistent entity
  (e.g. "RBC RRSP", "Binance"). An upload does not need to cover every
  account — the user can upload just one account's screenshot at any
  time. After extraction, the system proposes a match to an existing
  account (based on extracted identifying info such as institution name
  or account label) for the user to confirm; the user can also choose to
  create a new account instead when no match is right. Each confirmed
  upload becomes a new dated snapshot *for that account*, and snapshots
  are never overwritten or deleted.
- **"Current state" is a merge, not a single batch:** since accounts can
  be updated independently and on different schedules, the dashboard's
  "current" view is built from each account's most recent snapshot, which
  may be of different ages across accounts. The UI should make a stale
  account's last-updated date visible rather than implying everything is
  equally fresh.
- **Open access, no quota (accepted risk):** sign-up stays fully open to
  any Google account, with no invite list or usage limit in this
  iteration. This is a deliberate choice despite the real cost exposure
  of metered DeepSeek calls per upload — revisit if abuse or
  cost actually shows up, but nothing is built to guard against it now.
- **Allocation targets:** system proposes defaults, user edits them;
  edited targets are stored per-user and marked as user-set once touched.
- **Remediation model:** drift from target produces a flag in the UI and
  an option to create a to-do item; nothing is automated.
- **Extraction review step:** after a screenshot is parsed, the user sees
  the extracted fields and confirms/corrects them before they're saved as
  a snapshot (addresses the "silent misread" anti-goal above).
- **Historical rate locking:** each snapshot stores the FX/crypto
  conversion rate used at that time. Trend-over-time charts replay those
  locked rates, not today's rate — so a currency swing never shows up as
  a net-worth change that didn't actually happen.
- **Country vs. currency:** tracked as two separate fields on every
  holding, not one. A Singapore-custodied account holding USD-denominated
  US stock has a jurisdiction (Singapore) and a currency (USD) that
  differ, and both breakdowns need to reflect that correctly.
- **Screenshot retention:** the original uploaded image is kept on the
  VPS after extraction is confirmed (associated with its snapshot), so a
  questioned extraction can be re-checked against the source later. It is
  never sent anywhere beyond the one extraction API call.

## Frontend UX (decided during Plan 4 brainstorming)

The user's day-to-day usage is mostly from a phone browser, opportunistically
(snap one account screenshot whenever they happen to check it, not a batch
session), so the Flutter web app is designed mobile-first; desktop gets the
same screens with more breathing room, not a different layout.

- **Navigation:** a bottom tab bar with two tabs — Dashboard and
  Insights/To-dos. (The user's own call was to leave this to the builder;
  bottom tabs over a hamburger menu is the builder's choice, made for
  mobile thumb-reach.)
- **Dashboard (landing screen):** total net worth is the hero number,
  rolled up to the user's chosen display currency, with a small
  month-over-month delta underneath. Below it: a trend sparkline (tap to
  expand to full history), a drift alert banner that only appears when an
  allocation target is off (tapping it jumps to Insights/To-dos), and a
  breakdown list by country. A camera FAB in the bottom-right is the
  primary action — tap it to pick/snap a screenshot and start the upload
  flow immediately.
- **Upload → review flow:** picking a screenshot goes straight into an
  "extracting" state (short spinner, no separate upload confirmation
  step), then lands on an editable review screen — account, balance,
  currency, asset class, all pre-filled from the vision extraction and
  editable before saving. This is the required extraction-review step
  from the Key Decisions above, surfaced as the user asked: confirmed
  right away, not batched for later. Confirm and Discard are both always
  available; if extraction fails, the same screen appears with empty
  fields instead of pre-filled ones.
- **Insights/To-dos screen:** one screen combining allocation-vs-target
  bars (actual vs. target per asset class, drift visually flagged), the
  DeepSeek narrative text above those bars, and the manual to-do list
  (checkable items, add/complete) below.
- **Login:** a plain centered screen — app name and a single "Sign in
  with Google" button. Nothing else; settled without further discussion.

## Deployment (decided during Plan 5 — no brainstorming requested, these are the builder's own calls)

- **Containers:** Docker Compose with two services — `backend` (FastAPI +
  Uvicorn) and `db` (Postgres with a named volume for persistence,
  `depends_on` with a healthcheck gate). No separate frontend container —
  the Flutter web build is static output, served directly by the VPS's
  existing host nginx, consistent with the earlier decision that nginx
  owns TLS and fronts everything.
- **Path-space split (avoids a real collision):** the Flutter app's own
  client-side routes (`/login`, `/dashboard`, `/insights`, `/upload`) and
  several backend API paths (`/dashboard`, `/insights`, …) are literally
  the same strings. In production (single origin, unlike local dev's
  CORS-separated ports) this would collide. Fix: nginx proxies
  `location /api/ { proxy_pass http://127.0.0.1:8000/; }` (stripping the
  `/api` prefix — the backend's route code needs zero changes) and
  everything else falls through to the Flutter build with SPA fallback
  (`try_files $uri $uri/ /index.html;`). The frontend is built with
  `--dart-define=API_BASE_URL=https://finance.itluobo.com/api`.
- **Networking:** `backend`/`db` share an internal Compose network;
  `backend` additionally binds `127.0.0.1:8000:8000` on the host so the
  host's nginx process (not itself containerized) can reach it. No
  container port is exposed beyond localhost — nginx is still the only
  thing the internet reaches, per the existing constraint.
- **Migrations:** `alembic upgrade head` runs automatically in the
  backend container's entrypoint, before Uvicorn starts. No separate
  migration-runner service — simplest reliable choice for a
  single-operator deployment.
- **Secrets:** one git-ignored `.env` file on the VPS (DB credentials,
  DeepSeek key, Google OAuth client ID/secret, session signing secret),
  referenced via Compose's `env_file:`. Never committed.
- **Deploy workflow:** manual and SSH-triggered, no CI/CD pipeline — a
  single `deploy.sh` script in the repo that does `git pull`, rebuilds
  the `backend` image, runs `flutter build web` with the production
  `--dart-define`s, and syncs the build output into the directory the
  host nginx serves. Matches the spec's existing "no admin console,
  solo-operator" framing — this is a personal tool, not a team's
  production service.
- **Google OAuth (production):** a one-time manual step in Google Cloud
  Console — create a production OAuth 2.0 Web Client with Authorized
  JavaScript origin `https://finance.itluobo.com` (the web Google
  Sign-In flow used by the frontend is origin-based, not a redirect
  flow, so no redirect URI is needed). This can't be scripted from here;
  the plan documents the exact steps for the user to follow once.
- **Backups:** a daily cron job on the VPS running `pg_dump` against the
  `db` container's volume, written to a local backups directory with
  simple rotation (delete anything older than N days). No off-VPS backup
  destination — matches the project's personal/solo scale.
- **Observability/logging:** no external log aggregation. Uvicorn/FastAPI
  logs go to stdout, captured by Docker's default `json-file` log driver
  with size-based rotation configured in Compose. `docker compose logs`
  is the debugging tool. Revisit only if this genuinely becomes hard to
  operate.

## What's left to the builder

- Exact FastAPI project layout and Postgres schema/migrations tooling
  (e.g. Alembic).
- Choice of FX-rate data source (any reputable free/low-cost API) and
  crypto price source, and how often rates refresh.
- Specific DeepSeek model/endpoint wiring, read from environment
  configuration.
- Prompt design for vision extraction (per-account-type parsing) and for
  insight/target-suggestion generation.
- Exact set of default target-allocation heuristics suggested to a new
  user (e.g. emergency-fund-in-cash rule of thumb, max single-asset
  concentration) — reasonable personal-finance defaults, not something
  the user dictated.
- Flutter visual styling (colors, typography, spacing) and component-level
  implementation details beyond the screen content decided above.
- Exact account-matching heuristic (which extracted fields to compare,
  confidence threshold for proposing a match vs. just prompting the user
  to pick/create).
- Line-item asset-class taxonomy (the specific set of categories a stock,
  bond, cash position, or crypto holding gets classified into).
- Session/token handling details for Google OAuth (library choice, token
  storage/refresh strategy).
