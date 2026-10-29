# Wildcard TLS Certificate Deployer

A single POSIX `/bin/sh` script that deploys one wildcard TLS certificate to a
fleet of network appliances, then **verifies over TLS that each device is
actually serving the new certificate**. Built to run on an OPNsense firewall
(FreeBSD `/bin/sh`), and portable to Linux (`dash`).

The certificate itself is issued/renewed elsewhere — on OPNsense, by the ACME
Client plugin (Let's Encrypt via DNS-01). This script only **distributes** that
cert to devices that can't get it themselves.

## Supported targets

| Device | Method |
|---|---|
| FortiGate | REST API (`/api/v2`, bearer token) |
| FortiManager | JSON-RPC (bearer token) |
| FortiAnalyzer | JSON-RPC (bearer token) |
| Ubiquiti Cloud Gateway (UCG) | SSH + scp, restart `unifi-core` |
| GL-Net RM1 / GL-KVM | SSH + scp, restart `nginx` |
| Docker host (docker-dashboard) | SSH stdin push to a forced command (`--cert-receive`) |
| TrueNAS SCALE | v2.0 REST API (bearer token) |

Each device can be enabled or disabled independently in the config file.

## How it works

1. **Discover** the issued cert from the ACME plugin output by matching its SAN
   (the plugin stores it under an opaque id that changes on re-issue, so paths
   are never hardcoded).
2. For each enabled device, **probe** its live certificate over TLS:
   - already serving the right cert → `CURRENT`, skip;
   - serving a different cert → deploy;
   - no TLS response → `UNREACHABLE`, nothing attempted.
3. **Deploy**, then **re-probe** to confirm the device now serves the new cert
   (retrying while its web server restarts). A device that comes back with the
   old cert, or never comes back, is `FAILED` — not silently assumed good.
4. **Report**: a per-device summary, a non-zero exit if anything failed, and an
   optional email.

Each device runs in isolation: one failure is recorded and the rest continue.

## Requirements

- POSIX `/bin/sh` (FreeBSD `ash` / OPNsense, or Linux `dash`).
- `openssl`, `curl` (with `smtp` support, for email), `jq`.
  On OPNsense: `pkg install jq` (not shipped by default; re-check after a major
  upgrade). `ssh`/`scp` are only needed if a UCG/RM1 (SSH) device is enabled.
- For auto-discovery: the OPNsense ACME Client plugin, having issued the cert.

## Files

Public (safe to commit):

| File | Purpose |
|---|---|
| `install_wildcard_cert_api.sh` | the script |
| `install_wildcard_cert.conf.example` | config template |
| `README.md`, `CHANGELOG.md` | docs |

Private (create on the host; **never commit** — see `.gitignore`):

| File | Purpose |
|---|---|
| `/root/ssl_certs/install_wildcard_cert.conf` | your settings |
| `/root/ssl_certs/.env` | API keys (`chmod 600`) |
| `/root/.ssh/*_ed25519` | SSH keys for UCG/RM1 |

The script ships with safe **example defaults** (RFC 5737 addresses,
`example.com`). It refuses to run against them, so a missing or unedited config
fails loudly rather than touching the wrong thing.

## Setup

```sh
# 1. place the script and make it executable
install -m 700 install_wildcard_cert_api.sh /root/ssl_certs/

# 2. create your config from the template
cp install_wildcard_cert.conf.example /root/ssl_certs/install_wildcard_cert.conf
chmod 600 /root/ssl_certs/install_wildcard_cert.conf
$EDITOR  /root/ssl_certs/install_wildcard_cert.conf     # real IPs, domain, SMTP

# 3. create the secrets file (API keys only)
cat > /root/ssl_certs/.env <<'EOF'
API_KEY_FGT="..."
API_KEY_FMG="..."
API_KEY_FAZ="..."
API_KEY_TRUENAS="..."
EOF
chmod 600 /root/ssl_certs/.env

# 4. for SSH devices (UCG/RM1): install the keys and seed known_hosts
chmod 600 /root/.ssh/ucg_ed25519 /root/.ssh/rm1_ed25519
ssh-keyscan -p 22 <UCG_IP> >> /root/.ssh/known_hosts
ssh-keyscan -p 22 <RM1_IP> >> /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts

# 5. dry run — probes everything, changes nothing
/root/ssl_certs/install_wildcard_cert_api.sh -n -d
```

Only enabled devices are validated, so you can start with a subset.

### Docker host (docker-dashboard)

This target uses docker-dashboard's certificate **push** mode: the deployer
streams the chain + key over SSH to a forced command on the host. No scp, no
remote command (both are rejected for this user). One-time setup:

1. **Create the key on OPNsense:**
   ```sh
   ssh-keygen -t ed25519 -N '' -f /root/ssl_certs/docker_push_ed25519
   chmod 600 /root/ssl_certs/docker_push_ed25519
   ```
2. **On the Docker host:**
   - copy `docker_push_ed25519.pub` over;
   - `sudo docker-dashboard --cert-push-setup docker_push_ed25519.pub`
     (creates the `ddcertpush` user, its restricted `authorized_keys`, and the
     sudoers rule);
   - in **Settings → Certificate**, set `CERT_MODE=push` and
     `CERT_PUSH_FROM=<OPNsense LAN IP>`.
3. **Seed the host key on OPNsense:**
   ```sh
   ssh-keyscan -p 22 <DOCKER_IP> >> /root/.ssh/known_hosts
   ```
4. In your config, set `DEPLOY_DOCKER=1` and `DOCKER_IP` (and, if non-default,
   the port/user/key vars).
5. Test: `install_wildcard_cert_api.sh --dry-run`, then a real run.
6. **Manual sanity check** from OPNsense — should print a `DD-CERT-RECEIVE OK`
   line:
   ```sh
   cat fullchain.pem private.key | \
     ssh -i /root/ssl_certs/docker_push_ed25519 ddcertpush@<DOCKER_IP>
   ```

The deployer sends `fullchain.pem` when it sits beside the leaf (falling back to
`cert + chain.pem`, then leaf-only with a warning), checks the chain's first
certificate matches the local leaf before sending, and confirms the receiver's
reported `sha256` matches — then verifies over TLS like every other device.

## Usage

```
install_wildcard_cert_api.sh [options]

  -d, --debug      DEBUG-level console output
  -q, --quiet      warnings and errors only
  -n, --dry-run    report intended actions; make no changes
      --digest     read-only cert-status report (days-to-expiry), email it
  -c, --config F   config file (default /root/ssl_certs/install_wildcard_cert.conf
                   or $CERT_DEPLOY_CONF)
  -V, --version
  -h, --help
```

Full DEBUG detail is always written to a per-run log in `LOG_DIR`, regardless of
console verbosity. Manual runs behave identically to cron (fully
non-interactive).

## Scheduling on OPNsense

OPNsense regenerates `crontab` from `config.xml`, so register configd actions
rather than editing crontab directly. Create
`/usr/local/opnsense/service/conf/actions.d/actions_certdeploy.conf`:

```ini
[deploy]
command:/root/ssl_certs/install_wildcard_cert_api.sh
parameters:
type:script
message:Deploy wildcard certificate to network devices
description:Deploy wildcard certificate to network devices
timeout:600

[digest]
command:/root/ssl_certs/install_wildcard_cert_api.sh --digest
parameters:
type:script
message:Daily certificate status digest
description:Daily certificate status digest
timeout:300
```

Then:

```sh
service configd restart          # NOT 'configctl ... restart'
configctl certdeploy deploy      # test; returns OK with no output (type:script)
```

Both actions appear under **System → Settings → Cron** by their `description:`.
Schedule the deploy nightly and the digest once daily.

> The `description:` field (not `message:`) is what makes an action appear in
> the Cron dropdown.

> You may see a log line like `MAIL (mailed 37 bytes of output but got status
> 0x0001)`. That is an OPNsense cron quirk (configctl echoes a job UUID that
> cron tries to mail with no local MTA) — not this script. Harmless; filter it.

## Updating

Because all settings live in `install_wildcard_cert.conf`, you can replace the
script in place without losing anything:

```sh
# download the new version straight over the old one
fetch -o /root/ssl_certs/install_wildcard_cert_api.sh <url>   # or scp/git pull
chmod 700 /root/ssl_certs/install_wildcard_cert_api.sh
```

Your `.conf` and `.env` are untouched. If a release adds a new setting, it comes
with a safe default; check `CHANGELOG.md` and the updated
`install_wildcard_cert.conf.example` for anything new worth setting.

## Notifications

Email goes through an internal SMTP relay via `curl smtp://` (no mailer package
needed). `NOTIFY_ON` controls when:

| `NOTIFY_ON` | Sends on |
|---|---|
| `changes` (default) | any failure/expiry, or any device actually updated; silent on a quiet all-`CURRENT` night |
| `failure` | only failures / unreachable |
| `always` | every run |
| `never` | never (same as `NOTIFY_EMAIL=0`) |

A broken relay never changes the run's exit status — it logs a warning and the
deployment result stands.

### Expiry monitoring

Every normal run checks each enabled device's **live** cert against
`CERT_WARN_DAYS` (default 21) and raises a warning — and a notification — if it
is close to expiry, even when the cert otherwise matches. This catches a device
whose deployment has been quietly failing before the cert actually lapses.

The `--digest` run emails a full fleet report every day (`OK` / `EXPIRING` /
`EXPIRED` / `UNREACHABLE` / `DISABLED`). Because it is sent unconditionally, a
**missing** digest is itself a signal that the host or cron has stopped.

## Security notes

- No secrets in the script or the config file — API keys load from `.env`, SSH
  uses key files. Keep `.conf`, `.env`, and private keys out of git.
- Secrets are redacted from logs (bearer tokens, inline PEM keys).
- API calls use `-k` (the devices are on a trusted LAN with their own,
  soon-to-be-replaced certs). Review this if you run across untrusted networks.

## License

Add a license of your choosing (e.g. MIT) before publishing.
