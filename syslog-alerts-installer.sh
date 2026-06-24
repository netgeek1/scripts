#!/usr/bin/env bash
set -euo pipefail

#############################################
# Syslog Alerts Platform - AIO Installer
# Version: 1.0.0
#############################################

APP_NAME="syslog-alerts"
INSTALL_DIR="/opt/syslog-alerts"
APP_USER="syslogalerts"
PYTHON_BIN="/usr/bin/python3"

#############################################
# Detect OS
#############################################

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        echo "Cannot detect OS"
        exit 1
    fi

    echo "[INFO] Detected OS: $OS $VER"
}

#############################################
# Dependencies
#############################################

install_deps() {
    echo "[INFO] Installing dependencies..."

    apt update -y

    apt install -y \
        syslog-ng \
        postfix \
        mailutils \
        python3 \
        python3-pip \
        python3-venv \
        sqlite3 \
        jq \
        curl \
        openssl

    pip3 install --upgrade pip

    pip3 install \
        pyyaml \
        jinja2 \
        fastapi \
        uvicorn \
        aiosmtplib

    echo "[OK] Dependencies installed"
}

#############################################
# User creation
#############################################

create_user() {
    if ! id "$APP_USER" &>/dev/null; then
        useradd --system --home "$INSTALL_DIR" --shell /bin/bash "$APP_USER"
        echo "[OK] User created: $APP_USER"
    else
        echo "[INFO] User already exists"
    fi
}

#############################################
# Directory structure
#############################################

create_dirs() {
    echo "[INFO] Creating directories..."

    mkdir -p $INSTALL_DIR/{bin,config,templates,patterns,database,logs,backups,reports,plugins}

    chown -R $APP_USER:$APP_USER $INSTALL_DIR

    echo "[OK] Directories created"
}

#############################################
# SQLite init
#############################################

init_db() {
    echo "[INFO] Initializing SQLite DB..."

    cat <<EOF > $INSTALL_DIR/database/schema.sql
CREATE TABLE IF NOT EXISTS alerts (
    id INTEGER PRIMARY KEY,
    timestamp TEXT,
    host TEXT,
    site TEXT,
    alert_type TEXT,
    severity TEXT,
    message TEXT,
    status TEXT
);

CREATE TABLE IF NOT EXISTS alert_state (
    signature TEXT PRIMARY KEY,
    state TEXT,
    last_seen TEXT
);
EOF

    sqlite3 $INSTALL_DIR/database/alerts.db < $INSTALL_DIR/database/schema.sql

    chown $APP_USER:$APP_USER $INSTALL_DIR/database/alerts.db

    echo "[OK] Database initialized"
}

#############################################
# Postfix setup (relay prompt)
#############################################

configure_postfix() {
    echo "[INFO] Configuring Postfix relay..."

    read -p "SMTP Relay Host: " SMTP_HOST
    read -p "SMTP Port [587]: " SMTP_PORT
    SMTP_PORT=${SMTP_PORT:-587}

    postconf -e "relayhost = [$SMTP_HOST]:$SMTP_PORT"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_use_tls = yes"

    echo "[$SMTP_HOST]:$SMTP_PORT user:pass" > /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd

    systemctl restart postfix

    echo "[OK] Postfix configured"
}

#############################################
# syslog-ng config stub
#############################################

configure_syslog() {
    echo "[INFO] Configuring syslog-ng..."

    cat <<EOF > /etc/syslog-ng/conf.d/syslog-alerts.conf

destination d_syslog_alerts {
    program("$INSTALL_DIR/bin/alert-dispatcher.py");
};

log {
    source(s_src);
    destination(d_syslog_alerts);
};
EOF

    systemctl restart syslog-ng

    echo "[OK] syslog-ng configured"
}

#############################################
# Systemd services
#############################################

create_services() {

    echo "[INFO] Creating systemd services..."

    cat <<EOF > /etc/systemd/system/syslog-alert-dispatcher.service
[Unit]
Description=Syslog Alerts Dispatcher
After=network.target

[Service]
ExecStart=$PYTHON_BIN $INSTALL_DIR/bin/alert-dispatcher.py
Restart=always
User=$APP_USER

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/syslog-alert-maintenance.service
[Unit]
Description=Syslog Alerts Maintenance

[Service]
Type=oneshot
ExecStart=$PYTHON_BIN $INSTALL_DIR/bin/maintenance.py
User=$APP_USER
EOF

    systemctl daemon-reload

    systemctl enable syslog-alert-dispatcher.service

    echo "[OK] Services created"
}

#############################################
# Stub Python modules
#############################################

