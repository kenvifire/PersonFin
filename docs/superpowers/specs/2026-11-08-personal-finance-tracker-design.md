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
  proxy on his VPS, reachable at `finance.itlubo.com`.

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
  by the existing nginx as reverse proxy at `finance.itlubo.com`).
- Vision extraction uses Azure OpenAI (GPT-4o-mini or similar vision-
  capable deployment) — the user has Azure access and wants to use it.
- Text-based insight generation (allocation commentary, target
  suggestions) uses DeepSeek — cheaper, text-only.
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
  running on the host) reverse-proxies `finance.itlubo.com` to the app
  container(s). The app does not manage its own TLS termination — that
  stays with the existing nginx/cert setup.
- **Vision extraction provider:** Azure OpenAI.
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
  of metered Azure OpenAI/DeepSeek calls per upload — revisit if abuse or
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

## What's left to the builder

- Exact FastAPI project layout, Postgres schema/migrations tooling
  (e.g. Alembic), and Docker Compose service breakdown (how many
  containers, networking details).
- Choice of FX-rate data source (any reputable free/low-cost API) and
  crypto price source, and how often rates refresh.
- Specific Azure OpenAI deployment/model name and DeepSeek model/endpoint
  wiring, read from environment configuration.
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
- Observability/logging approach, backup strategy for the Postgres data
  volume.
