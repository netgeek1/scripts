#!/bin/sh
###############################################################################
# OPNsense -> FortiGate / FortiManager / FortiAnalyzer /
# Ubiquiti / GL-Net RM1 / TrueNAS ACME certificate deploy
#
# Runs ON the OPNsense firewall (FreeBSD /bin/sh). The certificate itself is
# issued/renewed locally by the OPNsense ACME client plugin; this script only
# DEPLOYS it to the six devices above. OPNsense's own GUI certificate is handled
# by the plugin and is deliberately not a target here.
#
# The SCRIPT_VERSION constant below is the source of truth for the version.
#
# Full version history: see CHANGELOG.md
###############################################################################

set -eu

# cron and OPNsense's configd hand scripts a minimal PATH. Pin it so that
# openssl/curl/jq (in /usr/local/bin on FreeBSD) resolve identically whether the
# script is run by hand from an interactive shell or unattended at 03:00.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

###############################################################################
# CONFIG
#
# This file ships with safe EXAMPLE defaults only. Do NOT edit values here for a
# live deployment - put your real settings in an external config file instead:
#
#     /root/ssl_certs/install_wildcard_cert.conf      (default location)
#
# The script sources that file over the defaults below at startup, so you can
# update THIS script (git pull / download over the old one) without touching
# your settings. Copy install_wildcard_cert.conf.example to the path above and
# edit it. Override the location with  -c /path/to.conf  or  $CERT_DEPLOY_CONF.
#
# Secrets (API keys) live separately in  $LOG_DIR/.env  (chmod 600):
#     API_KEY_FGT="..."  API_KEY_FMG="..."  API_KEY_FAZ="..."  API_KEY_TRUENAS="..."
#
# The example IPs below are RFC 5737 documentation addresses (192.0.2.0/24,
# 198.51.100.0/24). The script REFUSES to run against them for an enabled device
# (see validate_config), so a missing/unedited config fails loudly, never quietly.
###############################################################################

# --- Paths --------------------------------------------------------------------
LOG_DIR="/root/ssl_certs"                        # logs + .env live here

# --- Identity (set in the config file) ----------------------------------------
DOMAIN=""                                        # cert OBJECT name, e.g. wildcard_example_com
ACME_MATCH_SAN=""                                # DNS SAN to match, e.g. *.example.com

# --- Device enable/disable ----------------------------------------------------
# 1 = deploy to this device, 0 = skip it entirely (no TLS probe, no API call, no
# SSH). A disabled device is reported as DISABLED in the summary and does NOT
# affect the exit code or trigger a notification email - it is a config state,
# not a run outcome. Override per deployment in the config file.
DEPLOY_FGT=1          # FortiGate
DEPLOY_UCG=1          # Ubiquiti Cloud Gateway
DEPLOY_RM1=1          # GL-Net RM1
DEPLOY_DOCKER=0       # Docker host (docker-dashboard --cert-receive)
DEPLOY_TRUENAS=1      # TrueNAS SCALE
DEPLOY_FMG=0          # FortiManager
DEPLOY_FAZ=0          # FortiAnalyzer

# --- Device addresses / SSH (set in the config file) --------------------------
FGT_IP=""

FMG_IP=""
FAZ_IP=""

UCG_IP=""
UCG_SSH_USER=""
UCG_SSH_PORT="22"
UCG_SSH_KEY=""

RM1_IP=""
RM1_SSH_USER=""
RM1_SSH_PORT="22"
RM1_SSH_KEY=""

# Docker host running docker-dashboard (cert PUSH mode). The cert chain + key
# are streamed on stdin to a forced command (docker-dashboard --cert-receive);
# no remote command, no scp. DOCKER_SSH_USER is fixed by --cert-push-setup.
DOCKER_IP=""
DOCKER_HTTPS_PORT="443"
DOCKER_SSH_USER="ddcertpush"
DOCKER_SSH_PORT="22"
DOCKER_SSH_KEY="/root/ssl_certs/docker_push_ed25519"

TRUENAS_IP=""
TRUENAS_CERT_NAME=""                             # defaults to $DOMAIN if left empty

# --- Certificate source (OPNsense ACME client plugin) -------------------------
# The plugin writes to:
#   /var/etc/acme-client/certs/<CERT_ID>/{cert,chain,fullchain}.pem
#   /var/etc/acme-client/keys/<CERT_ID>/private.key
# <CERT_ID> is an opaque generated id (e.g. 680e9aae53c020.22641748), NOT the
# domain, and it CHANGES if the certificate entry is ever recreated. Hardcoding
# it would fail silently later, so we resolve it at run time by matching the SAN
# inside the certificate (see resolve_cert_paths).
ACME_DIR="/var/etc/acme-client"
ACME_CERT_FILE="cert.pem"                        # leaf. Use "fullchain.pem" to
                                                 # also ship the intermediate.
ACME_KEY_FILE="private.key"

# Leave BOTH empty to auto-discover under ACME_DIR (recommended on OPNsense).
# Set both to absolute paths to bypass discovery (e.g. on another host).
CERTIFICATE_FILE=""
PRIVATE_KEY_FILE=""

# --- Network timeouts (seconds) -----------------------------------------------
CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=120
TLS_TIMEOUT=10
VERIFY_RETRIES=15               # post-deploy re-probes before declaring failure
VERIFY_INTERVAL=2               # seconds between re-probes (15x2 = 30s max wait)

# --- Email notification (via curl smtp://, no extra dependencies) -------------
# Aimed at an internal, unauthenticated SMTP forwarder. If the relay ever needs
# auth, add --user to send_mail() rather than putting credentials here.
NOTIFY_EMAIL=1                          # 0 = never send mail
# When to send:
#   "changes" = on any FAILED/UNREACHABLE, AND on any device actually UPDATED.
#               Silent when every device is already CURRENT (the normal nightly
#               case). This is the useful default.
#   "failure" = only on FAILED/UNREACHABLE. Silent on a successful renewal.
#   "always"  = every run, including all-CURRENT nights.
#   "never"   = same as NOTIFY_EMAIL=0.
NOTIFY_ON="changes"
SMTP_HOST=""                            # set in the config file
SMTP_PORT=25
MAIL_FROM=""                            # set in the config file
MAIL_TO=""                              # set in the config file
SMTP_TIMEOUT=20

# Warn when a device's LIVE certificate is within this many days of expiry.
# LE certs are ~90 days and renew with weeks of lead time, so a device still
# serving a cert this close to expiry means deployment to it has been quietly
# failing. During a normal run this raises a WARN and forces a notification;
# in --digest it is listed per device.
CERT_WARN_DAYS=21

SSH_CONNECT_TIMEOUT=10
# Host key policy for scp/ssh. On a NEW host, /root/.ssh/known_hosts is empty,
# so with "yes" every scp fails instantly with "Host key verification failed".
# Seed known_hosts once (see preflight warning) and leave this at "yes".
# "accept-new" trusts a host key on first sight (TOFU) - convenient, but it
# means an unknown key is accepted silently. Your call; "yes" is the safe one.
SSH_HOST_KEY_CHECKING="yes"

# API keys - populated from .env; never hardcode here
API_KEY_FGT=""
API_KEY_FMG=""
API_KEY_FAZ=""
API_KEY_TRUENAS=""

###############################################################################
# LOGGING / DEBUG / CLI
###############################################################################

SCRIPT_VERSION="3.1.0"          # bump on every change
VERBOSITY=1                     # 0=quiet(warn/error)  1=info(default)  2=debug
DRY_RUN=0                       # 1 = report intended actions, change nothing
MODE="deploy"                   # "deploy" (default) or "digest" (--digest)
TRACE="${TRACE:-0}"             # TRACE=1 -> raw xtrace (may expose secrets; stderr only)

# Site configuration file (sourced over the defaults above). Override with
# -c/--config or the CERT_DEPLOY_CONF environment variable.
CONF_FILE="${CERT_DEPLOY_CONF:-/root/ssl_certs/install_wildcard_cert.conf}"

usage() {
    cat <<USAGE
${0##*/} v${SCRIPT_VERSION}
Usage: ${0##*/} [options]
  -d, --debug     DEBUG-level console output
  -q, --quiet     warnings and errors only on the console
  -n, --dry-run   report intended actions per device; make no changes
      --digest    read-only: probe every device, email a cert-status report
                  (days-to-expiry per device), change nothing. For a daily cron.
  -c, --config F  read settings from F (default: /root/ssl_certs/install_wildcard_cert.conf
                  or \$CERT_DEPLOY_CONF)
  -V, --version   print version and exit
  -h, --help      this help
Env:
  TRACE=1         raw shell xtrace (WARNING: may expose secrets; stderr only)
Notes:
  Fully non-interactive. Manual runs behave identically to cron.
  Full DEBUG detail is always written to the per-run log file regardless of -q/-d.
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--debug)   VERBOSITY=2 ;;
            -q|--quiet)   VERBOSITY=0 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            --digest)     MODE="digest" ;;
            -c|--config)  [ $# -ge 2 ] || { printf 'Option %s needs a path\n' "$1" >&2; exit 2; }
                          CONF_FILE="$2"; shift ;;
            -V|--version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help)    usage; exit 0 ;;
            --) shift; break ;;
            -*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
            *)  break ;;
        esac
        shift
    done
}

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Scrub secrets before anything reaches the log (bearer tokens, inline PEM keys).
_redact() {
    sed -E \
        -e 's/([Bb]earer )[A-Za-z0-9._~+/=-]+/\1<REDACTED>/g' \
        -e 's/(PRIVATE KEY-----)[^-]*(-----END)/\1<REDACTED>\2/g'
}

