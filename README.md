# syslog-alert-router

A self-contained, **menu-driven** installer that turns a clean Ubuntu 24.04 box
into a dedicated **syslog-ng → email alert appliance** that is also an **outbound
SMTP relay** for your LAN. It receives syslog from your network gear, classifies
messages against rules you define in YAML, deduplicates them, and emails the
right people — with escalation, digests, and multiple SMTP relays with failover.
It also accepts SMTP on port 25 from RFC 1918 clients and relays their mail out
through your smarthost.

The whole thing is one shell script with the Python pipeline embedded inside it.
Run it with no arguments and you get a menu; everything is driven from there.

```
network gear ──(UDP/TCP 514, TLS 6514)──▶ syslog-ng ──▶ alert-dispatcher.py
local logs   ──(system, internal)────────▶              classify · dedup (SQLite)
                                                         render · route · send
LAN devices  ──(SMTP/25, RFC 1918 only)──▶ Postfix ─────┐  escalation · digests
                                                         ▼  (alert-sweeper, cron)
                                          default relay (first in relays.yaml)
                                                         │ failover order
                                                         ▼
                                              upstream smarthost (e.g. provider SMTP)
```

On a dedicated box the script **owns syslog-ng and Postfix**: it writes their
configs with its own listeners, so there is nothing pre-existing to attach to.

---

## Requirements

- Ubuntu 24.04 (syslog-ng 4.x). Other apt-based distros generally work.
- Root (the script elevates itself via `sudo` when needed).
- Prerequisites installed automatically on first run: `syslog-ng-core`,
  `python3`, `python3-yaml`, `cron`, `openssl`, `ca-certificates`, `postfix`.

---

## Quick start

```bash
chmod +x syslog-alert-router.sh
./syslog-alert-router.sh          # opens the menu
```

Pick **1) Install / update everything**, then work down the menu: add a relay
(option 3), define alerts and recipients (option 2), send a test (option 4).
See `QUICKSTART.md` for the same flow as copy-paste commands.

---

## The main menu

Running the script with no arguments prints current status, then this menu:

```
----------------------------------------------------------------------
  1) Install / update everything       6) Validate configuration
  2) Manage alert rules + recipients   7) Regenerate filter + base config
  3) Manage relays + credentials       8) Configure mail relay (Postfix/smarthost)
  4) Send a test email                 9) Configure log archive + retention
  5) Dry-run a rule (sample log line) 10) Run sweep now (escalate/digest)
                                       u) Uninstall    q) Quit
----------------------------------------------------------------------
```

| Option | What it does |
|---|---|
| **1) Install / update everything** | Installs prerequisites, deploys the code, writes the managed `syslog-ng.conf` (listeners + archive), generates the alert filter, generates a self-signed TLS cert if missing, installs/configures Postfix, installs the sweeper cron job, and restarts syslog-ng. Run this for a fresh install, after updating the script, or after changing listeners. It restarts syslog-ng so updated dispatcher code is loaded. |
| **2) Manage alert rules + recipients** | Opens the rule submenu: add/edit/delete/reorder alerts, set the match mode, and manage recipient groups (see below). |
| **3) Manage relays + credentials** | Opens the relay submenu: add/edit/delete/test SMTP (or sendmail) relays, set the failover order, and store passwords securely (see below). The first SMTP relay in the order is the default relay and the Postfix smarthost. |
| **4) Send a test email** | Sends a real test message to an address you enter, optionally through one named relay (it lists the available relays). Confirms the mail path end to end. |
| **5) Dry-run a rule** | Feeds a sample log line through classification and shows every rule it matches and the rendered email(s) — without sending or touching the dedup database. |
| **6) Validate configuration** | Parses `alerts.yaml` / `recipients.yaml` / `relays.yaml` and prints a summary (alert count, groups, relays). Non-zero exit on error. |
| **7) Regenerate filter + base config** | Rebuilds `syslog-ng.conf` and the alert fragment from `alerts.yaml`, then reloads syslog-ng (graceful, no restart). Use after editing listeners or regex by hand. |
| **8) Configure mail relay (Postfix/smarthost)** | (Re)configures Postfix from `settings` plus the default relay: listener on :25 for RFC 1918, smarthost = first SMTP relay, TLS and SASL credentials from that relay. |
| **9) Configure log archive + retention** | Interactive submenu to set the archive root, subpath, line template, perms, today/yesterday symlinks, gzip/delete retention, and headerless facility/priority. Applies via regen on exit. |
| **10) Run sweep now** | Runs the escalation/digest/prune pass immediately instead of waiting for the 5-minute cron. Sends any due escalations and digests. |
| **u) Uninstall** | Removes the code, the alert fragment, and the cron job. Keeps config, secrets, the SQLite database, and the managed `syslog-ng.conf` (so logging keeps working). |
| **q) Quit** | Exit the menu. |

