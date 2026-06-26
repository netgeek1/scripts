#!/usr/bin/env bash
#
# syslog-alert-router.sh  (v2)
#
# Self-contained installer for a syslog-ng -> YAML-driven alert framework.
#
#   syslog-ng (program() dest)
#        -> alert-dispatcher.py   classify, dedup (SQLite), template, route, send
#        -> alert-sweeper.py      escalation + digests + prune  (cron, time-driven)
#
# Single source of truth: /etc/alerts/config/alerts.yaml
#   * Editing recipients/subject/template/severity = picked up live.
#   * Adding/removing a 'regex' = edit YAML, then:  syslog-alert-router.sh regen
#
# Host install. Local sendmail (no SMTP credentials on disk). Text + HTML email.
# Dependency: python3-yaml. Everything else is stdlib.
#
# Layout:
#   /usr/local/lib/alerts/alertlib.py     shared library
#   /usr/local/bin/alert-dispatcher.py    syslog-ng-fed dispatcher
#   /usr/local/bin/alert-sweeper.py       cron sweeper
#   /etc/alerts/config/{alerts,recipients}.yaml
#   /etc/alerts/templates/*.{txt,html}
#   /var/lib/alerts/alerts.db             SQLite state (FHS: mutable data)
#   /var/log/alerts/{dispatcher,sweeper}.log
#   /etc/syslog-ng/conf.d/alert-dispatch.conf   (generated)
#   /etc/cron.d/alert-sweeper
#
# Version: 2.0.0
#
set -euo pipefail
VERSION="2.2.0"

LIBDIR="${LIBDIR:-/usr/local/lib/alerts}"
ALERTLIB="$LIBDIR/alertlib.py"
DISPATCH="${DISPATCH:-/usr/local/bin/alert-dispatcher.py}"
SWEEPER="${SWEEPER:-/usr/local/bin/alert-sweeper.py}"
ALERTRELAYS="${ALERTRELAYS:-/usr/local/bin/alert-relays.py}"
CFGDIR="${CFGDIR:-/etc/alerts/config}"
ALERTS="$CFGDIR/alerts.yaml"
RECIP="$CFGDIR/recipients.yaml"
RELAYS_YAML="$CFGDIR/relays.yaml"
SECRETS="${SECRETS:-/etc/alerts/secrets}"
TPLDIR="${TPLDIR:-/etc/alerts/templates}"
DBDIR="${DBDIR:-/var/lib/alerts}"
LOGDIR="${LOGDIR:-/var/log/alerts}"
CONFD="${CONFD:-/etc/syslog-ng/conf.d}"
FRAGMENT="${FRAGMENT:-$CONFD/alert-dispatch.conf}"
CRON="${CRON:-/etc/cron.d/alert-sweeper}"
SYSLOG_SOURCE="${SYSLOG_SOURCE:-net}"
INSTALL_DEPS="${INSTALL_DEPS:-0}"
MTA="${MTA:-}"                 # "", msmtp, or postfix (only used if no MTA present)
RELAY="${RELAY:-}"            # smarthost HOST[:PORT] for msmtp / postfix satellite
RELAY_TLS="${RELAY_TLS:-0}"
MTA_MISSING=0

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
info() { printf '[%s] [INFO ] %s\n' "$(_ts)" "$*"; }
warn() { printf '[%s] [WARN ] %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "Must run as root."; }

backup() {
  local f="$1"
  if [ -e "$f" ]; then
    local b="${f}.bak.$(date '+%Y%m%d%H%M%S')"
    cp -a -- "$f" "$b"; info "Backed up $f -> $b"
  fi
}

atomic_write() {  # atomic_write <dest> <mode>  (content on stdin) -- always overwrites
  local dest="$1" mode="$2" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  cat > "$tmp"; chmod "$mode" "$tmp"; mv -f -- "$tmp" "$dest"
}

write_if_missing() {  # write_if_missing <dest> <mode>  (content on stdin) -- never clobbers
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp)"; cat > "$tmp"; chmod "$mode" "$tmp"
  if [ -e "$dest" ]; then info "Preserving existing $dest"; rm -f "$tmp"
  else mkdir -p "$(dirname "$dest")"; mv -- "$tmp" "$dest"; info "Created $dest"; fi
}

validate_syslogng() { syslog-ng -s 2>/dev/null || syslog-ng --syntax-only; }

reload_syslogng() {
  if command -v syslog-ngctl >/dev/null 2>&1; then info "Reloading via syslog-ngctl"; syslog-ngctl reload
  elif command -v systemctl >/dev/null 2>&1; then info "Reloading via systemctl"; systemctl reload syslog-ng 2>/dev/null || systemctl restart syslog-ng
  else warn "Reload syslog-ng manually."; fi
}

ensure_secrets_dir() {
  mkdir -p "$SECRETS"; chmod 0700 "$SECRETS"
  command -v chown >/dev/null 2>&1 && chown root:root "$SECRETS" 2>/dev/null || true
}

# Prompt twice (silently) and write a 0600 secret. Prints the file path on stdout;
# all prompts go to stderr so the path is the only thing captured.
write_secret() {
  local name="$1" p1 p2 path="$SECRETS/$1.pw"
  ensure_secrets_dir
  printf 'password> ' >&2; read -rs p1; printf '\n' >&2
  printf 'confirm > ' >&2; read -rs p2; printf '\n' >&2
  [ -n "$p1" ] || { echo "empty password" >&2; return 1; }
  [ "$p1" = "$p2" ] || { echo "passwords do not match" >&2; return 1; }
  ( umask 077; printf '%s' "$p1" > "$path" ); chmod 0600 "$path"
  echo "$path"
}