# _emit LEVEL MIN_VERBOSITY message...
# Always persists to the log file; echoes to stderr only if verbosity allows.
_emit() {
    local _lvl="$1" _min="$2"; shift 2
    local _line
    _line=$(printf '%s [%s] %s' "$(_ts)" "$_lvl" "$*" | _redact)
    [ -n "${LOG_FILE:-}" ] && printf '%s\n' "$_line" >> "$LOG_FILE"
    [ "$VERBOSITY" -ge "$_min" ] && printf '%s\n' "$_line" >&2
    return 0
}

log_debug() { _emit DEBUG 2 "$@"; }
log_info()  { _emit INFO  1 "$@"; }
log_warn()  { _emit WARN  0 "$@"; }
log_error() { _emit ERROR 0 "$@"; }

# Back-compat shims: existing log/die call sites keep working unchanged.
log()  { log_info "$@"; }
die()  { log_error "$*"; exit 1; }

# Device deployment contract (see device_precheck / run_device):
#   local pre=0
#   device_precheck "Label" "$IP" 443 "what would happen" || pre=$?
#   [ "$pre" -eq 0 ] || return "$pre"      # 10=CURRENT 20=UNREACHABLE 30=DRY-RUN
#   ...mutate...
#   verify_deployed "$IP" 443 "Label" || return 1   # non-zero => FAILED

parse_args "$@"
[ "$TRACE" = "1" ] && { log_warn "TRACE enabled: xtrace may expose secrets (stderr only)"; set -x; }

###############################################################################
# INIT
###############################################################################

umask 077

# --- Load site configuration --------------------------------------------------
# Sourced OVER the in-script example defaults, so updating the script never
# disturbs your settings. Missing config is a hard error (the defaults point at
# RFC 5737 example addresses and must not be used against real infrastructure).
if [ -f "$CONF_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
else
    die "Config file not found: $CONF_FILE
  Copy the example and edit it:
    cp install_wildcard_cert.conf.example $CONF_FILE && chmod 600 $CONF_FILE
  Or point elsewhere with:  $0 -c /path/to/your.conf"
fi

# Derived defaults (computed after the config is loaded)
[ -n "$TRUENAS_CERT_NAME" ] || TRUENAS_CERT_NAME="$DOMAIN"

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/certificate_install_${TIMESTAMP}.log"
: > "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

# Source secrets (API keys) - kept out of the config file and out of git.
ENV_FILE="$LOG_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
fi

# Require an API key only for a device that is actually enabled, and only when
# deploying (the digest only probes TLS and needs no keys). Guarded with if/then
# so a false test cannot trip 'set -e'.
if [ "$MODE" = "deploy" ]; then
    if [ "$DEPLOY_FGT" = 1 ]     && [ -z "${API_KEY_FGT:-}" ];     then die "DEPLOY_FGT=1 but API_KEY_FGT not set in $ENV_FILE"; fi
    if [ "$DEPLOY_FMG" = 1 ]     && [ -z "${API_KEY_FMG:-}" ];     then die "DEPLOY_FMG=1 but API_KEY_FMG not set in $ENV_FILE"; fi
    if [ "$DEPLOY_FAZ" = 1 ]     && [ -z "${API_KEY_FAZ:-}" ];     then die "DEPLOY_FAZ=1 but API_KEY_FAZ not set in $ENV_FILE"; fi
    if [ "$DEPLOY_TRUENAS" = 1 ] && [ -z "${API_KEY_TRUENAS:-}" ]; then die "DEPLOY_TRUENAS=1 but API_KEY_TRUENAS not set in $ENV_FILE"; fi
fi

TRUENAS_API_KEY="${API_KEY_TRUENAS:-}"
UCG_SSH_CMD=""
RM1_SSH_CMD=""
DOCKER_SSH_CMD=""
CERT_CONTENT=""
KEY_CONTENT=""
DEVICE_RESULTS=""
OVERALL_RC=0
EXPIRY_WARN=""
DIGEST_ROWS=""
DIGEST_RC=0

# Optional hard-timeout wrapper for the TLS probe
if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_BIN="timeout"
else
    _TIMEOUT_BIN=""
    log_warn "timeout binary not found - TLS probe hang protection disabled"
fi

###############################################################################
# HELPERS
###############################################################################

# with_timeout SECONDS cmd...   (no-op prefix if 'timeout' is unavailable)
with_timeout() {
    local secs="$1"; shift
    if [ -n "$_TIMEOUT_BIN" ]; then
        "$_TIMEOUT_BIN" "$secs" "$@"
    else
        "$@"
    fi
}

# SHA-256 fingerprint of a live TLS endpoint; empty string on failure/timeout
live_fingerprint() {
    local host="$1" port="${2:-443}"
    echo | with_timeout "$TLS_TIMEOUT" openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true
}

file_fingerprint() {
    openssl x509 -in "$CERTIFICATE_FILE" -noout -fingerprint -sha256 2>/dev/null
}

# Returns 0 if the target is already serving the new cert
# Probe a device's live TLS certificate. Three distinct outcomes - an
# unreachable device must NOT be confused with "certificate differs", or we
# would fire a full deployment at a host that is not answering.
#   0 = up, already serving the certificate in $CERTIFICATE_FILE
#   1 = up, serving a different certificate
#   2 = no TLS response (service down / port closed / host unreachable)
probe_device() {
    local host="$1" port="${2:-443}"
    local live
    live=$(live_fingerprint "$host" "$port")
    [ -n "$live" ] || return 2
    [ "$live" = "$(file_fingerprint)" ] && return 0
    return 1
}

# Days until the device's LIVE certificate expires.
# Prints an integer (may be negative = already expired) on success, nothing on
# failure, and returns non-zero if the device could not be probed or parsed.
# Reuses the same s_client probe as live_fingerprint, so no new dependency.
live_cert_days_left() {
    local host="$1" port="${2:-443}"
    local notafter end now days

    notafter=$(echo | with_timeout "$TLS_TIMEOUT" \
        openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
    [ -n "$notafter" ] || return 1

    # BSD date (FreeBSD/OPNsense) parses the openssl format with -j -f; GNU date
    # uses -d. Try BSD first, then GNU, so this works on both.
    end=$(date -j -f '%b %e %H:%M:%S %Y %Z' "$notafter" '+%s' 2>/dev/null) \
        || end=$(date -d "$notafter" '+%s' 2>/dev/null) \
        || return 1

    now=$(date '+%s')
    days=$(( (end - now) / 86400 ))
    printf '%s' "$days"
    return 0
}

# Raw SMTP send. Takes a subject and a body-producing command (run in a subshell
# so it can printf freely); returns curl's exit status. Factored out so both the
# event-driven notify_email and the daily digest share one sender and one CRLF
# path, without the digest inheriting notify_email's change-detection gating.
send_mail() {
    local subject="$1" body_fn="$2"
    local msg rc=0

    if [ -z "$SMTP_HOST" ] || [ -z "$MAIL_TO" ] || [ -z "$MAIL_FROM" ]; then
        log_warn "Email enabled but SMTP_HOST/MAIL_TO/MAIL_FROM is empty - skipping"
        return 1
    fi

    msg=$(mktemp) || { log_warn "Could not create temp file for email - skipping"; return 1; }

    # SMTP requires CRLF; awk gives it portably (BSD sed cannot do \r).
    {
        printf 'From: %s\n'    "$MAIL_FROM"
        printf 'To: %s\n'      "$MAIL_TO"
        printf 'Subject: %s\n' "$subject"
        printf 'Date: %s\n'    "$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"
        printf 'X-Mailer: cert-deploy %s\n' "$SCRIPT_VERSION"
        printf '\n'
        "$body_fn"
    } | awk '{ printf "%s\r\n", $0 }' > "$msg"

    curl -s --url "smtp://$SMTP_HOST:$SMTP_PORT" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$SMTP_TIMEOUT" \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$msg" >/dev/null 2>&1 || rc=$?

    rm -f "$msg"

    if [ "$rc" -eq 0 ]; then
        log_info "Email sent to $MAIL_TO"
    else
        log_warn "Failed to send email via $SMTP_HOST:$SMTP_PORT (curl rc=$rc)"
    fi
    return "$rc"
}

# Post-deployment proof: re-probe until the device is serving the NEW cert.
# Retries because most of these devices bounce their web server during the
# swap (FMG/FAZ httpsd, TrueNAS UI, RM1 nginx) and are briefly unreachable.
verify_deployed() {
    local host="$1" port="$2" label="$3"
    local i=0 rc

    while [ "$i" -lt "$VERIFY_RETRIES" ]; do
        probe_device "$host" "$port" && {
            log_info "$label VERIFIED: now serving the new certificate"
            return 0
        }
        sleep "$VERIFY_INTERVAL"
        i=$((i + 1))
    done

    rc=0; probe_device "$host" "$port" || rc=$?
    if [ "$rc" -eq 2 ]; then
        log_error "$label: web service did not come back after the certificate swap"
    else
        log_error "$label: still serving the OLD certificate after deployment"
    fi
    return 1
}

# Shared pre-deployment gate. Returns the device status code:
#   0  proceed with deployment
#   10 CURRENT      - already correct, nothing to do
#   20 UNREACHABLE  - no TLS response, deployment NOT attempted
#   30 DRY-RUN      - would deploy
device_precheck() {
    local label="$1" host="$2" port="$3" actions="$4"
    local rc=0

    probe_device "$host" "$port" || rc=$?
    case "$rc" in
        0)
            log_info "$label already serving current certificate - skipping"
            return 10
            ;;
        2)
            log_warn "$label UNREACHABLE - no TLS response on $host:$port; not attempting deployment"
            return 20
            ;;
    esac

    log_info "Certificate differs - proceeding with $label deployment"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "DRY-RUN [$label]: would $actions"
        return 30
    fi
    return 0
}