### Submenu: Alert rules + recipients (option 2)

```
========== Alert Rules (match_mode: first) ==========
  DISK_FULL    sev=high     -> storage  relay=alerts_dreamhost  digest  stop  escalate->management@4h
  ...
------------------------------------------------
  a) add/edit alert   s) show alert details
  o) reorder rules    d) delete alert
  m) match mode (first/all)   g) recipient groups   q) done
```

The header shows the active **match mode**, and each rule line shows its
per-rule overrides (`relay=`, `digest`, `stop`, `escalate->`).

| Option | What it does |
|---|---|
| **a) add/edit alert** | Prompts for name, match regex, severity, recipient group(s), relay(s), template, digest, stop, and escalation. Multi-choice prompts list the valid options inline. Blank keeps the current value, so the same flow edits an existing rule. Warns if a regex matches every line. |
| **s) show alert details** | Prints one rule's full YAML definition (all fields). |
| **o) reorder rules** | Shows current order and accepts a new comma-separated order. Rule order is the evaluation order. Rules you omit keep their relative order at the end, so partial reordering works. |
| **d) delete alert** | Removes a rule by name. |
| **m) match mode (first/all)** | Switches the global matching mode: `first` = one rule per line (first match wins, in rule order); `all` = every matching rule fires. |
| **g) recipient groups** | Opens the group sub-submenu (below). |
| **q) done** | Leaves the submenu; if anything changed, regenerates the filter and reloads. |

Recipient-group sub-submenu (`g`):

```
  a) add/edit group   d) delete group   q) back
```

| Option | What it does |
|---|---|
| **a) add/edit group** | Creates or updates a group: a name and a comma-separated list of email addresses. |
| **d) delete group** | Removes a group by name. |
| **q) back** | Returns to the rule submenu. |

### Submenu: Relays + credentials (option 3)

```
================ Relay Manager ================
Failover order: local, default
  local          sendmail  /usr/sbin/sendmail
  default        smtp  smtp.dreamhost.com:587  starttls  auth=True  secret=/etc/alerts/secrets/default.pw
-----------------------------------------------
  a) add relay      e) edit relay
  o) set order      p) set password
  t) test relay     d) delete relay
  q) quit
```

| Option | What it does |
|---|---|
| **a) add relay** | Adds a relay: `smtp` (host, port, security none/starttls/tls, optional auth + user) or `sendmail`. For auth, it prompts for and stores the password securely. |
| **e) edit relay** | Shows the current definition and changes only the fields you supply (blank = keep) — so you can change a port or security mode without re-entering host, user, auth, or secret. |
| **o) set order** | Sets the failover order (comma-separated names). The first SMTP relay in the order is the default relay and Postfix's smarthost. |
| **p) set password** | Stores/updates a relay's password in `/etc/alerts/secrets/<name>.pw` (mode 0600). |
| **t) test relay** | Sends a test message through one specific relay (via smtplib, directly — not through Postfix) and prints the result on screen. |
| **d) delete relay** | Removes a relay by name. |
| **q) quit** | Leaves the submenu; re-syncs Postfix's smarthost with the (possibly changed) default relay. |

### Mail relay configuration (option 8)

