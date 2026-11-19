# Personal Finance AI

**Author:** netgeek1 & Claude (Anthropic) · **Version:** 1.0.1 (installer) · 1.0.0 (app) · **License:** MIT

A private, self-hosted personal-finance intelligence app. Import read-only bank and credit-card
statements (PDF, CSV, Excel) for any number of accounts and months; get categorized transactions,
dashboards, recurring-bill and subscription detection, unusual-spending alerts, budgets, savings
goals, an emergency-fund gauge, a debt payoff planner, and an assistant that answers questions **only
from your own data and shows its math**.

It never connects to a bank, never moves money, and never sells or shares your data.

---

## Contents

- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Trust model: what “verified” means](#trust-model-what-verified-means)
- [Security](#security)
- [Installer reference](#installer-reference)
- [Optional AI](#optional-ai)
- [Supported statement formats](#supported-statement-formats)
- [Development](#development)
- [Project layout](#project-layout)

---

## Quick start

Requires Ubuntu or Debian (amd64/arm64) and root. Docker is installed automatically if missing.

```bash
chmod +x personal-finance-ai-installer.sh
sudo ./personal-finance-ai-installer.sh            # interactive menu → 1) Full install
# or non-interactive:
sudo ./personal-finance-ai-installer.sh --install --yes
```

The wizard asks for a **TLS mode**:

| Mode | Use when | What happens |
|------|----------|--------------|
| `proxy` *(default)* | You already run a reverse proxy (Caddy, Nginx, HAProxy on OPNsense) with your wildcard cert | App listens on `BIND_ADDRESS:HOST_PORT` over HTTP; the proxy serves `https://finance.<your-domain>`. Session cookies are `Secure`, so sign-in only works **via HTTPS through the proxy**. Set `TRUSTED_PROXIES` to the proxy's IP. |
| `direct` | No proxy | The app serves HTTPS itself. Leave `TLS_CERT_FILE`/`TLS_KEY_FILE` empty to get a self-signed cert generated for you (browser warning), or point them at your wildcard cert. Browse with **https://**: plain `http://` to this port gets no reply. |
| `insecure-http` | LAN testing only | Plain HTTP with non-Secure cookies. Not for real data. |

`BIND_ADDRESS` defaults to `0.0.0.0` (reachable from your LAN). Use `127.0.0.1` only when the reverse proxy runs on the same host.

**Troubleshooting “it doesn't respond”:** `sudo personal-finance-ai --status` prints the exact URL and warns about the usual causes:
a `127.0.0.1` bind accessed from another machine, `http://` sent to a direct-TLS port, or proxy mode opened without HTTPS.

Then:

1. Open the web UI and **create your account** (12+ character password).
2. **Close registration:** `sudo personal-finance-ai --registration close` (or menu **A**).
3. **Back up the vault now:** `sudo personal-finance-ai --backup --portable`. The vault holds the data
   master key; without it, stored statements can't be decrypted.
4. In the app, go to **Settings → Accounts**, add your accounts (nickname, type, optional last 4 digits), then **Imports → upload**.

## How it works

```
upload → type sniffing & size limits → original encrypted at rest → parse in a sandboxed child process
       → preview (column mapping, sign convention, per-row confidence, duplicates flagged)
       → you commit → merchant normalization → categorization → reconciliation → dashboards
```

- **Imports are previews until you commit.** You can fix the column mapping, date format and sign
  convention, exclude rows, and enter statement balances first.
- **Duplicates:** an identical file is blocked. Overlapping statements are de-duplicated row by row,
  while genuine same-day repeats (two $5.75 coffees) inside one statement are kept.
- **Categorization order:** your rules (learned automatically when you correct a category) → built-in
  rules → optional AI → *Uncategorized*. Each transaction shows *why* it got its category.
- **Corrections are remembered.** Changing a category creates a merchant rule, applies it to that
  merchant's other transactions (never overriding ones you set by hand), and applies it to future imports.
- **Rollback:** any committed import can be rolled back; the original file is kept and downloadable.

### What you get

| Area | Features |
|------|----------|
| Dashboard | Income, spending, net cash flow, savings rate with prior-month deltas; 12-month income vs spending; category breakdown; budgets; unusual activity; top merchants; recurring payments |
| Transactions | Full-text search, filters (account, category, type, review state, categorized-by, date and amount ranges), inline category correction, review marking, CSV export |
| Insights | Net cash-flow trend, year-over-year, month comparison, category & merchant analysis, recurring/subscription detection with price-change flags, unusual activity, downloadable reports |
| Planning | Monthly budgets with projections, savings goals with required monthly saving, emergency fund (months of essential expenses covered), debt avalanche vs snowball with an extra-payment slider |
| Assistant | Natural-language questions with calculation steps, data scope and data-quality caveats. It refuses to answer for periods with no data rather than guessing. |
| Privacy | Export everything (JSON); delete account and all data (crypto-shredded) |

## Trust model: what “verified” means

The app never labels data as verified unless something actually verified it:

| Label | Meaning |
|-------|---------|
| **Parsed** | Machine-extracted from your file. Not yet checked by anyone. |
| **Reviewed** | You marked the transaction as checked. |
| **Reconciled** (import) | Opening balance + every statement transaction = closing balance, to the cent. |
| **Does not reconcile** (import) | The arithmetic is off; rows may be missing or misread. The difference is shown. |
| **No balances to reconcile** (import) | The file had no balances and you didn't enter them, so it couldn't be checked. |

Every dashboard and assistant answer surfaces these states. For example: “12 of 13 transactions are
machine-parsed and not yet reviewed.”

**The assistant never invents numbers.** Answers are produced by deterministic functions over your
transactions. If you enable an AI provider, it may only reword the computed answer. Any AI text
containing a number that isn't in the calculation is discarded and the computed answer is shown instead.

## Security

| Control | Implementation |
|---------|----------------|
| Passwords | argon2id (64 MiB, t=3); 12+ chars with complexity rule; constant-time handling of unknown emails |
| Brute force | Per-account lockout (5 failures → 15 min) + per-IP sliding-window throttle |
| Sessions | Opaque random token, stored hashed server-side; `__Host-` HttpOnly Secure SameSite=Strict cookie; idle + absolute timeouts; instant revocation |
| CSRF | Per-session token required on every state-changing request |
| Isolation | Every query is scoped by `user_id`; other users' objects return 404. Covered by tests. |
| Encryption at rest | Envelope encryption: per-user AES-256-GCM data key wrapped by the master key; original files and raw source rows encrypted with owner/purpose-bound associated data. Put `DATA_DIR` on an encrypted volume (LUKS / ZFS native encryption) to cover the database too. |
| Encryption in transit | HTTPS via your proxy or direct TLS; HSTS |
| Untrusted files | Size cap, magic-byte sniffing, macro/legacy-Excel/zip-bomb rejection, parsing in a separate process with CPU/memory/time limits, never rendered as HTML, downloads forced to `attachment` |
| Web | Strict CSP (`script-src 'self'`, no inline script/style, no third-party assets), `frame-ancestors 'none'`, `nosniff`, `no-referrer`; all statement text rendered via `textContent` (no XSS sinks) |
| Exports | CSV formula-injection neutralized |
| Container | Read-only root FS, all capabilities dropped, `no-new-privileges`, non-root service account, memory limit |
| Secrets | Master key + API key live in the installer's encrypted vault (systemd-creds/TPM or openssl) and are injected at start; never written to compose files |
| Audit | Logins, failures, imports, commits, rollbacks, corrections and privacy changes are logged per user |

**Out of scope by design:** bank connections and payments. TOTP/passkeys and OCR of scanned PDFs are on the roadmap (see `docs/IMPLEMENTATION_PLAN.md`).

## Installer reference

The installer follows the standard menu pattern used across the `netgeek1/scripts` tools: an
interactive menu, a full CLI, `--dry-run`, an encrypted vault, host-bound or portable backups, a
self-test, and an embedded app source (no tarball needed).

```text
--install | --apply | --rebuild | --start | --stop | --restart | --status | --logs [N]
--settings | --show-config | --set KEY VALUE
--api-key                       store/replace/remove the Anthropic API key (vault)
--registration open|close       allow/stop new sign-ups
--health                        in-container health check
--backup [--portable]           consistent backup (container paused briefly); includes the vault
--restore FILE                  restore; portable backups restore onto a fresh host
--rekey | --uninstall | --self-test | --app-self-test | --build-standalone OUT
--dry-run | --yes | --source DIR | --confirm KEYWORD
```

Key settings (`--show-config` lists all of them): `TLS_MODE`, `TLS_CERT_FILE`, `TLS_KEY_FILE`, `TRUSTED_PROXIES`,
`BIND_ADDRESS`, `HOST_PORT` (default 8090), `DATA_DIR`, `REGISTRATION_OPEN`, `MAX_UPLOAD_MB`,
`SESSION_IDLE_MINUTES`, `AI_OLLAMA_URL`, `AI_OLLAMA_MODEL`, `AI_ANTHROPIC_MODEL`, `MEM_LIMIT`, `BASE_IMAGE`.

> ⚠️ **Back up the vault.** Host backups include it; portable backups carry the master key encrypted with
> your passphrase. Lose both and the encrypted statement files are unrecoverable. That's intentional.

### Reverse-proxy example (Caddy)

```caddy
finance.example.net {
    tls /etc/ssl/wildcard/fullchain.pem /etc/ssl/wildcard/privkey.pem
    reverse_proxy 127.0.0.1:8090
    request_body { max_size 25MB }
}
```

## Optional AI

AI is **off by default** and is never needed. Rules handle categorization, and code computes every answer.

- **Ollama (local):** set `AI_OLLAMA_URL` (e.g. `http://192.168.0.5:11434`). Data stays on your network.
- **Anthropic API (cloud):** `--api-key`, then choose the model with `AI_ANTHROPIC_MODEL`.
- Each user must also opt in under **Settings → Privacy & AI** and allow sharing. Only merchant names
  (for categorization) and already-computed summaries (for wording) are sent: never files, account
  numbers or full transaction lists.

## Supported statement formats

| Format | Notes |
|--------|-------|
| CSV / TSV / TXT | Delimiter + header detection; single amount, debit/credit or type (DR/CR) columns; running balance; US/EU number formats; 20 date formats with ambiguity warnings |
| Excel `.xlsx` | First data-bearing sheet, real date/number cells; `.xlsm`, `.xls` and macro workbooks rejected |
| PDF (text-based) | Statement period and year inference (incl. Dec→Jan rollover), opening/closing balances, deposit/withdrawal sections, card sign conventions, multi-line descriptions; per-row confidence. Scanned/image PDFs are rejected, not guessed. |

Card exports that list purchases as positive numbers are detected and flipped automatically (with a
notice and a toggle).

## Development

```bash
cd backend
pip install -r requirements-dev.txt
export PFAI_MASTER_KEY=$(python -c "import os,base64;print(base64.b64encode(os.urandom(32)).decode())") PFAI_ALLOW_HTTP=1
python -m pytest -q                  # 68 tests: auth, isolation, crypto, parsers, dedupe, analytics, assistant
uvicorn app.main:create_app --factory --port 8080
python ../scripts/e2e_smoke.py http://127.0.0.1:8080 /tmp/shots   # Playwright browser smoke test
```

Environment variables (all `PFAI_*`): `MASTER_KEY` (required), `DATABASE_URL` (default SQLite; PostgreSQL
supported with `psycopg`), `DATA_DIR`, `ALLOW_HTTP`, `TLS_CERT`/`TLS_KEY`, `TRUSTED_PROXIES`, `REGISTRATION_OPEN`,
`MAX_UPLOAD_MB`, `MAX_PDF_PAGES`, `MAX_ROWS`, `PARSE_TIMEOUT`, `PARSE_MEMORY_MB`, `SESSION_IDLE_MINUTES`,
`SESSION_ABSOLUTE_HOURS`, `OLLAMA_URL`, `OLLAMA_MODEL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`.

## Project layout

```
personal-finance-ai-installer.sh   self-contained installer (app source embedded)
Dockerfile                         runtime + test stages
backend/app/                       FastAPI app
  ingest/                          sniffing, readers, CSV/XLSX/PDF parsers, sandbox, pipeline
  categorize/                      merchant normalization, rules engine, learned corrections
  analytics.py                     summaries, trends, recurring, anomalies, budgets, debt math
  assistant.py                     grounded Q&A tools + numeric grounding check
  routers/                         HTTP API
backend/tests/                     pytest suite + synthetic statement fixtures
frontend/                          no-build SPA (ES modules, vendored Chart.js 4.6.1)
docs/                              PRD, architecture & schema, implementation plan
scripts/e2e_smoke.py               end-to-end browser test
```
