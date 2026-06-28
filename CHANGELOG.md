# Changelog

All notable changes to `syslog-alert-router.sh` are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [3.2.2] - 2026-06-27
### Added
- **Change `match_mode` from the menu.** The rule submenu now shows the active
  mode in its header (`Alert Rules (match_mode: first)`) and has an `m)` option to
  switch first/all; also `alert-rules.py match-mode [first|all]`. Other settings
  in `alerts.yaml` are preserved.
- The per-rule override (`stop`) was already shown in the rule list and in
  `s) show alert details`; the header now makes the global mode visible too.

## [3.2.1] - 2026-06-27
### Added
- **Reorder alert rules** from the rule submenu (`o`) and via
  `alert-rules.py order "NAME1,NAME2,..."`, mirroring relay ordering. Rule order
  is the evaluation order, so this controls which rule wins in `match_mode: first`
  and where a `stop` rule short-circuits in `match_mode: all`. Listed rules move
  to the front in the given order; omitted rules keep their relative order at the
  end, so partial reordering works without retyping everything.

## [3.2.0] - 2026-06-27
### Added
- **Multiple-match support.** A single log line can now fire more than one rule.
  New `settings.match_mode`:
  - `first` (default, unchanged): stop at the first matching rule, in file order.
  - `all`: fire every matching rule, each with its own recipients/relay/template
    and its own dedup signature (so no rule suppresses another).
- Per-alert **`stop: true`** flag (editable via the rule menu and
  `alert-rules.py --stop`): in `all` mode, matching this rule halts evaluation of
  later rules — firewall-style, e.g. to keep a broad catch-all from also firing.
- `test` (dry-run) now reports the match mode and shows **every** matched rule,
  not just the first.

## [3.1.3] - 2026-06-27
### Added
- Multi-choice prompts now **list the valid options inline**. When adding or
  editing an alert, the recipient-group, relay, template, and escalation-group
  prompts show what's defined (e.g. `available groups: ops, storage, security`);
  the mailtest relay prompt lists relays too. (Relay/group/alert name pickers
  already showed their lists.)

## [3.1.2] - 2026-06-27
### Added
- Dedicated **`/var/log/mail.log`** for Postfix relay activity (the managed
  syslog-ng config routes the `mail` facility there), so testing/auditing the
  SMTP relay no longer means grepping `/var/log/syslog`. Shown in `status`.

## [3.1.1] - 2026-06-27
### Added
- **Edit relay** in the relay manager (menu `e`, and `alert-relays.py edit`).
  Changes only the fields you supply and keeps the rest — so you can change a
  port or security mode without re-entering the host, user, auth, or secret.
  Previously the only way to change a relay was to re-add it under the same name
  (which required re-specifying every field).

## [3.1.0] - 2026-06-27
### Added
- **Outbound SMTP relay (smarthost).** The box now runs Postfix listening on
  **SMTP/25**, accepts mail only from **RFC 1918** clients (`mynetworks`, a
  `permit_mynetworks, reject` client restriction, and `reject_unauth_destination`
  so it is never an open relay), and forwards everything through the **default
  relay** — the first SMTP relay in the `relays.yaml` failover order. Point any
  LAN device's email at this box and it relays out via that relay.
- Postfix's smarthost (`relayhost`, TLS level, and SASL credentials) is derived
  from that relay, reusing its host/port/security and its 0600 secret (written to
  `/etc/postfix/sasl_passwd`, mode 0600). Editing relays in the relay manager
  re-syncs Postfix automatically on exit.
- `settings.smtp_relay_enable` (default true; false = sendmail only, no :25
  listener) and `settings.relay_networks` (default the RFC 1918 ranges).
- `status` now shows the SMTP relay listener and the active smarthost.

### Changed
- **Mailer is now Postfix, not msmtp.** msmtp cannot listen, which the relay role
  requires. Postfix provides `/usr/sbin/sendmail` for the box as before.
- `setup-mta` (re)configures Postfix from settings + the default relay; the
  `smarthost*` settings keys are removed (the smarthost lives in `relays.yaml`).

## [3.0.0] - 2026-06-27
Major refactor for a **dedicated log/alert appliance** (Ubuntu 24.04 /
syslog-ng 4.x). The script now owns syslog-ng instead of attaching to an
existing install, which removes the entire class of integration bugs hit in the
2.x line.

### Added
- The installer writes a **managed `syslog-ng.conf`** with its own listeners:
  `s_net` (UDP+TCP 514), `s_net_tls` (TLS 6514), and `s_local` (system+internal).
  `@version` is set from the installed syslog-ng so there is no "config too old"
  compatibility mode.
- **TLS listener** on 6514 with an auto-generated self-signed cert in
  `/etc/alerts/tls` (`peer-verify(optional-untrusted)`; drop in a CA-signed pair
  to replace). openssl added to prerequisites.