Configures Postfix as a smarthost: it listens on **SMTP/25**, accepts mail only
from **RFC 1918** clients, and relays through the default relay (the first SMTP
relay in `relays.yaml`), reusing that relay's host/port/TLS and its stored
credentials. It's never an open relay. Driven by `smtp_relay_enable` and
`relay_networks` in settings; leaving the relay manager also triggers this sync.

---

## Matching model

By default each log line fires **one** rule (`match_mode: first` — rules are
evaluated in file order; the first match wins). Set `match_mode: all` (option 2 →
`m`) to fire **every** matching rule, each with its own recipients, relay,
template, and its own dedup signature so no rule suppresses another. Add
**`stop: true`** to a rule (the add/edit prompt) so that, in `all` mode, matching
it halts evaluation of later rules — useful to let a specific rule pre-empt a
broad catch-all. `test` (option 5) shows the mode and every rule a line matches.

---

## Outbound SMTP relay (smarthost for the LAN)

Besides alerting, the box is a send-only mail relay for your internal network.
Point any LAN device's email (NAS, hypervisor, UPS, scripts) at this box's IP on
port 25; it relays out via the default relay. External clients are refused and
relaying is limited to `mynetworks` with `reject_unauth_destination`, so it is
never an open relay. Relay activity is logged to `/var/log/mail.log` (look for
`postfix/smtp` with `status=sent`).

---

## Configuration

Everything lives under `/etc/alerts/config/`. The dispatcher picks up edits to
recipients, severity, template, relay, order, and match mode **live** (within a
couple seconds); changing a `regex` or a listener also needs a regen/install.

### `alerts.yaml`

```yaml
settings:
  from: monitor@syslog.example.net
  dedup_window_sec: 1h
  digest_interval_sec: 1h
  active_grace_sec: 15m
  prune_after_sec: 7d
  match_mode: first        # first = one rule per line; all = every matching rule

  # syslog-ng listeners (re-run install after editing)
  listen_udp: 514          # 0 / false to disable
  listen_tcp: 514
  listen_tls: 6514         # uses /etc/alerts/tls/{cert,key}.pem
  listen_local: true       # collect this box's own logs

  # outbound SMTP relay (Postfix). Smarthost = first SMTP relay in relays.yaml.
  smtp_relay_enable: true  # false = sendmail only, no :25 listener
  relay_networks: '127.0.0.0/8,[::1]/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'

alerts:
  DISK_FULL:
    regex: 'filesystem full|No space left on device'
    severity: high
    recipients: storage          # a group, or [group1, group2]
    relay: alerts_dreamhost       # or [primary, backup] for failover; omit = default order
    template: disk_full
    stop: true                    # (match_mode: all) don't let later rules also fire
    escalation_after: 4h
    escalation_group: management
```

Per-alert keys: `regex` (required), `program` / `program_exclude` (optional regex on `$PROGRAM` — only-fire-if / never-fire-if),
`host` / `host_exclude` (optional regex on the sending `$HOST` — only-fire-if / never-fire-if),
`severity`, `recipients`, `relay`/`relays`, `template`, `subject`, `digest: true`,
`stop: true`, `dedup_window`, `dedup_key` (regex with a capture group to split
dedup, e.g. per source IP), `escalation_after` + `escalation_group`.

### `recipients.yaml`

```yaml
groups:
  ops:      [ops@example.com]
  storage:  [storage@example.com, oncall@example.com]
  security: [secteam@example.com]
```

### `relays.yaml`

Managed through the relay submenu (option 3). Holds relay definitions under
`relays.defs` and the failover `relays.order`; credentials are referenced by file
(`secret_file`), never stored inline.

---

## Sending devices to the box

- **Syslog (plain):** UDP or TCP **514**
- **Syslog (encrypted):** TLS **6514** — senders that verify certificates must
  trust `/etc/alerts/tls/cert.pem`, or replace that pair with a CA-signed
  cert/key (key mode 0600) and re-run install.
- **Email:** SMTP **25** from any RFC 1918 address — relayed out via the
  smarthost.