# =============================================================================
# write code (always overwrite, with backup)
# =============================================================================
write_code() {
  info "Installing code: alertlib + dispatcher + sweeper"
  backup "$ALERTLIB"
  atomic_write "$ALERTLIB" 0644 <<'__ALERTLIB_PY__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
alertlib.py -- shared helpers for the syslog alert framework.

Used by alert-dispatcher.py (event-driven, fed by syslog-ng) and
alert-sweeper.py (time-driven, run from cron for escalation + digests).

Dependencies: PyYAML (python3-yaml). Everything else is stdlib.
"""
import os
import re
import ssl
import time
import html
import sqlite3
import logging
import smtplib
import subprocess
from logging.handlers import RotatingFileHandler
from email.message import EmailMessage

try:
    import yaml
except ImportError:  # surfaced with a clear message by callers
    yaml = None

CONFIG_DIR = os.environ.get("ALERT_CONFIG_DIR", "/etc/alerts/config")
TEMPLATE_DIR = os.environ.get("ALERT_TEMPLATE_DIR", "/etc/alerts/templates")
DB_PATH = os.environ.get("ALERT_DB", "/var/lib/alerts/alerts.db")
ALERTS_YAML = os.path.join(CONFIG_DIR, "alerts.yaml")
RECIPIENTS_YAML = os.path.join(CONFIG_DIR, "recipients.yaml")
RELAYS_YAML = os.path.join(CONFIG_DIR, "relays.yaml")
SECRETS_DIR = os.environ.get("ALERT_SECRETS_DIR", "/etc/alerts/secrets")

h = html.escape  # short alias for code-built HTML

DEFAULT_SETTINGS = {
    "from": "monitor@syslog.certifiedgeeks.net",
    "sendmail": "/usr/sbin/sendmail",
    "dedup_window_sec": 3600,     # suppress identical signature within this window
    "digest_interval_sec": 3600,  # how often the sweeper flushes the digest queue
    "active_grace_sec": 900,      # gap after which a recurrence is a NEW episode
    "prune_after_sec": 604800,    # drop dedup rows untouched for this long (7d)
    "subject_max": 200,
    "body_max": 16000,
    "send_timeout": 20,
}

DURATION_KEYS = ("dedup_window_sec", "digest_interval_sec", "active_grace_sec",
                 "prune_after_sec", "send_timeout")


def parse_duration(v):
    """Accept int seconds or strings like '30m', '4h', '7d', '90s'."""
    if isinstance(v, (int, float)):
        return int(v)
    s = str(v).strip().lower()
    m = re.match(r"^(\d+)\s*([smhd]?)$", s)
    if not m:
        raise ValueError("bad duration: %r" % v)
    return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2) or "s"]


def hdr_safe(s, maxlen=998):
    """Strip CR/LF (header-injection guard) and clamp length."""
    return re.sub(r"[\r\n]+", " ", str(s)).strip()[:maxlen]


_VAR = re.compile(r"\{\{\s*(\w+)\s*\}\}")


def render(tpl, ctx, escape=False):
    """Minimal {{ var }} substitution. HTML values auto-escaped when escape=True."""
    def repl(m):
        val = str(ctx.get(m.group(1), ""))
        return html.escape(val) if escape else val
    return _VAR.sub(repl, tpl)


def load_template(base, ext):
    """Return template text for <base>.<ext>, falling back to generic.<ext>."""
    for cand in (base, "generic"):
        p = os.path.join(TEMPLATE_DIR, "%s.%s" % (cand, ext))
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                return f.read()
    return None


class Alert:
    __slots__ = ("name", "rx", "program", "template", "recipients", "severity",
                 "subject", "dedup_window", "digest", "escalation_after",
                 "escalation_group", "dedup_key", "relay_chain")

    def __init__(self, name, a, settings):
        self.name = name
        self.rx = re.compile(a["regex"], re.IGNORECASE)
        self.program = re.compile(a["program"], re.IGNORECASE) if a.get("program") else None
        tpl = str(a.get("template", name.lower()))
        if tpl.endswith((".txt", ".html")):
            tpl = tpl.rsplit(".", 1)[0]
        self.template = tpl
        self.recipients = a.get("recipients", [])
        self.severity = str(a.get("severity", "info"))
        self.subject = a.get("subject", "[{{severity}}] {{alert}} on {{host}}")
        self.dedup_window = parse_duration(a["dedup_window"]) if "dedup_window" in a \
            else settings["dedup_window_sec"]
        self.digest = bool(a.get("digest", False))
        self.escalation_after = parse_duration(a["escalation_after"]) if a.get("escalation_after") else None
        self.escalation_group = a.get("escalation_group")
        self.dedup_key = re.compile(a["dedup_key"]) if a.get("dedup_key") else None
        # optional per-alert relay override: 'relay: name' or 'relays: [a, b]'
        if a.get("relays"):
            self.relay_chain = list(a["relays"])
        elif a.get("relay"):
            self.relay_chain = [a["relay"]]
        else:
            self.relay_chain = None

    def signature(self, host, message):
        key = "%s:%s" % (self.name, host)
        if self.dedup_key:
            m = self.dedup_key.search(message)
            if m:
                key += ":" + (m.group(1) if m.groups() else m.group(0))
        return key


def load_config():
    """Parse YAML config -> (settings, [Alert], groups). Raises on error."""
    if yaml is None:
        raise RuntimeError("PyYAML not installed (apt install python3-yaml)")
    with open(ALERTS_YAML, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    settings = dict(DEFAULT_SETTINGS)
    settings.update(doc.get("settings") or {})
    for k in DURATION_KEYS:
        settings[k] = parse_duration(settings[k])
    settings["subject_max"] = int(settings["subject_max"])
    settings["body_max"] = int(settings["body_max"])

    alerts = []
    for name, a in (doc.get("alerts") or {}).items():
        if not isinstance(a, dict) or "regex" not in a:
            raise ValueError("alert %r missing 'regex'" % name)
        try:
            alerts.append(Alert(name, a, settings))
        except re.error as e:
            raise ValueError("alert %r bad regex: %s" % (name, e))
    if not alerts:
        raise ValueError("no alerts defined")

    with open(RECIPIENTS_YAML, encoding="utf-8") as f:
        rdoc = yaml.safe_load(f) or {}
    groups = rdoc.get("groups") or {}
    return settings, alerts, groups


def resolve_recipients(spec, groups):
    """Resolve a group name or list of group names to a deduped email list."""
    names = [spec] if isinstance(spec, str) else list(spec or [])
    seen, out = set(), []
    for n in names:
        for e in (groups.get(n) or []):
            if e not in seen:
                seen.add(e)
                out.append(e)
    return out


def db_connect(path=DB_PATH):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    con = sqlite3.connect(path, timeout=10)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA busy_timeout=5000")
    con.executescript("""
    CREATE TABLE IF NOT EXISTS dedup (
        signature  TEXT PRIMARY KEY,
        alert      TEXT NOT NULL,
        host       TEXT NOT NULL,
        first_seen INTEGER NOT NULL,
        last_seen  INTEGER NOT NULL,
        last_sent  INTEGER,
        count      INTEGER NOT NULL DEFAULT 0,
        escalated  INTEGER NOT NULL DEFAULT 0,
        sample_msg TEXT,
        level      TEXT
    );
    CREATE TABLE IF NOT EXISTS digest_queue (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        grp     TEXT NOT NULL,
        alert   TEXT NOT NULL,
        host    TEXT NOT NULL,
        ts      INTEGER NOT NULL,
        message TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
    """)
    con.commit()
    return con


def setup_logging(path, level="INFO"):
    log = logging.getLogger(path)
    if log.handlers:
        return log
    log.setLevel(getattr(logging, str(level).upper(), logging.INFO))
    try:
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        handler = RotatingFileHandler(path, maxBytes=1_048_576, backupCount=5)
    except Exception:
        handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(handler)
    return log


def load_relays():
    """Return (order:list, defs:dict). Empty -> caller falls back to local sendmail."""
    if not os.path.exists(RELAYS_YAML):
        return [], {}
    if yaml is None:
        raise RuntimeError("PyYAML not installed (apt install python3-yaml)")
    doc = yaml.safe_load(open(RELAYS_YAML, encoding="utf-8")) or {}
    r = doc.get("relays") or {}
    return list(r.get("order") or []), dict(r.get("defs") or {})


def _read_secret(relay, log=None):
    """Fetch a relay password without ever logging it. secret_cmd > secret_file."""
    cmd = relay.get("secret_cmd")
    if cmd:
        out = subprocess.run(cmd, shell=True, capture_output=True, timeout=10)
        if out.returncode != 0:
            raise RuntimeError("secret_cmd exited %s" % out.returncode)
        return out.stdout.decode("utf-8", "replace").strip("\r\n")
    sf = relay.get("secret_file")
    if sf:
        st = os.stat(sf)
        if (st.st_mode & 0o077) and log:
            log.warning("secret_file %s is group/other-readable; chmod 600 it", sf)
        with open(sf, encoding="utf-8") as f:
            return f.read().strip("\r\n")
    raise RuntimeError("auth enabled but no secret_file/secret_cmd configured")


def build_message(settings, to_list, subject, text_body, html_body=None):
    msg = EmailMessage()
    msg["From"] = hdr_safe(settings["from"], 256)
    msg["To"] = ", ".join(hdr_safe(t, 256) for t in to_list)
    msg["Subject"] = hdr_safe(subject, settings["subject_max"])
    msg.set_content(text_body[: settings["body_max"]])
    if html_body:
        msg.add_alternative(html_body[: settings["body_max"]], subtype="html")
    return msg


def _send_smtp(relay, settings, msg, to_list, log):
    host = relay["host"]
    port = int(relay.get("port", 25))
    sec = str(relay.get("security", "none")).lower()
    timeout = float(relay.get("timeout", settings["send_timeout"]))
    env_from = relay.get("from") or settings["from"]
    ctx = ssl.create_default_context()
    if relay.get("tls_verify", True) is False:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    if sec == "tls":
        server = smtplib.SMTP_SSL(host, port, timeout=timeout, context=ctx)
    else:
        server = smtplib.SMTP(host, port, timeout=timeout)
    try:
        server.ehlo()
        if sec == "starttls":
            server.starttls(context=ctx)
            server.ehlo()
        if relay.get("auth"):
            server.login(relay["user"], _read_secret(relay, log))
        server.send_message(msg, from_addr=env_from, to_addrs=list(to_list))
    finally:
        try:
            server.quit()
        except Exception:
            server.close()


def _send_sendmail(relay, settings, msg, to_list, log):
    sm = relay.get("sendmail", settings["sendmail"])
    subprocess.run([sm, "-t", "-oi"], input=msg.as_bytes(),
                   timeout=settings["send_timeout"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def send_mail(settings, to_list, subject, text_body, html_body=None,
              relays=None, order=None, chain=None, log=None):
    """Build the message once and try each relay in the chain until one accepts.

    chain (per-alert override) > order (global). With neither, fall back to the
    local sendmail binary so the no-relay case keeps working.
    """
    to_clean = [t for t in to_list if t]
    if not to_clean:
        return False, "no recipients"
    relays = dict(relays or {})
    names = list(chain) if chain else list(order or [])
    if not names:
        names = ["__local__"]
        relays["__local__"] = {"transport": "sendmail", "sendmail": settings["sendmail"]}
    msg = build_message(settings, to_clean, subject, text_body, html_body)
    errors = []
    for name in names:
        r = relays.get(name)
        if not r:
            errors.append("%s:undefined" % name)
            continue
        try:
            if str(r.get("transport", "smtp")).lower() == "sendmail":
                _send_sendmail(r, settings, msg, to_clean, log)
            else:
                _send_smtp(r, settings, msg, to_clean, log)
            return True, name
        except Exception as e:
            errors.append("%s:%s" % (name, type(e).__name__))
            if log:
                log.warning("relay %s failed: %s", name, e)  # never includes the secret
            continue
    return False, "all relays failed (%s)" % ", ".join(errors)
__ALERTLIB_PY__
  backup "$DISPATCH"
  atomic_write "$DISPATCH" 0755 <<'__DISPATCHER_PY__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
alert-dispatcher.py -- syslog-ng-fed alert classifier and notifier.

syslog-ng runs this as a program() destination and feeds one candidate
event per line, formatted as:   $ISODATE|$HOST|$PROGRAM|$MESSAGE
(split on the first 3 pipes; the message keeps any internal pipes).

Each line is classified against alerts.yaml; the first matching alert
decides template + recipient group. SQLite provides persistent dedup
(survives restarts) and tracks active episodes for the sweeper to
escalate. Digest-flagged alerts are queued, not emailed immediately.

Modes:
    (no args)        daemon: read stdin forever
    --check          validate config, print a summary, exit !=0 on error
    --test "MSG"     dry-run: show classification + rendered email (no send,
        [--host H]   no DB write)
        [--program P]
"""
import os
import sys
import time
import argparse

sys.path.insert(0, os.environ.get("ALERT_LIB_DIR", "/usr/local/lib/alerts"))
import alertlib as A  # noqa: E402

LOG_FILE = os.environ.get("ALERT_DISPATCH_LOG", "/var/log/alerts/dispatcher.log")


def classify(alerts, program, message):
    for al in alerts:
        if al.program and not al.program.search(program or ""):
            continue
        if al.rx.search(message):
            return al
    return None


def build_ctx(al, t, host, program, message, count):
    return {
        "alert": al.name, "host": host, "time": t, "program": program,
        "message": message, "severity": al.severity, "level": al.severity,
        "count": str(count),
    }


def render_bodies(al, ctx, suppressed):
    text_tpl = A.load_template(al.template, "txt") \
        or "Alert: {{alert}}\nHost: {{host}}\nTime: {{time}}\n\n{{message}}\n"
    text = A.render(text_tpl, ctx, escape=False)
    if suppressed > 0:
        text = "[%d repeat(s) suppressed since last alert]\n\n%s" % (suppressed, text)
    html_tpl = A.load_template(al.template, "html")
    html_body = None
    if html_tpl:
        html_body = A.render(html_tpl, ctx, escape=True)
        if suppressed > 0:
            html_body = "<p><em>%d repeat(s) suppressed since last alert</em></p>\n%s" \
                % (suppressed, html_body)
    return text, html_body


def deliver(settings, groups, al, ctx, suppressed, log, relays, order):
    subject = A.render(al.subject, ctx, escape=False)
    text, html_body = render_bodies(al, ctx, suppressed)
    to = A.resolve_recipients(al.recipients, groups)
    ok, used = A.send_mail(settings, to, subject, text, html_body,
                           relays=relays, order=order, chain=al.relay_chain, log=log)
    if ok:
        log.info("sent [%s] via %s -> %s : %s", al.name, used, ",".join(to), ctx["message"][:160])
    else:
        log.error("send failed [%s] -> %s : %s", al.name, ",".join(to), used)
    return ok


def handle(con, settings, groups, alerts, log, t, host, program, message, relays, order):
    al = classify(alerts, program, message)
    if al is None:
        return
    now = int(time.time())
    sig = al.signature(host, message)
    cur = con.cursor()
    row = cur.execute("SELECT * FROM dedup WHERE signature=?", (sig,)).fetchone()

    if row is None:
        cur.execute(
            "INSERT INTO dedup(signature,alert,host,first_seen,last_seen,"
            "last_sent,count,escalated,sample_msg,level) "
            "VALUES(?,?,?,?,?,?,?,?,?,?)",
            (sig, al.name, host, now, now, None, 1, 0, message, al.severity))
        last_sent, count = None, 1
    elif (now - row["last_seen"]) > settings["active_grace_sec"]:
        # quiet for a while -> treat as a brand new episode
        cur.execute(
            "UPDATE dedup SET first_seen=?, last_seen=?, last_sent=NULL, count=1, "
            "escalated=0, sample_msg=? WHERE signature=?", (now, now, message, sig))
        last_sent, count = None, 1
    else:
        cur.execute(
            "UPDATE dedup SET last_seen=?, count=count+1, sample_msg=? WHERE signature=?",
            (now, message, sig))
        last_sent, count = row["last_sent"], row["count"] + 1

    # digest-flagged alerts never email immediately; they queue for the sweeper
    if al.digest:
        grp = al.recipients if isinstance(al.recipients, str) \
            else (al.recipients[0] if al.recipients else "")
        cur.execute("INSERT INTO digest_queue(grp,alert,host,ts,message) VALUES(?,?,?,?,?)",
                    (grp, al.name, host, now, message))
        con.commit()
        log.debug("queued digest [%s] %s", al.name, host)
        return

    # dedup suppression window
    if last_sent is not None and (now - last_sent) < al.dedup_window:
        con.commit()
        log.debug("suppressed [%s] %s", al.name, sig)
        return

    suppressed = count - 1  # occurrences accumulated since the last email
    ctx = build_ctx(al, t, host, program, message, count)
    deliver(settings, groups, al, ctx, suppressed, log, relays, order)
    cur.execute("UPDATE dedup SET last_sent=?, count=0 WHERE signature=?", (now, sig))
    con.commit()


def parse_line(raw):
    parts = raw.rstrip("\n").split("|", 3)
    while len(parts) < 4:
        parts.append("")
    return parts[0], parts[1], parts[2], parts[3]


def daemon(log):
    settings, alerts, groups = A.load_config()
    order, relays = A.load_relays()
    con = A.db_connect()
    log.info("dispatcher start: %d alerts, %d relay(s) [%s]",
             len(alerts), len(relays), ",".join(order) or "local-sendmail")
    cfgs = (A.ALERTS_YAML, A.RECIPIENTS_YAML, A.RELAYS_YAML)
    mtime = max((os.path.getmtime(p) for p in cfgs if os.path.exists(p)), default=0.0)
    last_stat = 0.0
    for raw in iter(sys.stdin.readline, ""):
        try:
            now = time.time()
            if now - last_stat > 2.0:
                last_stat = now
                m = max((os.path.getmtime(p) for p in cfgs if os.path.exists(p)), default=0.0)
                if m != mtime:
                    mtime = m
                    try:
                        settings, alerts, groups = A.load_config()
                        order, relays = A.load_relays()
                        log.info("reloaded config: %d alerts, %d relay(s)", len(alerts), len(relays))
                    except Exception as e:
                        log.error("config reload failed, keeping previous: %s", e)
            if not raw.strip():
                continue
            t, host, program, message = parse_line(raw)
            handle(con, settings, groups, alerts, log, t, host, program, message, relays, order)
        except Exception:
            log.exception("error processing line")
    log.info("stdin closed; exiting")


def main(argv=None):
    ap = argparse.ArgumentParser(description="syslog alert dispatcher")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--test", metavar="MSG")
    ap.add_argument("--host", default="test-host")
    ap.add_argument("--program", default="test")
    args = ap.parse_args(argv)

    if args.check:
        try:
            settings, alerts, groups = A.load_config()
            order, relays = A.load_relays()
        except Exception as e:
            print("INVALID: %s" % e, file=sys.stderr)
            return 2
        print("OK: %d alert(s), %d recipient group(s), %d relay(s)"
              % (len(alerts), len(groups), len(relays)))
        if relays:
            print("  relay order: %s" % (", ".join(order) or "(none set)"))
            for n, r in relays.items():
                t = str(r.get("transport", "smtp"))
                if t == "sendmail":
                    print("    %-12s sendmail %s" % (n, r.get("sendmail", "(default)")))
                else:
                    print("    %-12s smtp %s:%s %s auth=%s"
                          % (n, r.get("host"), r.get("port", 25),
                             r.get("security", "none"), bool(r.get("auth"))))
        else:
            print("  (no relays.yaml -> local sendmail fallback)")
        for al in alerts:
            extra = []
            if al.digest:
                extra.append("digest")
            if al.relay_chain:
                extra.append("relay=%s" % ">".join(al.relay_chain))
            if al.escalation_after:
                extra.append("escalate->%s@%ss" % (al.escalation_group, al.escalation_after))
            print("  %-16s sev=%-8s -> %s  tpl=%s %s"
                  % (al.name, al.severity, al.recipients, al.template, " ".join(extra)))
        return 0

    if args.test is not None:
        settings, alerts, groups = A.load_config()
        order, relays = A.load_relays()
        al = classify(alerts, args.program, args.test)
        if al is None:
            print("NO MATCH (event would be ignored)")
            return 3
        ctx = build_ctx(al, time.strftime("%Y-%m-%dT%H:%M:%S"),
                        args.host, args.program, args.test, 1)
        subject = A.hdr_safe(A.render(al.subject, ctx), settings["subject_max"])
        text, html_body = render_bodies(al, ctx, 0)
        to = A.resolve_recipients(al.recipients, groups)
        chain = al.relay_chain or order or ["local-sendmail"]
        print("MATCH alert : %s (severity=%s, digest=%s)" % (al.name, al.severity, al.digest))
        print("To          : %s" % ", ".join(to))
        print("Relay chain : %s" % " -> ".join(chain))
        print("Subject     : %s" % subject)
        print("--- text ---\n%s" % text, end="")
        print("------------")
        if html_body:
            print("(HTML alternative: %d bytes)" % len(html_body))
        return 0

    log = A.setup_logging(LOG_FILE, os.environ.get("ALERT_LOG_LEVEL", "INFO"))
    try:
        daemon(log)
    except Exception:
        log.exception("fatal")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
__DISPATCHER_PY__
  backup "$SWEEPER"
  atomic_write "$SWEEPER" 0755 <<'__SWEEPER_PY__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
alert-sweeper.py -- time-driven companion to the dispatcher.

Run from cron (default every 5 min). Reads the same SQLite state and:
  * Escalation: an alert whose episode has been active longer than its
    'escalation_after' and is still firing gets sent once to its
    'escalation_group'.
  * Digests: digest-queued events are flushed as one summary per recipient
    group, no more often than 'digest_interval_sec'.
  * Pruning: dedup rows untouched for 'prune_after_sec' are dropped.

The dispatcher cannot do these itself: it only wakes when a log line
arrives, and these are time-based actions.
"""
import os
import sys
import time

sys.path.insert(0, os.environ.get("ALERT_LIB_DIR", "/usr/local/lib/alerts"))
import alertlib as A  # noqa: E402

LOG_FILE = os.environ.get("ALERT_SWEEP_LOG", "/var/log/alerts/sweeper.log")


def do_escalations(con, settings, groups, amap, log, now, relays, order):
    cur = con.cursor()
    for r in cur.execute("SELECT * FROM dedup WHERE escalated=0").fetchall():
        al = amap.get(r["alert"])
        if not al or not al.escalation_after or not al.escalation_group:
            continue
        active = (now - r["last_seen"]) <= settings["active_grace_sec"]
        old_enough = (now - r["first_seen"]) >= al.escalation_after
        if not (active and old_enough):
            continue
        mins = (now - r["first_seen"]) // 60
        ctx = {"alert": al.name, "host": r["host"], "severity": al.severity,
               "level": al.severity, "program": "", "count": str(r["count"]),
               "minutes": str(mins),
               "time": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now)),
               "message": r["sample_msg"] or ""}
        subject = "[ESCALATION] %s on %s unresolved %d min" % (al.name, r["host"], mins)
        base_txt = A.load_template(al.template, "txt") or "{{message}}\n"
        text = ("ESCALATION: %s on %s has been active for %d minutes "
                "(%d occurrences).\n\n%s"
                % (al.name, r["host"], mins, r["count"], A.render(base_txt, ctx)))
        html_body = None
        base_html = A.load_template(al.template, "html")
        if base_html:
            html_body = ("<p style='color:#b00'><strong>ESCALATION</strong>: %s on %s "
                         "active for %d min (%d occurrences).</p>\n%s"
                         % (A.h(al.name), A.h(r["host"]), mins, r["count"],
                            A.render(base_html, ctx, escape=True)))
        to = A.resolve_recipients(al.escalation_group, groups)
        ok, used = A.send_mail(settings, to, subject, text, html_body,
                               relays=relays, order=order, chain=al.relay_chain, log=log)
        if ok:
            cur.execute("UPDATE dedup SET escalated=1 WHERE signature=?", (r["signature"],))
            log.info("escalated [%s] %s via %s -> %s", al.name, r["host"], used, ",".join(to))
        else:
            log.error("escalation send failed [%s] %s: %s", al.name, r["host"], used)
    con.commit()


def build_digest(grp, items, now):
    by_alert = {}
    for it in items:
        by_alert.setdefault(it["alert"], []).append(it)
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(now))
    tlines = ["Alert digest for group '%s' at %s" % (grp, when),
              "%d event(s) since the last digest.\n" % len(items)]
    hparts = ["<html><body style='font-family:sans-serif'>",
              "<h2>Alert digest: %s</h2>" % A.h(grp),
              "<p>%d event(s) since the last digest.</p>" % len(items)]
    for alert, lst in sorted(by_alert.items()):
        tlines.append("%s (%d):" % (alert, len(lst)))
        hparts.append("<h3>%s <small>(%d)</small></h3><ul>" % (A.h(alert), len(lst)))
        for it in lst:
            ts = time.strftime("%H:%M:%S", time.localtime(it["ts"]))
            tlines.append("  %s  %s  %s" % (ts, it["host"], it["message"]))
            hparts.append("<li><code>%s</code> <b>%s</b> &mdash; %s</li>"
                          % (ts, A.h(it["host"]), A.h(it["message"])))
        tlines.append("")
        hparts.append("</ul>")
    hparts.append("</body></html>")
    return "\n".join(tlines) + "\n", "\n".join(hparts)


def flush_digest(con, settings, groups, log, now, relays, order):
    cur = con.cursor()
    row = cur.execute("SELECT v FROM meta WHERE k='last_digest'").fetchone()
    last_ts = int(row["v"]) if row else 0
    if now - last_ts < settings["digest_interval_sec"]:
        return
    items = cur.execute("SELECT * FROM digest_queue ORDER BY grp, alert, ts").fetchall()
    if items:
        by_grp = {}
        for it in items:
            by_grp.setdefault(it["grp"], []).append(it)
        for grp, lst in by_grp.items():
            text, html_body = build_digest(grp, lst, now)
            subject = "[DIGEST] %s: %d event(s)" % (grp, len(lst))
            to = A.resolve_recipients(grp, groups)
            ok, used = A.send_mail(settings, to, subject, text, html_body,
                                   relays=relays, order=order, log=log)
            if ok:
                log.info("digest grp=%s items=%d via %s -> %s", grp, len(lst), used, ",".join(to))
            else:
                log.error("digest send failed grp=%s: %s", grp, used)
        cur.execute("DELETE FROM digest_queue")
    cur.execute("INSERT OR REPLACE INTO meta(k,v) VALUES('last_digest',?)", (str(now),))
    con.commit()


def prune(con, settings, log, now):
    cur = con.cursor()
    cur.execute("DELETE FROM dedup WHERE last_seen < ?", (now - settings["prune_after_sec"],))
    if cur.rowcount:
        log.info("pruned %d stale dedup row(s)", cur.rowcount)
    con.commit()


def main(argv=None):
    log = A.setup_logging(LOG_FILE)
    try:
        settings, alerts, groups = A.load_config()
    except Exception:
        log.exception("config load failed")
        return 2
    con = A.db_connect()
    now = int(time.time())
    amap = {a.name: a for a in alerts}
    order, relays = A.load_relays()
    try:
        do_escalations(con, settings, groups, amap, log, now, relays, order)
        flush_digest(con, settings, groups, log, now, relays, order)
        prune(con, settings, log, now)
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
__SWEEPER_PY__
  backup "$ALERTRELAYS"
  atomic_write "$ALERTRELAYS" 0755 <<'__RELAYS_PY__'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
alert-relays.py -- manage the relay definitions in relays.yaml.

This tool NEVER handles passwords. It only records relay definitions and a
reference (secret_file / secret_cmd) to where the secret lives. The menu in
syslog-alert-router.sh writes the actual 0600 secret file.

Subcommands:
    list
    show NAME
    add  --name N --transport smtp --host H [--port P] [--security none|starttls|tls]
         [--from ADDR] [--auth --user U --secret-file PATH | --secret-cmd CMD]
         [--tls-no-verify]
    add  --name N --transport sendmail [--sendmail PATH]
    del  NAME
    set-order N1,N2,...
    check
"""
import os
import re
import sys
import argparse

sys.path.insert(0, os.environ.get("ALERT_LIB_DIR", "/usr/local/lib/alerts"))
import alertlib as A  # noqa: E402
import yaml  # noqa: E402

NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _load():
    if os.path.exists(A.RELAYS_YAML):
        doc = yaml.safe_load(open(A.RELAYS_YAML, encoding="utf-8")) or {}
    else:
        doc = {}
    doc.setdefault("relays", {})
    doc["relays"].setdefault("order", [])
    doc["relays"].setdefault("defs", {})
    return doc


def _save(doc):
    os.makedirs(os.path.dirname(A.RELAYS_YAML), exist_ok=True)
    tmp = A.RELAYS_YAML + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# Managed by alert-relays.py / syslog-alert-router.sh.\n")
        f.write("# Contains NO secrets -- only references (secret_file/secret_cmd).\n")
        yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
    os.chmod(tmp, 0o644)
    os.replace(tmp, A.RELAYS_YAML)


def cmd_list(a):
    doc = _load()
    order = doc["relays"]["order"]
    defs = doc["relays"]["defs"]
    print("Failover order: %s" % (", ".join(order) if order else "(none set)"))
    if not defs:
        print("  (no relays defined)")
    for n, r in defs.items():
        t = str(r.get("transport", "smtp"))
        if t == "sendmail":
            print("  %-14s sendmail  %s" % (n, r.get("sendmail", "(system default)")))
        else:
            print("  %-14s smtp  %s:%s  %s  auth=%s%s"
                  % (n, r.get("host"), r.get("port", 25), r.get("security", "none"),
                     bool(r.get("auth")),
                     "  secret=" + (r.get("secret_file") or r.get("secret_cmd") or "?")
                     if r.get("auth") else ""))
    return 0


def cmd_show(a):
    doc = _load()
    r = doc["relays"]["defs"].get(a.name)
    if not r:
        print("no such relay: %s" % a.name, file=sys.stderr)
        return 1
    yaml.safe_dump({a.name: r}, sys.stdout, default_flow_style=False, sort_keys=False)
    return 0


def cmd_add(a):
    if not NAME_RE.match(a.name):
        print("invalid name (use letters/digits/_/-)", file=sys.stderr)
        return 2
    doc = _load()
    rel = {"transport": a.transport}
    if a.transport == "sendmail":
        if a.sendmail:
            rel["sendmail"] = a.sendmail
    else:
        if not a.host:
            print("--host required for smtp", file=sys.stderr)
            return 2
        rel["host"] = a.host
        rel["port"] = int(a.port)
        rel["security"] = a.security
        if a.from_addr:
            rel["from"] = a.from_addr
        if a.tls_no_verify:
            rel["tls_verify"] = False
        if a.auth:
            rel["auth"] = True
            if not a.user:
                print("--user required with --auth", file=sys.stderr)
                return 2
            rel["user"] = a.user
            if a.secret_cmd:
                rel["secret_cmd"] = a.secret_cmd
            elif a.secret_file:
                rel["secret_file"] = a.secret_file
            else:
                print("--auth needs --secret-file or --secret-cmd", file=sys.stderr)
                return 2
    doc["relays"]["defs"][a.name] = rel
    if a.name not in doc["relays"]["order"]:
        doc["relays"]["order"].append(a.name)
    _save(doc)
    print("saved relay %s" % a.name)
    return 0


def cmd_del(a):
    doc = _load()
    if a.name in doc["relays"]["defs"]:
        del doc["relays"]["defs"][a.name]
    doc["relays"]["order"] = [n for n in doc["relays"]["order"] if n != a.name]
    _save(doc)
    print("removed relay %s" % a.name)
    return 0


def cmd_set_order(a):
    doc = _load()
    names = [s.strip() for s in a.order.split(",") if s.strip()]
    unknown = [n for n in names if n not in doc["relays"]["defs"]]
    if unknown:
        print("unknown relay(s): %s" % ", ".join(unknown), file=sys.stderr)
        return 2
    doc["relays"]["order"] = names
    _save(doc)
    print("order: %s" % ", ".join(names))
    return 0


def cmd_check(a):
    try:
        order, defs = A.load_relays()
    except Exception as e:
        print("INVALID: %s" % e, file=sys.stderr)
        return 2
    for n in order:
        if n not in defs:
            print("WARN: order references undefined relay %r" % n, file=sys.stderr)
    print("OK: %d relay(s), order=%s" % (len(defs), ",".join(order) or "(none)"))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    sp = sub.add_parser("show"); sp.add_argument("name")
    sp = sub.add_parser("add")
    sp.add_argument("--name", required=True)
    sp.add_argument("--transport", choices=["smtp", "sendmail"], default="smtp")
    sp.add_argument("--host"); sp.add_argument("--port", default="25")
    sp.add_argument("--security", choices=["none", "starttls", "tls"], default="none")
    sp.add_argument("--from", dest="from_addr")
    sp.add_argument("--auth", action="store_true")
    sp.add_argument("--user")
    sp.add_argument("--secret-file", dest="secret_file")
    sp.add_argument("--secret-cmd", dest="secret_cmd")
    sp.add_argument("--tls-no-verify", dest="tls_no_verify", action="store_true")
    sp.add_argument("--sendmail")
    sp = sub.add_parser("del"); sp.add_argument("name")
    sp = sub.add_parser("set-order"); sp.add_argument("order")
    sub.add_parser("check")
    a = p.parse_args(argv)
    return {
        "list": cmd_list, "show": cmd_show, "add": cmd_add, "del": cmd_del,
        "set-order": cmd_set_order, "check": cmd_check,
    }[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
__RELAYS_PY__
}

# =============================================================================
# bootstrap config + templates (never clobber existing files)
# =============================================================================
bootstrap_config() {
  info "Bootstrapping config + templates (preserving any existing)"
  write_if_missing "$ALERTS" 0644 <<'__ALERTS_YAML__'
# ============================================================================
#  alerts.yaml -- single source of truth for classification + routing.
#  Add/remove an alert here; if you change a 'regex' run:
#      syslog-alert-router.sh regen
#  Editing recipients/subject/template/severity is picked up live.
#
#  Per-alert keys:
#    regex            (required) Python regex, case-insensitive
#    program          optional regex gated against $PROGRAM
#    severity         critical|high|medium|low|info
#    recipients       group name (from recipients.yaml) or list of groups
#    template         base name in templates/ (loads <name>.txt + <name>.html,
#                     falls back to generic.*). Default: alert name lowercased.
#    subject          {{ var }} template; vars: alert host time program severity count
#    dedup_window     suppress identical signature within this (default 1h)
#    dedup_key        optional regex w/ capture group to split dedup (e.g. per IP)
#    digest: true     queue instead of emailing; sweeper sends a summary
#    escalation_after + escalation_group: notify another group if still active
# ============================================================================

settings:
  from: monitor@syslog.certifiedgeeks.net
  sendmail: /usr/sbin/sendmail
  dedup_window_sec: 1h
  digest_interval_sec: 1h
  active_grace_sec: 15m
  prune_after_sec: 7d

alerts:

  DISK_FULL:
    regex: 'filesystem full|No space left on device'
    severity: high
    recipients: storage
    template: disk_full
    subject: '[{{severity}}] DISK on {{host}}'
    dedup_window: 1h
    escalation_after: 4h
    escalation_group: management

  OOM:
    regex: 'oom-killer|Out of memory|memory used is over high threshold'
    severity: high
    recipients: ops
    dedup_window: 30m

  SSH_BRUTEFORCE:
    regex: 'Failed password|authentication failure|AAA user authentication'
    severity: high
    recipients: security
    template: ssh_bruteforce
    dedup_key: 'from\s+(\d+\.\d+\.\d+\.\d+)'
    dedup_window: 15m

  BACKUP_FAILED:
    regex: 'backup failed|backup error'
    severity: medium
    recipients: backup
    template: backup_failed
    escalation_after: 12h
    escalation_group: management

  INTERFACE_DOWN:
    regex: 'interface .* (down|link down)|link state changed to down'
    severity: low
    recipients: network
    digest: true

  DFS_RADAR:
    regex: 'radar was detected'
    severity: low
    recipients: network
    digest: true

  REBOOT:
    regex: 'Systool Rebooting|Kernel panic'
    severity: critical
    recipients: ops
    escalation_after: 30m
    escalation_group: management
__ALERTS_YAML__
  write_if_missing "$RECIP" 0644 <<'__RECIPIENTS_YAML__'
# Recipient groups. Reference these by name in alerts.yaml.
groups:
  ops:
    - ops@certifiedgeeks.net
  storage:
    - storage@certifiedgeeks.net
  security:
    - security@certifiedgeeks.net
  backup:
    - backup@certifiedgeeks.net
  network:
    - netops@certifiedgeeks.net
  management:
    - matt@certifiedgeeks.net
__RECIPIENTS_YAML__
  write_if_missing "$RELAYS_YAML" 0644 <<'__RELAYS_YAML__'
# ============================================================================
#  relays.yaml -- mail relays and failover order. Managed via:
#      syslog-alert-router.sh relays        (interactive menu)
#  or  alert-relays.py {list,add,del,set-order}
#
#  CONTAINS NO SECRETS. Authenticated relays reference a 0600 secret file
#  (or a secret_cmd). The dispatcher tries relays in 'order' until one accepts;
#  an alert may override with its own 'relay:'/'relays:' in alerts.yaml.
#
#  transport: smtp     host/port/security(none|starttls|tls)/from/auth/user/
#                      secret_file or secret_cmd / tls_verify
#  transport: sendmail pipes to a local MTA binary (default /usr/sbin/sendmail)
# ============================================================================
relays:
  order:
    - local
  defs:
    local:
      transport: sendmail
      sendmail: /usr/sbin/sendmail
__RELAYS_YAML__
  write_if_missing "$TPLDIR/backup_failed.txt" 0644 <<'__TPL_BACKUP_FAILED_TXT__'
BACKUP FAILURE on {{host}}

Time:    {{time}}
Details: {{message}}
__TPL_BACKUP_FAILED_TXT__
  write_if_missing "$TPLDIR/disk_full.html" 0644 <<'__TPL_DISK_FULL_HTML__'
<html><body style="font-family:sans-serif">
  <h2 style="color:#b00">Disk Space Alert</h2>
  <p>A filesystem on <b>{{host}}</b> is critically full.</p>
  <table cellpadding="4"><tr><td><b>Time</b></td><td>{{time}}</td></tr>
  <tr><td><b>Details</b></td><td>{{message}}</td></tr></table>
</body></html>
__TPL_DISK_FULL_HTML__
  write_if_missing "$TPLDIR/disk_full.txt" 0644 <<'__TPL_DISK_FULL_TXT__'
DISK SPACE ALERT on {{host}}

A filesystem is critically full. Investigate before services fail.

Time:    {{time}}
Details: {{message}}
__TPL_DISK_FULL_TXT__
  write_if_missing "$TPLDIR/generic.html" 0644 <<'__TPL_GENERIC_HTML__'
<html><body style="font-family:sans-serif;color:#222">
  <h2 style="margin-bottom:4px">{{alert}} <small style="color:#888">({{severity}})</small></h2>
  <table cellpadding="4" style="border-collapse:collapse">
    <tr><td><b>Host</b></td><td>{{host}}</td></tr>
    <tr><td><b>Program</b></td><td>{{program}}</td></tr>
    <tr><td><b>Time</b></td><td>{{time}}</td></tr>
  </table>
  <pre style="background:#f4f4f4;border:1px solid #ddd;padding:8px">{{message}}</pre>
</body></html>
__TPL_GENERIC_HTML__
  write_if_missing "$TPLDIR/generic.txt" 0644 <<'__TPL_GENERIC_TXT__'
Alert:    {{alert}}
Severity: {{severity}}
Host:     {{host}}
Program:  {{program}}
Time:     {{time}}

{{message}}
__TPL_GENERIC_TXT__
  write_if_missing "$TPLDIR/ssh_bruteforce.html" 0644 <<'__TPL_SSH_BRUTEFORCE_HTML__'
<html><body style="font-family:sans-serif">
  <h2 style="color:#b00">Authentication Brute Force</h2>
  <p>Repeated auth failures on <b>{{host}}</b>.</p>
  <pre style="background:#fff3f3;border:1px solid #f0c0c0;padding:8px">{{message}}</pre>
  <p style="color:#888">{{time}} &middot; {{program}}</p>
</body></html>
__TPL_SSH_BRUTEFORCE_HTML__
  write_if_missing "$TPLDIR/ssh_bruteforce.txt" 0644 <<'__TPL_SSH_BRUTEFORCE_TXT__'
SSH / AUTH BRUTE FORCE on {{host}}

Repeated authentication failures detected.

Time:    {{time}}
Program: {{program}}
Details: {{message}}
__TPL_SSH_BRUTEFORCE_TXT__
}

# =============================================================================
# preflight
# =============================================================================
preflight() {
  need_root
  command -v syslog-ng >/dev/null 2>&1 || die "syslog-ng not found."
  command -v python3   >/dev/null 2>&1 || die "python3 not found (need >= 3.6)."
  python3 - <<'PY' || die "Python 3.6+ required."
import sys; sys.exit(0 if sys.version_info[:2] >= (3,6) else 1)
PY
  [ -d "$CONFD" ] || die "syslog-ng conf.d not found: $CONFD"
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    if [ "$INSTALL_DEPS" = "1" ] && command -v apt-get >/dev/null 2>&1; then
      info "Installing python3-yaml..."; apt-get update -qq && apt-get install -y python3-yaml
    else
      die "PyYAML missing. Run: apt install python3-yaml   (or re-run with --install-deps)"
    fi
  fi
}

# =============================================================================
# mail transport (MTA)
# =============================================================================
detect_sendmail() {
  [ -x /usr/sbin/sendmail ] || command -v sendmail >/dev/null 2>&1
}

get_from() {
  if [ -f "$ALERTS" ]; then
    python3 - "$ALERTS" <<'PY' 2>/dev/null || echo "monitor@localhost"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print((d.get("settings") or {}).get("from") or "monitor@localhost")
PY
  else
    echo "monitor@$(hostname -f 2>/dev/null || hostname)"
  fi
}

write_msmtprc() {  # uses RELAY / RELAY_TLS / get_from
  local host="${RELAY%%:*}" port="25" from; from="$(get_from)"
  case "$RELAY" in *:*) port="${RELAY##*:}";; esac
  local tls="off" trust=""
  if [ "$RELAY_TLS" = "1" ]; then tls="on"; trust="tls_trust_file /etc/ssl/certs/ca-certificates.crt"; fi
  info "Writing /etc/msmtprc (relay $host:$port, auth off, tls $tls)"
  atomic_write /etc/msmtprc 0644 <<EOF
# Managed by syslog-alert-router.sh -- send-only relay, no credentials on disk.
# To use an authenticated relay instead, set 'auth on', add 'user NAME', and
# point 'passwordeval' at a 0600 secret (e.g. passwordeval "cat /etc/alerts/relay.pw").
defaults
auth           off
tls            $tls
$trust
logfile        $LOGDIR/msmtp.log

account        default
host           $host
port           $port
from           $from
EOF
}

install_msmtp() {
  [ -n "$RELAY" ] || die "msmtp needs a relay: pass --relay HOST[:PORT] (an SMTP relay that accepts mail from this box)."
  command -v apt-get >/dev/null 2>&1 || die "apt-get unavailable; install 'msmtp msmtp-mta' manually, then re-run setup-mta."
  info "Installing msmtp + msmtp-mta..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp msmtp-mta
  write_msmtprc
  detect_sendmail || die "msmtp-mta did not provide /usr/sbin/sendmail."
  info "msmtp ready; /usr/sbin/sendmail now relays to $RELAY."
}

install_postfix() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get unavailable; install postfix manually."
  command -v debconf-set-selections >/dev/null 2>&1 || die "debconf-set-selections missing."
  local mailname; mailname="$(hostname -f 2>/dev/null || hostname)"
  if [ -n "$RELAY" ]; then
    local host="${RELAY%%:*}" port="25"; case "$RELAY" in *:*) port="${RELAY##*:}";; esac
    echo "postfix postfix/main_mailer_type select Satellite system" | debconf-set-selections
    echo "postfix postfix/relayhost string [$host]:$port" | debconf-set-selections
    info "Postfix as satellite -> relay [$host]:$port"
  else
    echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
    warn "Postfix will deliver DIRECTLY (no relay). SOHO IPs are frequently spam-filtered; --relay is far more reliable."
  fi
  echo "postfix postfix/mailname string $mailname" | debconf-set-selections
  info "Installing postfix (noninteractive)..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
  detect_sendmail || die "postfix did not provide /usr/sbin/sendmail."
  command -v systemctl >/dev/null 2>&1 && systemctl enable --now postfix >/dev/null 2>&1 || true
  info "postfix ready."
}

