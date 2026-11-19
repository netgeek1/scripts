# Changelog

All notable changes to Personal Finance AI and its installer. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

Author: netgeek1 & Claude (Anthropic)

## [1.2.0] - 2026-11-18

### Changed
- **Simplifi categories are kept exactly as they are in Simplifi**, including Parent:Child levels: `Kids:Allowance` becomes *Kids › Allowance*. They are no longer translated into built-in categories. Behind the scenes each category still knows which built-in group it behaves like (for example *Bills › Mobile Phone* acts like Phone & Internet), so bill detection and the emergency fund keep working. Allowance is explicitly not a bill.
- Category names show their full path everywhere (pickers, reports, budgets, assistant tables, CSV export). Pickers list your categories as a tree first, then the built-in ones.
- Account names are shown on their own. The "· Simplifi: <category>" suffix after the account in the transaction list and "Multiple (Simplifi)" in import history are gone.

### Added
- **Category management** (Settings → Categories): rename, move under another parent, merge into another category (transactions, rules, budgets and sub-categories move with it), delete unused categories, and add categories under a parent. Renaming a built-in category gives you your own copy with that name; built-in rules use it from then on.
- Insights → Categories: **Group by parent category** toggle.

### Fixed
- **Duplicate categories.** One import built a separate category lookup per account type, so a Simplifi category first seen on checking and again on a credit card was created twice. Lookups now go to the database, so a category is created once.
- A one-time repair on upgrade: duplicate categories are merged (keeping the one in use), imported transactions you haven't categorized by hand go back to their Simplifi category with its hierarchy, and flat categories left unused by the old mapping are removed. Categories you chose yourself are never changed.

## [1.1.2] - 2026-11-18

### Fixed
- **Assistant answers were one long run-on sentence.** List-type answers (subscriptions and bills, unusual activity, top merchants/categories, summary, income by source, month comparison, budgets) now show a one-line summary followed by proper tables with totals. Numbers in the tables are covered by the AI grounding check.
- **Transfers to your own accounts showed up as bills** (e.g. "Transfer To Certificate -0701"). Payees like "Transfer to/from …" and Simplifi categories such as Savings, Investments, Certificates/CDs, Retirement, IRA and 401k are now treated as transfers and left out of spending, bills and subscriptions.
- **Fuel, pharmacy and grocery purchases were listed as bills** (Wawa, Speedway, CVS). Only housing, utilities, phone/internet, insurance, loans, childcare, taxes and education count as bills. Frequent purchases with varying amounts are treated as habits and not listed.
- **Bills were split by amount** ("T-mobile ($213.76)"). A merchant is first assessed as a whole, so variable bills stay one line. Splitting is only used for several fixed-price subscription plans from one merchant, and same-price plans billed on different days are split by billing day ("Spotify (billed ~15th)", "Spotify (billed ~22nd)").
- **Simplifi "Auto Insurance"** was mapped to Transportation; insurance now takes priority.
- **Raw payee text** such as "Brightspeed 833-692-7773 Nc Brightspeed Xxx-xxx-7773 Nc" is cleaned to "Brightspeed". Payees Simplifi already cleaned are kept exactly as they are.
- The "Possible subscriptions" list only shows subscription-like candidates, not everyday purchases.

### Changed
- A one-time data fix runs on upgrade: it tidies raw payee names on imported Simplifi transactions (updating any category rules that referenced them) and re-categorizes imported transactions you haven't set by hand. Categories you chose yourself are never changed.

## [1.1.1] - 2026-11-18

### Fixed
- **Subscriptions were under-detected.** The old rules needed 3+ charges with an identical amount across the whole history, one charge per merchant per cycle, and a category on a short whitelist, so real exports reported only one or two subscriptions. Detection now:
  - splits a merchant's charges into amount streams, so Apple iCloud $2.99 and Apple Music $10.99 (or several PayPal/Google/Amazon plans) are detected separately;
  - judges "fixed price" on the last 3 charges, so a price increase (Netflix $15.49 → $17.99) no longer disqualifies it;
  - recognises subscription-like categories from Simplifi (Streaming, Software, Online Services, Memberships, Music, …) even when they became custom categories;
  - accepts two identical, correctly spaced charges as a **likely** subscription (labelled as such), useful for short exports;
  - widens the monthly window to ±5 days (February, billing-date drift) and accepts 60% regular gaps.
- Variable bills (phone, utilities) no longer show a misleading "price changed" flag; that note is for subscriptions only.

### Added
- **Possible subscriptions** list (Insights → Recurring) with the reason each one isn't counted yet (e.g. "only one charge in the imported data", "irregular timing") and the imported date range. The assistant reports these too.

## [1.1.0] - 2026-11-18

### Added (app 1.1.0)
- **Quicken Simplifi import.** A Simplifi CSV export (`Date,Account,Reviewed,Payee,Category,Exclusion,Amount`) is detected automatically and imported as one file covering every account:
  - Each row goes to the account named in its `Account` column. Accounts that don't exist yet are listed in an **Accounts in this file** step, where you create each one (name, type guessed from the name, optional last 4), map it to an existing account, or skip it. Commit stays blocked until every account has a decision.
  - Decisions are remembered: later exports map the same Simplifi account names automatically, and only new accounts are asked about.
  - `Payee` becomes the merchant name as-is. Simplifi categories are kept: known ones map to the built-in categories (e.g. Restaurants → Dining & Coffee, Paycheck → Salary, Credit Card Payment/Transfer → transfers), and unknown ones become your own custom categories. Your category corrections still take priority on future imports.
  - `Reviewed` rows are marked **Reviewed (Simplifi)** and `Exclusion` rows are imported but left out of dashboards, budgets and assistant totals. Each can be switched off per import.
  - De-duplication is per destination account, so overlapping exports only add new rows.
