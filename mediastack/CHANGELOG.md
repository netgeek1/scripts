# Changelog

All notable changes to **mediastack-installer.sh**. Newest first.
`SCRIPT_VERSION` in the script is the authoritative version string. Versions follow `MAJOR.MINOR.PATCH`.

## v2.8.0 — 2026-11-24 — Authentik forward auth configured automatically

### Added
- **Authentik blueprint** (`<data>/authentik/blueprints/mediastack-forward-auth.yaml`, mounted as
  `/blueprints/mediastack` in the server and worker). It creates upstream's manual setup:
  - the domain-level forward-auth proxy provider for `https://auth.<domain>`, cookie domain `<domain>`
  - the "Authentik" application
  - the embedded outpost bound to it, with `authentik_host: https://auth.<domain>/`

  This fixes app hostnames showing Authentik's "Not Found" and redirects to `http://0.0.0.0:9000/...`. Objects with
  the upstream names are updated, not duplicated.
- **`AUTHENTIK_BOOTSTRAP_PASSWORD`**: generated into the vault, and becomes `akadmin`'s password on a new Authentik
  database (Secrets → 4 to reveal). The install summary says how to sign in.
- Self-test: 83 checks.

## v2.7.0 — 2026-11-24 — CrowdSec bouncer works out of the box

### Fixed
- **Every HTTPS hostname answered 404** ("middleware traefik-bouncer@file does not exist"). Traefik fetches the
  CrowdSec bouncer plugin when it starts, and if that fails plugins stay off for the container's lifetime. After
  starting, Apply now checks Traefik's API, restarts Traefik once if the plugin is missing, and shows Traefik's
  plugin messages if the retry fails too.
- **Upstream's sample CrowdSec LAPI key.** Every install had the same key, and no CrowdSec knew it, so the bouncer
  would refuse requests once loaded. A per-install `CROWDSEC_BOUNCER_KEY` is now generated into the vault and
  written into Traefik's `dynamic.yaml` on every apply. CrowdSec registers it via `BOUNCER_KEY_traefik` in the
  managed override, which also sets `COLLECTIONS=crowdsecurity/traefik crowdsecurity/http-cve`.
- Secrets that a newer version adds (generated ones) are now created on apply, so an existing install does not
  need a full reinstall.
- The Traefik check also shows Traefik's plugin messages.
- Self-test: 82 checks.

## v2.6.1 — 2026-11-24

### Added
- **Traefik check** (Post-install helpers → 7, `--helper traefik-check`): asks Traefik's own API which routers are in
  error and why (an error makes the hostname answer 404). It also checks whether the config-file (`@file`)
  middlewares loaded, shows the certificate actually served, and lists recent Traefik errors.
- Self-test: 81 checks.

## v2.6.0 — 2026-11-24 — URLs, ports and DNS view

### Added
- **Menu L / `--urls`:** every enabled service's LAN URL (`http://<host-ip>:<WEBUI_PORT_*>`, with `/web` for Plex) and
  HTTPS hostname(s), read from the effective `docker compose config` (Traefik `Host()` rules). It notes "via VPN"
  (runs in Gluetun's network) and "Authentik login" (forward-auth middleware).
- The other published ports (VPN proxy, torrent, Plex discovery, databases, metrics), each named after the `.env`
  variable that sets it.
- The DNS records to create: one wildcard `*.<domain>` for LAN DNS and, in `internet` mode, public DNS plus the
  HTTPS port forward.
- The full install's summary shows this view instead of its fixed 15-app list, and Apply points to it.
- Self-test: 80 checks.

## v2.5.10 — 2026-11-24

### Fixed
- **"Served now" was empty, and every certificate check restarted Traefik.** The local check connected with the bare
  domain as SNI (`certifiedgeeks.net`). A wildcard certificate (`*.certifiedgeeks.net`) doesn't cover it, so
  Traefik's strict SNI refused the handshake. The check read that as "old certificate" and restarted Traefik. It now
  uses `mediastack-probe.<domain>`, which the wildcard covers.
- No TLS answer at all is now reported as `live=unknown`, with a pointer to Traefik's log, instead of restarting
  Traefik. A restart happens only when Traefik answers with a different certificate.
- Self-test: 79 checks.

## v2.5.9 — 2026-11-24

### Fixed
- **Apply looked hung after "N container(s) started or running".** The installer then waited silently for up to
  180 s for every service to run, and up to ~45 s more for Traefik to serve the certificate. It now:
  - says what it waits for, with a live count and the services still pending (every 30 s when not on a terminal)
  - stops waiting early when the remaining services have exited or were never started, since waiting can't change that
  - announces the Traefik certificate check

## v2.5.8 — 2026-11-24

### Fixed
- **The second route came from an orphaned bridge, not a Docker network.** `br-cef1f9fa439b` was left behind by a
  Docker network that no longer exists. Docker no longer lists it, so 2.5.7's check didn't see it, but its
  `linkdown` route for `172.28.10.0/24` still captured the replies, because Linux uses linkdown routes unless
  `ignore_routes_with_linkdown` is set. Apply now also checks host interfaces on the stack's subnet:
  - orphaned Docker bridges (`br-<12 hex>`, no ports, unknown to Docker) are deleted
  - any other interface on that subnet stops Apply with what to do
- Self-test: 78 checks.

## v2.5.7 — 2026-11-23

### Fixed
- **Gluetun's WireGuard handshake never completed** although the server answered. Two Docker networks used the
  stack's subnet `172.28.10.0/24` (`br-96030da22a8b` and `br-cef1f9fa439b`), so the host had two routes for it, and
  the de-NATed answers were routed into the other bridge. Apply now checks this before starting (`ensure_stack_network`):
  - duplicates that belong to MediaStack or are unused are removed (the stack is stopped first) and Compose recreates
    the network
  - a network from something else that is in use stops Apply with what to do
- The WireGuard probe reports more than one host route for the stack's subnet.
- Self-test: 77 checks.

## v2.5.6 — 2026-11-23

### Changed
- The container egress test also runs on **the stack's own Docker network** (Gluetun's network, a `br-…` bridge),
  not only on `docker0`. When `docker0` works and the stack's bridge doesn't, it says so and points at a host
  firewall rule that allows `docker0` only. The tcpdump advice explains how to read a lost reply.

