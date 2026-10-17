# Changelog

All notable changes to **mediastack-installer.sh**. Newest first.
`SCRIPT_VERSION` in the script is the authoritative version string. Versions follow `MAJOR.MINOR.PATCH`.

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
