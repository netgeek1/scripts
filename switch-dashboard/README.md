# switch-dashboard

A single web page (**HTTPS**, with optional plain HTTP) for all your **HP 1810-8G** and **Netgear GS110TP** switches. It shows every port's
state, lets you give ports **display names**, and can **enable or disable** ports. It runs as a hardened Docker
container, installed and managed by one self-contained, menu-driven installer.

> Formerly **hp1810-dashboard**. The 2.0 installer upgrades an existing hp1810-dashboard install in place; see
> [Upgrading from hp1810-dashboard](#upgrading-from-hp1810-dashboard).

| Model | How it is managed | Ports |
|---|---|---|
| **HP 1810-8G** (PL.2.x) | The switch's own web UI. It has no SSH, CLI or SNMP write, so the request format was decoded from a capture of the real PL.2.10 UI. The switch saves changes itself | 8 |
| **Netgear GS110TP** | **SNMPv3** (authenticated and encrypted; v2c also supported): standard IF-MIB for status, admin up/down and port descriptions, and NETGEAR-SWITCHING-MIB `agentSaveConfig` to save to the startup config | 10 (9–10 are SFP) |

Both models can sit on the same dashboard; each switch has a **model** setting.

![Dashboard](docs/dashboard.png)

- **Dashboard.**
  - Every switch on one page, with 8 ports per card.
  - Each port shows its name, whether it is up, down or disabled, its link speed and its packets per second.
  - A dot appears when new errors show up, and you can filter by switch or port name.
  - Click a port for its details, to rename it, or to enable or disable it.
- **Port names.**
  - Label ports "Uplink to UCG", "NAS", "Office AP" and so on, up to 24 characters each.
  - Operators can name ports from the port dialog; admins can also edit all eight in the switch editor.
  - On the GS110TP the names **are the switch's own port descriptions** (`ifAlias`): read over SNMP, and written
    back (and saved) when you rename a port.
  - Names are also settable from the CLI, and every change is audited.
- **HTTPS by default.**
  - The dashboard generates a self-signed certificate covering the host's name and IPs, and the installer shows its
    SHA-256 fingerprint so you can verify it.
  - You can import your own certificate (e.g. a wildcard) from the web UI or the CLI.
  - Plain HTTP is available only for running behind a TLS reverse proxy.
- **Settings in the web UI and on the CLI.** Switches, switch defaults, users, HTTPS and general options can be
  changed in either place. Changes are picked up live; only certificate changes need a restart, and there's a
  button for that.
- **Users and roles.**

  | Role | Can do |
  |---|---|
  | viewer | Look at the dashboard |
  | operator | Also change ports, name ports and read the audit log |
  | admin | Also change settings and users |

- **Protected ports.** Uplinks, and the port your management PC is on, can't be disabled from the dashboard.
- **Port changes from the shell.** `sudo switch-dashboard --port` lists your configured switches, then the chosen
  switch's ports with their names and current state, and offers the opposite state as the default.
- **Audit log.** Every login, port change, rename and configuration change is recorded with who made it and from
  which IP.
- **Secrets.**
  - Switch passwords are encrypted at rest; dashboard passwords are hashed.
  - The encryption key lives in the installer's vault (TPM2 via systemd-creds, or openssl).
- **Hardened container.**
  - Runs as a non-root nologin account.
  - Read-only root filesystem, all capabilities dropped, `no-new-privileges`.
  - Memory limit and healthcheck.
- **Switch sessions.** One web session is kept per switch and logged out cleanly, so the dashboard doesn't use up
  the switch's few login slots.

> Versions: `SCRIPT_VERSION` in the installer and `__version__` in `app/switchdash.py`. History: [CHANGELOG.md](CHANGELOG.md).

---

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [First steps after installing](#first-steps-after-installing)
- [Netgear GS110TP](#netgear-gs110tp)
- [Web UI](#web-ui)
- [HTTPS and HTTP](#https-and-http)
- [Port names](#port-names)
- [Installer: menu and CLI](#installer-menu-and-cli)
- [App CLI (`ctl`)](#app-cli-ctl)
- [Settings reference](#settings-reference)
- [Security notes](#security-notes)
- [Upgrading](#upgrading)
- [Upgrading from hp1810-dashboard](#upgrading-from-hp1810-dashboard)
- [Migrating from v1.0.0](#migrating-from-v100)
- [Backup and restore](#backup-and-restore)
- [Uninstall](#uninstall)
- [Files and paths](#files-and-paths)
- [How the switch is driven](#how-the-switch-is-driven)
- [Repository layout and maintenance](#repository-layout-and-maintenance)
- [Notes and limitations](#notes-and-limitations)
- [Testing](#testing)

---

## Requirements

| | |
|---|---|
| OS | Ubuntu or Debian (amd64 / arm64) |
| Access | root. The installer re-runs itself through `sudo` |
| Installed for you if missing | **Docker CE** from download.docker.com, with the compose and buildx plugins (a stopped daemon is started), plus curl, openssl, iproute2, gawk, coreutils, util-linux, gzip, tar, findutils, passwd, ca-certificates |
| Network at install/build time | download.docker.com, Docker Hub (base image), PyPI (`cryptography`) |
| Network at run time | HTTPS (or HTTP) from the Docker host to each switch's web UI |
| Switches | **HP 1810-8G**: PL.2.x with web management enabled (built against PL.2.10). **Netgear GS110TP**: SNMPv3 enabled for the `admin` user (or a v2c read-write community limited to the Docker host). Open UDP 161 from the host |

## Quick start

The installer is **self-contained**: the app source is embedded at the end of the script, so this single file is
all you need.

```bash
curl -fsSLO https://raw.githubusercontent.com/<you>/<repo>/main/switch-dashboard/switch-dashboard-installer.sh
chmod +x switch-dashboard-installer.sh
sudo ./switch-dashboard-installer.sh          # menu -> 1) Full install
```

Menu 1 asks for:

- bind address, port and timezone;
- install, data and backup folders;
- **HTTPS**: a self-signed certificate (the default), your own certificate files, or off.

It then:

1. installs any missing prerequisites and Docker;
2. creates the service account and the encrypted vault;
3. builds the image;
4. creates the first **admin** user, with your password or a generated one shown once;
5. starts the container and prints the URL and the certificate fingerprint.

```
==> HTTPS
  [ OK ] HTTPS with a self-signed certificate
  [ OK ] Self-signed certificate names: ubuntu-gold, 192.168.0.20
  [ OK ] Container healthy
  Dashboard: https://192.168.0.20:8810/
  Certificate (self-signed, 824 days left) SHA-256: 2A:BB:A0:...:0E:72
  Self-signed: the browser warns once; check that the fingerprint matches, then accept.
```

The installer copies itself to `/usr/local/sbin/switch-dashboard`, so after the first run you can use
`sudo switch-dashboard …` from anywhere.

**Non-interactive:** `sudo ./switch-dashboard-installer.sh --install --yes` takes every default, including a
self-signed certificate and a generated admin password. The password is printed and saved to
`/etc/switch-dashboard/initial-admin-password`.

## First steps after installing

1. Open the URL. With the self-signed certificate, compare the fingerprint in the browser's certificate viewer with
   the one the installer printed, then accept it.
2. Sign in, go to **Settings → Switch defaults** and set the switches' shared admin password, if they share one.
3. In **Settings → Switches**, add each switch. Use **Test connection** before saving, and mark uplinks under
   **Protected ports**.
4. On the dashboard, click ports to give them names.
5. In **Settings → Users**, add operators and viewers.

The same steps from the shell:

```bash
sudo switch-dashboard --ctl set defaults.password --password-prompt
sudo switch-dashboard --ctl switch add office-sw 192.168.0.51 --protected 8
sudo switch-dashboard --ctl switch add garage-sw 192.168.0.60 --model gs110tp --protected 9 --password-prompt   # SNMPv3: prompts for the admin password
sudo switch-dashboard --ctl switch add lab-sw    192.168.0.52 --password-prompt
sudo switch-dashboard --ctl switch test all
sudo switch-dashboard --port-name office-sw 8 "Uplink to UCG"
echo 'longpassword1' | sudo switch-dashboard --ctl user add alex --role operator --password-stdin
```

## Netgear GS110TP

The dashboard talks to the GS110TP over **SNMPv3** by default. v3 authenticates every request and encrypts it, so
nobody on the network can read or replay the credentials. v2c is still available, but its community string travels
in clear text and grants write access.

**On the switch** (web UI → **System → SNMP → SNMPv3 → User Configuration**), for the `admin` user:

- **SNMPv3 access mode:** Read/Write;
- **authentication protocol:** SHA (or MD5);
- **encryption:** DES, with an **encryption key** of 8+ characters.

GS110TP limits to keep in mind (from Netgear's manual):

- only the built-in `admin` account can use SNMPv3;
- its **authentication password is the admin login password**, so changing the admin password also changes it here;
- encryption is **DES only**. DES is old and weak, but it is still far better than v2c's clear text. The dashboard
  also supports AES-128 for switches that offer it.

Then add the switch in the web UI (**Settings → Switches → Add switch → Model: Netgear GS110TP**), or from the shell:

```bash
sudo switch-dashboard --ctl switch add garage-sw 192.168.0.60 --model gs110tp --protected 9 \
     --auth-proto sha --priv-proto des --password-prompt --priv-key-prompt
sudo switch-dashboard --ctl switch test garage-sw
```

`--password-prompt` asks for the admin password; `--priv-key-prompt` asks for the encryption key (press Enter to
use the admin password for both). In scripts, `--password-stdin --priv-key-stdin` read the two from stdin, one per
line.

| Field | |
|---|---|
| SNMP version | `3` (default for new switches) or `2c`. Switches added before v3 support keep `2c` until you change them |
| SNMPv3 user | Default `admin` |
| Authentication | `sha` (default), `md5`, `sha224`, `sha256`, `sha384`, `sha512`, or `none`. GS110TP: MD5 or SHA |
| Encryption | `des` (default), `aes` (AES-128), or `none`. Needs authentication |
| Auth password / encryption key | Both stored encrypted, 8+ characters. If no encryption key is stored, the auth password is used |
| SNMP write community | v2c only. Stored encrypted. SNMP switches never use the HP default password |
| SNMP port | Default 161 |
| Save config | **On by default.** After each port change or rename the dashboard sets `agentSaveConfig` and waits for `agentSaveConfigStatus` to report complete. Both the managed (`1.3.6.1.4.1.4526.10.1.3`) and smart-switch (`…4526.11.1.3`) trees are tried, and the one that works is remembered. If saving fails, the change still applies but the dashboard and CLI warn that it will revert on reboot. With Save config off, changes are running-config only |
| Timeout | Per SNMP request. One retry is made |

Connection errors say what's wrong: wrong auth password or protocol, wrong encryption key or protocol, unknown
user, a security level the switch doesn't accept, or a user without write access.

**Using v2c instead:** on the switch, **SNMP V1/V2 → Community Configuration**, add a Read-Write community whose
client address is the Docker host, then add the switch with `--snmp-version 2c --password-prompt` (the prompt asks
for the community).

**Port names** on the GS110TP are its port descriptions (`ifAlias`, the **Description** field in the switch's port
configuration). The dashboard shows them, and renaming a port in the dashboard writes the description to the switch
and saves it. See [Port names](#port-names).

Ports are found from the IF-MIB interface table, using physical ports only (not the CPU or VLAN interfaces). Each is
numbered from its `ifName` (`g1`…`g10`, `0/1`…). Status, speed, duplex, 64-bit packet counters and errors come from
IF-MIB / ifXTable / EtherLike-MIB.

![GS110TP in the switch editor](docs/gs110tp-editor.png)

## Web UI

| Page | Role | What it does |
|---|---|---|
| **Dashboard** `/` | viewer | All switches and ports, with totals and a filter (matches switch names, hosts, locations and port names). Click a port for its details; operators also get **Port name** and **Enable/Disable** |
| **Audit log** `/audit` | operator | Searchable log of logins, port changes, port names and configuration changes. Can auto-refresh |
| **Settings** `/settings` | admin | Five tabs, described below |
| User menu | everyone | Change your own password, sign out |

The Settings tabs:

- **Switches.** Add, edit, delete, test and test all. The editor covers connection, password, protected ports,
  port names, polling and notes. Fields marked *inherit* use the value from **Switch defaults**.
- **Switch defaults.** The shared scheme, TLS verification, timeout, user and password.
- **Users.**
- **HTTPS.** The certificate being served, the mode, extra names, regenerate, import, and **Restart now**.
- **General.** Title, poll interval, session lifetime, lockout, log level and audit log rotation.

## HTTPS and HTTP

The dashboard always serves **HTTPS** on `HOST_PORT` (8810) unless `tls_mode` is `off`. **Plain HTTP** is optional,
on its own port (`HTTP_PORT`, 8880):

| `http_mode` | Port 8880 |
|---|---|
| `off` (default) | Closed |
| `redirect` | Answers every request with a redirect to the same page on HTTPS (`308`, same host name, HTTPS port) |
| `on` | Serves the full dashboard over plain HTTP, next to HTTPS. Logins and switch passwords you type cross the network unencrypted, so use it only on a trusted management network |

Set it in the web UI (**Settings → HTTP / HTTPS → Plain HTTP**), the install wizard, the installer menu
(Settings → 6 → 6), or:

```bash
sudo switch-dashboard --http-mode redirect      # or on / off; publishes HTTP_PORT if needed and restarts
sudo switch-dashboard --set HTTP_PORT 8080 && sudo switch-dashboard --apply   # a different host port
sudo switch-dashboard --set HTTP_PORT '' && sudo switch-dashboard --apply     # don't publish a plain-HTTP port at all
```

With `http_mode on`, the session cookie on the HTTP port is (necessarily) not `Secure`, and HSTS is not sent even with
a custom certificate: HSTS applies to the whole host name, so browsers would turn `http://host:8880` into
`https://host:8880` and fail. A login on one port doesn't carry over to the other.

`tls_mode off` is different: then the main port itself serves plain HTTP (for running behind a TLS reverse proxy),
and `http_mode` has no effect.

### Certificates

| Mode | What is served | Set with |
|---|---|---|
| `self-signed` (default) | A certificate the dashboard generates: EC P-256, valid 825 days, renewed automatically within 30 days of expiry. It covers the host name, `localhost`, `127.0.0.1`, `::1`, plus **extra names/IPs**. The installer fills those in on first install with the host's FQDN and its non-Docker IPs | Web: Settings → HTTPS. CLI: `--tls-mode self-signed`, `--tls-names "dash.lab.lan,192.168.0.20"`, `--tls-regen` |
| `custom` | Your certificate (full chain) and unencrypted key, e.g. your wildcard. Checked before use: valid PEM, key matches certificate, not expired | Web: Settings → HTTPS → **Import certificate…** (paste or choose files). CLI: `--tls-import fullchain.pem privkey.pem` |
| `off` | Plain HTTP on the main port. Use only behind a TLS reverse proxy, and set `BIND_ADDRESS=127.0.0.1` | Web: Settings → HTTPS. CLI: `--tls-mode off` |

![HTTPS settings](docs/https-tab.png)

Certificate changes take effect on restart:

- **Web UI:** **Restart now**. Everyone is signed out and the page reloads on the new address.
- **CLI:** the `--tls-*` flags restart the container themselves.
- **Installer menu:** Settings → 6 → HTTPS.

Further details:

- **Broken custom certificate.** If it becomes unusable (for example, the file was removed), the dashboard serves
  the self-signed certificate instead of failing to start, and shows a warning on the HTTPS tab.
- **Expiry warning.** The HTTPS tab warns when the served certificate has fewer than 30 days left.
- **Cookie and HSTS.** On HTTPS the session cookie is marked `Secure`. HSTS is sent only in `custom` mode (pinning
  HTTPS to a self-signed certificate isn't useful), and not while `http_mode` is `on`.
- **Renewals.** To use a renewed certificate (e.g. from `letsencrypt-manager.sh` / acme.sh), copy the files to the
  Docker host and run `sudo switch-dashboard --tls-import fullchain.pem privkey.pem`. It validates, installs and
  restarts.

## Port names

![Naming a port](docs/port-dialog.png)

- **Rules.** Up to 24 characters; leading, trailing and doubled spaces are removed. An empty name clears the label.
- **Where they show.**
  - On each port tile (shortened if long, full text on hover).
  - In the port dialog title and the screen-reader label.
  - In the dashboard filter.
- **Where they are stored.**
  - **HP 1810:** in the dashboard's config, kept with the switch (so they survive renaming it). The 1810 web UI has
    no port description field.
  - **GS110TP:** on the switch, as each port's description (`ifAlias`). The dashboard reads them on every poll.
    Renaming a port writes the description and, with Save config on, saves it to the startup config. Names you
    set elsewhere (the switch's UI, another tool) show up on the next poll.
  - A GS110TP name set in the dashboard by app 2.2.0 is kept as a **dashboard override** and wins over the switch's
    description. Renaming that port moves the name to the switch; you can also clear overrides in the switch editor.
- **Who can set them.**
  - Operators and admins, from the port dialog (**Save name**).
  - Admins, in the switch editor (HP: all 8 at once).
  - CLI: `--port-name SWITCH N "NAME"`, or `--ctl port-name …` / `--ctl port-names SWITCH`.
  - Installer menu: Settings → 1 → 6.
- **Audit.** Each rename records the old and new name.

## Installer: menu and CLI

Every menu item has a CLI flag. `sudo switch-dashboard --help` lists them all.

| Menu | CLI | |
|---|---|---|
| 1 | `--install` | Wizard (network, paths, HTTPS), prerequisites, Docker, account, vault, build, first admin, start |
| 2 | `--settings` | 1 switches (including **6 name a port**) · 2 switch defaults · 3 users · 4 general · 5 container/host · **6 HTTPS** |
| 3 | `--apply` | Re-render the compose file, rebuild the image, start |
| 4 | `--rebuild` | No-cache rebuild that re-pulls the base image (security updates) |
| 5 / 6 / 7 | `--start` `--stop` `--restart` | |
| 8 | `--status` | Settings, container health, URL and the app configuration |
| 9 | `--logs [N]`, `--audit [N]` | Container log, audit log, installer run logs |
| P | `--port [SWITCH [N [up\|down]]]` | Change a port. Anything you leave out is asked for: the configured switches are listed, then that switch's ports (name, admin, link, speed, protected), with the opposite state as the default and a confirmation. Goes through the running server and is audited |
| | `--ports [SWITCH]` | Show the ports of one switch, or of all switches |
| | `--port-name SWITCH N NAME` | Name a port (`''` clears it) |
| | `--tls-info`, `--tls-import CERT KEY`, `--tls-mode self-signed\|off`, `--tls-names LIST`, `--tls-regen` | HTTPS |
| | `--http-mode off\|redirect\|on` | Plain HTTP on `HTTP_PORT` next to HTTPS (restarts) |
| B / R | `--backup`, `--restore FILE` | Restore asks for the keyword `RESTORE` |
| U | `--uninstall` | Keyword `UNINSTALL`. Purging data needs a second keyword, `PURGE-DATA` |
| T | `--dry-run` | Shows every command and file write without running them |
| S | `--self-test`, `--app-self-test` | Installer tests (no root needed); app tests inside the built image |
| | `--show-config`, `--set KEY VALUE` | Container/host settings |
| | `--ctl ARGS...` | Any app CLI command (next section) |
| | `--rekey` | Re-encrypt the vault with the current `SECRETS_BACKEND` |
| | `--build-standalone OUT` | Write a self-contained installer from the current source |
| | `--yes`, `--confirm KW`, `--source DIR` | Non-interactive, pre-answered keyword, alternate source checkout |

## App CLI (`ctl`)

The same operations as the web Settings page. Run it through the installer, or directly in the container:

```bash
sudo switch-dashboard --ctl <command>                        # docker exec, or a one-off container when stopped
docker exec -it switch-dashboard switchdash ctl <command>
```

| Command | |
|---|---|
| `show [--json]`, `keys` | All settings (secrets show only as set / not set); every key with its default and description |
| `get KEY`, `set KEY VALUE [KEY VALUE ...]` | e.g. `set general.poll_interval 15` |
| `set defaults.password --password-stdin\|--password-prompt`, `unset-default-password` | Default switch password |
| `switch list\|show\|add\|edit\|remove\|test` | `add NAME HOST` takes `--scheme`, `--verify-tls`, `--timeout`, `--username` (each a value or `inherit`), plus `--protected 1,8`, `--notes`, `--password-stdin\|--password-prompt`, `--disable`. `edit` also takes `--host`, `--rename`, `--enable` and `--clear-password` |
| `port-name SWITCH N NAME`, `port-names SWITCH` | Port names. GS110TP: written to the switch's port description. `port-names` lists dashboard-side names |
| `ports SWITCH [--json\|--tsv]` | Live port list (from the running server, or polled directly) |
| `models` | Supported models. `switch add/edit` take `--model hp1810\|gs110tp`, `--snmp-port N` and `--save-config yes\|no` |
| SNMP options | `switch add/edit` take `--snmp-version 3\|2c`, `--snmp-user`, `--auth-proto`, `--priv-proto`, `--priv-key-stdin\|--priv-key-prompt`; `edit` also `--clear-priv-key`. `--password-*` sets the v3 auth password (or the v2c community) |
| `user list\|add\|edit\|remove` | `--role viewer\|operator\|admin`. Passwords only via `--password-stdin` or `--password-prompt` |
| `port SWITCH N up\|down` | |
| `tls-info`, `tls-import CERT KEY`, `tls-regen` | `tls-import` takes paths inside the container; the installer's `--tls-import` handles host files |
| `audit [--tail N] [--grep TEXT]`, `import-v1 FILE [--replace]` | |

Exit codes: `0` success, `1` operation failed, `2` invalid input.

## Settings reference

### Container / host (installer, `/etc/switch-dashboard/switch-dashboard.conf`)

Change these with the menu (Settings → 5) or `--set KEY VALUE`, then run `--apply`.

| Key | Default | |
|---|---|---|
| `BIND_ADDRESS` / `HOST_PORT` | `0.0.0.0` / `8810` | Where the web UI is published. The port serves HTTPS unless `tls_mode` is `off` |
| `HTTP_PORT` | `8880` | Host port for plain HTTP (`http_mode` redirect or on). Empty = not published. Must differ from `HOST_PORT` |
| `TIMEZONE` | detected | Container timezone (used for audit timestamps) |
| `INSTALL_DIR` / `DATA_DIR` / `BACKUP_DIR` | `/opt/switch-dashboard` / `…/data` / `/var/backups/switch-dashboard` | |
| `BACKUP_KEEP` | `10` | |
| `CONTAINER_NAME` / `IMAGE_NAME` | `switch-dashboard` | The container's host name is set to the Docker host's short name, so the self-signed certificate matches it |
| `BASE_IMAGE` / `CRYPTOGRAPHY_VERSION` | `python:3.13-slim-bookworm` / `50.0.2` | Pins. `BASE_IMAGE` may be pinned by `@sha256:` digest |
| `BUILD_NETWORK` | `default` | Set to `host` when builds must reach a proxy on localhost |
| `SERVICE_USER` / `SERVICE_UID` / `SERVICE_GID` | `switchdash` / auto / auto | |
| `RESTART_POLICY` | `unless-stopped` | With `no`, the web UI's **Restart now** button is disabled |
| `MEM_LIMIT`, `LOG_MAX_SIZE`, `LOG_MAX_FILE` | `128m`, `10m`, `3` | |
| `SECRETS_BACKEND` | `auto` | `systemd-creds` (TPM2) or `openssl` |

### Dashboard general (`ctl set general.KEY`; web Settings → General / HTTPS)

| Key | Default | |
|---|---|---|
| `title` | `Switch Ports` | |
| `poll_interval` | `10` | Seconds (3–3600) |
| `session_timeout_min` | `480` | |
| `login_max_failures` / `login_lockout_min` | `5` / `15` | |
| `log_level` | `INFO` | |
| `audit_max_kb` / `audit_keep` | `5120` / `5` | |
| `tls_mode` | `self-signed` | `self-signed`, `custom` or `off`. Takes effect on restart |
| `tls_san` | set by the installer | Extra names/IPs for the self-signed certificate |
| `tls_cert` / `tls_key` | set by import | Custom certificate paths inside `/data` |
| `http_mode` | `off` | Plain HTTP next to HTTPS: `off`, `redirect` or `on`. Takes effect on restart |

### Switch defaults (`ctl set defaults.KEY`; web Settings → Switch defaults)

| Key | Default | |
|---|---|---|
| `scheme` | `https` | |
| `verify_tls` | `no` | The 1810 ships a self-signed certificate |
| `timeout` | `8` | Seconds |
| `username` | `admin` | |
| `password` | not set | Encrypted |

### Per switch

| Field | |
|---|---|
| `model` | `hp1810` (default) or `gs110tp`. Sets the port count, the driver and which fields apply |
| `name`, `host` | `host` may be `ip`, `name`, `ip:port` (HP) or `[v6]:port` |
| `scheme`, `verify_tls`, `username` | HP only. Each can be `inherit` |
| `timeout` | Both models. Can be `inherit` |
| `password` | HP: the web password; if empty, the default password is used. GS110TP: the SNMPv3 auth password, or the v2c community. Encrypted |
| `snmp_port`, `save_config` | GS110TP only. Defaults: 161, on |
| `snmp_version`, `snmp_user`, `snmp_auth`, `snmp_priv` | GS110TP only. Defaults for new switches: `3`, `admin`, `sha`, `des` |
| privacy key | GS110TP v3 only. Encrypted. Empty = the auth password |
| `protected_ports` | Ports that can't be disabled from the dashboard |
| `port_names` | Port display names (GS110TP: dashboard overrides of the switch's descriptions) |
| `enabled` | Turn off to stop polling the switch without deleting it |
| `notes` | Free text |

## Security notes

- **The switch's own login is weak.** The 1810 sends `base64("admin:<password>")` in a URL and a cookie. Keep the
  switches on a management network, and change a switch's password if it has ever appeared in a browser capture
  (HAR).
- **Dashboard traffic is HTTPS by default.** With the self-signed certificate, verify the fingerprint once.
  Better still, import a certificate your browsers already trust. Plain HTTP is off unless you turn it on; prefer
  `redirect` over `on`.
- **Secrets at rest.**
  - Switch passwords are encrypted with Fernet (AES-128-CBC + HMAC-SHA256).
  - The key comes from the installer vault and reaches the container through its environment. It is never written
    to the compose file.
  - Dashboard passwords are stored as PBKDF2-SHA256 hashes.
  - TLS private keys are 0600, owned by the service account.
- **Web.**
  - Session cookie: HttpOnly, SameSite=Strict, and Secure over HTTPS.
  - A CSRF token is required on every change.
  - Strict CSP with no inline scripts or styles.
  - Lockout per IP after failed logins.
  - Sessions are dropped when a user's role or password changes; the last admin can't be removed.
- **The audit log never contains passwords or keys.** Configuration changes record which fields changed, not their
  values. Port renames record the old and new name.
- **Container.**
  - Runs as a non-root UID.
  - Read-only root filesystem, `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges`, an init process, a
    healthcheck, and a memory limit.

## Upgrading

Download the new installer (or `git pull`), then:

```bash
sudo ./switch-dashboard-installer.sh --apply
```

This copies the new app into the build context, rebuilds and restarts. `--rebuild` also re-pulls the base image.

**From app 2.0.x to 2.1.x:** the dashboard switches to **HTTPS** with a self-signed certificate on the same port.
Change bookmarks to `https://`. If you had set a certificate path before, it is kept as `custom` mode. If you really
want plain HTTP, run `--tls-mode off`.

## Upgrading from hp1810-dashboard

Installer 2.0 / app 3.0 renamed the project from **hp1810-dashboard** to **switch-dashboard**. Run the new installer
on the Docker host; any action (`--apply`, `--status`, or the menu) notices the old install and offers to upgrade it
(`--yes` answers for you):

```bash
sudo ./switch-dashboard-installer.sh --apply
```

What it does:

1. Backs up the old data folder and `/etc/hp1810-dashboard` to
   `/var/backups/switch-dashboard/hp1810-dashboard-pre-upgrade-<date>.tar.gz`.
2. Removes the old `hp1810-dashboard` container and its network.
3. Moves the folders: `/opt/hp1810-dashboard` → `/opt/switch-dashboard`, `/var/backups/hp1810-dashboard` →
   `/var/backups/switch-dashboard`, `/var/log/hp1810-dashboard` → `/var/log/switch-dashboard`. Folders you had set to
   custom paths stay where they are.
4. Renames the service account `hp1810dash` → `switchdash`, keeping its UID and GID, so file ownership is unchanged.
5. Re-encrypts the vault (the app secret key) under the new name in `/etc/switch-dashboard`, checks it decrypts, then
   removes `/etc/hp1810-dashboard` and the old `hp1810-dashboard` command and images.
6. Builds and starts `switch-dashboard`. Switches, stored passwords, users, port names, the audit log and the TLS
   certificate (same fingerprint) all carry over.

Afterwards:

- The command is `sudo switch-dashboard`; inside the container it's `switchdash ctl …`.
- Everyone signs in again: the session cookie has a new name.
- Scripts that used the old names need updating: `hp1810-dashboard` → `switch-dashboard`, `hp1810dash` →
  `switchdash`, environment variables `HP1810_*` → `SWDASH_*` (the app still accepts the old variable names).
- The URL is unchanged: `https://<host>:8810/`.

## Migrating from v1.0.0

v1.0.0 was a single script with a plaintext `switches.json`. Import it, then delete the old file:

```bash
sudo install -o switchdash -m 600 switches.json /opt/switch-dashboard/data/v1.json
sudo switch-dashboard --ctl import-v1 /data/v1.json
sudo shred -u /opt/switch-dashboard/data/v1.json
```

The switches, protected ports, poll interval, defaults and passwords are imported, with passwords encrypted on
import. `dashboard_auth` is not imported; create users instead.

## Backup and restore

`--backup` writes `BACKUP_DIR/switch-dashboard-YYYYmmdd-HHMMSS.tar.gz` (mode 0600). It contains:

- the data directory, including the config, port names, audit log and TLS certificates and keys;
- the installer settings;
- the vault and its key file.

**Treat the archive like the switch passwords.**

- **With the `systemd-creds` backend:** the vault is bound to this host/TPM, so the archive restores on this host
  only.
- **With the `openssl` backend:** the archive restores on any host.

`--restore FILE --confirm RESTORE`:

1. checks that every path in the archive is inside `DATA_DIR` or `/etc/switch-dashboard`;
2. stops the container;
3. moves the current data to `DATA_DIR.pre-restore-<date>`;
4. extracts the archive, re-owns the data, and starts the container.

## Uninstall

`--uninstall` (keyword `UNINSTALL`) removes:

- the container and image;
- the compose file and build context;
- `/usr/local/sbin/switch-dashboard`.

Data, settings and the vault are kept unless you also confirm a purge (keyword `PURGE-DATA`). The service account
is removed only if you confirm that separately.

## Files and paths

| Path | |
|---|---|
| `/etc/switch-dashboard/switch-dashboard.conf` | Container/host settings (0600) |
| `/etc/switch-dashboard/secrets.enc` (+ `.secrets.key` for openssl) | Vault holding the app secret key |
| `/etc/switch-dashboard/initial-admin-password` | Only if the installer generated the password. Delete it after the first login |
| `/opt/switch-dashboard/docker-compose.yml` | Generated. Contains no secrets |
| `/opt/switch-dashboard/src/` | Build context (from the embedded source or a checkout) |
| `/opt/switch-dashboard/data/config.json` | App settings, switches (passwords encrypted), port names, users (hashed) |
| `/opt/switch-dashboard/data/tls/` | `selfsigned.{crt,key}`, `custom.{crt,key}` (0600) |
| `/opt/switch-dashboard/data/audit.log[.N]` | Audit trail (JSON lines) |
| `/var/log/switch-dashboard/installer-*.log` | Installer run logs (newest 20 kept) |
| `/var/backups/switch-dashboard/` | Backups |

## How the switch is driven

| Purpose | Request |
|---|---|
| Login | `GET /config/login?deviceid=base64("admin:<pw>")`, with client-generated `seid`/`sesslid` cookies |
| Status | `GET /update/stat/portstate` (front panel, including admin-disabled), `/update/stat/ports` (link, speed, counters), `/update/config/sysinfo` |
| Port config | `GET /update/config/ports?port=N&sid=-1` |
| Admin up/down | `POST /update/config/ports` with `port=N[&admin=on]&speed=<current>&sid=-1`. The current speed setting is sent back unchanged, and the result is read back to confirm |
| Logout | `POST /config/logout` |

Every request carries a `CsrfToken` header equal to the session id. The firmware saves its configuration to flash
on its own after a change; the card shows "saving config…" while it does.

**Netgear GS110TP (SNMPv3 or v2c)**

| Purpose | Objects |
|---|---|
| System | `sysDescr`, `sysName`, `sysLocation`, `sysContact`, `sysUpTime` |
| Ports | `ifType` (physical only), `ifName` (port number), `ifAdminStatus`, `ifOperStatus`, `ifHighSpeed`, `dot3StatsDuplexStatus`, `ifMtu`, `ifIn/OutErrors`, `ifHCIn/Out{Ucast,Multicast,Broadcast}Pkts` (falls back to 32-bit counters) |
| Port names | `ifAlias` (read every poll; `SET` on rename, then read back) |
| Admin up/down | `SET ifAdminStatus.<ifIndex>` = 1 / 2, then read back to confirm |
| Save | `SET agentSaveConfig.0` = enable(1), then poll `agentSaveConfigStatus.0` until savingComplete(3) |

The SNMP client (`app/snmplite.py`) is a small v2c and v3 implementation; its only dependency is `cryptography`
(for DES and AES). v3 follows the User-based Security Model: engine discovery, key localization (checked against
the RFC 3414 test vectors), HMAC-MD5/SHA-96 and HMAC-SHA-2 authentication (RFC 7860), DES-CBC (RFC 3414) and
AES-128-CFB (RFC 3826) privacy, and time-window resync. The tests run it against net-snmp `snmpd` v3 users when
`snmpd` is installed.

## Repository layout and maintenance

```
switch-dashboard/
├── switch-dashboard-installer.sh   installer + lifecycle manager, with the app source embedded at the end
├── Dockerfile                      image (BASE_IMAGE / CRYPTOGRAPHY_VERSION pinned, overridable)
├── app/
│   ├── switchdash.py               the app: switch client, poller, HTTPS server, API, ctl CLI
│   ├── web/                        static UI (no inline script/style; strict CSP)
│   └── tests/                      unit + integration tests, mock 1810 switch
├── docs/                           screenshots
└── README.md  CHANGELOG.md  LICENSE
```

After changing anything under `app/` or the `Dockerfile`, regenerate the embedded copy before committing:

```bash
./switch-dashboard-installer.sh --build-standalone /tmp/i.sh && mv /tmp/i.sh switch-dashboard-installer.sh
```

- **Reproducible.** The embedded payload is a deterministic tar.gz, so rebuilding from the same source gives an
  identical file.
- **Verified on use.** A sha256 checksum is checked before the source is unpacked.
- **Never executed.** The payload sits in a heredoc after `exit`, so bash never runs it and shellcheck stays clean.

The installer looks for the source in this order:

1. `--source DIR`
2. a checkout next to the script
3. the embedded copy
4. the installed copy

## Notes and limitations

- **Testing so far.**
  - The HP support was built from a capture of one PL.2.10 switch and tested against a mock that replays those
    responses.
  - The GS110TP support follows the standard MIBs and Netgear's switching MIB. It was tested against a mock agent
    whose answers were checked with net-snmp, and the SNMP client (v2c and v3: SHA/AES, MD5/DES, SHA-256,
    read-only users) against a real net-snmp agent, but not against a real GS110TP.
  - Run `switch test all` and toggle a spare port on each model before relying on it.
- **GS110TP firmware.** Netgear's forum confirms `ifAdminStatus` writes on GS110TPv3 (firmware 7.x). If your unit
  doesn't confirm the save, the dashboard says so. In that case save once from the switch's own UI
  (**Maintenance → Save Configuration**) after a change, or turn Save config off.
- **Limited login slots.** The 1810 allows only a few concurrent web logins. The dashboard holds one per switch, and
  `--port` reuses it. If a card shows "maximum login count", log out of any browser sessions on that switch.
- **Restart policy.** A web **Restart now** relies on Docker's restart policy. With `RESTART_POLICY=no`, use
  `--restart` instead.
- **Hardware support.** Only copper 8-port 1810-8G v2 units have been seen. SFP/fiber image names are recognised but
  untested.

## Testing

```bash
./switch-dashboard-installer.sh --self-test        # installer: 34 checks
sudo switch-dashboard --app-self-test              # app: 59 tests inside the built image (offline, mock switches;
                                                   # the net-snmp interop test is skipped there)
cd app && SWDASH_SECRET_KEY=x python3 switchdash.py selftest   # same suite on the host (needs 'cryptography')
python3 app/tests/mock1810.py 18101 'pw' lab-sw    # a fake HP 1810 to point the dashboard at
python3 app/tests/mock_gs110tp.py 16161            # a fake GS110TP (SNMP v2c, ro "public", rw "private")
python3 app/tests/mock_gs110tp.py 16162 --v3-user admin --v3-auth-pass Password1   # ... plus SNMPv3 (SHA/DES)
```