Received syslog is archived under `/logs/$YEAR/$MONTH/$DAY/$HOST/$HOUR-syslog.log` by default.
The archive is configurable (`archive_root`, `archive_subpath`, `archive_template`,
perms, etc.) to reproduce a classic `YEAR/MONTH/DAY/HOST/HOUR` log-server layout, and
a generated `alert-logmaint.sh` cron handles `today`/`yesterday` symlinks plus gzip
(`archive_compress_after_days`, default 1) and retention (`archive_delete_after_days`,
default 90).

---

## Command-line interface (for scripting)

The menu is the primary interface, but every action has a subcommand:

```
syslog-alert-router.sh [command] [options]

  (no args) | menu          Interactive menu (default)
  status                    Install / listener / mailer / relay status
  install                   Install everything; own syslog-ng + Postfix
  rules                     Alert-rule + recipient-group submenu
  relays                    Relay submenu
  mailtest [--relay NAME] ADDR   Send a test email (optionally via one relay)
  setup-mta                 (Re)configure Postfix from settings + the default relay
  regen                     Rebuild base config + filter, reload
  test "<msg>" [program]    Dry-run a rule (no send)
  check                     Validate the YAML config
  sweep                     Run escalation/digest/prune once
  uninstall                 Remove code + fragment + cron (keeps config/secrets/DB)
  version | help
```

The submenu managers also have non-interactive subcommands, e.g.
`alert-rules.py order "A,B"`, `alert-rules.py match-mode all`,
`alert-relays.py edit --name default --port 465 --security tls`.

---

## File layout

| Path | Purpose |
|---|---|
| `/etc/syslog-ng/syslog-ng.conf` | Managed base config (listeners, archive, mail log) |
| `/etc/syslog-ng/conf.d/10-alert-router.conf` | Generated alert filter + dispatch |
| `/usr/local/lib/alerts/alertlib.py` | Shared library |
| `/usr/local/bin/alert-{dispatcher,sweeper,relays,rules}.py` | Pipeline + managers |
| `/etc/alerts/config/{alerts,recipients,relays}.yaml` | Configuration |
| `/etc/alerts/templates/*.{txt,html}` | Email templates |
| `/etc/alerts/secrets/<name>.pw` | Relay credentials (0600) |
| `/etc/alerts/tls/{cert,key}.pem` | TLS listener cert |
| `/etc/postfix/sasl_passwd` | Smarthost SASL credential (0600) |
| `/var/lib/alerts/alerts.db` | SQLite state (dedup, escalation, digest queue) |
| `/var/log/alerts/*.log` | Dispatcher / sweeper logs |
| `/var/log/mail.log` | Postfix relay activity (mail facility) |
| `/var/log/remote/<host>/<date>.log` | Received-log archive |
| `/etc/cron.d/alert-sweeper` | Sweeper schedule |

---

## Logs

- **Alert delivery (via SMTP relays):** `/var/log/alerts/dispatcher.log`.
- **Sweeper (escalation/digest):** `/var/log/alerts/sweeper.log`.
- **Mail relay (Postfix, port 25 / sendmail):** `/var/log/mail.log`.
- **Everything received over the network:** `/var/log/remote/<host>/<date>.log`.

---

## Security notes

- Passwords never live in YAML; they sit in 0600 files under
  `/etc/alerts/secrets/`. Postfix's smarthost password is written only to
  `/etc/postfix/sasl_passwd` (mode 0600).
- The SMTP relay accepts only RFC 1918 clients and refuses to relay to external
  destinations from anyone else — it is not an open relay.
- The TLS syslog listener uses `peer-verify(optional-untrusted)` so devices
  without client certs can connect over an encrypted channel; replace the
  self-signed cert for production trust.

---

## Troubleshooting

- `status` shows whether the library is current, which listeners are active,
  whether the base config is managed, the mailer, the SMTP relay, and the
  smarthost.
- If syslog-ng won't start after an install/regen, the script reports the failure
  and prints the recent journal. Inspect: `systemctl status syslog-ng` and
  `journalctl -xeu syslog-ng`.
- After editing dispatcher/library code, run **install** so syslog-ng restarts
  and loads it; `status` flags a stale library otherwise.

