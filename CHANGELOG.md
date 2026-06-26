# Changelog

All notable changes to `syslog-alert-router.sh` are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [2.4.0] - 2026-06-26
### Added
- **Menu-driven interface.** Running the script with no arguments now launches
  an interactive top-level menu covering install/update, relay management, test
  mail, rule dry-run, config validation, filter regeneration, MTA setup, manual
  sweep, legacy disable, and uninstall.
- `menu` and `status` subcommands. `status` reports dispatcher/sweeper presence,
  syslog-ng, generated filter, sweeper cron, local MTA, and configured relays.
- This CHANGELOG.

### Changed
- A bare invocation now opens the menu instead of running `install`. All
  non-interactive subcommands are unchanged and remain available for scripting.

## [2.3.0] - 2026-06-26
### Added
- **Auto-sudo.** Subcommands that need root re-exec the script under `sudo`
  automatically (preserving arguments, with a re-exec guard). `help`, `version`,
  `test`, and `check` run without elevation.
- **Automatic prerequisite installation** on first install: `syslog-ng`,
  `python3`, `python3-yaml`, `cron`, and `ca-certificates`, via `apt`/`dnf`/`yum`.
  Only missing packages are installed; the package manager is not invoked when
  everything is already present.

### Changed
- `preflight` installs missing prerequisites instead of aborting.

### Notes
- A mail transport is intentionally **not** auto-installed: delivery topology
  (direct vs. relay, which smarthost) cannot be guessed safely. Use the relay
  menu or `setup-mta`.

## [2.2.0] - 2026-06-25
### Added
- **Multiple mail relays** with an ordered failover chain. Sending moved into the
  dispatcher via stdlib `smtplib`; the local sendmail binary is now just one
  relay transport (the default `local` relay).
- **Per-alert relay override** via `relay:` / `relays:` in `alerts.yaml`.
- **Secured credentials.** Per-relay passwords live in `0600` files under a
  `0700` `secrets/` directory (or are fetched via a `secret_cmd`, e.g. `gpg`).
  `relays.yaml` stores only references, never passwords.
- Interactive relay manager and `alert-relays.py` CLI (list/add/del/set-order/
  check); `relays.yaml` bootstrap; `mailtest [--relay NAME]`.
- Per-relay TLS mode (`none`/`starttls`/`tls`), optional `tls_verify: false`,
  envelope `from`, and `timeout`.

### Security
- Passwords are never written to config or logs and never passed on the command
  line. Group/other-readable secret files trigger a warning.

## [2.1.0] - 2026-06-24
### Added
- MTA detection and reuse; the installer keeps an existing `/usr/sbin/sendmail`.
- Optional `setup-mta` to install a send-only MTA (msmtp relay, or postfix as a
  satellite/Internet Site).
- `mailtest ADDR` to verify the mail path end to end.

### Changed
- Filesystem layout follows the FHS: state in `/var/lib/alerts`, logs in
  `/var/log/alerts`, config under `/etc/alerts`.

## [2.0.0] - 2026-06-23
### Added
- Rewrite as a **YAML-driven framework**: `alerts.yaml`, `recipients.yaml`, and
  text + HTML templates with a generic fallback.
- **Persistent SQLite deduplication** that survives dispatcher restarts; alert
  severity; recipient groups.
- **Escalation** and **digest** handling via a cron-driven sweeper
  (`alert-sweeper.py`).
- Hardening: header/HTML injection escaping, per-line crash isolation, config
  hot-reload, validate-before-reload of the syslog-ng fragment, rotating logs,
  bounded SQLite growth (pruning).
- Coarse syslog-ng filter generated from `alerts.yaml` (single source of truth).

### Changed
- Replaced the INI rules table with YAML; split into a long-lived dispatcher
  plus a time-driven sweeper.

## [1.0.0] - 2026-06-23
### Added
- Initial installer. INI rules table (`rules.ini`), a single dispatcher fed by a
  syslog-ng `program()` destination, coarse filter generated from the rules,
  config hot-reload, in-memory deduplication and per-recipient token-bucket rate
  limiting, plus `regen`, `test`, `disable-legacy`, and `uninstall`.