# Strip PEM armor and newlines -> single-line base64 body, as the FortiGate
# monitor import endpoint expects for file_content / key_file_content.
# Generic BEGIN/END match covers RSA, EC, and PKCS#8 keys.
fgt_strip_pem() {
    tr -d '\n' | sed -e 's/-----BEGIN[^-]*-----//g' -e 's/-----END[^-]*-----//g'
}

# api_request METHOD LABEL URL KEY [PAYLOAD]
# Bearer-authenticated JSON call; logs the full response at DEBUG; returns body.
api_request() {
    local method="$1" label="$2" url="$3" key="$4" payload="${5:-}"
    local resp
    # '|| resp=""' is essential: a device that restarts its web daemon in
    # response to the call (e.g. FMG/FAZ on SET-ADMIN) drops the connection and
    # makes curl exit non-zero, which under 'set -e' would otherwise abort the
    # entire run at this assignment.
    if [ -n "$payload" ]; then
        resp=$(curl --http1.1 -k -s \
            --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -X "$method" "$url" \
            -H "Authorization: Bearer $key" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null) || resp=""
    else
        resp=$(curl --http1.1 -k -s \
            --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -X "$method" "$url" \
            -H "Authorization: Bearer $key" \
            -H "Content-Type: application/json" 2>/dev/null) || resp=""
    fi
    log_debug "$label response: $resp"
    printf '%s' "$resp"
}

# POST wrapper (used by FortiManager / FortiAnalyzer)
api_post() {
    api_request POST "$1" "$2" "$3" "$4"
}

###############################################################################
# PREFLIGHT
###############################################################################

# Locate the certificate and key written by the OPNsense ACME client.
#
# We deliberately do NOT hardcode the ACME cert id: it is generated, opaque, and
# changes if the certificate entry is recreated. Instead every cert under
# $ACME_DIR/certs/*/ is inspected and the one whose SAN matches $ACME_MATCH_SAN
# wins. If several match, the most recently written one is used.
resolve_cert_paths() {
    local candidate id newest=""

    # Explicit override: both set, nothing to discover.
    if [ -n "$CERTIFICATE_FILE" ] && [ -n "$PRIVATE_KEY_FILE" ]; then
        log_debug "Using explicitly configured certificate paths"
        return 0
    fi
    if [ -n "$CERTIFICATE_FILE" ] || [ -n "$PRIVATE_KEY_FILE" ]; then
        die "CERTIFICATE_FILE and PRIVATE_KEY_FILE must be set together, or both left empty for auto-discovery"
    fi

    [ -d "$ACME_DIR/certs" ] \
        || die "ACME cert directory not found: $ACME_DIR/certs (is the ACME client plugin installed and has it issued a cert?)"

    # Glob rather than parsing ls, so odd characters in a path cannot bite us.
    # -nt is not strictly POSIX but is supported by both FreeBSD sh (ash) and
    # dash, which are the only two shells this ever runs under.
    for candidate in "$ACME_DIR"/certs/*/"$ACME_CERT_FILE"; do
        [ -f "$candidate" ] || continue
        # -F: ACME_MATCH_SAN contains '*', which must not be read as a regex.
        openssl x509 -in "$candidate" -noout -text 2>/dev/null \
            | grep -Fq "DNS:$ACME_MATCH_SAN" || continue
        if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
            newest="$candidate"
        fi
    done

    [ -n "$newest" ] \
        || die "No certificate under $ACME_DIR/certs/*/$ACME_CERT_FILE contains SAN '$ACME_MATCH_SAN'"

    # .../certs/<CERT_ID>/<file>  ->  <CERT_ID>
    id=$(basename "$(dirname "$newest")")

    CERTIFICATE_FILE="$newest"
    PRIVATE_KEY_FILE="$ACME_DIR/keys/$id/$ACME_KEY_FILE"

    log_info "Resolved ACME cert id: $id"
    log_debug "  cert: $CERTIFICATE_FILE"
    log_debug "  key : $PRIVATE_KEY_FILE"
}

# scp, with stderr CAPTURED INTO THE LOG.
#
# 'scp -q' silences the progress meter but NOT errors - and nothing was
# capturing them, so a failed upload reached the terminal and never the log
# file. That is why a failed run showed a bare "FAILED" with no reason.
scp_file() {
    local label="$1" key="$2" port="$3" src="$4" dst="$5"
    local out rc=0

    out=$(scp -q -o BatchMode=yes \
        -o StrictHostKeyChecking="$SSH_HOST_KEY_CHECKING" \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -i "$key" -P "$port" "$src" "$dst" 2>&1) || rc=$?

    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r _l; do
            [ -n "$_l" ] && log_debug "$label scp: $_l"
        done
    fi

    if [ "$rc" -ne 0 ]; then
        log_error "$label scp failed (rc=$rc): ${out:-<no output from scp>}"
        return 1
    fi
    return 0
}

# Verify an SSH key exists and that we have a host key for the target. A brand
# new host has an empty known_hosts, which makes every BatchMode scp fail
# instantly with "Host key verification failed" - a confusing failure that this
# turns into an actionable message.
check_ssh_target() {
    local label="$1" key="$2" host="$3" port="$4"
    local perm

    if [ ! -f "$key" ]; then
        log_warn "$label: SSH key not found: $key (deployment will fail)"
        return 0
    fi
    if [ ! -r "$key" ]; then
        log_warn "$label: SSH key not readable: $key"
        return 0
    fi

    # OpenSSH refuses a private key that is group- or world-accessible:
    #   "Permissions 0644 for '...' are too open. This private key will be
    #    ignored."  -> scp then fails instantly, before any network activity.
    # Keys copied between hosts very often arrive as 0644.
    # stat(1) differs: BSD/FreeBSD uses -f '%Lp', GNU uses -c '%a'.
    perm=$(stat -f '%Lp' "$key" 2>/dev/null || stat -c '%a' "$key" 2>/dev/null) || perm=""
    case "$perm" in
        "")     : ;;                      # no usable stat; let scp report it
        *00)    log_debug "$label: key mode $perm OK" ;;
        *)      log_warn "$label: SSH key $key has mode $perm - too open. OpenSSH will IGNORE it and scp will fail."
                log_warn "$label: fix with:  chmod 600 $key"
                ;;
    esac

    if [ "$SSH_HOST_KEY_CHECKING" = "yes" ]; then
        if ! ssh-keygen -F "[$host]:$port" >/dev/null 2>&1 \
            && ! ssh-keygen -F "$host" >/dev/null 2>&1; then
            log_warn "$label: no host key for $host in known_hosts - scp will fail with 'Host key verification failed'."
            log_warn "$label: fix with:  ssh-keyscan -p $port $host >> /root/.ssh/known_hosts"
        fi
    fi
}

# True if the address is an RFC 5737 documentation range (the shipped examples).
_is_doc_ip() {
    case "$1" in
        192.0.2.*|198.51.100.*|203.0.113.*) return 0 ;;
        *) return 1 ;;
    esac
}