## v2.5.5 — 2026-11-23

### Fixed
- **`sudo mediastack-installer` ran an older version** than the copy you just started. The installed copy
  (`/usr/local/sbin/mediastack-installer`) was only refreshed by a full install or restore. Now any run of a newer
  copy updates it, and an older copy never overwrites a newer installed one. The certificate timer/watcher and the
  push receiver use the installed copy, so they stay current too.

### Added
- The WireGuard probe shows Gluetun's **source port**. When it equals the server port (51820), the probe warns
  that a router/firewall forwarding inbound UDP 51820 (e.g. its own WireGuard server) or rewriting source ports
  can swallow the server's answer, while a `wg-quick` test from the host uses a random port and works.
- Self-test: 76 checks.

## v2.5.4 — 2026-11-23

### Added
- The WireGuard probe also shows the **server key** Gluetun uses (compare with `[Peer] PublicKey`). When there is no
  handshake, it runs a **container egress test** (DNS to 1.1.1.1 from a throwaway container on Docker's bridge) to
  tell a broken Docker forwarding/NAT setup apart from something upstream treating NATed container UDP differently,
  and says what to check for each.

### Changed
- The "passes no traffic" hint no longer suggests ProtonVPN `FREE_ONLY` or server-list updates for provider `custom`.

## v2.5.3 — 2026-11-23

### Added
- **WireGuard handshake probe:** when Gluetun is unhealthy, the diagnosis reads `wg show` inside Gluetun's network
  namespace (`nsenter`). It reports the interface public key, the peer endpoint, bytes sent/received and the last
  handshake, then says what that means:
  - no handshake: compare the public key with a working config's (a wrong stored key, or packets get no answer)
  - handshake with data: the tunnel works and the problem is DNS or the health check
  Needs `wireguard-tools` on the host.
- **VPN check** helper (Post-install helpers → 6, `--helper vpn-check`): settings problems, Gluetun's state, recent
  errors with hints, and the handshake probe, at any time.
- Self-test: 75 checks.

## v2.5.2 — 2026-11-23

### Fixed
- **`custom` + WireGuard refused to start** ("for VPN service provider custom: the country specified is not valid").
  Server filters kept from a listed provider were still passed. `custom` has no server list, so Apply now leaves
  `SERVER_COUNTRIES`/`CITIES`/`HOSTNAMES`/`REGIONS` out of `.env` for `custom` (the settings are kept for switching
  back), and the wizard doesn't ask for them. There is a matching hint in the start-failure diagnosis.
- **Deprecated endpoint names:** Gluetun warned about `VPN_ENDPOINT_IP`/`_PORT`, which upstream's compose file
  passes. They are now blank in `.env`, and the override sets `WIREGUARD_ENDPOINT_IP`/`_PORT` for custom WireGuard.
- Self-test: 74 checks.

## v2.5.1 — 2026-11-23

### Fixed
- **False "The VPN rejected the username/password" hint for WireGuard.** The diagnosis picked log lines containing
  `fail` or `auth` anywhere, including Gluetun's settings dump ("Restart VPN on healthcheck failure", "Authentication
  file path"), and matched hints across line breaks. It now uses only lines with Gluetun's `ERROR`/`WARN`/`FATAL`
  level and judges each line on its own.
- The "tunnel passes no traffic" hint names the usual WireGuard causes: a ProtonVPN free plan (only free servers
  accept the key, so set `FREE_ONLY=on`), outbound UDP 51820 blocked by a firewall, a revoked key, or an outdated
  server list.
- Self-test: 73 checks.

## v2.5.0 — 2026-11-23 — Gluetun WireGuard fixes and server-list updates

### Fixed
- **Misleading "WireGuard settings problem: re-import the provider's wg0.conf".** The start-failure diagnosis
  matched hints against Gluetun's **whole** log, so every normal `[wireguard]` line produced that hint, whatever the
  real cause was. Hints now come only from Gluetun's error/warning lines, and the WireGuard hint needs an actual
  key/address error.
- **Stale fixed endpoint for listed providers.** `VPN_ENDPOINT_IP` / `_PORT` / `WIREGUARD_PUBLIC_KEY` were written to
  `.env` only when set and never blanked. A value left from an earlier `custom` setup (the old default) or from an
  existing `.env` stayed, and Gluetun then looks for exactly that server in its list ("target IP address not
  found"). For every provider except `custom` they are now blanked on each apply. `OPENVPN_CUSTOM_CONFIG` is also
  blanked when not using custom OpenVPN.
- **IPv6 in `Address`** (newer ProtonVPN configs): Docker gives Gluetun no IPv6 by default, so only the IPv4
  address(es) go to `WIREGUARD_ADDRESSES`.
- Importing a `wg0.conf` for a listed provider says that its `Endpoint` is not used (Gluetun picks a server).

### Added
- **Automatic server-list updates:** `VPN_SERVERS_UPDATE_PERIOD` (default `480h`; `off` to disable) sets Gluetun's
  `UPDATER_PERIOD` in the managed override.
  - ProtonVPN needs an account to download its list. `VPN_UPDATER_PROTON_EMAIL` and the vault secret
    `UPDATER_PROTONVPN_PASSWORD` become `UPDATER_PROTONVPN_EMAIL` / `_PASSWORD`. Without them, automatic updates
    stay off for ProtonVPN.
- **Update the server list now:** Post-install helpers → 5 / `--helper vpn-servers` runs Gluetun's CLI updater
  (outside the tunnel) and restarts Gluetun. Credentials are passed as environment variables, not on the host's
  command line.
- **Server filters in the wizard:** `SERVER_COUNTRIES`, `SERVER_CITIES` and `SERVER_HOSTNAMES` (plus
  `SERVER_REGIONS`) are config settings, validated and written to `.env`. Values hand-edited into `.env` before are
  taken over.
- New hints: fixed endpoint ("target IP address not found" / "endpoint IP is not set"), and a tunnel that is up but
  unhealthy (key not accepted or an outdated server list → update the list).
- Self-test: 72 checks.

## v2.4.0 — 2026-11-23 — Certificate pull and push

### Added
- **Two new certificate modes, matching docker-dashboard:**
  - **`CERT_MODE=fetch` (pull):** the pair is copied over scp from `CERT_FETCH_SOURCE` (`user@host:/folder`, with
    `CERT_FETCH_CERT` / `CERT_FETCH_KEY` file names) on every apply and daily via `mediastack-cert.timer`.
    `--cert-fetch-key` (menu K → 3) creates the SSH key. If a fetch fails, the last good certificate stays in use
    and the timer run exits non-zero.
  - **`CERT_MODE=push`:** another machine streams `chain + key` over SSH to `--cert-receive`.
    - `--cert-push-setup [FILE|-]` (menu K → 4) creates the push user (`CERT_PUSH_USER`, default `mscertpush`), an
      `authorized_keys` line restricted to that one command (`restrict`, optional `from=` from `CERT_PUSH_FROM`),
      and a sudoers rule for that exact command, checked with `visudo`.
    - Input is capped (64 KB, 30 s). A push waits up to 5 minutes for a running menu or apply.
    - It prints docker-dashboard's status line (`DD-CERT-RECEIVE OK changed|unchanged sha256=… notafter=…
      live=…` / `DD-CERT-RECEIVE FAIL <reason>`), so the same deployer can push to both hosts.
  - Until the first fetch or push, Traefik serves a temporary self-signed certificate.
- **Certificate menu (K) / CLI:** refresh now (`--cert-refresh`), show what is deployed and what Traefik really
  serves (`--cert-show`), fetch key, push receiver, change mode/source. Mode and source can be changed at any time
  after the install.
- **Manual mode with file paths:** `mediastack-cert.path` watches the two files, and a renewal job replacing them is
  deployed without an Apply.
- **Traefik really serves the new certificate:** after any file-based certificate change (and after every apply),
  the installer compares what Traefik serves with `cert.pem`. It first lets Traefik's file watcher reload, then
  restarts `traefik` if needed.
- Status shows the fetch source / push user and when the last certificate arrived.
- Certificate refresh and push runs log to `cert-*.log`, rotated separately, so daily runs never push the install
  logs out.
- Uninstall removes the certificate units, the push user and its sudoers rule.
- Self-test: 69 checks.

### Changed
- The manual-certificate install is shared by `manual`, `fetch` and `push`, and replaces `cert.pem` / `key.pem`
  atomically.

### Notes
- Traefik uses strict SNI. A pusher's TLS check must use a hostname under the domain, not the IP.

## v2.3.0 — 2026-11-23 — Quiet console, paste and region fixes

### Changed
- **Pull/start output no longer floods the screen.** `docker compose pull` and `up` run with plain progress.
  - **Console:** one status line that updates in place ("Pulling images: 7 done, now sonarr", "Starting containers:
    …"), then a summary (images pulled, containers up). Errors are always printed in full. When the output is not a
    terminal, it prints one line per pulled image.
  - **Install log:** every line, except the per-layer byte counters (`Downloading 138.4MB`, `Extracting 6B`). Layer
    milestones (`Download complete`, `Pull complete`), image and container events, and errors are all kept.
  - Builds on 2.2.2, which made the pull fully quiet and lists the images that were new or updated.

### Fixed
- **Pasting a `wg0.conf` or `.ovpn` whose last line has no newline.** That line (for example
  `PersistentKeepalive = 25`) stayed in the terminal buffer and became the answer to the next prompt, which is the
  VPN regions prompt. Gluetun then failed with "the region specified is not valid". The paste now reads in
  non-canonical mode and keeps the unterminated last line.
- `SERVER_REGIONS` is checked: values with `=`, `[`, `]`, `#` or `/` are rejected in the wizard and in `--set`. A bad
  stored value is cleared in the wizard and reported in the VPN preflight.
- Gluetun diagnosis: "server selection … region specified is not valid" was also reported as an unknown provider.
  It now gives only the server-filter hint, and says when the provider has no regions at all.
- Self-test: 65 checks.

## v2.2.2 — 2026-11-23

### Changed
- `pull` runs with `--quiet` and reports which images were new or updated. `up` uses `--quiet-pull`. Both are
  replaced by the compact output of 2.3.0.

## v2.2.1 — 2026-11-23

### Fixed
- **WireGuard: no more prompt for `WIREGUARD_PRESHARED_KEY`.** It was treated as required whenever WireGuard was
  selected, so it was asked for after importing a `wg0.conf`, even though most providers (Mullvad, Proton,
  NordLynx, Surfshark) don't use one. It is now optional: it is taken from the `PresharedKey` line of `wg0.conf`
  when present and left blank otherwise. Importing a config without one also clears a stale key from an earlier
  config. It can still be set by hand in the Secrets menu.
- Self-test: 62 checks.

## v2.2.0 — 2026-11-23 — Certificate chains, VPN checks and diagnostics

### Fixed
- **Full chains with several certificates.** The chain paste stopped at the first blank line after a certificate,
  so a chain with blank lines between its certificates kept only the first one. The paste now reads every
  certificate and ends 3 seconds after the paste, at `END`, or at Ctrl-D.
- **Gluetun unhealthy → most apps "not started".** The new-install default `VPN_SERVICE_PROVIDER=custom` cannot work
  without a custom config, and the installer never collected one. The provider now has no default and must be
  chosen, and the VPN is checked before anything starts (see *Added*).
- A failed `compose up` or `pull` no longer prints error-trap stack lines. It ends with a diagnosis and one clear
  message.

### Added
- **Chain handling for manual certificates:** the chain may be in any order. It is listed (`subject <- issued by`),
  the leaf is found by its key, and Traefik gets it as leaf → intermediate(s) → root. There is a warning when only
  the server certificate is present.
- **VPN section in the wizard (Settings → 8):**
  - The provider is checked against Gluetun's names.
  - OpenVPN credentials are entered there.
  - `custom` + OpenVPN takes your `.ovpn` by path or paste. It is stored in `/etc/mediastack/vpn/`, copied to
    Gluetun as `/gluetun/custom.ovpn`, and sets `OPENVPN_CUSTOM_CONFIG`.
  - WireGuard imports your provider's `wg0.conf` by path or paste. The private/preshared keys go into the vault,
    plus `WIREGUARD_ADDRESSES` and, for `custom`, the endpoint IP/port and the server public key.
- **VPN preflight:** before starting, the installer lists what stops Gluetun connecting (provider, credentials,
  `.ovpn`, WireGuard key/address/endpoint, `/dev/net/tun`). It refuses to start unless you confirm.
- **Start-failure diagnosis:** shows the containers that are not running, Gluetun's last error lines, and the likely
  cause (wrong credentials, no matching server, unknown provider, custom config, WireGuard, TUN device, unreachable
  server).
- Status shows the VPN provider/type and any VPN problems.
- New settings: `VPN_CUSTOM_OVPN_FILE`, `WIREGUARD_ADDRESSES`, `VPN_ENDPOINT_IP`, `VPN_ENDPOINT_PORT` and
  `WIREGUARD_PUBLIC_KEY` (written to `.env` only when set). They are also detected from an existing install's
  `.env`.
- Self-test: 61 checks.

## v2.1.0 — 2026-11-19 — Paste and encrypted keys for manual certificates

### Added
- **Paste instead of a path.** At the certificate and key prompts (wizard and Settings → Access/certs), type
  `paste` and paste the PEM.
  - The chain ends at a blank line, `END` or Ctrl-D.
  - The key paste is hidden and ends at its `-----END … PRIVATE KEY-----` line. CRLF is accepted.
  - Pasted PEMs are stored in `/etc/mediastack/tls/manual-cert.pem` (0644) and `manual-key.pem` (0600), and are
    covered by both backup formats.
- **Encrypted private keys.** PKCS#8 (`ENCRYPTED PRIVATE KEY`) and traditional (`Proc-Type: 4,ENCRYPTED`) keys are
  detected.
  - The passphrase is asked for, verified (3 tries) and stored in the vault as `TLS_KEY_PASSPHRASE`. It is passed to
    OpenSSL on a file descriptor, never on the command line or in logs.
  - Each apply decrypts the key into Traefik's root-only copy, so a renewal job can keep writing encrypted keys
    without prompts.
  - A missing or wrong passphrase stops the apply with instructions.
- Self-test: 56 checks (encrypted key formats and passphrases; the paste readers).

## v2.0.1 — 2026-11-19 — Preflight fix

### Fixed
- On a host without Docker yet, the preflight Compose version check called the missing `docker` command. This
  printed two `[FAIL] rc=127 ... sed 's/^v//'` lines and a warning with an empty version. The check now reports
  "Docker is not installed yet; it is installed after the settings" and only compares versions when Docker exists.
  The install itself was not affected.
- Self-test: 54 checks (version check with no Docker on PATH).

## v2.0.0 — 2026-11-19 — Presets, access modes, certificates, Homarr 1.x, standard CLI

### Breaking
- **Homarr moves to homarr-labs (1.x).** `ghcr.io/homarr-labs/homarr:latest` replaces upstream's legacy
  `ghcr.io/ajnart/homarr` via the managed override (`volumes`/`environment` use `!override`):
  - data now lives in `<FOLDER_FOR_DATA>/homarr/appdata`, with a read-only Docker socket
  - a generated 64-hex `SECRET_ENCRYPTION_KEY` comes from the vault
  - 0.x boards are not migrated (they stay in `homarr/configs`)
- Docker Compose **v2.24.4+** is required (for `!override`). The installer upgrades `docker-compose-plugin` when it
  is older.
- New installs default to the **Core** preset (about 15 services LAN-only, about 23 Internet-facing) instead of
  "everything".
- New installs default to the **official Tailscale control server**. Existing v1.x configs keep their behaviour
  (see *Changed*).

### Added
- **Service presets** chosen in the wizard: `core` (default), `full` and `custom`.
  - Core: Gluetun, qBittorrent, SABnzbd, Prowlarr, FlareSolverr, Unpackerr, Sonarr, Radarr, Lidarr, Bazarr, Seerr,
    Homepage, **Tailscale**, Audiobookshelf + `PLAYER` (Jellyfin, Plex or both). In `internet` mode it adds
    Traefik, Authentik + worker, CrowdSec, PostgreSQL, Valkey and traefik-certs-dumper; with Headscale control it
    adds Headscale + Headplane.
  - Full: every upstream service except Whisparr (disabled).
  - Readarr is always removed (retired upstream).
- **Access mode** asked at install: `internet` (Traefik, Authentik, CrowdSec on a public domain) or `lan` (apps on
  their own ports; no Cloudflare or public domain needed; defaults to `mediastack.lan`).
- **Certificate source** for Traefik:
  - `letsencrypt`: upstream's Cloudflare DNS-01
  - `selfsigned`: a local CA in `/etc/mediastack/tls`, plus a wildcard leaf for the domain and host IP that is
    renewed 30 days before expiry or when the domain or IP changes
  - `manual`: your full-chain cert + key, checked for key match, expiry and `*.<domain>` coverage, and re-copied on
    every apply
  - For `selfsigned` and `manual`, the ACME resolver is removed from Traefik's config, a `sniStrict`-compatible file
    certificate is wired in, and `traefik-certs-dumper` is parked automatically.
- **Tailscale control server** setting (`TAILSCALE_CONTROL`): `tailscale` (official; overrides only
  `TS_EXTRA_ARGS` to drop upstream's `--login-server`) or `headscale` (upstream).
- **Dependency check**: covers upstream `depends_on` and `network_mode: service:*`, plus Traefik → CrowdSec/Authentik
  and Tailscale → Headscale. It warns in Settings, `--set` and status, and **refuses to apply** while an enabled
  service needs a disabled one.
- **Secrets are prompted only when used.** The Cloudflare token only with Traefik + Let's Encrypt, PLEX_CLAIM only
  with Plex, VPN credentials only with Gluetun, and SMTP only with Authentik. Unused placeholders no longer warn.
- **Standard CLI**, matching the other netgeek1 installers:
  - `--restart` and `--logs [N] [SERVICE]`
  - `--show-config` (every key with its meaning) and `--set KEY VALUE` (validated; re-applies presets; switches to
    `custom` when the lists are edited)
  - `--backup [--portable]`, `--restore FILE`, `--passphrase-file` / `MS_BACKUP_PASSPHRASE`, and `--rekey`
- **Backup / restore:**
  - host format (`tar.gz`): settings, vault + key, TLS CA, compose folder and app data, made with the containers
    stopped
  - portable format (`.msbak`): the same with secrets decrypted inside a passphrase-encrypted archive
    (AES-256-CBC, PBKDF2-SHA256 × 600,000) that restores onto a fresh host
  - Media and Plex/Jellyfin caches are excluded, and backups are pruned to `BACKUP_KEEP`.
  - Restore keeps the previous folders as `*.pre-restore-*` and refuses unsafe archives.
- Menu: **R** restart, **B** backup/restore, **C** show settings. Settings gains **Access / certs** and **Services**
  (preset, player, Tailscale control), and the backup settings are added to the upstream/secrets section.
- Status shows access mode, certificate source and expiry, preset, auto-off services and dependency problems. The
  summary prints `https://<app>.<domain>` links when Traefik runs.
- **MIT LICENSE** file. The header now reads *Author: netgeek1 & Claude (Anthropic)* and *License: MIT*, and the
  script has `SCRIPT_DIR`.
- Self-test grows to 53 checks.

### Changed
- Existing v1.x configs **keep their behaviour**. Settings missing from the file default to `ACCESS_MODE=internet`,
  `CERT_MODE=letsencrypt`, `SERVICE_PRESET=custom`, `TAILSCALE_CONTROL=headscale` and `PLAYER=both`.
- Post-install helpers are offered only for enabled services (Authentik, Guacamole).
- The README quick start points at `netgeek1/scripts`.

### Fixed
- `producer | grep -q` pipelines could fail with SIGPIPE (rc 141) under `pipefail` and make an enabled service look
  disabled. All such checks now match against captured output.
- `--restore NAME` now finds backups in `BACKUP_DIR` and next to the installer.

## v1.2.0 — 2026-10-16 — Audiobookshelf add-on

### Added
- **Add-on services**: services the installer adds on top of upstream. They are rendered into the managed
  `docker-compose.override.yaml`, so the upstream compose file is never edited, and they toggle on, disabled or
  removed like any other service. They are marked `+` in Settings → Services.
- **Audiobookshelf** add-on (on by default):
  - official `ghcr.io/advplyr/audiobookshelf` image, run as `user: PUID:PGID`
  - port `WEBUI_PORT_AUDIOBOOKSHELF=13378`, added to `.env` once
  - Traefik route `audiobookshelf.<domain>` without forward-auth, so the mobile apps work
  - `/config` and `/metadata` under app data; `/audiobooks`, `/podcasts` and `/books` under `media/`
  - creates `media/podcasts` and the app-data folders
  - warns when app data is on network storage (SQLite)
- Self-test: 34 checks (add-on rendering when on, disabled and removed).

## v1.1.0 — 2026-10-16 — Storage, settings menu, generic defaults

### Added
- **Storage layer** for media and app data: `local`, `smb` (CIFS: Windows/NTFS, Samba, macOS, Synology/TrueNAS/QNAP),
  `nfs` (v3/v4.x) and `external` (a mount you manage yourself).
  - Managed shares are written to fstab under a marker line with `_netdev,nofail`; the original fstab is backed
    up once.
  - SMB credentials are kept in the vault and written to a 0600 file for `mount.cifs`.
  - SMB mounts set `uid/gid` to the service account and `0775` modes.
  - A Docker `RequiresMountsFor=` drop-in makes Docker wait for the mount at boot.
  - An empty mountpoint is made immutable, so a missing share can't fill the local disk.
  - Each apply runs a post-mount write test as the service account.
  - Changing the share or its type remounts it (stopping the stack first); switching to `local` releases it.
- `Settings → T` / `--test-storage MEDIA|DATA` trial-mounts a share and tests write and **hardlink** support as the
  service account.
- Refuses to mount over a folder containing real files, and prints `rsync` migration steps. A folder holding only
  the installer's own empty skeleton is cleaned up automatically.
- **Settings menu** (`2` / `--settings`) edits one section at a time: paths, domain/network, media storage, app-data
  storage, service account, services, VPN/email, upstream/secrets. It also offers re-detect, test, view, save, and
  save + apply. The first-run wizard uses the same sections.
- **Detection** of defaults:
  - an existing install, from running containers or common folders, with its `.env` values (placeholders ignored)
  - the domain, from `.env` or `hostname -d`
  - the service account, from the existing `PUID`
  - folders that are already mountpoints, proposed as `external`
  - IP, subnet and timezone
  - `Settings → D` re-runs detection.
- **Service states**: `on`, `disabled` (never started, folders kept) and `removed` (never started, no app-data
  folder, skipped by helpers), toggled from a numbered list of the compose variant's services.
- Status shows storage type, share, mounted state and usage.
- Self-test grows to 31 checks (storage rendering, fstab editing, remote parsing, service states, config migration).

### Changed
- **Readarr is `removed` by default** (retired upstream). Whisparr stays `disabled`.
- Generic defaults for public use: no built-in domain (detected or required), no extra packages, blank SMTP.
- `EXCLUDE_SERVICES` is replaced by `DISABLED_SERVICES` / `REMOVED_SERVICES`. v1.0.0 configs migrate automatically.
- Folder creation, ownership and app-config placement are storage-aware. No chown on SMB. On root-squashed NFS,
  folders are created as the service account and a failed chown is reported, not treated as fatal.
- Uninstall wipes only the contents of mounted folders, releases managed mounts, and warns that deleting media on
  a share deletes it on the server.
- Non-interactive runs fail fast with a clear message when a required value (e.g. `DOMAIN`) is missing or invalid.

### Fixed
- A refused mount (non-empty folder) no longer leaves an fstab entry behind that would mount at next boot.

## v1.0.0 — 2026-10-16 — Redesign

This is a full rewrite of the unversioned `mediastack-installer.sh`, now referred to as "pre-1.0". It targets
upstream `geekau/mediastack` @ `8e908ae60bf4` (2026-04-24).

### Added
- Menu-driven UI (Setup / Operate / Maintenance) with matching CLI flags: `--install`, `--apply`, `--start`,
  `--stop`, `--status`, `--helper`, `--secrets`, `--uninstall`, `--purge-docker`, `--compose`, `--self-test`,
  `--dry-run`, `--yes`, `--ref`, and `--confirm`.
- Persistent config at `/etc/mediastack/mediastack.conf` (0600). Prompts default to your saved values, not
  hard-coded ones.
- Encrypted secrets vault at `/etc/mediastack/secrets.enc`. It uses `systemd-creds` (TPM2 and/or host key) when
  available and falls back to `openssl` AES-256 with a root-only key file.
  - `SECRETS_MODE=vault` (default): secrets stay out of `.env` and are injected into the `docker compose`
    process environment at runtime.
  - `SECRETS_MODE=env`: secrets are written into `.env` (0600 root) so the upstream scripts and plain
    `docker compose` work.
  - Secrets menu with status, set/change, reveal, export, import, and re-encrypt. Changing
    `POSTGRESQL_PASSWORD` also runs `ALTER ROLE` in the live database.
- Dedicated `mediastack` system service account: nologin, no home, not in the `docker` group. Optional fixed
  UID/GID for NFS shares.
- Upstream pinned to a commit SHA, cached under `/var/lib/mediastack-installer/upstream/<sha>`, and overridable
  with `--ref` or `UPSTREAM_REF`. Falls back to `git clone` if the tarball download is blocked.
- Upstream drift check that warns if upstream's folder layout no longer matches the installer's.
- Service exclusion via a managed `docker-compose.override.yaml` that puts services in a `disabled` profile.
  The upstream compose file is never edited.
- Native post-install helpers: secure the Authentik DB, create the Guacamole DB and schema, reset the
  `akadmin` password, and read *ARR API keys (optionally storing them in the vault).
- Auto-detection of `LOCAL_DOCKER_IP` / `LOCAL_SUBNET` (`auto`, re-detected on every apply) and of the
  timezone.
- Automatic generation of the headplane `cookie_secret` (stored in the vault).
- Run logs under `/var/log/mediastack/installer-*.log`, keeping the newest 20, with secrets never logged.
- Single-instance lock, ERR trap with line numbers, and dry-run mode (menu `T` or `--dry-run`).
- Built-in self-test (22 checks; no root, Docker, or network needed).
- Installer copies itself to `/usr/local/sbin/mediastack-installer`. Generated `restart.sh` / `stop.sh` /
  helper wrappers in the compose folder call it. Upstream originals are kept as `*.upstream`.
- Backups to `<compose>/.backup/<timestamp>/` before any upstream file is overwritten on upgrade.

### Changed
- The stack is managed project-scoped (`docker compose -p mediastack`). The installer no longer runs
  upstream `restart.sh`, which stops every container on the host and prunes all volumes, networks, and images.
- `uninstall` removes only the MediaStack stack plus its compose and app-data folders, gated by the typed
  keyword `UNINSTALL`. Deleting the media library (`DELETE-MEDIA`) and purging the Docker Engine
  (`PURGE-DOCKER`, separate menu item) need their own confirmations.
- The default compose folder is now `/mediastack/compose`, separate from app data. An existing
  `/mediastack/appdata` layout is detected and still supported.
- Folder layout matches upstream at the pinned commit (traefik, crowdsec, headscale/headplane, seerr, grafana,
  prometheus, valkey, …). Whisparr and `xxx` folders are kept.
- The media library is no longer re-owned recursively on every run. Only the structure is re-owned, unless
  `CHOWN_MEDIA_RECURSIVE=yes` or you confirm a one-time re-own when ownership differs.
- Docker install supports Debian as well as Ubuntu and removes conflicting distro packages first (after
  confirmation).
- Domain substitution is limited to the files upstream documents (`traefik-*.yaml`, `headscale-config.yaml`,
  `headplane-config.yaml`, and bookmark HTML). It is idempotent, and a domain or IP change rewrites the old
  value to the new one.

### Fixed (defects in pre-1.0)
- `restart.sh` patch targeted `FOLDER_FOR_YAML=` but upstream uses `FOLDER_FOR_YAMLS=`, so restart.sh still
  `cd`'d to `/docker` and failed.
- Generated `stop.sh` referenced `docker-compose.yml`; the file is `docker-compose.yaml`.
- DB auto-detection looked for `postgres:`; the service is `postgresql:`.
- The DB wait loop ran before the stack was started and had no timeout. A match would have hung forever.
- The `status` subcommand aborted under `set -e` and never set `FOLDER_FOR_YAML`.
- `POSTGRESQL_PASSWORD` and `AUTHENTIK_SECRET_KEY` were regenerated on every run, breaking an initialised
  database and invalidating sessions. They also silently overwrote values typed at the prompt.
- VPN username/password were hard-coded in the script.
- `JWT_SECRET` was generated and appended to `.env` but nothing uses it, so it has been removed.
- `HOST_IP` was detected but never used. `LOCAL_DOCKER_IP` stayed at `192.168.56.2`.
- `normalize_env_comments` corrupted any value containing `" #"`.
- Blanket "prefix `sudo` to every grep/sed" rewriting of upstream scripts has been removed.
- `wget`/`unzip` of `master.zip` into `~` collided on re-runs (`master.zip.1`, overwrite prompts) and
  tracked an unpinned branch.
- Whisparr removal used `sed '/whisparr:/,$d'`, which deleted everything to the end of the file.
- `uninstall` and `clean` wiped all of Docker on the host without confirmation, and `rm -rf` had no path guard.
- The Readarr image re-pin was a no-op (upstream already pins `0.4.18-develop`) and has been dropped.
- A reboot is no longer required. The installer runs Docker as root via sudo and only adds your admin user to
  the `docker` group if asked.
- Upstream helper scripts echo `POSTGRESQL_PASSWORD` to the terminal. The native helpers never print secrets.

## pre-1.0 — unversioned
- Original `mediastack-installer.sh`: interactive prompts, Docker CE install, `docker` user, download of
  `master.zip`, `.env` edits, compose patches, `restart.sh` patching, `status` / `uninstall` / `clean`.