ensure_mta() {
  if detect_sendmail; then
    info "MTA present; reusing existing $(command -v sendmail 2>/dev/null || echo /usr/sbin/sendmail)."
    return 0
  fi
  warn "No local MTA found (nothing provides /usr/sbin/sendmail)."
  case "$MTA" in
    msmtp)   install_msmtp;;
    postfix) install_postfix;;
    "")      MTA_MISSING=1
             warn "No --mta chosen: the framework installs fine but CANNOT send mail yet.";;
    *)       die "Unknown --mta '$MTA' (use: msmtp or postfix).";;
  esac
}

# =============================================================================
# generate the syslog-ng coarse filter from alerts.yaml
# =============================================================================
generate_fragment() {
  info "Generating syslog-ng fragment from $ALERTS"
  local tmp; tmp="$(mktemp "${FRAGMENT}.tmp.XXXXXX")"
  DISPATCH="$DISPATCH" SYSLOG_SOURCE="$SYSLOG_SOURCE" \
  python3 - "$ALERTS" <<'PYGEN' > "$tmp"
import sys, os, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
pats = [a["regex"] for a in (doc.get("alerts") or {}).values()
        if isinstance(a, dict) and a.get("regex")]
if not pats:
    sys.stderr.write("no regex patterns in alerts.yaml\n"); sys.exit(1)
disp = os.environ["DISPATCH"]; src = os.environ["SYSLOG_SOURCE"]
def esc(p): return p.replace("\\", "\\\\").replace('"', '\\"')
terms = ['    message("%s" type(pcre) flags(ignore-case))' % esc(p) for p in pats]
print("# AUTO-GENERATED by syslog-alert-router.sh -- do not edit by hand.")
print("# Source of truth: %s   Regenerate: syslog-alert-router.sh regen" % sys.argv[1])
print("# Requires source(%s) defined elsewhere in the syslog-ng config." % src)
print()
print("filter f_alert_coarse {")
print(" or\n".join(terms) + ";")
print("};")
print()
print("destination d_alert_dispatch {")
print('    program("%s"' % disp)
print('        template("$ISODATE|$HOST|$PROGRAM|$MESSAGE\\n"));')
print("};")
print()
print("log { source(%s); filter(f_alert_coarse); destination(d_alert_dispatch); };" % src)
PYGEN
  backup "$FRAGMENT"; chmod 0644 "$tmp"; mv -f -- "$tmp" "$FRAGMENT"
  info "Validating syslog-ng configuration..."
  if ! validate_syslogng; then
    err "syslog-ng config validation FAILED."
    if ls "${FRAGMENT}.bak."* >/dev/null 2>&1; then
      cp -a -- "$(ls -1t "${FRAGMENT}.bak."* | head -n1)" "$FRAGMENT"; warn "Restored previous fragment."
    else rm -f -- "$FRAGMENT"; warn "Removed bad fragment."; fi
    die "Fix alerts.yaml and re-run. Running syslog-ng was NOT touched."
  fi
  info "Config valid."
}