# Fail loudly on a missing or unedited config: an enabled device must have a
# real IP, not an empty value and not a shipped example address. Runs in both
# deploy and digest modes (both probe real hosts).
validate_config() {
    [ -n "$DOMAIN" ]         || die "DOMAIN is not set - edit $CONF_FILE"
    [ -n "$ACME_MATCH_SAN" ] || die "ACME_MATCH_SAN is not set - edit $CONF_FILE"

    _vreq_ip() {   # label  enabled  ip
        [ "$2" = 1 ] || return 0
        [ -n "$3" ] || die "$1 is enabled but its IP is empty - set it in $CONF_FILE"
        if _is_doc_ip "$3"; then
            die "$1 IP ($3) is still the example value - set the real address in $CONF_FILE"
        fi
        return 0
    }
    _vreq_ip FortiGate     "$DEPLOY_FGT"     "$FGT_IP"
    _vreq_ip FortiManager  "$DEPLOY_FMG"     "$FMG_IP"
    _vreq_ip FortiAnalyzer "$DEPLOY_FAZ"     "$FAZ_IP"
    _vreq_ip UCG           "$DEPLOY_UCG"     "$UCG_IP"
    _vreq_ip RM1           "$DEPLOY_RM1"     "$RM1_IP"
    _vreq_ip Docker        "$DEPLOY_DOCKER"  "$DOCKER_IP"
    _vreq_ip TrueNAS       "$DEPLOY_TRUENAS" "$TRUENAS_IP"

    # SSH devices also need a user + key when enabled.
    if [ "$DEPLOY_UCG" = 1 ]; then
        [ -n "$UCG_SSH_USER" ] || die "UCG enabled but UCG_SSH_USER is empty - set it in $CONF_FILE"
        [ -n "$UCG_SSH_KEY"  ] || die "UCG enabled but UCG_SSH_KEY is empty - set it in $CONF_FILE"
    fi
    if [ "$DEPLOY_RM1" = 1 ]; then
        [ -n "$RM1_SSH_USER" ] || die "RM1 enabled but RM1_SSH_USER is empty - set it in $CONF_FILE"
        [ -n "$RM1_SSH_KEY"  ] || die "RM1 enabled but RM1_SSH_KEY is empty - set it in $CONF_FILE"
    fi
    if [ "$DEPLOY_DOCKER" = 1 ]; then
        [ -n "$DOCKER_SSH_USER" ] || die "Docker enabled but DOCKER_SSH_USER is empty - set it in $CONF_FILE"
        [ -n "$DOCKER_SSH_KEY"  ] || die "Docker enabled but DOCKER_SSH_KEY is empty - set it in $CONF_FILE"
        case "$DOCKER_SSH_PORT"   in ''|*[!0-9]*) die "Docker: DOCKER_SSH_PORT ($DOCKER_SSH_PORT) is not numeric - fix it in $CONF_FILE" ;; esac
        case "$DOCKER_HTTPS_PORT" in ''|*[!0-9]*) die "Docker: DOCKER_HTTPS_PORT ($DOCKER_HTTPS_PORT) is not numeric - fix it in $CONF_FILE" ;; esac
    fi

    if [ "$NOTIFY_EMAIL" = 1 ]; then
        [ -n "$SMTP_HOST" ] || die "NOTIFY_EMAIL=1 but SMTP_HOST is empty - set it in $CONF_FILE"
        if _is_doc_ip "$SMTP_HOST"; then
            die "SMTP_HOST ($SMTP_HOST) is still the example value - set the real relay in $CONF_FILE"
        fi
        [ -n "$MAIL_TO" ]   || die "NOTIFY_EMAIL=1 but MAIL_TO is empty - set it in $CONF_FILE"
        [ -n "$MAIL_FROM" ] || die "NOTIFY_EMAIL=1 but MAIL_FROM is empty - set it in $CONF_FILE"
        case "$MAIL_TO" in *@example.com) log_warn "MAIL_TO is still @example.com - mail will not be delivered" ;; esac
    fi
}

# Checks common to both modes: valid config and the tools we always need to
# probe devices. Deliberately does NOT touch the local ACME certificate - the
# digest must still run (and report) when local issuance has failed.
preflight_common() {
    validate_config

    local missing=""
    for bin in openssl curl jq; do
        command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
    done
    # scp is needed for the scp-based SSH devices (UCG/RM1).
    if [ "$DEPLOY_UCG" = 1 ] || [ "$DEPLOY_RM1" = 1 ]; then
        for bin in ssh scp; do
            command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
        done
    fi
    # Docker uses ssh only (stdin push, no scp).
    if [ "$DEPLOY_DOCKER" = 1 ]; then
        command -v ssh >/dev/null 2>&1 || case "$missing" in *" ssh"*) : ;; *) missing="$missing ssh" ;; esac
    fi
    # if/then (not '&& die'): as the function's last command, a false '[ -n ]'
    # test would otherwise make preflight_common return 1 and trip 'set -e' at
    # the call site.
    if [ -n "$missing" ]; then die "Missing required binaries:$missing"; fi
    return 0
}

# Full deploy-mode preflight: common checks, plus resolving and sanity-checking
# the LOCAL certificate we are about to push, plus SSH target readiness.
preflight() {
    log_info "Running preflight checks"

    preflight_common

    resolve_cert_paths

    [ -f "$CERTIFICATE_FILE" ] || die "Certificate file not found: $CERTIFICATE_FILE"
    [ -f "$PRIVATE_KEY_FILE"  ] || die "Key file not found: $PRIVATE_KEY_FILE"

    CERT_CONTENT=$(cat "$CERTIFICATE_FILE")
    KEY_CONTENT=$(cat "$PRIVATE_KEY_FILE")

    # An expired/not-yet-valid cert would be deployed happily otherwise.
    if ! openssl x509 -in "$CERTIFICATE_FILE" -noout -checkend 0 >/dev/null 2>&1; then
        die "Certificate is EXPIRED: $CERTIFICATE_FILE - refusing to deploy it"
    fi

    if [ "$DEPLOY_UCG" = 1 ]; then check_ssh_target "UCG" "$UCG_SSH_KEY" "$UCG_IP" "$UCG_SSH_PORT"; fi
    if [ "$DEPLOY_RM1" = 1 ]; then check_ssh_target "RM1" "$RM1_SSH_KEY" "$RM1_IP" "$RM1_SSH_PORT"; fi
    if [ "$DEPLOY_DOCKER" = 1 ]; then check_ssh_target "Docker" "$DOCKER_SSH_KEY" "$DOCKER_IP" "$DOCKER_SSH_PORT"; fi

    log_info "Preflight OK"
}

###############################################################################
# WAIT / VERIFY HELPERS
###############################################################################

wait_api() {
    local label="$1" ip="$2"
    log_info "Waiting for $label API to recover"
    local i=0 code
    while [ "$i" -lt 24 ]; do
        code=$(curl -k -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 15 \
            "https://$ip/jsonrpc" 2>/dev/null || true)
        [ "$code" -eq 400 ] 2>/dev/null && { log_info "$label API is available"; return 0; }
        log_debug "$label API not ready (HTTP $code) - retrying in 5s"
        sleep 5
        i=$((i + 1))
    done
    die "$label API did not recover after 2 minutes"
}

###############################################################################
# FORTIGATE DEPLOYMENT (REST API)
###############################################################################

install_fgt_cert() {
    local pre=0
    log_info "--- FortiGate ---"
    device_precheck "FortiGate" "$FGT_IP" 443 \
        "reset->delete->import '$DOMAIN' and set admin-server-cert via REST API" || pre=$?
    [ "$pre" -eq 0 ] || return "$pre"

    local base_cmdb="https://$FGT_IP/api/v2/cmdb"
    local base_mon="https://$FGT_IP/api/v2/monitor"
    local cert_body key_body json_cert json_admin install_resp

    cert_body=$(printf '%s' "$CERT_CONTENT" | fgt_strip_pem)
    key_body=$(printf '%s'  "$KEY_CONTENT"  | fgt_strip_pem)

    json_cert=$(jq -n \
        --arg name "$DOMAIN" \
        --arg cert "$cert_body" \
        --arg key  "$key_body" '{
            type: "regular",
            certname: $name,
            file_content: $cert,
            key_file_content: $key,
            scope: "global"
        }')

    json_admin=$(jq -n --arg name "$DOMAIN" '{ "admin-server-cert": $name }')

    # Reset admin GUI cert to factory so the API stays reachable during the swap
    api_request PUT "FortiGate RESET" \
        "$base_cmdb/system/global" "$API_KEY_FGT" \
        '{"admin-server-cert":"Fortinet_Factory"}' >/dev/null

    # Remove the previous cert of the same name (harmless if it does not exist)
    api_request DELETE "FortiGate DELETE" \
        "$base_cmdb/vpn.certificate/local/$DOMAIN" "$API_KEY_FGT" >/dev/null

    # Import the new certificate + key
    install_resp=$(api_request POST "FortiGate INSTALL" \
        "$base_mon/vpn-certificate/local/import" "$API_KEY_FGT" "$json_cert")

    if printf '%s' "$install_resp" | jq -e '.status == "success"' >/dev/null 2>&1; then
        log_info "FortiGate certificate installed successfully"
    else
        die "FortiGate certificate installation failed - check $LOG_FILE for the API response"
    fi

    # Point the admin GUI at the new certificate
    api_request PUT "FortiGate SET-ADMIN" \
        "$base_cmdb/system/global" "$API_KEY_FGT" "$json_admin" >/dev/null

    log_info "FortiGate: admin-server-cert set to $DOMAIN"

    verify_deployed "$FGT_IP" 443 "FortiGate" || return 1
}

