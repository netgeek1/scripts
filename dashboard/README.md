# docker-dashboard

An all-in-one, menu-driven installer for a self-hosted Docker host. It runs your apps behind one HTTPS reverse proxy
with a landing page, keeps them updated, and moves them from an old host to a new one.

| App | What you get |
|---|---|
| **Pi-hole** | DNS filtering. It also answers the proxy's own names locally |
| **Portainer CE** | Container management |
| **Internet monitoring** | Grafana, Prometheus, speedtest, ping (blackbox) and node exporters — the [geerlingguy/internet-pi](https://github.com/geerlingguy/internet-pi) stack |
| **Guacamole** | Clientless remote desktop with PostgreSQL. Schema upgrades are applied for you |
| **MeshCentral** | Remote device management |
| **Greenbone / OpenVAS** *(optional, off)* | Vulnerability scanning, using Greenbone's own compose file |

Every app gets its own name, such as `https://grafana.example.net`, with one certificate (a wildcard or
self-signed). Its original port can stay published as a fallback.

The landing page shows a live up/down dot for each app, your own extra links, and an optional `/files/` share for
scripts you `curl` onto other machines.

> Version: see `SCRIPT_VERSION` in the script. History: [CHANGELOG.md](CHANGELOG.md).

---

## Contents

- [Requirements](#requirements)
- [Quick start (new host)](#quick-start-new-host)
- [Migrating from an existing host](#migrating-from-an-existing-host)
- [Names, DNS and certificates](#names-dns-and-certificates)
- [Menu and CLI](#menu-and-cli)
- [Apps](#apps)
- [Custom apps](#custom-apps)
- [Host health](#host-health)
- [Updating containers](#updating-containers)
- [Secrets](#secrets)
- [Settings reference](#settings-reference)
- [Files and paths](#files-and-paths)
- [Uninstall](#uninstall)
- [Testing](#testing)

---

## Requirements

| | |
|---|---|
| OS | Debian 12/13 or Ubuntu 22.04/24.04 (amd64 / arm64) with systemd |
| Access | root. The script re-runs itself through `sudo` |
| Docker | Installed for you if missing (Docker CE + compose plugin from download.docker.com) |
| Network | The image registries (docker.io, ghcr.io, and registry.community.greenbone.net for GVM), plus github.com for first-run defaults |
| Ports | 80/443 for the proxy, 53 for Pi-hole, and each app's fallback port if you keep it |

The install prepares the host before writing anything:

- **Base packages:** installs any that are missing.
- **Checks:** disk, RAM, NTP, a DHCP-leased address on the DNS server, host DNS, and Docker Hub reachability.
- **Port 53:** if `systemd-resolved` holds it and Pi-hole is enabled, it turns off only resolved's stub listener,
  after asking first. The host keeps resolving through the upstream servers resolved already uses. The change is
  rolled back if host DNS stops working, and undone on uninstall.

## Quick start (new host)

```bash
chmod +x docker-dashboard.sh
sudo ./docker-dashboard.sh          # menu -> 1) Full install
```

The install runs in this order:

1. It installs Docker.
2. It walks through the settings: domain, apps, certificate, file share, updates and paths. Each prompt shows the
   current value, so Enter accepts it.
3. It prepares the host: base packages, the checks above, and freeing port 53 for Pi-hole. Then it checks every
   port the apps need.
4. It brings everything up.
5. It prints the DNS records to create.

Afterwards the tool is installed as `sudo docker-dashboard`.

First-run defaults for a fresh install:

| App | Default |
|---|---|
| Pi-hole, Grafana, Guacamole DB | Passwords are generated and stored in the vault (see **Secrets**) |
| Guacamole | Starts with `guacadmin` / `guacadmin`. Change it at first login |
| Internet monitoring | Upstream's dashboards and blackbox config. Ping targets are in `/opt/stacks/monitoring/prometheus/pinghosts.yaml` |
| MeshCentral | A `config.json` is written so agents connect to `meshcentral.<domain>:<MeshCentral port>`. Create your admin account first, then set `NewAccounts` to `false` |

## Migrating from an existing host

Export runs on the **old** host and needs only `bash`, `docker`, `tar` and `openssl`. It works on old Docker 20.10
hosts with `docker-compose` v1. Import runs on the **new** host as part of the install.

```bash
# old host -- stops each app briefly for a consistent copy, then starts it again
sudo ./docker-dashboard.sh --export                 # asks for a passphrase; writes ~/docker-dashboard-export-<host>-<date>.tar.gz.enc

# new host
sudo ./docker-dashboard.sh --install --import docker-dashboard-export-<host>-<date>.tar.gz.enc
```

The export recognises apps by image, not by name or path. It reads each app's settings from the running container.

| App | What is carried over |
|---|---|
| Pi-hole | `/etc/pihole` (gravity, settings, local DNS records, query log), web password, `FTLCONF_*` settings, ports |
| Portainer | `/data` (users, endpoints, stacks), ports |
| Internet monitoring | Prometheus config and **history**, Grafana database and provisioning, blackbox config, the exact image tags you run, retention, plugins, admin password, ports |
| Guacamole | The database via `pg_dump`, which restores into a current PostgreSQL. The 1.6 schema upgrade is applied automatically. Also drive/recording folders and the old HTTPS port |
| MeshCentral | `meshcentral-data` (config, **server certificates** — your agents keep connecting), `-files`, `-backups`, `-web`. This works even when the data was never in a volume and lived inside the container |
| File share | `~/web-site-content` of the user running the export |

The bundle is AES-256 encrypted with your passphrase, because it contains the apps' passwords.

**Export options:**

- `--no-metrics` leaves out Prometheus history, which can be gigabytes.
- `--leave-stopped` keeps the old apps down after the export. Use it for the final cutover, so nothing changes after
  the snapshot.
- `--passphrase-file FILE` lets the export run without prompting.

**Not migrated:** containers the export doesn't recognise are listed in the bundle's notes, and the import shows them.

**Import behaviour:**

- Import refuses to write over existing app data unless you type `OVERWRITE` (or pass `--confirm OVERWRITE`). It
  then stops those apps first.
- The port check runs before any data is written.

### Cutover keeping the same IP

1. Build the new host on a temporary IP. In **Settings → Page** set the host address to the **final** IP, so links,
   DNS records and the certificate point there.
2. On the old host, run `sudo ./docker-dashboard.sh --export --leave-stopped`.
3. Copy the bundle to the new host, then run `--install --import`.
4. Shut the old host down, move the new one to the final IP, and run `sudo docker-dashboard --apply`.

Pi-hole is down from step 2 until step 4. Give clients a secondary DNS server for that window.

## Names, DNS and certificates

With a domain set, each app endpoint gets `https://<name>.<domain>`, and the landing page lives at
`https://dashboard.<domain>`. The names are configurable per app. Without a domain, links use `IP:port`.

**DNS:**

- `sudo docker-dashboard --dns-records` (menu D) lists every name with ready-to-paste `Add-DnsServerResourceRecordA`
  lines for Windows DNS.
- If Pi-hole is enabled, it answers these names itself. The script writes `etc-pihole/hosts/docker-dashboard.list`
  and leaves your own local DNS records alone.
- If clients resolve the domain through another server, such as Active Directory, add the records there as well.

**Certificates** (Settings → Certificate):

| Mode | Behaviour |
|---|---|
| `selfsigned` | Generated for the host IP, `*.<domain>` and `<domain>`. Browsers warn once |
| `custom` | Your full-chain PEM + key on this host. A systemd path unit redeploys them whenever the files change |
| `fetch` | Copied over `scp` every day from another machine, such as **OPNsense running acme.sh**, then deployed if changed |

Every mode is checked before it is used. The key must match, the certificate must not be expired, and every name the
proxy serves is checked against it (a warning names any that aren't covered). A bad certificate is refused and the
running one stays in place. nginx reloads without dropping connections.

**Fetch mode setup:**

1. Choose `fetch` and enter `user@host:/folder` plus the two file names, for example `fullchain.pem` and
   `privkey.pem`.
2. Let it create a key, or run `sudo docker-dashboard --cert-fetch-key`. Add the printed public key to that user on
   the source machine. On OPNsense, that is **System → Access → Users → Authorized keys**; the user needs a login
   shell and read access to the files.
3. If the source needs a non-standard SSH port, add a `Host` entry for it to root's `~/.ssh/config`.

If a fetch fails, the last good certificate keeps being served, and the timer run exits non-zero so the failure shows
in the journal.

## Menu and CLI

| Menu | CLI | What it does |
|---|---|---|
| 1 | `--install [--import FILE]` | Docker, settings, ports, (import), apps, proxy, page |
| 2 / 3 | `--settings` / `--apps` | Settings menu / turn apps on or off and edit their images, names and ports |
| 4 | `--services`, `--add-service`, `--remove-service`, `--detect` | Custom links on the page |
| K | `--secrets` | View or change stored passwords |
| C | `--cert-refresh`, `--cert-fetch-key` | Certificate actions |
| 5 | `--apply` | Converge everything: compose files, proxy config, page, DNS file, timers |
| 6 | `--update-all` | Update every running container on the host |
| 7 | `--check-updates` | Pull newer images and report which containers are behind; changes nothing |
| 8 / 9 | `--status` / `--health` | Overview / check every link now |
| D | `--dns-records` | DNS names to create |
| E / I | `--export` / `--import FILE` | Migration |
| X / U | `--stop` / `--uninstall` | Stop all (data kept) / remove (typed `UNINSTALL`) |
| T / S | `--dry-run` / `--self-test` | Show what would change / built-in tests |

More actions:

- `--host` (menu H) shows host health and refreshes the page's Host panel.
- `--custom-apps` (or Apps → C) manages your own apps.
- `--gvm-password` sets the Greenbone admin password from the vault once its first start has finished.

## Apps

Each app is its own compose project, `dd-<app>`, in `/opt/stacks/<app>/`. Its data sits next to its compose file in
plain folders, so one copy of `/opt/stacks` backs up everything.

- **Compose files are generated:** on every apply, from your settings. Change settings, not the files.
- **Passwords:** they never touch disk in plain text. They are passed to `docker compose` from the vault at run time.
- **Turning an app off:** it stops and its containers are removed, but its data stays. Turn it on again and it comes
  back as it was.
- **Ports:** every app's direct port is a setting. Blank means proxy only.

## Custom apps

Any app with a compose file can join the proxy: its own name, the wildcard certificate, a card with a status dot,
the DNS list, the port check, update-all and export/import. Your compose file is never changed. After each start,
the script attaches the app's container to the proxy network under the alias `dd-c-<name>`.

**Adding one from the menu:** **Apps → C → N**. Give it a short name, then either point at an existing compose file
(its `.env` is copied too) or let the script write a basic one from an image and port. Answer a few questions, then
apply.

**A project folder that's already there:** if a folder in `/opt/stacks/custom/` already has its own
`docker-compose.yml`, for example one another installer put there, it shows as "not set up yet". Choose
**Apps → C → F** to give it an `app.conf`. Apps with a `build:` section are built on the first apply, and
update-all rebuilds them.

**Adding one by hand:** create `/opt/stacks/custom/<name>/compose.yaml` (or `docker-compose.yml`) and an `app.conf`, then run
`sudo docker-dashboard --apply`:

```
TITLE='HP Switches'
SUBDOMAIN='switches'                       # -> https://switches.<domain>
SERVICE='web'                              # compose service the proxy talks to
PORT='8443'                                # its container port
TLS='yes'                                  # that port speaks HTTPS itself
FLAGS='ws'                                 # ws (websockets), stream (no buffering), big (large uploads)
FALLBACK_URL='https://192.168.0.190:8444/' # shown under the card (optional)
DESCRIPTION='Port status and admin up/down'
ENABLED='yes'
```

**How it behaves:**

- **Host networking:** apps using `network_mode: host` can't join a network. Set
  `UPSTREAM_URL='http://<host-ip>:<port>'` instead of `SERVICE`/`PORT`.
- **Checks at apply:** names must be unique, and the service must exist in the compose file.
- **One broken app doesn't block the rest:** a custom app with a problem is reported and skipped.
- **Recreated outside the script:** if the container is recreated another way (for example with
  `docker compose up` by hand), the next health run re-attaches it, within the health interval.
- **Disable or remove:** `ENABLED='no'` stops the app and keeps its folder. **Remove** in the menu offers three
  levels: *unregister only* (containers and folder untouched), *stop + unregister* (folder and data kept), or
  *delete everything* (after you type `DELETE-APP`).

## Host health

The health check (every 2 minutes) also collects host health for the **Host** panel at the top of the page. Each
value shows OK, HIGH or CRITICAL against thresholds you set in **Settings → Health**.

| Tile | Shows |
|---|---|
| CPU | Busy % and 5-min load per core (default: high at 1.0, critical at 2.0) |
| Memory / Swap | Use % and amounts (memory default: high at 85%, critical at 95%) |
| Disk (each filesystem) | Use % and amounts (default: high at 80%, critical at 90%). Includes NFS/SMB mounts |
| Containers | Running / total. Lists unhealthy, restarting, and exited-with-error containers |
| Uptime | Uptime and OS |

`sudo docker-dashboard --host` (menu H) prints the same in the terminal. For history and graphs, Grafana's
*Node Exporter Full* dashboard (ID 1860) uses the node-exporter that the monitoring app already runs.

## Updating containers

`sudo docker-dashboard --update-all` (menu 6) runs in three passes:

1. **Managed apps and the dashboard:** `pull` + `up` with secrets from the vault. Guacamole's schema is checked
   before it starts.
2. **Other compose projects:** `pull` + `up` from their own folder. Projects that need an installer's secrets are
   skipped with a hint, or handed to that installer as a **delegate**, e.g.
   `mediastack=/usr/local/sbin/mediastack-installer --apply --yes`. MediaStack is detected automatically.
3. **`docker run` containers:** recreated with their original settings by one run of the maintained Watchtower fork
   (`nickfedor/watchtower`). `--rm` containers are never touched.

Pinned tags stay pinned: an update moves within the tag you chose. You can exclude apps, containers or projects. A
daily or weekly timer is optional.

## Secrets

Secrets are stored in `/etc/docker-dashboard/secrets.enc`, encrypted with **systemd-creds** (bound to the TPM2 when
present) or with openssl and a root-only key file. This is the same scheme as `mediastack-installer`.

| Secret | Used for | Changing it later |
|---|---|---|
| `PIHOLE_PASSWORD` | Pi-hole web login | Applies on the next apply. If an imported Pi-hole had no password in its environment, none is set, and the one in its `pihole.toml` stays |
| `GRAFANA_ADMIN_PASSWORD` | Grafana's first start only | Change it in the Grafana UI |
| `GUAC_DB_PASSWORD` | Guacamole's PostgreSQL user | The Secrets menu changes it in PostgreSQL too |
| `GVM_ADMIN_PASSWORD` | Greenbone admin, via `--gvm-password` | Run `--gvm-password` again |

## Settings reference

All settings live in `/etc/docker-dashboard/dashboard.conf` (0600). Use the menus, or edit the file and then run
`--apply`. In menus, `-` clears an optional value.

**General:**

| Key | Default | Meaning |
|---|---|---|
| `DOMAIN` | detected | Names become `<sub>.<domain>`; empty = port links |
| `DASH_SUBDOMAIN` | `dashboard` | Landing page name |
| `HOST_ADDR` | `auto` | IP the names point at. Set the final IP before a cutover |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | Proxy ports |
| `TIMEZONE` | host's | `TZ` for the apps |
| `STACKS_DIR` / `DEPLOY_DIR` | `/opt/stacks` / `/opt/docker-dashboard` | App folders / proxy + page |
| `CERT_MODE` | `selfsigned` | `selfsigned`, `custom` or `fetch` |
| `CERT_FILE`, `CERT_KEY_FILE` | — | `custom` mode |
| `CERT_FETCH_SOURCE`, `CERT_FETCH_CERT`, `CERT_FETCH_KEY` | — | `fetch` mode |
| `FILES_DIR`, `FILES_HTTP` | —, `yes` | `/files/` share, plus plain-HTTP downloads |
| `HEALTH_CHECK`, `HEALTH_INTERVAL` | `yes`, `2` | Status dots |
| `HOST_PANEL` | `yes` | Host panel on the page |
| `HOST_DISK_WARN`, `HOST_DISK_CRIT` | `80`, `90` | Disk thresholds (%) |
| `HOST_MEM_WARN`, `HOST_MEM_CRIT` | `85`, `95` | Memory thresholds (%) |
| `HOST_LOAD_WARN`, `HOST_LOAD_CRIT` | `1.0`, `2.0` | Load-per-core thresholds |
| `UPDATE_SCHEDULE`, `UPDATE_DAY`, `UPDATE_TIME` | `off`, `Sun`, `04:00` | Scheduled updates |
| `UPDATE_PRUNE` | `yes` | Prune dangling images after updates |
| `UPDATE_EXCLUDE` | — | Apps, containers or projects never updated |
| `UPDATE_DELEGATE` | — | `project=command;...` |

**Per app:**

| Keys | Meaning |
|---|---|
| `APP_<NAME>` | `yes` / `no` |
| `<APP>_IMAGE` | Image and tag |
| `<APP>_SUBDOMAIN` | Name on the proxy |
| `<APP>_*_PORT` | Direct ports. Blank = not published |
| `PIHOLE_EXTRA_ENV`, `GRAFANA_EXTRA_ENV` | Extra settings as `K=V;K=V` |
| `PROMETHEUS_RETENTION`, `GRAFANA_PLUGINS` | Monitoring options |
| `GUAC_POSTGRES_IMAGE` | Default `postgres:17`. Keep the major version once data exists |

## Files and paths

| Path | What |
|---|---|
| `/etc/docker-dashboard/dashboard.conf` | Settings (0600) |
| `/etc/docker-dashboard/secrets.enc` | Encrypted secrets |
| `/etc/docker-dashboard/services.conf` | Custom links |
| `/etc/docker-dashboard/certfetch_ed25519` | Fetch-mode SSH key |
| `/opt/stacks/<app>/` | `compose.yaml` + the app's data |
| `/opt/stacks/guacamole/.restore/` | Imported database dump (kept after restore) |
| `/opt/docker-dashboard/` | Proxy compose, `nginx/`, `html/` (page, `services.json`, `status.json`), `certs/` |
| `/var/log/docker-dashboard/run-*.log` | One log per run (newest 30 kept) |
| `/etc/systemd/system/docker-dashboard-*` | Health, update and certificate timers/watchers |
| `/usr/local/sbin/docker-dashboard` | Installed copy |

## Uninstall

`sudo docker-dashboard --uninstall` (menu U) requires you to type `UNINSTALL`. It removes:

- the dashboard and every managed app container
- the proxy network
- the timers
- `/opt/docker-dashboard`

It then asks two questions. Deleting app data needs a second typed `DELETE-DATA`; removing settings and the vault is
a yes/no. Both default to keeping, so `--apply` brings everything back. Other containers and Docker itself are
never touched.

## Testing

```bash
./docker-dashboard.sh --self-test      # 67 checks, no root or Docker needed
```

The self-test covers the compose file and nginx config of every app (YAML-validated), the page JSON, endpoint
parsing, port-conflict parsing, certificate SANs, the vault round-trip, manifest safety, delegates and exclusions.

v2.0.0 was also run end to end on a real Docker daemon. The test environment used PostgreSQL holding a real
Guacamole 1.5 schema, and stand-in containers for the other apps at their real ports, mounts and image names. It
covered:

- export from a replica of an old Debian 11 layout, including MeshCentral data inside a container
- wipe, then import
- every name served through the proxy with the wildcard certificate, including websocket upgrade
- the Guacamole data restored onto the new PostgreSQL, with the 1.6 schema upgrade applied
- ownership kept for Grafana (472) and Prometheus (65534)
- the Pi-hole local DNS file written, with existing records untouched
- idempotent re-apply, with no containers recreated
- update-all recreating only the changed image
- app off/on, certificate renewal, a mismatched key refused, a fetch over scp, a fetch failure fallback
- port-conflict and overwrite guards, the menus, uninstall, and a fresh install without a bundle
- the Greenbone override validated against Greenbone's real `compose.yaml`
