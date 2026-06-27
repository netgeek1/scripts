# syslog-alert-router — Quickstart (v3, dedicated appliance)

For a clean Ubuntu 24.04 box that will do nothing but receive syslog and send
alerts. The script owns syslog-ng on this host.

## 1. Install

```bash
chmod +x syslog-alert-router.sh
sudo ./syslog-alert-router.sh install
```

This installs prerequisites (syslog-ng-core, python3-yaml, cron, openssl,
ca-certificates, msmtp), writes a managed `/etc/syslog-ng/syslog-ng.conf` with
listeners on **UDP/TCP 514** and **TLS 6514** (self-signed cert auto-generated in
`/etc/alerts/tls`) plus local logging, deploys the pipeline, and starts syslog-ng.

Check it:

```bash
./syslog-alert-router.sh status     # expect library: 3.0.0 (current), listeners, mailer
```

## 2. Configure mail (msmtp smarthost)

Either set it under `settings:` in `/etc/alerts/config/alerts.yaml`:

```yaml
  smarthost: smtp.dreamhost.com
  smarthost_port: 587
  smarthost_tls: true
  smarthost_user: alerts@geektech.us     # omit for an unauthenticated relay
```

then store the password (0600) and apply:

```bash
sudo ./syslog-alert-router.sh setup-mta   # prompts for the password if a user is set
./syslog-alert-router.sh mailtest you@example.com
```

…or do it inline: `sudo ./syslog-alert-router.sh setup-mta --relay smtp.dreamhost.com:587 --relay-tls`.

## 3. Define alerts and recipients

```bash
sudo ./syslog-alert-router.sh rules     # add/edit alerts; set recipients + relay per alert
sudo ./syslog-alert-router.sh relays    # optional: additional SMTP relays + failover
```

Per alert you set its own recipient group(s) and its own relay/failover chain.
The editor warns if a regex matches every line (e.g. a stray leading `|`).

## 4. Point your gear at the box

Send syslog from FortiGate / pfSense / Ubiquiti to this box's IP:
- Plain: UDP or TCP **514**
- Encrypted: TLS **6514** (senders that verify certs need to trust the cert in
  `/etc/alerts/tls/cert.pem`, or replace it with a CA-signed pair)

Watch it work:

```bash
tail -f /var/log/alerts/dispatcher.log
ls /var/log/remote/                      # per-host archive of everything received
```

## Day-to-day

| Task | Command |
|---|---|
| Change alerts/recipients | `rules` (auto-regens) |
| Change listeners (ports/toggles) | edit `alerts.yaml` settings, then `install` |
| Rebuild config + reload | `regen` |
| Test mail path | `mailtest [--relay NAME] addr` |
| Dry-run a log line | `test "<message>" [program]` |
| Force escalation/digest pass | `sweep` |
| State of everything | `status` |

## Notes

- Changing a **regex** or **listener** needs `regen`/`install`; changing
  recipients/severity/relay/template is picked up live by the dispatcher.
- After editing the dispatcher/library code, `install` restarts syslog-ng so the
  new code loads; `status` flags a stale library.
- `uninstall` removes code/fragment/cron but leaves your managed `syslog-ng.conf`
  in place (so logging keeps working) and keeps config/secrets/DB. To fully
  revert syslog-ng, restore a `/etc/syslog-ng/syslog-ng.conf.bak.*`.