###############################################################################
# UBIQUITI CLOUD GATEWAY DEPLOYMENT
###############################################################################

upload_ucg_files() {
    log_info "Uploading certificate and key to UCG via SCP"
    scp_file "UCG" "$UCG_SSH_KEY" "$UCG_SSH_PORT" \
        "$CERTIFICATE_FILE" "$UCG_SSH_USER@$UCG_IP:/home/$UCG_SSH_USER/cert-upload/unifi-core.crt" \
        || die "UCG certificate upload failed"
    scp_file "UCG" "$UCG_SSH_KEY" "$UCG_SSH_PORT" \
        "$PRIVATE_KEY_FILE" "$UCG_SSH_USER@$UCG_IP:/home/$UCG_SSH_USER/cert-upload/unifi-core.key" \
        || die "UCG key upload failed"
    log_info "UCG upload complete"
}

deploy_ucg_cert() {
    log_info "Moving certificate files and restarting unifi-core"
    $UCG_SSH_CMD <<EOF
sudo mv /home/$UCG_SSH_USER/cert-upload/unifi-core.crt /data/unifi-core/config/unifi-core.crt
sudo mv /home/$UCG_SSH_USER/cert-upload/unifi-core.key /data/unifi-core/config/unifi-core.key
sudo chmod 644 /data/unifi-core/config/unifi-core.crt
sudo chmod 600 /data/unifi-core/config/unifi-core.key
sudo systemctl restart unifi-core || true
EOF
    log_info "UCG certificate deployed and unifi-core restarted"
}

install_ucg_cert() {
    log_info "--- Ubiquiti Cloud Gateway ---"
    [ -f "$UCG_SSH_KEY" ] || die "UCG SSH key missing: $UCG_SSH_KEY"
    UCG_SSH_CMD="ssh -T -o BatchMode=yes -o StrictHostKeyChecking=$SSH_HOST_KEY_CHECKING -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o LogLevel=ERROR -i $UCG_SSH_KEY -p $UCG_SSH_PORT $UCG_SSH_USER@$UCG_IP"

    local pre=0
    device_precheck "UCG" "$UCG_IP" 443 "scp cert/key and restart unifi-core" || pre=$?
    [ "$pre" -eq 0 ] || return "$pre"

    upload_ucg_files
    deploy_ucg_cert

    verify_deployed "$UCG_IP" 443 "UCG" || return 1
}

###############################################################################
# GL-Net RM-1 Deployment
###############################################################################

upload_rm1_files() {
    log_info "Uploading certificate and key to RM1 via SCP"
    scp_file "RM1" "$RM1_SSH_KEY" "$RM1_SSH_PORT" \
        "$CERTIFICATE_FILE" "$RM1_SSH_USER@$RM1_IP:/$RM1_SSH_USER/cert-upload/rm1-core.crt" \
        || die "RM1 certificate upload failed"
    scp_file "RM1" "$RM1_SSH_KEY" "$RM1_SSH_PORT" \
        "$PRIVATE_KEY_FILE" "$RM1_SSH_USER@$RM1_IP:/$RM1_SSH_USER/cert-upload/rm1-core.key" \
        || die "RM1 key upload failed"
    log_info "RM1 upload complete"
}

deploy_rm1_cert() {
    log_info "Moving certificate files and restarting nginx"
    local rm1_out rc=0
    # Remote combined output is captured and sent to the DEBUG log (shown on the
    # console only with -d). Remote xtrace is enabled only when this script runs
    # with -d ($VERBOSITY >= 2), passed to the remote as $1.
    rm1_out=$($RM1_SSH_CMD "sh -s -- $VERBOSITY" 2>&1 <<'EOF'
[ "${1:-1}" -ge 2 ] && set -x
set -e

NGINX="/usr/sbin/nginx"
PREFIX="/etc/kvmd/nginx"
CONF="/etc/kvmd/nginx-kvmd.conf"
PIDFILE="/run/kvmd/nginx.pid"

echo "Checking PID file..."
ls -l $PIDFILE || true

mv /root/cert-upload/rm1-core.crt /etc/kvmd/user/ssl/server.crt
mv /root/cert-upload/rm1-core.key /etc/kvmd/user/ssl/server.key

chmod 644 /etc/kvmd/user/ssl/server.crt
chmod 600 /etc/kvmd/user/ssl/server.key

echo "Testing nginx config..."
$NGINX -t -p $PREFIX -c $CONF -g "pid $PIDFILE; user root; error_log stderr;"

echo "Stopping nginx..."
kill "$(cat $PIDFILE 2>/dev/null)" 2>/dev/null || pkill nginx

sleep 2

echo "Starting nginx..."
$NGINX -p $PREFIX -c $CONF -g "pid $PIDFILE; user root; error_log stderr;"

sleep 1

echo "Verifying nginx is running..."
pgrep nginx || { echo "nginx failed to start"; exit 1; }
EOF
) || rc=$?

    printf '%s\n' "$rm1_out" | while IFS= read -r _line; do
        [ -n "$_line" ] && log_debug "RM1: $_line"
    done

    [ "$rc" -eq 0 ] || die "RM1 nginx deploy failed (rc=$rc) - see DEBUG log"
    log_info "RM1 certificate deployed and nginx restarted"
}

install_rm1_cert() {
    log_info "--- GL-Net RM1 ---"
    [ -f "$RM1_SSH_KEY" ] || die "RM1 SSH key missing: $RM1_SSH_KEY"
    RM1_SSH_CMD="ssh -T -o BatchMode=yes -o StrictHostKeyChecking=$SSH_HOST_KEY_CHECKING -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o LogLevel=ERROR -i $RM1_SSH_KEY -p $RM1_SSH_PORT $RM1_SSH_USER@$RM1_IP"

    local pre=0
    device_precheck "RM1" "$RM1_IP" 443 "scp cert/key and restart nginx" || pre=$?
    [ "$pre" -eq 0 ] || return "$pre"

    upload_rm1_files
    deploy_rm1_cert

    verify_deployed "$RM1_IP" 443 "RM1" || return 1
}

