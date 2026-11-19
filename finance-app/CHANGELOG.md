# Changelog

All notable changes to Personal Finance AI and its installer. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

Author: netgeek1 & Claude (Anthropic)

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
