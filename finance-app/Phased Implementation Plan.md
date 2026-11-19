# Personal Finance AI — Phased Implementation Plan

Author: netgeek1 & Claude (Anthropic) · 2026-11-18

Each phase ends with an automated test gate; the next phase starts only when it passes.

| Phase | Scope | Exit test gate |
|-------|-------|----------------|
| 0 | PRD, architecture, schema, plan | Reviewed docs |
| 1 | Secure core: config, DB models, argon2 auth, sessions, CSRF, security headers, envelope encryption, accounts CRUD, per-user scoping, audit log | Auth flows; CSRF enforced; lockout; cross-user access → 404; encryption round-trip & tamper detection |
| 2 | Import pipeline: sniffing, size limits, sandboxed parse, CSV/XLSX/PDF parsers, mapping override, sign conventions, staging, dedupe, commit, rollback, reconciliation, import history | Fixture statements parse exactly; hostile files rejected; overlap dedupe; same-day repeats kept; reconciliation pass/fail |
| 3 | Merchant normalization, system categories, built-in rules, learned rules from corrections, re-apply, optional AI classifier | Normalization cases; correction creates rule and recategorizes; precedence order |
| 4 | Analytics: summary, trends, categories, merchants, YoY, recurring/subscriptions, anomalies, budgets, goals, emergency fund, debt avalanche/snowball, CSV/report export | Hand-computed expectations on fixture data; debt schedule math; CSV injection escaping |
| 5 | Assistant: router, tools, calculation/provenance output, LLM providers, grounding check | Answers match analytics; no-data refusal; fabricated-number LLM output rejected |
| 6 | Frontend SPA: login, dashboard, imports (upload→preview→commit), transactions, insights, planning, assistant, settings/privacy | Smoke test in a real browser; keyboard nav; responsive layouts |
| 7 | Docker image, compose, menu installer (app embedded), README/CHANGELOG/LICENSE | Build image; end-to-end smoke test through the container |

## Later (requires explicit authorization)
- TOTP 2FA and WebAuthn passkeys
- OCR for scanned PDFs (local Tesseract) — still flagged as `parsed`, never verified
- Shared household spaces with role-based access
- Read-only aggregator connection (only with explicit opt-in)