###############################################################################
# Docker host (docker-dashboard --cert-receive)
#
# PUSH model: the cert chain followed by exactly one private key is streamed on
# stdin to a forced command over SSH. No remote command, no scp (the forced
# command ignores any command and scp hangs for this user). The receiver
# validates, installs, reloads nginx, and prints a machine-readable last line:
#   DD-CERT-RECEIVE OK changed|unchanged sha256=AA:..:FF notafter=... live=yes|no
#   DD-CERT-RECEIVE FAIL <reason>
###############################################################################
install_docker_cert() {
    log_info "--- Docker host (docker-dashboard) ---"
    [ -f "$DOCKER_SSH_KEY" ] || die "Docker SSH key missing: $DOCKER_SSH_KEY"
    # No remote command: the server's forced command runs --cert-receive and
    # ignores anything we would pass. stdin carries the chain + key.
    DOCKER_SSH_CMD="ssh -T -o BatchMode=yes -o StrictHostKeyChecking=$SSH_HOST_KEY_CHECKING -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o LogLevel=ERROR -i $DOCKER_SSH_KEY -p $DOCKER_SSH_PORT $DOCKER_SSH_USER@$DOCKER_IP"

    local pre=0
    device_precheck "Docker" "$DOCKER_IP" "$DOCKER_HTTPS_PORT" \
        "push cert chain + key over SSH (docker-dashboard --cert-receive)" || pre=$?
    [ "$pre" -eq 0 ] || return "$pre"

    # --- Build the chain to send (nginx needs the full chain, not just leaf) ---
    local dir chain tmpchain=""
    dir=$(dirname "$CERTIFICATE_FILE")
    if [ -f "$dir/fullchain.pem" ]; then
        chain="$dir/fullchain.pem"
        log_debug "Docker: sending $chain"
    elif [ -f "$dir/chain.pem" ]; then
        tmpchain=$(mktemp "${TMPDIR:-/tmp}/ddchain.XXXXXX") || die "Docker: mktemp failed"
        cat "$CERTIFICATE_FILE" "$dir/chain.pem" > "$tmpchain"
        chain="$tmpchain"
        log_debug "Docker: sending leaf + $dir/chain.pem"
    else
        chain="$CERTIFICATE_FILE"
        log_warn "Docker: no fullchain.pem/chain.pem beside $CERTIFICATE_FILE - sending leaf only; browsers may complain about an incomplete chain"
    fi

    # The chain's FIRST certificate must be our leaf, or we would deploy the
    # wrong cert. (openssl x509 reads only the first cert from a bundle.)
    local chain_fp leaf_fp
    chain_fp=$(openssl x509 -in "$chain" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' | tr 'a-f' 'A-F')
    leaf_fp=$(file_fingerprint 2>/dev/null | sed 's/^.*=//' | tr 'a-f' 'A-F')
    if [ -z "$chain_fp" ] || [ "$chain_fp" != "$leaf_fp" ]; then
        if [ -n "$tmpchain" ]; then rm -f "$tmpchain"; fi
        die "Docker: chain's first certificate does not match the leaf ($CERTIFICATE_FILE) - refusing to push"
    fi

    # --- Push chain + key on stdin; capture result without 'die' in the pipe ---
    # The KEY is never logged and never written to a temp file - only streamed.
    local out rc=0
    out=$( { cat "$chain"; cat "$PRIVATE_KEY_FILE"; } | $DOCKER_SSH_CMD 2>&1 ) || rc=$?
    if [ -n "$tmpchain" ]; then rm -f "$tmpchain"; fi

    # 'out' is the RECEIVER's stdout/stderr (diagnostics + status line), not our
    # stdin, so it is safe to log.
    printf '%s\n' "$out" | while IFS= read -r _line; do
        [ -n "$_line" ] && log_debug "Docker: $_line"
    done

    local status
    status=$(printf '%s\n' "$out" | grep '^DD-CERT-RECEIVE ' | tail -n 1)

    # --- Failure: non-zero rc, or no OK status line ---
    case "$status" in
        "DD-CERT-RECEIVE OK"*) : ;;
        *)
            if [ -z "$status" ]; then
                log_error "Docker: no DD-CERT-RECEIVE status line (ssh rc=$rc). Last output:"
            else
                log_error "Docker: $status"
            fi
            printf '%s\n' "$out" | tail -n 5 | while IFS= read -r _l; do
                [ -n "$_l" ] && log_error "Docker: | $_l"
            done
            return 1
            ;;
    esac
    if [ "$rc" -ne 0 ]; then
        log_error "Docker: OK status but ssh exited $rc - treating as failure"
        return 1
    fi

    # --- Fingerprint check: receiver's sha256 must equal our leaf ---
    local remote_fp
    remote_fp=$(printf '%s' "$status" | sed -n 's/.*[[:space:]]sha256=\([^[:space:]]*\).*/\1/p' | tr 'a-f' 'A-F')
    if [ -z "$remote_fp" ]; then
        log_error "Docker: OK status had no sha256= field - cannot verify"
        return 1
    fi
    if [ "$remote_fp" != "$leaf_fp" ]; then
        log_error "Docker: received fingerprint ($remote_fp) does not match local leaf ($leaf_fp)"
        return 1
    fi

    local changed live
    changed=$(printf '%s' "$status" | awk '{print $3}')
    live=$(printf '%s' "$status" | sed -n 's/.*[[:space:]]live=\([^[:space:]]*\).*/\1/p')
    log_info "Docker: received (${changed:-?}), live=${live:-unknown}"
    if [ "$live" = "no" ]; then
        log_warn "Docker: receiver reports proxy not yet serving the new cert; verifying over TLS"
    fi

    verify_deployed "$DOCKER_IP" "$DOCKER_HTTPS_PORT" "Docker" || return 1
}

###############################################################################
# FORTIMANAGER / FORTIANALYZER - shared logic
###############################################################################

# Populates JSON_RESET, JSON_DELETE, JSON_CERT, JSON_ADMIN
build_json_payloads() {
    JSON_RESET=$(jq -n '{
        "jsonrpc": "2.0", "method": "set",
        "params": [{"data": {"admin_server_cert": "server.crt"},
                    "url": "/cli/global/system/admin/setting"}]
    }')

    JSON_DELETE=$(jq -n --arg name "$DOMAIN" '{
        "jsonrpc": "2.0", "method": "delete",
        "params": [{"url": ("/cli/global/system/certificate/local/" + $name)}]
    }')

    JSON_CERT=$(jq -n \
        --arg name "$DOMAIN" \
        --arg cert "$CERT_CONTENT" \
        --arg key  "$KEY_CONTENT" '{
        "id": 1, "jsonrpc": "1.0", "method": "add", "verbose": 1,
        "params": [{
            "data": {
                "certificate": $cert,
                "comment": "Deployed via ACME deploy script",
                "name": $name,
                "private-key": $key
            },
            "url": "/cli/global/system/certificate/local"
        }]
    }')

    JSON_ADMIN=$(jq -n --arg name "$DOMAIN" '{
        "jsonrpc": "2.0", "method": "set",
        "params": [{"data": {"admin_server_cert": $name},
                    "url": "/cli/global/system/admin/setting"}]
    }')
}

install_fortinet_cert() {
    local label="$1" ip="$2" api_key="$3"
    local base_url="https://$ip/jsonrpc"
    local pre=0

    log_info "--- $label ---"

    device_precheck "$label" "$ip" 443 \
        "reset->delete->install '$DOMAIN' and set admin cert via jsonrpc" || pre=$?
    [ "$pre" -eq 0 ] || return "$pre"

    build_json_payloads

    # Reset to built-in cert first so the API remains reachable during the swap
    api_post "$label RESET"     "$base_url" "$api_key" "$JSON_RESET"  >/dev/null
    wait_api "$label" "$ip"

    api_post "$label DELETE"    "$base_url" "$api_key" "$JSON_DELETE" >/dev/null

    local result
    result=$(api_post "$label INSTALL" "$base_url" "$api_key" "$JSON_CERT")
    if printf '%s' "$result" | jq -e '.result[0].status.code == 0' >/dev/null 2>&1; then
        log_info "$label certificate installed successfully"
    else
        die "$label certificate installation failed - check $LOG_FILE for the API response"
    fi

    api_post "$label SET-ADMIN" "$base_url" "$api_key" "$JSON_ADMIN"  >/dev/null

    # The daemon bounces here, so this also confirms the web service came back
    verify_deployed "$ip" 443 "$label" || return 1
}

###############################################################################
# TRUENAS HELPERS
###############################################################################

truenas_get() {
    local endpoint="$1"
    curl -s -k \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -H "Authorization: Bearer $TRUENAS_API_KEY" \
        "https://$TRUENAS_IP/api/v2.0/$endpoint" || true
}

truenas_post() {
    local endpoint="$1"
    local payload="$2"
    curl -s -k \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -X POST \
        "https://$TRUENAS_IP/api/v2.0/$endpoint" \
        -H "Authorization: Bearer $TRUENAS_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" || true
}

truenas_put() {
    local endpoint="$1"
    local payload="$2"
    curl -s -k \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -X PUT \
        "https://$TRUENAS_IP/api/v2.0/$endpoint" \
        -H "Authorization: Bearer $TRUENAS_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" || true
}

###############################################################################
# TRUENAS CERT FUNCTIONS
###############################################################################

# All cert ids whose name is the base name OR a timestamped variant of it
# ("<DOMAIN>-20260713170259"). Matching the prefix is what lets us import a
# uniquely-named cert and still find the old ones to clean up.
tn_find_all_cert_ids() {
    truenas_get "certificate" \
        | jq -r --arg name "$TRUENAS_CERT_NAME" \
            '.[] | select(.name==$name or (.name|startswith($name + "-"))) | .id' 2>/dev/null || true
}

tn_delete_cert() {
    local cert_id="$1"
    local body code
    [ -z "$cert_id" ] && return 0
    log_info "TrueNAS deleting existing cert ID $cert_id"

    # The response was previously discarded to /dev/null, which is why a REFUSED
    # delete looked identical to a successful one. Log body + HTTP status.
    body=$(curl -s -k -w '\n%{http_code}' \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -X DELETE \
        "https://$TRUENAS_IP/api/v2.0/certificate/id/$cert_id" \
        -H "Authorization: Bearer $TRUENAS_API_KEY" 2>/dev/null) || body=""

    code=$(printf '%s' "$body" | tail -n1)
    body=$(printf '%s' "$body" | sed '$d')

    log_debug "TrueNAS DELETE id=$cert_id http=$code response: $body"

    case "$code" in
        2*) return 0 ;;
        *)  log_warn "TrueNAS DELETE of cert $cert_id returned HTTP ${code:-?}: $body"
            return 1
            ;;
    esac
}

# Poll for a certificate id that is NOT in $1 (a space-separated exclusion list).
#
# Guards a real failure mode seen in the field: if the DELETE is refused, the OLD
# cert is still present under the same name, so a plain find-by-name returns the
# OLD id - which then gets assigned to the UI and logged as "imported certificate
# ID: 42", the very id we just failed to delete. Only an id we did not already
# know about counts as the freshly imported certificate.
tn_wait_for_new() {
    local exclude="$1"
    local i=0 id k known
    while [ "$i" -lt "$VERIFY_RETRIES" ]; do
        for id in $(tn_find_all_cert_ids); do
            echo "$id" | grep -Eq '^[0-9]+$' || continue
            known=0
            for k in $exclude; do
                [ "$id" = "$k" ] && known=1
            done
            if [ "$known" -eq 0 ]; then
                printf '%s' "$id"
                return 0
            fi
        done
        sleep "$VERIFY_INTERVAL"
        i=$((i + 1))
    done
    return 1
}

