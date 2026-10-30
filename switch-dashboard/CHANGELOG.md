# Changelog

All notable changes, newest first. Two components are versioned separately:

- **installer**: `SCRIPT_VERSION` in `switch-dashboard-installer.sh` (`hp1810-dashboard-installer.sh` before 2.0)
- **app**: `__version__` in `app/switchdash.py` (`app/hp1810dash.py` before 3.0), which is also the image tag

Versions follow `MAJOR.MINOR.PATCH`.

## installer v2.1.0 / app v3.0.0 — 2026-10-29 — portable backups

### Installer 2.1.0
- **Portable backups** (`--backup --portable`, or `BACKUP_FORMAT=portable`): `switch-dashboard-<date>.swdbak`, the whole
  archive encrypted with a passphrase (AES-256-CBC, PBKDF2-SHA256, 600,000 iterations). It carries the app secret key
  instead of the host-bound vault, so it restores on any host. Includes a manifest and SHA-256 checksums.
- **Restore onto a new machine:** `--restore FILE.swdbak` works with nothing installed. It verifies the passphrase
  and checksums before changing anything, adopts the backup's container settings on a fresh host (minus
  UID/GID, vault backend, timezone, and a bind address the host doesn't have), restores the data owned by this
  host's service account, seals the key in this host's vault (TPM where available), installs Docker if needed,
  builds and starts. From a different host, the self-signed certificate is re-issued, keeping DNS names and
  dropping IPs that aren't on the new host.
- Passphrase sources: prompt (12+ characters, confirmed), `--passphrase-file FILE`, `SWDASH_BACKUP_PASSPHRASE`, or
  the new `BACKUP_PASSPHRASE_FILE` setting. The menu's Backup item asks which type.
- Restoring a host backup whose vault is TPM-bound now warns that it only restores on its own host.
- Fix: pruning old backups failed when one of the two backup types had no files yet.
- Self-test: 38 checks (was 34).

## installer v2.0.0 / app v3.0.0 — 2026-10-26 — renamed to switch-dashboard, optional plain HTTP

### Renamed: hp1810-dashboard → switch-dashboard
- Installer `switch-dashboard-installer.sh`, host command `switch-dashboard`, container and image `switch-dashboard`,
  folders `/opt|/etc|/var/backups|/var/log/switch-dashboard`, service account `switchdash`, in-container command
  `switchdash`, Python module `app/switchdash.py`, environment variables `SWDASH_*`, session cookie `swdash_sid`.
- Model IDs (`hp1810`, `gs110tp`) are unchanged. The app still reads `HP1810_*` environment variables as a fallback,
  and the stored-secret format is unchanged (a test now decrypts a password written by 2.x).

### Installer 2.0.0
- **Upgrade from hp1810-dashboard.** Any action detects an old install and, after confirmation (or `--yes`):
  backs it up; removes the old container; moves folders that used the old default paths; renames the service
  account keeping its UID/GID; re-encrypts the vault under the new name and verifies it; removes the old settings
  folder, command and images; then builds and starts the new container. Custom paths are kept.
- **Plain HTTP option.** New setting `HTTP_PORT` (default 8880; empty = not published) and flag
  `--http-mode off|redirect|on`. The wizard asks after the HTTPS choice; the HTTPS menu has a new item 6. The URL
  summary shows the HTTP address when it's on.
- **Fix:** the build context now gets fresh file times on every copy. The embedded source has fixed timestamps,
  and Docker's build cache treated a changed file of the same size as unchanged, so such an edit could be left
  out of the image.
- Self-test: 34 checks (was 30).

### App 3.0.0
- **`general.http_mode`** (`off` | `redirect` | `on`, restart to apply): a second listener on container port 8880.
  `redirect` answers with `308` to the same host and path on the published HTTPS port; `on` serves the dashboard
  (session cookie without `Secure`, no HSTS). Ignored when `tls_mode` is `off`.
- Web UI: the **HTTP / HTTPS** tab has a Plain HTTP setting with port and risk notes; "Serving now" shows it.
- `ctl tls-info` shows `http_mode`.
- Dropped connections (scans, health probes, a browser rejecting the certificate) are logged at debug level
  instead of printing a traceback.
