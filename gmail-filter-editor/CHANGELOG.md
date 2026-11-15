# Changelog

All notable changes, newest first. Two components are versioned separately:

- **installer**: `SCRIPT_VERSION` in `gmail-filter-editor-installer.sh`
- **app**: `__version__` in `app/app.py`, which is also the image tag

Versions follow `MAJOR.MINOR.PATCH`.

## installer v1.0.0 / app v1.0.1 — 2026-11-15 — block exports Gmail would reject

### App 1.0.1
- **Fix:** export no longer writes filters that Gmail's *Import filters* rejects: no action, no criteria, or criteria
  over 1,500 characters. One such filter made Gmail refuse the whole file. Export now stops and lists them by row
  number, and you can export without them (`skip_invalid`), or cancel and go to the "With warnings" view.
  The response reports exported/skipped counts.
- The warning now reads "No action — Gmail will reject this".
- Properties the app doesn't know are counted as actions, so they are never wrongly flagged.
- 11 unit tests (was 9).

## installer v1.0.0 / app v1.0.0 — 2026-11-15 — first release

### Installer 1.0.0
- Self-contained, menu-driven installer on the standard pattern (docker-base-install.sh / switch-dashboard):
  the app source is embedded as a checksummed payload, and `--build-standalone` regenerates it from a checkout.
- Preflight checks (Ubuntu/Debian, amd64/arm64, bash 4.4+). Installs missing prerequisites, plus Docker CE with the
  compose and buildx plugins.
- Runs as the `gmailfilters` system account (nologin, not in the docker group). The container is hardened: read-only
  root, all capabilities dropped, `no-new-privileges`, and a memory limit.
- The web UI basic-auth password is kept in an encrypted vault (`systemd-creds`/TPM or OpenSSL) and injected at
  start; it is never written to the compose file. Unattended installs generate a password and show it.
- Settings model with validation: `--show-config`, `--set KEY VALUE`, and a settings menu.
- Host-side `--import FILE [merge]` and `--export [OUT]` against the running app; credentials are passed to
  curl on stdin.
- Backups: host-bound tar.gz, or a portable `.gfebak` encrypted with a passphrase (AES-256-CBC, PBKDF2-SHA256,
  600,000 iterations) with a manifest and SHA-256 checksums. A portable backup restores onto a fresh host.
- Dry-run mode, typed confirmations for destructive actions, run logs (20 kept), lock file.
- Self-test: 25 checks. `--app-self-test` runs the app's unit tests inside the built image.

### App 1.0.0
- Import Gmail `mailFilters.xml` (replace or merge, skipping exact duplicates), parsed with `defusedxml`.
- Editor for all Gmail criteria and actions; unknown properties are preserved unchanged.
- Search, sort, multi-select, duplicate, delete, and bulk label rename (with nested children).
- Warnings: no criteria, no action, criteria over 1,500 chars, conflicting actions, exact duplicates.
- Export all or selected filters in Gmail's own XML layout (single-quoted attributes).
- Autosave, plus snapshots before each import, export, restore and clear, restorable from the UI.
- Optional HTTP basic auth (`GFE_AUTH_USER`/`GFE_AUTH_PASS`); refuses requests if a user is set without a password.
- 9 unit tests: XML round-trip is lossless, merge dedupe, entity-expansion rejection, backup path traversal.
