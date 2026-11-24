# mediastack-installer

A menu-driven installer and lifecycle manager for [MediaStack](https://github.com/geekau/mediastack), the Docker
Compose stack built around Gluetun VPN, the *ARR apps, Plex/Jellyfin, Authentik, Traefik, Guacamole and Headscale.
It also adds optional services that upstream doesn't ship, such as [Audiobookshelf](https://www.audiobookshelf.org/).

It **detects** sensible defaults and asks for the rest. From there it:

- installs Docker and creates a dedicated service account
- lets you pick a **service preset** (Core, Full or Custom) and choose **LAN-only or Internet-facing** access
- serves HTTPS with a **Let's Encrypt, self-signed or your own (manual)** certificate, or one **pulled from** or
  **pushed by** another machine (e.g. OPNsense acme.sh)
- mounts your media (and optionally app data) from **local disk, SMB/CIFS (Windows/NTFS, Samba, NAS) or NFS**
- deploys a **pinned** upstream release and keeps secrets **encrypted at rest**
- brings the stack up and runs the post-install database steps

After installation it handles day-2 operations:

- settings (menu or `--set`), apply/update, restart and stop
- status and logs
- secrets, including re-keying the vault
- backup/restore (host-bound or portable)
- uninstall

> Version: see `SCRIPT_VERSION` in the script. History: [CHANGELOG.md](CHANGELOG.md).
> This is an independent helper, not part of the upstream MediaStack project.

---

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What it detects](#what-it-detects)
- [Menu and CLI](#menu-and-cli)
- [Settings reference](#settings-reference)
- [Access mode and certificates](#access-mode-and-certificates)
- [VPN (Gluetun)](#vpn-gluetun)
- [Service presets](#service-presets)
- [Storage: local, SMB, NFS, external](#storage-local-smb-nfs-external)
- [Services: on / disabled / removed](#services-on--disabled--removed)
- [Add-ons and patched services](#add-ons-and-patched-services)
- [Secrets](#secrets)
- [Backup and restore](#backup-and-restore)
- [Service account](#service-account)
- [Upstream pinning and upgrades](#upstream-pinning-and-upgrades)
- [Upgrading from v1.x](#upgrading-from-v1x)
- [Post-install helpers](#post-install-helpers)
- [Uninstall](#uninstall)
- [Files and paths](#files-and-paths)
- [Notes and limitations](#notes-and-limitations)
- [Testing](#testing)

---

## Requirements

| | |
|---|---|
| OS | Ubuntu or Debian (amd64 / arm64) with systemd |
| Access | root. The script re-runs itself through `sudo` |
| Docker | Installed from Docker's apt repository when missing. Compose **v2.24.4+** is required (for the `!override` tag) |
| Network | `download.docker.com`, `github.com`, and the image registries (ghcr.io, lscr.io, docker.io) |
| Disk | ≥ 20 GiB free for images and app data, plus your media |
| Optional | TPM2 + systemd ≥ 250 for hardware-bound secret encryption |
| For shares | `cifs-utils` (SMB) or `nfs-common` (NFS), installed automatically when needed |

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/netgeek1/scripts/main/mediastack/mediastack-installer.sh
chmod +x mediastack-installer.sh
sudo ./mediastack-installer.sh          # menu -> 1) Full install
```

The first run detects what it can, then walks through each settings section:

1. paths
2. access mode and certificate
3. domain/network
4. media storage and app-data storage
5. service account
6. service preset, player and Tailscale control server
7. VPN/email
8. upstream, secrets and backups

Each prompt shows the detected or current value, so you can press Enter to accept it. The installer then asks only
for the secrets your selection actually uses. For example, there is no Cloudflare token prompt unless Traefik runs
with Let's Encrypt. You can skip any of them and set them later in the **Secrets** menu.

Afterwards the installer is also available as `sudo mediastack-installer`.

Unattended runs (e.g. from config management) work too:

```bash
sudo ./mediastack-installer.sh --install --yes      # uses /etc/mediastack/mediastack.conf + detection
```

---

## What it detects

| Setting | Source |
|---|---|
| Existing install | Running `mediastack` containers (their compose working dir), then `/docker`, `/mediastack/compose`, `/mediastack/appdata`, `/mediastack`, `/opt/mediastack`, `/srv/mediastack` |
| Paths, timezone, VPN provider/type/regions, Cloudflare, SMTP | The existing install's `.env`. Upstream placeholder values are ignored |
| Domain | `CLOUDFLARE_DNS_ZONE` from an existing `.env`, else the host's DNS domain (`hostname -d`) |
| Service account | The existing `PUID` mapped to its user name. The legacy `docker` user is not reused |
| Host IP / LAN subnet | The default-route interface (`auto`, re-detected on every apply) |
| Timezone | `timedatectl` / `/etc/localtime` |
| Storage | A path that is already a mountpoint (not managed by the installer) is proposed as `external` |
| Secrets | Real values in an existing `.env` are imported into the vault, including `POSTGRESQL_PASSWORD`, so existing databases keep working |

You can re-run detection any time with **Settings → D**.

---

## Menu and CLI

```
 Setup        1) Full install / reconfigure   2) Settings   3) Secrets
 Operate      4) Apply + pull updates          5) Apply without pulling
              6) Stop stack                    R) Restart containers
              7) Status                        8) Post-install helpers   9) Logs
              K) Certificate (refresh, show, fetch key, push receiver)
 Maintenance  B) Backup / restore   C) Show settings   U) Uninstall...
              T) Toggle dry-run     S) Self-test       0) Quit
```

**Settings** edits one section at a time. Each line shows the current value:

```
   1) Paths              media=/mediastack/media data=/mediastack/appdata
   2) Access / certs     internet, certificate=letsencrypt
   3) Domain / network   media.example.org  ip=auto subnet=auto
   4) Media storage      smb //fileserver/Media
   5) App-data storage   local
   6) Service account    mediastack
   7) Services           preset=core player=jellyfin tailscale=tailscale
   8) VPN / email        openvpn / mullvad
   9) Upstream / secrets / backups  8e908ae60bf4 full-download-vpn mode=vault
   D) Re-run detection   T) Test share mount   V) View all
   W) Save   A) Save + apply   0) Back