- Tests: 59 (was 55), including the real `serve` command in all three HTTP modes.

## installer v1.4.1 / app v2.3.1 — 2026-10-23 — dashboard layout fix

### App 2.3.1
- **Cards no longer overflow on wide screens.** Port tiles grew to fit long port names, which pushed a card wider
  than its column. Columns can now shrink, cards are at least 680 px wide (one per row on small screens), and long
  port names wrap onto a second line, breaking at hyphens, before they are cut off. The full name stays in the
  tooltip.
- No stray "·" before the uptime when a switch doesn't report a firmware version.
- The top bar no longer causes sideways scrolling on phone-width screens.

### Installer 1.4.1
- Ships app 2.3.1.

## installer v1.4.0 / app v2.3.0 — 2026-10-23 — SNMPv3, port names from the switch

### App 2.3.0
- **SNMPv3 for the GS110TP**, now the default for new SNMP switches.
  - USM in `snmplite.py`: engine discovery, RFC 3414 key localization (checked against the RFC test vectors),
    HMAC-MD5/SHA-96 and HMAC-SHA-224/256/384/512 authentication, DES-CBC and AES-128-CFB privacy, time-window
    resync. USM reports are turned into plain messages (wrong auth password, wrong encryption key, unknown user,
    unsupported security level, user without write access).
  - Interop tested against net-snmp `snmpd` v3 users (SHA/AES, MD5/DES, SHA-256, read-only user).
  - New switch fields `snmp_version` (`3`/`2c`), `snmp_user`, `snmp_auth`, `snmp_priv`, and an encrypted privacy
    key (falls back to the auth password). Switches saved by 2.2.0 have no `snmp_version` and keep using v2c.
  - v3 auth passwords and privacy keys must be 8+ characters; checked when saved.
- **GS110TP port names come from the switch.** Each port's description (`ifAlias`) is read on every poll and shown
  as its name. Renaming a port from the dashboard or `ctl port-name` writes `ifAlias`, reads it back, and saves the
  config. HP 1810 names stay in the dashboard config as before.
  - A dashboard-side name (e.g. set in 2.2.0) still wins as an override; renaming the port moves it to the switch.
  - A poll that was already running when a port was renamed can no longer put the old name back.
  - Ports carry `alias` and `label_src` (`switch`/`dashboard`) in `/api/status`; cards carry `proto` and
    `snmp_version`.
- **Web UI.** The switch editor has SNMP version, user, authentication, encryption and encryption key fields, with
  GS110TP hints. For SNMP switches the port-name grid is replaced by a note (shown only to clear old overrides).
  The port dialog says the name is saved on the switch; a rename that couldn't be saved is shown as a warning.
- **ctl.** `switch add/edit --snmp-version --snmp-user --auth-proto --priv-proto --priv-key-stdin|--priv-key-prompt`,
  `edit --clear-priv-key`. `switch list` shows `snmp v3 admin sha/des`. `port-name` reports where the name went.
