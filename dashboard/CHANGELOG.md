# Changelog

All notable changes to **docker-dashboard.sh**. Newest first.
`SCRIPT_VERSION` in the script is the authoritative version string. Versions follow `MAJOR.MINOR.PATCH`.

## v2.1.1 — 2026-10-26 — Progress output

### Fixed
- Image pulls and apt output scrolled line by line instead of updating in place. Commands now write straight to the
  terminal when there is one. The run log records each command and its exit code, and timer runs, which have no
  terminal, still log the full output.

## v2.1.0 — 2026-10-26 — Host preparation

### Added
- **Host preparation** runs during install, after the settings and before anything is written:
  - It installs the base packages (`ca-certificates curl gnupg openssl iproute2 ...`) as `docker-base-install.sh`
    does.
  - It checks disk space (30 GiB with Greenbone), RAM for Greenbone, NTP sync, a DHCP-leased address on a DNS
    server, host DNS, and Docker Hub reachability.
- **Port 53 freed automatically** when Pi-hole is on and systemd-resolved's stub listener holds it.
  - Only the stub listener is turned off. `/etc/resolv.conf` is pointed at resolved's upstream list, so the host
    keeps resolving.
  - If host DNS breaks, the change is rolled back.
  - The original is recorded and restored on uninstall.
  - This also runs on `--apply`.
- Self-test: 52 checks (stub freed/restored, rollback on DNS failure).

### Changed
- The install checks ports before any import data is written, and checks them once per run.

## v2.0.0 — 2026-10-26 — All-in-one installer, reverse proxy, migration