- Transactions can be excluded/included individually, filtered by exclusion, and show the source app's original category. The CSV export has an `excluded` column.
- An automatic schema migration upgrades existing 1.0.x databases in place. The SQLite table rebuild runs with foreign keys off outside a transaction, so no transactions are cascade-deleted, and it checks foreign keys afterwards.

### Fixed
- A stray "null" appeared on some pages (DOM `append()` rendering empty values). Views now use a null-safe helper.

## [1.0.1] - 2026-11-18

### Fixed (installer)
- `TLS_MODE=direct` with no certificate configured rendered an empty volume mount (`":/run/tls/cert.pem:ro"`), so the container never started. Direct mode now generates a self-signed certificate (ECDSA P-256, 825 days, SANs for the hostname, FQDN, LAN IP, localhost and 127.0.0.1) in `/etc/personal-finance-ai/tls/`, readable only by root and the service group. The compose file never contains an empty mount.
- The default `BIND_ADDRESS` was `127.0.0.1`, so the app was unreachable from other machines in every mode. It is now `0.0.0.0`. Choosing `direct` or `insecure-http` in the wizard moves a loopback bind to `0.0.0.0`.

### Added (installer)
- Status/start output explains the common "no response" causes: a loopback bind, `http://` sent to a direct-TLS port (it gets no reply), and proxy mode opened without HTTPS (sign-in won't stick).
- Direct mode with your own certificate checks that the service account can read the key and prints the exact `chgrp`/`chmod` fix if it can't.
- Self-test: no empty TLS mount, LAN-reachable default bind, self-signed generation with SANs (31 checks + 2 payload checks).

## [1.0.0] - 2026-11-18

### Added (app)
- Accounts with argon2id passwords, server-side sessions (`__Host-` HttpOnly/Secure/SameSite=Strict), CSRF tokens, per-account lockout and per-IP login throttling, audit log.
- Envelope encryption at rest: per-user AES-256-GCM data keys wrapped by a master key; original statements and raw source rows encrypted with owner/purpose-bound associated data; crypto-shredding on account deletion.
- Strict per-user data isolation (all queries scoped by user; cross-user access returns 404).
- Statement import for CSV/TSV, Excel `.xlsx` and text-based PDF: type sniffing, size/row/page limits, macro and zip-bomb rejection, parsing in a resource-limited `forkserver` child process.
- Column-role and date-format inference with manual mapping override; debit/credit and DR/CR handling; European number formats; automatic sign flip for card exports.
- PDF parsing with statement-period year inference, balance detection, deposit/withdrawal sections, card conventions and multi-line descriptions; per-row confidence; scanned PDFs rejected.
- Preview → commit workflow, row exclusion, duplicate-file blocking, overlap de-duplication that keeps genuine same-day repeats, possible-duplicate warnings, rollback, original-file download.
- Reconciliation (opening + transactions = closing) with honest import states: reconciled / does not reconcile / no balances.
- Merchant normalization; built-in categorization rules; learned rules from corrections applied to similar and future transactions; custom categories and rules; optional AI categorization (merchant names only, opt-in).
- Analytics: period summaries, savings rate, monthly series, category and merchant breakdowns, month comparison, year-over-year, recurring payment and subscription detection with price-change flags, anomaly detection (merchant outliers, category spikes, possible duplicate charges, new large merchants).
- Planning: budgets with projections, savings goals, emergency-fund coverage from essential spending, debt avalanche/snowball simulator with extra-payment comparison.
- Grounded assistant: deterministic tools with calculation steps, data scope and data-quality notes; refuses periods without data; optional LLM rewording with a numeric grounding check.
- Reports: filtered transaction CSV (formula-injection safe), monthly category × month report, full JSON export.
- Responsive, accessible no-build SPA: dashboard, imports, transactions, insights, planning, assistant, settings; light/dark themes; chart table views; strict CSP with vendored Chart.js 4.6.1.
- Test suite: 68 backend tests plus a Playwright end-to-end smoke test.

### Added (installer)
- `personal-finance-ai-installer.sh` built on the standard menu installer (`docker-base-install.sh` / gmail-filter-editor pattern): wizard, settings menus, full CLI, dry-run, run logs, lock file, self-test (29 checks incl. embedded-payload verification), embedded app source.
- Vault holds the generated 256-bit data master key and the optional Anthropic API key; both are injected at container start and never written to the compose file.
- TLS modes: `proxy` (default), `direct` (cert/key mounted read-only), `insecure-http` (LAN testing, warned).
- Hardened container: read-only root, all capabilities dropped, `no-new-privileges`, non-root service account, memory limit, health check.
- Consistent backups (container paused during archiving) in host-bound or portable (passphrase-encrypted) formats; portable restore onto a fresh host.
- Application menu and `--registration open|close`, `--health`, `--api-key`; `--app-self-test` builds the Dockerfile `test` stage and runs the suite in-image.
