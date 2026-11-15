# gmail-filter-editor

A web page for editing your **Gmail filters**. Export them from Gmail as `mailFilters.xml`, import that file here,
change what you need, and export a file that Gmail's **Import filters** accepts. It does not use the Gmail API,
OAuth or a Google Cloud project; it only reads and writes the XML file.

It runs as a hardened Docker container, installed and managed by one self-contained, menu-driven installer
(`gmail-filter-editor-installer.sh`), built on the same pattern as `docker-base-install.sh` and switch-dashboard.

Authors: netgeek1 & Claude (Anthropic)

![Filter list](docs/filters.png)

- **Import.** Upload `mailFilters.xml` and either **replace** what is loaded or **merge** it in (exact duplicates are
  skipped). A snapshot is taken first.
- **Edit.** A form for every Gmail criterion (from, to, subject, has the words, doesn't have, size,
  attachment, exclude chats) and action (label, skip inbox, mark read, star, delete, never spam, importance,
  category, forward). Properties the form doesn't know, such as canned responses, are preserved unchanged.
- **Bulk.** Search, sort, multi-select, duplicate, delete, and **rename a label** across all filters (nested
  `Parent/Child` labels included).
- **Warnings.** Filters with no criteria (Gmail rejects them), no action, criteria over Gmail's 1,500-character limit,
  conflicting actions, or exact duplicates.
- **Export** all or selected filters, in the same layout Gmail itself exports.
- **Snapshots.** Edits autosave; a snapshot is taken before every import, export, restore and clear, and can be
  restored from the **Backups** dialog.

## Install

```sh
sudo ./gmail-filter-editor-installer.sh            # interactive menu; choose 1) Full install
# or unattended (defaults: port 8085, login 'admin' with a generated password):
sudo ./gmail-filter-editor-installer.sh --install --yes
```

The installer:

1. Checks the OS (Ubuntu/Debian, amd64/arm64) and installs missing prerequisites.
2. Installs Docker CE + compose/buildx plugins from download.docker.com if Docker is missing.
3. Creates the **`gmailfilters`** system account (nologin, no home, not in the docker group). The container runs as it.
4. Stores the web UI password in an **encrypted vault** (`systemd-creds`, TPM-bound where available, or OpenSSL
   with a root-only key). The password is injected at start and is never written to the compose file.
5. Copies the embedded app source to `/opt/gmail-filter-editor/src`, builds the image, starts the container
   and waits for its health check.
6. Installs itself as **`/usr/local/sbin/gmail-filter-editor`**, so afterwards you just run
   `sudo gmail-filter-editor`.

Open `http://<host>:8085/` and sign in.

### Behind your reverse proxy

To publish it only through the proxy (e.g. `gmailfilters.domain.com` with the wildcard cert):

```sh
sudo gmail-filter-editor --set BIND_ADDRESS 127.0.0.1
sudo gmail-filter-editor --apply
```

Keep the basic-auth login on even behind a proxy: the filter file reveals your mail rules and addresses.

## Workflow

1. Gmail → **Settings → See all settings → Filters and Blocked Addresses** → tick all → **Export**.
2. Web UI → **Import XML…** (or from the host: `sudo gmail-filter-editor --import ~/mailFilters.xml`).
3. Edit.
4. **Export all** (or `sudo gmail-filter-editor --export ~/mailFilters-new.xml`).
5. In Gmail, **delete the old filters first**, then **Import filters** → choose the file → **Create filters**.
   Gmail's import *adds* filters; it never replaces them, so skipping the delete gives you duplicates.

Notes: `forwardTo` only works for addresses already verified in Gmail's Forwarding settings. A label that
doesn't exist in Gmail is created on import, so a renamed label shows up as a new label unless you rename it
in Gmail too.

## Menu

```
 Setup      1) Full install / reconfigure      2) Settings (login, password, container)
 Operate    3) Apply   4) Rebuild (no cache)   5) Start   6) Stop   7) Restart
            8) Status  9) Logs                 F) Filter files (import / export from this host)
 Maint.     B) Backup  R) Restore  U) Uninstall  T) Toggle dry-run  S) Self-test  0) Quit
```