install_cron() {
  info "Installing sweeper cron -> $CRON"
  atomic_write "$CRON" 0644 <<EOF
# alert-sweeper: escalations, digests, pruning. Managed by syslog-alert-router.sh
# Time-driven work the stdin dispatcher can't do on its own.
*/5 * * * * root $SWEEPER >/dev/null 2>&1
EOF
}

# =============================================================================
# subcommands
# =============================================================================
cmd_install() {
  preflight
  mkdir -p "$LIBDIR" "$CFGDIR" "$TPLDIR" "$DBDIR" "$LOGDIR"
  chmod 0755 "$DBDIR" "$LOGDIR"
  ensure_secrets_dir
  write_code
  bootstrap_config
  ensure_mta
  info "Validating config..."
  python3 "$DISPATCH" --check || die "Config failed validation; aborting before touching syslog-ng."
  generate_fragment
  install_cron
  reload_syslogng
  info "Install complete (v$VERSION)."
  if [ "$MTA_MISSING" = "1" ]; then
    cat <<EOF

*** MAIL NOT YET CONFIGURED ***
Nothing provides /usr/sbin/sendmail, so alerts cannot be delivered. Pick one:

  # Lightweight relay (recommended; no daemon, no credentials):
  $0 setup-mta --mta msmtp --relay YOUR_RELAY_HOST[:PORT]

  # Or Postfix (satellite via relay, or direct Internet Site if --relay omitted):
  $0 setup-mta --mta postfix --relay YOUR_RELAY_HOST[:PORT]

YOUR_RELAY_HOST = an SMTP relay that accepts mail from this box without auth
(e.g. an internal mail server, or a provider relay with this IP allowlisted).
Then confirm:   $0 mailtest you@certifiedgeeks.net
EOF
  fi
  cat <<EOF

Next steps:
  1. Edit recipients:   $RECIP
  2. Configure relays:  $0 relays           (interactive; add SMTP relays + secured creds)
  3. Confirm mail path: $0 mailtest you@certifiedgeeks.net
  4. Dry-run a rule:    $0 test "kernel: Out of memory: Killed process 1 (mysqld)"
  5. Avoid DUPLICATES:  legacy d_sendpage still fires; when satisfied: $0 disable-legacy
EOF
}