```

| CLI flag | Action |
|---|---|
| `--install` | Full install / reconfigure |
| `--settings` | Settings menu |
| `--apply` / `--start` | Converge and start, with / without pulling images |
| `--stop` | `docker compose down` (data kept) |
| `--restart` | Restart the containers (no converge) |
| `--status` | Configuration, access/certificate and expiry, storage mounts, dependency problems, containers, PostgreSQL readiness |
| `--logs [N] [SERVICE]` | Last N container log lines (default 100), all services or one |
| `--show-config` | Print every setting with its meaning |
| `--set KEY VALUE` | Change one setting, validated. Presets are re-applied when needed. Follow with `--apply` |
| `--backup [--portable]` | Back up settings, vault, compose folder and app data (see [Backup and restore](#backup-and-restore)) |
| `--restore FILE` | Restore a backup (keyword `RESTORE`) |
| `--passphrase-file FILE` | Portable-backup passphrase (first line). `MS_BACKUP_PASSPHRASE` also works |
| `--rekey` | Re-encrypt the vault with the configured `SECRETS_BACKEND` |
| `--cert-refresh` | Fetch or re-read the certificate, install it, reload Traefik if it changed (used by the timer/watcher) |
| `--cert-show` | The deployed certificate, its source, and what Traefik actually serves |
| `--cert-fetch-key` | Create / show the SSH key used to pull the certificate (`fetch` mode) |
| `--cert-push-setup [FILE\|-]` | Set up the push receiver: user, forced-command key, sudoers rule. Public key from a file, stdin or a prompt |
| `--cert-receive` | The push receiver itself (run by the forced SSH command; reads chain + key on stdin) |
| `--test-storage MEDIA\|DATA` | Trial-mount the share; test write and hardlinks as the service account |
| `--helper NAME` | `authentik-db`, `guacamole`, `akadmin`, `apikeys` or `vpn-servers` |
| `--secrets` | Secrets menu |
| `--uninstall` | Remove stack, compose and app-data folders, and managed mounts (keyword `UNINSTALL`) |
| `--purge-docker` | Remove Docker Engine host-wide (keyword `PURGE-DOCKER`) |
| `--compose ARGS…` | `docker compose` for the project with secrets injected, e.g. `--compose logs -f gluetun` |
| `--self-test` | Built-in tests (no root needed) |
| `--dry-run` / `--yes` / `--ref REF` / `--confirm KEYWORD` | Modifiers |

The compose folder also gets wrappers, so the upstream workflow keeps working:
`./restart.sh` (apply), `./stop.sh`, `./create_guacamole_database.sh`, `./secure_authentik_database.sh`,
`./get-apikeys.sh`.

---

## Settings reference

Settings are stored in `/etc/mediastack/mediastack.conf` (0600, non-secret values only). Edit them from the menu,
or by hand followed by **Apply**.

| Key | Default | Notes |
|---|---|---|
| `FOLDER_FOR_MEDIA` | `/mediastack/media` | Library + downloads. This is the share mountpoint when remote |
| `FOLDER_FOR_DATA` | `/mediastack/appdata` | App configs + databases |
| `FOLDER_FOR_YAML` | `/mediastack/compose` | Compose file, `.env`, templates (always local) |
| `ACCESS_MODE` | asked | `internet` or `lan` (see [Access mode](#access-mode-and-certificates)) |
| `CERT_MODE` | `letsencrypt` (internet) / `selfsigned` (lan) | `letsencrypt`, `selfsigned`, `manual`, `fetch` or `push` |
| `CERT_FETCH_SOURCE` / `CERT_FETCH_CERT` / `CERT_FETCH_KEY` | blank / `fullchain.pem` / `privkey.pem` | `fetch` mode: `user@host:/folder` and the two file names in it |
| `CERT_PUSH_USER` / `CERT_PUSH_FROM` | `mscertpush` / blank | `push` mode: the local user the pushing machine logs in as, and the IPs/CIDRs it may push from (blank = any) |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | blank | Manual mode: PEM full chain + key (encrypted is fine), or the pasted copies in `/etc/mediastack/tls/`; re-read on every apply |
| `DOMAIN` | *detected / required* (`mediastack.lan` in LAN mode) | `auth.<domain>`, `sonarr.<domain>`, … |
| `CLOUDFLARE_DNS_ZONE` / `CLOUDFLARE_EMAIL` | `= DOMAIN` / blank | Traefik DNS-01 (Let's Encrypt only) |
| `LOCAL_DOCKER_IP` / `LOCAL_SUBNET` | `auto` | Or a fixed IPv4 / CIDR |
| `TIMEZONE` | detected | |
| `MEDIA_STORAGE` | `local` | `local`, `smb`, `nfs` or `external` |
| `MEDIA_REMOTE` | | `//server/share` or `server:/export` |
| `MEDIA_SMB_DOMAIN` / `MEDIA_SMB_VERSION` | blank / `auto` | `auto` lets the kernel negotiate; or `3.1.1`, `3.0`, `2.1`, … |
| `MEDIA_NFS_VERSION` | `auto` | Or `4.2`, `4.1`, `4`, `3` |
| `MEDIA_MOUNT_OPTS` | blank | Extra comma-separated mount options |
| `MEDIA_MOUNT_REQUIRED` | `yes` | Docker waits for the mount at boot |
| `DATA_STORAGE` | `local` | `local`, `nfs` or `external` (SMB not supported for app data; see below) |
| `DATA_REMOTE` / `DATA_NFS_VERSION` / `DATA_MOUNT_OPTS` / `DATA_MOUNT_REQUIRED` | | As above |
| `SERVICE_USER` / `SERVICE_UID` / `SERVICE_GID` | `mediastack` / auto / auto | Becomes `PUID`/`PGID` |
| `ADMIN_DOCKER_GROUP` | `no` | `yes` adds your sudo user to `docker` (root-equivalent) |
| `SERVICE_PRESET` | `core` | `core`, `full` or `custom` (see [Service presets](#service-presets)) |
| `PLAYER` | `jellyfin` | `jellyfin`, `plex` or `both` (Core preset) |
| `TAILSCALE_CONTROL` | `tailscale` | `tailscale` (official service) or `headscale` (self-hosted, upstream's setup) |
| `DISABLED_SERVICES` | from preset | Never started; folders kept. Editing it switches the preset to `custom` |
| `REMOVED_SERVICES` | `readarr` | Never started; no app-data folder (also applies to add-ons) |
| `VPN_TYPE` / `VPN_SERVICE_PROVIDER` | `openvpn` / *required* | Gluetun provider name (see [VPN](#vpn-gluetun)) |
| `SERVER_COUNTRIES` / `SERVER_CITIES` / `SERVER_HOSTNAMES` / `SERVER_REGIONS` | blank | Gluetun server filters, comma-separated |
| `VPN_SERVERS_UPDATE_PERIOD` | `480h` | How often Gluetun refreshes its server list (`off` = never) |
| `VPN_UPDATER_PROTON_EMAIL` | blank | ProtonVPN: account email for server-list updates (password in the vault) |
| `VPN_CUSTOM_OVPN_FILE` | blank | `custom` + OpenVPN: your `.ovpn` (path or pasted copy in `/etc/mediastack/vpn/`) |
| `WIREGUARD_ADDRESSES` | blank | WireGuard address(es), imported from a `wg0.conf` |
| `VPN_ENDPOINT_IP` / `VPN_ENDPOINT_PORT` / `WIREGUARD_PUBLIC_KEY` | blank | `custom` + WireGuard only (blanked for listed providers) |
| `EMAIL_SERVER_HOST` / `_PORT` / `EMAIL_ADDRESS` / `EMAIL_SENDER` | blank / `587` | Authentik email |
| `UPSTREAM_REPO` / `UPSTREAM_REF` / `UPSTREAM_VARIANT` | `geekau/mediastack` / pinned SHA / `full-download-vpn` | |
| `SECRETS_MODE` / `SECRETS_BACKEND` | `vault` / `auto` | See [Secrets](#secrets) |
| `CHOWN_MEDIA_RECURSIVE` | `no` | Re-own the whole library on every apply |
| `EXTRA_PACKAGES` | blank | apt packages to add |
| `BACKUP_DIR` / `BACKUP_KEEP` | `/var/backups/mediastack` / `5` | Where backups go, and how many are kept |
| `BACKUP_FORMAT` | `host` | `host` or `portable` (default for `--backup`) |
| `BACKUP_PASSPHRASE_FILE` | blank | File whose first line is the portable-backup passphrase (for scheduled backups) |
| `BACKUP_STOP_STACK` | `yes` | Stop containers while archiving so databases are consistent |

`--show-config` prints every key with its current value and meaning. `--set KEY VALUE` changes one key with the same
validation the menu uses.

Other `.env` values (ports, Docker subnet, Authentik version, …) are upstream's. Edit `.env` directly. The installer
rewrites only the keys it manages, and it appends keys that newer upstream releases introduce.

---

## Access mode and certificates

| | `internet` | `lan` |
|---|---|---|
| Reached as | `https://<app>.<domain>` through Traefik, plus each app's own port | `http://<host-ip>:<port>` for each app |
| Core preset adds | Traefik, Authentik + worker, CrowdSec, PostgreSQL, Valkey, traefik-certs-dumper | none of these (enable any of them in Custom) |
| Needs | DNS for `*.<domain>` pointing at you, port 443 forwarded | nothing outside your LAN |
| Default certificate | `letsencrypt` | `selfsigned` |

The certificate source applies whenever Traefik runs, in either mode:

- **`letsencrypt`** is upstream's behaviour: a wildcard for `<domain>` and `*.<domain>` via Cloudflare DNS-01. It
  needs `CLOUDFLARE_DNS_API_TOKEN`. DNS-01 also works for a LAN-only host if the domain is on Cloudflare.
- **`selfsigned`**: the installer creates a local CA in `/etc/mediastack/tls/` (EC P-384, 10 years) and issues a
  leaf for `<domain>`, `*.<domain>` and the host IP (EC P-256, 397 days).
  - The leaf is renewed automatically 30 days before expiry, or when the domain or IP changes.
  - **Import `ca.crt` once on each device** and every app hostname is trusted.
  - Point `*.<domain>` at the host in your local DNS (for example Pi-hole or your router).
- **`manual`**: your own certificate chain (server certificate + intermediates, **in any order**) and private key.
  For each one, the wizard (Settings → Access/certs) asks for a **file path**, or you can type **`paste`** and paste
  the PEM text.
  - The chain is listed as `subject <- issued by`, with a warning when only the server certificate is present.
  - The leaf is found by its key and installed first, followed by its issuers.
  - **Paths** suit files a renewal job such as acme.sh keeps replacing: every apply re-reads them.
  - **Pasted** PEMs are stored in `/etc/mediastack/tls/manual-cert.pem` (0644) and `manual-key.pem` (0600). The
    chain paste reads every certificate, including blank lines between them. It ends 3 seconds after the paste,
    at a line `END`, or at Ctrl-D. The key paste is hidden and ends at its `-----END … PRIVATE KEY-----` line.
    Windows line endings are fine.
  - **Encrypted keys** (PKCS#8 `ENCRYPTED PRIVATE KEY`, or traditional `Proc-Type: 4,ENCRYPTED`) are detected and
    the wizard asks for the passphrase. It verifies the passphrase (3 tries) and stores it in the vault as
    `TLS_KEY_PASSPHRASE`. Traefik cannot read an encrypted key, so every apply decrypts it into Traefik's copy
    (`traefik/certs/key.pem`, root-only 0600). A renewal job can keep writing encrypted keys with the same passphrase
    without any prompt. If the passphrase changes, set it again in Settings → Access/certs or the Secrets menu.
  - Each apply checks that the key matches, the certificate hasn't expired (warns inside 14 days) and it covers
    `*.<domain>`, then installs it.
  - When the certificate comes from **file paths**, a systemd path unit (`mediastack-cert.path`) watches the two
    files. When a renewal job replaces them, it installs them and reloads Traefik. No Apply is needed.
- **`fetch`** (pull): the pair is copied over scp from another machine (for example the OPNsense acme.sh folder).
  This happens on every apply and daily via `mediastack-cert.timer` (around 05:23, randomised by up to 30 minutes).
  Details below.
- **`push`**: another machine pushes the pair over SSH when it renews, for example the OPNsense
  `install_wildcard_cert_api.sh` deployer. The new certificate is live within seconds, and the pusher gets a
  pass/fail answer. Details below.

All file-based modes (`manual`, `fetch`, `push`) go through the same checks before anything is replaced: the
chain is ordered leaf first, the key must match, and the certificate must not be expired. After installing,
the installer makes sure Traefik **really serves** the new certificate. It first lets Traefik reload on its own,
and restarts the `traefik` container only if it still serves the old one.

### Pull mode (`fetch`)

1. Settings → Access / certs, or Certificate menu (**K**) → 5: choose `fetch` and set the source, e.g.
   `certsync@192.168.1.1:/var/etc/acme-client/certs/<id>`, plus the two file names (`fullchain.pem`, `privkey.pem`).
2. Let it create the fetch key (`/etc/mediastack/certfetch_ed25519`), or run `--cert-fetch-key`. Then add the
   printed public key to that account on the source (OPNsense: System → Access → Users → Authorized keys).
3. Apply. Use **K → 1** or `--cert-refresh` to fetch right away.

If a fetch fails, Traefik keeps serving the last good certificate, and the timer run exits non-zero so the failure
shows in the journal (`journalctl -u mediastack-cert`). Until the first successful fetch, Traefik serves a
temporary self-signed certificate. The key must be unencrypted (use `manual` for encrypted keys).

### Push mode (`push`)

1. On the pushing machine, create a key pair. On OPNsense:
   `ssh-keygen -t ed25519 -N '' -f /root/ssl_certs/mediastack_push_ed25519`
2. Here, choose `push` (Settings → Access / certs, or **K** → 5) and let it set up the receiver. You can also use
   **K → 4**, or run `sudo mediastack-installer --cert-push-setup /path/to/mediastack_push_ed25519.pub`. This
   creates:
   - a system user, `mscertpush` by default (`CERT_PUSH_USER`), with no password and no shell access
   - its `authorized_keys` line, which pins the key to one command:
     `restrict,from="<CERT_PUSH_FROM>",command="sudo -n /usr/local/sbin/mediastack-installer --cert-receive"`
   - `/etc/sudoers.d/mediastack-certpush`, which allows that user that one command and nothing else (checked with
     `visudo`)
3. Set `CERT_PUSH_FROM` to the pushing machine's IP so the key works only from there.
4. Push: `cat fullchain.pem privkey.pem | ssh -i mediastack_push_ed25519 mscertpush@<this host>`

The receiver works like docker-dashboard's, with the same status line, so the same deployer can push to both:

- **Input:** the certificate chain (any order) followed by exactly one **unencrypted** private key, on stdin. At
  most 64 KB, read within 30 seconds. scp, sftp, shells and remote commands don't work for this user. A remote
  command is ignored.
- **Lock:** if a menu or apply run holds the lock, the push waits up to 5 minutes.
- **Output:** the last stdout line is machine-readable; diagnostics go to stderr. Exit code 0 means OK.
  ```
  DD-CERT-RECEIVE OK changed|unchanged sha256=<fingerprint> notafter=<date> live=yes|no|n/a
  DD-CERT-RECEIVE FAIL <reason>
  ```
  The `sha256=` value is the leaf's fingerprint, in the format `openssl x509 -fingerprint -sha256` prints after the
  `=`.
- **TLS checks from the pushing side need a hostname.** Traefik uses strict SNI, so a probe of `https://<IP>`
  (SNI = IP) gets no certificate. Probe `<anything>.<domain>` instead.

Until the first push, Traefik serves a temporary self-signed certificate. The pushed pair is kept in
`/etc/mediastack/certs-pushed/`. Uninstall removes the push user, its sudoers rule and the certificate units.

In `selfsigned`, `manual`, `fetch` and `push` modes the installer rewires Traefik's config:

- It removes the ACME resolver and points the TLS store, which upstream keeps `sniStrict`, at
  `/etc/traefik/certs/cert.pem`.
- It parks `traefik-certs-dumper` automatically. That container only reads Let's Encrypt's `acme.json`, and it shows
  as `auto-off` in the services list.

---

## VPN (Gluetun)

In the Core and Full presets, the download apps run **behind Gluetun**. If Gluetun cannot connect it stays
unhealthy, and Docker skips every app that waits for it. The installer therefore checks the VPN settings before
starting anything:

- **Provider:** `VPN_SERVICE_PROVIDER` must be one of Gluetun's names, which the wizard lists (for example
  `mullvad`, `nordvpn`, `protonvpn`, `private internet access`, `surfshark`). There is no default.
- **OpenVPN with a listed provider:** set `VPN_USERNAME` and `VPN_PASSWORD`. Most providers issue separate
  OpenVPN/service credentials (for example NordVPN "service credentials"), not your account login.
- **OpenVPN with `custom`:** give your `.ovpn` as a path or by pasting it. It is stored in `/etc/mediastack/vpn/`,
  copied to Gluetun as `/gluetun/custom.ovpn`, and `OPENVPN_CUSTOM_CONFIG` is set for you. Credentials are asked
  for only if the file uses `auth-user-pass`.
- **WireGuard:** give your provider's `wg0.conf` as a path or by pasting it.
  - The private key goes into the vault, and `Address` goes into `WIREGUARD_ADDRESSES`. A `PresharedKey` is
    optional: it is stored only if your file has one, and you are never asked for it.
  - Docker gives Gluetun no IPv6 by default, so an IPv6 entry in `Address` (newer ProtonVPN configs have one) is
    left out of what Gluetun gets.
  - For `custom`, the server's `Endpoint` (resolved to an IP) and `PublicKey` are also taken.
  - For **listed providers** (ProtonVPN, Mullvad, …) the `Endpoint` and `PublicKey` are **not** used. Gluetun
    picks a server from its own list, and the provider's key works with any of its servers. A fixed
    `VPN_ENDPOINT_IP`/`_PORT` makes Gluetun look for exactly that server in its list ("target IP address not
    found"), so Apply blanks these for every provider except `custom`, including values left from an earlier
    setup.
- **Host:** `/dev/net/tun` must exist.

If something is missing, Apply stops and says what. Interactively you can choose to start anyway. If containers
still fail to start, for example because the VPN rejected the login, the installer:

- lists the containers that are not running
- shows Gluetun's last error lines
- names the likely cause: wrong credentials, a fixed endpoint, a server filter matching nothing, an unknown
  provider, a custom config problem, a rejected WireGuard key or address, a missing TUN device, an unreachable
  server, or a tunnel that is up but passes no traffic (key not accepted, or an outdated server list)

Only Gluetun's own `ERROR`/`WARN` lines are used for this, and each line is judged on its own. Normal WireGuard log lines no longer produce a "WireGuard
settings problem" hint.

Read the full log with `--logs 200 gluetun`. To run without a VPN, pick the `no-download-vpn` variant.

### Server filters

`SERVER_COUNTRIES`, `SERVER_CITIES`, `SERVER_HOSTNAMES` and `SERVER_REGIONS` are optional, comma-separated, and set
in the wizard. Blank means any server of the provider. Some providers have no regions in Gluetun (ProtonVPN, for
example), and any value then stops Gluetun with "the region specified is not valid": use countries instead.
Values that are clearly not names are rejected, for example a line from a pasted `wg0.conf`. Filters set by hand in
`.env` before v2.5.0 are taken over into the config.

### Server list updates

Gluetun picks servers from a list built into its image, which goes out of date. It can then find no server or
connect to one that no longer accepts your key. Two ways to keep the list fresh
([Gluetun wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/servers.md)):

- **Automatic** (`VPN_SERVERS_UPDATE_PERIOD`, default `480h` = 20 days; the wiki asks for at least `360h`; `off` to
  disable). Gluetun refreshes the list for your provider through the tunnel and keeps it in `<data>/gluetun/`. It
  is set as `UPDATER_PERIOD` in the managed override.
- **Now:** Post-install helpers → 5 or `--helper vpn-servers`. This runs Gluetun's updater once and restarts Gluetun.
  It is the fix when the list is so old that no tunnel comes up. It runs **outside** the VPN, so your public IP is
  visible to the provider's API and the DNS-over-HTTPS resolver.

**ProtonVPN** only serves its server list to a logged-in account. The wizard asks for the Proton account email
(`VPN_UPDATER_PROTON_EMAIL`) and password (vault: `UPDATER_PROTONVPN_PASSWORD`), and a free account is enough for
the free servers. Without them, automatic updates are off for ProtonVPN and "update now" asks for them. The
credentials reach the updater as environment variables. They are never on this host's `docker` command line, but
inside the one-off update container Gluetun's updater takes them as arguments for the few seconds it runs.

---

## Service presets

| Preset | Services on |
|---|---|
| **core** (default) | Gluetun, qBittorrent, SABnzbd, Prowlarr, FlareSolverr, Unpackerr, Sonarr, Radarr, Lidarr, Bazarr, Seerr, Homepage, **Tailscale**, Audiobookshelf + your **player** (Jellyfin, Plex or both). In `internet` mode, also Traefik, Authentik, CrowdSec, PostgreSQL, Valkey and traefik-certs-dumper. With `TAILSCALE_CONTROL=headscale`, also Headscale and Headplane |
| **full** | Every upstream service except Whisparr (disabled), plus add-ons |
| **custom** | Whatever you choose in the numbered list (a new install starts from Core) |

Readarr is always removed: the project was retired upstream. Everything that is off stays one keypress away in
**Settings → Services**.

Before anything starts, the installer checks the dependencies of every enabled service:

- upstream's `depends_on` and `network_mode: service:…` links
- Traefik's need for CrowdSec and Authentik (its middlewares)
- Tailscale's need for Headscale when it is the control server

If something is missing it names the pair (for example `qbittorrent needs gluetun`) instead of letting Compose fail
later.

**Tailscale control server.** Upstream's Tailscale container logs in to *your own* Headscale at
`https://headscale.<domain>`, which needs Traefik and a public domain.

- **`TAILSCALE_CONTROL=tailscale`** (default for new installs) uses the official service instead, so it also works
  LAN-only.
  - Create a reusable auth key in the Tailscale admin console.
  - Approve the advertised subnet routes and exit node there.
- **`headscale`** keeps upstream's setup and enables Headscale and Headplane. Create the key with
  `docker exec headscale headscale preauthkeys create --user <user> --reusable` once Headscale runs.

---

## Storage: local, SMB, NFS, external

Upstream MediaStack documents `FOLDER_FOR_MEDIA` and `FOLDER_FOR_DATA` on "Linux, Windows, macOS, Synology or NFS"
filesystems. The installer supports these storage types:

| Type | Use for | Media | App data |
|---|---|:-:|:-:|
| `local` | Disks on this host | ✓ | ✓ (recommended) |
| `smb` | SMB/CIFS: Windows file servers (NTFS), Samba, macOS sharing, Synology / TrueNAS / QNAP SMB | ✓ | — |
| `nfs` | NFS v3/v4.x: Linux, TrueNAS, Synology, QNAP, Unraid | ✓ | ✓ |
| `external` | A mount you manage yourself (fstab, autofs, systemd units). The installer only checks it is mounted | ✓ | ✓ |

### How managed shares work (`smb` / `nfs`)

On every apply the installer:

1. Installs `cifs-utils` or `nfs-common` if missing.
2. Writes **one fstab entry** tagged `# mediastack-installer:MEDIA` (or `:DATA`), with `_netdev,nofail` so the share
   mounts at boot and a missing share never blocks boot. A backup of the original is kept in
   `/etc/fstab.mediastack.bak`.
3. For SMB, writes a credentials file `/etc/mediastack/media.smbcred` (0600 root) from the encrypted vault. The
   kernel's `mount.cifs` can only read credentials from a plaintext file, so this file must exist.
4. Mounts SMB shares with `uid/gid` = the service account and `0775` modes, so every container sees files it owns.
   With NFS, ownership comes from the server.
5. Adds a systemd drop-in, `docker.service.d/mediastack-mounts.conf`, with `RequiresMountsFor=`. Docker therefore
   starts only after the share is mounted. Set `*_MOUNT_REQUIRED=no` to disable this.
6. Marks the **empty local mountpoint immutable** (`chattr +i`). If the share ever fails to mount, downloads cannot
   silently fill your local disk.
7. Verifies the mount and **tests a write as the service account** before starting anything.

Changing the share, its options, or its type remounts it, stopping the stack first if needed. Switching back to
`local` unmounts the share and removes the fstab entry and credentials.

**Safety:** if the local folder already contains files, the installer refuses to mount over them (they would be
hidden) and prints the exact `rsync` steps to move them onto the share first. A folder that holds only the
installer's own empty skeleton is cleaned up automatically.

### Windows / NTFS shares

- Use `smb` with `//server/share`. You can also type `\\server\share`; it is converted.
- Give the account **Modify** rights in both the share permissions and the NTFS ACLs.
- `MEDIA_SMB_VERSION=auto` works with Windows 8/Server 2012 and later. Pin `3.1.1` if you want to enforce it.
- **Hardlinks work on NTFS over SMB.** Keep downloads (`torrents/`, `usenet/`) and the library (`media/`) on the
  same share, as the default layout does, so the *ARR apps can hardlink instead of copying.
- Run **Settings → T) Test** first. It mounts the share temporarily and reports whether the service account can
  write and hardlink there.

### NFS shares

- Use `server:/export/path`. IPv6 is also accepted as `[fd00::5]:/export`.
- With `root_squash` (the usual default), root on this host cannot chown. The export must let the service account's
  UID/GID write, either through matching ownership on the server or a fixed `SERVICE_UID`/`SERVICE_GID` set before
  the first install. The installer falls back to creating folders as the service account when root is refused.

### Why app data can't be on SMB

PostgreSQL requires its data directory to be `0700`/`0750` and owned by its user. Traefik refuses an `acme.json`
looser than `0600`. CIFS fakes ownership and modes for the whole mount, so both fail, and SQLite locking over SMB
is unreliable. NFS works. Local disk is best.

---

## Services: on / disabled / removed

**Settings → 7** (Custom preset) lists every service in the selected compose variant. You cycle a service through three states by
entering its number:

| State | Effect |
|---|---|
| `on` | Runs normally |
| `disabled` | Never started (Compose `disabled` profile); its folders are still created |
| `removed` | Never started; no app-data folder is created; skipped by the API-key helper |

Defaults:

- **Readarr is `removed`.** The project was retired upstream.
- **Whisparr is `disabled`.**

The upstream compose file is never edited. Exclusions live in a managed `docker-compose.override.yaml`. If you
already keep your own override file, the installer leaves it alone and tells you exclusions are not applied.

Add-ons are marked `+` in the list and use the same three states.

The dependency check warns as you toggle, and **refuses to apply** while an enabled service needs a disabled one.
Unpackerr and some dashboards still reference removed apps and will log harmless connection errors.

---

## Add-ons and patched services

Everything the installer adds or changes lives in the managed `docker-compose.override.yaml`. The upstream compose
file stays untouched.

### Homarr 1.x (homarr-labs)

Upstream still ships the legacy `ghcr.io/ajnart/homarr` (0.x) image. The installer replaces it with
**`ghcr.io/homarr-labs/homarr:latest`**:

- **Image and port:** the homarr-labs image, on the same `WEBUI_PORT_HOMARR` → 7575.
- **Mounts:** only `/appdata` (`<FOLDER_FOR_DATA>/homarr/appdata`) and a **read-only** Docker socket. `volumes: !override`
  drops the old 0.x mounts.
- **Encryption key:** a `SECRET_ENCRYPTION_KEY` (64 hex characters) is generated once into the vault and injected at
  runtime.
- **Not migrated:** existing 0.x boards in `homarr/configs` are left untouched. Recreate them in 1.x, or follow
  Homarr's migration guide.

Homarr is off in the Core preset and on in Full.

### Tailscale

With `TAILSCALE_CONTROL=tailscale`, only `TS_EXTRA_ARGS` is overridden: the same exit node and routes, without
`--login-server`.

### Audiobookshelf (add-on)

**Audiobookshelf** is on in Core and Full:

| | |
|---|---|
| Image | `ghcr.io/advplyr/audiobookshelf:latest` (official) |
| Runs as | `user: PUID:PGID`, the service account. ABS does not support PUID/PGID environment variables |
| Web UI | `http://<host>:13378` (`WEBUI_PORT_AUDIOBOOKSHELF` in `.env`, added once and then yours to change) and `https://audiobookshelf.<domain>` via Traefik |
| Network | `mediastack` bridge, not behind Gluetun. It serves media and needs no VPN |
| `/config`, `/metadata` | `<FOLDER_FOR_DATA>/audiobookshelf/{config,metadata}`. `/config` is SQLite and ABS warns against network storage, so the installer warns if app data isn't local |
| `/audiobooks` | `<FOLDER_FOR_MEDIA>/media/audio`, upstream's audiobook folder, so downloads land where ABS reads them |
| `/podcasts` | `<FOLDER_FOR_MEDIA>/media/podcasts` (created) |
| `/books` | `<FOLDER_FOR_MEDIA>/media/books` (ebooks) |

In ABS, create libraries pointing at `/audiobooks`, `/podcasts` and/or `/books`.

The Traefik route deliberately has **no Authentik forward-auth**. ABS has its own login, and its mobile apps call
the API directly, which forward-auth would break. It keeps upstream's security headers and CrowdSec bouncer.

---

## Secrets

Secrets live encrypted in `/etc/mediastack/secrets.enc`. They are never logged and never placed on a command line.

- **Prompted:** VPN credentials, Cloudflare token, Tailscale key, SMTP password, Plex claim, and the WireGuard keys
  when `VPN_TYPE=wireguard`.
- **Collected from Settings:** OpenVPN username/password, WireGuard private/preshared keys (from `wg0.conf`),
  the SMB username and password for the media share, and the passphrase of an encrypted manual TLS key
  (`TLS_KEY_PASSPHRASE`).
- **Generated once and reused:** the PostgreSQL password, Authentik secret key, headplane cookie secret and Homarr's
  `SECRET_ENCRYPTION_KEY`.
- **Asked for only when used:** for example, the Cloudflare token only when Traefik runs with Let's Encrypt, and
  `PLEX_CLAIM` only when Plex is on.
- **Collected by a helper:** *ARR API tokens.

| Backend | When | Protection |
|---|---|---|
| `systemd-creds` | `auto` on systemd ≥ 250 | Bound to TPM2 (if present) and the host key |
| `openssl` | Fallback | AES-256-CBC, PBKDF2 250k rounds, root-only key file |

| Mode | Behaviour |
|---|---|
| `vault` (default) | Secrets stay out of `.env` and are injected into the `docker compose` process at runtime. Plain `docker compose` in the folder fails validation, so use the wrappers or `--compose` |
| `env` | Secrets are written to `.env` (0600 root) for compatibility with plain `docker compose` and the upstream scripts |

> **Back up your secrets.** A TPM-bound vault cannot be read after an OS reinstall. A **portable backup**
> (`--backup --portable`) carries them safely. **Secrets → Export / Import** still works for plaintext key=value
> backups. After changing `SECRETS_BACKEND`, run `--rekey`.

The vault protects secrets at rest and in stray copies. It does not protect against root on a running host, since
`docker inspect` shows container environments.

---

## Backup and restore

| | `host` (default) | `portable` |
|---|---|---|
| Command | `--backup` | `--backup --portable` (or `BACKUP_FORMAT=portable`) |
| File | `mediastack-YYYYMMDD-HHMMSS.tar.gz` (0600) | `mediastack-YYYYMMDD-HHMMSS.msbak` (0600) |
| Contains | `/etc/mediastack` (settings, vault **and its key**, TLS CA, SMB credentials), compose folder, app data | settings, **decrypted** secrets, TLS CA, compose folder and app data, all inside one archive encrypted with your passphrase (AES-256-CBC, PBKDF2-SHA256 × 600,000) |
| Restores on | this host (a `systemd-creds`/TPM vault cannot leave it) | **any** host |

- **Media is never included.** Plex and Jellyfin caches and transcodes are skipped.
- With `BACKUP_STOP_STACK=yes`, containers are stopped while archiving, so PostgreSQL and the SQLite databases are
  consistent. They start again afterwards, even on failure.
- The newest `BACKUP_KEEP` backups are kept.

**Restore** with `--restore FILE` (or **Backup / restore → 4**, keyword `RESTORE`). `FILE` may be a path, a name in
`BACKUP_DIR`, or a file next to the installer. Restore:

1. stops the stack
2. moves the current folders aside as `*.pre-restore-<timestamp>` (mountpoints are restored over in place)
3. extracts the archive
4. re-creates the service account if needed, and applies

A **portable** restore onto a **fresh host** adopts the backup's settings and resets the host-specific ones:

- the UID/GID become auto, `SECRETS_BACKEND` becomes auto, and a foreign fixed IP becomes auto
- the vault is re-encrypted with this host's backend
- Docker is installed if missing

A wrong passphrase or a damaged file is detected before anything changes. Archives that contain `..` paths, or paths
outside the MediaStack folders, are refused.

For scheduled portable backups, use `BACKUP_PASSPHRASE_FILE` (0600) or `--passphrase-file`.

---

## Service account

The default is a dedicated **`mediastack` system account**:

- nologin shell and no home directory
- **not** a member of the `docker` group, which is root-equivalent

LinuxServer/hotio images drop to `PUID`/`PGID` internally, so the containers don't need Docker access. You
administer the stack with `sudo`.

- **Local storage:** the account owns app data (`chown -R`) and the media structure, with setgid `2775` directories.
- **SMB:** ownership comes from the mount options (`uid=`/`gid=`), so any UID works.
- **NFS:** set `SERVICE_UID`/`SERVICE_GID` to match the export's owner before the first install.
- **Migrating from a `docker` user:** app data is re-owned automatically. For local media, you get a one-time offer
  to re-own it.

PostgreSQL's folder is excluded from the `2775` pass. Seerr's folder is owned by UID 1000, as upstream requires.

---

## Upstream pinning and upgrades

- `UPSTREAM_REF` defaults to a tested commit SHA. Each SHA is downloaded once and cached. If the tarball download
  is blocked, the installer falls back to `git clone`.
- **To upgrade,** set a new SHA (Settings → 9, or `--ref <sha>`), then run **Apply + pull**:
  - Upstream working files are refreshed.
  - Previous versions are saved in `<compose>/.backup/<timestamp>/`. Re-apply any hand edits from there.
  - `.env` is preserved, and new upstream keys are appended.
- A branch or tag name works too, but it is re-downloaded on every run and you get a warning.
- If upstream's folder layout changes, you get a warning that the installer needs updating.

## Upgrading from v1.x

Run v2.0.0 once with **Apply** (or `--install`, answering *no* to "review every section"). An existing
`/etc/mediastack/mediastack.conf` keeps its behaviour, because settings it doesn't contain get their old values:

- `ACCESS_MODE=internet` and `CERT_MODE=letsencrypt`
- `SERVICE_PRESET=custom`, so your disabled/removed lists are untouched
- `TAILSCALE_CONTROL=headscale` (upstream's login server) and `PLAYER=both`

**What does change: Homarr moves to homarr-labs (1.x)** if you run it. Its new data lives in `homarr/appdata`, and
0.x boards are not migrated. To keep the legacy image instead, set Homarr to `removed` and run your own override.

Make a backup first: `--backup`.

## Post-install helpers

These are native versions of upstream's scripts. Unlike upstream's versions, they **never print the database
password**.

| Helper | Does |
|---|---|
| Secure Authentik DB | Waits for PostgreSQL and applies upstream's grants |
| Create Guacamole DB | Creates the database, grants access, loads the schema and restarts Guacamole. The default login is `guacadmin`/`guacadmin`, so change it |
| Reset akadmin | Runs `ak changepassword akadmin` once Authentik is healthy |
| *ARR API keys | Reads each app's key and optionally stores the keys in the vault for unpackerr/homepage |
| Update VPN server list | Runs Gluetun's server-list updater once and restarts Gluetun (`--helper vpn-servers`; see [Server list updates](#server-list-updates)) |

## Uninstall

- **Stack only** (`UNINSTALL`):
  - Runs `compose down --volumes --rmi all` for this project only.
  - Deletes the compose and app-data folders. Only their contents are deleted when a folder is a mountpoint.
  - Unmounts the managed shares and removes their fstab entries, credentials and the Docker drop-in.
  - Then asks separately about the media library (`DELETE-MEDIA`; on a share this deletes files **on the share**),
    the service account, and the config/vault.
  - Removes the certificate timer/watcher and, if it was set up, the push user and its sudoers rule.
- **Docker Engine purge** (`PURGE-DOCKER`) is a separate menu item. It lists non-MediaStack containers before
  removing anything.
- `rm -rf` is guarded against `/`, system directories and `/home/<user>`.

## Files and paths

```
/etc/mediastack/mediastack.conf          settings (0600)
/etc/mediastack/secrets.enc              encrypted vault
/etc/mediastack/.secrets.key             openssl backend key (0400)
/etc/mediastack/media.smbcred            SMB credentials for mount.cifs (0600, regenerated from vault)
/etc/mediastack/tls/ca.{crt,key}         local CA for CERT_MODE=selfsigned (import ca.crt on devices)
/etc/mediastack/tls/manual-{cert,key}.pem  pasted manual certificate / key (key 0600, kept as pasted)
/etc/mediastack/vpn/custom.ovpn          custom OpenVPN config (0600; copied to <data>/gluetun/custom.ovpn)
/etc/mediastack/certfetch_ed25519        fetch mode: SSH key used to pull the certificate (+ certfetch_known_hosts)
/etc/mediastack/certs-fetched/           fetch mode: last fetched fullchain.pem / privkey.pem
/etc/mediastack/certs-pushed/            push mode: last pushed fullchain.pem / privkey.pem
/etc/sudoers.d/mediastack-certpush       push mode: allows only 'mediastack-installer --cert-receive'
/etc/systemd/system/mediastack-cert.*    certificate refresh: .timer (fetch, daily) or .path (manual file paths)
<FOLDER_FOR_DATA>/traefik/certs/         certificate Traefik serves in selfsigned/manual/fetch/push mode
/var/backups/mediastack/                 backups (BACKUP_DIR)
/etc/fstab                               '# mediastack-installer:MEDIA|DATA' entries
/etc/systemd/system/docker.service.d/mediastack-mounts.conf
/var/lib/mediastack-installer/           upstream cache, deployed ref/domain/IP state
/var/log/mediastack/installer-*.log      run logs (newest 20 kept). Image pulls and container starts are logged
                                         line by line, without the per-layer byte counters. The console shows a
                                         single updating status line instead, plus any errors.
/var/log/mediastack/cert-*.log           certificate refresh/push runs (own rotation, newest 20 kept)
/usr/local/sbin/mediastack-installer     installed copy
<FOLDER_FOR_YAML>/                       docker-compose.yaml, docker-compose.override.yaml, .env,
                                         templates, wrappers, *.upstream originals, .backup/
```

## Notes and limitations

- The installer does **not** run upstream `restart.sh`. That script stops every container on the host and prunes
  all volumes, networks and images. The installer's apply is scoped to the `mediastack` project.
- A `PLEX_CLAIM` token expires about 4 minutes after you request it, and Plex only uses it on first start.
- Upstream's `.env` defines `WEBUI_PORT_HUNTARR`, but upstream has no Huntarr service. It is harmless.
- Upstream hard-codes the CrowdSec bouncer key (`crowdsecLapiKey`) in `traefik-dynamic.yaml`. If you expose Traefik
  to the Internet, replace it with a key from `docker exec crowdsec cscli bouncers add traefik` and register the same
  key in CrowdSec.

## Testing

```bash
./mediastack-installer.sh --self-test     # 73 checks, no root/Docker/network needed
```

The self-test covers:

- `.env` parsing and editing, and config quoting
- CIDR maths and the delete-path guard
- folder layout drift, override rendering (including add-ons in each state) and the service-state cycle
- SMB/NFS remote validation and normalisation
- fstab line rendering and fstab edit/remove
- config migration (v1.0 names and v1.x → v2 defaults) and an encrypted vault round-trip
- presets for both access modes and both Tailscale control servers, the dependency check, and the Homarr/Tailscale
  patches
- automatic parking of traefik-certs-dumper
- Traefik ACME removal and the file certificate
- the local CA and leaf (SANs, chain, renewal triggers) and the manual cert/key match check
- encrypted keys (PKCS#8 and traditional; with no, a wrong, and the right passphrase) and the paste readers
  (chains, CRLF, the blank line in traditional keys)
- multi-certificate chains pasted with blank lines and reordered leaf → intermediate → root
- `wg0.conf` import (with and without a PresharedKey), VPN settings problems, and Gluetun log diagnosis
- portable-backup encryption and `--set` validation

Development testing ran these scenarios against the real upstream compose file, validated with `docker compose config`:

- LAN Core, Internet Core and Full installs, all with no dependency errors
- the resolved Homarr (`!override`) and Tailscale (env merge) services
- self-signed, manual and Let's Encrypt certificates
- re-apply idempotency and `--set` / `--restart` / `--logs`
- host backup/restore, and portable backup/restore onto a fresh host
- the v1.2.0 → v2.0.0 config upgrade and the interactive wizard
- storage transitions (local ↔ SMB ↔ NFS ↔ external)

Mounts and containers were simulated, so test a real share with **Settings → T** before the first apply.