- **Per-host network archive** at `/var/log/remote/<host>/<date>.log`.
- **Listener + smarthost settings** in `alerts.yaml` (`listen_udp/tcp/tls`,
  `listen_local`, `smarthost*`) — still one source of truth.
- `msmtp` installed and configured as the system mailer (`/usr/sbin/sendmail`),
  with authenticated-smarthost support via a 0600 secret and `passwordeval`.
- The generated alert fragment references only sources defined in the base
  config, so a missing-source startup crash is structurally impossible.

### Changed
- Alert filter + dispatch path live in `conf.d/10-alert-router.conf` (was
  `alert-dispatch.conf`). `regen` rebuilds base config + fragment, then reloads.
- `status` reports listeners, base-config ownership, TLS cert, and mailer.
- `setup-mta` is msmtp-only and prompts for the smarthost password when needed.

### Removed
- Source auto-detection (`resolve_syslog_source`) and the `syslog_source`
  setting — the appliance defines its own sources.
- `disable-legacy` and the legacy `d_sendpage` handling.
- MTA-reuse heuristics and the Postfix path (msmtp only).

## [2.5.2] - 2026-06-26
### Fixed
- **Fragment hardcoded `source(net)`.** The generated log path referenced a
  source named `net`, which does not exist in most configs. syslog-ng failed to
  start with `Error resolving reference; content='source', name='net'` and
  systemd looped on it. `syslog-ng -s` (syntax check) does not resolve
  references, so it falsely reported the config valid. The generator now
  **auto-detects the network-receiving source** in your syslog-ng config,
  verifies the chosen source actually exists, and **refuses to write the
  fragment or touch syslog-ng** if it cannot resolve one — so a bad reference can
  no longer take the daemon down.

### Added
- `settings.syslog_source` in `alerts.yaml` to pin the source name explicitly
  (used when auto-detect finds zero or multiple network sources).
- `status` now shows the resolved `log source: source(NAME)` (or UNRESOLVED).
- Rule editor warns when a regex matches an empty string (e.g. a stray leading/
  trailing `|`), which would otherwise make an alert match every log line.

## [2.5.1] - 2026-06-26
### Fixed
- **Wrong control binary name.** Used `syslog-ngctl` instead of the real
  `syslog-ng-ctl` (with the dash), so the graceful reload path was never taken
  and it always fell back to systemctl.
- **False success reporting.** `regen` printed "syslog-ng reloaded" even when the
  reload/restart failed. `regen` and `install` now check the result, report the
  real outcome, and print the recent `journalctl -xeu syslog-ng` tail on failure.
- **Dangerous fallback removed.** Reload no longer escalates to a full restart on
  failure (which could take down a working daemon). Reload failures are reported;
  `install` still does an explicit, verified restart because dispatcher code
  changes require it.

## [2.5.0] - 2026-06-26
### Added
- **Alert-rule management in the menu** (and an `alert-rules.py` CLI). New
  "Manage alert rules + recipients" menu option and `rules` subcommand to
  add/edit/delete alerts and recipient groups without hand-editing YAML.
- Per-alert routing is now fully editable from the menu: each alert sets its own
  recipient group(s) **and** its own relay (single relay or a comma-separated
  failover chain), independent of other alerts and of the global relay `order`.
- Recipient-group management (add/edit/delete groups and their email lists).

### Changed
- Editing alert rules from the menu regenerates the syslog-ng filter and reloads
  automatically on exit when something changed.

## [2.4.3] - 2026-06-26
### Added
- Library version stamp (`alertlib.__version__`). `status` now reports the
  deployed library version and flags it as STALE when it does not match the
  script version, with a prompt to run `install`. This surfaces the common
  situation where the script was updated but the library on disk
  (`/usr/local/lib/alerts/alertlib.py`) was never redeployed — rebooting or
  editing relays does not update it; only `install` does.

## [2.4.2] - 2026-06-26
### Fixed
- `install` now **restarts** syslog-ng instead of only reloading it. syslog-ng
  keeps `program()` destination children running across a reload, so an updated
  dispatcher kept executing the old code in memory — which made the v2.4.1
  `From:`-header fix appear not to take effect for alerts routed through the
  long-lived dispatcher (the `From:` header still showed the global address
  while `X-Envelope-From` already used the relay's identity). Filter-only changes
  (`regen`) still use a lightweight reload.

## [2.4.1] - 2026-06-26
### Fixed
- An invalid relay name (e.g. a hostname typed into the name field) no longer
  crashes the script. The menu validates the name, shows a clear message, and
  stays open; all menu actions are now errexit-immune.
- The relay's envelope `from` is now applied to the visible `From:` header as
  well as the SMTP envelope. The message is built per relay, so a relay's
  identity is used for both header and envelope (and `sendmail` transport now
  passes `-f` for the envelope sender). Previously the `From:` header always
  showed the global address regardless of the relay's `from`.

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