tn_import_certificate() {
    local name="$1"
    local payload response

    payload=$(jq -n \
        --arg name "$name" \
        --arg cert "$CERT_CONTENT" \
        --arg key "$KEY_CONTENT" \
        '{
            name: $name,
            certificate: $cert,
            privatekey: $key,
            create_type: "CERTIFICATE_CREATE_IMPORTED"
        }')

    log_info "TrueNAS importing certificate as '$name' (async job may take a few seconds)"

    # On SCALE this POST returns a job id, not the cert object, so we do not
    # parse the id here - the caller polls tn_wait_for_new after this.
    response=$(truenas_post "certificate" "$payload")
    log_debug "TrueNAS import response: $response"
}

tn_assign_ui_certificate() {
    local cert_id="$1"
    local payload response current

    echo "$cert_id" | grep -Eq '^[0-9]+$' || {
        log_warn "Invalid TrueNAS cert ID: $cert_id"
        return 1
    }

    payload=$(printf '{ "ui_certificate": %s }' "$cert_id")

    log_info "TrueNAS assigning UI certificate ID $cert_id"

    response=$(truenas_put "system/general" "$payload") || response=""
    log_debug "TrueNAS assignment response: $response"

    # Confirm the assignment actually took effect rather than assuming success
    current=$(truenas_get "system/general" \
        | jq -r '(.ui_certificate.id? // .ui_certificate?) // empty' 2>/dev/null || true)

    if [ "$current" = "$cert_id" ]; then
        return 0
    fi

    log_warn "TrueNAS UI certificate is '$current' after assignment, expected '$cert_id'"
    return 1
}

tn_restart_ui() {
    log_info "Restarting TrueNAS UI"
    curl -s -k \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -X POST \
        "https://$TRUENAS_IP/api/v2.0/system/general/ui_restart" \
        -H "Authorization: Bearer $TRUENAS_API_KEY" \
        >/dev/null || true
}

install_truenas_cert() {
    local cert_id existing id new_name deleted_any
    local pre=0

    log_info "--- TrueNAS SCALE ---"

    [ -n "$TRUENAS_API_KEY" ] \
        || die "TRUENAS_API_KEY not configured"

    device_precheck "TrueNAS" "$TRUENAS_IP" 443 \
        "import a new cert, assign it to the UI, restart the UI, then delete the old cert" || pre=$?
    [ "$pre" -eq 0 ] || return "$pre"

    # ORDER MATTERS. TrueNAS refuses to delete a certificate that is currently
    # assigned as the UI certificate, and it refuses to import a second cert
    # with the same name - so delete-then-import deadlocks: the delete is denied
    # because the cert is in use, then the import collides on the name and the
    # box keeps serving the old certificate.
    #
    # Instead: import under a UNIQUE name -> point the UI at it -> verify ->
    # and only then delete the old cert, which by that point is no longer in use.
    existing=$(tn_find_all_cert_ids)
    [ -n "$existing" ] && log_info "TrueNAS existing cert id(s) for this name: $existing"

    new_name="${TRUENAS_CERT_NAME}-$(date '+%Y%m%d%H%M%S')"

    tn_import_certificate "$new_name"

    # Only an id that was NOT already present counts as the new import.
    cert_id=$(tn_wait_for_new "$existing") || cert_id=""
    [ -n "$cert_id" ] \
        || die "TrueNAS: import of '$new_name' produced no new certificate - see the import response in $LOG_FILE"

    log_info "TrueNAS imported NEW certificate ID: $cert_id ($new_name)"

    tn_assign_ui_certificate "$cert_id" \
        || die "TrueNAS UI certificate assignment failed or did not take effect"

    tn_restart_ui

    verify_deployed "$TRUENAS_IP" 443 "TrueNAS" || return 1

    # The old cert is no longer in use, so it can finally be removed. Failure
    # here is NOT fatal: the new cert is already live and verified. Leftovers
    # are matched by prefix on the next run, so they cannot accumulate silently.
    deleted_any=0
    for id in $existing; do
        echo "$id" | grep -Eq '^[0-9]+$' || continue
        [ "$id" = "$cert_id" ] && continue
        if tn_delete_cert "$id"; then
            deleted_any=1
        else
            log_warn "TrueNAS: could not delete old cert $id (it will be retried next run)"
        fi
    done
    [ "$deleted_any" -eq 1 ] && log_info "TrueNAS: old certificate(s) removed"

    log_info "TrueNAS deployment complete"
}

###############################################################################
# MAIN
###############################################################################

# Send the run summary to the internal SMTP forwarder using curl's smtp://
# support (curl is already a hard dependency, so this adds nothing to install).
#
# This function is deliberately incapable of changing the outcome of the run:
# every failure path returns 0 and only logs. A broken mail relay must never
# turn a successful deployment into a failed one, nor mask a real failure.
notify_email() {
    local subject="$1" status_word="$2"
    local msg rc=0 errors

    [ "$NOTIFY_EMAIL" -eq 1 ] || return 0
    [ "$DRY_RUN" -eq 0 ] || { log_debug "Dry-run: suppressing notification email"; return 0; }

    # Did anything actually change this run?
    local changed=0
    case "$DEVICE_RESULTS" in
        *=UPDATED*) changed=1 ;;
    esac

    case "$NOTIFY_ON" in
        never)
            return 0
            ;;
        always)
            :
            ;;
        failure)
            if [ "$OVERALL_RC" -eq 0 ]; then
                log_debug "NOTIFY_ON=failure and run succeeded - no email sent"
                return 0
            fi
            ;;
        changes|*)
            [ "$NOTIFY_ON" = "changes" ] \
                || log_warn "Unknown NOTIFY_ON '$NOTIFY_ON' - treating as 'changes'"
            if [ "$OVERALL_RC" -eq 0 ] && [ "$changed" -eq 0 ]; then
                log_debug "NOTIFY_ON=changes: nothing deployed and nothing failed - no email sent"
                return 0
            fi
            ;;
    esac

    if [ -z "$SMTP_HOST" ] || [ -z "$MAIL_TO" ] || [ -z "$MAIL_FROM" ]; then
        log_warn "Email notification enabled but SMTP_HOST/MAIL_TO/MAIL_FROM is empty - skipping"
        return 0
    fi

    # Pull any WARN/ERROR lines from this run's log so the mail is actionable
    # on its own. The log is already secret-redacted by _emit.
    errors=$(grep -E '\[(WARN|ERROR)\]' "$LOG_FILE" 2>/dev/null | head -n 25) || errors=""
    [ -n "$errors" ] || errors="(none)"

    msg=$(mktemp) || { log_warn "Could not create temp file for email - skipping"; return 0; }

    # SMTP requires CRLF line endings; awk gives us that portably (BSD sed does
    # not understand \r). A blank line separates headers from the body.
    {
        printf 'From: %s\n'    "$MAIL_FROM"
        printf 'To: %s\n'      "$MAIL_TO"
        printf 'Subject: %s\n' "$subject"
        printf 'Date: %s\n'    "$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"
        printf 'X-Mailer: cert-deploy %s\n' "$SCRIPT_VERSION"
        printf '\n'
        printf 'Certificate deployment %s on %s\n\n' "$status_word" "$(hostname)"
        printf 'Summary:%s\n\n' "$DEVICE_RESULTS"
        printf 'CURRENT     = already serving the correct certificate\n'
        printf 'UPDATED     = replaced and verified over TLS\n'
        printf 'FAILED      = deploy error, or still serving the old certificate\n'
        printf 'UNREACHABLE = no TLS response; deployment not attempted\n\n'
        printf 'Warnings/errors this run:\n%s\n\n' "$errors"
        printf 'Full log: %s\n' "$LOG_FILE"
    } | awk '{ printf "%s\r\n", $0 }' > "$msg"

    curl -s --url "smtp://$SMTP_HOST:$SMTP_PORT" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$SMTP_TIMEOUT" \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$msg" >/dev/null 2>&1 || rc=$?

    rm -f "$msg"

    if [ "$rc" -eq 0 ]; then
        log_info "Notification email sent to $MAIL_TO"
    else
        # Non-fatal by design - see the comment above.
        log_warn "Failed to send notification email via $SMTP_HOST:$SMTP_PORT (curl rc=$rc)"
    fi
    return 0
}