cmd_setup_mta() {
  need_root
  case "$MTA" in
    msmtp)   install_msmtp;;
    postfix) install_postfix;;
    "")      if detect_sendmail; then
               info "MTA already present: $(command -v sendmail 2>/dev/null || echo /usr/sbin/sendmail). Nothing to do."
             else
               die "No MTA present. Specify one: $0 setup-mta --mta msmtp --relay HOST[:PORT]"
             fi;;
    *)       die "Unknown --mta '$MTA' (use: msmtp or postfix).";;
  esac
}

cmd_mailtest() {
  local to="${1:-}"
  [ -n "$to" ] || die "Usage: $0 mailtest [--relay NAME] you@example.com"
  ALERT_LIB_DIR="$LIBDIR" ALERT_CONFIG_DIR="$CFGDIR" ALERT_TEMPLATE_DIR="$TPLDIR" \
  ALERT_SECRETS_DIR="$SECRETS" RELAY_NAME="$RELAY" \
    python3 - "$to" <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("ALERT_LIB_DIR", "/usr/local/lib/alerts"))
import alertlib as A
settings, _, _ = A.load_config()
order, relays = A.load_relays()
name = os.environ.get("RELAY_NAME") or ""
chain = [name] if name else None
ok, used = A.send_mail(settings, [sys.argv[1]],
                       "[TEST] syslog-alert-router mail path",
                       "If you can read this, the alert mail path works (relay: %s).\n" % (name or "default chain"),
                       "<p>If you can read this, the alert mail path works.</p>",
                       relays=relays, order=order, chain=chain, log=None)
