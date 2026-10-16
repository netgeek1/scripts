# mediastack-installer

A menu-driven installer and lifecycle manager for [MediaStack](https://github.com/geekau/mediastack), the Docker
Compose stack built around Gluetun VPN, the *ARR apps, Plex/Jellyfin, Authentik, Traefik, Guacamole and Headscale.

It **detects** sensible defaults and asks for the rest. From there it:

- installs Docker and creates a dedicated service account
- mounts your media (and optionally app data) from **local disk, SMB/CIFS (Windows/NTFS, Samba, NAS) or NFS**
- deploys a **pinned** upstream release and keeps secrets **encrypted at rest**
- brings the stack up and runs the post-install database steps

After installation it handles day-2 operations: settings, apply/update, stop, status, secrets, logs and uninstall.

> Version: see `SCRIPT_VERSION` in the script. History: [CHANGELOG.md](CHANGELOG.md).
> This is an independent helper, not part of the upstream MediaStack project.

---

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What it detects](#what-it-detects)
- [Menu and CLI](#menu-and-cli)
- [Settings reference](#settings-reference)
- [Storage: local, SMB, NFS, external](#storage-local-smb-nfs-external)
- [Services: on / disabled / removed](#services-on--disabled--removed)
- [Secrets](#secrets)
- [Service account](#service-account)
- [Upstream pinning and upgrades](#upstream-pinning-and-upgrades)
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
| Network | `download.docker.com`, `github.com`, and the image registries (ghcr.io, lscr.io, docker.io) |
| Disk | ≥ 20 GiB free for images and app data, plus your media |
| Optional | TPM2 + systemd ≥ 250 for hardware-bound secret encryption |
| For shares | `cifs-utils` (SMB) or `nfs-common` (NFS), installed automatically when needed |

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/<you>/<repo>/main/mediastack-installer.sh
chmod +x mediastack-installer.sh
sudo ./mediastack-installer.sh          # menu -> 1) Full install
```

The first run detects what it can, then walks through each settings section: paths, domain/network, media storage,
app-data storage, service account, services, VPN/email, and upstream/secrets. Each prompt shows the detected or
current value, so you can press Enter to accept it. It then asks for secrets (VPN, Cloudflare, Tailscale). You can
skip any of these and set them later in the **Secrets** menu.

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
              6) Stop stack                    7) Status
              8) Post-install helpers          9) Logs
 Maintenance  U) Uninstall...   T) Toggle dry-run   S) Self-test   0) Quit
```

**Settings** edits one section at a time. Each line shows the current value:

```
   1) Paths             media=/mediastack/media data=/mediastack/appdata
   2) Domain / network  media.example.org  ip=auto subnet=auto
   3) Media storage     smb //fileserver/Media
   4) App-data storage  local
   5) Service account   mediastack
   6) Services          disabled: whisparr | removed: readarr
   7) VPN / email       openvpn / mullvad
   8) Upstream/secrets  8e908ae60bf4 full-download-vpn mode=vault
   D) Re-run detection   T) Test share mount   V) View all
   W) Save   A) Save + apply   0) Back
```

| CLI flag | Action |
|---|---|
| `--install` | Full install / reconfigure |
| `--settings` | Settings menu |
| `--apply` / `--start` | Converge and start, with / without pulling images |
| `--stop` | `docker compose down` (data kept) |
| `--status` | Configuration, storage mounts, containers, PostgreSQL readiness |
| `--test-storage MEDIA\|DATA` | Trial-mount the share; test write and hardlinks as the service account |
| `--helper NAME` | `authentik-db`, `guacamole`, `akadmin` or `apikeys` |
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
| `DOMAIN` | *detected / required* | `auth.<domain>`, `headscale.<domain>`, … |
| `CLOUDFLARE_DNS_ZONE` / `CLOUDFLARE_EMAIL` | `= DOMAIN` / blank | Traefik DNS-01 |
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
| `DISABLED_SERVICES` | `whisparr` | Never started; folders kept |
| `REMOVED_SERVICES` | `readarr` | Never started; no app-data folder |
| `VPN_TYPE` / `VPN_SERVICE_PROVIDER` / `SERVER_REGIONS` | `openvpn` / `custom` / blank | Gluetun provider names |
| `EMAIL_SERVER_HOST` / `_PORT` / `EMAIL_ADDRESS` / `EMAIL_SENDER` | blank / `587` | Authentik email |
| `UPSTREAM_REPO` / `UPSTREAM_REF` / `UPSTREAM_VARIANT` | `geekau/mediastack` / pinned SHA / `full-download-vpn` | |
| `SECRETS_MODE` / `SECRETS_BACKEND` | `vault` / `auto` | See [Secrets](#secrets) |
| `CHOWN_MEDIA_RECURSIVE` | `no` | Re-own the whole library on every apply |
| `EXTRA_PACKAGES` | blank | apt packages to add |

Other `.env` values (ports, Docker subnet, Authentik version, …) are upstream's. Edit `.env` directly. The installer
rewrites only the keys it manages, and it appends keys that newer upstream releases introduce.

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

**Settings → 6** lists every service in the selected compose variant. You cycle a service through three states by
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

Disabling core services (gluetun, postgresql, valkey, traefik, authentik) is allowed but warned about. Other
services depend on them. Unpackerr and some dashboards still reference removed apps and will log harmless
connection errors.

---

## Secrets

Secrets live encrypted in `/etc/mediastack/secrets.enc`. They are never logged and never placed on a command line.

- **Prompted:** VPN credentials, Cloudflare token, Tailscale key, SMTP password, Plex claim, and the WireGuard keys
  when `VPN_TYPE=wireguard`.
- **Collected from Settings:** SMB username and password for the media share.
- **Generated once and reused:** the PostgreSQL password, Authentik secret key and headplane cookie secret.
- **Collected by a helper:** *ARR API tokens.

| Backend | When | Protection |
|---|---|---|
| `systemd-creds` | `auto` on systemd ≥ 250 | Bound to TPM2 (if present) and the host key |
| `openssl` | Fallback | AES-256-CBC, PBKDF2 250k rounds, root-only key file |

| Mode | Behaviour |
|---|---|
| `vault` (default) | Secrets stay out of `.env` and are injected into the `docker compose` process at runtime. Plain `docker compose` in the folder fails validation, so use the wrappers or `--compose` |
| `env` | Secrets are written to `.env` (0600 root) for compatibility with plain `docker compose` and the upstream scripts |

> **Back up your secrets** with **Secrets → Export**. A TPM-bound vault cannot be read after an OS reinstall.
> **Secrets → Import** restores them.

The vault protects secrets at rest and in stray copies. It does not protect against root on a running host, since
`docker inspect` shows container environments.

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
- **To upgrade,** set a new SHA (Settings → 8, or `--ref <sha>`), then run **Apply + pull**:
  - Upstream working files are refreshed.
  - Previous versions are saved in `<compose>/.backup/<timestamp>/`. Re-apply any hand edits from there.
  - `.env` is preserved, and new upstream keys are appended.
- A branch or tag name works too, but it is re-downloaded on every run and you get a warning.
- If upstream's folder layout changes, you get a warning that the installer needs updating.

## Post-install helpers

These are native versions of upstream's scripts. Unlike upstream's versions, they **never print the database
password**.

| Helper | Does |
|---|---|
| Secure Authentik DB | Waits for PostgreSQL and applies upstream's grants |
| Create Guacamole DB | Creates the database, grants access, loads the schema and restarts Guacamole. The default login is `guacadmin`/`guacadmin`, so change it |
| Reset akadmin | Runs `ak changepassword akadmin` once Authentik is healthy |
| *ARR API keys | Reads each app's key and optionally stores the keys in the vault for unpackerr/homepage |

## Uninstall

- **Stack only** (`UNINSTALL`):
  - Runs `compose down --volumes --rmi all` for this project only.
  - Deletes the compose and app-data folders. Only their contents are deleted when a folder is a mountpoint.
  - Unmounts the managed shares and removes their fstab entries, credentials and the Docker drop-in.
  - Then asks separately about the media library (`DELETE-MEDIA`; on a share this deletes files **on the share**),
    the service account, and the config/vault.
- **Docker Engine purge** (`PURGE-DOCKER`) is a separate menu item. It lists non-MediaStack containers before
  removing anything.
- `rm -rf` is guarded against `/`, system directories and `/home/<user>`.

## Files and paths

```
/etc/mediastack/mediastack.conf          settings (0600)
/etc/mediastack/secrets.enc              encrypted vault
/etc/mediastack/.secrets.key             openssl backend key (0400)
/etc/mediastack/media.smbcred            SMB credentials for mount.cifs (0600, regenerated from vault)
/etc/fstab                               '# mediastack-installer:MEDIA|DATA' entries
/etc/systemd/system/docker.service.d/mediastack-mounts.conf
/var/lib/mediastack-installer/           upstream cache, deployed ref/domain/IP state
/var/log/mediastack/installer-*.log      run logs (newest 20 kept)
/usr/local/sbin/mediastack-installer     installed copy
<FOLDER_FOR_YAML>/                       docker-compose.yaml, docker-compose.override.yaml, .env,
                                         templates, wrappers, *.upstream originals, .backup/
```

## Notes and limitations

- The installer does **not** run upstream `restart.sh`. That script stops every container on the host and prunes
  all volumes, networks and images. The installer's apply is scoped to the `mediastack` project.
- `VPN_SERVICE_PROVIDER=custom` also needs `OPENVPN_CUSTOM_CONFIG` in `.env` (see the Gluetun docs).
- A `PLEX_CLAIM` token expires about 4 minutes after you request it, and Plex only uses it on first start.

## Testing

```bash
./mediastack-installer.sh --self-test     # 31 checks, no root/Docker/network needed
```

The self-test covers:

- `.env` parsing and editing, and config quoting
- CIDR maths and the delete-path guard
- folder layout drift, override rendering and the service-state cycle
- SMB/NFS remote validation and normalisation
- fstab line rendering and fstab edit/remove
- config migration and an encrypted vault round-trip

Development testing also ran full install, re-apply, dry-run, upgrade, migration, storage transitions
(local ↔ SMB ↔ NFS ↔ external), failure paths and uninstall against the real upstream compose file. Mounts and
containers were simulated, so test a real share with **Settings → T** before the first apply.