# Run one device deployment in isolation. A failure inside (die/exit, or any
# error under 'set -e') is confined to the subshell, recorded, and does NOT
# abort the remaining devices.
# NOTE: the subshell must NOT sit in an if/&&/|| condition - that would disable
# 'set -e' inside it (POSIX). Instead errexit is toggled around a standalone
# subshell that re-enables it explicitly.
# Status codes returned by the install_* functions:
#   0  -> UPDATED      (deployed AND re-verified as serving the new cert)
#   10 -> CURRENT      (was already correct; no action taken)
#   20 -> UNREACHABLE  (no TLS response; nothing attempted)
#   30 -> DRY-RUN      (would have deployed)
#   *  -> FAILED       (deploy error, or still serving the old cert afterwards)
run_device() {
    local enabled="$1" label="$2"; shift 2
    local rc status

    # Disabled devices are inert: the guard is BEFORE the subshell and the
    # precheck TLS probe, so a disabled device gets no probe, no API call and no
    # SSH. It is recorded as DISABLED and left out of the exit code / email.
    if [ "$enabled" != "1" ]; then
        log_info "--- $label (disabled - skipping) ---"
        DEVICE_RESULTS="$DEVICE_RESULTS $label=DISABLED"
        return 0
    fi

    set +e
    ( set -e; "$@" )
    rc=$?
    set -e

    case "$rc" in
        0)  status="UPDATED"     ;;
        10) status="CURRENT"     ;;
        20) status="UNREACHABLE" ;;
        30) status="DRY-RUN"     ;;
        *)  status="FAILED"      ;;
    esac

    case "$status" in
        FAILED)
            OVERALL_RC=1
            log_error "$label FAILED - continuing with remaining devices"
            ;;
        UNREACHABLE)
            OVERALL_RC=1
            ;;
    esac

    DEVICE_RESULTS="$DEVICE_RESULTS $label=$status"
}

# The device roster as iterable rows: "ENABLEDVAR|Label|host|port".
# One source of truth for both the digest and any future per-device loop.
# (FMG/FAZ use their own IPs; all serve TLS on 443 for probing.)
device_roster() {
    cat <<ROSTER
$DEPLOY_FGT|FortiGate|$FGT_IP|443
$DEPLOY_UCG|UCG|$UCG_IP|443
$DEPLOY_RM1|RM1|$RM1_IP|443
$DEPLOY_DOCKER|Docker|$DOCKER_IP|$DOCKER_HTTPS_PORT
$DEPLOY_TRUENAS|TrueNAS|$TRUENAS_IP|443
$DEPLOY_FMG|FortiManager|$FMG_IP|443
$DEPLOY_FAZ|FortiAnalyzer|$FAZ_IP|443
ROSTER
}

# Read-only fleet certificate report. Probes every ENABLED device's live cert,
# lists days-to-expiry, flags anything within CERT_WARN_DAYS or unreachable, and
# emails the report unconditionally. Disabled devices are listed but not probed.
# Makes no changes. Exit non-zero if anything is expiring soon or unreachable.
run_digest() {
    log_info "=== cert digest v$SCRIPT_VERSION on $(hostname) (read-only) ==="
    # Common checks only: the digest must report even when the LOCAL cert is
    # missing or expired, so it does not resolve/validate the ACME cert.
    preflight_common

    DIGEST_ROWS=""      # accumulated "Label STATUS detail" lines
    DIGEST_RC=0         # non-zero if anything needs attention

    local enabled label host port days line
    while IFS='|' read -r enabled label host port; do
        [ -n "$label" ] || continue

        if [ "$enabled" != "1" ]; then
            line=$(printf '  %-14s %-11s %s' "$label" "DISABLED" "(not checked)")
            DIGEST_ROWS="$DIGEST_ROWS$line
"
            continue
        fi

        days=$(live_cert_days_left "$host" "$port") || days=""

        if [ -z "$days" ]; then
            line=$(printf '  %-14s %-11s %s' "$label" "UNREACHABLE" "no TLS response on $host:$port")
            DIGEST_RC=1
        elif [ "$days" -lt 0 ]; then
            line=$(printf '  %-14s %-11s %s' "$label" "EXPIRED" "expired $(( -days )) day(s) ago")
            DIGEST_RC=1
        elif [ "$days" -le "$CERT_WARN_DAYS" ]; then
            line=$(printf '  %-14s %-11s %s' "$label" "EXPIRING" "$days day(s) left (<= $CERT_WARN_DAYS)")
            DIGEST_RC=1
        else
            line=$(printf '  %-14s %-11s %s' "$label" "OK" "$days day(s) left")
        fi
        DIGEST_ROWS="$DIGEST_ROWS$line
"
    done <<ROSTER
$(device_roster)
ROSTER

    # Log every row too, so the per-run log is self-contained.
    printf '%s' "$DIGEST_ROWS" | while IFS= read -r line; do
        [ -n "$line" ] && log_info "digest:$line"
    done

    if [ "$DIGEST_RC" -eq 0 ]; then
        log_info "Digest: all enabled devices OK"
    else
        log_warn "Digest: one or more devices need attention"
    fi

    _digest_body() {
        local status_line
        status_line="all enabled devices OK"
        [ "$DIGEST_RC" -eq 0 ] || status_line="ATTENTION NEEDED - see flags below"
        printf 'Certificate status digest for %s\n' "$(hostname)"
        printf 'Generated: %s\n\n' "$(LC_ALL=C date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'Overall: %s\n\n' "$status_line"
        printf '%s\n' "$DIGEST_ROWS"
        printf 'Legend:\n'
        printf '  OK          serving a cert with more than %s days left\n' "$CERT_WARN_DAYS"
        printf '  EXPIRING    within %s days of expiry - renewal/deploy may be failing\n' "$CERT_WARN_DAYS"
        printf '  EXPIRED     past its notAfter date\n'
        printf '  UNREACHABLE no TLS response when probed\n'
        printf '  DISABLED    deployment turned off in config; not checked\n\n'
        printf 'This is a read-only report; no changes were made.\n'
        printf 'Full log: %s\n' "$LOG_FILE"
    }

    if [ "$NOTIFY_EMAIL" -eq 1 ]; then
        local subj
        subj="[cert-digest] OK on $(hostname)"
        [ "$DIGEST_RC" -eq 0 ] || subj="[cert-digest] ATTENTION on $(hostname)"
        send_mail "$subj" _digest_body || true   # mail failure never changes rc
    fi

    printf '\nDigest complete. Full log: %s\n' "$LOG_FILE"
    return "$DIGEST_RC"
}

main() {
    if [ "$MODE" = "digest" ]; then
        run_digest
        return $?
    fi

    log_info "=== cert deploy v$SCRIPT_VERSION starting (host=$(hostname) pid=$$ verbosity=$VERBOSITY dry_run=$DRY_RUN) ==="
    [ "$DRY_RUN" -eq 1 ] && log_warn "DRY-RUN mode: no changes will be made"
    preflight

    run_device "$DEPLOY_FGT"     "FortiGate"     install_fgt_cert
    run_device "$DEPLOY_UCG"     "UCG"           install_ucg_cert
    run_device "$DEPLOY_RM1"     "RM1"           install_rm1_cert
    run_device "$DEPLOY_DOCKER"  "Docker"        install_docker_cert
    run_device "$DEPLOY_TRUENAS" "TrueNAS"       install_truenas_cert
    run_device "$DEPLOY_FMG"     "FortiManager"  install_fortinet_cert "FortiManager"  "$FMG_IP" "$API_KEY_FMG"
    run_device "$DEPLOY_FAZ"     "FortiAnalyzer" install_fortinet_cert "FortiAnalyzer" "$FAZ_IP" "$API_KEY_FAZ"

    # Expiry sweep: an enabled, reachable device still serving a cert within
    # CERT_WARN_DAYS means deployment to it has been silently failing. Surface it
    # as a WARN and force a notification even if every device reported CURRENT.
    local enabled label host port days
    EXPIRY_WARN=""
    while IFS='|' read -r enabled label host port; do
        [ -n "$label" ] || continue
        [ "$enabled" = "1" ] || continue
        days=$(live_cert_days_left "$host" "$port") || days=""
        [ -n "$days" ] || continue        # unreachable already handled by run_device
        if [ "$days" -lt 0 ]; then
            log_warn "$label: certificate EXPIRED $(( -days )) day(s) ago"
            EXPIRY_WARN="$EXPIRY_WARN $label=EXPIRED"
            OVERALL_RC=1
        elif [ "$days" -le "$CERT_WARN_DAYS" ]; then
            log_warn "$label: certificate expires in $days day(s) (<= $CERT_WARN_DAYS)"
            EXPIRY_WARN="$EXPIRY_WARN $label=${days}d"
            OVERALL_RC=1
        fi
    done <<ROSTER
$(device_roster)
ROSTER

    log_info "=== Summary:$DEVICE_RESULTS ==="
    if [ "$OVERALL_RC" -ne 0 ]; then
        if [ -n "$EXPIRY_WARN" ]; then
            log_error "Expiry warning -$EXPIRY_WARN"
        fi
        log_error "One or more devices FAILED, UNREACHABLE, or EXPIRING -$DEVICE_RESULTS"
        notify_email "[cert-deploy] ATTENTION on $(hostname)" "reported problems"
    else
        log_info "All devices verified serving the current certificate"
        case "$DEVICE_RESULTS" in
            *=UPDATED*)
                notify_email "[cert-deploy] certificate DEPLOYED on $(hostname)" \
                             "deployed and verified a new certificate"
                ;;
            *)
                notify_email "[cert-deploy] OK on $(hostname)" \
                             "found every device already current (no changes)"
                ;;
        esac
    fi
    printf '\nDone. Full log: %s\n' "$LOG_FILE"
    return "$OVERALL_RC"
}

main