See `CHANGELOG.md` for version history.# syslog-alert-router

A self-contained, **menu-driven** installer that turns a clean Ubuntu 24.04 box
into a dedicated **syslog-ng → email alert appliance** that is also an **outbound
SMTP relay** for your LAN. It receives syslog from your network gear, classifies
messages against rules you define in YAML, deduplicates them, and emails the
right people — with escalation, digests, and multiple SMTP relays with failover.
It also accepts SMTP on port 25 from RFC 1918 clients and relays their mail out
through your smarthost.

The whole thing is one shell script with the Python pipeline embedded inside it.
Run it with no arguments and you get a menu; everything is driven from there.

```
network gear ──(UDP/TCP 514, TLS 6514)──▶ syslog-ng ──▶ alert-dispatcher.py
local logs   ──(system, internal)────────▶              classify · dedup (SQLite)
                                                         render · route · send
LAN devices  ──(SMTP/25, RFC 1918 only)──▶ Postfix ─────┐  escalation · digests
                                                         ▼  (alert-sweeper, cron)
                                          default relay (first in relays.yaml)
                                                         │ failover order
                                                         ▼
                                              upstream smarthost (e.g. provider SMTP)
```

On a dedicated box the script **owns syslog-ng and Postfix**: it writes their
configs with its own listeners, so there is nothing pre-existing to attach to.

---

## Requirements

- Ubuntu 24.04 (syslog-ng 4.x). Other apt-based distros generally work.
- Root (the script elevates itself via `sudo` when needed).
- Prerequisites installed automatically on first run: `syslog-ng-core`,
  `python3`, `python3-yaml`, `cron`, `openssl`, `ca-certificates`, `postfix`.

---

## Quick start

```bash
chmod +x syslog-alert-router.sh
./syslog-alert-router.sh          # opens the menu
```

Pick **1) Install / update everything**, then work down the menu: add a relay
(option 3), define alerts and recipients (option 2), send a test (option 4).
See `QUICKSTART.md` for the same flow as copy-paste commands.

---

## The main menu

Running the script with no arguments prints current status, then this menu:

```
----------------------------------------------------------------------
  1) Install / update everything       6) Validate configuration
  2) Manage alert rules + recipients   7) Regenerate filter + base config
  3) Manage relays + credentials       8) Configure mail relay (Postfix/smarthost)
  4) Send a test email                 9) Configure log archive + retention
  5) Dry-run a rule (sample log line) 10) Run sweep now (escalate/digest)
                                       u) Uninstall    q) Quit
----------------------------------------------------------------------
```

| Option | What it does |
|---|---|
| **1) Install / update everything** | Installs prerequisites, deploys the code, writes the managed `syslog-ng.conf` (listeners + archive), generates the alert filter, generates a self-signed TLS cert if missing, installs/configures Postfix, installs the sweeper cron job, and restarts syslog-ng. Run this for a fresh install, after updating the script, or after changing listeners. It restarts syslog-ng so updated dispatcher code is loaded. |
| **2) Manage alert rules + recipients** | Opens the rule submenu: add/edit/delete/reorder alerts, set the match mode, and manage recipient groups (see below). |
| **3) Manage relays + credentials** | Opens the relay submenu: add/edit/delete/test SMTP (or sendmail) relays, set the failover order, and store passwords securely (see below). The first SMTP relay in the order is the default relay and the Postfix smarthost. |
| **4) Send a test email** | Sends a real test message to an address you enter, optionally through one named relay (it lists the available relays). Confirms the mail path end to end. |
| **5) Dry-run a rule** | Feeds a sample log line through classification and shows every rule it matches and the rendered email(s) — without sending or touching the dedup database. |
| **6) Validate configuration** | Parses `alerts.yaml` / `recipients.yaml` / `relays.yaml` and prints a summary (alert count, groups, relays). Non-zero exit on error. |
| **7) Regenerate filter + base config** | Rebuilds `syslog-ng.conf` and the alert fragment from `alerts.yaml`, then reloads syslog-ng (graceful, no restart). Use after editing listeners or regex by hand. |
| **8) Configure mail relay (Postfix/smarthost)** | (Re)configures Postfix from `settings` plus the default relay: listener on :25 for RFC 1918, smarthost = first SMTP relay, TLS and SASL credentials from that relay. |
| **9) Configure log archive + retention** | Interactive submenu to set the archive root, subpath, line template, perms, today/yesterday symlinks, gzip/delete retention, and headerless facility/priority. Applies via regen on exit. |
| **10) Run sweep now** | Runs the escalation/digest/prune pass immediately instead of waiting for the 5-minute cron. Sends any due escalations and digests. |
| **u) Uninstall** | Removes the code, the alert fragment, and the cron job. Keeps config, secrets, the SQLite database, and the managed `syslog-ng.conf` (so logging keeps working). |
| **q) Quit** | Exit the menu. |

