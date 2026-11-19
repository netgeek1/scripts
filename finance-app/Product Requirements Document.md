# Personal Finance AI — Product Requirements Document

Author: netgeek1 & Claude (Anthropic) · Version 1.0 · 2026-11-18

## 1. Vision

A private, self-hosted finance intelligence platform. Users import read-only statements
(PDF, CSV, Excel) from any number of accounts and months, and get accurate, explainable
insight into income, spending, saving and debt. An assistant answers questions **only**
from the user's own imported data, shows its math, and never presents unverified data as
verified.

## 2. Principles (non-negotiable)

| # | Principle | How it shows up in the product |
|---|-----------|--------------------------------|
| P1 | **No fabrication** | Every number on screen or in an assistant answer is computed by code from stored transactions. The LLM (optional) only phrases text; answers containing numbers not produced by the calculation are rejected and replaced with the deterministic answer. |
| P2 | **Honest verification states** | Transactions are `parsed` (machine-extracted), `reviewed` (user confirmed), or belong to an import that is `reconciled` (statement opening + Σ transactions = closing balance). Nothing is labelled verified unless one of those is true. |
| P3 | **Source preservation** | The original file is stored encrypted and every transaction keeps its raw source row and line reference. |
| P4 | **Read-only** | No bank connections, no payments, no transfers. Aggregator linking is out of scope unless explicitly authorized in a future phase. |
| P5 | **Untrusted input** | Uploaded files are size-limited, type-sniffed, parsed in a resource-limited child process, and never executed or rendered as HTML. |
| P6 | **Privacy** | Data never leaves the host except to an LLM provider the user explicitly enables; data is never sold or shared. Full export and full delete are one click. |

## 3. Users

- **Primary:** an individual or household admin managing several checking, savings, credit
  card and loan accounts.
- **Secondary:** additional household members with their own isolated logins (no shared
  data between users in v1).

## 4. Functional requirements

### 4.1 Accounts & authentication
- FR-1 Registration/login with email + strong password (argon2id); lockout/rate limit on failed logins.
- FR-2 Server-side sessions in HttpOnly/Secure/SameSite=Strict cookies; CSRF tokens on state-changing requests; idle and absolute session timeouts.
- FR-3 Users manage financial accounts (name, institution, type, currency, last 4 digits only).

### 4.2 Statement import
- FR-4 Upload PDF, CSV, XLSX (≤ 20 MB, ≤ 200 PDF pages, ≤ 50k rows). `.xlsm`/macro files rejected.
- FR-5 Auto-detect columns (date, description, amount, or debit/credit, balance) and date format; user can override the mapping before committing.
- FR-6 Sign convention by account type (credit card charges are spending even when positive in the file); user can flip.
- FR-7 Preview with per-row parse confidence and warnings before commit.
- FR-8 Duplicate detection: identical file (SHA-256) blocked; overlapping statements flagged row-by-row by fingerprint; genuine same-day repeats within one statement preserved.
- FR-9 Reconciliation when opening/closing balances are found or entered.
- FR-10 Import history with status, counts (new / duplicate / skipped), and the ability to roll back an import.

### 4.3 Transactions & categorization
- FR-11 Normalized merchant name, date, amount, direction (income / expense / transfer), category.
- FR-12 Category assignment order: user rules learned from corrections → built-in rules → optional AI classifier → `Uncategorized`. Source and confidence are stored.
- FR-13 Correcting a category creates/updates a user rule and can re-apply it to past matching transactions.
- FR-14 Search and filter by text, date range, account, category, amount range, direction, review state; paginated.
- FR-15 Mark transactions reviewed; add notes; mark as transfer between own accounts (excluded from income/spend).

### 4.4 Insight
- FR-16 Dashboard: income, spending, net cash flow, savings rate for a chosen period, with prior-period comparison.
- FR-17 Category and merchant breakdowns; monthly trend; year-over-year comparison.
- FR-18 Recurring payment and subscription detection (cadence, typical amount, next expected date, price changes).
- FR-19 Unusual spending: per-merchant/category outliers, new large merchants, category spikes vs. trailing average.
- FR-20 Budgets per category per month with progress.
- FR-21 Savings goals and emergency fund (months of essential expenses covered).
- FR-22 Debt reduction planner (avalanche & snowball) from user-entered balances, APR, minimum payments.

### 4.5 Assistant
- FR-23 Natural-language questions answered from the user's data via deterministic tools.
- FR-24 Each answer includes: result, calculation steps, data scope (date range, # transactions, accounts), and a data-quality note (e.g. % unreviewed).
- FR-25 Refuses to guess when data is missing ("No transactions imported for March 2025").
- FR-26 Recommendations are derived from computed facts (e.g. subscriptions not used, categories over budget).

### 4.6 Reports & privacy
- FR-27 CSV export of filtered transactions (formula-injection safe); monthly summary report.
- FR-28 Export all my data (JSON); delete all my data (irreversible, confirmed).
- FR-29 Privacy settings: AI provider (off / local Ollama / Anthropic API), whether merchant text may be sent to the AI.

## 5. Non-functional requirements

| Area | Requirement |
|------|-------------|
| Security | TLS (reverse proxy), envelope encryption for files and raw rows (AES-256-GCM, per-user DEK wrapped by master KEK), DB on encrypted volume, strict CSP, no third-party CDNs. |
| Isolation | Every data access path is scoped by `user_id`; automated tests assert cross-user access returns 404. |
| Accuracy | Money stored as integer minor units (cents); no floats in storage or arithmetic. |
| Performance | Dashboard < 500 ms for 100k transactions on a modest host. |
| Accessibility | WCAG 2.2 AA: keyboard navigation, focus states, contrast ≥ 4.5:1, chart data also available as tables. |
| Responsiveness | Usable from 360 px phones to wide desktops. |
| Operability | Single Docker host deployment via menu installer; backups of DB + encrypted file store. |

## 6. Out of scope (v1)
Bank aggregation (Plaid etc.), payments/transfers, investment performance analytics, tax filing,
shared multi-user households, mobile native apps, OCR of scanned image-only PDFs (flagged as
unsupported rather than guessed).

## 7. Success metrics
- ≥ 98% of rows from supported CSV/XLSX exports extracted correctly; PDF parse confidence shown per row.
- ≥ 85% auto-categorization on first import; ≥ 95% after corrections.
- Zero assistant answers containing numbers not traceable to a calculation.
