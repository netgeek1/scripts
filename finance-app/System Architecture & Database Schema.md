# Personal Finance AI — System Architecture & Database Schema

Author: netgeek1 & Claude (Anthropic) · Version 1.0 · 2026-11-18

> Note: the parse sandbox uses a `forkserver` child process with RLIMIT_AS/CPU/NOFILE limits and a wall-clock timeout.

## 1. Overview

```
 Browser (SPA, vanilla ES modules, vendored Chart.js, strict CSP)
        │  HTTPS (reverse proxy: Caddy/Nginx/OPNsense HAProxy terminates TLS)
        ▼
 FastAPI app (uvicorn) ──────────────┐
  ├─ auth/session/CSRF middleware    │
  ├─ routers (accounts, imports, ... )│
  ├─ ingest/  (sniff → sandboxed parse → normalize → dedupe → stage)
  ├─ categorize/ (merchant normalizer, rules, learned rules, optional LLM)
  ├─ analytics/ (cash flow, recurring, anomalies, debt math)
  └─ assistant/ (intent router → deterministic tools → optional LLM phrasing → grounding check)
        │
        ├── SQLite (WAL) on /data by default · PostgreSQL optional · SQLAlchemy 2
        └── Encrypted file store  /data/files/<user_id>/<uuid>.bin  (AES-256-GCM)
                                   optional ─► Ollama (local) or Anthropic API
```

## 2. Key technical decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Backend | Python 3.12+, FastAPI, SQLAlchemy 2 | Best-in-class PDF/Excel parsing libraries (pdfplumber, openpyxl); typed request validation via Pydantic. |
| Database | SQLite (WAL) on the data volume by default; PostgreSQL supported via `PFAI_DATABASE_URL` | A household-scale app is well within SQLite's limits, and a single container keeps the installer, backups and restores simple. The same ORM models run on PostgreSQL for multi-household or high-concurrency deployments. |
| Money | `BIGINT` minor units (cents) + ISO currency | Floats cause rounding drift; integer math is exact. |
| Frontend | No-build vanilla ES modules + vendored Chart.js | No Node toolchain in production, tiny supply-chain surface, a strict CSP (`script-src 'self'`) is easy to enforce. |
| Sessions | Opaque random token → server-side session row (hashed) | Instant revocation; nothing sensitive in the cookie. JWTs were rejected because they can't be revoked cleanly. |
| Encryption at rest | Envelope encryption: per-user DEK (AES-256-GCM) wrapped by a master KEK from the environment/secret; DB volume on encrypted storage (LUKS/ZFS native encryption) | Files and raw source rows are the most sensitive, least-queried data, so they're encrypted at the app layer. Amounts/dates stay queryable in plaintext columns inside an encrypted volume, because column-encrypting them would make aggregation impossible. Deleting a user's DEK crypto-shreds their files. |
| Parsing isolation | Parser runs in a child process with CPU-time, memory and wall-clock limits | Malformed/hostile PDFs or zip-bomb XLSX can't take down the app. |
| AI | Provider interface: `none` (default) / `ollama` / `anthropic` | Local-first privacy. The LLM never computes money; it only classifies merchant names (opt-in) and rewords computed results. |
| Verification | Three explicit states + import reconciliation | Satisfies "never claim verified when it is not". |

## 3. Request security pipeline

1. Reverse proxy terminates TLS (HSTS). App also sets `Secure` cookies and refuses non-HTTPS in production mode unless `PFAI_ALLOW_HTTP=1` (lab only).
2. Security headers on every response: CSP `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Permissions-Policy`.
3. Session lookup → `current_user`. All repository functions take `user_id` and add it to every `WHERE`.
4. Mutating requests require `X-CSRF-Token` matching the session's CSRF token.
5. Login protection: per-IP sliding-window throttle + per-account lockout (5 failures → 15 min); argon2id with a dummy-hash verify for unknown emails to equalize timing.

## 4. Import pipeline

```
upload → size check → magic-byte sniff (PDF %PDF / XLSX zip with [Content_Types].xml / CSV text)
       → SHA-256 (duplicate-file check per user)
       → encrypt & store original
       → child process parse (limits: 60 s, 1 GB RAM)
            CSV : delimiter sniff, header detection, column role inference, date-format inference
            XLSX: openpyxl read-only, data_only, first sheet with a header row; uncompressed-size cap
            PDF : pdfplumber text lines → date/description/amount regex, multi-line descriptions,
                  opening/closing balance detection; image-only PDFs flagged unsupported
       → normalize (cents, sign convention by account type, merchant normalization)
       → fingerprint & dedupe (account, date, amount, normalized description, occurrence #)
       → staged rows (status: preview)  ──user reviews mapping──►  commit
       → categorize → reconcile (if balances) → import status: committed / reconciled / unbalanced
```