print("OK: delivered via relay '%s'" % used if ok else "FAIL: %s" % used)
sys.exit(0 if ok else 1)
PY
}

# ---- interactive relay manager ---------------------------------------------
_menu_add_relay() {
  local name tr host port sec frm ver au user noverify authargs sfile smp
  printf 'relay name> '; read -r name; [ -n "$name" ] || { echo "name required"; return; }
  printf 'transport [smtp/sendmail] (smtp)> '; read -r tr; tr="${tr:-smtp}"
  if [ "$tr" = "sendmail" ]; then
    printf 'sendmail path (blank = system default)> '; read -r smp
    python3 "$ALERTRELAYS" add --name "$name" --transport sendmail ${smp:+--sendmail "$smp"}
    return
  fi
  printf 'host> '; read -r host; [ -n "$host" ] || { echo "host required"; return; }
  printf 'port (25)> '; read -r port; port="${port:-25}"
  printf 'security [none/starttls/tls] (starttls)> '; read -r sec; sec="${sec:-starttls}"
  printf 'envelope from (blank = use global)> '; read -r frm
  printf 'verify TLS certificate? [Y/n]> '; read -r ver
  noverify=""; case "$ver" in n|N) noverify="--tls-no-verify";; esac
  authargs=""
  printf 'requires authentication? [Y/n]> '; read -r au
  case "$au" in
    n|N) : ;;
    *) printf 'username> '; read -r user
       [ -n "$user" ] || { echo "username required for auth"; return; }
       sfile="$(write_secret "$name")" || { echo "password not set; relay not added"; return; }
       authargs="--auth --user $user --secret-file $sfile";;
  esac
  python3 "$ALERTRELAYS" add --name "$name" --transport smtp --host "$host" \
    --port "$port" --security "$sec" ${frm:+--from "$frm"} $noverify $authargs
}