- Mock GS110TP: SNMPv3 agent (reusing the client's USM code), writable `ifAlias`, saved/rebooted descriptions.
- Tests: 55 (was 48).

### Installer 1.4.0
- The add-switch menu asks for the SNMP version (3 by default), then the v3 user, auth and encryption protocols, auth
  password and encryption key. It explains the GS110TP specifics (admin user, auth password = login password, DES)
  and warns that v2c is cleartext.

## installer v1.3.0 / app v2.2.0 — 2026-10-23 — Netgear GS110TP, port picker

### App 2.2.0
- **Netgear GS110TP support** (`model: gs110tp`, 10 ports), using SNMP v2c.
  - **Status** comes from IF-MIB / ifXTable / EtherLike-MIB: physical ports only, numbered from `ifName`. Packet
    rates use 64-bit counters, falling back to 32-bit.
  - **Admin up/down** is a `SET ifAdminStatus`, verified by reading it back.
  - **Saving.** With "Save config" on (the default), each change is saved through NETGEAR-SWITCHING-MIB
    `agentSaveConfig`; the `4526.10` and `4526.11` trees are tried, and completion is confirmed with
    `agentSaveConfigStatus`. A save that fails is reported to the user and recorded in the audit log.
  - **Credentials.** The SNMP write community is stored encrypted; SNMP switches never inherit the HP default
    password.
- **`app/snmplite.py`**: a dependency-free SNMP v2c client (BER codec, GET, GETBULK walk, SET). It reports a
  read-only community and no reply (wrong community or SNMP off) as clear errors. Checked against net-snmp.
- **Model abstraction.**
  - Each switch has a `model`; drivers return a common poll format.
  - Protected ports and port names are checked against the model's port count.
  - Cards show the model and a 10-wide port grid.
  - The switch editor shows HP or SNMP fields to match the model, with a port-name grid sized to it.
- **New `ctl` commands.** `models`, `ports SWITCH [--json|--tsv]`; `switch add/edit --model --snmp-port
  --save-config`. `switch list` shows a numbered list with model and connection. `port` on an unknown switch lists
  the configured ones. Port results include whether the change was saved.
- **Fixed: config edits from `ctl` could be missed by the running server.** It compared against a read cache that any
  web request refreshed. It now tracks the version it last applied.
- **Fixed: no polling without credentials.** Switches with no password or community are no longer polled with empty
  credentials; the card says what's missing.
- **Fixed: retiring an SNMP client no longer waits** for a poll that is timing out.
- **Tests:** 48, up from 39. New: the codec, the client against the mock agent, the GS110TP driver (poll, set + save,
  persistence across a simulated reboot, running-config only mode, save-tree fallback, missing save object,
  read-only community), mixed-model dashboard, model validation, CLI with a GS110TP, and change detection for edits
  made in another process.

### Installer 1.3.0
- **Port picker.** Menu **P** and `--port` with missing arguments:
  1. list the configured switches (numbered: model, host, connection);
  2. show the chosen switch's ports with name, admin, link, speed and protection;
  3. offer the opposite of the current state, and ask for confirmation.
  `--port SWITCH N up|down` still runs unattended; an unknown switch name lists the configured ones.
- **`--ports [SWITCH]`** shows the ports of one switch, or of all.
- **Add switch** (menu and wizard) asks for the model first. For the GS110TP it then asks for the SNMP port, the save
  option and the write community.
- **Fixed: keystrokes swallowed.** `docker exec -it` could swallow keystrokes typed while a `ctl` command ran. Now
  the terminal is attached only for `--password-prompt`, and stdin is passed only when piped.
- **Self-test: 30 checks.**

## installer v1.2.0 / app v2.1.0 — 2026-10-23 — HTTPS by default, port names

### App 2.1.0
- **HTTPS by default.** New `general.tls_mode`:
  - `self-signed` (the default) generates an EC P-256 certificate, valid 825 days, covering the host name,
    `localhost`, loopback addresses and `general.tls_san`. It is regenerated when those names change or fewer than
    30 days remain.
  - `custom` serves your certificate chain and key, checked first: valid PEM, key matches certificate, not expired.
  - `off` serves plain HTTP.
  - If a custom certificate becomes unusable, the dashboard falls back to the self-signed one and shows a warning.
  - HSTS is sent only in custom mode, and the session cookie is `Secure` whenever HTTPS is on.
  - A config from before 2.1 without TLS settings becomes `self-signed`; one with a certificate path becomes
    `custom`.
- **Settings → HTTPS tab.**
  - Shows the certificate being served: names, issuer, expiry, SHA-256.
  - Mode and extra names; regenerate the self-signed certificate.
  - **Import certificate…** by paste or file chooser.
  - **Restart now**, which exits so Docker restarts the container. It's enabled when the restart policy allows it.
  - Warnings for pending restarts and for certificates expiring within 30 days.
- **Port names.**
  - Per-switch `port_names`, up to 24 characters each.
  - Shown on the tiles, in the port dialog title, and matched by the filter.
  - Operators can rename ports from the port dialog (`PUT /api/port-name`); admins can edit all 8 in the switch
    editor.
  - Names survive renaming the switch, and each rename is audited with the old and new name.
- **New `ctl` commands.** `port-name`, `port-names`, `tls-info`, `tls-import CERT KEY`, `tls-regen`. `switch show`
  now lists port names.
- **Fixed.** On the Settings page, changing the `#tab` in the URL now switches the tab.
- **Tests:** 39, up from 33. New: self-signed creation, reuse and regeneration; custom import with chain,
  mismatch and garbage input; fallback; config upgrade; an HTTPS round trip with a Secure cookie and no HSTS for
  self-signed; port names in the store, the API with roles, and the CLI.

### Installer 1.2.0
- **Install wizard asks about HTTPS:** self-signed (default), import certificate files, or off. The choice is
  applied before the first start. The self-signed certificate is given the host's FQDN and its non-Docker IPs.
  After every start, the installer prints the certificate mode, days left and SHA-256 fingerprint.
- **New flags:** `--tls-info`, `--tls-import CERT KEY` (host files are validated by the app, then the container
  restarts), `--tls-mode self-signed|off`, `--tls-names LIST`, `--tls-regen`, `--port-name SWITCH N NAME`.
- **Menus.** Settings → 6 **HTTPS**, and Settings → 1 → 6 **Name a port**.
- **Compose file.** Sets the container's host name to the Docker host's short name, so the certificate matches it,
  and passes `HP1810_SELF_RESTART`, which is off when `RESTART_POLICY=no`.
- **Fixed.** The banner showed a stray line break before "absent" when no container existed.
- **Self-test: 28 checks.** New: host name and self-restart in the compose file, and certificate names skipping
  Docker bridge addresses.

## installer v1.1.0 — 2026-10-23 — Self-contained, prerequisites

### Fixed
- **Standalone runs stopped at preflight.** Running the installer on its own, without the repository checkout next to
  it, stopped with "Cannot find the dashboard source" before Docker or anything else was installed.

### Added
- **Embedded app source.** The Dockerfile, `app/` and docs are embedded at the end of the script as a sha256-checked,
  reproducible tar.gz inside a heredoc that is never executed. The installer looks for the source in this order:
  `--source`, a checkout next to the script, the embedded copy, the installed copy. It reports which one it used and
  cleans up the temporary folder on exit.
- **`--build-standalone OUT`** regenerates the self-contained installer. No root needed.
- **Missing prerequisites are installed.** Each required tool is mapped to the package that provides it; only the
  missing packages are installed, with `--no-install-recommends`.
- **Docker handling.**
  - A stopped Docker daemon is started (systemctl, then `service`), waiting up to 20 s.
  - `docker-buildx-plugin` is added when Docker CE is present without it.
  - The banner shows "docker not installed" instead of "docker not running" when Docker is missing.
- **Generated admin password surfaced.** If the container generated the first admin password (for example, the data
  volume was started outside the installer), the installer now shows it.
- **Self-test: 26 checks.** New: source available, embedded payload checksum and layout, version match, script body
  stops before the payload, prerequisite map.

## installer v1.0.0 / app v2.0.0 — 2026-10-23 — Docker, web settings, users

### Installer (new)
- **Menu and CLI.** Menu-driven installer and lifecycle manager in the `mediastack-installer.sh` style. Every menu
  item has a CLI flag. `--dry-run` and `--yes` are supported, destructive actions need a typed keyword (`UNINSTALL`,
  `PURGE-DATA`, `RESTORE`), runs are serialised by a lock, and run logs are rotated (newest 20 kept).
- **Docker.** Installs Docker CE if it's missing, the same way as `docker-base-install.sh`. Builds the image locally
  from the checkout with a pinned `BASE_IMAGE` and `CRYPTOGRAPHY_VERSION`; both can be overridden with `--set`, and
  `BUILD_NETWORK=host` is available for builds behind a local proxy.
- **Service account and vault.** A dedicated nologin, home-less account that is not in the docker group; the data
  directory belongs to it (0700). The vault holding the app secret key is encrypted with systemd-creds/TPM2 or an
  openssl fallback, and `--rekey` re-encrypts it.
- **Compose file.** Generated with a read-only root filesystem, `tmpfs /tmp`, `cap_drop: ALL`,
  `no-new-privileges`, `init`, a memory limit, log rotation and a healthcheck. The secret key is injected at start
  time; the compose file itself refuses to start without it.
- **First admin.** The first admin user is created before the first start, with your password or a generated one
  (shown once and saved root-only).
- **Settings menu.**
  - Switches: add, edit, remove, test one, test all.
  - Switch defaults, users and general settings, all wrapping `hp1810dash ctl`.
  - Container/host settings: network, paths, image pins, limits, logs, account, vault.
- **`--ctl ARGS…`** runs any `ctl` command. It uses `docker exec` when the container is running, a one-off container
  when it is stopped, and a TTY when you're at a terminal so `--password-prompt` works.
- **`--port SWITCH N up|down`.**
- **Backup and restore.**
  - `--backup` archives the data, settings, vault and key (0600) and prunes old archives.
  - `--restore` validates the archive's paths, moves the current data aside, and re-owns the restored data.
- **Uninstall** keeps data unless you also purge it, and asks separately before removing the service account.
- **Self-test.** `--self-test` runs 22 checks: validators, `safe_path`, config round-trip, compose rendering and
  hardening, build command, `docker compose config` validation, the start-without-key guard, and a vault round-trip.
  `--app-self-test` runs the app suite inside the image.

### App 2.0.0
- **Breaking.** Configuration moved to `/data/config.json` (schema 2). Use `ctl import-v1` to bring in a v1
  `switches.json`.
- **Container-ready.** `serve`, `ctl`, `health` and `selftest` subcommands; runs as non-root on a read-only root
  filesystem; `/data` volume.
- **Encrypted secrets.** Switch passwords and the default password are encrypted with Fernet. The key comes from
  `HP1810_SECRET_KEY`, or `/data/.secret.key` when that variable isn't set.
- **Users and roles.**
  - viewer, operator and admin, with PBKDF2-SHA256 password hashes.
  - Form login with server-side sessions, an HttpOnly + SameSite=Strict cookie, and a CSRF header on every change.
  - Lockout per IP after failed logins.
  - Sessions are dropped when a user's role or password changes; the last admin can't be removed.
- **Web Settings page.**
  - Switches: add, edit, delete, test connection with the unsaved values, test all.
  - Switch defaults, including the default password.
  - Users.
  - General: title, poll interval, session lifetime, lockout, log level, audit rotation, TLS certificate/key.
- **Audit page.** Search, adjustable limit, auto-refresh.
- **Self-service.** Change your own password and sign out from the user menu.
- **`ctl` CLI.** `show`, `keys`, `get`, `set` (several keys in one call), `switch …`, `user …`, `port`, `audit`,
  `import-v1`. Passwords are only read from stdin or a prompt.
- **Live reload.** Changes made from the GUI and the CLI are picked up without a restart. When a switch's settings
  change, its old session is logged out.
- **`ctl port` goes through the running server** via a token-protected, loopback-only endpoint, so it reuses that
  switch's session instead of using up another login slot. If the server isn't running, it connects to the switch
  directly.
- **Per-switch options.** Each switch can override the scheme, TLS verification, timeout and username, or inherit
  them from the defaults. Switches can also have notes, and polling can be turned off without deleting the switch.
- **Optional HTTPS** using a certificate and key in `/data` (adds a Secure cookie and HSTS).
- **Audit log.** Rotates by size, records which fields changed rather than their values, and never records
  passwords.
- **Security headers.** Strict CSP with no inline script or style, `X-Frame-Options: DENY`, nosniff, no-referrer.
- **Tests.** 33 tests covering parsers, the client against a mock switch, crypto, the config store, the audit log,
  the HTTP API with roles and CSRF, the internal endpoint and the CLI.

## app v1.0.0 — 2026-10-22 — Initial release
- Single-file dashboard (standard library only) that drives the PL.2.10 web UI.
- Port status and admin up/down, protected ports, HTTP Basic auth, an audit log.
- `--check` and `--set` CLI. Plaintext `switches.json`.