## 5. Assistant design

1. **Intent routing**: deterministic keyword/period/category/merchant router. (LLM-based tool selection is a possible later enhancement; v1 keeps routing deterministic.)
2. **Tools** (pure functions over the user's data): `spend` (category/merchant), `overview`, `income`, `savings`, `compare`, `top`, `recurring`, `anomalies`, `budgets`, `emergency`, `debt`, `recommend`.
3. Each tool returns `{answer, calculation[], scope{from,to,period,accounts,txn_count}, quality{...}, recommendations[], notes[], data}`.
4. **Phrasing**: deterministic template, or (opt-in) an LLM given only the tool output.
5. **Grounding check**: every number in LLM text must match a number in the tool output (after formatting normalization); otherwise the template answer is returned.

## 6. Database schema

All tables carry `user_id` (except `users`) with `ON DELETE CASCADE`. Money = `BIGINT` cents.

```sql
users(id PK, email UNIQUE, password_hash, created_at, wrapped_dek BYTEA,
      ai_provider TEXT DEFAULT 'none', ai_share_merchants BOOL DEFAULT false,
      failed_logins INT, locked_until TIMESTAMP)

sessions(id PK, user_id FK, token_hash UNIQUE, csrf_token, created_at, last_seen, expires_at,
         ip, user_agent)

accounts(id PK, user_id FK, name, institution, account_type   -- checking|savings|credit_card|loan|cash|other
         , currency CHAR(3), last4 CHAR(4) NULL, created_at, archived BOOL)

imports(id PK, user_id FK, account_id FK, filename, file_type, file_sha256, file_size,
        storage_path, status            -- preview|committed|reconciled|unbalanced|failed|rolled_back
        , column_mapping JSON, parse_warnings JSON,
        statement_start DATE, statement_end DATE,
        opening_balance_cents, closing_balance_cents, reconciliation_diff_cents, flip_sign BOOL,
        rows_total, rows_new, rows_duplicate, rows_skipped,
        created_at, committed_at,
        UNIQUE(user_id, file_sha256))

staged_rows(id PK, import_id FK, user_id FK, line_no, raw_enc BYTEA,
            date, description, amount_cents, balance_cents, confidence REAL,
            warnings JSON, fingerprint, duplicate_of NULL, include BOOL)

categories(id PK, user_id FK NULL  -- NULL = system category
           , name, kind   -- expense|income|transfer
           , essential BOOL, color)

transactions(id PK, user_id FK, account_id FK, import_id FK NULL,
             date DATE, amount_cents BIGINT   -- negative = money out
             , currency, description_raw, merchant, category_id FK,
             category_source            -- user|user_rule|rule|ai|none
             , category_confidence REAL,
             direction                  -- income|expense|transfer
             , status                   -- parsed|reviewed
             , fingerprint, source_line, raw_enc BYTEA, notes, created_at,
             INDEX(user_id, date), INDEX(user_id, merchant), INDEX(user_id, category_id),
             UNIQUE(user_id, account_id, fingerprint))

category_rules(id PK, user_id FK, match_type  -- merchant_exact|contains
               , pattern, category_id FK, hits, created_at)   -- newest rule wins

budgets(id PK, user_id FK, category_id FK, monthly_limit_cents, UNIQUE(user_id, category_id))

goals(id PK, user_id FK, name, kind   -- savings|emergency_fund
      , target_cents, current_cents, target_date NULL)

debts(id PK, user_id FK, name, balance_cents, apr_bps INT, min_payment_cents)

audit_log(id PK, user_id FK, action, detail JSON, ip, created_at)
```

## 7. Deployment

`personal-finance-ai-installer.sh` (standard menu installer, app embedded) renders a single-service compose file:
`app` (uvicorn, UID-mapped service account, read-only root FS, all caps dropped, `no-new-privileges`, `/data` volume, tmpfs `/tmp`).
TLS modes: `proxy` (reverse proxy terminates HTTPS; `TRUSTED_PROXIES` honoured for client IPs), `direct` (uvicorn serves HTTPS with mounted cert/key), `insecure-http` (LAN testing).
Secrets: the 256-bit master key and optional Anthropic API key live in the installer's encrypted vault (systemd-creds/TPM or openssl) and are injected as environment variables at start; they are never written to disk in the compose file.
Backups: the container is paused briefly while `/data` (SQLite + encrypted files), settings and the vault are archived — host-bound tar.gz or passphrase-encrypted portable archive. The vault must be backed up: it holds the master key.