_menu_set_password() {
  local name; printf 'relay name> '; read -r name
  [ -n "$name" ] || { echo "name required"; return; }
  local p; p="$(write_secret "$name")" && info "Secret written to $p (referenced as secret_file)."
}

_menu_set_order() {
  python3 "$ALERTRELAYS" list
  printf 'new order (comma-separated names)> '; read -r ord
  [ -n "$ord" ] && python3 "$ALERTRELAYS" set-order "$ord"
}

_menu_del_relay() {
  local name rm; printf 'relay name to delete> '; read -r name
  [ -n "$name" ] || return
  python3 "$ALERTRELAYS" del "$name"
  if [ -f "$SECRETS/$name.pw" ]; then
    printf 'also delete its secret file %s? [y/N]> ' "$SECRETS/$name.pw"; read -r rm
    case "$rm" in y|Y) rm -f "$SECRETS/$name.pw"; info "secret removed";; esac
  fi
}

_menu_test_relay() {
  local name addr; printf 'relay name (blank = default chain)> '; read -r name
  printf 'send test to> '; read -r addr; [ -n "$addr" ] || return
  RELAY="$name" cmd_mailtest "$addr"
}

cmd_relays() {
  need_root
  [ -x "$ALERTRELAYS" ] || die "Relay manager not installed; run '$0 install' first."
  ensure_secrets_dir
  while true; do
    echo; echo "================ Relay Manager ================"
    python3 "$ALERTRELAYS" list
    echo "-----------------------------------------------"
    echo "  a) add relay      o) set failover order"
    echo "  p) set password   d) delete relay"
    echo "  t) test relay     q) quit"
    printf 'choose> '; read -r choice
    case "$choice" in
      a|A) _menu_add_relay;;
      o|O) _menu_set_order;;
      p|P) _menu_set_password;;
      d|D) _menu_del_relay;;
      t|T) _menu_test_relay;;
      q|Q|"") break;;
      *) echo "unknown option";;
    esac
  done
  python3 "$ALERTRELAYS" check || warn "relays.yaml has issues; review above."
  info "Done. The dispatcher picks up relay changes within ~2s (no reload needed)."
}

