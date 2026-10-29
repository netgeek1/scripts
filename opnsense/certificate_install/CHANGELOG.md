# Changelog

All notable changes to this project are documented here.
The format is loosely based on [Keep a Changelog](https://keepachangelog.com/),
and the project uses [Semantic Versioning](https://semver.org/).

## [3.1.0] - 2026-10-28

### Added
- **Docker host target** (`docker-dashboard --cert-receive`), a seventh device.
  Uses docker-dashboard's certificate push model: the deployer streams the
  certificate chain followed by the private key over SSH to a forced command —
  no scp, no remote command (both are rejected for the `ddcertpush` user).
  - Sends `fullchain.pem` when present beside the leaf, else `cert + chain.pem`,
    else the leaf alone with a warning; verifies the chain's first certificate
    matches the local leaf before sending.
  - Parses the receiver's `DD-CERT-RECEIVE OK …` status line, confirms its
    `sha256` matches the local leaf, then verifies over TLS like every other
    device. The private key is never logged and never written to a temp file.
  - New config: `DEPLOY_DOCKER`, `DOCKER_IP`, `DOCKER_HTTPS_PORT`,
    `DOCKER_SSH_USER` (default `ddcertpush`), `DOCKER_SSH_PORT`,
    `DOCKER_SSH_KEY`. Included in `validate_config`, `preflight`, the `--digest`
    report, and the run summary. `validate_config` also checks the SSH/HTTPS
    ports are numeric.
  - Ships disabled (`DEPLOY_DOCKER=0`). See the README section
    "Docker host (docker-dashboard)" for one-time setup.

## [3.0.0] - 2026-10-28

### Changed (breaking)
- **Site configuration moved to an external file.** All host-specific settings
  (domain, device IPs, SSH users/keys, SMTP, toggles, thresholds) now live in
  `install_wildcard_cert.conf`, sourced over the script's built-in example
  defaults at startup. The script itself can be updated (git pull / download
  over the old copy) without disturbing your settings.
  - Default location `/root/ssl_certs/install_wildcard_cert.conf`; override with
    `-c/--config PATH` or `$CERT_DEPLOY_CONF`.
  - A missing config is a hard error. Shipped defaults are RFC 5737
    documentation addresses and the script refuses to run against them for an
    enabled device, so an unedited config fails loudly, never quietly.
  - **Migration:** copy `install_wildcard_cert.conf.example` to the path above,
    edit it, and keep your `.env` (API keys) as before.
- The version history moved out of the script header into this file.

### Added
- `validate_config()` — fails preflight with a specific message when an enabled
  device has an empty or still-example IP, an SSH device lacks a user/key, or
  email is enabled without SMTP settings.

### Fixed
- API keys are now required only for **enabled** devices, and only in deploy
  mode (the digest needs none). Previously all four keys were mandatory even
  for disabled FortiManager/FortiAnalyzer.
- The `--digest` run no longer depends on the local ACME certificate being
  present/valid: it uses a lighter preflight so it can still report device
  status when local issuance has failed — which is when you most need it.

## [2.14.0] - 2026-10-12

### Added
- **Certificate expiry monitoring**, addressing a silent failure where a device
  read `CURRENT` every night until its cert actually lapsed.
  - Every normal run now sweeps each enabled, reachable device's live cert and,
    if it is within `CERT_WARN_DAYS` (default 21) of expiry — or already
    expired — raises a warning and forces a non-zero exit, so `NOTIFY_ON=changes`
    mails you even when every device otherwise reported `CURRENT`.
  - New `--digest` mode: a read-only daily report. Probes every device, lists
    days-to-expiry per device (`OK` / `EXPIRING` / `EXPIRED` / `UNREACHABLE` /
    `DISABLED`), emails it unconditionally, and changes nothing. Its arrival
    confirms host and cron are alive; its absence is itself an alarm.

### Changed
- Factored the raw SMTP send into `send_mail()`, shared by the event-driven
  `notify_email()` and the unconditional digest. `notify_email` behaviour is
  unchanged.
- `live_cert_days_left()` reads `notAfter` off the same `s_client` probe already
  used for fingerprinting (no new dependency); handles BSD and GNU `date`.

## [2.13.0] - 2026-10-12

### Added
- Per-device enable/disable toggles (`DEPLOY_FGT`, `DEPLOY_UCG`, `DEPLOY_RM1`,
  `DEPLOY_TRUENAS`, `DEPLOY_FMG`, `DEPLOY_FAZ`). A disabled device is fully inert
  — no probe, no API call, no SSH — reported as a distinct `DISABLED` state that
  never affects the exit code or notification. A disabled device under
  `--dry-run` stays `DISABLED`.
- FortiManager/FortiAnalyzer ship disabled pending an API-admin trusted-hosts
  fix after the move to OPNsense; re-enable with a config flag, no code change.

## [2.12.0] - 2026-07-13

### Changed
- `NOTIFY_ON="changes"` is now the default: mail on any `FAILED`/`UNREACHABLE`
  and on any device actually `UPDATED`, but stay silent on a quiet all-`CURRENT`
  night. `failure`, `always`, and `never` remain available; an unrecognised
  value warns and falls back to `changes`.
- Notification subject distinguishes the outcomes: certificate `DEPLOYED` / `OK`
  (no changes) / `FAILED`.

## [2.11.0] - 2026-07-13

### Fixed
- **TrueNAS deadlock.** TrueNAS refuses to delete a certificate currently
  assigned to the UI, and refuses to import a second cert with the same name —
  so delete-then-import failed and the box kept serving the old cert while
  reporting success. New order: import under a unique timestamped name → assign
  → restart → verify over TLS → then delete the old cert (no longer in use).
  Old certs are matched by name prefix so they cannot accumulate; a failed
  cleanup is a warning, since the new cert is already live and verified.

## [2.10.1] - 2026-07-13

### Fixed
- Preflight now checks SSH private-key file mode. OpenSSH ignores a
  group/world-readable key and scp then fails instantly, which looked identical
  to a host-key problem. Keys copied between hosts routinely arrive as `0644`.

## [2.10.0] - 2026-07-13

### Fixed
- scp stderr and the TrueNAS DELETE response are now captured into the log;
  previously a failed upload or a refused delete produced a bare `FAILED` with
  no reason.
- TrueNAS: a refused delete left the old cert in place, so find-by-name returned
  the old id and it was re-assigned as if new. The script now only accepts an id
  that was not already present.

### Added
- Preflight checks each SSH key exists and that the target host key is in
  `known_hosts`, printing the exact `ssh-keyscan` command to fix it.
- `SSH_HOST_KEY_CHECKING` (default `yes`), threaded through scp and ssh.

## [2.9.0] - 2026-07-13

### Changed
- Host moved from pfSense to OPNsense; the certificate is issued locally by the
  OPNsense ACME client plugin.
- `CERTIFICATE_FILE`/`PRIVATE_KEY_FILE` are no longer hardcoded. The plugin
  stores certs under an opaque id that changes if the entry is recreated, so
  `resolve_cert_paths()` discovers them at runtime by matching the SAN.
- `PATH` is pinned, since cron and configd provide a minimal environment and
  `openssl`/`curl`/`jq` live in `/usr/local/bin` on FreeBSD.

### Added
- Preflight refuses to deploy an expired certificate (`openssl -checkend 0`).

## [2.8.0] - 2026-07-12

### Added
- `notify_email()` emails the run summary via curl's `smtp://` support (no mailer
  package needed). Includes the per-device summary plus any WARN/ERROR lines.
  Always returns success so a broken relay can never change the run's exit
  status. CRLF per RFC 5321, built with awk (BSD sed cannot emit `\r`).

## [2.7.0] - 2026-07-12

### Removed
- OPNsense as a deployment target: the script now runs *on* the OPNsense box and
  its GUI certificate is handled by the ACME plugin. Back to six devices.

## [2.6.0] - 2026-07-11

### Added
- OPNsense support via the `trust/cert` REST API (basic key:secret auth). Because
  OPNsense has no API to select the GUI cert, the entry is updated in place to
  preserve its `refid`. (Superseded by 2.7.0.)

## [2.5.0] - 2026-07-11

### Added
- Post-deployment verification: `verify_deployed()` re-probes each device after
  the swap (retrying while the web server restarts) and confirms it is actually
  serving the new certificate. Per-device states: `CURRENT` / `UPDATED` /
  `FAILED` / `UNREACHABLE` / `DRY-RUN`.

### Fixed
- An unreachable device was indistinguishable from "certificate differs", so a
  full deployment was attempted against a host that was not answering.
  `probe_device()` now distinguishes current / differs / no-TLS.

## [2.4.0] - 2026-07-11

### Added
- Per-device isolation: each deployment runs in a subshell, so one failure is
  recorded without aborting the rest; end-of-run summary and non-zero exit if
  any device failed.
- TrueNAS async import handling (poll until the imported cert appears) and
  verified UI-certificate assignment.
- RM1 remote output captured into the debug log; quiet by default.

## [2.3.0] - 2026-07-11

### Changed
- Fortinet success detection uses `jq` against the status code instead of
  whitespace-sensitive `grep`.

## [2.2.1] - 2026-07-11

### Fixed
- FortiManager/FortiAnalyzer required multiple runs: when a device restarted its
  web daemon, curl exited non-zero and `set -e` aborted the run at the command
  substitution. All API curls are now guarded so a dropped connection during a
  service restart cannot terminate the run.

## [2.2.0] - 2026-07-10

### Added
- Network timeouts on all curl/ssh/scp calls and a `timeout`-wrapped TLS probe,
  so one dead host cannot stall the run.
- `-n/--dry-run`: reports intended actions per device and makes no changes.

## [2.1.0] - 2026-07-10

### Changed
- FortiGate deploys via the REST API (monitor import) instead of the SSH CLI;
  removed FortiGate SSH machinery. PEM-armor stripping generalised to
  RSA/EC/PKCS#8.

## [2.0.0] - 2026-07-10

### Added
- Levelled logging (DEBUG/INFO/WARN/ERROR) with full detail always to the log
  file, CLI flags, secret redaction, tight log permissions.

### Changed
- Fully non-interactive; key-only SSH with `BatchMode=yes`.

## [20260526-1849]

- Prior date-versioned revision (pre-semver).