### Submenu: Alert rules + recipients (option 2)

```
========== Alert Rules (match_mode: first) ==========
  DISK_FULL    sev=high     -> storage  relay=alerts_dreamhost  digest  stop  escalate->management@4h
  ...
------------------------------------------------
  a) add/edit alert   s) show alert details
  o) reorder rules    d) delete alert
  m) match mode (first/all)   g) recipient groups   q) done
```

The header shows the active **match mode**, and each rule line shows its
per-rule overrides (`relay=`, `digest`, `stop`, `escalate->`).

| Option | What it does |
|---|---|
| **a) add/edit alert** | Prompts for name, match regex, severity, recipient group(s), relay(s), template, digest, stop, and escalation. Multi-choice prompts list the valid options inline. Blank keeps the current value, so the same flow edits an existing rule. Warns if a regex matches every line. |
| **s) show alert details** | Prints one rule's full YAML definition (all fields). |
| **o) reorder rules** | Shows current order and accepts a new comma-separated order. Rule order is the evaluation order. Rules you omit keep their relative order at the end, so partial reordering works. |
| **d) delete alert** | Removes a rule by name. |
| **m) match mode (first/all)** | Switches the global matching mode: `first` = one rule per line (first match wins, in rule order); `all` = every matching rule fires. |
| **g) recipient groups** | Opens the group sub-submenu (below). |
| **q) done** | Leaves the submenu; if anything changed, regenerates the filter and reloads. |

Recipient-group sub-submenu (`g`):

```
  a) add/edit group   d) delete group   q) back
```

| Option | What it does |
|---|---|
| **a) add/edit group** | Creates or updates a group: a name and a comma-separated list of email addresses. |
| **d) delete group** | Removes a group by name. |
| **q) back** | Returns to the rule submenu. |

### Submenu: Relays + credentials (option 3)

```
================ Relay Manager ================
Failover order: local, default
  local          sendmail  /usr/sbin/sendmail
  default        smtp  smtp.dreamhost.com:587  starttls  auth=True  secret=/etc/alerts/secrets/default.pw
-----------------------------------------------
  a) add relay      e) edit relay
  o) set order      p) set password
  t) test relay     d) delete relay
  q) quit
```

| Option | What it does |
|---|---|
| **a) add relay** | Adds a relay: `smtp` (host, port, security none/starttls/tls, optional auth + user) or `sendmail`. For auth, it prompts for and stores the password securely. |
| **e) edit relay** | Shows the current definition and changes only the fields you supply (blank = keep) — so you can change a port or security mode without re-entering host, user, auth, or secret. |
| **o) set order** | Sets the failover order (comma-separated names). The first SMTP relay in the order is the default relay and Postfix's smarthost. |
| **p) set password** | Stores/updates a relay's password in `/etc/alerts/secrets/<name>.pw` (mode 0600). |
| **t) test relay** | Sends a test message through one specific relay (via smtplib, directly — not through Postfix) and prints the result on screen. |
| **d) delete relay** | Removes a relay by name. |
| **q) quit** | Leaves the submenu; re-syncs Postfix's smarthost with the (possibly changed) default relay. |

### Mail relay configuration (option 8)