cmd_regen() {
  preflight
  [ -e "$ALERTS" ] || die "No $ALERTS (run 'install' first)."
  python3 "$DISPATCH" --check || die "Config invalid; not regenerating."
  generate_fragment; reload_syslogng
  info "Filter regenerated and syslog-ng reloaded."
}

cmd_test() {
  local msg="${1:-}"; local prog="${2:-test}"
  [ -n "$msg" ] || die "Usage: $0 test \"<log message>\" [program]"
  python3 "$DISPATCH" --test "$msg" --program "$prog"
}

cmd_check() { python3 "$DISPATCH" --check; }
cmd_sweep() { need_root; python3 "$SWEEPER"; info "Sweep complete (see $LOGDIR/sweeper.log)."; }

cmd_disable_legacy() {
  need_root
  local remote="$CONFD/remote.conf"
  [ -e "$remote" ] || die "Not found: $remote"
  backup "$remote"
  REMOTE="$remote" python3 - <<'PYDL'
import os, re, sys
p = os.environ["REMOTE"]; src = open(p).read()
pat = re.compile(r'(?ms)^(\s*log\s*\{(?:(?!\}).)*?destination\s*\(\s*d_sendpage\s*\).*?\}\s*;)')
m = pat.search(src)
if not m:
    sys.stderr.write("Could not find the legacy 'log { ... d_sendpage ... };' block; comment it out manually.\n")
    sys.exit(1)
blk = m.group(1)
out = "\n".join(("# "+ln) if ln.strip() else ln for ln in blk.splitlines())
open(p,"w").write(src[:m.start(1)] + "# [disabled by syslog-alert-router]\n" + out + src[m.end(1):])
print("Commented out the legacy d_sendpage log block.")
PYDL
  info "Validating..."; validate_syslogng || die "Validation failed; restore from the .bak just created."
  reload_syslogng; info "Legacy single-recipient path disabled."
}

cmd_uninstall() {
  need_root
  info "Removing fragment, cron, and code (config / secrets / DB / logs are kept)."
  backup "$FRAGMENT"; rm -f -- "$FRAGMENT" "$CRON" "$DISPATCH" "$SWEEPER" "$ALERTRELAYS" "$ALERTLIB"
  validate_syslogng && reload_syslogng || warn "Validate/reload skipped or failed; check syslog-ng."
  info "Uninstalled. Config at $CFGDIR, secrets at $SECRETS, state at $DBDIR, logs at $LOGDIR remain."
}

usage() {
  cat <<EOF
syslog-alert-router.sh v$VERSION

  install [--install-deps] [--mta msmtp|postfix --relay HOST[:PORT]] [--relay-tls]
                            Install code, config, filter, cron, reload.
  relays                    Interactive menu: add/edit/test relays + secured creds
  mailtest [--relay NAME] ADDR
                            Send a test email (optionally via a specific relay)
  setup-mta --mta msmtp|postfix [--relay HOST[:PORT]] [--relay-tls]
                            Install a local send-only MTA (for the 'local' relay)
  regen                     Rebuild the coarse syslog-ng filter from alerts.yaml
  test "<msg>" [program]    Dry-run classification + rendered email (no send)
  check                     Validate the YAML config
  sweep                     Run the escalation/digest/prune sweep once now
  disable-legacy            Comment out the old single-recipient d_sendpage block
  uninstall                 Remove code + fragment + cron (keeps config/secrets/DB/logs)
  version | help

Relays: multiple SMTP/sendmail relays with a failover 'order'; alerts may override
via 'relay:'/'relays:' in alerts.yaml. Credentials live in $SECRETS/<name>.pw (0600);
relays.yaml holds only references, never passwords.
EOF
}

main() {
  local cmd="${1:-install}"; shift || true
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --install-deps) INSTALL_DEPS=1;;
      --mta)          MTA="${2:-}"; shift;;
      --mta=*)        MTA="${1#*=}";;
      --relay)        RELAY="${2:-}"; shift;;
      --relay=*)      RELAY="${1#*=}";;
      --relay-tls)    RELAY_TLS=1;;
      *)              positional+=("$1");;
    esac
    shift
  done
  set -- ${positional[@]+"${positional[@]}"}
  case "$cmd" in
    install)               cmd_install "$@";;
    relays)                cmd_relays "$@";;
    mailtest)              cmd_mailtest "$@";;
    setup-mta)             cmd_setup_mta "$@";;
    regen|regen-filter)    cmd_regen "$@";;
    test)                  cmd_test "$@";;
    check)                 cmd_check "$@";;
    sweep)                 cmd_sweep "$@";;
    disable-legacy)        cmd_disable_legacy "$@";;
    uninstall)             cmd_uninstall "$@";;
    version|--version)     echo "$VERSION";;
    help|-h|--help)        usage;;
    *) usage; die "Unknown command: $cmd";;
  esac
}

main "$@"