## CLI

| Command | What it does |
|---|---|
| `--install [--yes]` | Wizard (or defaults), vault, Docker, account, build, start |
| `--apply` / `--rebuild` | Re-render and start; `--rebuild` also re-pulls the base image with no cache |
| `--start` `--stop` `--restart` `--status` `--logs [N]` | Lifecycle |
| `--show-config` / `--set KEY VALUE` | View / change a container or host setting (then `--apply`) |
| `--password` | Set the web UI password (prompt, or one line on stdin), then `--restart` |
| `--import FILE [merge]` / `--export [OUT]` | Load or write `mailFilters.xml` from the host shell |
| `--backup [--portable]` / `--restore FILE` | Host-bound tar.gz, or passphrase-encrypted `.gfebak` that restores on any host |
| `--rekey` | Re-encrypt the vault with the configured backend |
| `--uninstall` | Remove container and image (data kept unless you purge it; keyword `UNINSTALL`) |
| `--self-test` / `--app-self-test` | Installer tests (no root) / app tests inside the built image |
| `--build-standalone OUT` | Regenerate the self-contained installer from a checkout |
| `--dry-run`, `--yes`, `--source DIR`, `--confirm KEYWORD` | Options |

## Settings

`sudo gmail-filter-editor --show-config` lists every key with its help text. The main ones:

| Key | Default | Meaning |
|---|---|---|
| `BIND_ADDRESS` / `HOST_PORT` | `0.0.0.0` / `8085` | Where the web UI is published |
| `AUTH_USER` | `admin` (wizard) | Basic-auth user; empty turns the login off |
| `DATA_DIR` | `/opt/gmail-filter-editor/data` | `filters.json` + in-app snapshots |
| `BACKUP_DIR` / `BACKUP_KEEP` | `/var/backups/gmail-filter-editor` / `10` | Installer backups |
| `APP_BACKUP_KEEP` | `50` | In-app snapshots kept |
| `BASE_IMAGE` | `python:3.13-slim-bookworm` | Pin by tag or `@sha256:` digest |
| `MEM_LIMIT` | `256m` | Container memory cap |
| `SECRETS_BACKEND` | `auto` | `systemd-creds` (TPM) or `openssl` |
| `BACKUP_FORMAT` | `host` | `portable` makes `--backup` passphrase-encrypted by default |

## Container hardening

The container has a read-only root filesystem with a 16 MB `/tmp` tmpfs. It drops all capabilities, sets
`no-new-privileges` and runs as the non-root service account, with only `DATA_DIR` writable. The XML is parsed
with `defusedxml`, which blocks entity-expansion and external-entity attacks. Uploads are capped at 10 MB.

## Files

| Path | Contents |
|---|---|
| `/etc/gmail-filter-editor/gmail-filter-editor.conf` | Container/host settings (0600) |
| `/etc/gmail-filter-editor/secrets.enc` | Encrypted vault (web UI password) |
| `/opt/gmail-filter-editor/src/` | Build context (Dockerfile, app/) |
| `/opt/gmail-filter-editor/docker-compose.yml` | Generated; don't edit |
| `<DATA_DIR>/filters.json`, `<DATA_DIR>/backups/` | Current filter set, in-app snapshots |
| `/var/log/gmail-filter-editor/installer-*.log` | Installer run logs (20 kept) |

## Alternatives considered

- **gmailctl** (mbrt/gmailctl): filters-as-code in Jsonnet, synced through the Gmail API. Best if you want
  filters in git and are fine creating a Google Cloud OAuth client. It has no web UI and can't load an exported XML.
- **gmail_filter_manager** (rcmdnk): command-line XML↔YAML conversion.
- **gmail-britta**, **junlarsen/inbox**: generate new XML from a Ruby DSL or TOML file; they can't edit existing filters.

## License

MIT