create_stubs() {

echo "[INFO] Creating stub modules..."

cat <<'''EOF''' > $INSTALL_DIR/bin/alert-dispatcher.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Alert Dispatcher
Version: 1.0.0
"""

import sys
import re
from datetime import datetime

from config import config
from database import db
from smtp import smtp_client

from jinja2 import Template


class AlertDispatcher:

    def __init__(self):
        self.cfg = config()
        self.db = db()
        self.mail = smtp_client()

    # ----------------------------
    # Entry Point (syslog-ng input)
    # ----------------------------

    def run(self):
        """
        Reads syslog-ng piped input:
        expected format:
        timestamp|host|program|message
        """

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            try:
                self.process_line(line)
            except Exception as e:
                self.db.audit("system", "DISPATCH_ERROR", str(e))

    # ----------------------------
    # Parse syslog line
    # ----------------------------

    def parse(self, line):
        parts = line.split("|", 3)

        if len(parts) != 4:
            raise ValueError(f"Invalid syslog format: {line}")

        return {
            "timestamp": parts[0],
            "host": parts[1],
            "program": parts[2],
            "message": parts[3]
        }

    # ----------------------------
    # Main processing pipeline
    # ----------------------------

    def process_line(self, line):
        event = self.parse(line)

        alerts = self.cfg.get_alerts()

        for name, rule in alerts.items():
            if not self.match(rule, event["message"]):
                continue

            self.handle_alert(name, rule, event)

    # ----------------------------
    # Matching engine
    # ----------------------------

    def match(self, rule, message):
        patterns = rule.get("regex", [])

        if isinstance(patterns, str):
            patterns = [patterns]

        for pattern in patterns:
            if re.search(pattern, message):
                return True

        return False

    # ----------------------------
    # Alert handler
    # ----------------------------

    def handle_alert(self, alert_name, rule, event):

        severity = rule.get("severity", "INFO")
        site = rule.get("site", "default")
        dedup_minutes = rule.get("dedup_minutes", 60)

        signature = f"{event['host']}:{alert_name}"

        # ------------------------
        # Deduplication
        # ------------------------

        if self.db.should_suppress(signature, dedup_minutes * 60):
            self.db.record_history(0, "SUPPRESSED", signature)
            return

        # ------------------------
        # State tracking
        # ------------------------

        state = self.db.get_alert_state(signature)

        if state and state["state"] == "ACTIVE":
            # already active, just update last_seen
            self.db.set_alert_state(signature, event["host"], alert_name, "ACTIVE")
            return

        # ------------------------
        # Insert alert
        # ------------------------

        self.db.insert_alert(
            event["host"],
            site,
            alert_name,
            severity,
            event["message"]
        )

        alert_id = self.db.fetchone(
            "SELECT last_insert_rowid() AS id"
        )["id"]

        self.db.set_alert_state(signature, event["host"], alert_name, "ACTIVE")

        self.db.record_history(alert_id, "RECEIVED", event["message"])

        # ------------------------
        # Notify
        # ------------------------

        self.notify(alert_id, alert_name, rule, event)

    # ----------------------------
    # Notification engine
    # ----------------------------

    def notify(self, alert_id, alert_name, rule, event):

        profile_name = rule.get("notification_profile", "default")

        # recipients
        site = rule.get("site", "default")
        group = rule.get("recipient_group", "default")

        recipients = self.cfg.resolve_recipients(site, group)

        if not recipients:
            self.db.audit("system", "NO_RECIPIENTS", alert_name)
            return

        # template
        template_name = rule.get("template", "generic.html")

        html = self.render_template(template_name, event, rule)

        subject = f"[{rule.get('severity','INFO')}] {alert_name} on {event['host']}"

        # send email
        self.mail.send_email(
            profile_name,
            recipients,
            subject,
            html
        )

        self.db.record_history(alert_id, "NOTIFIED", f"Sent to {recipients}")

    # ----------------------------
    # Template rendering
    # ----------------------------

    def render_template(self, template_name, event, rule):

        path = f"/opt/syslog-alerts/templates/{template_name}"

        try:
            with open(path, "r") as f:
                tpl = Template(f.read())

            return tpl.render(
                host=event["host"],
                message=event["message"],
                timestamp=event["timestamp"],
                severity=rule.get("severity"),
                alert_type=rule.get("alert_type")
            )

        except Exception as e:
            return f"<pre>Template error: {e}</pre>"


# ----------------------------
# Main
# ----------------------------

if __name__ == "__main__":
    dispatcher = AlertDispatcher()
    dispatcher.run()
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/config.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Config Engine
Version: 1.0.0
"""

import os
import yaml
import time
from threading import RLock

INSTALL_DIR = "/opt/syslog-alerts"
CONFIG_DIR = os.path.join(INSTALL_DIR, "config")


class ConfigError(Exception):
    pass


class Config:
    """
    Central configuration loader with caching + validation.
    """

    _instance = None
    _lock = RLock()
    _cache = {}
    _last_load = 0
    _cache_ttl = 5  # seconds

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(Config, cls).__new__(cls)
        return cls._instance

    # ----------------------------
    # Public API
    # ----------------------------

    def get(self, key, default=None):
        data = self.load()
        return data.get(key, default)

    def load(self, force_reload=False):
        with self._lock:
            now = time.time()

            if (
                not force_reload
                and self._cache
                and (now - self._last_load) < self._cache_ttl
            ):
                return self._cache

            config = {}

            config_files = {
                "alerts": "alerts.yaml",
                "recipients": "recipients.yaml",
                "sites": "sites.yaml",
                "smtp": "smtp.yaml",
                "notification_profiles": "notification_profiles.yaml",
                "escalation": "escalation.yaml",
                "digest": "digest.yaml",
                "retention": "retention.yaml",
                "secrets": "secrets.yaml",
            }

            for key, file in config_files.items():
                path = os.path.join(CONFIG_DIR, file)
                config[key] = self._load_yaml(path)

            self._validate(config)

            self._cache = config
            self._last_load = now

            return config

    # ----------------------------
    # YAML Loader
    # ----------------------------

    def _load_yaml(self, path):
        if not os.path.exists(path):
            return {}

        try:
            with open(path, "r") as f:
                return yaml.safe_load(f) or {}
        except Exception as e:
            raise ConfigError(f"Failed to load {path}: {str(e)}")

    # ----------------------------
    # Validation Layer
    # ----------------------------

    def _validate(self, config):
        """
        Basic sanity checks to prevent runtime failures.
        """

        # SMTP must exist
        smtp = config.get("smtp", {})
        if not smtp:
            raise ConfigError("SMTP configuration missing")

        # Alerts must exist
        alerts = config.get("alerts", {}).get("alerts", {})
        if not isinstance(alerts, dict):
            raise ConfigError("Invalid alerts configuration")

        # Notification profiles optional but normalized
        if "notification_profiles" not in config:
            config["notification_profiles"] = {}

        # Sites optional
        if "sites" not in config:
            config["sites"] = {}

        # Secrets file should always exist (even if empty)
        if "secrets" not in config:
            config["secrets"] = {}

        # Ensure alert structure integrity
        for name, alert in alerts.items():
            if "severity" not in alert:
                alert["severity"] = "INFO"

            if "regex" not in alert:
                raise ConfigError(f"Alert {name} missing regex")

    # ----------------------------
    # Helper Accessors
    # ----------------------------

    def get_alerts(self):
        return self.load().get("alerts", {}).get("alerts", {})

    def get_smtp_profiles(self):
        smtp = self.load().get("smtp", {})
        return smtp.get("smtp_profiles", {})

    def get_notification_profiles(self):
        return self.load().get("notification_profiles", {}).get("notification_profiles", {})

    def get_sites(self):
        return self.load().get("sites", {}).get("sites", {})

    def get_secrets(self):
        return self.load().get("secrets", {})

    # ----------------------------
    # Resolution Logic
    # ----------------------------

    def resolve_notification_profile(self, alert):
        """
        Determine which notification profile an alert uses.
        """

        profiles = self.get_notification_profiles()

        profile_name = alert.get("notification_profile", "default")

        return profiles.get(profile_name, profiles.get("default", {}))

    def resolve_smtp_profile(self, profile):
        """
        Resolve SMTP profile from notification profile.
        """

        smtp_profiles = self.get_smtp_profiles()

        smtp_name = profile.get("smtp_profile", "default")

        return smtp_profiles.get(smtp_name, smtp_profiles.get("default", {}))

    def resolve_recipients(self, site, group):
        """
        Get recipients for site + group combination.
        """

        recipients = self.load().get("recipients", {}).get("recipient_groups", {})

        site_data = recipients.get(site, {})
        return site_data.get(group, [])


# ----------------------------
# Singleton accessor
# ----------------------------

_config_instance = Config()

def config():
    return _config_instance


# ----------------------------
# CLI debug
# ----------------------------

if __name__ == "__main__":
    c = config().load(force_reload=True)
    print(yaml.dump(c, default_flow_style=False))
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/database.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Database Layer
Version: 1.0.0
"""

import os
import sqlite3
import threading
from datetime import datetime

INSTALL_DIR = "/opt/syslog-alerts"
DB_PATH = os.path.join(INSTALL_DIR, "database", "alerts.db")
SCHEMA_PATH = os.path.join(INSTALL_DIR, "database", "schema.sql")


class DatabaseError(Exception):
    pass


class Database:
    """
    Thread-safe SQLite wrapper for alert state, history, and audit logs.
    """

    _instance = None
    _lock = threading.Lock()

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(Database, cls).__new__(cls)
            cls._instance._init_db()
        return cls._instance

    # ----------------------------
    # Initialization
    # ----------------------------

    def _init_db(self):
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

        self.conn = sqlite3.connect(
            DB_PATH,
            check_same_thread=False,
            isolation_level=None
        )
        self.conn.row_factory = sqlite3.Row

        self._apply_schema()

    def _apply_schema(self):
        if not os.path.exists(SCHEMA_PATH):
            raise DatabaseError("Schema file missing")

        with open(SCHEMA_PATH, "r") as f:
            schema_sql = f.read()

        with self.conn:
            self.conn.executescript(schema_sql)

    # ----------------------------
    # Core helpers
    # ----------------------------

    def execute(self, query, params=()):
        with self._lock:
            cur = self.conn.cursor()
            cur.execute(query, params)
            return cur

    def fetchone(self, query, params=()):
        cur = self.execute(query, params)
        return cur.fetchone()

    def fetchall(self, query, params=()):
        cur = self.execute(query, params)
        return cur.fetchall()

    # ----------------------------
    # Alert State Tracking
    # ----------------------------

    def get_alert_state(self, signature):
        return self.fetchone(
            "SELECT * FROM alert_state WHERE signature = ?",
            (signature,)
        )

    def set_alert_state(self, signature, host, alert_type, state):
        now = datetime.utcnow().isoformat()

        existing = self.get_alert_state(signature)

        if existing:
            self.execute(
                """
                UPDATE alert_state
                SET state = ?, last_seen = ?
                WHERE signature = ?
                """,
                (state, now, signature)
            )
        else:
            self.execute(
                """
                INSERT INTO alert_state (signature, host, alert_type, state, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (signature, host, alert_type, state, now, now)
            )

    # ----------------------------
    # Alert Logging
    # ----------------------------

    def insert_alert(self, host, site, alert_type, severity, message):
        now = datetime.utcnow().isoformat()

        self.execute(
            """
            INSERT INTO alerts (timestamp, host, site, alert_type, severity, message, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (now, host, site, alert_type, severity, message, "NEW")
        )

    def update_alert_status(self, alert_id, status):
        self.execute(
            "UPDATE alerts SET status = ? WHERE id = ?",
            (status, alert_id)
        )

    # ----------------------------
    # Deduplication / Suppression
    # ----------------------------

    def should_suppress(self, signature, dedup_seconds):
        row = self.fetchone(
            "SELECT last_seen FROM alert_state WHERE signature = ?",
            (signature,)
        )

        if not row:
            return False

        last_seen = datetime.fromisoformat(row["last_seen"])
        now = datetime.utcnow()

        delta = (now - last_seen).total_seconds()

        return delta < dedup_seconds

    # ----------------------------
    # Audit Log
    # ----------------------------

    def audit(self, user, action, details):
        now = datetime.utcnow().isoformat()

        self.execute(
            """
            INSERT INTO audit_log (timestamp, user, action, details)
            VALUES (?, ?, ?, ?)
            """,
            (now, user, action, details)
        )

    # ----------------------------
    # Alert History
    # ----------------------------

    def record_history(self, alert_id, action, details=""):
        now = datetime.utcnow().isoformat()

        self.execute(
            """
            INSERT INTO alert_history (alert_id, action, timestamp, details)
            VALUES (?, ?, ?, ?)
            """,
            (alert_id, action, now, details)
        )

    # ----------------------------
    # Recovery Handling
    # ----------------------------

    def mark_recovered(self, signature):
        self.set_alert_state(signature, "", "", "RECOVERED")

    # ----------------------------
    # Queries
    # ----------------------------

    def get_active_alerts(self):
        return self.fetchall(
            "SELECT * FROM alert_state WHERE state = 'ACTIVE'"
        )

    def get_recent_alerts(self, limit=100):
        return self.fetchall(
            "SELECT * FROM alerts ORDER BY id DESC LIMIT ?",
            (limit,)
        )

    # ----------------------------
    # Health Check
    # ----------------------------

    def healthcheck(self):
        try:
            self.fetchone("SELECT 1")
            return True
        except Exception:
            return False


# ----------------------------
# Singleton accessor
# ----------------------------

_db_instance = Database()

def db():
    return _db_instance


# ----------------------------
# CLI test
# ----------------------------

if __name__ == "__main__":
    d = db()
    print("DB Health:", d.healthcheck())
    print("Recent Alerts:", d.get_recent_alerts(5))
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/smtp.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - SMTP / Notification Engine
Version: 1.0.0
"""

import smtplib
import ssl
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

from config import config


class SMTPError(Exception):
    pass


class SMTPClient:
    """
    Handles multi-profile SMTP delivery using Postfix relay or direct SMTP.
    """

    def __init__(self):
        self.cfg = config()

    # ----------------------------
    # Profile Resolution
    # ----------------------------

    def resolve_profiles(self, notification_profile_name):
        profiles = self.cfg.get_notification_profiles()
        smtp_profiles = self.cfg.get_smtp_profiles()

        profile = profiles.get(notification_profile_name)

        if not profile:
            profile = profiles.get("default")

        if not profile:
            raise SMTPError("No notification profile found")

        smtp_name = profile.get("smtp_profile", "default")
        smtp = smtp_profiles.get(smtp_name)

        if not smtp:
            smtp = smtp_profiles.get("default")

        if not smtp:
            raise SMTPError("No SMTP profile found")

        return profile, smtp

    # ----------------------------
    # Send Email
    # ----------------------------

    def send_email(self, notification_profile_name, to_addresses, subject, html_body, text_body=None):
        profile, smtp = self.resolve_profiles(notification_profile_name)

        from_email = profile.get("from_email", "alerts@localhost")
        from_name = profile.get("from_name", "Syslog Alerts")
        reply_to = profile.get("reply_to", from_email)

        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"] = f"{from_name} <{from_email}>"
        msg["To"] = ", ".join(to_addresses)
        msg["Reply-To"] = reply_to

        if text_body:
            part1 = MIMEText(text_body, "plain")
            msg.attach(part1)

        part2 = MIMEText(html_body, "html")
        msg.attach(part2)

        try:
            self._send_via_smtp(smtp, from_email, to_addresses, msg)
        except Exception as e:
            raise SMTPError(f"Failed to send email: {str(e)}")

    # ----------------------------
    # SMTP Transport Layer
    # ----------------------------

    def _send_via_smtp(self, smtp, from_email, to_addresses, msg):
        host = smtp.get("relay_host", "localhost")
        port = int(smtp.get("relay_port", 25))
        username = smtp.get("username")
        password = self.cfg.get_secrets().get("smtp_password")
        tls = smtp.get("tls", True)

        context = ssl.create_default_context()

        with smtplib.SMTP(host, port, timeout=10) as server:

            server.ehlo()

            if tls:
                try:
                    server.starttls(context=context)
                    server.ehlo()
                except Exception:
                    # fallback for non-TLS relays
                    pass

            if username and password:
                server.login(username, password)

            server.sendmail(
                from_email,
                to_addresses,
                msg.as_string()
            )

    # ----------------------------
    # Health Check
    # ----------------------------

    def test_connection(self, notification_profile_name="default"):
        try:
            profile, smtp = self.resolve_profiles(notification_profile_name)

            host = smtp.get("relay_host", "localhost")
            port = int(smtp.get("relay_port", 25))

            with smtplib.SMTP(host, port, timeout=5) as server:
                server.noop()

            return True, f"SMTP OK ({host}:{port})"

        except Exception as e:
            return False, str(e)

    # ----------------------------
    # Future Extensions (placeholders)
    # ----------------------------

    def send_webhook(self, url, payload):
        """
        Reserved for Slack / Teams / Discord / custom integrations.
        """
        raise NotImplementedError("Webhooks not implemented yet")

    def send_sms(self, number, message):
        """
        Reserved for future SMS integration.
        """
        raise NotImplementedError("SMS not implemented yet")


# ----------------------------
# Singleton accessor
# ----------------------------

_client = SMTPClient()

def smtp_client():
    return _client


# ----------------------------
# CLI test
# ----------------------------

if __name__ == "__main__":
    client = smtp_client()

    ok, msg = client.test_connection()
    print("SMTP Test:", ok, msg)
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/templates.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Template Engine
Version: 1.0.0
"""

import os
from jinja2 import Template, meta, Environment, FileSystemLoader

from config import config


class TemplateError(Exception):
    pass


class TemplateEngine:

    def __init__(self):
        self.cfg = config()
        self.base_path = "/opt/syslog-alerts/templates"

        self.env = Environment(
            loader=FileSystemLoader(self.base_path),
            autoescape=False
        )

    # ----------------------------
    # Load template
    # ----------------------------

    def load(self, template_name):
        path = os.path.join(self.base_path, template_name)

        if not os.path.exists(path):
            raise TemplateError(f"Template not found: {template_name}")

        with open(path, "r") as f:
            return f.read()

    # ----------------------------
    # Render template
    # ----------------------------

    def render(self, template_name, context):
        try:
            template_source = self.load(template_name)
            template = Template(template_source)

            return template.render(**context)

        except Exception as e:
            raise TemplateError(f"Render failed: {str(e)}")

    # ----------------------------
    # Preview safe render (no crash)
    # ----------------------------

    def preview(self, template_name, context=None):
        if context is None:
            context = self.sample_context()

        try:
            return self.render(template_name, context)
        except Exception as e:
            return f"[TEMPLATE ERROR] {str(e)}"

    # ----------------------------
    # List templates
    # ----------------------------

    def list_templates(self):
        files = os.listdir(self.base_path)

        return [
            f for f in files
            if f.endswith(".html") or f.endswith(".txt")
        ]

    # ----------------------------
    # Validate template
    # ----------------------------

    def validate(self, template_name):
        """
        Ensures template has no undefined variables.
        """

        source = self.load(template_name)
        ast = self.env.parse(source)
        variables = meta.find_undeclared_variables(ast)

        required_context = self.sample_context().keys()

        missing_safe_defaults = []

        for var in variables:
            if var not in required_context:
                missing_safe_defaults.append(var)

        return {
            "template": template_name,
            "variables_found": list(variables),
            "missing_context_keys": missing_safe_defaults,
            "status": "OK" if not missing_safe_defaults else "WARNING"
        }

    # ----------------------------
    # Sample context for testing
    # ----------------------------

    def sample_context(self):
        return {
            "host": "test-host",
            "message": "Sample alert message",
            "timestamp": "2026-01-01T00:00:00Z",
            "severity": "INFO",
            "alert_type": "TEST_ALERT",
            "site": "default"
        }

    # ----------------------------
    # Render from alert event
    # ----------------------------

    def render_from_event(self, template_name, event, rule=None):

        context = {
            "host": event.get("host"),
            "message": event.get("message"),
            "timestamp": event.get("timestamp"),
            "program": event.get("program"),
            "severity": rule.get("severity") if rule else "INFO",
            "alert_type": rule.get("alert_type") if rule else "UNKNOWN",
            "site": rule.get("site") if rule else "default"
        }

        return self.render(template_name, context)

    # ----------------------------
    # Template creation helper
    # ----------------------------

    def create_template(self, name, content):
        path = os.path.join(self.base_path, name)

        if os.path.exists(path):
            raise TemplateError(f"Template already exists: {name}")

        with open(path, "w") as f:
            f.write(content)

        return True

    # ----------------------------
    # Delete template
    # ----------------------------

    def delete_template(self, name):
        path = os.path.join(self.base_path, name)

        if os.path.exists(path):
            os.remove(path)
            return True

        return False

    # ----------------------------
    # Debug CLI
    # ----------------------------

    def debug(self, template_name):
        print("Template:", template_name)
        print("Validation:", self.validate(template_name))
        print("\nPreview:\n")
        print(self.preview(template_name))


# ----------------------------
# Singleton accessor
# ----------------------------

_engine = TemplateEngine()

def templates():
    return _engine


# ----------------------------
# CLI test
# ----------------------------

if __name__ == "__main__":
    t = templates()

    print("Available templates:")
    print(t.list_templates())

    print("\nValidation example:")
    for tpl in t.list_templates():
        print(t.validate(tpl))
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/alerts.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Alert Rules Engine
Version: 1.0.0
"""

import re
import hashlib
from datetime import datetime

from config import config
from database import db


class AlertEngineError(Exception):
    pass


class AlertEngine:
    """
    Responsible for evaluating syslog events against alert rules
    and producing structured alert decisions.
    """

    def __init__(self):
        self.cfg = config()
        self.db = db()

    # ----------------------------
    # Normalize alerts config
    # ----------------------------

    def get_rules(self):
        rules = self.cfg.get_alerts().get("alerts", {})

        normalized = {}

        for name, rule in rules.items():
            normalized[name] = self.normalize_rule(name, rule)

        return normalized

    # ----------------------------
    # Rule normalization
    # ----------------------------

    def normalize_rule(self, name, rule):
        return {
            "name": name,
            "severity": rule.get("severity", "INFO").upper(),
            "site": rule.get("site", "default"),
            "regex": self._ensure_list(rule.get("regex", [])),
            "recovery_regex": self._ensure_list(rule.get("recovery_regex", [])),
            "dedup_minutes": int(rule.get("dedup_minutes", 60)),
            "template": rule.get("template", "generic.html"),
            "notification_profile": rule.get("notification_profile", "default"),
            "recipient_group": rule.get("recipient_group", "default")
        }

    # ----------------------------
    # Match engine
    # ----------------------------

    def match_alerts(self, message):
        matches = []

        for name, rule in self.get_rules().items():
            if self._match_any(rule["regex"], message):
                matches.append(rule)

        return matches

    # ----------------------------
    # Recovery detection
    # ----------------------------

    def match_recovery(self, message):
        recoveries = []

        for name, rule in self.get_rules().items():
            if self._match_any(rule["recovery_regex"], message):
                recoveries.append(rule)

        return recoveries

    # ----------------------------
    # Core matching helper
    # ----------------------------

    def _match_any(self, patterns, message):
        if not patterns:
            return False

        for pattern in patterns:
            try:
                if re.search(pattern, message, re.IGNORECASE):
                    return True
            except re.error:
                continue

        return False

    # ----------------------------
    # Dedup signature generation
    # ----------------------------

    def generate_signature(self, host, alert_name, message=None):
        base = f"{host}:{alert_name}"

        if message:
            base += f":{message}"

        return hashlib.sha256(base.encode()).hexdigest()

    # ----------------------------
    # Severity normalization
    # ----------------------------

    def normalize_severity(self, severity):
        mapping = {
            "INFO": "INFO",
            "INFORMATION": "INFO",
            "WARN": "WARNING",
            "WARNING": "WARNING",
            "CRITICAL": "CRITICAL",
            "ERROR": "CRITICAL",
            "FATAL": "CRITICAL",
            "DEBUG": "INFO"
        }

        return mapping.get(severity.upper(), "INFO")

    # ----------------------------
    # Dedup decision
    # ----------------------------

    def should_suppress(self, signature, dedup_minutes):
        return self.db.should_suppress(signature, dedup_minutes * 60)

    # ----------------------------
    # Build alert object (canonical format)
    # ----------------------------

    def build_alert(self, rule, event):
        severity = self.normalize_severity(rule["severity"])

        signature = self.generate_signature(
            event["host"],
            rule["name"],
            event["message"]
        )

        return {
            "rule_name": rule["name"],
            "severity": severity,
            "site": rule["site"],
            "template": rule["template"],
            "notification_profile": rule["notification_profile"],
            "recipient_group": rule["recipient_group"],
            "signature": signature,
            "host": event["host"],
            "message": event["message"],
            "timestamp": event["timestamp"],
            "program": event.get("program")
        }

    # ----------------------------
    # Evaluate event fully
    # ----------------------------

    def evaluate(self, event):
        """
        Returns:
        {
            "alerts": [...],
            "recoveries": [...]
        }
        """

        message = event.get("message", "")

        alerts = self.match_alerts(message)
        recoveries = self.match_recovery(message)

        result = {
            "alerts": [],
            "recoveries": []
        }

        for rule in alerts:
            alert_obj = self.build_alert(rule, event)
            result["alerts"].append(alert_obj)

        for rule in recoveries:
            alert_obj = self.build_alert(rule, event)
            result["recoveries"].append(alert_obj)

        return result

    # ----------------------------
    # Utility
    # ----------------------------

    def _ensure_list(self, value):
        if isinstance(value, list):
            return value
        if value is None:
            return []
        return [value]


# ----------------------------
# Singleton accessor
# ----------------------------

_engine = AlertEngine()

def alerts():
    return _engine


# ----------------------------
# CLI test
# ----------------------------

if __name__ == "__main__":
    engine = alerts()

    test_event = {
        "host": "test-host",
        "message": "filesystem full on /var",
        "timestamp": datetime.utcnow().isoformat(),
        "program": "test"
    }

    result = engine.evaluate(test_event)

    print("Evaluation Result:")
    print(result)
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/simulator.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Event Simulator
Version: 1.0.0
"""

import time
import random
from datetime import datetime, timedelta

from alerts import alerts
from config import config
from database import db


class Simulator:

    def __init__(self):
        self.alert_engine = alerts()
        self.cfg = config()
        self.db = db()

    # ----------------------------
    # Run single event
    # ----------------------------

    def run_event(self, host, message, program="simulator"):
        event = {
            "host": host,
            "message": message,
            "timestamp": datetime.utcnow().isoformat(),
            "program": program
        }

        return self.alert_engine.evaluate(event)

    # ----------------------------
    # Run batch simulation
    # ----------------------------

    def run_batch(self, events, delay=0):
        results = []

        for e in events:
            result = self.run_event(
                e.get("host", "test-host"),
                e.get("message", ""),
                e.get("program", "simulator")
            )

            results.append(result)

            if delay > 0:
                time.sleep(delay)

        return results

    # ----------------------------
    # Generate alert storm
    # ----------------------------

    def generate_storm(self, host="test-host", count=50):
        """
        Simulates repeated identical alerts (dedup testing)
        """

        messages = [
            "filesystem full on /var",
            "no space left on device",
            "ssh failed login attempt",
            "interface down eth0",
            "backup job failed",
        ]

        results = []

        for _ in range(count):
            msg = random.choice(messages)

            result = self.run_event(host, msg)
            results.append(result)

        return results

    # ----------------------------
    # Recovery simulation
    # ----------------------------

    def simulate_recovery(self, host="test-host"):
        """
        Simulates alert + recovery sequence
        """

        sequence = [
            "filesystem full on /var",
            "filesystem normal on /var"
        ]

        results = []

        for msg in sequence:
            result = self.run_event(host, msg)
            results.append(result)
            time.sleep(1)

        return results

    # ----------------------------
    # Time-based replay
    # ----------------------------

    def replay(self, logs, speed=1.0):
        """
        Replay historical logs with optional speed multiplier
        """

        results = []

        for log in logs:
            event = {
                "host": log.get("host", "replay"),
                "message": log.get("message", ""),
                "timestamp": log.get("timestamp", datetime.utcnow().isoformat()),
                "program": "replay"
            }

            result = self.alert_engine.evaluate(event)
            results.append(result)

            time.sleep(speed)

        return results

    # ----------------------------
    # Template test feed
    # ----------------------------

    def test_all_alerts(self):
        """
        Automatically triggers one sample event per rule
        """

        rules = self.cfg.get_alerts().get("alerts", {})

        results = []

        for name, rule in rules.items():
            sample_message = rule.get("regex", ["test alert"])[0]

            result = self.run_event(
                host="test-host",
                message=sample_message,
                program="tester"
            )

            results.append({
                "rule": name,
                "result": result
            })

        return results

    # ----------------------------
    # Load test mode
    # ----------------------------

    def load_test(self, events_per_second=10, duration_seconds=10):
        """
        High-rate simulation for stress testing dispatcher
        """

        messages = [
            "filesystem full",
            "ssh login failure",
            "interface down",
            "backup failed",
            "cpu overload detected"
        ]

        results = []
        end_time = time.time() + duration_seconds

        while time.time() < end_time:
            for _ in range(events_per_second):
                msg = random.choice(messages)

                result = self.run_event("load-test", msg)
                results.append(result)

            time.sleep(1)

        return results


# ----------------------------
# Singleton accessor
# ----------------------------

_sim = Simulator()

def simulator():
    return _sim


# ----------------------------
# CLI test
# ----------------------------

if __name__ == "__main__":
    sim = simulator()

    print("Running sample storm...")
    results = sim.generate_storm(count=10)

    print("Storm results:")
    print(results)

    print("\nRunning recovery test...")
    print(sim.simulate_recovery())
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/validator.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Configuration Validator
Version: 1.0.0
"""

import re
import os

from config import config
from templates import templates
from smtp import smtp_client
from database import db


class ValidationError(Exception):
    pass


class Validator:

    def __init__(self):
        self.cfg = config()
        self.tpl = templates()
        self.smtp = smtp_client()
        self.db = db()

    # ----------------------------
    # Run full system validation
    # ----------------------------

    def run_all(self):
        return {
            "config": self.validate_config(),
            "alerts": self.validate_alerts(),
            "templates": self.validate_templates(),
            "smtp": self.validate_smtp(),
            "database": self.validate_database(),
        }

    # ----------------------------
    # Config validation
    # ----------------------------

    def validate_config(self):
        errors = []

        try:
            cfg = self.cfg.load(force_reload=True)
        except Exception as e:
            return {"status": "FAIL", "errors": [str(e)]}

        required_files = [
            "alerts",
            "recipients",
            "sites",
            "smtp",
            "notification_profiles",
            "secrets"
        ]

        for f in required_files:
            if f not in cfg or not cfg[f]:
                errors.append(f"Missing config section: {f}")

        return self._result(errors)

    # ----------------------------
    # Alert rule validation
    # ----------------------------

    def validate_alerts(self):
        errors = []

        alerts = self.cfg.get_alerts().get("alerts", {})

        if not alerts:
            return {"status": "FAIL", "errors": ["No alerts defined"]}

        for name, rule in alerts.items():

            # regex validation
            for pattern in rule.get("regex", []):
                try:
                    re.compile(pattern)
                except re.error as e:
                    errors.append(f"{name}: invalid regex '{pattern}' - {e}")

            # recovery regex validation
            for pattern in rule.get("recovery_regex", []):
                try:
                    re.compile(pattern)
                except re.error as e:
                    errors.append(f"{name}: invalid recovery regex '{pattern}' - {e}")

            # required fields
            if "severity" not in rule:
                errors.append(f"{name}: missing severity")

            if "template" not in rule:
                errors.append(f"{name}: missing template")

        return self._result(errors)

    # ----------------------------
    # Template validation
    # ----------------------------

    def validate_templates(self):
        errors = []

        templates_list = self.tpl.list_templates()

        if not templates_list:
            return {"status": "WARN", "errors": ["No templates found"]}

        for tpl in templates_list:
            result = self.tpl.validate(tpl)

            if result["status"] != "OK":
                errors.append(f"{tpl}: {result['missing_context_keys']}")

        return self._result(errors)

    # ----------------------------
    # SMTP validation
    # ----------------------------

    def validate_smtp(self):
        errors = []

        try:
            ok, msg = self.smtp.test_connection()

            if not ok:
                errors.append(msg)

        except Exception as e:
            errors.append(str(e))

        return self._result(errors)

    # ----------------------------
    # Database validation
    # ----------------------------

    def validate_database(self):
        errors = []

        try:
            if not self.db.healthcheck():
                errors.append("Database healthcheck failed")

            # basic table checks
            required_tables = [
                "alerts",
                "alert_state",
                "alert_history",
                "audit_log"
            ]

            for table in required_tables:
                try:
                    self.db.fetchone(f"SELECT 1 FROM {table} LIMIT 1")
                except Exception:
                    errors.append(f"Missing or invalid table: {table}")

        except Exception as e:
            errors.append(str(e))

        return self._result(errors)

    # ----------------------------
    # Helpers
    # ----------------------------

    def _result(self, errors):
        if errors:
            return {
                "status": "FAIL",
                "errors": errors
            }

        return {
            "status": "OK",
            "errors": []
        }

    # ----------------------------
    # Quick pre-flight check
    # ----------------------------

    def preflight(self):
        results = self.run_all()

        for k, v in results.items():
            if v["status"] != "OK":
                return False, results

        return True, results


# ----------------------------
# Singleton accessor
# ----------------------------

_validator = Validator()

def validator():
    return _validator


# ----------------------------
# CLI test
# ----------------------------

if __name__ == "__main__":
    v = validator()

    results = v.run_all()

    print("Validation Report:")
    for section, result in results.items():
        print(f"\n[{section.upper()}]")
        print(result)
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/maintenance.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Maintenance Engine
Version: 1.0.0
"""

import os
import glob
import tarfile
from datetime import datetime, timedelta

from config import config
from database import db


class Maintenance:

    def __init__(self):
        self.cfg = config()
        self.db = db()

        self.base_dir = "/opt/syslog-alerts"
        self.backup_dir = os.path.join(self.base_dir, "backups")
        self.db_path = os.path.join(self.base_dir, "database", "alerts.db")

    # ----------------------------
    # Run all maintenance tasks
    # ----------------------------

    def run_all(self):
        return {
            "cleanup": self.cleanup_old_data(),
            "db_vacuum": self.vacuum_db(),
            "backup": self.create_backup(),
            "state_check": self.check_stale_alerts(),
        }

    # ----------------------------
    # Remove old logs and temp files
    # ----------------------------

    def cleanup_old_data(self):
        retention = self.cfg.get("retention", {}).get("retention", {})

        alerts_days = retention.get("alerts_days", 90)
        audit_days = retention.get("audit_days", 365)

        cutoff_alerts = datetime.utcnow() - timedelta(days=alerts_days)
        cutoff_audit = datetime.utcnow() - timedelta(days=audit_days)

        # Clean alerts table
        self.db.execute(
            "DELETE FROM alerts WHERE timestamp < ?",
            (cutoff_alerts.isoformat(),)
        )

        # Clean audit log
        self.db.execute(
            "DELETE FROM audit_log WHERE timestamp < ?",
            (cutoff_audit.isoformat(),)
        )

        return {
            "status": "OK",
            "alerts_cutoff": cutoff_alerts.isoformat(),
            "audit_cutoff": cutoff_audit.isoformat()
        }

    # ----------------------------
    # Vacuum database
    # ----------------------------

    def vacuum_db(self):
        try:
            self.db.execute("VACUUM")
            return {"status": "OK"}
        except Exception as e:
            return {"status": "FAIL", "error": str(e)}

    # ----------------------------
    # Create compressed backup
    # ----------------------------

    def create_backup(self):
        os.makedirs(self.backup_dir, exist_ok=True)

        timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
        backup_file = os.path.join(self.backup_dir, f"backup-{timestamp}.tar.gz")

        try:
            with tarfile.open(backup_file, "w:gz") as tar:
                tar.add(self.db_path, arcname="alerts.db")
                tar.add(os.path.join(self.base_dir, "config"), arcname="config")
                tar.add(os.path.join(self.base_dir, "templates"), arcname="templates")

            self._cleanup_old_backups()

            return {
                "status": "OK",
                "backup": backup_file
            }

        except Exception as e:
            return {
                "status": "FAIL",
                "error": str(e)
            }

    # ----------------------------
    # Remove old backups
    # ----------------------------

    def _cleanup_old_backups(self):
        retention = self.cfg.get("retention", {}).get("retention", {})
        max_backups = retention.get("backups", 30)

        backups = sorted(
            glob.glob(os.path.join(self.backup_dir, "backup-*.tar.gz"))
        )

        if len(backups) <= max_backups:
            return

        to_delete = backups[:-max_backups]

        for file in to_delete:
            try:
                os.remove(file)
            except Exception:
                pass

    # ----------------------------
    # Detect stale alerts
    # ----------------------------

    def check_stale_alerts(self):
        """
        Finds ACTIVE alerts that have not updated recently.
        """

        stale_minutes = 120
        cutoff = datetime.utcnow() - timedelta(minutes=stale_minutes)

        stale = self.db.fetchall(
            "SELECT * FROM alert_state WHERE state = 'ACTIVE' AND last_seen < ?",
            (cutoff.isoformat(),)
        )

        return {
            "status": "OK",
            "stale_count": len(stale),
            "stale_alerts": [dict(s) for s in stale]
        }

    # ----------------------------
    # Full system health maintenance report
    # ----------------------------

    def report(self):
        return {
            "timestamp": datetime.utcnow().isoformat(),
            "maintenance": self.run_all()
        }


# ----------------------------
# Singleton accessor
# ----------------------------

_maint = Maintenance()

def maintenance():
    return _maint


# ----------------------------
# CLI test
# ----------------------------

if __name__ == "__main__":
    m = maintenance()

    result = m.report()

    print("Maintenance Report:")
    print(result)
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/digest-engine.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - Digest Engine
Version: 1.0.0
"""

from datetime import datetime, timedelta
from collections import defaultdict

from config import config
from database import db
from smtp import smtp_client
from templates import templates


class DigestEngine:

    def __init__(self):
        self.cfg = config()
        self.db = db()
        self.smtp = smtp_client()
        self.tpl = templates()

    # ----------------------------
    # Build digest window
    # ----------------------------

    def get_window(self, minutes=60):
        end = datetime.utcnow()
        start = end - timedelta(minutes=minutes)
        return start, end

    # ----------------------------
    # Fetch alerts in time window
    # ----------------------------

    def fetch_alerts(self, start, end):
        return self.db.fetchall(
            """
            SELECT * FROM alerts
            WHERE timestamp BETWEEN ? AND ?
            ORDER BY severity DESC, timestamp DESC
            """,
            (start.isoformat(), end.isoformat())
        )

    # ----------------------------
    # Group alerts
    # ----------------------------

    def group_alerts(self, alerts):
        grouped = defaultdict(list)

        for a in alerts:
            key = f"{a['host']}::{a['alert_type']}"
            grouped[key].append(dict(a))

        return grouped

    # ----------------------------
    # Severity scoring
    # ----------------------------

    def score_group(self, alerts):
        severity_map = {
            "INFO": 1,
            "WARNING": 2,
            "CRITICAL": 3
        }

        return max(
            severity_map.get(a.get("severity", "INFO"), 1)
            for a in alerts
        )

    # ----------------------------
    # Build digest model
    # ----------------------------

    def build_digest(self, minutes=60):
        start, end = self.get_window(minutes)

        alerts = self.fetch_alerts(start, end)
        grouped = self.group_alerts(alerts)

        digest = {
            "start": start.isoformat(),
            "end": end.isoformat(),
            "total_alerts": len(alerts),
            "groups": []
        }

        for key, items in grouped.items():
            host, alert_type = key.split("::", 1)

            digest["groups"].append({
                "host": host,
                "alert_type": alert_type,
                "count": len(items),
                "severity_score": self.score_group(items),
                "latest_message": items[0]["message"],
                "latest_time": items[0]["timestamp"],
            })

        # sort worst first
        digest["groups"].sort(
            key=lambda x: x["severity_score"],
            reverse=True
        )

        return digest

    # ----------------------------
    # Render digest
    # ----------------------------

    def render(self, digest):
        template_path = "/opt/syslog-alerts/templates/digest.html"

        try:
            with open(template_path, "r") as f:
                tpl = self.tpl.env.from_string(f.read())

            return tpl.render(digest=digest)

        except Exception as e:
            return f"<pre>Digest render error: {e}</pre>"

    # ----------------------------
    # Send digest
    # ----------------------------

    def send_digest(self, minutes=60, profile="default"):
        digest = self.build_digest(minutes)

        html = self.render(digest)

        subject = f"[DIGEST] {digest['total_alerts']} alerts in last {minutes} minutes"

        recipients = self.cfg.get_notification_profiles().get(
            profile,
            self.cfg.get_notification_profiles().get("default", {})
        ).get("digest_recipients", [])

        if not recipients:
            return {
                "status": "SKIPPED",
                "reason": "No digest recipients configured"
            }

        self.smtp.send_email(
            profile,
            recipients,
            subject,
            html
        )

        return {
            "status": "OK",
            "sent_to": recipients,
            "total_alerts": digest["total_alerts"]
        }

    # ----------------------------
    # Hourly digest runner
    # ----------------------------

    def run_hourly(self):
        return self.send_digest(minutes=60)

    # ----------------------------
    # Daily digest runner
    # ----------------------------

    def run_daily(self):
        return self.send_digest(minutes=1440)


# ----------------------------
# Singleton accessor
# ----------------------------

_engine = DigestEngine()

def digest_engine():
    return _engine


# ----------------------------
# CLI test
# ----------------------------

if __name__ == "__main__":
    d = digest_engine()

    result = d.build_digest(60)

    print("DIGEST PREVIEW:")
    print(result)
EOF

cat <<'''EOF''' > $INSTALL_DIR/bin/api.py
#!/usr/bin/env python3
"""
Syslog Alerts Platform - API Layer
Version: 1.0.0
"""

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from database import db
from alerts import alerts
from simulator import simulator
from validator import validator
from maintenance import maintenance
from digest_engine import digest_engine

app = FastAPI(title="Syslog Alerts API", version="1.0.0")


# ----------------------------
# Models
# ----------------------------

class EventModel(BaseModel):
    host: str
    message: str
    program: str = "api"


class SimulateModel(BaseModel):
    host: str
    message: str


# ----------------------------
# Health
# ----------------------------

@app.get("/health")
def health():
    return {
        "status": "ok",
        "db": db().healthcheck()
    }


# ----------------------------
# Alerts - evaluate event
# ----------------------------

@app.post("/event")
def process_event(event: EventModel):
    engine = alerts()

    result = engine.evaluate({
        "host": event.host,
        "message": event.message,
        "timestamp": __import__("datetime").datetime.utcnow().isoformat(),
        "program": event.program
    })

    return result


# ----------------------------
# Simulator endpoints
# ----------------------------

@app.post("/simulate")
def simulate(event: SimulateModel):
    sim = simulator()
    return sim.run_event(event.host, event.message)


@app.post("/simulate/storm")
def storm(count: int = 20):
    return simulator().generate_storm(count=count)


@app.post("/simulate/recovery")
def recovery():
    return simulator().simulate_recovery()


# ----------------------------
# Validation
# ----------------------------

@app.get("/validate")
def validate():
    return validator().run_all()


# ----------------------------
# Maintenance
# ----------------------------

@app.post("/maintenance/run")
def run_maintenance():
    return maintenance().run_all()


@app.get("/maintenance/report")
def maintenance_report():
    return maintenance().report()


# ----------------------------
# Digest
# ----------------------------

@app.post("/digest/run")
def run_digest(minutes: int = 60):
    return digest_engine().send_digest(minutes=minutes)


# ----------------------------
# Active alerts
# ----------------------------

@app.get("/alerts/active")
def active_alerts():
    return db().get_active_alerts()


@app.get("/alerts/recent")
def recent_alerts(limit: int = 50):
    return db().get_recent_alerts(limit)


# ----------------------------
# Audit log
# ----------------------------

@app.get("/audit")
def audit(limit: int = 50):
    return db().fetchall(
        "SELECT * FROM audit_log ORDER BY id DESC LIMIT ?",
        (limit,)
    )


# ----------------------------
# CLI entry (optional fallback)
# ----------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api:app",
        host="0.0.0.0",
        port=8080,
        reload=False
    )
EOF

chmod +x $INSTALL_DIR/bin/*.py

echo "[OK] Stub modules created"
}

#############################################
# Config files
#############################################

create_configs() {

echo "[INFO] Creating config files..."

cat <<EOF > $INSTALL_DIR/config/smtp.yaml
smtp:
  relay_host: localhost
  relay_port: 25
EOF

cat <<EOF > $INSTALL_DIR/config/alerts.yaml
alerts:
  DISK_FULL:
    severity: CRITICAL
    regex: "filesystem full"
EOF

cat <<EOF > $INSTALL_DIR/config/recipients.yaml
recipient_groups:
  default:
    - admin@example.com
EOF

cat <<EOF > $INSTALL_DIR/config/sites.yaml
sites:
  default:
    timezone: UTC
EOF

cat <<EOF > $INSTALL_DIR/config/notification_profiles.yaml
notification_profiles:
  default:
    from_email: alerts@localhost
EOF

chown -R $APP_USER:$APP_USER $INSTALL_DIR/config

echo "[OK] Config files created"
}

#############################################
# Templates
#############################################

create_templates() {

cat <<EOF > $INSTALL_DIR/templates/generic.html
<h1>Syslog Alert</h1>
<p>{{ message }}</p>
EOF

cat <<EOF > $INSTALL_DIR/templates/disk_full.html
<h1>Disk Full Alert</h1>
<p>{{ message }}</p>
EOF

chown -R $APP_USER:$APP_USER $INSTALL_DIR/templates

echo "[OK] Templates created"
}

#############################################
# Repair function
#############################################

repair() {
    echo "[INFO] Repairing installation..."

    create_dirs
    init_db
    create_services

    systemctl daemon-reload

    echo "[OK] Repair complete"
}

#############################################
# Upgrade function
#############################################

upgrade() {
    echo "[INFO] Upgrading..."

    backup

    install_deps
    create_services
    create_stubs

    systemctl restart syslog-alert-dispatcher.service

    echo "[OK] Upgrade complete"
}

#############################################
# Backup
#############################################

backup() {
    echo "[INFO] Creating backup..."

    TAR="$INSTALL_DIR/backups/backup-$(date +%F-%H%M%S).tar.gz"

    tar -czf "$TAR" \
        -C $INSTALL_DIR \
        config templates database

    echo "[OK] Backup created: $TAR"
}

#############################################
# Status
#############################################

status() {
    systemctl status syslog-alert-dispatcher.service --no-pager || true
}

#############################################
# Uninstall
#############################################

uninstall() {
    read -p "Are you sure? This removes $INSTALL_DIR (y/N): " CONF

    if [[ "$CONF" == "y" ]]; then
        systemctl stop syslog-alert-dispatcher.service || true
        systemctl disable syslog-alert-dispatcher.service || true

        rm -rf $INSTALL_DIR
        rm -f /etc/systemd/system/syslog-alert-*.service

        systemctl daemon-reload

        echo "[OK] Uninstalled"
    fi
}

#############################################
# Main Menu
#############################################

menu() {
    echo ""
    echo "Syslog Alerts Installer"
    echo "1) Install"
    echo "2) Upgrade"
    echo "3) Repair"
    echo "4) Backup"
    echo "5) Status"
    echo "6) Uninstall"
    echo "0) Exit"
    echo ""
    read -p "Select: " choice

    case $choice in
        1)
            detect_os
            install_deps
            create_user
            create_dirs
            init_db
            configure_postfix
            configure_syslog
            create_services
            create_stubs
            create_configs
            create_templates
            systemctl start syslog-alert-dispatcher.service
            ;;
        2) upgrade ;;
        3) repair ;;
        4) backup ;;
        5) status ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
}

menu
