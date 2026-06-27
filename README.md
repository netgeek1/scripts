# syslog-alert-router

A self-contained, **menu-driven** installer that turns a clean Ubuntu 24.04 box
into a dedicated **syslog-ng → email alert appliance**. It receives syslog from
your network gear, classifies messages against rules you define in YAML,
deduplicates them, and emails the right people — with escalation, digests, and
multiple SMTP relays with failover.

The whole thing is one shell script with the Python pipeline embedded inside it.
Run it with no arguments and you get a menu; everything is driven from there.

```
network gear ──(UDP/TCP 514, TLS 6514)──▶ syslog-ng ──▶ alert-dispatcher.py
local logs   ──(system, internal)────────▶              classify · dedup (SQLite)
                                                         render · route · send
                                            alert-sweeper.py (cron)
                                                         escalation · digests · prune
                                                                       │
                                                                       ▼
                                                   msmtp / SMTP relays (failover)
```

On a dedicated box the script **owns syslog-ng**: it writes the base config with
its own listeners, so there is no existing configuration to detect or attach to.

---

## Requirements

- Ubuntu 24.04 (syslog-ng 4.x). Other apt-based distros generally work.
- Root (the script elevates itself via `sudo` when needed).
- Prerequisites are installed automatically on first run: `syslog-ng-core`,
  `python3`, `python3-yaml`, `cron`, `openssl`, `ca-certificates`, `msmtp`.

---

## Quick start

```bash
chmod +x syslog-alert-router.sh
./syslog-alert-router.sh          # opens the menu
```

Pick **1) Install / update everything**. That installs prerequisites, writes a
managed `/etc/syslog-ng/syslog-ng.conf` (listeners on UDP/TCP 514 and TLS 6514,
self-signed cert auto-generated), deploys the pipeline, configures msmtp, and
starts syslog-ng. Then work down the menu: configure the mailer, define alerts,
add recipients, send a test.

See `QUICKSTART.md` for the same flow as copy-paste commands.

---

## The menu

Running the script with no arguments prints current status, then this menu:

```
==================== syslog-alert-router v3.0.0 ====================
  dispatcher : installed
  library    : 3.0.0 (current)
  syslog-ng  : yes (v4.x)
  base config: managed
  listeners  : udp=514 tcp=514 tls=6514 local=true
  tls cert   : present
  mailer     : msmtp (/usr/sbin/sendmail)
  relays:
    local            sendmail /usr/sbin/sendmail
----------------------------------------------------------------------
  1) Install / update everything       6) Validate configuration
  2) Manage alert rules + recipients   7) Regenerate filter + base config
  3) Manage relays + credentials       8) Configure mailer (msmtp smarthost)
  4) Send a test email                 9) Run sweep now (escalate/digest)
  5) Dry-run a rule (sample log line)  u) Uninstall    q) Quit
----------------------------------------------------------------------
```

| Option | What it does |
|---|---|
| **1 Install / update** | Installs/updates code, writes the managed syslog-ng config + listeners, generates the alert filter, configures cron and msmtp, restarts syslog-ng. Run this after editing listeners or updating the script. |
| **2 Alert rules + recipients** | Submenu to add/edit/delete alerts and recipient groups (below). |
| **3 Relays + credentials** | Submenu to add/edit/test SMTP relays, set the failover order, and store passwords securely (below). |
| **4 Send a test email** | Sends a test message, optionally through one named relay, to confirm the mail path. |
| **5 Dry-run a rule** | Feeds a sample log line through classification and shows the rendered email — without sending. |
| **6 Validate configuration** | Checks the YAML config and reports the alerts, groups, and relays it parsed. |
| **7 Regenerate filter + base config** | Rebuilds `syslog-ng.conf` and the alert fragment from `alerts.yaml`, then reloads. |
| **8 Configure mailer** | Sets the msmtp smarthost (host/port/TLS) and prompts for the password if the smarthost needs auth. |
| **9 Run sweep now** | Runs the escalation/digest/prune pass immediately instead of waiting for cron. |
| **u Uninstall** | Removes code, the alert fragment, and cron. Keeps config, secrets, the database, and your managed `syslog-ng.conf`. |
| **q Quit** | Exit. |

### Submenu: Alert rules + recipients (option 2)

```
================== Alert Rules ==================
  DISK_FULL        sev=high     -> storage  relay=(default order) digest? escalate->management@4h
  ...
------------------------------------------------
  a) add/edit alert   s) show alert details
  d) delete alert     g) manage recipient groups
  q) done
```

Add or edit an alert and you're prompted for: name, match regex, severity,
recipient group(s), relay(s), template, digest, and escalation. Each alert is
routed independently — its own recipients **and** its own relay (single relay or
a comma-separated failover chain). Leaving a field blank keeps the existing
value, so the same prompt edits as well as creates. The editor warns if a regex
matches every line (e.g. a stray leading `|`). On exit, any change regenerates
the filter and reloads automatically.

The **g** sub-submenu manages recipient groups (a group name → list of email
addresses), which is what the per-alert "recipients" field points at.

### Submenu: Relays + credentials (option 3)

```
================ Relay Manager ================
  relay order: local, alerts_dreamhost
    local            sendmail /usr/sbin/sendmail
    alerts_dreamhost smtp smtp.dreamhost.com:587 starttls auth=True
-----------------------------------------------
  a) add relay      o) set failover order
  p) set password   d) delete relay
  t) test relay     q) quit
```