Configures Postfix as a smarthost: it listens on **SMTP/25**, accepts mail only
from **RFC 1918** clients, and relays through the default relay (the first SMTP
relay in `relays.yaml`), reusing that relay's host/port/TLS and its stored
credentials. It's never an open relay. Driven by `smtp_relay_enable` and
`relay_networks` in settings; leaving the relay manager also triggers this sync.

---

## Matching model

By default each log line fires **one** rule (`match_mode: first` — rules are
evaluated in file order; the first match wins). Set `match_mode: all` (option 2 →
`m`) to fire **every** matching rule, each with its own recipients, relay,
template, and its own dedup signature so no rule suppresses another. Add
**`stop: true`** to a rule (the add/edit prompt) so that, in `all` mode, matching
it halts evaluation of later rules — useful to let a specific rule pre-empt a
broad catch-all. `test` (option 5) shows the mode and every rule a line matches.

---

## Outbound SMTP relay (smarthost for the LAN)

Besides alerting, the box is a send-only mail relay for your internal network.
Point any LAN device's email (NAS, hypervisor, UPS, scripts) at this box's IP on
port 25; it relays out via the default relay. External clients are refused and
relaying is limited to `mynetworks` with `reject_unauth_destination`, so it is
never an open relay. Relay activity is logged to `/var/log/mail.log` (look for
`postfix/smtp` with `status=sent`).

---

## Configuration

Everything lives under `/etc/alerts/config/`. The dispatcher picks up edits to
recipients, severity, template, relay, order, and match mode **live** (within a
couple seconds); changing a `regex` or a listener also needs a regen/install.

### `alerts.yaml`

```yaml
settings:
  from: monitor@syslog.example.net
  dedup_window_sec: 1h
  digest_interval_sec: 1h
  active_grace_sec: 15m
  prune_after_sec: 7d
  match_mode: first        # first = one rule per line; all = every matching rule

  # syslog-ng listeners (re-run install after editing)
  listen_udp: 514          # 0 / false to disable
  listen_tcp: 514
  listen_tls: 6514         # uses /etc/alerts/tls/{cert,key}.pem
  listen_local: true       # collect this box's own logs

  # outbound SMTP relay (Postfix). Smarthost = first SMTP relay in relays.yaml.
  smtp_relay_enable: true  # false = sendmail only, no :25 listener
  relay_networks: '127.0.0.0/8,[::1]/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'

alerts:
  DISK_FULL:
    regex: 'filesystem full|No space left on device'
    severity: high
    recipients: storage          # a group, or [group1, group2]
    relay: alerts_dreamhost       # or [primary, backup] for failover; omit = default order
    template: disk_full
    stop: true                    # (match_mode: all) don't let later rules also fire
    escalation_after: 4h
    escalation_group: management
```

Per-alert keys: `regex` (required), `program` (optional gate on `$PROGRAM`),
`host` / `host_exclude` (optional regex on the sending `$HOST` — only-fire-if / never-fire-if),
`severity`, `recipients`, `relay`/`relays`, `template`, `subject`, `digest: true`,
`stop: true`, `dedup_window`, `dedup_key` (regex with a capture group to split
dedup, e.g. per source IP), `escalation_after` + `escalation_group`.

### `recipients.yaml`

```yaml
groups:
  ops:      [ops@example.com]
  storage:  [storage@example.com, oncall@example.com]
  security: [secteam@example.com]
```

### `relays.yaml`

Managed through the relay submenu (option 3). Holds relay definitions under
`relays.defs` and the failover `relays.order`; credentials are referenced by file
(`secret_file`), never stored inline.

---

## Sending devices to the box

- **Syslog (plain):** UDP or TCP **514**
- **Syslog (encrypted):** TLS **6514** — senders that verify certificates must
  trust `/etc/alerts/tls/cert.pem`, or replace that pair with a CA-signed
  cert/key (key mode 0600) and re-run install.
- **Email:** SMTP **25** from any RFC 1918 address — relayed out via the
  smarthost.