### Added
- **App catalog**, each app as its own compose project (`dd-<app>`) under `/opt/stacks/<app>`, with data alongside:
  - Pi-hole
  - Portainer CE
  - internet monitoring (Grafana, Prometheus, node, blackbox and speedtest exporters)
  - Guacamole on PostgreSQL 17
  - MeshCentral
  - Greenbone/OpenVAS (optional, off by default; uses Greenbone's own compose file plus an override)
- **Reverse proxy:** each app endpoint gets `https://<name>.<domain>`.
  - Upstreams resolve per request through Docker DNS, so a stopped app returns 502 without breaking nginx.
  - Websockets, TLS upstreams, unbuffered streaming and large uploads are handled per app.
  - Pi-hole `/` redirects to `/admin/`.
  - Guacamole's legacy `:8443` keeps working.
  - Direct ports stay published as fallbacks and can be blanked per app.
- **Certificates:**
  - Modes: `selfsigned` (adds `*.<domain>`), `custom` (watched by a systemd path unit), and `fetch` (daily `scp`
    from another host, e.g. OPNsense acme.sh, with its own SSH key).
  - Key match, expiry and name coverage are checked before deploying, and a bad certificate is refused.
- **DNS:**
  - `--dns-records` lists every name, with Windows DNS PowerShell lines.
  - Pi-hole answers the names itself through `etc-pihole/hosts/docker-dashboard.list`, without touching your
    records.
- **Migration:**
  - `--export` runs on the old host using only `docker`/`tar`/`openssl`, so it works with Docker 20.10 and
    `docker-compose` v1. It recognises apps by image and reads their real settings.
  - Data is captured consistently: apps are stopped briefly and restarted, Guacamole is captured with `pg_dump`, and
    MeshCentral data is copied out even from inside a container. The result is one AES-256 bundle.
  - `--import` (with `--install`) restores data with numeric ownership, restores the Guacamole database, and applies
    the Guacamole 1.6 schema upgrade.
  - Options: `--no-metrics`, `--leave-stopped`, `--passphrase-file`. Import has an `OVERWRITE` gate that stops the
    apps first.
- **Encrypted vault** for app passwords (systemd-creds/TPM2 or openssl, same scheme as mediastack-installer).
  Passwords are passed to compose at run time and never written to compose files. The Secrets menu changes the
  Guacamole DB password in PostgreSQL as well.
- Update-all updates managed apps and the dashboard first, with secrets. Other projects and `docker run` containers
  are handled as before.
- Apps menu (on/off, images, names, ports), Secrets menu, Certificate menu, `--gvm-password`, `--cert-refresh`,
  `--cert-fetch-key`.
- The page shows each app's direct-port fallback under its link.
- Port check covers every app port (TCP and UDP 53) and explains systemd-resolved on Ubuntu.
- Self-test: 50 checks.

### Changed
- The page groups app links under **Apps**. Custom links keep their own groups (default group: `Links`).
- Uninstall also removes managed app containers and the proxy network. App data is kept unless `DELETE-DATA` is
  typed.
- Health checks reach the app names through the local proxy, so they work before DNS records exist.

### Fixed
- Endpoint records use `|`, not tabs. `read` collapses repeated tabs, which shifted empty fields.

### Companion: docker-inventory.sh v1.0.1
- Compose v1 records config files relative to the project folder. Those files are now found and included.

## v1.0.0 — 2026-10-25 — Initial release

### Added
- **Landing page** on the host's ports 80/443, served by an nginx container (`docker-dashboard`):
  - HTTP redirects to HTTPS, keeping the path; a non-443 HTTPS port is kept in the redirect.
  - Links are grouped and filterable, in light and dark themes, and work at phone width.
  - The page loads nothing from the internet. Its content comes from `services.json`, so editing the services list
    never touches the page or nginx.
- **Services list** in `/etc/docker-dashboard/services.conf` (`group | name | url | description`), managed from the
  Services menu (add, edit, remove, move, detect) or the CLI (`--add-service`, `--remove-service`,
  `--list-services`). Changes publish to the running page immediately.
- **Detection** of web endpoints published by running containers:
  - Each published TCP port is probed for HTTPS, then HTTP.
  - Common images get friendly names, and Pi-hole gets its `/admin/` path.
  - `--rm` containers and the dashboard's own ports are skipped.
  - Host-network containers are listed for manual entry.
- **Health checks** run host-side from a systemd timer every N minutes and write `status.json`, so the page's status
  dots work for `http://` services too. A browser on an HTTPS page cannot probe those (mixed content).
- **TLS**: a self-signed certificate (IP + hostname SANs, plus extra names) that is regenerated when names change or
  expiry is under 30 days. Alternatively, a custom certificate (e.g. an acme.sh wildcard), checked for key match and
  expiry.
- **File share** (optional): a read-only folder at `/files/`.
  - The page lists the files with copy-ready `curl` commands.
  - Downloads also work over plain HTTP for targets without TLS.
  - Dotfiles are never served.
- **Update all containers** (`--update-all`, menu 5):
  - Compose projects are pulled and brought up from their own folder and compose files. One unpullable (local or
    private) image does not block the rest of its project.
  - A project whose `docker compose config` fails is skipped with guidance. This is usually because an installer
    supplies its variables or secrets.
  - **Delegates** (`project=command`) hand a project to its own installer. `mediastack-installer` is detected
    automatically.
  - Standalone `docker run` containers are recreated with their original settings by a one-shot run of the
    maintained Watchtower fork (`nickfedor/watchtower`). If the pull fails, a local copy is used.
  - `--rm` containers (such as the temporary `web` file server) are never touched. An exclusion list applies too.
  - Dangling images are pruned, and the run ends with a summary of which containers actually changed.
  - The exit status is non-zero when anything failed, for the timer.
- `--check-updates` (menu 6): pulls newer images and reports which containers are behind, without restarting
  anything.
- **Scheduled updates** (off, daily or weekly at a set time) as a systemd timer, with `Persistent=true` so a missed
  run happens at next boot.
- **Port check** before every apply: names the container or process holding 80/443, with the exact fix (the
  compose file to edit, or `docker run -p`, or Pi-hole's `FTLCONF_webserver_port` for host networking).
- Safety:
  - `nginx -t` validates in a throwaway container before the running dashboard is touched.
  - Writes are atomic and only happen when content changed. nginx is reloaded and systemd `daemon-reload` runs only
    when needed.
  - Dry-run mode is available everywhere.
  - Uninstall requires typing `UNINSTALL`, and the shared files folder is never deleted.
- Docker Engine install based on `docker-base-install.sh` (Ubuntu/Debian, conflicting distro packages handled),
  with an optional add of the invoking user to the `docker` group.
- Menu and CLI equivalents, per-run logs in `/var/log/docker-dashboard` (newest 30 kept), and a self-test with
  38 checks.