Add an SMTP relay (host, port, security, optional auth) or a `sendmail` relay.
Passwords are written to `/etc/alerts/secrets/<name>.pw` (mode 0600); the YAML
only ever stores a reference, never the password. The failover **order** is the
default chain; individual alerts can override it.

---

## Configuration

Everything lives under `/etc/alerts/config/`. The dispatcher picks up edits to
recipients, severity, template, and relay **live**; changing a `regex` or a
listener needs a regen/install.

### `alerts.yaml`

```yaml
settings:
  from: monitor@syslog.example.net
  dedup_window_sec: 1h
  digest_interval_sec: 1h
  active_grace_sec: 15m
  prune_after_sec: 7d

  # syslog-ng listeners (this box owns them; re-run install after editing)
  listen_udp: 514          # 0 / false to disable
  listen_tcp: 514
  listen_tls: 6514         # uses /etc/alerts/tls/{cert,key}.pem
  listen_local: true       # collect this box's own logs

  # msmtp smarthost (system mailer)
  smarthost: smtp.example.com
  smarthost_port: 587
  smarthost_tls: true
  smarthost_user: alerts@example.com   # omit for an unauthenticated relay

alerts:
  DISK_FULL:
    regex: 'filesystem full|No space left on device'
    severity: high
    recipients: storage          # a group, or [group1, group2]
    relay: alerts_dreamhost       # or [primary, backup] for failover; omit = default order
    template: disk_full
    escalation_after: 4h
    escalation_group: management
```

Per-alert keys: `regex` (required), `program` (optional gate on `$PROGRAM`),
`severity`, `recipients`, `relay`/`relays`, `template`, `subject`,
`dedup_window`, `dedup_key` (regex with a capture group to split dedup, e.g. per
source IP), `digest: true`, `escalation_after` + `escalation_group`.

### `recipients.yaml`

```yaml
groups:
  ops:      [ops@example.com]
  storage:  [storage@example.com, oncall@example.com]
  security: [secteam@example.com]
```

### `relays.yaml`

Managed through the relay submenu (option 3). Holds relay definitions and the
failover `order`; credentials are referenced by file, never stored inline.

---

## Sending devices to the box

Point FortiGate / pfSense / Ubiquiti (and anything else) at this box's IP:

- **Plain:** UDP or TCP **514**
- **Encrypted:** TLS **6514** — senders that verify certificates must trust
  `/etc/alerts/tls/cert.pem`, or replace that pair with a CA-signed cert/key
  (key mode 0600) and re-run install.

Everything received is archived per host per day under
`/var/log/remote/<host>/<date>.log`, independent of whether it matched an alert.

---

## Command-line interface (for scripting)

The menu is the primary interface, but every action has a subcommand:

```
syslog-alert-router.sh [command] [options]

  (no args) | menu     Interactive menu (default)
  status               Install / listener / mailer / relay status
  install [--relay HOST[:PORT]] [--relay-tls]
  rules                Alert-rule + recipient-group submenu
  relays               Relay submenu
  mailtest [--relay NAME] ADDR
  setup-mta [--relay HOST[:PORT]] [--relay-tls]
  regen                Rebuild base config + filter, reload
  test "<msg>" [program]   Dry-run a rule (no send)
  check                Validate the YAML config
  sweep                Run escalation/digest/prune once
  uninstall
  version | help
```

---

## File layout

| Path | Purpose |
|---|---|
| `/etc/syslog-ng/syslog-ng.conf` | Managed base config (listeners, archive) |
| `/etc/syslog-ng/conf.d/10-alert-router.conf` | Generated alert filter + dispatch |
| `/usr/local/lib/alerts/alertlib.py` | Shared library |
| `/usr/local/bin/alert-{dispatcher,sweeper,relays,rules}.py` | Pipeline + managers |
| `/etc/alerts/config/{alerts,recipients,relays}.yaml` | Configuration |
| `/etc/alerts/templates/*.{txt,html}` | Email templates |
| `/etc/alerts/secrets/<name>.pw` | Relay/msmtp credentials (0600) |
| `/etc/alerts/tls/{cert,key}.pem` | TLS listener cert |
| `/var/lib/alerts/alerts.db` | SQLite state (dedup, escalation) |
| `/var/log/alerts/*.log` | Dispatcher / sweeper / msmtp logs |
| `/var/log/remote/<host>/<date>.log` | Received-log archive |
| `/etc/cron.d/alert-sweeper` | Sweeper schedule |

---

## Security notes

- Passwords never live in YAML or in `/etc/msmtprc`; they sit in 0600 files under
  `/etc/alerts/secrets/` and are read at send time.
- The TLS listener uses `peer-verify(optional-untrusted)` so devices without
  client certs can connect over an encrypted channel; replace the self-signed
  cert for production trust.

---

## Troubleshooting

- `status` shows whether the library is current, which listeners are active, and
  whether the base config is managed.
- If syslog-ng won't start after an install/regen, the script prints the failure
  honestly and shows the recent journal. Inspect with:
  `systemctl status syslog-ng` and `journalctl -xeu syslog-ng`.
- After editing dispatcher/library code, run **install** so syslog-ng restarts
  and loads the new code; `status` flags a stale library otherwise.

See `CHANGELOG.md` for version history.