Received syslog is archived under `/logs/$YEAR/$MONTH/$DAY/$HOST/$HOUR-syslog.log` by default.
The archive is configurable (`archive_root`, `archive_subpath`, `archive_template`,
perms, etc.) to reproduce a classic `YEAR/MONTH/DAY/HOST/HOUR` log-server layout, and
a generated `alert-logmaint.sh` cron handles `today`/`yesterday` symlinks plus gzip
(`archive_compress_after_days`, default 1) and retention (`archive_delete_after_days`,
default 90).

---

## Command-line interface (for scripting)

The menu is the primary interface, but every action has a subcommand:

```
syslog-alert-router.sh [command] [options]

  (no args) | menu          Interactive menu (default)
  status                    Install / listener / mailer / relay status
  install                   Install everything; own syslog-ng + Postfix
  rules                     Alert-rule + recipient-group submenu
  relays                    Relay submenu
  mailtest [--relay NAME] ADDR   Send a test email (optionally via one relay)
  setup-mta                 (Re)configure Postfix from settings + the default relay
  regen                     Rebuild base config + filter, reload
  test "<msg>" [program]    Dry-run a rule (no send)
  check                     Validate the YAML config
  sweep                     Run escalation/digest/prune once
  uninstall                 Remove code + fragment + cron (keeps config/secrets/DB)
  version | help
```

The submenu managers also have non-interactive subcommands, e.g.
`alert-rules.py order "A,B"`, `alert-rules.py match-mode all`,
`alert-relays.py edit --name default --port 465 --security tls`.

---

## File layout

| Path | Purpose |
|---|---|
| `/etc/syslog-ng/syslog-ng.conf` | Managed base config (listeners, archive, mail log) |
| `/etc/syslog-ng/conf.d/10-alert-router.conf` | Generated alert filter + dispatch |
| `/usr/local/lib/alerts/alertlib.py` | Shared library |
| `/usr/local/bin/alert-{dispatcher,sweeper,relays,rules}.py` | Pipeline + managers |
| `/etc/alerts/config/{alerts,recipients,relays}.yaml` | Configuration |
| `/etc/alerts/templates/*.{txt,html}` | Email templates |
| `/etc/alerts/secrets/<name>.pw` | Relay credentials (0600) |
| `/etc/alerts/tls/{cert,key}.pem` | TLS listener cert |
| `/etc/postfix/sasl_passwd` | Smarthost SASL credential (0600) |
| `/var/lib/alerts/alerts.db` | SQLite state (dedup, escalation, digest queue) |
| `/var/log/alerts/*.log` | Dispatcher / sweeper logs |
| `/var/log/mail.log` | Postfix relay activity (mail facility) |
| `/var/log/remote/<host>/<date>.log` | Received-log archive |
| `/etc/cron.d/alert-sweeper` | Sweeper schedule |

---

## Logs

- **Alert delivery (via SMTP relays):** `/var/log/alerts/dispatcher.log`.
- **Sweeper (escalation/digest):** `/var/log/alerts/sweeper.log`.
- **Mail relay (Postfix, port 25 / sendmail):** `/var/log/mail.log`.
- **Everything received over the network:** `/var/log/remote/<host>/<date>.log`.

---

## Security notes

- Passwords never live in YAML; they sit in 0600 files under
  `/etc/alerts/secrets/`. Postfix's smarthost password is written only to
  `/etc/postfix/sasl_passwd` (mode 0600).
- The SMTP relay accepts only RFC 1918 clients and refuses to relay to external
  destinations from anyone else — it is not an open relay.
- The TLS syslog listener uses `peer-verify(optional-untrusted)` so devices
  without client certs can connect over an encrypted channel; replace the
  self-signed cert for production trust.

---

## Troubleshooting

- `status` shows whether the library is current, which listeners are active,
  whether the base config is managed, the mailer, the SMTP relay, and the
  smarthost.
- If syslog-ng won't start after an install/regen, the script reports the failure
  and prints the recent journal. Inspect: `systemctl status syslog-ng` and
  `journalctl -xeu syslog-ng`.
- After editing dispatcher/library code, run **install** so syslog-ng restarts
  and loads it; `status` flags a stale library otherwise.

See `CHANGELOG.md` for version history.
