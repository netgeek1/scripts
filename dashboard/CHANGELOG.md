# Changelog

All notable changes to **docker-dashboard.sh**. Newest first.
`SCRIPT_VERSION` in the script is the authoritative version string. Versions follow `MAJOR.MINOR.PATCH`.

## v2.4.0 — 2026-10-26 — Add any running container

### Added
- **Add a container that's already running** (Apps → C → D): lists every running container that docker-dashboard
  doesn't run or proxy yet, from any folder, compose or `docker run`. The menu shows them as "running, not added".
  - The chosen one is set up as started by its own script. Its folder under `custom/` holds only an `app.conf`, and
    its files stay where they are.
  - The container port and HTTPS are pre-filled from the container.
- `CONTAINER` in `app.conf` lets you proxy a single `docker run` container instead of a compose project.
- Self-test: 72 checks.

### Fixed
- Update-all warned about a custom app started by its own script a second time, in the compose-project pass.
  `producer | grep -q` reports failure under `pipefail` when grep exits early, so the membership checks now
  capture the list first.
- Update-all no longer passes a registered `docker run` custom app to Watchtower; its own script updates it.
- Records with empty fields (docker-run containers have no compose labels) use the 0x1f separator, so `read`
  doesn't shift fields.

## v2.3.0 — 2026-10-26 — Apps started by their own script

### Added
- **Custom apps started by their own script** (`MANAGED='no'`): docker-dashboard adds the proxy name, card, DNS
  entry and health checks, and attaches to the running container.
  - It never starts, stops, pulls or rebuilds the app; its own installer keeps doing that.
  - Update-all reports it once and skips it. A delegate can run its installer instead.
  - Remove only takes it off the proxy.
- **Set up a folder** (F) detects an app already running from that folder under its own compose project and offers
  this mode (recommended), or handing it over to docker-dashboard under the same project, so no second copy starts.
- `PROJECT` in `app.conf` uses an existing compose project name instead of `dd-c-<name>`.
- Self-test: 70 checks.

### Fixed
- Setting up a folder whose compose file needs variables or secrets supplied by its installer exited the script.
  The setup now finds the services from the running containers, and `docker compose config` errors are shown with
  a hint instead.
- Errors inside the Custom apps menu return to the menu instead of ending the script.

## v2.2.2 — 2026-10-26 — Remove options for custom apps

### Changed
- **Remove** (Apps → C → R) now offers three levels:
  - *unregister only*: off the proxy, page and DNS list; containers keep running and the folder is untouched
  - *stop + unregister*: containers removed, folder and data kept
  - *delete everything*: still needs `DELETE-APP`
- An unregistered folder shows as "not set up yet" and can be set up again with F.

## v2.2.1 — 2026-10-26 — Custom app fixes

### Fixed
- A custom app whose `docker compose up` failed was reported as `[ OK ] ... is up`. Errors weren't being caught in
  that step. Each step is now checked, the proxied service must actually be running, and failures are reported
  while the other apps still start.
- Custom apps accept `docker-compose.yml`, `docker-compose.yaml` and `compose.yml`, as well as `compose.yaml`.

### Added
- **Set up a folder already in custom/** (Apps → C → F): for project folders another installer put there, built
  from source or not. The menu lists such folders as "not set up yet".
- Custom apps with a `build:` section are built on first apply. Update-all rebuilds them against a fresh base image,
  and falls back to the local base if it can't be pulled.
- "Make one from an image" warns when the image isn't on the host and points source-built apps to the folder setup.
- Self-test: 67 checks.

## v2.2.0 — 2026-10-26 — Custom apps and host health

### Added
- **Custom apps** live in `/opt/stacks/custom/<name>/` (`compose.yaml` + `app.conf`). Each one gets:
  - its own proxy name and the certificate
  - a card with a status dot, a place in the DNS list and the port check
  - update-all and export/import
- Custom apps are added from **Apps → C** (from an existing compose file or from an image) or by hand. Your compose
  file is never modified: the container is attached to the proxy network after each start, and re-attached by the
  health run if it was recreated elsewhere.
- `UPSTREAM_URL` covers host-networking apps. Names must be unique, and one broken custom app is skipped without
  blocking the rest.
- **Host panel** on the page: CPU (busy %, load per core), memory, swap, each filesystem, uptime, and containers
  (listing unhealthy, restarting and failed ones).
  - Values show OK / HIGH / CRITICAL against thresholds you set.
  - The data is collected by the existing health timer and needs no agent.
- `--host` (menu H) prints the same in the terminal. `--custom-apps` opens the custom apps menu.
- Self-test: 65 checks.

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
