#!/usr/bin/env bash
# =============================================================================
#  docker-dashboard.sh
#  All-in-one installer for a Docker host: apps (Pi-hole, Portainer, Grafana
#  internet monitoring, Guacamole, MeshCentral, optional Greenbone), an HTTPS
#  reverse proxy + landing page on 80/443, update-all, and host-to-host migration
#
#  Version   : SCRIPT_VERSION below is the authoritative version string
#  Changelog : CHANGELOG.md (per-version history)
#  Docs      : README.md
#  Author    : netgeek1 (Claude.ai)
#
#  Usage     : sudo ./docker-dashboard.sh                     interactive menu
#              sudo ./docker-dashboard.sh --install           full install / reconfigure
#              sudo ./docker-dashboard.sh --export            on the OLD host: bundle apps + data
#              sudo ./docker-dashboard.sh --install --import FILE   new host from a bundle
#              sudo ./docker-dashboard.sh --update-all        update every container on the host
#              sudo ./docker-dashboard.sh --help              all CLI flags
#
#  Requires  : bash 4.4+, Ubuntu or Debian (amd64/arm64), systemd, root (re-execs via sudo)
#              --export only needs bash, docker, tar and openssl (works on old Docker 20.10 hosts)
#  License   : see LICENSE in the repository
# =============================================================================
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION="2.4.0"
readonly SCRIPT_NAME="docker-dashboard"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH

# -----------------------------------------------------------------------------
# PATHS (overridable via environment for testing; normal use leaves these alone)
# -----------------------------------------------------------------------------
DD_CONF_DIR="${DD_CONF_DIR:-/etc/docker-dashboard}"
DD_STATE_DIR="${DD_STATE_DIR:-/var/lib/docker-dashboard}"
DD_LOG_DIR="${DD_LOG_DIR:-/var/log/docker-dashboard}"
DD_INSTALL_BIN="${DD_INSTALL_BIN:-/usr/local/sbin/docker-dashboard}"
DD_LOCK_FILE="${DD_LOCK_FILE:-/run/docker-dashboard.lock}"
DD_HEALTH_LOCK="${DD_HEALTH_LOCK:-/run/docker-dashboard-health.lock}"
DD_UNIT_DIR="${DD_UNIT_DIR:-/etc/systemd/system}"
DD_RESOLV_CONF="${DD_RESOLV_CONF:-/etc/resolv.conf}"
DD_RESOLVED_DIR="${DD_RESOLVED_DIR:-/etc/systemd/resolved.conf.d}"
DD_RESOLVED_UPSTREAM="${DD_RESOLVED_UPSTREAM:-/run/systemd/resolve/resolv.conf}"

CONF_FILE="$DD_CONF_DIR/dashboard.conf"
SERVICES_FILE="$DD_CONF_DIR/services.conf"
SECRETS_FILE="$DD_CONF_DIR/secrets.enc"
KEY_FILE="$DD_CONF_DIR/.secrets.key"
FETCH_KEY="$DD_CONF_DIR/certfetch_ed25519"
FETCH_KNOWN_HOSTS="$DD_CONF_DIR/certfetch_known_hosts"
LOG_KEEP=30

readonly PROJECT_NAME="docker-dashboard"
readonly CONTAINER_NAME="docker-dashboard"
readonly WATCHTOWER_NAME="docker-dashboard-watchtower"
readonly PROXY_NET="dd-proxy"
readonly APP_PREFIX="dd-"
readonly UNIT_HEALTH="docker-dashboard-health"
readonly UNIT_UPDATE="docker-dashboard-update"
readonly UNIT_CERT="docker-dashboard-cert"
readonly FILES_MOUNT="/srv/files"
readonly EXPORT_FORMAT="docker-dashboard-export v1"

# Fresh (non-imported) monitoring configs come from geerlingguy/internet-pi at this commit.
readonly INTERNET_PI_REF="8bf88e99e6a855ce5a8e3294fc6aeb63cebe1bd6"
readonly GVM_COMPOSE_DEFAULT="https://greenbone.github.io/docs/latest/_static/compose.yaml"

# -----------------------------------------------------------------------------
# APP CATALOG
# -----------------------------------------------------------------------------
APPS=( pihole portainer monitoring guacamole meshcentral gvm )
declare -A APP_TITLE=( [pihole]="Pi-hole" [portainer]="Portainer" [monitoring]="Internet monitoring (Grafana + Prometheus)"
                       [guacamole]="Guacamole" [meshcentral]="MeshCentral" [gvm]="Greenbone / OpenVAS (GVM)" )
# Secrets each app needs (generated if not imported or entered)
declare -A APP_SECRETS=( [pihole]="PIHOLE_PASSWORD" [portainer]="" [monitoring]="GRAFANA_ADMIN_PASSWORD"
                         [guacamole]="GUAC_DB_PASSWORD" [meshcentral]="" [gvm]="GVM_ADMIN_PASSWORD" )
SECRET_KEYS=( PIHOLE_PASSWORD GRAFANA_ADMIN_PASSWORD GUAC_DB_PASSWORD GVM_ADMIN_PASSWORD )

# -----------------------------------------------------------------------------
# CONFIG MODEL (-> $CONF_FILE)
# -----------------------------------------------------------------------------
CONF_KEYS=( DASH_TITLE DOMAIN DASH_SUBDOMAIN HOST_ADDR EXTRA_NAMES HTTP_PORT HTTPS_PORT TIMEZONE
            DEPLOY_DIR STACKS_DIR NGINX_IMAGE
            CERT_MODE CERT_FILE CERT_KEY_FILE CERT_DAYS CERT_FETCH_SOURCE CERT_FETCH_CERT CERT_FETCH_KEY
            FILES_DIR FILES_HTTP HEALTH_CHECK HEALTH_INTERVAL
            HOST_PANEL HOST_DISK_WARN HOST_DISK_CRIT HOST_MEM_WARN HOST_MEM_CRIT HOST_LOAD_WARN HOST_LOAD_CRIT
            UPDATE_SCHEDULE UPDATE_DAY UPDATE_TIME UPDATE_PRUNE UPDATE_EXCLUDE UPDATE_DELEGATE WATCHTOWER_IMAGE
            SECRETS_BACKEND
            APP_PIHOLE PIHOLE_IMAGE PIHOLE_SUBDOMAIN PIHOLE_WEB_PORT PIHOLE_DNS_PORT PIHOLE_LOCAL_DNS PIHOLE_EXTRA_ENV
            APP_PORTAINER PORTAINER_IMAGE PORTAINER_SUBDOMAIN PORTAINER_HTTPS_PORT PORTAINER_EDGE_PORT
            APP_MONITORING GRAFANA_IMAGE PROMETHEUS_IMAGE NODEEXP_IMAGE BLACKBOX_IMAGE SPEEDTEST_IMAGE
            GRAFANA_SUBDOMAIN PROMETHEUS_SUBDOMAIN GRAFANA_PORT PROMETHEUS_PORT NODEEXP_PORT BLACKBOX_PORT SPEEDTEST_PORT
            PROMETHEUS_RETENTION GRAFANA_PLUGINS GRAFANA_EXTRA_ENV
            APP_GUACAMOLE GUACAMOLE_IMAGE GUACD_IMAGE GUAC_POSTGRES_IMAGE GUACAMOLE_SUBDOMAIN GUACAMOLE_TLS_PORT
            GUAC_DB_NAME GUAC_DB_USER
            APP_MESHCENTRAL MESHCENTRAL_IMAGE MESHCENTRAL_SUBDOMAIN MESHCENTRAL_PORT
            APP_GVM GVM_SUBDOMAIN GVM_COMPOSE_URL )
declare -A CFG=()
declare -A SECRETS=()
SECRETS_LOADED=0

# Services list (-> $SERVICES_FILE, one "group|name|url|description" per line) -- custom links
SVC_GROUP=() SVC_NAME=() SVC_URL=() SVC_DESC=()

# -----------------------------------------------------------------------------
# RUNTIME STATE
# -----------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
CONFIRM_KEYWORD=""
PASSPHRASE_FILE=""
IMPORT_FILE=""
EXPORT_NO_METRICS=0
EXPORT_LEAVE_STOPPED=0
LOG_FILE=""
REAL_USER="${SUDO_USER:-root}"
CONFIG_LOADED=0
DET_IP="" DET_IFACE=""
US=$'\x1f'   # field separator for records with empty fields (read collapses repeated tabs)
UPDATE_FAILS=0
CERT_FETCH_FAILED=0
DEPLOY_DIR="" STACKS_DIR=""
# -----------------------------------------------------------------------------
# COLORS / LOGGING
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; D=$'\e[2m'; NC=$'\e[0m'
else
    R=""; G=""; Y=""; C=""; B=""; D=""; NC=""
fi

_log_file() {
    [[ -n "$LOG_FILE" ]] || return 0
    printf '[%s] [%-6s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true
}
log_info()  { printf '  %s\n' "$*"; _log_file INFO "$*"; }
log_ok()    { printf '  %s[ OK ]%s %s\n' "$G" "$NC" "$*"; _log_file OK "$*"; }
log_warn()  { printf '  %s[WARN]%s %s\n' "$Y" "$NC" "$*" >&2; _log_file WARN "$*"; }
log_error() { printf '  %s[FAIL]%s %s\n' "$R" "$NC" "$*" >&2; _log_file ERROR "$*"; }
log_step()  { printf '\n%s==>%s %s%s%s\n' "$C" "$NC" "$B" "$*" "$NC"; _log_file STEP "$*"; }
die()       { log_error "$*"; exit 1; }

on_err() {
    local rc=$?
    _log_file ERROR "rc=$rc line=${BASH_LINENO[0]} cmd=${BASH_COMMAND}"
    printf '  %s[FAIL]%s rc=%s at line %s: %s\n' "$R" "$NC" "$rc" "${BASH_LINENO[0]}" "$BASH_COMMAND" >&2
}
trap on_err ERR

# init_logging ACTION -- one log file per run, newest $LOG_KEEP kept
init_logging() {
    mkdir -p "$DD_LOG_DIR"
    chmod 750 "$DD_LOG_DIR"
    LOG_FILE="$DD_LOG_DIR/run-${1}-$(date +%F_%H-%M-%S).log"
    : >"$LOG_FILE"
    chmod 640 "$LOG_FILE"
    local old
    while IFS= read -r old; do rm -f -- "$old"; done < <(ls -1t "$DD_LOG_DIR"/run-*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)))
}

# -----------------------------------------------------------------------------
# GENERIC HELPERS
# -----------------------------------------------------------------------------
is_tty() { [[ -t 0 ]]; }

# run CMD...  -- execute (or print in dry-run)
run() {
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s %s\n' "$D" "$NC" "$*"
        _log_file DRYRUN "$*"
        return 0
    fi
    _log_file RUN "$*"
    "$@"
}

# run_logged CMD...  -- like run, but also tees command output into the run log
# On a terminal the command writes straight to it, so docker/apt keep their in-place progress bars
# (a pipe makes them print one line per update); the log gets the command and its exit code.
# Without a terminal (timers) the full output is teed into the log.
run_logged() {
    if (( DRY_RUN )); then run "$@"; return 0; fi
    _log_file RUN "$*"
    local rc=0
    if [[ -t 1 || -z "$LOG_FILE" ]]; then
        "$@" || rc=$?
        _log_file RC "$rc (output shown on the terminal)"
    else
        "$@" 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
    fi
    return "$rc"
}

# write_file PATH MODE OWNER:GROUP  (content on stdin), atomic. Returns 0; sets WROTE=1 if content changed.
WROTE=0
write_file() {
    local path=$1 mode=$2 owner=$3 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 0
    fi
    WROTE=1
    if (( DRY_RUN )); then
        rm -f "$tmp"
        printf '  %s[dry-run]%s write %s (mode %s, %s)\n' "$D" "$NC" "$path" "$mode" "$owner"
        _log_file DRYRUN "write $path"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    local final; final=$(mktemp "$(dirname "$path")/.dd-tmp.XXXXXX")
    cat "$tmp" >"$final"; rm -f "$tmp"
    chmod "$mode" "$final"
    chown "$owner" "$final" 2>/dev/null || true
    mv -f "$final" "$path"
    _log_file WRITE "$path"
}

# ask VAR "Prompt" "default"
ask() {
    local __var=$1 __prompt=$2 __def=${3-} __in=""
    if (( ASSUME_YES )) || ! is_tty; then printf -v "$__var" '%s' "$__def"; return 0; fi
    read -rp "  ${__prompt} [${__def}]: " __in || true
    printf -v "$__var" '%s' "${__in:-$__def}"
}

# confirm "Question" [y|n]  -- --yes / no TTY returns the default answer
confirm() {
    local q=$1 def=${2:-n} a=""
    if (( ASSUME_YES )) || ! is_tty; then [[ $def == y ]]; return; fi
    if [[ $def == y ]]; then read -rp "  $q [Y/n]: " a || true; else read -rp "  $q [y/N]: " a || true; fi
    a=${a:-$def}
    [[ ${a,,} == y* ]]
}

# confirm_typed KEYWORD  -- destructive-action gate. CLI: --confirm KEYWORD
confirm_typed() {
    local kw=$1 a=""
    if [[ -n "$CONFIRM_KEYWORD" ]]; then [[ "$CONFIRM_KEYWORD" == "$kw" ]]; return; fi
    is_tty || { log_error "Non-interactive: pass --confirm $kw to proceed."; return 1; }
    read -rp "  Type ${B}${kw}${NC} to proceed (anything else cancels): " a || true
    [[ "$a" == "$kw" ]]
}

pause() { is_tty && { read -rp "  Press Enter to continue..." _ || true; }; return 0; }

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

in_list() { local n=$1; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }
list_words() { local -a a; read -ra a <<<"${1//,/ }"; (( ${#a[@]} )) && printf '%s\n' "${a[@]}"; return 0; }

# safe_path PATH -- refuse to rm -rf system or top-level paths
safe_path() {
    local p=${1%/}
    [[ -n "$p" && "$p" == /* && "$p" != *..* ]] || return 1
    case "$p" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/var/lib|/var/log)
            return 1 ;;
    esac
    [[ "$p" == /home/* && "$p" != /home/*/* ]] && return 1
    return 0
}

valid_abs_path() { [[ "$1" == /* && "$1" != *..* && "$1" =~ ^[A-Za-z0-9._/+@-]+$ ]]; }
valid_ipv4()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local IFS=. o; for o in $1; do (( o <= 255 )) || return 1; done; }
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; }
valid_url()      { [[ "$1" =~ ^https?://[^[:space:]\|\"\<\>\`]+$ ]]; }
valid_field()    { [[ "$1" != *"|"* && ! "$1" =~ [[:cntrl:]] && ${#1} -le 200 ]]; }
valid_port()     { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

have_docker() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
docker_up()   { have_docker && docker info >/dev/null 2>&1; }

detect_network() {
    local r
    r=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1) || true
    DET_IFACE=$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$r")
    DET_IP=$(sed -n 's/.* src \([0-9.]*\).*/\1/p' <<<"$r")
    [[ -n "$DET_IP" ]] || DET_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    return 0
}
eff_host() { if [[ "${CFG[HOST_ADDR]}" == auto ]]; then printf '%s' "${DET_IP:-127.0.0.1}"; else printf '%s' "${CFG[HOST_ADDR]}"; fi; }

# json_str STRING -> JSON string literal (fields are validated free of control chars)
json_str() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
    s=${s//</\\u003c}; s=${s//>/\\u003e}
    printf '"%s"' "$s"
}

state_get() { cat "$DD_STATE_DIR/$1" 2>/dev/null || true; }
state_set() { (( DRY_RUN )) && return 0; mkdir -p "$DD_STATE_DIR"; printf '%s\n' "$2" >"$DD_STATE_DIR/$1"; }

# -----------------------------------------------------------------------------
# CONFIG FILE
# -----------------------------------------------------------------------------
conf_quote()   { local v=$1; printf "'%s'" "${v//"'"/"'\\''"}"; }
conf_unquote() {
    local v=$1
    if [[ ${#v} -ge 2 && "$v" == \'*\' ]]; then
        v=${v:1:${#v}-2}; v=${v//"'\\''"/"'"}
    elif [[ ${#v} -ge 2 && "$v" == \"*\" ]]; then
        v=${v:1:${#v}-2}
    fi
    printf '%s' "$v"
}

detect_timezone() {
    local tz=""
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ -z "$tz" && -L /etc/localtime ]] && tz=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
    printf '%s' "${tz:-Etc/UTC}"
}

detect_domain() {
    local d
    d=$(hostname -d 2>/dev/null || true)
    [[ -z "$d" ]] && d=$(awk '/^(search|domain)[[:space:]]/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    [[ "$d" == *.* ]] && printf '%s' "$d"
    return 0
}

set_default_config() {
    CFG=(
        [DASH_TITLE]="Docker Host"
        [DOMAIN]=""
        [DASH_SUBDOMAIN]="dashboard"
        [HOST_ADDR]="auto"
        [EXTRA_NAMES]=""
        [HTTP_PORT]="80"
        [HTTPS_PORT]="443"
        [TIMEZONE]="$(detect_timezone)"
        [DEPLOY_DIR]="/opt/docker-dashboard"
        [STACKS_DIR]="/opt/stacks"
        [NGINX_IMAGE]="nginx:stable-alpine"
        [CERT_MODE]="selfsigned"
        [CERT_FILE]=""
        [CERT_KEY_FILE]=""
        [CERT_DAYS]="3650"
        [CERT_FETCH_SOURCE]=""
        [CERT_FETCH_CERT]="fullchain.pem"
        [CERT_FETCH_KEY]="privkey.pem"
        [FILES_DIR]=""
        [FILES_HTTP]="yes"
        [HEALTH_CHECK]="yes"
        [HEALTH_INTERVAL]="2"
        [HOST_PANEL]="yes"
        [HOST_DISK_WARN]="80"
        [HOST_DISK_CRIT]="90"
        [HOST_MEM_WARN]="85"
        [HOST_MEM_CRIT]="95"
        [HOST_LOAD_WARN]="1.0"
        [HOST_LOAD_CRIT]="2.0"
        [UPDATE_SCHEDULE]="off"
        [UPDATE_DAY]="Sun"
        [UPDATE_TIME]="04:00"
        [UPDATE_PRUNE]="yes"
        [UPDATE_EXCLUDE]=""
        [UPDATE_DELEGATE]=""
        [WATCHTOWER_IMAGE]="nickfedor/watchtower:latest"
        [SECRETS_BACKEND]="auto"
        [APP_PIHOLE]="no"
        [PIHOLE_IMAGE]="pihole/pihole:latest"
        [PIHOLE_SUBDOMAIN]="pihole"
        [PIHOLE_WEB_PORT]="8081"
        [PIHOLE_DNS_PORT]="53"
        [PIHOLE_LOCAL_DNS]="yes"
        [PIHOLE_EXTRA_ENV]="FTLCONF_dns_listeningMode=all"
        [APP_PORTAINER]="no"
        [PORTAINER_IMAGE]="portainer/portainer-ce:lts"
        [PORTAINER_SUBDOMAIN]="portainer"
        [PORTAINER_HTTPS_PORT]="9443"
        [PORTAINER_EDGE_PORT]="8000"
        [APP_MONITORING]="no"
        [GRAFANA_IMAGE]="grafana/grafana:latest"
        [PROMETHEUS_IMAGE]="prom/prometheus:latest"
        [NODEEXP_IMAGE]="prom/node-exporter:latest"
        [BLACKBOX_IMAGE]="prom/blackbox-exporter:latest"
        [SPEEDTEST_IMAGE]="miguelndecarvalho/speedtest-exporter:latest"
        [GRAFANA_SUBDOMAIN]="grafana"
        [PROMETHEUS_SUBDOMAIN]="prometheus"
        [GRAFANA_PORT]="3030"
        [PROMETHEUS_PORT]="9090"
        [NODEEXP_PORT]="9100"
        [BLACKBOX_PORT]="9115"
        [SPEEDTEST_PORT]="9798"
        [PROMETHEUS_RETENTION]="90d"
        [GRAFANA_PLUGINS]="flant-statusmap-panel,ae3e-plotly-panel"
        [GRAFANA_EXTRA_ENV]=""
        [APP_GUACAMOLE]="no"
        [GUACAMOLE_IMAGE]="guacamole/guacamole:1.6.0"
        [GUACD_IMAGE]="guacamole/guacd:1.6.0"
        [GUAC_POSTGRES_IMAGE]="postgres:17"
        [GUACAMOLE_SUBDOMAIN]="guacamole"
        [GUACAMOLE_TLS_PORT]="8443"
        [GUAC_DB_NAME]="guacamole_db"
        [GUAC_DB_USER]="guacamole_user"
        [APP_MESHCENTRAL]="no"
        [MESHCENTRAL_IMAGE]="ghcr.io/ylianst/meshcentral:latest"
        [MESHCENTRAL_SUBDOMAIN]="meshcentral"
        [MESHCENTRAL_PORT]="3000"
        [APP_GVM]="no"
        [GVM_SUBDOMAIN]="gvm"
        [GVM_COMPOSE_URL]="$GVM_COMPOSE_DEFAULT"
    )
}

apply_cfg_line() {   # apply_cfg_line "KEY='value'" -> sets CFG if KEY is known
    [[ "$1" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || return 0
    in_list "${BASH_REMATCH[1]}" "${CONF_KEYS[@]}" || return 0
    CFG[${BASH_REMATCH[1]}]=$(conf_unquote "${BASH_REMATCH[2]}")
}

load_config() {
    set_default_config
    if [[ -f "$CONF_FILE" ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do apply_cfg_line "$line"; done <"$CONF_FILE"
    fi
    DEPLOY_DIR=${CFG[DEPLOY_DIR]%/}
    STACKS_DIR=${CFG[STACKS_DIR]%/}
    CONFIG_LOADED=1
    return 0
}

ensure_config() { (( CONFIG_LOADED )) || load_config; }

save_config() {
    local k
    mkdir -p "$DD_CONF_DIR"; chmod 700 "$DD_CONF_DIR"
    {
        printf '# %s configuration -- written by %s v%s on %s\n' "$PROJECT_NAME" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(date '+%F %T')"
        printf '# Non-secret settings only (secrets: %s). Edit with the menu, or by hand then --apply.\n' "$SECRETS_FILE"
        for k in "${CONF_KEYS[@]}"; do printf '%s=%s\n' "$k" "$(conf_quote "${CFG[$k]:-}")"; done
    } | write_file "$CONF_FILE" 600 root:root
    DEPLOY_DIR=${CFG[DEPLOY_DIR]%/}
    STACKS_DIR=${CFG[STACKS_DIR]%/}
    (( DRY_RUN )) || log_ok "Configuration saved: $CONF_FILE"
}

require_config() {
    [[ -f "$CONF_FILE" ]] || (( DRY_RUN )) || die "No configuration found ($CONF_FILE). Run the full install (menu 1 / --install) first."
    ensure_config
}

app_on()        { [[ "${CFG[APP_${1^^}]:-no}" == yes ]]; }
enabled_apps()  { local a; for a in "${APPS[@]}"; do app_on "$a" && printf '%s\n' "$a"; done; return 0; }
app_dir()       { printf '%s/%s' "$STACKS_DIR" "$1"; }
app_project()   { printf '%s%s' "$APP_PREFIX" "$1"; }

# fqdn SUBDOMAIN -> sub.domain (or "" without a domain)
fqdn() { [[ -n "${CFG[DOMAIN]}" && -n "$1" ]] && printf '%s.%s' "$1" "${CFG[DOMAIN]}"; return 0; }

# -----------------------------------------------------------------------------
# SECRETS (encrypted at rest; systemd-creds w/ TPM2 when available, else openssl)
# Same scheme as mediastack-installer.
# -----------------------------------------------------------------------------
systemd_version() { systemctl --version 2>/dev/null | awk 'NR==1 {print $2+0}'; }

secrets_backend_resolve() {
    local b=${CFG[SECRETS_BACKEND]:-auto} v
    if [[ "$b" == auto ]]; then
        b=openssl
        if command -v systemd-creds >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
            v=$(systemd_version); [[ "${v:-0}" -ge 250 ]] && b=systemd-creds
        fi
    fi
    printf '%s' "$b"
}

ensure_keyfile() {
    [[ -s "$KEY_FILE" ]] && return 0
    mkdir -p "$(dirname "$KEY_FILE")"
    ( umask 077; openssl rand -base64 48 | tr -d '\n' >"$KEY_FILE" )
    chmod 400 "$KEY_FILE"
    log_info "Created local secrets key $KEY_FILE (root-only)."
}

secrets_encrypt_to() {   # secrets_encrypt_to BACKEND OUTFILE  (payload on stdin)
    local backend=$1 out=$2 tmp
    mkdir -p "$(dirname "$out")"; chmod 700 "$(dirname "$out")"
    tmp=$(mktemp "$(dirname "$out")/.secrets.XXXXXX")
    {
        printf '# docker-dashboard-secrets v1 backend=%s\n' "$backend"
        case "$backend" in
            systemd-creds) systemd-creds encrypt --name=docker-dashboard-secrets - - ;;
            openssl)       ensure_keyfile
                           openssl enc -aes-256-cbc -pbkdf2 -iter 250000 -salt -a -pass "file:$KEY_FILE" ;;
            *)             return 1 ;;
        esac
    } >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$out"
}

secrets_decrypt() {
    local hdr backend
    hdr=$(head -n1 "$SECRETS_FILE")
    [[ "$hdr" == "# docker-dashboard-secrets v1 backend="* ]] || return 1
    backend=${hdr##*backend=}
    case "$backend" in
        systemd-creds) tail -n +2 "$SECRETS_FILE" | systemd-creds decrypt --name=docker-dashboard-secrets - - ;;
        openssl)       tail -n +2 "$SECRETS_FILE" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -a -pass "file:$KEY_FILE" ;;
        *)             return 1 ;;
    esac
}

secrets_file_backend() { head -n1 "$SECRETS_FILE" 2>/dev/null | sed -n 's/.*backend=//p'; }

load_secrets() {
    (( SECRETS_LOADED )) && return 0
    SECRETS=()
    if [[ -f "$SECRETS_FILE" ]]; then
        local payload line
        payload=$(secrets_decrypt) || die "Cannot decrypt $SECRETS_FILE (backend: $(secrets_file_backend)). Was the host key / TPM changed?"
        while IFS= read -r line; do
            [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
            SECRETS[${BASH_REMATCH[1]}]=$(printf '%s' "${BASH_REMATCH[2]}" | base64 -d)
        done <<<"$payload"
    fi
    SECRETS_LOADED=1
}

save_secrets() {
    local k payload="" backend
    if (( DRY_RUN )); then log_info "[dry-run] would save encrypted secrets to $SECRETS_FILE"; return 0; fi
    backend=$(secrets_backend_resolve)
    for k in "${!SECRETS[@]}"; do
        payload+="$k=$(printf '%s' "${SECRETS[$k]}" | base64 -w0)"$'\n'
    done
    printf '%s' "$payload" | secrets_encrypt_to "$backend" "$SECRETS_FILE" \
        || die "Encrypting secrets with backend '$backend' failed."
    log_ok "Secrets saved encrypted ($backend): $SECRETS_FILE"
}

secret_is_set() { [[ -n "${SECRETS[$1]:-}" ]]; }
gen_password()  { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24; }

# ensure_app_secrets -- generate whatever an enabled app needs and isn't set yet
ensure_app_secrets() {
    load_secrets
    local a k changed=0
    for a in $(enabled_apps); do
        for k in ${APP_SECRETS[$a]}; do
            secret_is_set "$k" && continue
            # an existing Pi-hole keeps the password in its pihole.toml
            [[ "$k" == PIHOLE_PASSWORD && -f "$(app_dir pihole)/etc-pihole/pihole.toml" ]] && continue
            SECRETS[$k]=$(gen_password); changed=1
            log_ok "Generated $k (view it in the Secrets menu: K)"
        done
    done
    (( changed )) && save_secrets
    return 0
}
# Delegates: "project=command;project2=command" -- projects updated by their own installer
delegate_for() {   # delegate_for PROJECT -> command or empty
    local entry IFS=';'
    for entry in ${CFG[UPDATE_DELEGATE]:-}; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        [[ "${entry%%=*}" == "$1" && "$entry" == *=* ]] && { printf '%s' "${entry#*=}"; return 0; }
    done
    return 0
}

is_excluded() {   # is_excluded NAME [PROJECT]
    local w
    while IFS= read -r w; do
        [[ -n "$w" ]] || continue
        [[ "$w" == "$1" || ( -n "${2:-}" && "$w" == "$2" ) ]] && return 0
    done < <(list_words "${CFG[UPDATE_EXCLUDE]:-}")
    return 1
}

# -----------------------------------------------------------------------------
# SERVICES LIST
# -----------------------------------------------------------------------------
load_services() {
    SVC_GROUP=() SVC_NAME=() SVC_URL=() SVC_DESC=()
    [[ -f "$SERVICES_FILE" ]] || return 0
    local line g n u d
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        IFS='|' read -r g n u d <<<"$line"
        g=$(trim "${g:-}"); n=$(trim "${n:-}"); u=$(trim "${u:-}"); d=$(trim "${d:-}")
        if [[ -z "$n" ]] || ! valid_url "$u"; then
            log_warn "Skipping invalid line in $SERVICES_FILE: $line"
            continue
        fi
        SVC_GROUP+=("${g:-Services}"); SVC_NAME+=("$n"); SVC_URL+=("$u"); SVC_DESC+=("$d")
    done <"$SERVICES_FILE"
    return 0
}

save_services() {
    local i
    {
        printf '# %s services -- one per line: group | name | url | description\n' "$PROJECT_NAME"
        printf '# Order here is the order on the page. Lines starting with # are ignored.\n'
        for i in "${!SVC_NAME[@]}"; do
            printf '%s | %s | %s | %s\n' "${SVC_GROUP[$i]}" "${SVC_NAME[$i]}" "${SVC_URL[$i]}" "${SVC_DESC[$i]}"
        done
    } | write_file "$SERVICES_FILE" 644 root:root
}

svc_index_by_url() { local i; for i in "${!SVC_URL[@]}"; do [[ "${SVC_URL[$i]}" == "$1" ]] && { echo "$i"; return 0; }; done; return 1; }

svc_add() {   # svc_add GROUP NAME URL DESC
    valid_field "$1" && valid_field "$2" && [[ -n "$2" ]] && valid_url "$3" && valid_field "$4" \
        || { log_error "Invalid service: name required, no '|' in fields, URL must be http(s)://"; return 1; }
    SVC_GROUP+=("${1:-Services}"); SVC_NAME+=("$2"); SVC_URL+=("$3"); SVC_DESC+=("$4")
}

svc_remove() {   # svc_remove INDEX
    local i=$1
    SVC_GROUP=("${SVC_GROUP[@]:0:$i}" "${SVC_GROUP[@]:$((i+1))}")
    SVC_NAME=("${SVC_NAME[@]:0:$i}" "${SVC_NAME[@]:$((i+1))}")
    SVC_URL=("${SVC_URL[@]:0:$i}" "${SVC_URL[@]:$((i+1))}")
    SVC_DESC=("${SVC_DESC[@]:0:$i}" "${SVC_DESC[@]:$((i+1))}")
}

svc_move() {   # svc_move FROM TO (0-based)
    local f=$1 t=$2 g n u d
    g=${SVC_GROUP[$f]}; n=${SVC_NAME[$f]}; u=${SVC_URL[$f]}; d=${SVC_DESC[$f]}
    svc_remove "$f"
    SVC_GROUP=("${SVC_GROUP[@]:0:$t}" "$g" "${SVC_GROUP[@]:$t}")
    SVC_NAME=("${SVC_NAME[@]:0:$t}" "$n" "${SVC_NAME[@]:$t}")
    SVC_URL=("${SVC_URL[@]:0:$t}" "$u" "${SVC_URL[@]:$t}")
    SVC_DESC=("${SVC_DESC[@]:0:$t}" "$d" "${SVC_DESC[@]:$t}")
}

# pretty_name IMAGE CONTAINER -> display name for a detected service
pretty_name() {
    local img=${1,,} c=$2
    case "$img" in
        *grafana*)      echo "Grafana" ;;
        *portainer*)    echo "Portainer" ;;
        *meshcentral*)  echo "MeshCentral" ;;
        *pihole*)       echo "Pi-hole" ;;
        *guacamole*)    echo "Guacamole" ;;
        *prometheus*)   echo "Prometheus" ;;
        *uptime-kuma*)  echo "Uptime Kuma" ;;
        *homeassistant*|*home-assistant*) echo "Home Assistant" ;;
        *netbox*)       echo "NetBox" ;;
        *gvm*|*greenbone*|*openvas*) echo "Greenbone (GVM)" ;;
        *)              c=${c#/}; echo "${c^}" ;;
    esac
}
path_hint() { case "${1,,}" in *pihole*) echo "/admin/" ;; *) echo "/" ;; esac; }

# probe_scheme HOST PORT -> https|http|"" (empty = nothing answering HTTP)
probe_scheme() {
    local code
    code=$(curl -sk --noproxy '*' -o /dev/null -m 4 --connect-timeout 2 -w '%{http_code}' "https://$1:$2/" 2>/dev/null || true)
    [[ "$code" != 000 && -n "$code" ]] && { echo https; return 0; }
    code=$(curl -s --noproxy '*' -o /dev/null -m 4 --connect-timeout 2 -w '%{http_code}' "http://$1:$2/" 2>/dev/null || true)
    [[ "$code" != 000 && -n "$code" ]] && { echo http; return 0; }
    return 0
}

# published_tcp_ports CONTAINER -> unique host TCP ports, one per line
published_tcp_ports() {
    docker inspect -f '{{range $p, $c := .NetworkSettings.Ports}}{{if $c}}{{range $c}}{{$p}}={{.HostPort}} {{end}}{{end}}{{end}}' "$1" 2>/dev/null \
        | tr ' ' '\n' | sed -n 's#^[0-9]*/tcp=\([0-9][0-9]*\)$#\1#p' | sort -un
}

detect_services() {
    log_step "Detect services from running containers"
    docker_up || { log_warn "Docker is not running; nothing to detect."; return 0; }
    local host c img port scheme url name added=0 found=0
    host=$(eff_host)
    while IFS=$'\t' read -r c img; do
        [[ -n "$c" && "$c" != "$CONTAINER_NAME" && "$c" != "$WATCHTOWER_NAME" ]] || continue
        if is_own_project "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)"; then
            continue
        fi
        if [[ "$(docker inspect -f '{{.HostConfig.AutoRemove}}' "$c" 2>/dev/null)" == true ]]; then
            log_info "${D}$c -- temporary (--rm) container, skipped${NC}"; continue
        fi
        while IFS= read -r port; do
            [[ -n "$port" ]] || continue
            if in_list "$port" "${CFG[HTTP_PORT]}" "${CFG[HTTPS_PORT]}"; then
                log_warn "$c:$port -- uses a dashboard port; move it, then detect again"; continue
            fi
            scheme=$(probe_scheme "$host" "$port")
            [[ -n "$scheme" ]] || { log_info "${D}$c:$port -- no HTTP response, skipped${NC}"; continue; }
            found=$((found + 1))
            url="$scheme://$host:$port$(path_hint "$img")"
            if svc_index_by_url "$url" >/dev/null; then log_info "${D}$url already listed${NC}"; continue; fi
            name=$(pretty_name "$img" "$c")
            if confirm "Add ${B}$name${NC}  $url  ($c, $img)?" y; then
                svc_add "Links" "$name" "$url" "${img%%@*}" && added=$((added + 1))
            fi
        done < <(published_tcp_ports "$c")
    done < <(docker ps --format '{{.Names}}\t{{.Image}}' | LC_ALL=C sort)
    log_ok "Found $found web endpoint(s), added $added"
    local hostnet; hostnet=$(docker ps -q | xargs -r docker inspect -f '{{.Name}} {{.HostConfig.NetworkMode}}' 2>/dev/null | awk '$2 == "host" {sub("^/", "", $1); print $1}' | xargs)
    [[ -n "$hostnet" ]] && log_info "Host-network containers have no published ports; add them by hand: $hostnet"
    (( added )) && save_services
    return 0
}

# -----------------------------------------------------------------------------
# PREFLIGHT / DOCKER ENGINE (docker-base-install.sh, hardened)
# -----------------------------------------------------------------------------
OS_ID="" OS_CODENAME=""
detect_os() {
    [[ -f /etc/os-release ]] || die "Cannot identify OS (/etc/os-release missing)."
    local id like
    id=$(. /etc/os-release; printf '%s' "${ID:-}")
    like=$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")
    OS_CODENAME=$(. /etc/os-release; printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")
    case "$id" in
        ubuntu|debian) OS_ID=$id ;;
        *) if [[ "$like" == *ubuntu* ]]; then OS_ID=ubuntu
           elif [[ "$like" == *debian* ]]; then OS_ID=debian
           else die "Unsupported OS '$id'. Ubuntu or Debian required."; fi ;;
    esac
    [[ -n "$OS_CODENAME" ]] || die "Cannot determine release codename."
}

preflight() {
    log_step "Preflight checks"
    detect_os
    local arch; arch=$(dpkg --print-architecture)
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || die "Unsupported architecture: $arch"
    log_ok "OS: $OS_ID $OS_CODENAME ($arch)"
    local -a need=() c
    for c in curl openssl ip ss awk sed flock cmp; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
    if (( ${#need[@]} )); then
        log_warn "Missing tools: ${need[*]} -- installing base packages"
        run_logged apt-get update
        run_logged apt-get install -y ca-certificates curl openssl iproute2 gawk sed util-linux diffutils
    fi
    command -v systemctl >/dev/null 2>&1 || die "systemd is required."
    log_ok "Base tools present"
}

install_docker() {
    log_step "Docker Engine"
    if have_docker; then
        log_ok "Docker present: $(docker --version | sed 's/Docker version //') / compose $(docker compose version --short 2>/dev/null)"
    else
        local -a conflicts=() p
        for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
            dpkg -s "$p" >/dev/null 2>&1 && conflicts+=("$p")
        done
        if (( ${#conflicts[@]} )); then
            log_warn "Conflicting distro packages installed: ${conflicts[*]}"
            confirm "Remove them so Docker CE can be installed?" y || die "Cannot continue with conflicting packages."
            run_logged apt-get remove -y "${conflicts[@]}"
        fi
        run_logged apt-get update
        run_logged apt-get install -y ca-certificates curl
        run install -m 0755 -d /etc/apt/keyrings
        run curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
        run chmod a+r /etc/apt/keyrings/docker.asc
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
            "$(dpkg --print-architecture)" "$OS_ID" "$OS_CODENAME" \
            | write_file /etc/apt/sources.list.d/docker.list 644 root:root
        run_logged apt-get update
        run_logged apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        run systemctl enable --now docker
        log_ok "Docker CE installed"
    fi
    (( DRY_RUN )) || docker_up || die "Docker daemon is not running (systemctl status docker)."
}

ensure_docker_group() {
    [[ "$REAL_USER" != root ]] || return 0
    getent group docker >/dev/null || run groupadd docker
    if id -nG "$REAL_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        log_ok "User '$REAL_USER' is in the docker group"
        return 0
    fi
    log_info "Members of the docker group can run docker without sudo (root-equivalent access)."
    if confirm "Add '$REAL_USER' to the docker group?" y; then
        run usermod -aG docker "$REAL_USER"
        log_warn "Log out and back in for the group change to apply to '$REAL_USER'."
    fi
    return 0
}


# -----------------------------------------------------------------------------
# APPS: endpoints, compose renderers, first-run configs
# -----------------------------------------------------------------------------
# yaml_str VALUE -> double-quoted YAML scalar, '$' escaped for compose interpolation
yaml_str() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\$\$}
    printf '"%s"' "$s"
}

# kv_pairs "K=V;K2=V2" -> "K<TAB>V" lines (validated keys only)
kv_pairs() {
    local e IFS=';'
    for e in ${1:-}; do
        e=$(trim "$e")
        [[ "$e" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    done
    return 0
}

# app_endpoints APP -> "key|title|subdomain|upstream|flags|fallback|description"
#   ("|", not a tab: read collapses repeated tabs, which would shift empty fields)
#   flags: ws (websockets), tls (https upstream), stream (no buffering), big (large uploads), admin (/ -> /admin/)
app_endpoints() {
    local ip; ip=$(eff_host)
    local p
    case "$1" in
        pihole)
            p=${CFG[PIHOLE_WEB_PORT]}
            printf 'pihole|Pi-hole|%s|http://pihole:80|ws,admin|%s|DNS filtering\n' "${CFG[PIHOLE_SUBDOMAIN]}" "${p:+http://$ip:$p/admin/}" ;;
        portainer)
            p=${CFG[PORTAINER_HTTPS_PORT]}
            printf 'portainer|Portainer|%s|https://portainer:9443|ws,tls,big|%s|Container management\n' "${CFG[PORTAINER_SUBDOMAIN]}" "${p:+https://$ip:$p/}" ;;
        monitoring)
            p=${CFG[GRAFANA_PORT]}
            printf 'grafana|Grafana|%s|http://grafana:3000|ws|%s|Internet monitoring dashboards\n' "${CFG[GRAFANA_SUBDOMAIN]}" "${p:+http://$ip:$p/}"
            p=${CFG[PROMETHEUS_PORT]}
            printf 'prometheus|Prometheus|%s|http://prometheus:9090||%s|Metrics (speedtest, ping, node)\n' "${CFG[PROMETHEUS_SUBDOMAIN]}" "${p:+http://$ip:$p/}" ;;
        guacamole)
            p=${CFG[GUACAMOLE_TLS_PORT]}
            printf 'guacamole|Guacamole|%s|http://guacamole:8080|ws,stream|%s|Clientless remote desktop gateway\n' "${CFG[GUACAMOLE_SUBDOMAIN]}" "${p:+https://$ip:$p/}" ;;
        meshcentral)
            p=${CFG[MESHCENTRAL_PORT]}
            printf 'meshcentral|MeshCentral|%s|https://meshcentral:443|ws,tls,big,stream|%s|Remote device management\n' "${CFG[MESHCENTRAL_SUBDOMAIN]}" "${p:+https://$ip:$p/}" ;;
        gvm)
            printf 'gvm|Greenbone|%s|https://gvm-web:443|tls,big||Vulnerability scanning\n' "${CFG[GVM_SUBDOMAIN]}" ;;
    esac
}

all_endpoints() {
    local a
    for a in $(enabled_apps); do app_endpoints "$a"; done
    [[ -n "$STACKS_DIR" ]] && for a in $(enabled_customs); do custom_endpoint "$a"; done
    return 0
}

# Host ports an app publishes (or that the dashboard publishes for it): "port/proto<TAB>label"
app_host_ports() {
    local p
    case "$1" in
        pihole)      printf '%s/tcp\tPi-hole DNS\n%s/udp\tPi-hole DNS\n' "${CFG[PIHOLE_DNS_PORT]}" "${CFG[PIHOLE_DNS_PORT]}"
                     [[ -n "${CFG[PIHOLE_WEB_PORT]}" ]] && printf '%s/tcp\tPi-hole web\n' "${CFG[PIHOLE_WEB_PORT]}" ;;
        portainer)   for p in PORTAINER_HTTPS_PORT PORTAINER_EDGE_PORT; do [[ -n "${CFG[$p]}" ]] && printf '%s/tcp\tPortainer\n' "${CFG[$p]}"; done ;;
        monitoring)  for p in GRAFANA_PORT PROMETHEUS_PORT NODEEXP_PORT BLACKBOX_PORT SPEEDTEST_PORT; do
                         [[ -n "${CFG[$p]}" ]] && printf '%s/tcp\t%s\n' "${CFG[$p]}" "${p%_PORT}"
                     done ;;
        guacamole)   [[ -n "${CFG[GUACAMOLE_TLS_PORT]}" ]] && printf '%s/tcp\tGuacamole (via dashboard)\n' "${CFG[GUACAMOLE_TLS_PORT]}" ;;
        meshcentral) [[ -n "${CFG[MESHCENTRAL_PORT]}" ]] && printf '%s/tcp\tMeshCentral (agents)\n' "${CFG[MESHCENTRAL_PORT]}" ;;
    esac
    return 0
}

render_proxy_net() {   # service-level network block: render_proxy_net ALIAS
    printf '    networks:\n      default: {}\n      %s:\n        aliases: ["%s"]\n' "$PROXY_NET" "$1"
}
render_net_footer() { printf 'networks:\n  %s:\n    external: true\n' "$PROXY_NET"; }
render_port() { [[ -n "$1" ]] && printf '      - "%s:%s"\n' "$1" "$2"; return 0; }
render_labels() { printf '    labels:\n      dev.docker-dashboard.app: "%s"\n' "$1"; }
render_header() { printf '# Managed by %s v%s -- regenerated on every apply; change settings instead.\nname: %s\nservices:\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(app_project "$1")"; }

render_app_pihole() {
    render_header pihole
    printf '  pihole:\n    image: %s\n    container_name: pihole\n    restart: unless-stopped\n' "$(yaml_str "${CFG[PIHOLE_IMAGE]}")"
    printf '    ports:\n'
    printf '      - "%s:53/tcp"\n      - "%s:53/udp"\n' "${CFG[PIHOLE_DNS_PORT]}" "${CFG[PIHOLE_DNS_PORT]}"
    [[ -n "${CFG[PIHOLE_WEB_PORT]}" ]] && printf '      - "%s:80/tcp"\n' "${CFG[PIHOLE_WEB_PORT]}"
    printf '    environment:\n      TZ: %s\n' "$(yaml_str "${CFG[TIMEZONE]}")"
    # only when we manage the password: an imported Pi-hole without one keeps its pihole.toml password
    secret_is_set PIHOLE_PASSWORD && printf '      FTLCONF_webserver_api_password: "${PIHOLE_PASSWORD:?err}"\n'
    local k v
    while IFS=$'\t' read -r k v; do
        [[ "$k" == TZ || "$k" == FTLCONF_webserver_api_password ]] && continue
        printf '      %s: %s\n' "$k" "$(yaml_str "$v")"
    done < <(kv_pairs "${CFG[PIHOLE_EXTRA_ENV]}")
    printf '    volumes:\n      - "./etc-pihole:/etc/pihole"\n'
    printf '    cap_add: ["NET_ADMIN"]\n'
    render_labels pihole
    render_proxy_net pihole
    render_net_footer
}

render_app_portainer() {
    render_header portainer
    printf '  portainer:\n    image: %s\n    container_name: portainer\n    restart: unless-stopped\n' "$(yaml_str "${CFG[PORTAINER_IMAGE]}")"
    if [[ -n "${CFG[PORTAINER_HTTPS_PORT]}${CFG[PORTAINER_EDGE_PORT]}" ]]; then
        printf '    ports:\n'
        render_port "${CFG[PORTAINER_HTTPS_PORT]}" 9443
        render_port "${CFG[PORTAINER_EDGE_PORT]}" 8000
    fi
    printf '    volumes:\n      - "/var/run/docker.sock:/var/run/docker.sock"\n      - "./data:/data"\n'
    render_labels portainer
    render_proxy_net portainer
    render_net_footer
}

render_app_monitoring() {
    local k v d
    render_header monitoring
    # grafana
    printf '  grafana:\n    image: %s\n    container_name: grafana\n    restart: unless-stopped\n    user: "472"\n' "$(yaml_str "${CFG[GRAFANA_IMAGE]}")"
    [[ -n "${CFG[GRAFANA_PORT]}" ]] && { printf '    ports:\n'; render_port "${CFG[GRAFANA_PORT]}" 3000; }
    printf '    environment:\n      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD:?err}"\n      GF_USERS_ALLOW_SIGN_UP: "false"\n'
    [[ -n "${CFG[GRAFANA_PLUGINS]}" ]] && printf '      GF_INSTALL_PLUGINS: %s\n' "$(yaml_str "${CFG[GRAFANA_PLUGINS]}")"
    d=$(fqdn "${CFG[GRAFANA_SUBDOMAIN]}")
    [[ -n "$d" ]] && printf '      GF_SERVER_ROOT_URL: %s\n' "$(yaml_str "https://$d$(https_port_suffix)/")"
    while IFS=$'\t' read -r k v; do printf '      %s: %s\n' "$k" "$(yaml_str "$v")"; done < <(kv_pairs "${CFG[GRAFANA_EXTRA_ENV]}")
    printf '    volumes:\n      - "./grafana/provisioning:/etc/grafana/provisioning"\n      - "./data/grafana:/var/lib/grafana"\n'
    render_labels monitoring
    render_proxy_net grafana
    # prometheus
    printf '  prometheus:\n    image: %s\n    container_name: prometheus\n    restart: unless-stopped\n    user: "65534:65534"\n' "$(yaml_str "${CFG[PROMETHEUS_IMAGE]}")"
    [[ -n "${CFG[PROMETHEUS_PORT]}" ]] && { printf '    ports:\n'; render_port "${CFG[PROMETHEUS_PORT]}" 9090; }
    printf '    command:\n'
    printf '      - "--config.file=/etc/prometheus/prometheus.yml"\n      - "--storage.tsdb.path=/prometheus"\n'
    printf '      - "--storage.tsdb.retention.time=%s"\n' "${CFG[PROMETHEUS_RETENTION]}"
    printf '    volumes:\n      - "./prometheus:/etc/prometheus"\n      - "./data/prometheus:/prometheus"\n'
    render_labels monitoring
    render_proxy_net prometheus
    # node exporter
    printf '  nodeexp:\n    image: %s\n    container_name: nodeexp\n    restart: unless-stopped\n    privileged: true\n' "$(yaml_str "${CFG[NODEEXP_IMAGE]}")"
    [[ -n "${CFG[NODEEXP_PORT]}" ]] && { printf '    ports:\n'; render_port "${CFG[NODEEXP_PORT]}" 9100; }
    printf '    command:\n      - "--path.procfs=/host/proc"\n      - "--path.sysfs=/host/sys"\n      - "--path.rootfs=/rootfs"\n'
    printf '      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|rootfs/var/lib/docker/containers|rootfs/var/lib/docker/overlay2|rootfs/run/docker/netns)($$|/)"\n'
    printf '    volumes:\n      - "/proc:/host/proc:ro"\n      - "/sys:/host/sys:ro"\n      - "/:/rootfs:ro"\n'
    render_labels monitoring
    # blackbox ("ping" is the name prometheus.yml uses)
    printf '  ping:\n    image: %s\n    container_name: ping\n    restart: unless-stopped\n' "$(yaml_str "${CFG[BLACKBOX_IMAGE]}")"
    [[ -n "${CFG[BLACKBOX_PORT]}" ]] && { printf '    ports:\n'; render_port "${CFG[BLACKBOX_PORT]}" 9115; }
    printf '    command:\n      - "--config.file=/config/blackbox.yml"\n    volumes:\n      - "./blackbox/config:/config"\n'
    render_labels monitoring
    # speedtest
    printf '  speedtest:\n    image: %s\n    container_name: speedtest\n    restart: unless-stopped\n' "$(yaml_str "${CFG[SPEEDTEST_IMAGE]}")"
    [[ -n "${CFG[SPEEDTEST_PORT]}" ]] && { printf '    ports:\n'; render_port "${CFG[SPEEDTEST_PORT]}" 9798; }
    render_labels monitoring
    render_net_footer
}

render_app_guacamole() {
    render_header guacamole
    printf '  postgres:\n    image: %s\n    container_name: guacamole-postgres\n    restart: unless-stopped\n' "$(yaml_str "${CFG[GUAC_POSTGRES_IMAGE]}")"
    printf '    environment:\n      POSTGRES_DB: %s\n      POSTGRES_USER: %s\n      POSTGRES_PASSWORD: "${GUAC_DB_PASSWORD:?err}"\n' \
        "$(yaml_str "${CFG[GUAC_DB_NAME]}")" "$(yaml_str "${CFG[GUAC_DB_USER]}")"
    printf '    volumes:\n      - "./init:/docker-entrypoint-initdb.d:ro"\n      - "./data/postgres:/var/lib/postgresql/data"\n'
    printf '    healthcheck:\n      test: ["CMD-SHELL", "pg_isready -U \\"$$POSTGRES_USER\\" -d \\"$$POSTGRES_DB\\""]\n      interval: 10s\n      timeout: 5s\n      retries: 12\n'
    render_labels guacamole
    printf '  guacd:\n    image: %s\n    container_name: guacd\n    restart: unless-stopped\n' "$(yaml_str "${CFG[GUACD_IMAGE]}")"
    printf '    volumes:\n      - "./drive:/drive"\n      - "./record:/record"\n'
    render_labels guacamole
    printf '  guacamole:\n    image: %s\n    container_name: guacamole\n    restart: unless-stopped\n' "$(yaml_str "${CFG[GUACAMOLE_IMAGE]}")"
    printf '    depends_on:\n      postgres:\n        condition: service_healthy\n      guacd:\n        condition: service_started\n'
    printf '    environment:\n      GUACD_HOSTNAME: "guacd"\n      POSTGRESQL_HOSTNAME: "postgres"\n'
    printf '      POSTGRESQL_DATABASE: %s\n      POSTGRESQL_USERNAME: %s\n      POSTGRESQL_PASSWORD: "${GUAC_DB_PASSWORD:?err}"\n' \
        "$(yaml_str "${CFG[GUAC_DB_NAME]}")" "$(yaml_str "${CFG[GUAC_DB_USER]}")"
    printf '      REMOTE_IP_VALVE_ENABLED: "true"\n      WEBAPP_CONTEXT: "ROOT"\n'
    render_labels guacamole
    render_proxy_net guacamole
    render_net_footer
}

render_app_meshcentral() {
    render_header meshcentral
    printf '  meshcentral:\n    image: %s\n    container_name: meshcentral\n    restart: unless-stopped\n' "$(yaml_str "${CFG[MESHCENTRAL_IMAGE]}")"
    [[ -n "${CFG[MESHCENTRAL_PORT]}" ]] && { printf '    ports:\n'; render_port "${CFG[MESHCENTRAL_PORT]}" 443; }
    printf '    environment:\n      DYNAMIC_CONFIG: "false"\n      TZ: %s\n' "$(yaml_str "${CFG[TIMEZONE]}")"
    printf '    volumes:\n'
    printf '      - "./data:/opt/meshcentral/meshcentral-data"\n      - "./files:/opt/meshcentral/meshcentral-files"\n'
    printf '      - "./backups:/opt/meshcentral/meshcentral-backups"\n      - "./web:/opt/meshcentral/meshcentral-web"\n'
    render_labels meshcentral
    render_proxy_net meshcentral
    render_net_footer
}

# GVM uses Greenbone's own compose.yaml; this override only re-wires its nginx
render_app_gvm_override() {
    printf '# Managed by %s v%s -- applied on top of Greenbone'"'"'s compose.yaml\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf 'services:\n  nginx:\n    ports: !reset []\n'
    printf '    labels:\n      dev.docker-dashboard.app: "gvm"\n'
    render_proxy_net gvm-web
    render_net_footer
}

# compose_app APP ARGS...  -- project-scoped; secrets exported only into this subshell
compose_app() {
    local app=$1; shift
    (
        cd "$(app_dir "$app")" || exit 1
        local k
        for k in "${SECRET_KEYS[@]}"; do export "$k=${SECRETS[$k]:-}"; done
        if [[ "$app" == gvm ]]; then
            docker compose -p "$(app_project gvm)" -f compose.yaml -f compose.override.yaml "$@"
        else
            docker compose -p "$(app_project "$app")" -f compose.yaml "$@"
        fi
    )
}

https_port_suffix() { [[ "${CFG[HTTPS_PORT]}" == 443 ]] || printf ':%s' "${CFG[HTTPS_PORT]}"; }

# ---- first-run configs (never overwrite existing / imported files) ----------
write_default_prometheus_yml() {
    cat <<'YML'
---
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s
  external_labels:
    monitor: 'Alertmanager'

rule_files:
  - 'alert.rules'

scrape_configs:
  - job_name: 'prometheus'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'speedtest'
    metrics_path: /metrics
    scrape_interval: 60m
    scrape_timeout: 60s  # running speedtest needs time to complete
    static_configs:
      - targets: ['speedtest:9798']

  - job_name: 'ping'
    metrics_path: /probe
    scrape_interval: 5s
    params:
      module: [http_2xx]  # Look for a HTTP 200 response.
    file_sd_configs:
      - files:
          - pinghosts.yaml
    relabel_configs:
      - source_labels: [__address__]
        regex: '(.*);(.*)'  # first is the url, thus unique for instance
        target_label: instance
        replacement: $1
      - source_labels: [__address__]
        regex: '(.*);(.*)'  # second is humanname to use in charts
        target_label: humanname
        replacement: $2
      - source_labels: [instance]
        target_label: __param_target
      - target_label: __address__
        replacement: ping:9115  # The blackbox exporter's real hostname:port.

  - job_name: 'nodeexp'
    static_configs:
      - targets: ['nodeexp:9100']
YML
}

fetch_internet_pi() {   # fetch_internet_pi DEST -> internet-monitoring/ from upstream at the pinned commit
    local dest=$1 t
    t=$(mktemp -d)
    log_info "Downloading internet-monitoring defaults (geerlingguy/internet-pi @ ${INTERNET_PI_REF:0:7})"
    if ! curl -fsSL --retry 2 -o "$t/ip.tgz" "${DD_INTERNET_PI_URL:-https://codeload.github.com/geerlingguy/internet-pi/tar.gz/$INTERNET_PI_REF}"; then
        rm -rf "$t"; return 1
    fi
    tar -xzf "$t/ip.tgz" -C "$t" || { rm -rf "$t"; return 1; }
    cp -a "$t"/internet-pi-*/internet-monitoring/. "$dest/"
    rm -rf "$t"
}

app_prepare() {   # app_prepare APP -- folders, ownership, first-run config
    local app=$1 d
    d=$(app_dir "$app")
    run mkdir -p "$d"
    case "$app" in
        pihole)
            run mkdir -p "$d/etc-pihole" ;;
        portainer)
            run mkdir -p "$d/data" ;;
        monitoring)
            if [[ ! -f "$d/prometheus/prometheus.yml" ]]; then
                if (( DRY_RUN )); then run fetch_internet_pi "$d"
                else
                    fetch_internet_pi "$d" || die "Could not download internet-monitoring defaults (github.com reachable?)."
                    rm -f "$d/README.md" "$d/docker-compose.yml"
                    write_default_prometheus_yml >"$d/prometheus/prometheus.yml"
                    printf -- '- targets:\n    - http://www.google.com/;google.com\n    - https://github.com/;github.com\n    - https://www.apple.com/;apple.com\n' >"$d/prometheus/pinghosts.yaml"
                    log_ok "Monitoring defaults written (edit $d/prometheus/pinghosts.yaml for ping targets)"
                fi
            fi
            run mkdir -p "$d/data/grafana" "$d/data/prometheus" "$d/blackbox/config" "$d/grafana/provisioning"
            if (( ! DRY_RUN )); then
                [[ "$(stat -c %u "$d/data/grafana")" == 472 ]] || chown -R 472:472 "$d/data/grafana"
                [[ "$(stat -c %u "$d/data/prometheus")" == 65534 ]] || chown -R 65534:65534 "$d/data/prometheus"
            fi ;;
        guacamole)
            run mkdir -p "$d/init" "$d/data/postgres" "$d/drive" "$d/record" "$d/.restore"
            if [[ ! -f "$d/data/postgres/PG_VERSION" && ! -f "$d/init/initdb.sql" && ! -f "$d/.restore/guacamole.dump" ]]; then
                if (( DRY_RUN )); then run docker run --rm "${CFG[GUACAMOLE_IMAGE]}" /opt/guacamole/bin/initdb.sh --postgresql
                else
                    docker run --rm "${CFG[GUACAMOLE_IMAGE]}" /opt/guacamole/bin/initdb.sh --postgresql >"$d/init/initdb.sql.tmp" \
                        && [[ -s "$d/init/initdb.sql.tmp" ]] && mv "$d/init/initdb.sql.tmp" "$d/init/initdb.sql" \
                        || { rm -f "$d/init/initdb.sql.tmp"; die "Could not generate the Guacamole database schema."; }
                    log_ok "Guacamole schema prepared (first login: guacadmin / guacadmin -- change it)"
                fi
            fi ;;
        meshcentral)
            run mkdir -p "$d/data" "$d/files" "$d/backups" "$d/web"
            if [[ ! -f "$d/data/config.json" ]] && (( ! DRY_RUN )); then
                local host; host=$(fqdn "${CFG[MESHCENTRAL_SUBDOMAIN]}"); host=${host:-$(eff_host)}
                cat >"$d/data/config.json" <<JSON
{
  "settings": {
    "cert": "$host",
    "port": 443,
    "aliasPort": ${CFG[MESHCENTRAL_PORT]:-443},
    "redirPort": 0,
    "selfUpdate": false,
    "WebRTC": false
  },
  "domains": {
    "": {
      "title": "MeshCentral",
      "NewAccounts": true
    }
  }
}
JSON
                log_ok "MeshCentral config.json written (agents connect to $host:${CFG[MESHCENTRAL_PORT]:-443}). Create your admin account first, then set NewAccounts to false."
            fi ;;
        gvm)
            if [[ ! -f "$d/compose.yaml" ]]; then
                if (( DRY_RUN )); then run curl -fsSL "${CFG[GVM_COMPOSE_URL]}"
                else
                    curl -fsSL --retry 2 -o "$d/compose.yaml.tmp" "${CFG[GVM_COMPOSE_URL]}" && mv "$d/compose.yaml.tmp" "$d/compose.yaml" \
                        || { rm -f "$d/compose.yaml.tmp"; die "Could not download Greenbone compose file from ${CFG[GVM_COMPOSE_URL]}"; }
                    log_ok "Greenbone compose.yaml downloaded"
                fi
            fi ;;
    esac
    return 0
}

write_app_compose() {   # write_app_compose APP
    local app=$1 d; d=$(app_dir "$app")
    case "$app" in
        gvm) write_file "$d/compose.override.yaml" 644 root:root < <(render_app_gvm_override) ;;
        *)   write_file "$d/compose.yaml" 644 root:root < <("render_app_$app") ;;
    esac
}

ensure_proxy_net() {
    docker network inspect "$PROXY_NET" >/dev/null 2>&1 && return 0
    run docker network create "$PROXY_NET" >/dev/null
    log_ok "Created docker network $PROXY_NET"
}

# ---- Guacamole: restore an imported dump, apply schema upgrades --------------
guac_psql() { docker exec -i guacamole-postgres psql -v ON_ERROR_STOP=1 -U "${CFG[GUAC_DB_USER]}" -d "${CFG[GUAC_DB_NAME]}" "$@"; }

wait_guac_db() {
    local i
    for (( i = 0; i < 60; i++ )); do
        docker exec guacamole-postgres pg_isready -q -U "${CFG[GUAC_DB_USER]}" -d "${CFG[GUAC_DB_NAME]}" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# image_version_ge IMAGE MAJOR.MINOR -> true if the tag is >= or not a version (latest, stable...)
image_version_ge() {
    local tag=${1##*:} want=$2
    [[ "$1" == *:* ]] || tag=latest
    [[ "$tag" =~ ^([0-9]+)\.([0-9]+) ]] || return 0
    local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
    local wa=${want%%.*} wb=${want#*.}
    (( a > wa || (a == wa && b >= wb) ))
}

guac_db_prepare() {   # run before the rest of the guacamole project starts
    local d dump n
    d=$(app_dir guacamole); dump="$d/.restore/guacamole.dump"
    (( DRY_RUN )) && { [[ -f "$dump" ]] && run pg_restore "$dump"; return 0; }
    compose_app guacamole up -d postgres >/dev/null 2>&1 || compose_app guacamole up -d postgres
    wait_guac_db || die "Guacamole PostgreSQL did not become ready (docker logs guacamole-postgres)."
    n=$(guac_psql -tAc "SELECT count(*) FROM information_schema.tables WHERE table_name = 'guacamole_user'" </dev/null 2>/dev/null || echo 0)
    if [[ -f "$dump" ]]; then
        if [[ "$n" != 0 ]]; then
            log_warn "Guacamole database already has data; imported dump NOT restored (kept at $dump)."
        else
            log_info "Restoring imported Guacamole database ($(du -h "$dump" | cut -f1))"
            docker exec -i guacamole-postgres pg_restore -U "${CFG[GUAC_DB_USER]}" -d "${CFG[GUAC_DB_NAME]}" \
                --no-owner --role="${CFG[GUAC_DB_USER]}" --exit-on-error <"$dump" \
                || die "pg_restore failed; the dump is kept at $dump"
            mv "$dump" "$d/.restore/restored-$(date +%F_%H%M%S).dump"
            log_ok "Guacamole database restored"
            n=1
        fi
    fi
    if [[ "$n" != 0 ]] && image_version_ge "${CFG[GUACAMOLE_IMAGE]}" 1.6; then
        local has
        has=$(guac_psql -tAc "SELECT count(*) FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'guacamole_system_permission_type' AND e.enumlabel = 'AUDIT'" </dev/null 2>/dev/null || echo error)
        if [[ "$has" == 0 ]]; then
            log_info "Upgrading Guacamole schema for 1.6 (upgrade-pre-1.6.0.sql)"
            guac_psql -c "ALTER TYPE guacamole_system_permission_type ADD VALUE 'AUDIT' BEFORE 'ADMINISTER';" </dev/null >/dev/null \
                || die "Guacamole schema upgrade failed."
            log_ok "Guacamole schema upgraded"
        fi
    fi
    return 0
}

# ---- Pi-hole local DNS for our names ----------------------------------------
render_dns_hosts() {   # "IP name" lines for the dashboard and every endpoint with a subdomain
    local ip key title sub _rest name
    ip=$(eff_host)
    [[ -n "${CFG[DOMAIN]}" ]] || return 0
    name=$(fqdn "${CFG[DASH_SUBDOMAIN]}"); [[ -n "$name" ]] && printf '%s %s\n' "$ip" "$name"
    while IFS='|' read -r key title sub _rest; do
        name=$(fqdn "$sub"); [[ -n "$name" ]] && printf '%s %s\n' "$ip" "$name"
    done < <(all_endpoints)
    return 0
}

write_pihole_dns() {
    app_on pihole && [[ "${CFG[PIHOLE_LOCAL_DNS]}" == yes && -n "${CFG[DOMAIN]}" ]] || return 0
    local f; f="$(app_dir pihole)/etc-pihole/hosts/docker-dashboard.list"
    run mkdir -p "$(dirname "$f")"
    { printf '# Managed by %s -- names served by the dashboard proxy\n' "$SCRIPT_NAME"; render_dns_hosts; } | write_file "$f" 644 root:root
    return 0
}

dns_records() {
    ensure_config; detect_network
    [[ -n "${CFG[DOMAIN]}" ]] || { log_warn "No domain set (Settings -> Page); links use ports instead."; return 0; }
    log_step "DNS records for the dashboard proxy (all point at $(eff_host))"
    render_dns_hosts | awk '{printf "  %-40s A  %s\n", $2, $1}'
    if app_on pihole && [[ "${CFG[PIHOLE_LOCAL_DNS]}" == yes ]]; then
        log_info "Pi-hole answers these itself (etc-pihole/hosts/docker-dashboard.list)."
    fi
    log_info "If clients use another DNS server for ${CFG[DOMAIN]}, add them there. Windows DNS (PowerShell on the DNS server):"
    render_dns_hosts | while read -r ip name; do
        printf '    Add-DnsServerResourceRecordA -ZoneName "%s" -Name "%s" -IPv4Address "%s"\n' "${CFG[DOMAIN]}" "${name%."${CFG[DOMAIN]}"}" "$ip"
    done
    return 0
}

# -----------------------------------------------------------------------------
# CUSTOM APPS: $STACKS_DIR/custom/<name>/{compose.yaml|docker-compose.yml} + app.conf
# Your compose file is never modified: after each start the script attaches the app's
# container to the proxy network under the alias dd-c-<name>.
# -----------------------------------------------------------------------------
CUSTOM_KEYS=( TITLE ENABLED MANAGED PROJECT CONTAINER SUBDOMAIN SERVICE PORT TLS FLAGS UPSTREAM_URL FALLBACK_URL DESCRIPTION )
declare -A CA=()

custom_root()     { printf '%s/custom' "$STACKS_DIR"; }
custom_dir()      { printf '%s/custom/%s' "$STACKS_DIR" "$1"; }
# custom_conf_get NAME KEY -- one value from app.conf without touching CA[]
custom_conf_get() {
    local f; f="$(custom_dir "$1")/app.conf"
    [[ -f "$f" ]] || return 0
    conf_unquote "$(sed -n "s/^$2=//p" "$f" | head -n1)"
}
custom_project()  { local p; p=$(custom_conf_get "$1" PROJECT); printf '%s' "${p:-${APP_PREFIX}c-$1}"; }
custom_managed()  { [[ "$(custom_conf_get "$1" MANAGED)" != no ]]; }
ca_project()      { printf '%s' "${CA[PROJECT]:-${APP_PREFIX}c-$1}"; }   # same, from CA[] (also before app.conf is saved)
# compose projects of managed custom apps (handled by the custom-app pass of update-all)
custom_managed_projects()  { local n; for n in $(custom_names); do custom_managed "$n" && custom_project "$n" && echo; done; return 0; }
custom_external_projects() { local n; for n in $(custom_names); do custom_managed "$n" || { custom_project "$n"; echo; }; done; return 0; }
custom_alias()    { printf '%sc-%s' "$APP_PREFIX" "$1"; }
valid_app_name()  { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]]; }

custom_names() {   # every folder with an app.conf
    local d
    [[ -d "$(custom_root)" ]] || return 0
    for d in "$(custom_root)"/*/; do
        [[ -f "${d}app.conf" ]] || continue
        d=${d%/}; d=${d##*/}
        valid_app_name "$d" && printf '%s\n' "$d"
    done
    return 0
}

custom_defaults() {
    CA=( [TITLE]="$1" [ENABLED]="yes" [MANAGED]="yes" [PROJECT]="" [CONTAINER]="" [SUBDOMAIN]="$1" [SERVICE]="" [PORT]="" [TLS]="no" [FLAGS]="ws"
         [UPSTREAM_URL]="" [FALLBACK_URL]="" [DESCRIPTION]="" )
}

custom_load() {   # custom_load NAME -> CA[]
    local f line
    custom_defaults "$1"
    f="$(custom_dir "$1")/app.conf"
    [[ -f "$f" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
        in_list "${BASH_REMATCH[1]}" "${CUSTOM_KEYS[@]}" || continue
        CA[${BASH_REMATCH[1]}]=$(conf_unquote "${BASH_REMATCH[2]}")
    done <"$f"
    return 0
}

custom_save() {   # custom_save NAME  (from CA[])
    local k d; d=$(custom_dir "$1")
    run mkdir -p "$d"
    {
        printf '# %s custom app -- edit here or in the Apps menu, then: sudo docker-dashboard --apply\n' "$SCRIPT_NAME"
        printf '# SERVICE/PORT: compose service and container port the proxy talks to (PORT speaks https: TLS=yes)\n'
        printf '# UPSTREAM_URL: instead of SERVICE/PORT, e.g. for network_mode: host apps (http://192.168.0.190:8080)\n'
        printf '# FLAGS: any of ws (websockets), stream (no buffering), big (large uploads)\n'
        printf '# MANAGED=no: started/updated by its own script; docker-dashboard only proxies and checks it\n'
        printf '# PROJECT: its compose project name (empty = %sc-<folder>); CONTAINER: a plain docker-run container instead\n' "$APP_PREFIX"
        for k in "${CUSTOM_KEYS[@]}"; do printf '%s=%s\n' "$k" "$(conf_quote "${CA[$k]:-}")"; done
    } | write_file "$d/app.conf" 644 root:root
}

# custom_compose_file NAME -> the app's compose file (the usual names, in compose's own order of preference)
custom_compose_file() {
    local f
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        [[ -f "$(custom_dir "$1")/$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}
custom_on() {
    custom_load "$1" && [[ "${CA[ENABLED]}" == yes ]] || return 1
    [[ "${CA[MANAGED]}" == no ]] || custom_compose_file "$1" >/dev/null
}

# folders under custom/ that have a compose file but no app.conf yet (e.g. put there by another installer)
custom_unconfigured() {
    local d n
    [[ -d "$(custom_root)" ]] || return 0
    for d in "$(custom_root)"/*/; do
        d=${d%/}; n=${d##*/}
        [[ -f "$d/app.conf" ]] && continue
        valid_app_name "$n" && custom_compose_file "$n" >/dev/null && printf '%s\n' "$n"
    done
    return 0
}
enabled_customs() { local n; for n in $(custom_names); do custom_on "$n" && printf '%s\n' "$n"; done; return 0; }

custom_upstream() {   # from CA[] of NAME
    if [[ -n "${CA[UPSTREAM_URL]}" ]]; then printf '%s' "${CA[UPSTREAM_URL]%/}"
    else printf '%s://%s:%s' "$( [[ "${CA[TLS]}" == yes ]] && echo https || echo http)" "$(custom_alias "$1")" "${CA[PORT]}"; fi
}

custom_endpoint() {   # custom_endpoint NAME -> endpoint record (same shape as app_endpoints)
    custom_load "$1" || return 0
    local flags=${CA[FLAGS]//[[:space:]]/}
    [[ "${CA[TLS]}" == yes || "${CA[UPSTREAM_URL]}" == https://* ]] && flags+="${flags:+,}tls"
    printf 'c-%s|%s|%s|%s|%s|%s|%s\n' "$1" "${CA[TITLE]}" "${CA[SUBDOMAIN]}" "$(custom_upstream "$1")" \
        "$flags" "${CA[FALLBACK_URL]}" "${CA[DESCRIPTION]}"
}

# every subdomain in use, except the one for EXCLUDE (an app key or c-<name>)
used_subdomains() {
    local key title sub _r a n
    for a in $(enabled_apps); do
        while IFS='|' read -r key title sub _r; do [[ "$key" == "${1:-}" ]] || printf '%s\n' "$sub"; done < <(app_endpoints "$a")
    done
    for n in $(custom_names); do
        [[ "c-$n" == "${1:-}" ]] && continue
        custom_load "$n" && printf '%s\n' "${CA[SUBDOMAIN]}"
    done
    printf '%s\n' "${CFG[DASH_SUBDOMAIN]}"
}

custom_compose() {   # custom_compose NAME ARGS...  (runs in the app folder so its .env is used)
    local n=$1; shift
    local f; f=$(custom_compose_file "$n") || { log_error "$n: no compose file in $(custom_dir "$n")"; return 1; }
    ( cd "$(custom_dir "$n")" && docker compose -p "$(custom_project "$n")" -f "$f" "$@" )
}

# published host ports from 'docker compose config --format json' -> "port/proto<TAB>label"
compose_json_ports() {   # stdin: compose config JSON; $1 label
    { grep -o '{[^{}]*"published":"[0-9]*"[^{}]*}' || true; } | while IFS= read -r o; do
        local p proto
        p=$(sed -n 's/.*"published":"\([0-9]*\)".*/\1/p' <<<"$o")
        proto=$(sed -n 's/.*"protocol":"\([a-z]*\)".*/\1/p' <<<"$o")
        printf '%s/%s\t%s\n' "$p" "${proto:-tcp}" "$1"
    done
}

custom_host_ports() {   # only apps this script starts; an external app's ports are its own business
    local n
    docker_up || return 0
    for n in $(enabled_customs); do
        custom_managed "$n" || continue
        custom_load "$n"
        custom_compose "$n" config --format json 2>/dev/null | tr -d '\n ' | compose_json_ports "${CA[TITLE]} (custom)"
    done
    return 0
}

custom_validate() {   # custom_validate NAME -> 0 ok, messages on failure
    local n=$1 d sub bad=0 svcs
    d=$(custom_dir "$n")
    custom_load "$n"
    if [[ "${CA[MANAGED]}" != no ]]; then
        custom_compose_file "$n" >/dev/null || { log_error "$n: no compose file (compose.yaml or docker-compose.yml) in $d."; return 1; }
    fi
    v_sub "${CA[SUBDOMAIN]}" || { log_error "$n: SUBDOMAIN '${CA[SUBDOMAIN]}' is not a valid name."; bad=1; }
    while IFS= read -r sub; do
        [[ "$sub" == "${CA[SUBDOMAIN]}" ]] && { log_error "$n: name '${CA[SUBDOMAIN]}' is already used by another app."; bad=1; break; }
    done < <(used_subdomains "c-$n")
    if [[ -n "${CA[UPSTREAM_URL]}" ]]; then
        valid_url "${CA[UPSTREAM_URL]}" || { log_error "$n: UPSTREAM_URL is not an http(s) URL."; bad=1; }
    else
        valid_port "${CA[PORT]}" || { log_error "$n: PORT '${CA[PORT]}' is not a port number."; bad=1; }
        if docker_up && [[ "${CA[MANAGED]}" == no ]]; then
            [[ -n "$(custom_service_ids "$n")" ]] || { log_error "$n: no container for service '${CA[SERVICE]}' in project $(ca_project "$n")."; bad=1; }
        elif docker_up; then
            local err
            if ! svcs=$(custom_compose "$n" config --services 2>"$d/.config-error"); then
                err=$(head -n3 "$d/.config-error" 2>/dev/null | tr '\n' ' ')
                log_error "$n: 'docker compose config' fails in $d: $err"
                log_info "  If its own script supplies variables or secrets, set it up as started by its own script (MANAGED='no')."
                rm -f "$d/.config-error"; return 1
            fi
            rm -f "$d/.config-error"
            in_list "${CA[SERVICE]}" $svcs || { log_error "$n: SERVICE '${CA[SERVICE]}' is not in $(custom_compose_file "$n") (services: $(xargs <<<"$svcs"))."; bad=1; }
        fi
    fi
    valid_field "${CA[TITLE]}" && valid_field "${CA[DESCRIPTION]}" || { log_error "$n: TITLE/DESCRIPTION may not contain '|'."; bad=1; }
    return $bad
}

custom_attach() {   # put the service's container(s) on the proxy network (idempotent)
    local n=$1 id nets
    custom_load "$n"
    [[ -z "${CA[UPSTREAM_URL]}" ]] || return 0
    for id in $(custom_service_ids "$n"); do
        nets=$(docker inspect -f '{{.HostConfig.NetworkMode}} {{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id" 2>/dev/null)
        [[ " $nets " == *" $PROXY_NET "* ]] && continue
        if [[ "$nets" == host* ]]; then
            log_warn "$n: '${CA[SERVICE]}' uses host networking; set UPSTREAM_URL=http://$(eff_host):<port> in its app.conf."
            continue
        fi
        run docker network connect --alias "$(custom_alias "$n")" "$PROXY_NET" "$id" >/dev/null \
            && _log_file INFO "attached $id ($n) to $PROXY_NET"
    done
    return 0
}

custom_up() {   # custom_up NAME [pull]
    local n=$1 mode=${2:-nopull}
    custom_load "$n"
    log_step "${CA[TITLE]} (custom$( [[ "${CA[MANAGED]}" == no ]] && echo ", started by its own script"): $(custom_dir "$n"))"
    custom_validate "$n" || { log_error "Fix $(custom_dir "$n")/app.conf, then apply again."; return 1; }
    if [[ "${CA[MANAGED]}" == no ]]; then   # never start, stop or pull someone else's app
        (( DRY_RUN )) && { run docker network connect "$PROXY_NET" "<${CA[SERVICE]}>"; return 0; }
        custom_running "$n" || return 1
        custom_attach "$n"
        log_ok "${CA[TITLE]} is proxied"
        return 0
    fi
    if (( DRY_RUN )); then
        [[ "$mode" == pull ]] && run custom_compose "$n" pull
        run custom_compose "$n" up -d --remove-orphans
        return 0
    fi
    # errexit is off in here (called as `( custom_up ) || ...`), so every step is checked explicitly
    if [[ "$mode" == pull ]]; then run_logged custom_compose "$n" pull --ignore-buildable --ignore-pull-failures || true; fi
    # compose builds images that have a build: section and are not built yet
    run_logged custom_compose "$n" up -d --remove-orphans || { log_error "$n: docker compose up failed."; return 1; }
    custom_running "$n" || return 1
    custom_attach "$n"
    log_ok "${CA[TITLE]} is up"
}

custom_service_ids() {   # custom_service_ids NAME [running]  (CA[] loaded)
    local -a filt=( --filter "label=com.docker.compose.project=$(ca_project "$1")" --filter "label=com.docker.compose.service=${CA[SERVICE]}" )
    [[ -n "${CA[CONTAINER]}" ]] && filt=( --filter "name=^${CA[CONTAINER]}\$" )
    [[ "${2:-}" == running ]] && filt+=( --filter status=running )
    docker ps -aq "${filt[@]}" 2>/dev/null
}

custom_running() {   # the proxied service must actually be running
    local n=$1
    [[ -n "${CA[UPSTREAM_URL]}" ]] && return 0
    if [[ -z "$(custom_service_ids "$n" running)" ]]; then
        if [[ "${CA[MANAGED]}" == no ]]; then
            log_error "$n: '${CA[SERVICE]}' of project $(ca_project "$n") is not running. Start it with its own script."
        else
            log_error "$n: service '${CA[SERVICE]}' is not running. See: sudo docker compose -p $(custom_project "$n") logs ${CA[SERVICE]} (in $(custom_dir "$n"))"
        fi
        return 1
    fi
}

custom_buildable() { custom_compose "$1" config --format json 2>/dev/null | tr -d '\n ' | grep -q '"build":{'; }

custom_down() {   # custom_down NAME [REASON]
    local n=$1
    custom_ids_all "$n" | grep -q . || return 0
    custom_load "$n"
    if [[ "${CA[MANAGED]}" == no ]]; then
        log_info "${CA[TITLE]}: started by its own script -- taken off the proxy, left running"
        custom_detach "$n"
        return 0
    fi
    log_info "Stopping ${CA[TITLE]} (${2:-disabled; data kept in $(custom_dir "$n")})"
    run_logged custom_compose "$n" down --remove-orphans || true
}

# custom_services NAME -> service names, from its running containers (external) or its compose file
custom_services() {
    local n=$1 p
    if [[ "${CA[MANAGED]}" == no ]]; then
        p=$(ca_project "$n")
        docker ps -a --filter "label=com.docker.compose.project=$p" --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null | sort -u | xargs
    else
        { custom_compose "$n" config --services 2>/dev/null || true; } | xargs
    fi
}

# the compose project already running from a folder, if any (started by another script)
running_project_in() {
    docker ps -a --filter "label=com.docker.compose.project.working_dir=$1" --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u | head -n1
}

# ---- Apps menu: add / edit / toggle / remove ---------------------------------
custom_prompt() {   # custom_prompt NAME -- edit CA[] interactively
    local n=$1 v svcs
    ask v "Title on the page" "${CA[TITLE]}"; CA[TITLE]=$v
    ask v "Name (-> $(fqdn "${CA[SUBDOMAIN]}"))" "${CA[SUBDOMAIN]}"; CA[SUBDOMAIN]=$v
    svcs=$(custom_services "$n")
    [[ -z "${CA[SERVICE]}" && -n "$svcs" && "$svcs" != *" "* ]] && CA[SERVICE]=$svcs
    log_info "Services: ${svcs:-unknown}"
    if [[ -n "${CA[CONTAINER]}" ]]; then log_info "Container: ${CA[CONTAINER]}"
    else ask v "Service the proxy talks to" "${CA[SERVICE]}"; CA[SERVICE]=$v; fi
    ask v "Its container port" "${CA[PORT]}"; CA[PORT]=$v
    ask v "Does that port speak HTTPS itself? (yes/no)" "${CA[TLS]}"; CA[TLS]=$v
    ask v "Flags: ws,stream,big (- for none)" "${CA[FLAGS]}"; [[ "$v" == - ]] && v=""; CA[FLAGS]=$v
    ask v "Direct link shown under the card, e.g. https://$(eff_host):8444/ (- for none)" "${CA[FALLBACK_URL]}"; [[ "$v" == - ]] && v=""; CA[FALLBACK_URL]=$v
    ask v "Description (- for none)" "${CA[DESCRIPTION]}"; [[ "$v" == - ]] && v=""; CA[DESCRIPTION]=$v
}

custom_add() {
    local n src v d img cport hport
    read -rp "  Short name (a-z, 0-9, -; folder and project name): " n || return 0
    valid_app_name "$n" || { log_warn "Invalid name"; return 0; }
    d=$(custom_dir "$n")
    [[ -e "$d" ]] && { log_warn "$d already exists; use Edit."; return 0; }
    printf '   1) Use an existing compose file (copied here)\n   2) Make one from an image\n'
    read -rp "  Choice: " src || return 0
    run mkdir -p "$d"
    case "$src" in
        1) read -rp "  Path to the compose file: " v || return 0
           [[ -f "$v" ]] || { log_warn "Not found: $v"; rmdir "$d" 2>/dev/null; return 0; }
           run cp "$v" "$d/compose.yaml"
           [[ -f "$(dirname "$v")/.env" ]] && run cp "$(dirname "$v")/.env" "$d/.env" && run chmod 600 "$d/.env"
           log_info "Copied. Relative paths in it (./data ...) now resolve inside $d -- copy those folders there too." ;;
        2) ask img "Image" ""
           [[ "$img" =~ ^[a-z0-9][a-z0-9._/:@-]*$ ]] || { log_warn "Invalid image"; rmdir "$d" 2>/dev/null; return 0; }
           if ! docker image inspect "$img" >/dev/null 2>&1; then
               log_warn "Image '$img' is not on this host; apply will try to pull it from a registry."
               [[ "$img" != */* ]] && log_warn "If it is built from source, use 'Set up a folder' with its project folder instead."
               confirm "Continue with this image?" n || { rmdir "$d" 2>/dev/null; return 0; }
           fi
           ask cport "Container port of its web UI" ""
           valid_port "$cport" || { log_warn "Invalid port"; rmdir "$d" 2>/dev/null; return 0; }
           ask hport "Also publish on host port (- for proxy only)" "-"; [[ "$hport" == - ]] && hport=""
           {
               printf '# Created by %s -- yours to edit (volumes, environment, ...)\n' "$SCRIPT_NAME"
               printf 'services:\n  %s:\n    image: %s\n    container_name: %s\n    restart: unless-stopped\n' "$n" "$(yaml_str "$img")" "$n"
               [[ -n "$hport" ]] && printf '    ports:\n      - "%s:%s"\n' "$hport" "$cport"
               printf '    volumes:\n      - "./data:/data"\n'
           } | write_file "$d/compose.yaml" 644 root:root
           run mkdir -p "$d/data"
           custom_defaults "$n"; CA[SERVICE]=$n; CA[PORT]=$cport
           [[ -n "$hport" ]] && CA[FALLBACK_URL]="http://$(eff_host):$hport/" ;;
        *) rmdir "$d" 2>/dev/null; return 0 ;;
    esac
    [[ "$src" == 1 ]] && custom_defaults "$n"
    custom_prompt "$n"
    custom_save "$n"
    custom_validate "$n" && log_ok "Custom app '$n' saved. Apply (A) to start it." || log_warn "Saved, but fix the problems above before applying."
}

custom_ids_all() {   # every container of the app (compose project, or its one named container)
    local c; c=$(custom_conf_get "$1" CONTAINER)
    if [[ -n "$c" ]]; then docker ps -aq --filter "name=^${c}\$" 2>/dev/null
    else docker ps -aq --filter "label=com.docker.compose.project=$(custom_project "$1")" 2>/dev/null; fi
}

custom_detach() {   # take the app's containers off the proxy network
    local n=$1 id
    for id in $(custom_ids_all "$n"); do
        docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id" 2>/dev/null | grep -qw "$PROXY_NET" \
            && run docker network disconnect "$PROXY_NET" "$id" >/dev/null 2>&1
    done
    return 0
}

custom_remove() {   # three levels: unregister / stop + unregister / delete everything
    local n=$1 d ch
    d=$(custom_dir "$n"); custom_load "$n"
    printf '\n  Remove %s (%s):\n' "${CA[TITLE]}" "$d"
    printf '   1) Unregister only    -- off the proxy, page and DNS list; containers keep running, folder untouched\n'
    if [[ "${CA[MANAGED]}" == no ]]; then printf '   2) (same as 1 -- this app is started by its own script, so it is never stopped from here)\n'
    else printf '   2) Stop + unregister  -- containers stopped and removed; folder and data kept\n'; fi
    printf '   3) Delete everything  -- containers stopped, folder deleted with its data\n'
    printf '   0) Cancel\n'
    read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) local proj; proj=$(custom_project "$n"); [[ -n "${CA[CONTAINER]}" ]] && proj="container ${CA[CONTAINER]}"
           custom_detach "$n"
           run rm -f "$d/app.conf"
           log_ok "Unregistered $n. Its containers still run (project $proj); docker-dashboard no longer proxies or updates them."
           log_info "Set it up again any time with F (it is listed under 'not set up yet')." ;;
        2) custom_down "$n" "unregistering"
           run rm -f "$d/app.conf"
           log_ok "Stopped and unregistered $n; $d is kept (set up again with F)." ;;
        3) confirm "Stop '$n' and delete $d with all its data?" n && confirm_typed DELETE-APP || { log_info "Cancelled"; return 0; }
           custom_down "$n" "removing"
           safe_path "$d" && run rm -rf -- "$d"
           log_ok "Removed $n and its folder" ;;
        *) log_info "Cancelled" ;;
    esac
    [[ "$ch" =~ ^[123]$ ]] && log_info "Apply (A) to update the proxy, page and DNS list."
    return 0
}

# custom_candidates -> running containers not run or proxied by docker-dashboard, fields separated by $US:
#   container image project service workdir ports   (project/service/workdir empty for docker run;
#   $US, not a tab: read collapses repeated tabs and would shift the empty fields)
custom_candidates() {
    docker_up || return 0
    local known_p known_c n
    known_p=" $( { custom_managed_projects; custom_external_projects; } | xargs) "
    known_c=" $(for n in $(custom_names); do custom_conf_get "$n" CONTAINER; echo; done | xargs) "
    local fmt
    fmt=$(printf "%s$US" '{{.Names}}' '{{.Image}}' '{{.Label "com.docker.compose.project"}}' '{{.Label "com.docker.compose.service"}}' \
        '{{.Label "com.docker.compose.project.working_dir"}}')'{{.Ports}}'
    docker ps --format "$fmt" 2>/dev/null \
    | while IFS=$US read -r c img proj svc wd ports; do
        [[ "$c" == "$CONTAINER_NAME" || "$c" == "$WATCHTOWER_NAME" ]] && continue
        [[ -n "$proj" ]] && { is_own_project "$proj" && continue; [[ "$known_p" == *" $proj "* ]] && continue; }
        [[ "$known_c" == *" $c "* ]] && continue
        printf "%s$US%s$US%s$US%s$US%s$US%s\n" "$c" "$img" "$proj" "$svc" "$wd" "$ports"
    done
}

# first container port of a container: published ones first, then exposed ones
container_port_guess() {
    local p
    p=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Ports}}{{if $v}}{{$k}} {{end}}{{end}}' "$1" 2>/dev/null | tr ' ' '\n' | sed -n 's#/tcp$##p' | sort -n | head -n1)
    [[ -n "$p" ]] || p=$(docker inspect -f '{{range $k, $v := .Config.ExposedPorts}}{{$k}} {{end}}' "$1" 2>/dev/null | tr ' ' '\n' | sed -n 's#/tcp$##p' | sort -n | head -n1)
    printf '%s' "$p"
}

custom_add_running() {   # register a running container (any folder, compose or docker run) -- started by its own script
    local -a rows; local i c img proj svc wd ports n d
    mapfile -t rows < <(custom_candidates)
    (( ${#rows[@]} )) || { log_info "Every running container is already run or proxied by docker-dashboard."; return 0; }
    printf '\n  Running containers docker-dashboard does not know yet:\n'
    for i in "${!rows[@]}"; do
        IFS=$US read -r c img proj svc wd ports <<<"${rows[$i]}"
        printf '   %d) %-24s %-32s %s\n' "$((i + 1))" "$c" "${img:0:32}" "${proj:+compose: $proj ($wd)}${proj:-docker run}"
    done
    read -rp "  Number: " i || return 0
    [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#rows[@]} )) || { log_warn "No such container"; return 0; }
    IFS=$US read -r c img proj svc wd ports <<<"${rows[$((i - 1))]}"
    n=$(tr '[:upper:]_. ' '[:lower:]---' <<<"${proj:-$c}" | sed 's/[^a-z0-9-]//g; s/^-*//; s/-*$//' | cut -c1-32)
    ask n "Short name for it (folder custom/<name> holds only its app.conf)" "$n"
    valid_app_name "$n" || { log_warn "Invalid name"; return 0; }
    d=$(custom_dir "$n")
    [[ -e "$d/app.conf" ]] && { log_warn "$n is already set up; use Edit."; return 0; }
    custom_defaults "$n"
    CA[MANAGED]=no
    if [[ -n "$proj" ]]; then CA[PROJECT]=$proj; CA[SERVICE]=$svc
    else CA[CONTAINER]=$c; CA[SERVICE]=$c; fi
    CA[PORT]=$(container_port_guess "$c")
    [[ "${CA[PORT]}" =~ ^(443|8443|9443)$ ]] && CA[TLS]=yes
    log_info "Its own script keeps starting and updating it; docker-dashboard adds the name, card, DNS entry and checks."
    [[ -n "$wd" ]] && log_info "Its files stay in $wd."
    custom_prompt "$n"
    run mkdir -p "$d"
    custom_save "$n"
    custom_validate "$n" && log_ok "Custom app '$n' saved. Apply (A) to put it behind the proxy." \
        || log_warn "Saved, but fix the problems above before applying."
}

custom_edit() { custom_load "$1"; custom_prompt "$1"; custom_save "$1"; custom_validate "$1" || true; }

custom_adopt() {   # give a folder that already has a compose file (and maybe a build) its app.conf
    local -a cand; local i n
    mapfile -t cand < <(custom_unconfigured)
    (( ${#cand[@]} )) || { log_info "No folders without app.conf in $(custom_root)."; return 0; }
    for i in "${!cand[@]}"; do printf '   %d) %s  (%s)\n' "$((i + 1))" "${cand[$i]}" "$(custom_compose_file "${cand[$i]}")"; done
    read -rp "  Number: " i || return 0
    [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#cand[@]} )) || { log_warn "No such folder"; return 0; }
    n=${cand[$((i - 1))]}
    custom_defaults "$n"
    local proj ch
    proj=$(running_project_in "$(custom_dir "$n")")
    if [[ -n "$proj" ]]; then
        log_info "$n is already running as compose project '$proj' (started outside docker-dashboard)."
        printf '   1) Its own script keeps starting and updating it -- docker-dashboard adds the name, card and checks (recommended)\n'
        printf '   2) docker-dashboard starts and updates it from now on (its compose file must work on its own)\n'
        read -rp "  Choice [1]: " ch || return 0
        CA[PROJECT]=$proj
        [[ "${ch:-1}" == 2 ]] || CA[MANAGED]=no
    fi
    if [[ "${CA[MANAGED]}" != no ]] && custom_buildable "$n"; then
        log_info "$n builds its image from source; the first apply builds it, update-all rebuilds it."
    fi
    custom_prompt "$n"
    custom_save "$n"
    custom_validate "$n" && log_ok "Custom app '$n' saved. Apply (A) to $( [[ "${CA[MANAGED]}" == no ]] && echo "put it behind the proxy" || echo "start it")." \
        || log_warn "Saved, but fix the problems above before applying."
}

menu_custom() {
    ensure_config
    local n ch i
    local -a names
    while :; do
        mapfile -t names < <(custom_names)
        printf '\n  %sCustom apps%s  (%s)\n' "$B" "$NC" "$(custom_root)"
        (( ${#names[@]} )) || printf '   none yet\n'
        local pending running
        pending=$(custom_unconfigured | xargs)
        [[ -n "$pending" ]] && printf '   %snot set up yet:%s %s  (F to set up)\n' "$Y" "$NC" "$pending"
        running=$(custom_candidates | cut -d"$US" -f1 | xargs)
        [[ -n "$running" ]] && printf '   %srunning, not added:%s %s  (D to add)\n' "$Y" "$NC" "$running"
        for i in "${!names[@]}"; do
            n=${names[$i]}; custom_load "$n"
            printf '   %d) %-22s %-34s %b%s\n' "$((i + 1))" "${CA[TITLE]}" "$(fqdn "${CA[SUBDOMAIN]}")" \
                "$( [[ "${CA[ENABLED]}" == yes ]] && echo "${G}on${NC}" || echo "${D}off${NC}")" \
                "$( [[ "${CA[MANAGED]}" == no ]] && echo "  (started by its own script)")"
        done
        printf '\n   N) New   F) Set up a folder already in custom/   D) Add a container that is already running (any folder)\n'
        printf '   E) Edit   T) Toggle on/off   R) Remove   A) Apply   0) Back\n'
        read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            n) menu_action custom_add ;;
            d) menu_action custom_add_running ;;
            f) menu_action custom_adopt ;;
            e|t|r)
                read -rp "  Number: " i || continue
                [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#names[@]} )) || { log_warn "No such app"; continue; }
                n=${names[$((i - 1))]}; custom_load "$n"
                case "${ch,,}" in
                    e) menu_action custom_edit "$n" ;;
                    t) [[ "${CA[ENABLED]}" == yes ]] && CA[ENABLED]=no || CA[ENABLED]=yes
                       custom_save "$n"; log_info "${CA[TITLE]}: ${CA[ENABLED]} (takes effect on apply)" ;;
                    r) menu_action custom_remove "$n" ;;
                esac ;;
            a) menu_action stack_apply ;;
            0|q) return 0 ;;
            *) printf '  %sInvalid choice%s\n' "$R" "$NC" ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# DASHBOARD RENDERERS (stdout; no side effects -- covered by the self-test)
# -----------------------------------------------------------------------------
dash_host() { fqdn "${CFG[DASH_SUBDOMAIN]}"; }
dashboard_url() {
    local h; h=$(dash_host); h=${h:-$(eff_host)}
    printf 'https://%s%s/' "$h" "$(https_port_suffix)"
}
endpoint_url() {   # endpoint_url SUBDOMAIN FALLBACK -> the link to show
    local h; h=$(fqdn "$1")
    if [[ -n "$h" ]]; then printf 'https://%s%s/' "$h" "$(https_port_suffix)"; else printf '%s' "$2"; fi
}

render_compose() {
    printf '# Managed by %s v%s -- regenerated on every apply; change settings instead.\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf 'name: %s\nservices:\n  dashboard:\n' "$PROJECT_NAME"
    printf '    image: %s\n    container_name: %s\n    restart: unless-stopped\n' "$(yaml_str "${CFG[NGINX_IMAGE]}")" "$CONTAINER_NAME"
    printf '    ports:\n      - "%s:80"\n      - "%s:443"\n' "${CFG[HTTP_PORT]}" "${CFG[HTTPS_PORT]}"
    if app_on guacamole && [[ -n "${CFG[GUACAMOLE_TLS_PORT]}" ]]; then
        printf '      - "%s:%s"\n' "${CFG[GUACAMOLE_TLS_PORT]}" "${CFG[GUACAMOLE_TLS_PORT]}"
    fi
    printf '    volumes:\n      - "./html:/usr/share/nginx/html:ro"\n      - "./nginx:/etc/nginx/conf.d:ro"\n      - "./certs:/etc/nginx/certs:ro"\n'
    [[ -n "${CFG[FILES_DIR]}" ]] && printf '      - "%s:%s:ro"\n' "${CFG[FILES_DIR]%/}" "$FILES_MOUNT"
    printf '    labels:\n      dev.docker-dashboard.managed: "true"\n'
    printf '    networks: ["%s"]\n' "$PROXY_NET"
    printf 'networks:\n  %s:\n    external: true\n' "$PROXY_NET"
}

render_files_locations() {
    printf '    location /files/ {\n        alias %s/;\n        autoindex on;\n        default_type application/octet-stream;\n    }\n' "$FILES_MOUNT"
}

render_tls_common() {
    printf '    ssl_certificate     /etc/nginx/certs/dashboard.crt;\n'
    printf '    ssl_certificate_key /etc/nginx/certs/dashboard.key;\n'
    printf '    ssl_protocols       TLSv1.2 TLSv1.3;\n'
    printf '    server_tokens off;\n'
}

# render_proxy_location UPSTREAM FLAGS
render_proxy_location() {
    local up=$1 flags=",$2,"
    [[ "$flags" == *,admin,* ]] && printf '    location = / { return 302 /admin/; }\n'
    printf '    location / {\n'
    printf '        set $upstream %s;\n' "$up"
    printf '        proxy_pass $upstream;\n'
    printf '        proxy_http_version 1.1;\n'
    printf '        proxy_set_header Host $host;\n'
    printf '        proxy_set_header X-Real-IP $remote_addr;\n'
    printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
    printf '        proxy_set_header X-Forwarded-Proto https;\n'
    printf '        proxy_set_header X-Forwarded-Host $host;\n'
    if [[ "$flags" == *,ws,* ]]; then
        printf '        proxy_set_header Upgrade $http_upgrade;\n'
        printf '        proxy_set_header Connection $connection_upgrade;\n'
        printf '        proxy_read_timeout 1h;\n        proxy_send_timeout 1h;\n'
    fi
    [[ "$flags" == *,tls,* ]]    && printf '        proxy_ssl_verify off;\n        proxy_ssl_server_name on;\n'
    [[ "$flags" == *,stream,* ]] && printf '        proxy_buffering off;\n        proxy_request_buffering off;\n'
    [[ "$flags" == *,big,* ]]    && printf '        client_max_body_size 0;\n'
    printf '    }\n'
}

render_nginx() {
    local redirect="https://\$host" key title sub up flags fb desc host
    [[ "${CFG[HTTPS_PORT]}" == 443 ]] || redirect+=":${CFG[HTTPS_PORT]}"
    printf '# Managed by %s v%s -- regenerated on every apply.\n\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '# Docker DNS: upstreams resolve per request, so a stopped app gives 502 instead of breaking nginx\n'
    printf 'resolver 127.0.0.11 valid=10s ipv6=off;\n'
    printf 'map $http_upgrade $connection_upgrade { default upgrade; "" close; }\n\n'
    printf 'server {\n    listen 80 default_server;\n    server_name _;\n    server_tokens off;\n'
    printf '    location ~ /\\. { return 404; }\n'
    if [[ -n "${CFG[FILES_DIR]}" && "${CFG[FILES_HTTP]}" == yes ]]; then
        printf '    # Plain-HTTP file downloads for clients that cannot do TLS\n'
        render_files_locations
    fi
    printf '    location / { return 301 %s$request_uri; }\n}\n\n' "$redirect"
    # landing page: dashboard name, bare IP and anything unmatched
    printf 'server {\n    listen 443 ssl default_server;\n    server_name _;\n'
    render_tls_common
    printf '    root  /usr/share/nginx/html;\n    index index.html;\n'
    printf '    add_header X-Content-Type-Options nosniff always;\n    add_header Referrer-Policy same-origin always;\n    add_header X-Frame-Options DENY always;\n'
    printf '    location ~ /\\. { return 404; }\n'
    printf '    location ~ \\.json$ {\n        add_header Cache-Control "no-store" always;\n        add_header X-Content-Type-Options nosniff always;\n    }\n'
    if [[ -n "${CFG[FILES_DIR]}" ]]; then
        render_files_locations
        printf '    location /files-index/ {\n        alias %s/;\n        autoindex on;\n        autoindex_format json;\n        add_header Cache-Control "no-store" always;\n    }\n' "$FILES_MOUNT"
    fi
    printf '    location / { try_files $uri $uri/ =404; }\n}\n'
    # one server per app endpoint
    while IFS='|' read -r key title sub up flags fb desc; do
        host=$(fqdn "$sub"); [[ -n "$host" ]] || continue
        printf '\n# %s\nserver {\n    listen 443 ssl;\n    server_name %s;\n' "$title" "$host"
        render_tls_common
        render_proxy_location "$up" "$flags"
        printf '}\n'
    done < <(all_endpoints)
    # Guacamole's old https://host:8443/ keeps working
    if app_on guacamole && [[ -n "${CFG[GUACAMOLE_TLS_PORT]}" ]]; then
        printf '\n# Guacamole on its legacy port\nserver {\n    listen %s ssl;\n    server_name _;\n' "${CFG[GUACAMOLE_TLS_PORT]}"
        render_tls_common
        render_proxy_location "http://guacamole:8080" "ws,stream"
        printf '}\n'
    fi
}

render_services_json() {
    local i g first=1 gfirst key title sub up flags fb desc url
    local -a groups=()
    for i in "${!SVC_NAME[@]}"; do in_list "${SVC_GROUP[$i]}" ${groups[@]+"${groups[@]}"} || groups+=("${SVC_GROUP[$i]}"); done
    printf '{\n  "title": %s,\n  "version": %s,\n  "generated": %s,\n' \
        "$(json_str "${CFG[DASH_TITLE]}")" "$(json_str "$SCRIPT_VERSION")" "$(json_str "$(date -Iseconds)")"
    printf '  "host": %s,\n  "httpPort": %s,\n  "httpsPort": %s,\n' "$(json_str "$(eff_host)")" "${CFG[HTTP_PORT]}" "${CFG[HTTPS_PORT]}"
    printf '  "files": %s,\n  "filesHttp": %s,\n  "health": %s,\n' \
        "$( [[ -n "${CFG[FILES_DIR]}" ]] && echo true || echo false)" \
        "$( [[ -n "${CFG[FILES_DIR]}" && "${CFG[FILES_HTTP]}" == yes ]] && echo true || echo false)" \
        "$( [[ "${CFG[HEALTH_CHECK]}" == yes ]] && echo true || echo false)"
    printf '  "groups": ['
    local apps_out=""
    while IFS='|' read -r key title sub up flags fb desc; do
        url=$(endpoint_url "$sub" "$fb"); [[ -n "$url" ]] || continue
        [[ -n "$apps_out" ]] && apps_out+=','
        apps_out+=$(printf '\n      {"name": %s, "url": %s, "alt": %s, "desc": %s}' \
            "$(json_str "$title")" "$(json_str "$url")" "$(json_str "$( [[ "$fb" != "$url" ]] && printf '%s' "$fb")")" "$(json_str "$desc")")
    done < <(all_endpoints)
    if [[ -n "$apps_out" ]]; then
        printf '\n    {"name": "Apps", "items": [%s\n    ]}' "$apps_out"
        first=0
    fi
    for g in ${groups[@]+"${groups[@]}"}; do
        (( first )) || printf ','
        first=0; gfirst=1
        printf '\n    {"name": %s, "items": [' "$(json_str "$g")"
        for i in "${!SVC_NAME[@]}"; do
            [[ "${SVC_GROUP[$i]}" == "$g" ]] || continue
            (( gfirst )) || printf ','
            gfirst=0
            printf '\n      {"name": %s, "url": %s, "alt": "", "desc": %s}' \
                "$(json_str "${SVC_NAME[$i]}")" "$(json_str "${SVC_URL[$i]}")" "$(json_str "${SVC_DESC[$i]}")"
        done
        printf '\n    ]}'
    done
    printf '\n  ]\n}\n'
}

# every URL the health check probes: "url<TAB>resolve-host" (resolve-host = via the local proxy)
health_targets() {
    local key title sub up flags fb desc url h i
    while IFS='|' read -r key title sub up flags fb desc; do
        url=$(endpoint_url "$sub" "$fb"); [[ -n "$url" ]] || continue
        h=$(fqdn "$sub")
        printf '%s\t%s\n' "$url" "$h"
    done < <(all_endpoints)
    for i in "${!SVC_URL[@]}"; do printf '%s\t\n' "${SVC_URL[$i]}"; done
}
render_status_json() {
    local url code secs first=1 state ms
    printf '{\n  "generated": %s,\n  "results": {' "$(json_str "$(date -Iseconds)")"
    while IFS=$'\t' read -r url code secs; do
        [[ -n "$url" ]] || continue
        [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
        if [[ "$code" == 000 ]]; then state=down; else state=up; fi
        ms=$(awk -v s="${secs:-0}" 'BEGIN { printf "%d", s * 1000 }')
        (( first )) || printf ','
        first=0
        printf '\n    %s: {"state": "%s", "code": %d, "ms": %d}' "$(json_str "$url")" "$state" "$((10#$code))" "$ms"
    done
    printf '\n  }\n}\n'
}

render_index() {
    cat <<'HTML'
<!doctype html>
<!-- Managed by docker-dashboard -- regenerated on every apply. Content comes from services.json. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Docker Host</title>
<style>
  :root {
    --bg:#f4f5f7; --card:#fff; --text:#1d2330; --muted:#5f6b7a; --border:#dfe3e8;
    --accent:#1f6feb; --ok:#2da44e; --bad:#cf222e; --unk:#9aa4b2; --code:#eef1f4; --warn:#bf8700; --track:#e6e9ee;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg:#0f1218; --card:#171b23; --text:#e6e9ef; --muted:#8b95a5; --border:#262c37;
      --accent:#58a6ff; --ok:#3fb950; --bad:#f85149; --unk:#5b6575; --code:#11151c; --warn:#d29922; --track:#262c37;
    }
  }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }
  .wrap { max-width:1040px; margin:0 auto; padding:0 16px; }
  header { padding:28px 0 4px; display:flex; flex-wrap:wrap; gap:12px; align-items:flex-end; justify-content:space-between; }
  h1 { margin:0; font-size:22px; }
  .sub { color:var(--muted); font-size:13px; }
  input[type=search] { background:var(--card); color:var(--text); border:1px solid var(--border);
         border-radius:8px; padding:7px 10px; font:inherit; width:220px; max-width:100%; }
  h2 { font-size:12px; text-transform:uppercase; letter-spacing:.07em; color:var(--muted); margin:26px 0 10px; }
  .grid { display:grid; gap:12px; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); }
  a.card { display:block; text-decoration:none; color:inherit; background:var(--card);
           border:1px solid var(--border); border-radius:10px; padding:13px 15px;
           transition:border-color .15s, transform .15s; }
  a.card:hover, a.card:focus-visible { border-color:var(--accent); transform:translateY(-1px); outline:none; }
  .name { font-weight:600; display:flex; align-items:center; gap:8px; }
  .dot { width:9px; height:9px; border-radius:50%; background:var(--unk); flex:none; }
  .dot.up { background:var(--ok); } .dot.down { background:var(--bad); }
  .url { color:var(--muted); font-size:12px; font-family:ui-monospace,SFMono-Regular,Consolas,monospace; word-break:break-all; }
  .desc { font-size:13px; margin-top:4px; }
  table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--border); border-radius:10px; overflow:hidden; }
  td, th { text-align:left; padding:8px 12px; border-top:1px solid var(--border); font-size:13px; vertical-align:top; }
  th { border-top:0; color:var(--muted); font-weight:600; }
  code { font-family:ui-monospace,SFMono-Regular,Consolas,monospace; font-size:12px; background:var(--code);
         padding:2px 6px; border-radius:5px; word-break:break-all; }
  button { font:inherit; font-size:12px; color:var(--accent); background:none; border:1px solid var(--border);
           border-radius:6px; padding:2px 8px; cursor:pointer; margin-left:6px; }
  .empty { color:var(--muted); font-size:13px; }
  footer { color:var(--muted); font-size:12px; text-align:center; padding:28px 16px; }
  .tablewrap { overflow-x:auto; }
  .tiles { display:grid; gap:12px; grid-template-columns:repeat(auto-fill,minmax(180px,1fr)); }
  .tile { background:var(--card); border:1px solid var(--border); border-left:4px solid var(--ok); border-radius:10px; padding:11px 14px; }
  .tile.warn { border-left-color:var(--warn); } .tile.crit { border-left-color:var(--bad); }
  .t-head { display:flex; justify-content:space-between; align-items:baseline; gap:8px; font-size:12px; color:var(--muted); }
  .badge { font-size:11px; font-weight:600; letter-spacing:.04em; color:var(--ok); }
  .warn .badge { color:var(--warn); } .crit .badge { color:var(--bad); }
  .t-val { font-size:20px; font-weight:600; margin-top:2px; }
  .t-sub { font-size:12px; color:var(--muted); margin-top:2px; overflow-wrap:anywhere; }
  .bar { height:6px; background:var(--track); border-radius:3px; margin-top:8px; overflow:hidden; }
  .bar i { display:block; height:100%; background:var(--ok); }
  .warn .bar i { background:var(--warn); } .crit .bar i { background:var(--bad); }
  td a { color:var(--accent); }
  td.size { white-space:nowrap; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1 id="title">Docker Host</h1>
      <div class="sub" id="sub">Loading…</div>
    </div>
    <input type="search" id="filter" placeholder="Filter services" aria-label="Filter services">
  </header>
  <main id="main"></main>
</div>
<footer id="foot"></footer>
<script>
"use strict";
const $ = (s) => document.querySelector(s);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
let CONFIG = null;

function ago(iso) {
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 90) return s + "s ago";
  if (s < 5400) return Math.round(s / 60) + " min ago";
  return Math.round(s / 3600) + " h ago";
}

function render(cfg) {
  CONFIG = cfg;
  document.title = cfg.title;
  $("#title").textContent = cfg.title;
  $("#sub").textContent = cfg.host + (cfg.health ? " · checking status…" : "");
  const main = $("#main");
  main.replaceChildren();
  const hs = el("section"); hs.id = "host"; hs.hidden = true; main.append(hs);
  if (!cfg.groups.length) main.append(el("p", "empty", "Nothing here yet. Turn apps on in the docker-dashboard menu (3) or add links (4)."));
  for (const g of cfg.groups) {
    const sec = el("section"); sec.dataset.group = "1";
    sec.append(el("h2", null, g.name));
    const grid = el("div", "grid");
    for (const s of g.items) {
      const a = el("a", "card"); a.href = s.url; a.target = "_blank"; a.rel = "noopener";
      a.dataset.url = s.url; a.dataset.search = (s.name + " " + s.url + " " + s.desc).toLowerCase();
      const n = el("div", "name"); const d = el("span", "dot"); d.title = "status unknown";
      n.append(d, document.createTextNode(s.name));
      a.append(n, el("div", "url", s.url));
      if (s.desc) a.append(el("div", "desc", s.desc));
      if (s.alt) a.append(el("div", "url", "direct: " + s.alt));
      grid.append(a);
    }
    sec.append(grid); main.append(sec);
  }
  if (cfg.files) {
    const sec = el("section", null); sec.id = "files";
    sec.append(el("h2", null, "Files"));
    sec.append(el("p", "empty", "Loading file list…"));
    main.append(sec);
    loadFiles();
  }
  $("#foot").textContent = "docker-dashboard v" + cfg.version + " · page generated " + new Date(cfg.generated).toLocaleString();
  applyFilter();
}

function applyFilter() {
  const q = $("#filter").value.trim().toLowerCase();
  document.querySelectorAll("a.card").forEach(a => { a.style.display = !q || a.dataset.search.includes(q) ? "" : "none"; });
  document.querySelectorAll("section[data-group]").forEach(s => {
    s.style.display = [...s.querySelectorAll("a.card")].some(a => a.style.display !== "none") ? "" : "none";
  });
}

async function loadStatus() {
  if (!CONFIG || !CONFIG.health) return;
  try {
    const r = await fetch("status.json", { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    const st = await r.json();
    let up = 0, down = 0;
    document.querySelectorAll("a.card").forEach(a => {
      const res = st.results[a.dataset.url]; const d = a.querySelector(".dot");
      d.className = "dot"; d.title = "status unknown";
      if (!res) return;
      d.classList.add(res.state);
      d.title = res.state === "up" ? "up · HTTP " + res.code + " · " + res.ms + " ms" : "not responding";
      res.state === "up" ? up++ : down++;
    });
    $("#sub").textContent = CONFIG.host + " · " + up + " up, " + down + " down · checked " + ago(st.generated);
  } catch (e) {
    $("#sub").textContent = CONFIG.host + " · status not available yet";
  }
}

const WORD = { ok: "OK", warn: "HIGH", crit: "CRITICAL" };
function fmtKb(k) { return k >= 1073741824 ? (k / 1073741824).toFixed(1) + " TB" : k >= 1048576 ? (k / 1048576).toFixed(1) + " GB" : Math.round(k / 1024) + " MB"; }
function fmtUp(s) { const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60); return (d ? d + "d " : "") + h + "h " + m + "m"; }
function tile(label, level, value, sub, pct) {
  const t = el("div", "tile " + (level || "ok"));
  const head = el("div", "t-head"); head.append(el("span", null, label), el("span", "badge", WORD[level] || ""));
  t.append(head, el("div", "t-val", value));
  if (sub) t.append(el("div", "t-sub", sub));
  if (pct != null) { const b = el("div", "bar"), i = el("i"); i.style.width = Math.min(100, Math.max(0, pct)) + "%"; b.append(i); t.append(b); }
  return t;
}
async function loadHost() {
  const sec = $("#host");
  if (!sec) return;
  try {
    const r = await fetch("host.json", { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    const h = await r.json();
    const grid = el("div", "tiles");
    grid.append(tile("CPU", h.cpu.level, h.cpu.busy + "%", "load " + h.cpu.load[1] + " \u00b7 " + h.cpu.cores + " cores", h.cpu.busy));
    grid.append(tile("Memory", h.memory.level, h.memory.pct + "%", fmtKb(h.memory.usedKb) + " of " + fmtKb(h.memory.totalKb), h.memory.pct));
    if (h.swap.totalKb > 0) grid.append(tile("Swap", h.swap.level, h.swap.pct + "%", fmtKb(h.swap.usedKb) + " of " + fmtKb(h.swap.totalKb), h.swap.pct));
    for (const d of h.disks) grid.append(tile("Disk " + d.mount, d.level, d.pct + "%", fmtKb(d.usedKb) + " of " + fmtKb(d.sizeKb), d.pct));
    const ct = tile("Containers", h.containers.level, h.containers.running + " / " + h.containers.total,
                    h.containers.problems.length ? h.containers.problems.join(" \u00b7 ") : "all running or cleanly stopped", null);
    grid.append(ct);
    grid.append(tile("Uptime", "ok", fmtUp(h.uptime), h.os, null));
    const head = el("h2", null, "Host \u00b7 " + h.hostname + " \u00b7 checked " + ago(h.generated));
    sec.replaceChildren(head, grid);
    sec.hidden = false;
  } catch (e) { sec.hidden = true; }
}

function copyBtn(text) {
  const b = el("button", null, "Copy");
  b.type = "button";
  b.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(text); b.textContent = "Copied"; }
    catch (e) { b.textContent = "Select & copy"; }
    setTimeout(() => (b.textContent = "Copy"), 1500);
  });
  return b;
}

function fmtSize(n) { return n < 1024 ? n + " B" : n < 1048576 ? (n / 1024).toFixed(1) + " KB" : (n / 1048576).toFixed(1) + " MB"; }

async function loadFiles() {
  const sec = $("#files");
  try {
    const r = await fetch("files-index/", { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    const list = (await r.json()).filter(f => f.type === "file");
    sec.querySelector("p").remove();
    if (!list.length) { sec.append(el("p", "empty", "The file share is empty.")); return; }
    const host = location.hostname;
    const httpBase = "http://" + host + (CONFIG.httpPort === 80 ? "" : ":" + CONFIG.httpPort) + "/files/";
    const httpsBase = location.origin + "/files/";
    const wrap = el("div", "tablewrap"); const t = el("table");
    const hr = el("tr"); ["File", "Size", "Download on the target"].forEach(h => hr.append(el("th", null, h)));
    t.append(hr);
    for (const f of list) {
      const tr = el("tr");
      const a = el("a", null, f.name); a.href = "files/" + encodeURIComponent(f.name);
      const td1 = el("td"); td1.append(a);
      const td3 = el("td");
      const cmds = ["curl -fkLO " + httpsBase + encodeURIComponent(f.name)];
      if (CONFIG.filesHttp) cmds.push("curl -fLO " + httpBase + encodeURIComponent(f.name));
      cmds.forEach((c, i) => { const line = el("div"); if (i) line.style.marginTop = "4px"; line.append(el("code", null, c), copyBtn(c)); td3.append(line); });
      tr.append(td1, el("td", "size", fmtSize(f.size || 0)), td3);
      t.append(tr);
    }
    wrap.append(t); sec.append(wrap);
  } catch (e) {
    sec.querySelector("p").textContent = "File list not available.";
  }
}

$("#filter").addEventListener("input", applyFilter);
fetch("services.json", { cache: "no-store" })
  .then(r => { if (!r.ok) throw new Error(r.status); return r.json(); })
  .then(cfg => { render(cfg); loadStatus(); loadHost(); setInterval(() => { loadStatus(); loadHost(); }, 60000); })
  .catch(() => { $("#sub").textContent = "services.json could not be loaded -- run docker-dashboard --apply"; });
</script>
</body>
</html>
HTML
}

# systemd OnCalendar for the update timer
render_oncalendar() {   # render_oncalendar SCHEDULE DAY HH:MM
    case "$1" in
        daily)  printf '*-*-* %s:00' "$3" ;;
        weekly) printf '%s *-*-* %s:00' "$2" "$3" ;;
        *)      return 1 ;;
    esac
}


# -----------------------------------------------------------------------------
# HOST PREPARATION (after the settings are known, before anything is deployed)
# -----------------------------------------------------------------------------
readonly BASE_PACKAGES="ca-certificates curl gnupg openssl iproute2 gawk sed util-linux diffutils tar gzip openssh-client"

ensure_base_packages() {
    local -a missing=() p
    for p in $BASE_PACKAGES; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if (( ${#missing[@]} )); then
        log_info "Installing base packages: ${missing[*]}"
        run_logged apt-get update
        run_logged apt-get install -y "${missing[@]}"
    fi
    log_ok "Base packages present"
}

resolved_stub_active() { ss -Hlnp "sport = :53" 2>/dev/null | grep -q '"systemd-resolve"'; }
resolved_dropin() { printf '%s/docker-dashboard-no-stub.conf' "$DD_RESOLVED_DIR"; }
host_dns_ok() { getent hosts download.docker.com >/dev/null 2>&1 || getent hosts github.com >/dev/null 2>&1; }

# free_resolved_stub -- Pi-hole needs :53. Turn off only resolved's stub listener; the host keeps
# resolving through the upstream servers resolved already uses. Rolled back if host DNS breaks.
free_resolved_stub() {
    log_info "systemd-resolved's stub listener (127.0.0.53) holds port 53, which Pi-hole needs."
    log_info "Fix: switch off only the stub listener and point $DD_RESOLV_CONF at resolved's upstream DNS list."
    confirm "Apply that now?" y || return 1
    if (( DRY_RUN )); then
        run write "$(resolved_dropin)"; run ln -sf "$DD_RESOLVED_UPSTREAM" "$DD_RESOLV_CONF"; run systemctl restart systemd-resolved
        return 0
    fi
    local orig=""
    [[ -L "$DD_RESOLV_CONF" ]] && orig=$(readlink "$DD_RESOLV_CONF")
    mkdir -p "$DD_STATE_DIR"
    if [[ ! -f "$DD_STATE_DIR/resolv.conf.orig" ]]; then
        if [[ -n "$orig" ]]; then printf 'link %s\n' "$orig" >"$DD_STATE_DIR/resolv.conf.orig"
        else { printf 'file\n'; cat "$DD_RESOLV_CONF" 2>/dev/null; } >"$DD_STATE_DIR/resolv.conf.orig"; fi
    fi
    mkdir -p "$DD_RESOLVED_DIR"
    printf '# Managed by %s: Pi-hole serves DNS on port 53\n[Resolve]\nDNSStubListener=no\n' "$SCRIPT_NAME" \
        | write_file "$(resolved_dropin)" 644 root:root
    # only repoint resolv.conf when it is the stub (127.0.0.53); a hand-written one is left alone
    if [[ "$orig" == *stub-resolv.conf ]] || grep -q '^nameserver 127\.0\.0\.53' "$DD_RESOLV_CONF" 2>/dev/null; then
        if [[ -s "$DD_RESOLVED_UPSTREAM" ]]; then ln -sf "$DD_RESOLVED_UPSTREAM" "$DD_RESOLV_CONF"
        else log_warn "$DD_RESOLVED_UPSTREAM is missing; $DD_RESOLV_CONF left as it was."; fi
    fi
    systemctl restart systemd-resolved
    sleep 2
    if ! host_dns_ok; then
        log_error "Host DNS stopped working after the change -- rolling back."
        restore_resolved_stub quiet
        die "systemd-resolved has no upstream DNS of its own. Give the host a DNS server (other than this Pi-hole) in its network config, then run this again."
    fi
    resolved_stub_active && die "systemd-resolved still holds port 53 (check $DD_RESOLVED_DIR)."
    log_ok "Port 53 freed; host DNS still works (nameservers: $(awk '/^nameserver/ {printf "%s ", $2}' "$DD_RESOLV_CONF" 2>/dev/null))"
}

restore_resolved_stub() {   # undo free_resolved_stub (uninstall, or rollback)
    [[ -f "$(resolved_dropin)" ]] || return 0
    [[ "${1:-}" == quiet ]] || confirm "Turn systemd-resolved's stub listener back on (Pi-hole no longer needs port 53)?" y || return 0
    run rm -f "$(resolved_dropin)"
    local how=""
    [[ -f "$DD_STATE_DIR/resolv.conf.orig" ]] && how=$(head -n1 "$DD_STATE_DIR/resolv.conf.orig")
    case "$how" in
        link\ *) run ln -sf "${how#link }" "$DD_RESOLV_CONF" ;;
        file)    (( DRY_RUN )) || tail -n +2 "$DD_STATE_DIR/resolv.conf.orig" >"$DD_RESOLV_CONF" ;;
    esac
    run rm -f "$DD_STATE_DIR/resolv.conf.orig"
    run systemctl restart systemd-resolved
    log_ok "systemd-resolved stub listener restored"
}

# host_checks -- things that would bite later; warnings only
host_checks() {
    local parent avail_g need_g=10 mem_g code
    parent=$STACKS_DIR; while [[ ! -d "$parent" ]]; do parent=$(dirname "$parent"); done
    app_on gvm && need_g=30
    avail_g=$(df -Pk "$parent" | awk 'NR==2 {print int($4/1024/1024)}')
    if (( avail_g < need_g )); then log_warn "Only ${avail_g} GiB free under $parent (want ${need_g}+ for images and data)."
    else log_ok "Disk: ${avail_g} GiB free under $parent"; fi
    mem_g=$(awk '/^MemTotal:/ {print int($2/1024/1024 + 0.5)}' /proc/meminfo)
    if app_on gvm && (( mem_g < 8 )); then log_warn "Greenbone wants 8 GB RAM; this host has ${mem_g} GB."
    else log_ok "Memory: ${mem_g} GB"; fi
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then log_ok "Clock is NTP-synchronised"
    else log_warn "Clock is not NTP-synchronised (certificate checks and Prometheus need correct time): timedatectl set-ntp true"; fi
    if [[ -n "$DET_IFACE" ]] && ip -4 -o addr show dev "$DET_IFACE" 2>/dev/null | grep -q ' dynamic '; then
        app_on pihole && log_warn "$DET_IP on $DET_IFACE is a DHCP lease. A DNS server should have a static IP or a DHCP reservation."
    fi
    if [[ "${CFG[HOST_ADDR]}" != auto && "${CFG[HOST_ADDR]}" != "$DET_IP" ]]; then
        log_info "Names will point at ${CFG[HOST_ADDR]}; this host is $DET_IP right now (fine when it moves there at cutover)."
    fi
    if host_dns_ok; then log_ok "Host DNS resolves"; else log_warn "This host cannot resolve names; image pulls will fail."; fi
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null || true)
    if [[ "$code" == 401 || "$code" == 200 ]]; then log_ok "Docker Hub reachable"
    else log_warn "Docker Hub not reachable (HTTP ${code:-000}); image pulls will fail."; fi
    return 0
}

host_prepare() {
    log_step "Host preparation"
    detect_network
    ensure_base_packages
    host_checks
}

# -----------------------------------------------------------------------------
# PORTS
# -----------------------------------------------------------------------------
is_own_project() {
    [[ "$1" == "$PROJECT_NAME" || "$1" == "$APP_PREFIX"* ]] && return 0
    # list captured first: `producer | grep -q` fails under pipefail when grep exits early (SIGPIPE)
    [[ -n "$STACKS_DIR" && -n "$1" ]] || return 1
    local l; l=$(custom_managed_projects)
    [[ $'\n'"$l"$'\n' == *$'\n'"$1"$'\n'* ]]
}

# docker_ps_port_users PORT PROTO  (stdin: "name<TAB>ports<TAB>project") -> foreign container names
docker_ps_port_users() {
    awk -F'\t' -v p="$1" -v proto="${2:-tcp}" -v pre="$APP_PREFIX" -v self="$PROJECT_NAME" '
        $3 == self || index($3, pre) == 1 { next }
        { n = split($2, a, /, /); for (i = 1; i <= n; i++) if (a[i] ~ (":" p "->") && a[i] ~ ("/" proto "$")) { print $1; break } }'
}

# check_port PORT PROTO LABEL -- die with guidance if something else holds it
check_port() {
    local port=$1 proto=$2 label=$3 users procs c img proj files dir sockflag=t
    [[ "$proto" == udp ]] && sockflag=u
    users=$( { docker ps --format '{{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}' 2>/dev/null || true; } \
             | docker_ps_port_users "$port" "$proto" | sort -u | xargs)
    procs=$(ss -Hl${sockflag}np "sport = :$port" 2>/dev/null | grep -v '"docker-proxy"' | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | xargs || true)
    [[ -z "$users" && -z "$procs" ]] && { log_ok "Port $port/$proto ($label) is free"; return 0; }
    log_error "Port $port/$proto ($label) is in use by: ${users:+container(s) $users }${procs:+process(es) $procs}"
    for c in $users; do
        img=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true)
        proj=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null || true)
        files=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$c" 2>/dev/null || true)
        dir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null || true)
        if [[ -n "$proj" ]]; then
            log_info "  '$c' is compose-managed: edit ${files//,/ } (in $dir) and change \"$port:...\" to a free host port."
        else
            log_info "  '$c' was started with docker run: re-create it with a different -p host port."
        fi
        [[ "${img,,}" == *pihole* ]] && log_info "  If this is the Pi-hole you are replacing, stop it first: docker stop $c"
    done
    if [[ " $procs " == *" systemd-resolve "* ]]; then
        log_info "  systemd-resolved's stub listener holds :53. Answer yes when asked, or free it by hand:"
        log_info "    mkdir -p /etc/systemd/resolved.conf.d && printf '[Resolve]\\nDNSStubListener=no\\n' > /etc/systemd/resolved.conf.d/no-stub.conf"
        log_info "    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf && systemctl restart systemd-resolved"
    fi
    return 1
}

PORTS_CHECKED=0
check_ports() {
    (( PORTS_CHECKED )) && return 0
    log_step "Port check"
    local rc=0 a pp label
    if app_on pihole && [[ "${CFG[PIHOLE_DNS_PORT]}" == 53 ]] && resolved_stub_active; then
        free_resolved_stub || true
    fi
    [[ "${CFG[HTTP_PORT]}" != "${CFG[HTTPS_PORT]}" ]] || die "HTTP and HTTPS ports must differ."
    local -A seen=()
    while IFS=$'\t' read -r pp label; do
        [[ -n "$pp" ]] || continue
        if [[ -n "${seen[$pp]:-}" ]]; then log_error "Port $pp is assigned twice (${seen[$pp]} and $label)"; rc=1; continue; fi
        seen[$pp]=$label
        check_port "${pp%/*}" "${pp#*/}" "$label" || rc=1
    done < <(
        printf '%s/tcp\tdashboard HTTP\n%s/tcp\tdashboard HTTPS\n' "${CFG[HTTP_PORT]}" "${CFG[HTTPS_PORT]}"
        for a in $(enabled_apps); do app_host_ports "$a"; done
        custom_host_ports
    )
    (( rc == 0 )) || die "Free the port(s) above, or change them in Settings / Apps, then run this again."
    PORTS_CHECKED=1
}

# -----------------------------------------------------------------------------
# CERTIFICATE (selfsigned | custom files | fetch over scp, e.g. from OPNsense acme.sh)
# -----------------------------------------------------------------------------
cert_sans() {   # cert_sans HOST EXTRA_NAMES -> subjectAltName value
    local -a out=(); local n h=$1
    local -A seen=()
    local -a names=( "$h" )
    [[ -n "${CFG[DOMAIN]:-}" ]] && names+=( "*.${CFG[DOMAIN]}" "${CFG[DOMAIN]}" )
    local -a more=()
    read -ra more <<<"$(hostname -s 2>/dev/null) $(hostname -f 2>/dev/null) ${2//,/ }"
    names+=( ${more[@]+"${more[@]}"} )
    for n in "${names[@]}"; do
        [[ -n "$n" && -z "${seen[$n]:-}" ]] || continue
        seen[$n]=1
        if valid_ipv4 "$n"; then out+=("IP:$n"); elif valid_hostname "${n#\*.}"; then out+=("DNS:$n"); fi
    done
    local IFS=,; printf '%s' "${out[*]}"
}

cert_names_needed() {   # hostnames the certificate should cover
    local key title sub _r
    dash_host; echo
    while IFS='|' read -r key title sub _r; do fqdn "$sub"; echo; done < <(all_endpoints)
}

# cert_check CRT KEY -> 0 ok; prints problems
cert_check() {
    local crt=$1 key=$2 a b n bad=0
    a=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | sha256sum)
    b=$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256sum)
    [[ -n "$a" && "$a" == "$b" ]] || { log_error "Certificate and key do not match ($crt / $key)."; return 1; }
    openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1 || { log_error "Certificate has expired."; return 1; }
    openssl x509 -in "$crt" -noout -checkend 1209600 >/dev/null 2>&1 || log_warn "Certificate expires within 14 days."
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        openssl x509 -in "$crt" -noout -checkhost "$n" 2>/dev/null | grep -q 'does match' || { log_warn "Certificate does not cover $n"; bad=1; }
    done < <(cert_names_needed)
    (( bad )) && log_warn "Browsers will warn for the names above."
    return 0
}

cert_fetch() {   # scp the cert pair from CERT_FETCH_SOURCE into $DD_CONF_DIR/certs-fetched
    local src=${CFG[CERT_FETCH_SOURCE]%/} dst="$DD_CONF_DIR/certs-fetched" t
    [[ -n "$src" ]] || die "CERT_FETCH_SOURCE is not set (Settings -> Certificate)."
    [[ -f "$FETCH_KEY" ]] || die "No fetch key yet: run Certificate menu -> create fetch key (or --cert-fetch-key)."
    (( DRY_RUN )) && { run scp "$src/${CFG[CERT_FETCH_CERT]}" "$src/${CFG[CERT_FETCH_KEY]}" "$dst/"; return 0; }
    t=$(mktemp -d)
    if ! scp -q -i "$FETCH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$FETCH_KNOWN_HOSTS" "$src/${CFG[CERT_FETCH_CERT]}" "$src/${CFG[CERT_FETCH_KEY]}" "$t/" 2>"$t/err"; then
        log_error "Fetching the certificate from $src failed: $(tr '\n' ' ' <"$t/err")"
        rm -rf "$t"; return 1
    fi
    mkdir -p "$dst"; chmod 700 "$dst"
    install -m 644 "$t/${CFG[CERT_FETCH_CERT]}" "$dst/fullchain.pem"
    install -m 600 "$t/${CFG[CERT_FETCH_KEY]}" "$dst/privkey.pem"
    rm -rf "$t"
    log_ok "Certificate fetched from $src"
}

cert_fetch_key() {
    if [[ ! -f "$FETCH_KEY" ]]; then
        mkdir -p "$DD_CONF_DIR"
        run ssh-keygen -q -t ed25519 -N "" -C "docker-dashboard@$(hostname -s)" -f "$FETCH_KEY"
        log_ok "Created $FETCH_KEY"
    fi
    log_info "Public key -- add it to the account named in CERT_FETCH_SOURCE (OPNsense: System -> Access -> Users -> Authorized keys):"
    printf '\n    %s\n\n' "$(cat "$FETCH_KEY.pub" 2>/dev/null)"
}

ensure_cert() {
    log_step "TLS certificate (${CFG[CERT_MODE]})"
    local dir="$DEPLOY_DIR/certs" crt key src_c src_k
    crt="$dir/dashboard.crt"; key="$dir/dashboard.key"
    case "${CFG[CERT_MODE]}" in
        custom|fetch)
            if [[ "${CFG[CERT_MODE]}" == fetch ]]; then
                if ! cert_fetch; then
                    CERT_FETCH_FAILED=1
                    [[ -s "$DD_CONF_DIR/certs-fetched/fullchain.pem" ]] || die "No certificate available yet."
                    log_warn "Using the last fetched certificate."
                fi
                src_c="$DD_CONF_DIR/certs-fetched/fullchain.pem"; src_k="$DD_CONF_DIR/certs-fetched/privkey.pem"
            else
                src_c=${CFG[CERT_FILE]}; src_k=${CFG[CERT_KEY_FILE]}
            fi
            (( DRY_RUN )) && [[ ! -r "$src_c" ]] && { run install "$src_c" "$crt"; return 0; }
            [[ -r "$src_c" && -r "$src_k" ]] || die "Certificate/key not readable: $src_c / $src_k"
            cert_check "$src_c" "$src_k" || die "Refusing to deploy this certificate."
            write_file "$crt" 644 root:root <"$src_c"
            write_file "$key" 600 root:root <"$src_k"
            log_ok "Using $(openssl x509 -in "$src_c" -noout -subject 2>/dev/null | sed 's/^subject=//'), $(openssl x509 -in "$src_c" -noout -enddate 2>/dev/null | sed 's/notAfter=/expires /')"
            return 0 ;;
    esac
    local sans reason=""
    sans=$(cert_sans "$(eff_host)" "${CFG[EXTRA_NAMES]}")
    if [[ ! -s "$crt" || ! -s "$key" ]]; then reason="none present"
    elif [[ "$(state_get cert_sans)" != "$sans" ]]; then reason="names changed"
    elif ! openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null 2>&1; then reason="expires within 30 days"
    fi
    if [[ -z "$reason" ]]; then
        log_ok "Self-signed cert current ($(openssl x509 -in "$crt" -noout -enddate | sed 's/notAfter=/expires /'))"
        return 0
    fi
    log_info "Generating self-signed cert ($reason): $sans, ${CFG[CERT_DAYS]} days"
    if (( DRY_RUN )); then run openssl req -x509 ...; return 0; fi
    local t; t=$(mktemp -d)
    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days "${CFG[CERT_DAYS]}" \
        -subj "/CN=$(dash_host || true)" -addext "subjectAltName=$sans" \
        -addext "basicConstraints=critical,CA:FALSE" -addext "extendedKeyUsage=serverAuth" \
        -keyout "$t/k" -out "$t/c" >/dev/null 2>&1 \
        || openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days "${CFG[CERT_DAYS]}" -subj "/CN=$(eff_host)" \
              -addext "subjectAltName=$sans" -keyout "$t/k" -out "$t/c" >/dev/null 2>&1 \
        || { rm -rf "$t"; die "openssl failed to create the certificate."; }
    mkdir -p "$dir"
    write_file "$crt" 644 root:root <"$t/c"
    write_file "$key" 600 root:root <"$t/k"
    rm -rf "$t"
    state_set cert_sans "$sans"
    log_ok "Certificate written: $crt"
}

# cert_refresh -- timer/path-unit entry point: fetch or re-read, deploy only if it changed
cert_refresh() {
    require_config
    [[ "${CFG[CERT_MODE]}" == selfsigned ]] && { ensure_cert; dashboard_reload; return 0; }
    local before after
    before=$(sha256sum "$DEPLOY_DIR/certs/dashboard.crt" 2>/dev/null | cut -c1-16)
    ensure_cert
    after=$(sha256sum "$DEPLOY_DIR/certs/dashboard.crt" 2>/dev/null | cut -c1-16)
    if [[ "$before" != "$after" ]]; then dashboard_reload; log_ok "New certificate is live"
    else log_info "Certificate unchanged"; fi
    (( CERT_FETCH_FAILED == 0 ))   # non-zero for the timer's journal when the fetch itself failed
}

dashboard_reload() {
    (( DRY_RUN )) && { run docker exec "$CONTAINER_NAME" nginx -s reload; return 0; }
    docker ps -q --filter "name=^${CONTAINER_NAME}$" | grep -q . || return 0
    if docker exec "$CONTAINER_NAME" nginx -t >/dev/null 2>&1 && docker exec "$CONTAINER_NAME" nginx -s reload >/dev/null 2>&1; then
        log_ok "nginx reloaded"
    else
        log_warn "nginx reload failed: docker exec $CONTAINER_NAME nginx -t"
    fi
    state_set cert_applied "$(sha256sum "$DEPLOY_DIR/certs/dashboard.crt" 2>/dev/null | cut -c1-16)"
}

# -----------------------------------------------------------------------------
# DEPLOY
# -----------------------------------------------------------------------------
write_services_json() {   # only replace it when something other than the timestamp changed
    local f="$DEPLOY_DIR/html/services.json" new
    new=$(render_services_json)
    if [[ -f "$f" ]] && cmp -s <(grep -v '"generated":' "$f") <(grep -v '"generated":' <<<"$new"); then return 0; fi
    write_file "$f" 644 root:root <<<"$new"
}

compose_dd() { ( cd "$DEPLOY_DIR" && docker compose -p "$PROJECT_NAME" "$@" ); }

publish_services() {   # services.json only (fast path for link edits)
    [[ -d "$DEPLOY_DIR/html" ]] || return 0
    load_services
    write_services_json
    log_ok "Published the page ($(all_endpoints | wc -l) app link(s), ${#SVC_NAME[@]} custom)"
    [[ "${CFG[HEALTH_CHECK]}" == yes ]] && health_check quiet
    return 0
}

nginx_test() {
    (( DRY_RUN )) && { run docker run --rm "${CFG[NGINX_IMAGE]}" nginx -t; return 0; }
    local -a vols=( -v "$DEPLOY_DIR/nginx:/etc/nginx/conf.d:ro" -v "$DEPLOY_DIR/certs:/etc/nginx/certs:ro" )
    [[ -n "${CFG[FILES_DIR]}" ]] && vols+=( -v "${CFG[FILES_DIR]%/}:$FILES_MOUNT:ro" )
    local out
    if ! out=$(docker run --rm --network "$PROXY_NET" "${vols[@]}" "${CFG[NGINX_IMAGE]}" nginx -t 2>&1); then
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        return 1
    fi
    _log_file INFO "nginx -t: $(tr '\n' ' ' <<<"$out")"
}

ensure_image() {   # pull only when the image is not present locally
    docker image inspect "$1" >/dev/null 2>&1 || run_logged docker pull "$1"
}

app_up() {   # app_up APP [pull]
    local app=$1 mode=${2:-nopull}
    log_step "${APP_TITLE[$app]}"
    app_prepare "$app"
    write_app_compose "$app"
    if (( DRY_RUN )); then
        run compose_app "$app" config --quiet
        [[ "$mode" == pull ]] && run compose_app "$app" pull
        [[ "$app" == guacamole ]] && guac_db_prepare
        run compose_app "$app" up -d --remove-orphans
        return 0
    fi
    compose_app "$app" config --quiet || die "docker compose config failed for $(app_dir "$app")"
    if [[ "$mode" == pull ]]; then run_logged compose_app "$app" pull --ignore-pull-failures || true; fi
    [[ "$app" == guacamole ]] && guac_db_prepare
    run_logged compose_app "$app" up -d --remove-orphans
    log_ok "${APP_TITLE[$app]} is up"
}

app_down() {   # app_down APP [REASON] -- stop and remove containers; data kept
    local app=$1 why=${2:-"disabled; data kept in $(app_dir "$1")"}
    [[ -f "$(app_dir "$app")/compose.yaml" ]] || return 0
    docker ps -aq --filter "label=com.docker.compose.project=$(app_project "$app")" | grep -q . || return 0
    log_info "Stopping ${APP_TITLE[$app]} ($why)"
    run_logged compose_app "$app" down --remove-orphans || true
}

dashboard_up() {
    log_step "Dashboard ($DEPLOY_DIR)"
    run mkdir -p "$DEPLOY_DIR/html" "$DEPLOY_DIR/nginx" "$DEPLOY_DIR/certs"
    local conf_changed=0 running=0
    docker ps -q --filter "name=^${CONTAINER_NAME}$" 2>/dev/null | grep -q . && running=1
    WROTE=0; write_file "$DEPLOY_DIR/docker-compose.yml" 644 root:root < <(render_compose); local compose_changed=$WROTE
    WROTE=0; write_file "$DEPLOY_DIR/nginx/default.conf" 644 root:root < <(render_nginx); conf_changed=$WROTE
    write_file "$DEPLOY_DIR/html/index.html" 644 root:root < <(render_index)
    write_services_json
    log_ok "Compose, nginx config, page and links written"
    if (( DRY_RUN )); then run compose_dd config --quiet; run compose_dd up -d; return 0; fi
    compose_dd config --quiet || die "docker compose config failed for $DEPLOY_DIR/docker-compose.yml"
    ensure_image "${CFG[NGINX_IMAGE]}"
    nginx_test || die "nginx -t failed; the running dashboard was left as it was."
    log_ok "nginx configuration valid"
    run_logged compose_dd up -d
    # a recreated container already has everything; a running one needs a reload for new config/cert
    if (( running && ! compose_changed )) && \
       { (( conf_changed )) || [[ "$(state_get cert_applied)" != "$(sha256sum "$DEPLOY_DIR/certs/dashboard.crt" | cut -c1-16)" ]]; }; then
        dashboard_reload
    fi
    state_set cert_applied "$(sha256sum "$DEPLOY_DIR/certs/dashboard.crt" | cut -c1-16)"
}

stack_apply() {   # stack_apply [pull] -- converge everything: apps, proxy, page, timers
    local mode=${1:-nopull} a
    require_config
    detect_network
    (( DRY_RUN )) || docker_up || die "Docker is not running/installed. Run the full install first."
    load_services
    load_secrets
    ensure_app_secrets
    if [[ -n "${CFG[FILES_DIR]}" && ! -d "${CFG[FILES_DIR]}" ]]; then
        log_warn "File share folder ${CFG[FILES_DIR]} does not exist; creating it."
        run mkdir -p "${CFG[FILES_DIR]}"
    fi
    check_ports
    ensure_proxy_net
    ensure_cert
    for a in "${APPS[@]}"; do app_on "$a" || app_down "$a"; done
    write_pihole_dns
    for a in $(enabled_apps); do app_up "$a" "$mode"; done
    for a in $(custom_names); do custom_on "$a" || custom_down "$a"; done
    for a in $(enabled_customs); do ( custom_up "$a" "$mode" ) || log_error "Custom app '$a' was not started (see above)."; done
    dashboard_up
    (( DRY_RUN )) && return 0
    state_set deployed "$(date -Iseconds)"
    ensure_units
    [[ "${CFG[HEALTH_CHECK]}" == yes ]] && health_check quiet
    log_ok "Dashboard: $(dashboard_url)"
    return 0
}

stack_stop() {   # stop_all: dashboard + apps (data kept)
    require_config; load_secrets
    log_step "Stopping dashboard and apps (containers removed; data kept)"
    local a
    for a in "${APPS[@]}"; do app_down "$a" "stop; data kept"; done
    [[ -f "$DEPLOY_DIR/docker-compose.yml" ]] && run_logged compose_dd down
    log_ok "Stopped"
}

# -----------------------------------------------------------------------------
# HEALTH CHECKS (host-side, so http:// services are checked even from the https page)
# -----------------------------------------------------------------------------
# probe_url URL [VIA_PROXY_HOST] -> "code<TAB>seconds"; own names are sent to the local proxy
probe_url() {
    local out port
    local -a extra=()
    if [[ -n "${2:-}" ]]; then
        port=${CFG[HTTPS_PORT]:-443}
        extra=( --resolve "$2:$port:127.0.0.1" )
    fi
    out=$(curl -sk --noproxy '*' "${extra[@]}" -o /dev/null -m 6 --connect-timeout 3 -w '%{http_code}\t%{time_total}' "$1" 2>/dev/null || true)
    [[ "$out" =~ ^[0-9]{3}$'\t'[0-9.]+$ ]] || out=$'000\t0'
    # 502/503/504 from our own proxy means the app behind it is down
    [[ -n "${2:-}" && "$out" =~ ^50[234] ]] && out=$'000\t0'
    printf '%s' "$out"
}

health_check() {   # health_check [quiet]
    ensure_config
    detect_network
    load_services
    local quiet=${1:-} t i url via n
    local -a urls=() vias=()
    # custom apps recreated outside this script lose their proxy network: re-attach before probing
    if (( ! DRY_RUN )) && docker_up; then for n in $(enabled_customs); do custom_attach "$n"; done; fi
    while IFS=$'\t' read -r url via; do
        [[ -n "$url" ]] || continue
        in_list "$url" ${urls[@]+"${urls[@]}"} && continue
        urls+=("$url"); vias+=("$via")
    done < <(health_targets)
    (( ${#urls[@]} )) || { [[ -n "$quiet" ]] || log_info "No links to check."; host_health "$quiet"; return 0; }
    t=$(mktemp -d)
    for i in "${!urls[@]}"; do
        ( printf '%s\t%s\n' "${urls[$i]}" "$(probe_url "${urls[$i]}" "${vias[$i]}")" >"$t/$i" ) &
    done
    wait
    local results; results=$(cat "$t"/* 2>/dev/null)
    rm -rf "$t"
    if [[ -z "$quiet" ]]; then
        log_step "Service health"
        local code secs
        while IFS=$'\t' read -r url code secs; do
            if [[ "$code" != 000 ]]; then log_ok "$(printf '%-48s HTTP %s  %4d ms' "$url" "$code" "$(awk -v s="$secs" 'BEGIN{printf "%d", s*1000}')")"
            else log_warn "$(printf '%-48s not responding' "$url")"; fi
        done <<<"$results"
    fi
    if [[ -d "$DEPLOY_DIR/html" ]] && (( ! DRY_RUN )); then
        render_status_json <<<"$results" | write_file "$DEPLOY_DIR/html/status.json" 644 root:root
    fi
    host_health "$quiet"
    return 0
}

host_health() {   # host_health [quiet] -- page panel + (optionally) terminal report
    [[ "${CFG[HOST_PANEL]}" == yes ]] || { [[ -n "${1:-}" ]] || { host_collect; host_report; }; return 0; }
    host_collect
    [[ -n "${1:-}" ]] || host_report
    if [[ -d "$DEPLOY_DIR/html" ]] && (( ! DRY_RUN )); then
        render_host_json | write_file "$DEPLOY_DIR/html/host.json" 644 root:root
    fi
    return 0
}
# -----------------------------------------------------------------------------
# HOST HEALTH (CPU, memory, swap, disks, uptime, containers)
# One collector feeds both html/host.json (the page's Host panel) and the terminal report.
# Run by the health timer, so the page needs no agent or extra container.
# -----------------------------------------------------------------------------
level_for() {   # level_for VALUE WARN CRIT -> ok|warn|crit (decimals allowed)
    awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN { print (v + 0 >= c + 0) ? "crit" : (v + 0 >= w + 0) ? "warn" : "ok" }'
}
level_worst() { case " $* " in *" crit "*) echo crit ;; *" warn "*) echo warn ;; *) echo ok ;; esac; }

# /proc/stat "cpu" line -> "total idle" (idle includes iowait)
cpu_sample() { awk '/^cpu / { t = 0; for (i = 2; i <= 9; i++) t += $i; print t, $5 + $6 }' "${1:-/proc/stat}"; }
cpu_pct() {   # cpu_pct "total idle" "total idle" -> busy %
    awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, " "); split(b, y, " "); dt = y[1] - x[1]; di = y[2] - x[2]
                                     printf "%.0f", (dt > 0) ? 100 * (dt - di) / dt : 0 }'
}

# host_disks -> "mount<TAB>fstype<TAB>size_kb<TAB>used_kb<TAB>pct" for real filesystems, one per device
host_disks() {
    df -P -T -k -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs -x ramfs -x nsfs -x fuse.lxcfs 2>/dev/null \
        | awk 'NR > 1 && $1 !~ /^(none|udev|shm|overlay)$/ && $7 !~ /^\/(run|snap|var\/lib\/docker|proc|sys|dev)(\/|$)/ && !seen[$1]++ {
                 gsub("%", "", $6); printf "%s\t%s\t%s\t%s\t%s\n", $7, $2, $3, $4, $6 }'
}

H_CORES=1 H_CPU=0 H_LOAD1=0 H_LOAD5=0 H_LOAD15=0 H_LOADPC=0 H_CPU_LVL=ok
H_MEM_T=0 H_MEM_U=0 H_MEM_P=0 H_MEM_LVL=ok H_SW_T=0 H_SW_U=0 H_SW_P=0 H_SW_LVL=ok
H_UP=0 H_RUN=0 H_TOT=0 H_CT_LVL=ok H_DISKS="" H_DISK_LVL=ok
H_PROBLEMS=()

host_collect() {
    local a b mt ma st sf m fs size used pct
    read -r H_LOAD1 H_LOAD5 H_LOAD15 _ </proc/loadavg
    H_CORES=$(nproc 2>/dev/null || echo 1)
    a=$(cpu_sample); sleep 1; b=$(cpu_sample)
    H_CPU=$(cpu_pct "$a" "$b")
    H_LOADPC=$(awk -v l="$H_LOAD5" -v c="$H_CORES" 'BEGIN { printf "%.2f", l / c }')
    H_CPU_LVL=$(level_worst "$(level_for "$H_LOADPC" "${CFG[HOST_LOAD_WARN]}" "${CFG[HOST_LOAD_CRIT]}")" \
                            "$( [[ "$(level_for "$H_CPU" 95 999)" == crit ]] && echo warn)")
    mt=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo); ma=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    st=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo); sf=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)
    H_MEM_T=${mt:-0}; H_MEM_U=$(( ${mt:-0} - ${ma:-0} ))
    H_MEM_P=$(awk -v t="$H_MEM_T" -v u="$H_MEM_U" 'BEGIN { printf "%.0f", (t > 0) ? 100 * u / t : 0 }')
    H_MEM_LVL=$(level_for "$H_MEM_P" "${CFG[HOST_MEM_WARN]}" "${CFG[HOST_MEM_CRIT]}")
    H_SW_T=${st:-0}; H_SW_U=$(( ${st:-0} - ${sf:-0} ))
    H_SW_P=$(awk -v t="$H_SW_T" -v u="$H_SW_U" 'BEGIN { printf "%.0f", (t > 0) ? 100 * u / t : 0 }')
    H_SW_LVL=$(level_for "$H_SW_P" 50 80)
    H_UP=$(awk '{printf "%d", $1}' /proc/uptime)
    H_DISKS=$(host_disks)
    local -a lv=()
    while IFS=$'\t' read -r m fs size used pct; do
        [[ -n "$m" ]] && lv+=("$(level_for "$pct" "${CFG[HOST_DISK_WARN]}" "${CFG[HOST_DISK_CRIT]}")")
    done <<<"$H_DISKS"
    H_DISK_LVL=$(level_worst ${lv[@]+"${lv[@]}"})
    local name state status
    H_RUN=0 H_TOT=0 H_PROBLEMS=()
    while IFS=$'\t' read -r name state status; do
        [[ -n "$name" ]] || continue
        H_TOT=$((H_TOT + 1))
        [[ "$state" == running ]] && H_RUN=$((H_RUN + 1))
        if [[ "$status" == *"(unhealthy)"* ]]; then H_PROBLEMS+=("$name: unhealthy")
        elif [[ "$state" == restarting ]]; then H_PROBLEMS+=("$name: restarting")
        elif [[ "$state" == exited && "$status" != "Exited (0)"* ]]; then H_PROBLEMS+=("$name: ${status%% ago*} ago")
        fi
    done < <(docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' 2>/dev/null)
    (( ${#H_PROBLEMS[@]} )) && H_CT_LVL=warn || H_CT_LVL=ok
    return 0
}

render_host_json() {   # from H_* (host_collect first)
    local first=1 m fs size used pct p
    printf '{\n  "generated": %s,\n  "hostname": %s,\n  "os": %s,\n  "kernel": %s,\n  "uptime": %s,\n' \
        "$(json_str "$(date -Iseconds)")" "$(json_str "$(hostname -f 2>/dev/null || hostname)")" \
        "$(json_str "$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}")")" "$(json_str "$(uname -r)")" "$H_UP"
    printf '  "cpu": {"cores": %s, "busy": %s, "load": [%s, %s, %s], "loadPerCore": %s, "level": "%s"},\n' \
        "$H_CORES" "$H_CPU" "$H_LOAD1" "$H_LOAD5" "$H_LOAD15" "$H_LOADPC" "$H_CPU_LVL"
    printf '  "memory": {"totalKb": %s, "usedKb": %s, "pct": %s, "level": "%s"},\n' "$H_MEM_T" "$H_MEM_U" "$H_MEM_P" "$H_MEM_LVL"
    printf '  "swap": {"totalKb": %s, "usedKb": %s, "pct": %s, "level": "%s"},\n' "$H_SW_T" "$H_SW_U" "$H_SW_P" "$H_SW_LVL"
    printf '  "disks": ['
    while IFS=$'\t' read -r m fs size used pct; do
        [[ -n "$m" ]] || continue
        (( first )) || printf ','
        first=0
        printf '\n    {"mount": %s, "fs": %s, "sizeKb": %s, "usedKb": %s, "pct": %s, "level": "%s"}' \
            "$(json_str "$m")" "$(json_str "$fs")" "$size" "$used" "$pct" "$(level_for "$pct" "${CFG[HOST_DISK_WARN]}" "${CFG[HOST_DISK_CRIT]}")"
    done <<<"$H_DISKS"
    printf '\n  ],\n  "containers": {"running": %s, "total": %s, "level": "%s", "problems": [' "$H_RUN" "$H_TOT" "$H_CT_LVL"
    first=1
    for p in ${H_PROBLEMS[@]+"${H_PROBLEMS[@]}"}; do (( first )) || printf ', '; first=0; printf '%s' "$(json_str "$p")"; done
    printf ']},\n  "level": "%s"\n}\n' "$(level_worst "$H_CPU_LVL" "$H_MEM_LVL" "$H_DISK_LVL" "$H_CT_LVL")"
}

fmt_kb() { awk -v k="$1" 'BEGIN { if (k >= 1073741824) printf "%.1f TB", k/1073741824; else if (k >= 1048576) printf "%.1f GB", k/1048576; else printf "%.0f MB", k/1024 }'; }
level_word() { case "$1" in ok) printf '%sOK      %s' "$G" "$NC" ;; warn) printf '%sHIGH    %s' "$Y" "$NC" ;; *) printf '%sCRITICAL%s' "$R" "$NC" ;; esac; }

host_report() {   # terminal version (menu 9, --host); assumes host_collect ran
    local m fs size used pct
    log_step "Host health ($(hostname -s))"
    printf '  %-11s %b  %s%% busy, load %s (%s per core, %s cores)\n' CPU "$(level_word "$H_CPU_LVL")" "$H_CPU" "$H_LOAD5" "$H_LOADPC" "$H_CORES"
    printf '  %-11s %b  %s%% (%s of %s)\n' Memory "$(level_word "$H_MEM_LVL")" "$H_MEM_P" "$(fmt_kb "$H_MEM_U")" "$(fmt_kb "$H_MEM_T")"
    if (( H_SW_T > 0 )); then printf '  %-11s %b  %s%% (%s of %s)\n' Swap "$(level_word "$H_SW_LVL")" "$H_SW_P" "$(fmt_kb "$H_SW_U")" "$(fmt_kb "$H_SW_T")"
    else printf '  %-11s %s\n' Swap "none"; fi
    while IFS=$'\t' read -r m fs size used pct; do
        [[ -n "$m" ]] || continue
        printf '  %-11s %b  %s%% (%s of %s) %s\n' Disk "$(level_word "$(level_for "$pct" "${CFG[HOST_DISK_WARN]}" "${CFG[HOST_DISK_CRIT]}")")" \
            "$pct" "$(fmt_kb "$used")" "$(fmt_kb "$size")" "$m"
    done <<<"$H_DISKS"
    printf '  %-11s %s\n' Uptime "$(awk -v s="$H_UP" 'BEGIN { printf "%dd %dh %dm", s/86400, (s%86400)/3600, (s%3600)/60 }')"
    printf '  %-11s %b  %s of %s running\n' Containers "$(level_word "$H_CT_LVL")" "$H_RUN" "$H_TOT"
    local p; for p in ${H_PROBLEMS[@]+"${H_PROBLEMS[@]}"}; do printf '  %-11s           %s\n' "" "$p"; done
    return 0
}

# -----------------------------------------------------------------------------
# UPDATES
# -----------------------------------------------------------------------------
# running_containers -> name, image, imageid, project, autoremove, workdir, configfiles separated by $US
# (defined near the top: 0x1f is not IFS whitespace, so empty fields are kept by `read`).
running_containers() {
    local fmt
    fmt=$(printf "%s$US" '{{.Name}}' '{{.Config.Image}}' '{{.Image}}' '{{index .Config.Labels "com.docker.compose.project"}}' \
        '{{.HostConfig.AutoRemove}}' '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
    fmt+='{{index .Config.Labels "com.docker.compose.project.config_files"}}'
    docker ps -q | xargs -r docker inspect -f "$fmt" | sed 's#^/##; s#<no value>##g'
}

snapshot_images() { running_containers | awk -F"$US" '{print $1 "\t" $3}' | LC_ALL=C sort; }

check_updates() {
    require_config
    docker_up || die "Docker is not running."
    log_step "Check for image updates$( ((DRY_RUN)) && echo ' (dry-run: local images only, no pull)')"
    local name img id proj autorm newid n=0 avail=0
    local -A pulled=()
    printf '  %-28s %-44s %s\n' CONTAINER IMAGE STATUS
    while IFS=$US read -r name img id proj autorm _ _; do
        [[ -n "$name" ]] || continue
        n=$((n + 1))
        if [[ "$autorm" == true ]]; then printf '  %-28s %-44s %s\n' "$name" "${img:0:44}" "${D}skipped (--rm)${NC}"; continue; fi
        if is_excluded "$name" "$proj"; then printf '  %-28s %-44s %s\n' "$name" "${img:0:44}" "${D}excluded${NC}"; continue; fi
        if [[ "$img" == *@sha256:* ]]; then printf '  %-28s %-44s %s\n' "$name" "${img:0:44}" "${D}pinned by digest${NC}"; continue; fi
        if (( ! DRY_RUN )) && [[ -z "${pulled[$img]:-}" ]]; then
            if docker pull -q "$img" >/dev/null 2>&1; then pulled[$img]=ok; else pulled[$img]=fail; fi
        fi
        newid=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)
        if [[ -n "$newid" && "$newid" != "$id" ]]; then
            printf '  %-28s %-44s %s\n' "$name" "${img:0:44}" "${Y}UPDATE AVAILABLE${NC}$( [[ "${pulled[$img]:-}" == fail ]] && echo ' (newer local image)')"
            avail=$((avail + 1))
        elif [[ "${pulled[$img]:-}" == fail ]]; then
            printf '  %-28s %-44s %s\n' "$name" "${img:0:44}" "${Y}pull failed (local build or private registry?)${NC}"
        else
            printf '  %-28s %-44s %s\n' "$name" "${img:0:44}" "${G}current${NC}"
        fi
    done < <(running_containers | sort)
    echo
    log_info "$n running container(s), $avail with a newer image$( ((DRY_RUN)) && echo ' already pulled')."
    (( avail )) && log_info "Apply with menu 5 / --update-all (images are already downloaded)."
    return 0
}

update_all() {
    require_config
    (( DRY_RUN )) || docker_up || die "Docker is not running."
    log_step "Update all containers$( ((DRY_RUN)) && echo ' (dry-run)')"
    local before after name img id proj autorm dir files cmd fails=0 done_projects=" "
    local -a standalone=() fargs=()
    before=$(snapshot_images)

    # 0. Apps this script manages (secrets come from the vault) and the dashboard itself
    local a
    load_secrets
    for a in $(enabled_apps); do
        if is_excluded "$a" "$(app_project "$a")"; then log_info "App '$a': excluded"; continue; fi
        log_info "App '$a' ($(app_dir "$a"))"
        if run_logged compose_app "$a" pull --ignore-pull-failures \
           && { [[ "$a" != guacamole ]] || guac_db_prepare; } \
           && run_logged compose_app "$a" up -d --remove-orphans; then
            log_ok "App '$a' up to date"
        else
            log_error "App '$a' update failed"; fails=$((fails + 1))
        fi
    done
    for a in $(enabled_customs); do
        if is_excluded "$a" "$(custom_project "$a")"; then log_info "Custom app '$a': excluded"; continue; fi
        if ! custom_managed "$a"; then log_info "Custom app '$a': updated by its own script (add a delegate to run it from here)"; continue; fi
        log_info "Custom app '$a' ($(custom_dir "$a"))"
        if custom_buildable "$a"; then
            # --pull refreshes the base image; a local-only or private base can't be pulled, so build with what's here
            if ! run_logged custom_compose "$a" build --pull; then
                log_warn "Custom app '$a': could not pull its base image; building with the local one."
                run_logged custom_compose "$a" build || { log_error "Custom app '$a' build failed"; fails=$((fails + 1)); continue; }
            fi
        fi
        if run_logged custom_compose "$a" pull --ignore-buildable --ignore-pull-failures && run_logged custom_compose "$a" up -d --remove-orphans; then
            custom_attach "$a"; log_ok "Custom app '$a' up to date"
        else
            log_error "Custom app '$a' update failed"; fails=$((fails + 1))
        fi
    done
    if [[ -f "$DEPLOY_DIR/docker-compose.yml" ]] && ! is_excluded "$CONTAINER_NAME" "$PROJECT_NAME"; then
        if run_logged compose_dd pull --ignore-pull-failures && run_logged compose_dd up -d; then log_ok "Dashboard up to date"
        else log_error "Dashboard update failed"; fails=$((fails + 1)); fi
    fi

    local ext_projects ext_containers n
    ext_projects=$(custom_external_projects)
    ext_containers=" $(for n in $(custom_names); do custom_conf_get "$n" CONTAINER; echo; done | xargs) "

    # 1. Other compose projects -- pull + up from their own folder (or their installer)
    while IFS=$US read -r name img id proj autorm dir files; do
        [[ -n "$proj" ]] || continue
        [[ "$done_projects" == *" $proj "* ]] && continue
        done_projects+="$proj "
        is_own_project "$proj" && continue
        [[ $'\n'"$ext_projects"$'\n' == *$'\n'"$proj"$'\n'* ]] && continue   # reported in the custom-app pass
        if is_excluded "$name" "$proj"; then log_info "Project '$proj': excluded"; continue; fi
        cmd=$(delegate_for "$proj")
        if [[ -n "$cmd" ]]; then
            log_info "Project '$proj': delegated -> $cmd"
            run_logged bash -c "$cmd" || { log_error "Delegate for '$proj' failed"; fails=$((fails + 1)); }
            continue
        fi
        if [[ ! -d "$dir" ]]; then log_warn "Project '$proj': working dir '$dir' not found -- skipped"; fails=$((fails + 1)); continue; fi
        fargs=()
        local f IFS_old=$IFS; IFS=','
        for f in $files; do [[ -f "$f" ]] && fargs+=( -f "$f" ); done
        IFS=$IFS_old
        if (( ${#fargs[@]} == 0 )); then log_warn "Project '$proj': compose file(s) '$files' not found -- skipped"; fails=$((fails + 1)); continue; fi
        if ! ( cd "$dir" && docker compose -p "$proj" "${fargs[@]}" config --quiet ) >/dev/null 2>&1; then
            log_warn "Project '$proj': 'docker compose config' fails from $dir (variables/secrets supplied by an installer?)."
            log_warn "  Skipped. Add a delegate in Settings -> Updates, e.g. $proj=/path/to/installer --apply --yes"
            fails=$((fails + 1)); continue
        fi
        log_info "Project '$proj' ($dir)"
        # --ignore-pull-failures: one private/local image must not block the rest of the project
        if run_logged compose_in "$dir" -p "$proj" "${fargs[@]}" pull --ignore-buildable --ignore-pull-failures \
           && run_logged compose_in "$dir" -p "$proj" "${fargs[@]}" up -d; then
            log_ok "Project '$proj' up to date"
        else
            log_error "Project '$proj' update failed"; fails=$((fails + 1))
        fi
    done < <(running_containers | LC_ALL=C sort -t"$US" -k4,4)

    # 2. Standalone (docker run) containers -- one-shot Watchtower recreates them with their original settings
    while IFS=$US read -r name img id proj autorm _ _; do
        [[ -n "$name" && -z "$proj" ]] || continue
        [[ "$autorm" == true ]] && { log_info "${D}$name: --rm container, skipped${NC}"; continue; }
        [[ "$name" == "$WATCHTOWER_NAME" ]] && continue
        [[ "$ext_containers" == *" $name "* ]] && continue   # a custom app started by its own script
        is_excluded "$name" && { log_info "$name: excluded"; continue; }
        standalone+=("$name")
    done < <(running_containers)
    if (( ${#standalone[@]} )); then
        log_info "Standalone: ${standalone[*]}"
        if (( ! DRY_RUN )) && ! docker pull -q "${CFG[WATCHTOWER_IMAGE]}" >/dev/null 2>&1; then
            docker image inspect "${CFG[WATCHTOWER_IMAGE]}" >/dev/null 2>&1 \
                || die "Cannot pull ${CFG[WATCHTOWER_IMAGE]} and no local copy exists."
            log_warn "Could not pull ${CFG[WATCHTOWER_IMAGE]}; using the local copy."
        fi
        if run_logged docker run --rm --name "$WATCHTOWER_NAME" \
                -v /var/run/docker.sock:/var/run/docker.sock \
                "${CFG[WATCHTOWER_IMAGE]}" --run-once --cleanup "${standalone[@]}"; then
            log_ok "Standalone containers checked"
        else
            log_error "Watchtower run failed"; fails=$((fails + 1))
        fi
    else
        log_info "No standalone containers to update"
    fi

    # 3. Cleanup + report
    if [[ "${CFG[UPDATE_PRUNE]}" == yes ]]; then run_logged docker image prune -f >/dev/null || true; fi
    (( DRY_RUN )) && return 0
    after=$(snapshot_images)
    local changed; changed=$(LC_ALL=C join -t$'\t' <(printf '%s\n' "$before") <(printf '%s\n' "$after") | awk -F'\t' '$2 != $3 {print $1}' | xargs)
    local gone; gone=$(LC_ALL=C comm -23 <(cut -f1 <<<"$before") <(cut -f1 <<<"$after") | xargs)
    log_step "Update summary"
    log_info "Updated: ${changed:-none}"
    [[ -n "$gone" ]] && log_warn "No longer running after update: $gone"
    state_set last_update "$(date -Iseconds) updated=[${changed:-none}] failures=$fails"
    UPDATE_FAILS=$fails
    if (( fails )); then log_warn "$fails item(s) failed or were skipped -- see $LOG_FILE"; else log_ok "All done"; fi
    return 0
}

compose_in() { local d=$1; shift; ( cd "$d" && docker compose "$@" ); }

# -----------------------------------------------------------------------------
# SYSTEMD UNITS (health + scheduled updates) and installed copy
# -----------------------------------------------------------------------------
install_self() {
    [[ "$SCRIPT_PATH" == "$DD_INSTALL_BIN" ]] && return 0
    if [[ -f "$DD_INSTALL_BIN" ]] && cmp -s "$SCRIPT_PATH" "$DD_INSTALL_BIN"; then return 0; fi
    run install -m 0755 "$SCRIPT_PATH" "$DD_INSTALL_BIN"
    log_ok "Installed as $DD_INSTALL_BIN"
}

unit_set_path() {   # unit_set_path NAME ENABLE(yes/no) SERVICE_CONTENT PATH_CONTENT
    local name=$1 on=$2 changed=0
    if [[ "$on" == yes ]]; then
        WROTE=0; write_file "$DD_UNIT_DIR/$name.service" 644 root:root <<<"$3"; (( WROTE )) && changed=1
        WROTE=0; write_file "$DD_UNIT_DIR/$name.path" 644 root:root <<<"$4";    (( WROTE )) && changed=1
        if (( changed )); then
            run systemctl daemon-reload
            run systemctl enable "$name.path"
            run systemctl restart "$name.path"
        elif ! systemctl is-active --quiet "$name.path" 2>/dev/null; then
            run systemctl enable --now "$name.path"
        fi
        log_ok "Watcher $name enabled"
    elif [[ -f "$DD_UNIT_DIR/$name.path" ]]; then
        run systemctl disable --now "$name.path" || true
        run rm -f "$DD_UNIT_DIR/$name.service" "$DD_UNIT_DIR/$name.path"
        run systemctl daemon-reload
        log_ok "Watcher $name removed"
    fi
    return 0
}

unit_set() {   # unit_set NAME ENABLE(yes/no) SERVICE_CONTENT TIMER_CONTENT
    local name=$1 on=$2 changed=0
    if [[ "$on" == yes ]]; then
        WROTE=0; write_file "$DD_UNIT_DIR/$name.service" 644 root:root <<<"$3"; (( WROTE )) && changed=1
        WROTE=0; write_file "$DD_UNIT_DIR/$name.timer" 644 root:root <<<"$4";   (( WROTE )) && changed=1
        if (( changed )); then
            run systemctl daemon-reload
            run systemctl enable "$name.timer"
            run systemctl restart "$name.timer"
        elif ! systemctl is-active --quiet "$name.timer" 2>/dev/null; then
            run systemctl enable --now "$name.timer"
        fi
        log_ok "Timer $name enabled"
    elif [[ -f "$DD_UNIT_DIR/$name.timer" ]]; then
        run systemctl disable --now "$name.timer" || true
        run rm -f "$DD_UNIT_DIR/$name.service" "$DD_UNIT_DIR/$name.timer"
        run systemctl daemon-reload
        log_ok "Timer $name removed"
    fi
    return 0
}

ensure_units() {
    log_step "Scheduled jobs"
    install_self
    local health_on=no
    [[ "${CFG[HEALTH_CHECK]}" == yes || "${CFG[HOST_PANEL]}" == yes ]] && health_on=yes
    unit_set "$UNIT_HEALTH" "$health_on" \
"[Unit]
Description=docker-dashboard service health check
After=docker.service

[Service]
Type=oneshot
ExecStart=$DD_INSTALL_BIN --health --quiet
Nice=10" \
"[Unit]
Description=docker-dashboard health check every ${CFG[HEALTH_INTERVAL]} min

[Timer]
OnBootSec=1min
OnUnitActiveSec=${CFG[HEALTH_INTERVAL]}min
AccuracySec=15s

[Install]
WantedBy=timers.target"
    local on=no cal=""
    if [[ "${CFG[UPDATE_SCHEDULE]}" != off ]]; then
        on=yes; cal=$(render_oncalendar "${CFG[UPDATE_SCHEDULE]}" "${CFG[UPDATE_DAY]}" "${CFG[UPDATE_TIME]}")
    fi
    unit_set "$UNIT_UPDATE" "$on" \
"[Unit]
Description=docker-dashboard: update all containers
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DD_INSTALL_BIN --update-all --yes
TimeoutStartSec=2h" \
"[Unit]
Description=docker-dashboard scheduled container updates (${CFG[UPDATE_SCHEDULE]})

[Timer]
OnCalendar=$cal
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target"
    local cert_svc="[Unit]
Description=docker-dashboard: refresh the TLS certificate
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DD_INSTALL_BIN --cert-refresh --yes"
    local cert_timer="[Unit]
Description=docker-dashboard: fetch the TLS certificate daily

[Timer]
OnCalendar=*-*-* 05:17:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target"
    local cert_path="[Unit]
Description=docker-dashboard: deploy the TLS certificate when it changes

[Path]
PathChanged=${CFG[CERT_FILE]}
PathChanged=${CFG[CERT_KEY_FILE]}

[Install]
WantedBy=multi-user.target"
    # remove the variant not in use first: both share $UNIT_CERT.service
    case "${CFG[CERT_MODE]}" in
        fetch)  unit_set_path "$UNIT_CERT" no "" ""; unit_set "$UNIT_CERT" yes "$cert_svc" "$cert_timer" ;;
        custom) unit_set "$UNIT_CERT" no "" "";      unit_set_path "$UNIT_CERT" yes "$cert_svc" "$cert_path" ;;
        *)      unit_set "$UNIT_CERT" no "" "";      unit_set_path "$UNIT_CERT" no "" "" ;;
    esac
}


# -----------------------------------------------------------------------------
# MIGRATION: --export on the old host, --import on the new one
# Export needs only bash, docker, tar, gzip and openssl (no compose v2, no config).
# -----------------------------------------------------------------------------
c_inspect()  { docker inspect -f "$2" "$1" 2>/dev/null | sed 's/<no value>//g'; }
c_env()      { c_inspect "$1" '{{range .Config.Env}}{{println .}}{{end}}' | sed -n "s/^$2=//p" | head -n1; }
c_env_all()  { c_inspect "$1" '{{range .Config.Env}}{{println .}}{{end}}'; }
c_cmd()      { c_inspect "$1" '{{range .Config.Cmd}}{{println .}}{{end}}'; }
c_image()    { c_inspect "$1" '{{.Config.Image}}'; }
c_project()  { c_inspect "$1" '{{index .Config.Labels "com.docker.compose.project"}}'; }
c_running()  { [[ "$(c_inspect "$1" '{{.State.Running}}')" == true ]]; }
c_hostport() {   # c_hostport C 80/tcp -> host port
    c_inspect "$1" '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$p}}={{.HostPort}}{{println}}{{end}}{{end}}' \
        | sed -n "s#^$2=##p" | head -n1
}
c_mount_src() {  # c_mount_src C DEST -> host path behind that mount (bind source or volume data dir)
    c_inspect "$1" '{{range .Mounts}}{{.Destination}}={{.Source}}{{println}}{{end}}' | sed -n "s#^$2=##p" | head -n1
}
image_repo() {   # lowercase repository without registry/tag/digest
    local r=${1,,}; r=${r%%@*}
    [[ "${r##*/}" == *:* ]] && r=${r%:*}
    r=${r#docker.io/}; r=${r#library/}
    printf '%s' "$r"
}

EX_DIR="" EX_STOPPED=()
ex_set()    { printf '%s=%s\n' "$1" "$(conf_quote "$2")" >>"$EX_DIR/manifest.conf"; }
ex_secret() { [[ -n "$2" ]] && printf '%s=%s\n' "$1" "$(printf '%s' "$2" | base64 -w0)" >>"$EX_DIR/secrets.env"; return 0; }
ex_note()   { printf '%s\n' "$*" >>"$EX_DIR/notes.txt"; log_info "$*"; }

ex_stop() {   # stop a running container once, remember it for the restart
    local c=$1
    c_running "$c" || return 0
    in_list "$c" ${EX_STOPPED[@]+"${EX_STOPPED[@]}"} && return 0
    docker stop -t 30 "$c" >/dev/null && EX_STOPPED+=("$c") && log_info "Stopped $c for a consistent copy"
}

# ex_tar SRC_DIR NAME TARGET_REL  -- archive a host folder; TARGET_REL is where import puts it (under STACKS_DIR)
ex_tar() {
    local src=$1 name=$2 rel=$3
    [[ -n "$src" && -d "$src" ]] || { log_warn "Not found, skipped: $src ($name)"; return 0; }
    mkdir -p "$EX_DIR/data/$(dirname "$name")"
    tar --numeric-owner -C "$src" -czf "$EX_DIR/data/$name.tar.gz" . || die "tar of $src failed"
    printf '%s\t%s\n' "$name.tar.gz" "$rel" >>"$EX_DIR/data/index.tsv"
    log_ok "$(printf '%-34s %8s  <- %s' "$name" "$(du -h "$EX_DIR/data/$name.tar.gz" | cut -f1)" "$src")"
}

ex_ports() {   # ex_ports C KEY CONTAINER_PORT/PROTO [KEY PORT ...] -- only keys whose port is published
    local c=$1; shift
    while (( $# >= 2 )); do ex_set "$1" "$(c_hostport "$c" "$2")"; shift 2; done
}

export_pihole() {
    local c=$1 v pw k envs=""
    log_step "Pi-hole ($c)"
    ex_set APP_PIHOLE yes
    ex_set PIHOLE_IMAGE "$(c_image "$c")"
    ex_set PIHOLE_WEB_PORT "$(c_hostport "$c" 80/tcp)"
    v=$(c_hostport "$c" 53/udp); [[ -n "$v" ]] || v=$(c_hostport "$c" 53/tcp)
    ex_set PIHOLE_DNS_PORT "${v:-53}"
    pw=$(c_env "$c" FTLCONF_webserver_api_password); [[ -n "$pw" ]] || pw=$(c_env "$c" WEBPASSWORD)
    ex_secret PIHOLE_PASSWORD "$pw"
    [[ -n "$pw" ]] || ex_note "Pi-hole: no web password in the environment; the one stored in pihole.toml stays in effect."
    while IFS= read -r v; do
        k=${v%%=*}
        [[ "$k" == FTLCONF_* && "$k" != FTLCONF_webserver_api_password ]] || continue
        if [[ "$v" == *";"* ]]; then ex_note "Pi-hole: $k contains ';' and was not carried over -- set it again after import."; continue; fi
        envs+="${envs:+;}$v"
    done < <(c_env_all "$c")
    ex_set PIHOLE_EXTRA_ENV "$envs"
    [[ -n "$(c_env "$c" WEBPASSWORD)" ]] && ex_note "Pi-hole: v5-style variables found; Pi-hole v6 migrates them on first start."
    [[ -n "$(c_mount_src "$c" /etc/dnsmasq.d)" ]] && ex_note "Pi-hole: /etc/dnsmasq.d was mounted (v5). It is not carried over; v6 keeps its settings in pihole.toml."
    ex_stop "$c"
    ex_tar "$(c_mount_src "$c" /etc/pihole)" pihole/etc-pihole pihole/etc-pihole
}

export_portainer() {
    local c=$1
    log_step "Portainer ($c)"
    ex_set APP_PORTAINER yes
    ex_set PORTAINER_IMAGE "$(c_image "$c")"
    ex_ports "$c" PORTAINER_HTTPS_PORT 9443/tcp PORTAINER_EDGE_PORT 8000/tcp
    ex_stop "$c"
    ex_tar "$(c_mount_src "$c" /data)" portainer/data portainer/data
}

export_monitoring() {   # export_monitoring GRAFANA PROMETHEUS NODEEXP BLACKBOX SPEEDTEST (any may be empty)
    local g=$1 p=$2 n=$3 b=$4 s=$5 v k envs=""
    log_step "Internet monitoring (${g:-no grafana} / ${p:-no prometheus})"
    ex_set APP_MONITORING yes
    if [[ -n "$g" ]]; then
        ex_set GRAFANA_IMAGE "$(c_image "$g")"; ex_ports "$g" GRAFANA_PORT 3000/tcp
        ex_secret GRAFANA_ADMIN_PASSWORD "$(c_env "$g" GF_SECURITY_ADMIN_PASSWORD)"
        v=$(c_env "$g" GF_INSTALL_PLUGINS); [[ -n "$v" ]] || v=$(c_env "$g" GF_PLUGINS_PREINSTALL)
        ex_set GRAFANA_PLUGINS "$v"
        while IFS= read -r v; do
            k=${v%%=*}
            [[ "$k" == GF_* ]] || continue
            case "$k" in GF_SECURITY_ADMIN_PASSWORD|GF_PATHS_*|GF_USERS_ALLOW_SIGN_UP|GF_INSTALL_PLUGINS|GF_PLUGINS_PREINSTALL|GF_SERVER_ROOT_URL) continue ;; esac
            [[ "$v" == *";"* ]] && { ex_note "Grafana: $k contains ';' and was not carried over."; continue; }
            envs+="${envs:+;}$v"
        done < <(c_env_all "$g")
        ex_set GRAFANA_EXTRA_ENV "$envs"
    fi
    if [[ -n "$p" ]]; then
        ex_set PROMETHEUS_IMAGE "$(c_image "$p")"; ex_ports "$p" PROMETHEUS_PORT 9090/tcp
        v=$(c_cmd "$p" | sed -n 's/^--storage\.tsdb\.retention\(\.time\)\{0,1\}=//p' | head -n1)
        [[ -n "$v" ]] && ex_set PROMETHEUS_RETENTION "$v"
    fi
    [[ -n "$n" ]] && { ex_set NODEEXP_IMAGE "$(c_image "$n")";   ex_ports "$n" NODEEXP_PORT 9100/tcp; }
    [[ -n "$b" ]] && { ex_set BLACKBOX_IMAGE "$(c_image "$b")";  ex_ports "$b" BLACKBOX_PORT 9115/tcp; }
    [[ -n "$s" ]] && { ex_set SPEEDTEST_IMAGE "$(c_image "$s")"; ex_ports "$s" SPEEDTEST_PORT 9798/tcp; }
    [[ -n "$p" ]] && ex_tar "$(c_mount_src "$p" /etc/prometheus)" monitoring/prometheus-config monitoring/prometheus
    [[ -n "$g" ]] && ex_tar "$(c_mount_src "$g" /etc/grafana/provisioning)" monitoring/grafana-provisioning monitoring/grafana/provisioning
    [[ -n "$b" ]] && ex_tar "$(c_mount_src "$b" /config)" monitoring/blackbox-config monitoring/blackbox/config
    if [[ -n "$g" ]]; then ex_stop "$g"; ex_tar "$(c_mount_src "$g" /var/lib/grafana)" monitoring/grafana-data monitoring/data/grafana; fi
    if [[ -n "$p" ]]; then
        if (( EXPORT_NO_METRICS )); then ex_note "Prometheus history skipped (--no-metrics)."
        else ex_stop "$p"; ex_tar "$(c_mount_src "$p" /prometheus)" monitoring/prometheus-data monitoring/data/prometheus; fi
    fi
}

export_guacamole() {   # export_guacamole GUACAMOLE GUACD POSTGRES [TLS_PORT]
    local g=$1 d=$2 pg=$3 tlsport=${4:-} db user pw started=0
    log_step "Guacamole ($g, db: ${pg:-none})"
    db=$(c_env "$g" POSTGRESQL_DATABASE);  [[ -n "$db" ]]   || db=$(c_env "$g" POSTGRES_DATABASE)
    user=$(c_env "$g" POSTGRESQL_USERNAME); [[ -n "$user" ]] || user=$(c_env "$g" POSTGRESQL_USER); [[ -n "$user" ]] || user=$(c_env "$g" POSTGRES_USER)
    pw=$(c_env "$g" POSTGRESQL_PASSWORD);  [[ -n "$pw" ]]   || pw=$(c_env "$g" POSTGRES_PASSWORD)
    [[ -n "$pg" && -n "$db" && -n "$user" ]] || { ex_note "Guacamole: no PostgreSQL database found; not exported (MySQL setups are not supported)."; return 0; }
    ex_set APP_GUACAMOLE yes
    ex_set GUAC_DB_NAME "$db"; ex_set GUAC_DB_USER "$user"
    ex_secret GUAC_DB_PASSWORD "$pw"
    [[ -n "$tlsport" ]] && ex_set GUACAMOLE_TLS_PORT "$tlsport"
    if ! c_running "$pg"; then docker start "$pg" >/dev/null; started=1; sleep 5; fi
    mkdir -p "$EX_DIR/data/guacamole"
    log_info "Dumping database $db (pg_dump -Fc)"
    docker exec "$pg" pg_dump -U "$user" -d "$db" -Fc >"$EX_DIR/data/guacamole/guacamole.dump" \
        || die "pg_dump of the Guacamole database failed."
    docker exec -i "$pg" pg_restore -l <"$EX_DIR/data/guacamole/guacamole.dump" >/dev/null \
        || die "The Guacamole dump is not readable by pg_restore."
    printf 'guacamole/guacamole.dump\tguacamole/.restore/guacamole.dump\n' >>"$EX_DIR/data/index.tsv"
    log_ok "$(printf '%-34s %8s' guacamole/guacamole.dump "$(du -h "$EX_DIR/data/guacamole/guacamole.dump" | cut -f1)")"
    (( started )) && docker stop "$pg" >/dev/null
    if [[ -n "$d" ]]; then
        ex_tar "$(c_mount_src "$d" /drive)" guacamole/drive guacamole/drive
        ex_tar "$(c_mount_src "$d" /record)" guacamole/record guacamole/record
    fi
}

export_meshcentral() {
    local c=$1 base part src got=0 t
    log_step "MeshCentral ($c)"
    ex_set APP_MESHCENTRAL yes
    ex_set MESHCENTRAL_PORT "$(c_hostport "$c" 443/tcp)"
    ex_stop "$c"
    t=$(mktemp -d "$EX_DIR/.mesh.XXXXXX")
    for part in data files backups web; do
        src=""
        for base in /opt/meshcentral /meshcentral; do
            src=$(c_mount_src "$c" "$base/meshcentral-$part")
            if [[ -n "$src" ]]; then ex_tar "$src" "meshcentral/meshcentral-$part" "meshcentral/$part"; got=1; continue 2; fi
        done
        # not a mount: the data lives inside the container -- copy it out
        for base in /opt/meshcentral /meshcentral; do
            if docker cp "$c:$base/meshcentral-$part" "$t/" >/dev/null 2>&1; then
                if [[ "$part" == data ]] && grep -Eq '"(mongoDb|mongodb|postgres|mariaDB|mySQL)"[[:space:]]*:' "$t/meshcentral-data/config.json" 2>/dev/null; then
                    ex_note "MeshCentral: config.json uses an external database; only the files are migrated -- move that database yourself."
                fi
                ex_tar "$t/meshcentral-$part" "meshcentral/meshcentral-$part" "meshcentral/$part"; got=1
                [[ "$part" == data ]] && ex_note "MeshCentral: data was inside the container ($base/meshcentral-$part), now kept in a folder."
                break
            fi
        done
    done
    rm -rf "$t"
    (( got )) || ex_note "MeshCentral: no meshcentral-data found in $c -- not exported."
    return 0
}

export_bundle() {
    [[ $EUID -eq 0 ]] || die "Export needs root."
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || die "Docker is not running here."
    local outdir host ts work c img repo proj out pass_file="" p1 p2
    outdir=$(getent passwd "$REAL_USER" | cut -d: -f6); outdir=${EXPORT_DIR:-${outdir:-/root}}
    host=$(hostname -s); ts=$(date +%F_%H%M)
    work=$(mktemp -d "$outdir/.dd-export.XXXXXX")
    EX_DIR="$work/export"; mkdir -p "$EX_DIR/data"
    ( umask 077; : >"$EX_DIR/secrets.env" )
    : >"$EX_DIR/data/index.tsv"
    log_step "Export from $host ($SCRIPT_NAME v$SCRIPT_VERSION)"
    printf '# %s\nFORMAT=%s\nSOURCE_HOST=%s\nSOURCE_DATE=%s\n' "$EXPORT_FORMAT" "$(conf_quote "$EXPORT_FORMAT")" \
        "$(conf_quote "$host")" "$(conf_quote "$(date -Iseconds)")" >"$EX_DIR/manifest.conf"

    # passphrase first, so nothing is stopped if the user backs out
    if [[ -n "$PASSPHRASE_FILE" ]]; then
        [[ -s "$PASSPHRASE_FILE" ]] || die "Passphrase file $PASSPHRASE_FILE is empty or missing."
        pass_file=$PASSPHRASE_FILE
    elif is_tty; then
        log_info "The bundle holds your app passwords, so it is encrypted. Choose a passphrase (you need it for --import)."
        while :; do
            read -rsp "  Passphrase: " p1 || true; echo
            read -rsp "  Again: " p2 || true; echo
            [[ -n "$p1" && "$p1" == "$p2" ]] && break
            log_warn "Empty or not matching, try again."
        done
        pass_file="$work/.pass"; ( umask 077; printf '%s\n' "$p1" >"$pass_file" ); p1=""; p2=""
    else
        die "Non-interactive export needs --passphrase-file FILE."
    fi

    local pihole="" portainer="" grafana="" prom="" nodeexp="" blackbox="" speedtest="" guac="" guacd="" mesh="" guacproj="" pg="" tlsport=""
    local -a pgs=() unknown=() nginx_c=()
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        img=$(c_image "$c"); repo=$(image_repo "$img"); proj=$(c_project "$c")
        [[ "$proj" == "$PROJECT_NAME" ]] && continue
        [[ "$(c_inspect "$c" '{{.HostConfig.AutoRemove}}')" == true ]] && continue   # temporary (--rm) containers
        case "$repo" in
            */pihole|pihole)                           [[ -z "$pihole" ]] && pihole=$c || unknown+=("$c (second Pi-hole)") ;;
            portainer/portainer-ce|portainer/portainer-ee|portainer/portainer) [[ -z "$portainer" ]] && portainer=$c ;;
            grafana/grafana*)                          [[ -z "$grafana" ]] && grafana=$c ;;
            prom/prometheus|*/prometheus/prometheus)  [[ -z "$prom" ]] && prom=$c ;;
            *node-exporter*)                           [[ -z "$nodeexp" ]] && nodeexp=$c ;;
            *blackbox-exporter*)                       [[ -z "$blackbox" ]] && blackbox=$c ;;
            *speedtest-exporter*)                      [[ -z "$speedtest" ]] && speedtest=$c ;;
            guacamole/guacamole)                       guac=$c; guacproj=$proj ;;
            guacamole/guacd)                           guacd=$c ;;
            postgres|*/postgres)                       pgs+=("$c") ;;
            nginx|*/nginx)                             nginx_c+=("$c") ;;
            *meshcentral*)                             mesh=$c ;;
            *)  if c_cmd "$c" | grep -qx meshcentral; then mesh=$c; else unknown+=("$c ($img)"); fi ;;
        esac
    done < <(docker ps -a --format '{{.Names}}')

    if [[ -n "$guac" ]]; then
        for c in ${pgs[@]+"${pgs[@]}"}; do [[ -n "$guacproj" && "$(c_project "$c")" == "$guacproj" ]] && { pg=$c; break; }; done
        [[ -z "$pg" && ${#pgs[@]} -eq 1 ]] && pg=${pgs[0]}
        for c in ${nginx_c[@]+"${nginx_c[@]}"}; do
            [[ -n "$guacproj" && "$(c_project "$c")" == "$guacproj" ]] && tlsport=$(c_hostport "$c" 443/tcp)
        done
    fi
    for c in ${pgs[@]+"${pgs[@]}"}; do [[ "$c" == "$pg" ]] || unknown+=("$c (postgres, not Guacamole's)"); done
    for c in ${nginx_c[@]+"${nginx_c[@]}"}; do [[ -n "$guacproj" && "$(c_project "$c")" == "$guacproj" ]] || unknown+=("$c (nginx)"); done

    [[ -n "$pihole" ]]    && export_pihole "$pihole"
    [[ -n "$portainer" ]] && export_portainer "$portainer"
    [[ -n "$grafana$prom" ]] && export_monitoring "$grafana" "$prom" "$nodeexp" "$blackbox" "$speedtest"
    [[ -n "$guac" ]]      && export_guacamole "$guac" "$guacd" "$pg" "$tlsport"
    [[ -n "$mesh" ]]      && export_meshcentral "$mesh"

    if [[ -f "$CONF_FILE" ]]; then
        load_config
        local n cid
        for n in $(custom_names); do
            log_step "Custom app $n"
            for cid in $(docker ps -q --filter "label=com.docker.compose.project=$(custom_project "$n")"); do ex_stop "$(c_inspect "$cid" '{{.Name}}' | sed 's#^/##')"; done
            ex_tar "$(custom_dir "$n")" "custom/$n" "custom/$n"
        done
    fi

    local files_src; files_src="$(getent passwd "$REAL_USER" | cut -d: -f6)/web-site-content"
    if [[ -d "$files_src" ]]; then
        log_step "File share ($files_src)"
        ex_tar "$files_src" files/web-site-content files
        ex_set FILES_DIR "@STACKS@/files"
    fi

    local rc=0
    if (( ! EXPORT_LEAVE_STOPPED )) && (( ${#EX_STOPPED[@]} )); then
        log_step "Restarting stopped containers"
        for c in "${EX_STOPPED[@]}"; do docker start "$c" >/dev/null && log_ok "Started $c" || { log_warn "Could not start $c"; rc=1; }; done
    elif (( ${#EX_STOPPED[@]} )); then
        log_warn "Left stopped (--leave-stopped): ${EX_STOPPED[*]}"
    fi
    (( ${#unknown[@]} )) && ex_note "Not migrated (unknown to this installer): ${unknown[*]}"

    log_step "Writing bundle"
    out="$outdir/docker-dashboard-export-$host-$ts.tar.gz.enc"
    rm -rf "$EX_DIR"/.mesh.*
    tar -C "$work" --exclude .pass -cz export \
        | openssl enc -aes-256-cbc -pbkdf2 -iter 250000 -salt -pass "file:$pass_file" >"$out" \
        || { rm -f "$out"; die "Writing the encrypted bundle failed."; }
    chmod 600 "$out"; chown "$REAL_USER:" "$out" 2>/dev/null || true
    rm -rf "$work"
    log_ok "Bundle: $out ($(du -h "$out" | cut -f1), encrypted)"
    log_info "Changes made on this host after now are not in the bundle -- export again right before the cutover."
    log_info "Copy it to the new host, then: sudo ./docker-dashboard.sh --install --import $(basename "$out")"
    return $rc
}

# ---- import ---------------------------------------------------------------
IMPORT_STAGE="" IMPORT_FILES_DEFAULT=""

import_stage() {   # decrypt + unpack + apply manifest and secrets (no data written yet)
    local f=$1 pass_file="" p
    [[ -r "$f" ]] || die "Cannot read $f"
    IMPORT_STAGE="$DD_STATE_DIR/import"
    rm -rf "$IMPORT_STAGE"; mkdir -p "$IMPORT_STAGE"; chmod 700 "$IMPORT_STAGE"
    log_step "Import: unpack $(basename "$f") ($(du -h "$f" | cut -f1))"
    if [[ "$(head -c 8 "$f")" == "Salted__" ]]; then
        if [[ -n "$PASSPHRASE_FILE" ]]; then pass_file=$PASSPHRASE_FILE
        else
            is_tty || die "Encrypted bundle: pass --passphrase-file FILE."
            read -rsp "  Bundle passphrase: " p || true; echo
            pass_file="$IMPORT_STAGE/.pass"; ( umask 077; printf '%s\n' "$p" >"$pass_file" ); p=""
        fi
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -pass "file:$pass_file" <"$f" | tar -xz -C "$IMPORT_STAGE" \
            || { rm -rf "$IMPORT_STAGE"; die "Could not decrypt/unpack the bundle (wrong passphrase?)."; }
        rm -f "$IMPORT_STAGE/.pass"
    else
        tar -xzf "$f" -C "$IMPORT_STAGE" || die "Could not unpack $f"
    fi
    local ex="$IMPORT_STAGE/export" line k
    [[ -f "$ex/manifest.conf" ]] && grep -q "^FORMAT='$EXPORT_FORMAT'" "$ex/manifest.conf" || die "Not a $SCRIPT_NAME export bundle."
    log_info "From $(sed -n "s/^SOURCE_HOST=//p" "$ex/manifest.conf" | tr -d "'") on $(sed -n "s/^SOURCE_DATE=//p" "$ex/manifest.conf" | tr -d "'")"
    while IFS= read -r line; do apply_cfg_line "$line"; done <"$ex/manifest.conf"
    if [[ "${CFG[FILES_DIR]}" == "@STACKS@/files" ]]; then
        CFG[FILES_DIR]="${CFG[STACKS_DIR]%/}/files"; IMPORT_FILES_DEFAULT=${CFG[FILES_DIR]}
    fi
    load_secrets
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
        k=${BASH_REMATCH[1]}; in_list "$k" "${SECRET_KEYS[@]}" || continue
        SECRETS[$k]=$(printf '%s' "${BASH_REMATCH[2]}" | base64 -d)
    done <"$ex/secrets.env"
    log_ok "Apps in bundle: $(enabled_apps | xargs)"
    [[ -s "$ex/notes.txt" ]] && { log_info "Notes from the export:"; sed 's/^/    /' "$ex/notes.txt"; }
    return 0
}

import_data() {   # write the staged data into STACKS_DIR (after settings are final)
    local ex="$IMPORT_STAGE/export" tarf rel target
    [[ -n "$IMPORT_STAGE" && -f "$ex/data/index.tsv" ]] || return 0
    log_step "Import: restore data into $STACKS_DIR"
    save_secrets
    # the shared files were restored under the apps folder; follow it if the wizard moved that folder
    [[ -n "$IMPORT_FILES_DEFAULT" && "${CFG[FILES_DIR]}" == "$IMPORT_FILES_DEFAULT" ]] && CFG[FILES_DIR]="$STACKS_DIR/files"
    save_config
    # one decision for all existing data: overwrite means stopping the apps first
    local -a busy=()
    while IFS=$'\t' read -r tarf rel; do
        [[ -n "$tarf" ]] || continue
        [[ "$tarf" == *.dump ]] && rel="guacamole/data/postgres"   # the dump replaces the whole database
        [[ -d "$STACKS_DIR/$rel" && -n "$(ls -A "$STACKS_DIR/$rel" 2>/dev/null)" ]] && busy+=("$STACKS_DIR/$rel")
    done <"$ex/data/index.tsv"
    if (( ${#busy[@]} )); then
        log_warn "These folders already hold data and would be replaced by the bundle:"
        printf '      %s\n' "${busy[@]}" >&2
        confirm_typed OVERWRITE || die "Import stopped; nothing was changed. Type OVERWRITE (or --confirm OVERWRITE) to replace them."
        load_secrets
        local a; for a in "${APPS[@]}"; do app_down "$a" "its data is being replaced"; done
        in_list "$STACKS_DIR/guacamole/data/postgres" "${busy[@]}" && run rm -rf -- "$STACKS_DIR/guacamole/data/postgres"
    fi
    while IFS=$'\t' read -r tarf rel; do
        [[ -n "$tarf" ]] || continue
        target="$STACKS_DIR/$rel"
        if [[ "$tarf" == *.dump ]]; then
            run mkdir -p "$(dirname "$target")"
            run cp "$ex/data/$tarf" "$target"
            log_ok "$(printf '%-34s -> %s' "$tarf" "$target")"
            continue
        fi
        [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]] && run rm -rf -- "$target"
        run mkdir -p "$target"
        run tar --numeric-owner -xzf "$ex/data/$tarf" -C "$target"
        log_ok "$(printf '%-34s -> %s' "${tarf%.tar.gz}" "$target")"
    done <"$ex/data/index.tsv"
    (( DRY_RUN )) || rm -rf "$IMPORT_STAGE"
    state_set imported "$(date -Iseconds)"
    return 0
}
# -----------------------------------------------------------------------------
# SERVICES MENU
# -----------------------------------------------------------------------------
list_services() {
    if (( ${#SVC_NAME[@]} == 0 )); then log_info "No services yet (D detects them from running containers)."; return 0; fi
    local i
    for i in "${!SVC_NAME[@]}"; do
        printf '  %2d) %s[%s]%s %-18s %s\n' "$((i + 1))" "$D" "${SVC_GROUP[$i]}" "$NC" "${SVC_NAME[$i]}" "${SVC_URL[$i]}"
    done
}

pick_service() {   # pick_service VAR -> 0-based index
    local __v=$1 n
    read -rp "  Number: " n || return 1
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#SVC_NAME[@]} )) || { log_warn "No such entry"; return 1; }
    printf -v "$__v" '%s' "$((n - 1))"
}

service_prompt() {   # service_prompt GROUP NAME URL DESC -> sets P_G P_N P_U P_D
    local g n u d
    while :; do ask g "Group" "${1:-Services}"; valid_field "$g" && [[ -n "$g" ]] && break; log_warn "No '|' allowed"; done
    while :; do ask n "Name" "${2:-}"; valid_field "$n" && [[ -n "$n" ]] && break; log_warn "Name required, no '|'"; done
    while :; do ask u "URL (http:// or https://)" "${3:-}"; valid_url "$u" && break; log_warn "Must start with http:// or https:// and contain no spaces"; done
    while :; do ask d "Description (- for none)" "${4:-}"; [[ "$d" == - ]] && d=""; valid_field "$d" && break; log_warn "No '|' allowed"; done
    P_G=$g P_N=$n P_U=$u P_D=$d
}

menu_services() {
    ensure_config; detect_network; load_services
    local dirty=0 i j
    while :; do
        printf '\n  %sCustom links%s  (%s)\n' "$B" "$NC" "$SERVICES_FILE"
        list_services
        printf '\n   A) Add   E) Edit   R) Remove   M) Move   D) Detect from containers   H) Health now   0) Back\n'
        local ch; read -rp "  Choice: " ch || break
        case "${ch,,}" in
            a) service_prompt "Links" "" "" ""; svc_add "$P_G" "$P_N" "$P_U" "$P_D" && dirty=1 ;;
            e) pick_service i || continue
               service_prompt "${SVC_GROUP[$i]}" "${SVC_NAME[$i]}" "${SVC_URL[$i]}" "${SVC_DESC[$i]}"
               SVC_GROUP[i]=$P_G; SVC_NAME[i]=$P_N; SVC_URL[i]=$P_U; SVC_DESC[i]=$P_D; dirty=1 ;;
            r) pick_service i || continue
               confirm "Remove '${SVC_NAME[$i]}'?" n && { svc_remove "$i"; dirty=1; } ;;
            m) pick_service i || continue
               read -rp "  Move to position: " j || continue
               [[ "$j" =~ ^[0-9]+$ ]] && (( j >= 1 && j <= ${#SVC_NAME[@]} )) || { log_warn "No such position"; continue; }
               svc_move "$i" "$((j - 1))"; dirty=1 ;;
            d) save_services; menu_action detect_services; load_services; dirty=1 ;;
            h) (( dirty )) && { save_services; dirty=0; publish_services; }; menu_action health_check ;;
            0|q) break ;;
            *) printf '  %sInvalid choice%s\n' "$R" "$NC" ;;
        esac
        if (( dirty )); then save_services; dirty=0; publish_services; fi
    done
    return 0
}


# -----------------------------------------------------------------------------
# STATUS
# -----------------------------------------------------------------------------
show_status() {
    ensure_config; detect_network; load_services
    log_step "docker-dashboard status"
    printf '  %-20s %s\n' "Script" "v$SCRIPT_VERSION ($SCRIPT_PATH)"
    printf '  %-20s %s\n' "Config" "$( [[ -f "$CONF_FILE" ]] && echo "$CONF_FILE" || echo 'not configured')"
    printf '  %-20s %s\n' "Dashboard" "$(dashboard_url)  (http :${CFG[HTTP_PORT]} redirects)"
    printf '  %-20s %s\n' "Host address" "$(eff_host)  (detected ${DET_IP:-?} on ${DET_IFACE:-?})"
    printf '  %-20s %s\n' "Domain" "${CFG[DOMAIN]:-none (links use ports)}"
    printf '  %-20s %s\n' "Folders" "apps=$STACKS_DIR  dashboard=$DEPLOY_DIR"
    printf '  %-20s %s\n' "Secrets" "$( [[ -f "$SECRETS_FILE" ]] && echo "$SECRETS_FILE ($(secrets_file_backend))" || echo none)"
    if [[ -s "$DEPLOY_DIR/certs/dashboard.crt" ]]; then
        printf '  %-20s %s, %s\n' "Certificate" "${CFG[CERT_MODE]}" "$(openssl x509 -in "$DEPLOY_DIR/certs/dashboard.crt" -noout -enddate 2>/dev/null | sed 's/notAfter=/expires /')"
    fi
    printf '  %-20s %s\n' "File share" "$( [[ -n "${CFG[FILES_DIR]}" ]] && echo "${CFG[FILES_DIR]} -> /files/ (http: ${CFG[FILES_HTTP]})" || echo off)"
    printf '  %-20s %s\n' "Custom links" "${#SVC_NAME[@]}  ($SERVICES_FILE)"
    if [[ "${CFG[UPDATE_SCHEDULE]}" == off ]]; then printf '  %-20s %s\n' "Scheduled updates" "off"
    else printf '  %-20s %s\n' "Scheduled updates" "${CFG[UPDATE_SCHEDULE]} $( [[ "${CFG[UPDATE_SCHEDULE]}" == weekly ]] && echo "${CFG[UPDATE_DAY]} ")${CFG[UPDATE_TIME]}"; fi
    printf '  %-20s %s\n' "Last update run" "$(state_get last_update | sed 's/^$/never/')"
    printf '\n  %sApps%s\n' "$B" "$NC"
    local a st n
    for a in "${APPS[@]}"; do
        if app_on "$a"; then
            if docker_up; then
                n=$(docker ps -q --filter "label=com.docker.compose.project=$(app_project "$a")" | wc -l)
                st="${G}on${NC}, $n running"
            else st="${G}on${NC}"; fi
        else st="${D}off${NC}"; fi
        printf '  %-44s %b\n' "${APP_TITLE[$a]}" "$st"
    done
    for a in $(custom_names); do
        custom_load "$a"
        if [[ "${CA[ENABLED]}" == yes ]]; then
            if docker_up; then n=$(custom_ids_all "$a" | xargs -r docker inspect -f '{{.State.Running}}' 2>/dev/null | grep -c true); st="${G}on${NC}, $n running"
            else st="${G}on${NC}"; fi
        else st="${D}off${NC}"; fi
        printf '  %-44s %b\n' "${CA[TITLE]} (custom)" "$st"
    done
    if command -v systemctl >/dev/null 2>&1; then
        local tl; tl=$(systemctl list-timers "$UNIT_HEALTH.timer" "$UNIT_UPDATE.timer" "$UNIT_CERT.timer" --no-legend 2>/dev/null | awk '{print "    " $0}')
        [[ -n "$tl" ]] && printf '\n  Timers:\n%s\n' "$tl"
    fi
    if ! docker_up; then log_warn "Docker is not installed or not running."; return 0; fi
    echo
    docker ps -a --filter "label=com.docker.compose.project" --format '{{.Label "com.docker.compose.project"}}\t{{.Names}}\t{{.State}}\t{{.Status}}' \
        | awk -F'\t' -v pre="$APP_PREFIX" -v self="$PROJECT_NAME" '$1 == self || index($1, pre) == 1' | sort \
        | awk -F'\t' 'BEGIN {printf "  %-16s %-22s %-9s %s\n", "PROJECT", "CONTAINER", "STATE", "STATUS"} {printf "  %-16s %-22s %-9s %s\n", $1, $2, $3, $4}'
    if [[ -f "$DEPLOY_DIR/html/status.json" ]]; then
        local up down
        up=$(grep -c '"state": "up"' "$DEPLOY_DIR/html/status.json" || true)
        down=$(grep -c '"state": "down"' "$DEPLOY_DIR/html/status.json" || true)
        echo; printf '  Link health: %s up, %s down (menu 9 / --health for detail)\n' "$up" "$down"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# SETTINGS
# -----------------------------------------------------------------------------
ask_valid() {   # ask_valid KEY "Prompt" VALIDATOR -- '-' clears optional values
    local key=$1 prompt=$2 v=$3 val
    while :; do
        ask val "$prompt" "${CFG[$key]}"
        [[ "$val" == "-" ]] && val=""
        if "$v" "$val"; then CFG[$key]=$val; return 0; fi
        log_warn "Invalid value '$val'"
        { (( ASSUME_YES )) || ! is_tty; } && die "Invalid value for $key: '$val'"
    done
}
v_any()       { valid_field "$1"; }
v_title()     { [[ -n "$1" ]] && valid_field "$1"; }
v_host()      { [[ "$1" == auto ]] || valid_ipv4 "$1" || valid_hostname "$1"; }
v_names()     { local n; for n in ${1//,/ }; do valid_ipv4 "$n" || valid_hostname "${n#\*.}" || return 1; done; }
v_domain_opt(){ [[ -z "$1" ]] || { valid_hostname "$1" && [[ "$1" == *.* ]]; }; }
v_sub()       { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }
v_port()      { valid_port "$1"; }
v_port_opt()  { [[ -z "$1" ]] || valid_port "$1"; }
v_path()      { valid_abs_path "$1"; }
v_path_opt()  { [[ -z "$1" ]] || valid_abs_path "$1"; }
v_file_opt()  { [[ -z "$1" ]] || [[ "$1" == /* && -r "$1" ]]; }
v_image()     { [[ "$1" =~ ^[a-z0-9][a-z0-9._/:@-]*$ ]]; }
v_certmode()  { [[ "$1" =~ ^(selfsigned|custom|fetch)$ ]]; }
v_days()      { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 30 && $1 <= 3650 )); }
v_yesno()     { [[ "$1" =~ ^(yes|no)$ ]]; }
v_minutes()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 60 )); }
v_sched()     { [[ "$1" =~ ^(off|daily|weekly)$ ]]; }
v_day()       { [[ "$1" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]]; }
v_time()      { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
v_words()     { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9_.,\ -]+$ ]]; }
v_delegate()  { local e IFS=';'; for e in $1; do e="${e#"${e%%[![:space:]]*}"}"; [[ -z "$e" || "$e" =~ ^[a-z0-9][a-z0-9_-]*=/.+ ]] || return 1; done; }
v_tz()        { [[ "$1" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]]; }
v_retention() { [[ "$1" =~ ^[0-9]+[smhdwy]$ ]]; }
v_kv()        { local e IFS=';'; for e in $1; do e=$(trim "$e"); [[ -z "$e" || "$e" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^\'[:cntrl:]]*$ ]] || return 1; done; }
v_fetchsrc()  { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+:/[^[:space:]\']*$ ]]; }
v_fname()     { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
v_url()       { valid_url "$1"; }
v_pct()       { [[ "$1" =~ ^[0-9]{1,3}$ ]] && (( $1 >= 1 && $1 <= 100 )); }
v_load()      { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
section() { printf '\n  %s%s%s\n' "$B" "$1" "$NC"; }

cfg_page() {
    section "Page, domain and host"
    ask_valid DASH_TITLE "Page title" v_title
    [[ -z "${CFG[DOMAIN]}" ]] && CFG[DOMAIN]=$(detect_domain)
    ask_valid DOMAIN "Domain for app names, e.g. example.net -> grafana.example.net (- for none: links use ports)" v_domain_opt
    [[ -n "${CFG[DOMAIN]}" ]] && ask_valid DASH_SUBDOMAIN "Dashboard name (-> $(fqdn "${CFG[DASH_SUBDOMAIN]}"))" v_sub
    detect_network
    ask_valid HOST_ADDR "Address the names point at (auto = $DET_IP; set the FINAL IP if this host will move)" v_host
    ask_valid TIMEZONE "Time zone for the apps" v_tz
}
cfg_ports() {
    section "Dashboard ports"
    ask_valid HTTP_PORT  "HTTP port (redirects to HTTPS)" v_port
    ask_valid HTTPS_PORT "HTTPS port" v_port
    [[ "${CFG[HTTP_PORT]}" != "${CFG[HTTPS_PORT]}" ]] || { log_warn "Ports must differ"; cfg_ports; }
}
cfg_cert() {
    section "Certificate"
    log_info "selfsigned = generated here | custom = files on this host | fetch = copy over scp daily (e.g. from OPNsense acme.sh)"
    ask_valid CERT_MODE "Mode" v_certmode
    case "${CFG[CERT_MODE]}" in
        custom)
            ask_valid CERT_FILE "Certificate file (full chain PEM)" v_file_opt
            ask_valid CERT_KEY_FILE "Private key file (PEM)" v_file_opt
            [[ -n "${CFG[CERT_FILE]}" && -n "${CFG[CERT_KEY_FILE]}" ]] || { log_warn "Both files are required"; cfg_cert; } ;;
        fetch)
            ask_valid CERT_FETCH_SOURCE "Source user@host:/folder (e.g. certsync@192.168.0.253:/path/to/certs)" v_fetchsrc
            ask_valid CERT_FETCH_CERT "Certificate file name in that folder" v_fname
            ask_valid CERT_FETCH_KEY "Key file name in that folder" v_fname
            [[ -n "${CFG[CERT_FETCH_SOURCE]}" ]] || { log_warn "A source is required"; cfg_cert; return 0; }
            [[ -f "$FETCH_KEY" ]] || { confirm "Create the SSH key used for fetching now?" y && cert_fetch_key; } ;;
        *)  ask_valid CERT_DAYS "Self-signed validity in days (30-3650)" v_days
            ask_valid EXTRA_NAMES "Extra names for the certificate (- to clear)" v_names ;;
    esac
    return 0
}
cfg_files() {
    section "File share (/files/ on the page, e.g. scripts to curl onto other machines)"
    ask_valid FILES_DIR "Folder to share read-only (- to turn off)" v_path_opt
    [[ -n "${CFG[FILES_DIR]}" ]] && ask_valid FILES_HTTP "Also allow plain-HTTP downloads on :${CFG[HTTP_PORT]}/files/ (yes/no)" v_yesno
    return 0
}
cfg_health() {
    section "Health checks (status dots on the page)"
    ask_valid HEALTH_CHECK "Check links from this host (yes/no)" v_yesno
    [[ "${CFG[HEALTH_CHECK]}" == yes ]] && ask_valid HEALTH_INTERVAL "Interval in minutes (1-60)" v_minutes
    ask_valid HOST_PANEL "Show host health (CPU, memory, disks, containers) on the page (yes/no)" v_yesno
    if [[ "${CFG[HOST_PANEL]}" == yes ]]; then
        ask_valid HOST_DISK_WARN "Disk use warning at %" v_pct
        ask_valid HOST_DISK_CRIT "Disk use critical at %" v_pct
        ask_valid HOST_MEM_WARN "Memory use warning at %" v_pct
        ask_valid HOST_MEM_CRIT "Memory use critical at %" v_pct
        ask_valid HOST_LOAD_WARN "5-min load per CPU core, warning at" v_load
        ask_valid HOST_LOAD_CRIT "5-min load per CPU core, critical at" v_load
    fi
    return 0
}
cfg_updates() {
    section "Container updates"
    ask_valid UPDATE_SCHEDULE "Automatic schedule: off | daily | weekly" v_sched
    if [[ "${CFG[UPDATE_SCHEDULE]}" != off ]]; then
        [[ "${CFG[UPDATE_SCHEDULE]}" == weekly ]] && ask_valid UPDATE_DAY "Day (Mon..Sun)" v_day
        ask_valid UPDATE_TIME "Time (HH:MM, 24h, local)" v_time
    fi
    ask_valid UPDATE_PRUNE "Remove dangling images afterwards (yes/no)" v_yesno
    ask_valid UPDATE_EXCLUDE "Never update these apps/containers/projects (space-separated, - to clear)" v_words
    ask_valid UPDATE_DELEGATE "Projects updated by their own installer: project=command;... (- to clear)" v_delegate
    ask_valid WATCHTOWER_IMAGE "Watchtower image (for docker-run containers)" v_image
}
cfg_paths() {
    section "Paths and image"
    ask_valid STACKS_DIR "Apps folder (one subfolder per app, data included)" v_path
    ask_valid DEPLOY_DIR "Dashboard folder" v_path
    ask_valid NGINX_IMAGE "nginx image" v_image
    DEPLOY_DIR=${CFG[DEPLOY_DIR]%/}; STACKS_DIR=${CFG[STACKS_DIR]%/}
}

cfg_app() {   # per-app settings
    local a=$1
    section "${APP_TITLE[$a]}"
    case "$a" in
        pihole)
            ask_valid PIHOLE_IMAGE "Image" v_image
            ask_valid PIHOLE_SUBDOMAIN "Name (-> $(fqdn "${CFG[PIHOLE_SUBDOMAIN]}"))" v_sub
            ask_valid PIHOLE_DNS_PORT "DNS port on the host" v_port
            ask_valid PIHOLE_WEB_PORT "Direct web port on the host (- for proxy only)" v_port_opt
            ask_valid PIHOLE_LOCAL_DNS "Answer the dashboard's names itself (yes/no)" v_yesno
            ask_valid PIHOLE_EXTRA_ENV "Extra FTLCONF_* settings, K=V;K=V (- to clear)" v_kv ;;
        portainer)
            ask_valid PORTAINER_IMAGE "Image" v_image
            ask_valid PORTAINER_SUBDOMAIN "Name (-> $(fqdn "${CFG[PORTAINER_SUBDOMAIN]}"))" v_sub
            ask_valid PORTAINER_HTTPS_PORT "Direct HTTPS port (- for proxy only)" v_port_opt
            ask_valid PORTAINER_EDGE_PORT "Edge agent port (- for none)" v_port_opt ;;
        monitoring)
            ask_valid GRAFANA_IMAGE "Grafana image" v_image
            ask_valid PROMETHEUS_IMAGE "Prometheus image" v_image
            ask_valid GRAFANA_SUBDOMAIN "Grafana name (-> $(fqdn "${CFG[GRAFANA_SUBDOMAIN]}"))" v_sub
            ask_valid PROMETHEUS_SUBDOMAIN "Prometheus name (-> $(fqdn "${CFG[PROMETHEUS_SUBDOMAIN]}"))" v_sub
            ask_valid GRAFANA_PORT "Direct Grafana port (- for proxy only)" v_port_opt
            ask_valid PROMETHEUS_PORT "Direct Prometheus port (- for proxy only)" v_port_opt
            ask_valid NODEEXP_PORT "Node exporter port (- for none)" v_port_opt
            ask_valid BLACKBOX_PORT "Blackbox exporter port (- for none)" v_port_opt
            ask_valid SPEEDTEST_PORT "Speedtest exporter port (- for none)" v_port_opt
            ask_valid PROMETHEUS_RETENTION "Metrics retention (e.g. 90d)" v_retention
            ask_valid GRAFANA_PLUGINS "Grafana plugins, comma-separated (- for none)" v_any
            ask_valid GRAFANA_EXTRA_ENV "Extra GF_* settings, K=V;K=V (- to clear)" v_kv ;;
        guacamole)
            ask_valid GUACAMOLE_IMAGE "Guacamole image" v_image
            ask_valid GUACD_IMAGE "guacd image" v_image
            ask_valid GUAC_POSTGRES_IMAGE "PostgreSQL image (keep the major version once data exists)" v_image
            ask_valid GUACAMOLE_SUBDOMAIN "Name (-> $(fqdn "${CFG[GUACAMOLE_SUBDOMAIN]}"))" v_sub
            ask_valid GUACAMOLE_TLS_PORT "Extra HTTPS port served by the dashboard (- for none)" v_port_opt ;;
        meshcentral)
            ask_valid MESHCENTRAL_IMAGE "Image" v_image
            ask_valid MESHCENTRAL_SUBDOMAIN "Name (-> $(fqdn "${CFG[MESHCENTRAL_SUBDOMAIN]}"))" v_sub
            ask_valid MESHCENTRAL_PORT "Direct HTTPS port, used by agents (- for none)" v_port_opt ;;
        gvm)
            log_info "Greenbone needs ~8 GB RAM and a long first feed sync. It uses Greenbone's own compose file."
            ask_valid GVM_SUBDOMAIN "Name (-> $(fqdn "${CFG[GVM_SUBDOMAIN]}"))" v_sub
            ask_valid GVM_COMPOSE_URL "compose.yaml URL" v_url ;;
    esac
}

config_summary() {
    local k
    section "Current settings"
    for k in "${CONF_KEYS[@]}"; do printf '  %-22s %s\n' "$k" "${CFG[$k]:-${D}(empty)${NC}}"; done
}

detect_defaults() {
    [[ -f "$CONF_FILE" ]] && return 0
    if [[ -z "${CFG[UPDATE_DELEGATE]}" && -x /usr/local/sbin/mediastack-installer ]]; then
        CFG[UPDATE_DELEGATE]="mediastack=/usr/local/sbin/mediastack-installer --apply --yes"
        log_info "Found mediastack-installer: MediaStack updates will be delegated to it."
    fi
    return 0
}

cfg_apps_toggle() {
    section "Apps"
    local a ans
    for a in "${APPS[@]}"; do
        ans=${CFG[APP_${a^^}]}
        ask ans "Install ${APP_TITLE[$a]}? (yes/no)" "$ans"
        [[ "$ans" =~ ^(yes|no)$ ]] || ans=no
        CFG[APP_${a^^}]=$ans
    done
}

config_wizard() {
    log_step "Settings"
    ensure_config
    detect_defaults
    cfg_page; cfg_apps_toggle
    if is_tty && (( ! ASSUME_YES )) && confirm "Review per-app settings (images, names, ports)?" n; then
        local a; for a in $(enabled_apps); do cfg_app "$a"; done
    fi
    cfg_ports; cfg_cert; cfg_files; cfg_health; cfg_updates; cfg_paths
    config_summary
    confirm "Save these settings?" y || die "Cancelled; nothing saved."
    save_config
}

menu_settings() {
    ensure_config
    while :; do
        printf '\n  %sSettings%s  (%s)\n' "$B" "$NC" "$CONF_FILE"
        printf '   1) Page, domain, host   2) Dashboard ports   3) Certificate\n'
        printf '   4) File share   5) Health checks   6) Container updates   7) Paths and image\n'
        printf '   V) View   S) Save   A) Save + apply   0) Back (unsaved changes are discarded)\n'
        local ch; read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            1) cfg_page ;; 2) cfg_ports ;; 3) cfg_cert ;; 4) cfg_files ;;
            5) cfg_health ;; 6) cfg_updates ;; 7) cfg_paths ;;
            v) config_summary ;;
            s) save_config ;;
            a) save_config; menu_action stack_apply ;;
            0|q) load_config; return 0 ;;
            *) printf '  %sInvalid choice%s\n' "$R" "$NC" ;;
        esac
    done
}

menu_apps() {
    ensure_config
    local i a ch
    while :; do
        printf '\n  %sApps%s\n' "$B" "$NC"
        for i in "${!APPS[@]}"; do
            a=${APPS[$i]}
            printf '   %d) %-44s %b\n' "$((i + 1))" "${APP_TITLE[$a]}" "$(app_on "$a" && echo "${G}on${NC}" || echo "${D}off${NC}")"
        done
        printf '   C) Custom apps (%s)\n' "$(custom_names | wc -l)"
        printf '\n   T) Toggle on/off   E) Edit settings   S) Save   A) Save + apply   0) Back (unsaved changes are discarded)\n'
        read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            c) menu_custom ;;
            t|e) read -rp "  App number: " i || continue
                 [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#APPS[@]} )) || { log_warn "No such app"; continue; }
                 a=${APPS[$((i - 1))]}
                 if [[ "${ch,,}" == t ]]; then
                     if app_on "$a"; then CFG[APP_${a^^}]=no; log_info "${APP_TITLE[$a]}: off (containers stop on apply; data is kept)"
                     else CFG[APP_${a^^}]=yes; log_info "${APP_TITLE[$a]}: on"; fi
                 else cfg_app "$a"; fi ;;
            s) save_config ;;
            a) save_config; menu_action stack_apply ;;
            0|q) load_config; return 0 ;;
            *) printf '  %sInvalid choice%s\n' "$R" "$NC" ;;
        esac
    done
}

menu_secrets() {
    ensure_config; load_secrets
    local k ch v
    while :; do
        printf '\n  %sSecrets%s  (%s)\n' "$B" "$NC" "$SECRETS_FILE"
        for k in "${SECRET_KEYS[@]}"; do printf '   %-24s %s\n' "$k" "$(secret_is_set "$k" && echo set || echo "${D}not set${NC}")"; done
        printf '\n   R) Reveal one   C) Change one   0) Back\n'
        read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            r) read -rp "  Name: " k || continue; in_list "$k" "${SECRET_KEYS[@]}" || { log_warn "Unknown"; continue; }
               printf '  %s = %s\n' "$k" "${SECRETS[$k]:-}" ;;
            c) read -rp "  Name: " k || continue; in_list "$k" "${SECRET_KEYS[@]}" || { log_warn "Unknown"; continue; }
               log_info "Pi-hole and the Guacamole database follow the stored value; Grafana/GVM admin passwords are changed in their UI."
               read -rsp "  New value (empty = generate): " v || true; echo
               v=${v:-$(gen_password)}
               if [[ "$k" == GUAC_DB_PASSWORD ]] && docker ps -q --filter name='^guacamole-postgres$' | grep -q .; then
                   printf 'ALTER USER "%s" WITH PASSWORD :%s;\n' "${CFG[GUAC_DB_USER]}" "'pw'" | guac_psql -v pw="$v" >/dev/null \
                       || { log_error "Could not change the password in PostgreSQL; vault not changed."; continue; }
                   log_ok "PostgreSQL user password changed (apply restarts Guacamole with it)"
               fi
               SECRETS[$k]=$v; save_secrets ;;
            0|q) return 0 ;;
        esac
    done
}

menu_cert() {
    ensure_config
    printf '\n  %sCertificate%s (%s)\n   1) Refresh now (fetch/re-read, reload if changed)\n   2) Create / show fetch SSH key\n   3) Show certificate\n   0) Back\n' "$B" "$NC" "${CFG[CERT_MODE]}"
    local ch; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) menu_action cert_refresh ;;
        2) menu_action cert_fetch_key ;;
        3) openssl x509 -in "$DEPLOY_DIR/certs/dashboard.crt" -noout -subject -issuer -enddate -ext subjectAltName 2>&1 | sed 's/^/  /' ;;
    esac
}

# -----------------------------------------------------------------------------
# FULL INSTALL
# -----------------------------------------------------------------------------
full_install() {
    log_step "Full install / reconfigure ($SCRIPT_NAME v$SCRIPT_VERSION)"
    load_config
    preflight
    install_docker
    ensure_docker_group
    [[ -n "$IMPORT_FILE" ]] && import_stage "$IMPORT_FILE"
    config_wizard
    host_prepare
    check_ports            # before any data is written, so a conflict leaves nothing half-done
    [[ -n "$IMPORT_FILE" ]] && import_data
    stack_apply pull
    print_summary
}

print_summary() {
    log_step "Done"
    log_info "Dashboard:        $(dashboard_url)"
    log_info "Manage:           sudo docker-dashboard        (menu)"
    log_info "Update all:       sudo docker-dashboard --update-all"
    [[ "${CFG[CERT_MODE]}" == selfsigned ]] && log_info "Browsers will warn once about the self-signed certificate."
    dns_records
    app_on gvm && log_info "Greenbone: the first feed sync takes a long time. Then set its admin password: sudo docker-dashboard --gvm-password"
    return 0
}

host_now() { ensure_config; host_health ""; }   # report + refresh the page data

gvm_password() {
    require_config; load_secrets
    app_on gvm || die "Greenbone is not enabled."
    log_step "Set the Greenbone admin password (from the vault)"
    compose_app gvm exec -T -u gvmd gvmd gvmd --user=admin --new-password="${SECRETS[GVM_ADMIN_PASSWORD]}" \
        || die "gvmd is not ready yet (first start can take a while); try again later."
    log_ok "Greenbone login: admin / (Secrets menu -> GVM_ADMIN_PASSWORD)"
}

# -----------------------------------------------------------------------------
# UNINSTALL
# -----------------------------------------------------------------------------
uninstall_dashboard() {
    require_config; load_secrets
    log_step "Uninstall docker-dashboard"
    safe_path "$DEPLOY_DIR" || die "Refusing: unsafe dashboard path '$DEPLOY_DIR' in config."
    printf '  This will:\n'
    printf '   - stop and remove the dashboard and every app container this script manages\n'
    printf '   - remove the health/update/certificate timers and delete %s\n' "$DEPLOY_DIR"
    printf '  App data in %s is kept unless you ask below. Other containers are not touched.\n\n' "$STACKS_DIR"
    confirm_typed UNINSTALL || { log_info "Cancelled"; return 0; }
    local a
    for a in "${APPS[@]}"; do app_down "$a" "uninstall"; done
    for a in $(custom_names); do custom_down "$a" "uninstall"; done
    if docker_up && [[ -f "$DEPLOY_DIR/docker-compose.yml" ]]; then run_logged compose_dd down || log_warn "compose down reported errors"; fi
    docker network inspect "$PROXY_NET" >/dev/null 2>&1 && run docker network rm "$PROXY_NET" >/dev/null 2>&1 || true
    CFG[HEALTH_CHECK]=no; CFG[UPDATE_SCHEDULE]=off
    unit_set "$UNIT_HEALTH" no "" ""; unit_set "$UNIT_UPDATE" no "" ""; unit_set "$UNIT_CERT" no "" ""; unit_set_path "$UNIT_CERT" no "" ""
    run rm -rf -- "$DEPLOY_DIR"
    log_ok "Dashboard and app containers removed"
    restore_resolved_stub
    if [[ -d "$STACKS_DIR" ]] && is_tty && confirm "Also DELETE all app data in $STACKS_DIR (Pi-hole, Grafana, Guacamole DB, ...)?" n; then
        safe_path "$STACKS_DIR" || die "Refusing: unsafe apps path '$STACKS_DIR'."
        if confirm_typed DELETE-DATA; then run rm -rf -- "$STACKS_DIR"; log_ok "App data deleted"; else log_info "App data kept"; fi
    else
        log_info "App data kept in $STACKS_DIR"
    fi
    if confirm "Remove settings, encrypted secrets and state ($DD_CONF_DIR, $DD_STATE_DIR)? Keep them to reinstall as-is." n; then
        run rm -rf -- "$DD_CONF_DIR" "$DD_STATE_DIR"
        [[ "$SCRIPT_PATH" != "$DD_INSTALL_BIN" ]] && run rm -f "$DD_INSTALL_BIN"
        log_ok "Settings, secrets and state removed"
    else
        run rm -f "$DD_STATE_DIR/deployed" "$DD_STATE_DIR/cert_applied"
        log_info "Settings kept in $DD_CONF_DIR (reinstall with menu 5 / --apply)"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# LOGS
# -----------------------------------------------------------------------------
menu_logs() {
    printf '\n  %sLogs%s\n  1) List run logs\n  2) Latest update log\n  3) Previous run log\n  4) One container (last 200 lines)\n  5) Timer journal\n  0) Back\n' "$B" "$NC"
    local ch f c; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) ls -1t "$DD_LOG_DIR"/run-*.log 2>/dev/null | head -n "$LOG_KEEP" | sed 's/^/  /' ;;
        2) f=$(ls -1t "$DD_LOG_DIR"/run-update-*.log 2>/dev/null | head -n1)
           if [[ -n "$f" ]]; then ${PAGER:-less} "$f"; else log_info "No update runs logged yet."; fi ;;
        3) f=$(ls -1t "$DD_LOG_DIR"/run-*.log 2>/dev/null | sed -n 2p); [[ -n "$f" ]] && ${PAGER:-less} "$f" ;;
        4) ask c "Container name" "$CONTAINER_NAME"; docker logs --tail 200 "$c" 2>&1 | ${PAGER:-less} ;;
        5) journalctl -u "$UNIT_UPDATE.service" -u "$UNIT_HEALTH.service" -u "$UNIT_CERT.service" -n 200 --no-pager 2>/dev/null | ${PAGER:-less} ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# SELF-TEST (no root, no network, no Docker needed)
# -----------------------------------------------------------------------------
self_test() {
    log_step "Self-test ($SCRIPT_NAME v$SCRIPT_VERSION)"
    local pass=0 fail=0 t
    t=$(mktemp -d)
    st() { if eval "$2" >/dev/null 2>&1; then printf '  %s[PASS]%s %s\n' "$G" "$NC" "$1"; pass=$((pass + 1)); else printf '  %s[FAIL]%s %s\n' "$R" "$NC" "$1"; fail=$((fail + 1)); fi; }
    local have_py=0 have_yaml=0
    command -v python3 >/dev/null 2>&1 && have_py=1
    (( have_py )) && python3 -c "import yaml" 2>/dev/null && have_yaml=1
    # a fully populated config for the renderers
    allcfg() { set_default_config; CFG[DOMAIN]=example.net; CFG[HOST_ADDR]=192.168.0.190; DET_IP=10.9.9.9
               local a; for a in "${APPS[@]}"; do CFG[APP_${a^^}]=yes; done; CFG[APP_GVM]=no; SVC_GROUP=(); SVC_NAME=(); SVC_URL=(); SVC_DESC=()
               SECRETS=([PIHOLE_PASSWORD]=x [GRAFANA_ADMIN_PASSWORD]=y [GUAC_DB_PASSWORD]=z); }

    st "bash syntax"                        'bash -n "$SCRIPT_PATH"'
    st "version is semver"                  '[[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
    st "conf quote round-trip"              "[[ \"\$(conf_unquote \"\$(conf_quote \"it's \\\$x\")\")\" == \"it's \\\$x\" ]]"
    st "json_str escapes"                   '[[ "$(json_str "a\"b\\c<d>")" == "\"a\\\"b\\\\c\\u003cd\\u003e\"" ]]'
    st "yaml_str escapes \$ for compose"    '[[ "$(yaml_str "p\$w\"d")" == "\"p\$\$w\\\"d\"" ]]'
    st "kv_pairs parsing"                   '[[ "$(kv_pairs "A=1; B_2=x=y ;bad key=3" | tr "\t\n" ":|")" == "A:1|B_2:x=y|" ]]'
    st "url / field / port validators"      'valid_url "https://h.lan/#/" && ! valid_url ftp://x && valid_field "a b" && ! valid_field "a|b" && valid_port 53 && ! valid_port 0'
    st "ipv4/hostname/domain validators"    'valid_ipv4 192.168.0.190 && ! valid_ipv4 300.1.1.1 && v_domain_opt certifiedgeeks.net && ! v_domain_opt localhost && v_sub grafana && ! v_sub Graf_ana'
    st "fetch source validator"             'v_fetchsrc "root@192.168.0.1:/var/etc/acme/x" && v_fetchsrc "" && ! v_fetchsrc "host:/x" && ! v_fetchsrc "u@h:rel"'
    st "kv validator"                       'v_kv "FTLCONF_dns_listeningMode=all;FTLCONF_x=1" && v_kv "" && ! v_kv "1A=x" && ! v_kv "A=it'"'"'s"'
    st "safe_path guards"                   '! safe_path / && ! safe_path /opt && ! safe_path /home/u && safe_path /opt/stacks'
    printf '# c\nServices | Grafana | http://h:3030/ | Dashboards\n\nTools|Portainer|https://h:9443/|\nbad line\n' >"$t/s.conf"
    st "custom links file parse"            '( SERVICES_FILE="$t/s.conf"; load_services 2>/dev/null; [[ ${#SVC_NAME[@]} == 2 && "${SVC_GROUP[1]}" == Tools ]] )'
    st "app endpoints use subdomains"       '( allcfg; [[ "$(all_endpoints | cut -d"|" -f1 | xargs)" == "pihole portainer grafana prometheus guacamole meshcentral" ]] )'
    st "empty endpoint fields stay in place" '( allcfg; IFS="|" read -r k t s u f fb d < <(app_endpoints monitoring | sed -n 2p); [[ "$k" == prometheus && -z "$f" && "$fb" == http://192.168.0.190:9090/ && "$d" == Metrics* ]] )'
    st "endpoint url: domain vs fallback"   '( allcfg; [[ "$(endpoint_url grafana http://x:3030/)" == https://grafana.example.net/ ]] && CFG[DOMAIN]="" && [[ "$(endpoint_url grafana http://x:3030/)" == http://x:3030/ ]] )'
    st "https port kept in links"           '( allcfg; CFG[HTTPS_PORT]=8444; [[ "$(dashboard_url)" == https://dashboard.example.net:8444/ ]] )'
    st "nginx: one server per endpoint"     '( allcfg; c=$(render_nginx); [[ $(grep -c "server_name .*\.example\.net;" <<<"$c") == 6 ]] )'
    st "nginx: pihole / -> /admin/"         '( allcfg; c=$(render_nginx | sed -n "/server_name pihole/,/^}/p"); [[ "$c" == *"location = / { return 302 /admin/; }"* ]] )'
    st "nginx: tls upstream + websockets"   '( allcfg; c=$(render_nginx | sed -n "/server_name portainer/,/^}/p"); [[ "$c" == *"proxy_ssl_verify off"* && "$c" == *"Connection \$connection_upgrade"* && "$c" == *"client_max_body_size 0"* ]] )'
    st "nginx: guacamole legacy port"       '( allcfg; c=$(render_nginx); [[ "$c" == *"listen 8443 ssl;"* ]] && CFG[GUACAMOLE_TLS_PORT]=""; c=$(render_nginx); [[ "$c" != *"listen 8443"* ]] )'
    st "nginx: resolver for docker DNS"     '( allcfg; c=$(render_nginx); [[ "$c" == *"resolver 127.0.0.11"* ]] )'
    st "nginx: braces balanced"             '( allcfg; CFG[FILES_DIR]=/x; c=$(render_nginx); [[ $(tr -cd "{" <<<"$c" | wc -c) == $(tr -cd "}" <<<"$c" | wc -c) ]] )'
    st "nginx: no domain -> no app servers" '( allcfg; CFG[DOMAIN]=""; [[ $(render_nginx | grep -c "server_name .*\.") == 0 ]] )'
    st "nginx: files on https + http"       '( allcfg; CFG[FILES_DIR]=/srv/web; c=$(render_nginx); [[ $(grep -c "location /files/ {" <<<"$c") == 2 ]] )'
    st "dashboard compose maps 8443"        '( allcfg; c=$(render_compose); [[ "$c" == *"\"8443:8443\""* && "$c" == *"external: true"* ]] && CFG[APP_GUACAMOLE]=no && [[ "$(render_compose)" != *8443* ]] )'
    st "pihole: password only if managed"   '( allcfg; [[ "$(render_app_pihole)" == *PIHOLE_PASSWORD* ]] && unset "SECRETS[PIHOLE_PASSWORD]" && [[ "$(render_app_pihole)" != *PIHOLE_PASSWORD* ]] )'
    st "pihole: extra env + no web port"    '( allcfg; CFG[PIHOLE_WEB_PORT]=""; c=$(render_app_pihole); [[ "$c" == *"FTLCONF_dns_listeningMode: \"all\""* && "$c" != *":80/tcp"* && "$c" == *"\"53:53/udp\""* ]] )'
    st "monitoring: blank port unpublished" '( allcfg; CFG[NODEEXP_PORT]=""; c=$(render_app_monitoring); [[ "$c" != *"9100\""* && "$c" == *"\"3030:3000\""* && "$c" == *"GF_SERVER_ROOT_URL: \"https://grafana.example.net/\""* ]] )'
    st "guacamole: 1.6 env + secret ref"    '( allcfg; c=$(render_app_guacamole); [[ "$c" == *POSTGRESQL_USERNAME* && "$c" == *"\${GUAC_DB_PASSWORD:?err}"* && "$c" == *"WEBAPP_CONTEXT: \"ROOT\""* ]] )'
    st "meshcentral: agents port -> 443"    '( allcfg; [[ "$(render_app_meshcentral)" == *"\"3000:443\""* ]] )'
    st "gvm override drops host ports"      '( allcfg; c=$(render_app_gvm_override); [[ "$c" == *"ports: !reset []"* && "$c" == *gvm-web* ]] )'
    if (( have_yaml )); then
        st "all app compose files are YAML" '( allcfg; for a in pihole portainer monitoring guacamole meshcentral; do "render_app_$a" | python3 -c "import yaml,sys; d=yaml.safe_load(sys.stdin); assert d[\"networks\"][\"dd-proxy\"][\"external\"]" || exit 1; done; render_compose | python3 -c "import yaml,sys; yaml.safe_load(sys.stdin)" )'
    fi
    if (( have_py )); then
        st "services.json valid, apps first" '( allcfg; SVC_GROUP=(Links); SVC_NAME=("A\"b"); SVC_URL=(http://x/); SVC_DESC=(d); render_services_json | python3 -c "import json,sys; d=json.load(sys.stdin); g=d[\"groups\"]; assert g[0][\"name\"]==\"Apps\" and len(g[0][\"items\"])==6 and g[0][\"items\"][2][\"alt\"]==\"http://192.168.0.190:3030/\" and g[1][\"items\"][0][\"name\"]==\"A\\\"b\"" )'
        st "services.json valid when empty"  '( set_default_config; DET_IP=1.2.3.4; SVC_NAME=(); SVC_GROUP=(); SVC_URL=(); SVC_DESC=(); render_services_json | python3 -c "import json,sys; assert json.load(sys.stdin)[\"groups\"]==[]" )'
        st "status.json is valid JSON"       'printf "http://a/\t200\t0.012\nhttps://b/\t000\t0\n" | render_status_json | python3 -c "import json,sys; r=json.load(sys.stdin)[\"results\"]; assert r[\"http://a/\"][\"ms\"]==12 and r[\"https://b/\"][\"state\"]==\"down\""'
    fi
    st "health targets go via local proxy"  '( allcfg; [[ "$(health_targets | head -1)" == "https://pihole.example.net/	pihole.example.net" ]] )'
    st "dns hosts list"                     '( allcfg; l=$(render_dns_hosts); [[ $(wc -l <<<"$l") == 7 && "$l" == "192.168.0.190 dashboard.example.net"* ]] )'
    st "host ports per app"                 '( allcfg; [[ "$(app_host_ports pihole | cut -f1 | xargs)" == "53/tcp 53/udp 8081/tcp" && "$(app_host_ports guacamole | cut -f1)" == 8443/tcp ]] )'
    st "port parser skips own projects"     '[[ "$(printf "pihole\t0.0.0.0:53->53/udp, 0.0.0.0:80->80/tcp\tpi-hole\npihole2\t0.0.0.0:53->53/udp\tdd-pihole\ndocker-dashboard\t0.0.0.0:80->80/tcp\tdocker-dashboard\n" | docker_ps_port_users 53 udp | xargs)" == pihole ]]'
    st "port parser respects protocol"      '[[ -z "$(printf "x\t0.0.0.0:53->53/udp\tp\n" | docker_ps_port_users 53 tcp)" ]]'
    st "cert SANs include wildcard"         '( set_default_config; CFG[DOMAIN]=example.net; s=$(cert_sans 192.168.0.190 "docker01.lan"); [[ "$s" == "IP:192.168.0.190,DNS:*.example.net,DNS:example.net,"* && "$s" == *"DNS:docker01.lan" ]] )'
    st "image version compare"              'image_version_ge guacamole/guacamole:1.6.0 1.6 && image_version_ge x/y:latest 1.6 && image_version_ge x/y 1.6 && ! image_version_ge g/g:1.5.5 1.6 && image_version_ge g/g:2.0 1.6'
    st "image_repo normalises names"        '[[ "$(image_repo docker.io/library/Postgres:13.4)" == postgres && "$(image_repo pihole/pihole@sha256:ab)" == pihole/pihole && "$(image_repo reg:5000/a/b:1)" == reg:5000/a/b ]]'
    st "OnCalendar daily/weekly"            '[[ "$(render_oncalendar daily Sun 04:00)" == "*-*-* 04:00:00" && "$(render_oncalendar weekly Sat 23:15)" == "Sat *-*-* 23:15:00" ]]'
    st "delegate lookup"                    '( CFG[UPDATE_DELEGATE]="mediastack=/usr/local/sbin/mediastack-installer --apply --yes; foo=/bin/true"; [[ "$(delegate_for foo)" == /bin/true && -z "$(delegate_for bar)" ]] )'
    st "exclusion by name or project"       '( CFG[UPDATE_EXCLUDE]="pihole, mediastack"; is_excluded pihole && is_excluded radarr mediastack && ! is_excluded grafana other )'
    st "write_file flags changes only"      '( DRY_RUN=0; WROTE=0; write_file "$t/w" 644 "$(id -u):$(id -g)" <<<a; w1=$WROTE; WROTE=0; write_file "$t/w" 644 "$(id -u):$(id -g)" <<<a; w2=$WROTE; [[ $w1 == 1 && $w2 == 0 ]] )'
    st "secrets round-trip (openssl)"       '( DD_CONF_DIR="$t/conf"; SECRETS_FILE="$t/conf/s.enc"; KEY_FILE="$t/conf/.k"; CFG[SECRETS_BACKEND]=openssl; DRY_RUN=0; LOG_FILE=""
                                               SECRETS=([GUAC_DB_PASSWORD]="p@ss'"'"'w\"rd \$x"); save_secrets && SECRETS=() && SECRETS_LOADED=0 && load_secrets &&
                                               [[ "${SECRETS[GUAC_DB_PASSWORD]}" == "p@ss'"'"'w\"rd \$x" ]] && ! grep -q "p@ss" "$SECRETS_FILE" )'
    st "manifest lines only set known keys" '( set_default_config; apply_cfg_line "APP_PIHOLE='"'"'yes'"'"'"; apply_cfg_line "EVIL='"'"'x'"'"'"; [[ "${CFG[APP_PIHOLE]}" == yes && -z "${CFG[EVIL]:-}" ]] )'
    st "resolved stub freed and restored"   '( DRY_RUN=0; ASSUME_YES=1; LOG_FILE=""; DD_STATE_DIR="$t/state"; DD_RESOLVED_DIR="$t/rd"; DD_RESOLV_CONF="$t/resolv.conf"; DD_RESOLVED_UPSTREAM="$t/run/upstream"
                                               mkdir -p "$t/run"; printf "nameserver 127.0.0.53\n" >"$t/run/stub"; printf "nameserver 192.168.0.243\n" >"$DD_RESOLVED_UPSTREAM"; ln -s "$t/run/stub" "$DD_RESOLV_CONF"
                                               systemctl() { :; }; sleep() { :; }; host_dns_ok() { :; }; resolved_stub_active() { false; }
                                               free_resolved_stub && grep -qx "DNSStubListener=no" "$t/rd/docker-dashboard-no-stub.conf" && [[ "$(readlink "$DD_RESOLV_CONF")" == "$DD_RESOLVED_UPSTREAM" ]] &&
                                               restore_resolved_stub quiet && [[ ! -f "$t/rd/docker-dashboard-no-stub.conf" && "$(readlink "$DD_RESOLV_CONF")" == "$t/run/stub" ]] )'
    st "resolved stub rolled back on DNS failure" '( DRY_RUN=0; ASSUME_YES=1; LOG_FILE=""; DD_STATE_DIR="$t/s2"; DD_RESOLVED_DIR="$t/rd2"; DD_RESOLV_CONF="$t/resolv2.conf"
                                               ln -s "$t/run/stub" "$DD_RESOLV_CONF"; systemctl() { :; }; sleep() { :; }; host_dns_ok() { false; }
                                               ! ( free_resolved_stub ) && [[ ! -f "$t/rd2/docker-dashboard-no-stub.conf" && "$(readlink "$DD_RESOLV_CONF")" == "$t/run/stub" ]] )'
    st "custom app conf round-trip"         '( DRY_RUN=0; STACKS_DIR="$t/stacks"; custom_defaults hp; CA[TITLE]="HP Switches"; CA[SERVICE]=web; CA[PORT]=8443; CA[TLS]=yes; CA[SUBDOMAIN]=switches
                                               custom_save hp && touch "$t/stacks/custom/hp/compose.yaml" && CA=() && custom_load hp && [[ "${CA[TITLE]}" == "HP Switches" && "${CA[PORT]}" == 8443 ]] && [[ "$(enabled_customs)" == hp ]] )'
    st "custom app endpoint record"         '( allcfg; STACKS_DIR="$t/stacks"; IFS="|" read -r k ti su up fl fb de < <(custom_endpoint hp); [[ "$k" == c-hp && "$su" == switches && "$up" == https://dd-c-hp:8443 && "$fl" == ws,tls ]] )'
    st "custom app proxied, linked, in DNS" '( allcfg; STACKS_DIR="$t/stacks"; c=$(render_nginx); [[ "$c" == *"server_name switches.example.net;"* && "$c" == *"set \$upstream https://dd-c-hp:8443;"* ]] && [[ "$(render_dns_hosts)" == *switches.example.net* ]] && [[ "$(render_services_json)" == *"HP Switches"* ]] )'
    st "custom app off -> not proxied"      '( allcfg; STACKS_DIR="$t/stacks"; DRY_RUN=0; custom_load hp; CA[ENABLED]=no; custom_save hp; [[ "$(render_nginx)" != *switches* ]] )'
    st "custom app name clash rejected"     '( allcfg; STACKS_DIR="$t/stacks"; DRY_RUN=0; docker_up() { false; }; custom_load hp; CA[ENABLED]=yes; CA[SUBDOMAIN]=grafana; custom_save hp; ! custom_validate hp )'
    st "custom app needs service + port"    '( allcfg; STACKS_DIR="$t/stacks"; DRY_RUN=0; docker_up() { false; }; custom_load hp; CA[SUBDOMAIN]=switches; CA[PORT]=x; custom_save hp; ! custom_validate hp; CA[PORT]=8443; CA[UPSTREAM_URL]=""; custom_save hp; custom_validate hp )'
    st "custom: docker-compose.yml accepted" '( STACKS_DIR="$t/s3"; mkdir -p "$t/s3/custom/hp1810-dashboard"; touch "$t/s3/custom/hp1810-dashboard/docker-compose.yml"; [[ "$(custom_compose_file hp1810-dashboard)" == docker-compose.yml ]] && touch "$t/s3/custom/hp1810-dashboard/compose.yaml" && [[ "$(custom_compose_file hp1810-dashboard)" == compose.yaml ]] )'
    st "custom: folders without app.conf"   '( STACKS_DIR="$t/s4"; mkdir -p "$t/s4/custom/"{a,b,c}; touch "$t/s4/custom/a/docker-compose.yml" "$t/s4/custom/b/compose.yaml" "$t/s4/custom/b/app.conf"; [[ "$(custom_unconfigured | xargs)" == a && "$(custom_names | xargs)" == b ]] )'
    st "custom: external app project"       '( STACKS_DIR="$t/s5"; mkdir -p "$t/s5/custom/hp"; printf "MANAGED='"'"'no'"'"'\nPROJECT='"'"'hp1810-dashboard'"'"'\n" >"$t/s5/custom/hp/app.conf"; touch "$t/s5/custom/hp/docker-compose.yml"
                                               [[ "$(custom_project hp)" == hp1810-dashboard ]] && ! custom_managed hp && [[ "$(custom_external_projects)" == hp1810-dashboard ]] && ! is_own_project hp1810-dashboard && [[ -z "$(custom_managed_projects)" ]] )'
    st "external project check (pipefail)"   '( set -o pipefail; STACKS_DIR="$t/s7"; for i in 1 2 3; do mkdir -p "$t/s7/custom/a$i"; printf "MANAGED='"'"'no'"'"'\nPROJECT='"'"'p$i'"'"'\n" >"$t/s7/custom/a$i/app.conf"; done
                                               mkdir -p "$t/s7/custom/m"; printf "PROJECT='"'"'mp'"'"'\n" >"$t/s7/custom/m/app.conf"; touch "$t/s7/custom/m/compose.yaml"
                                               is_own_project mp && ! is_own_project p1 && e=$(custom_external_projects) && [[ $'"'"'\n'"'"'"$e"$'"'"'\n'"'"' == *$'"'"'\n'"'"'p1$'"'"'\n'"'"'* ]] )'
    st "custom: adopted managed project"    '( STACKS_DIR="$t/s6"; mkdir -p "$t/s6/custom/hp"; printf "PROJECT='"'"'hp1810-dashboard'"'"'\n" >"$t/s6/custom/hp/app.conf"; touch "$t/s6/custom/hp/compose.yaml"
                                               custom_managed hp && is_own_project hp1810-dashboard && is_own_project dd-c-x && ! is_own_project other )'
    st "custom: project before app.conf"    '( custom_defaults hp; [[ "$(ca_project hp)" == dd-c-hp ]] && CA[PROJECT]=mine && [[ "$(ca_project hp)" == mine ]] )'
    st "candidates keep empty fields"       '( r=$(printf "netbox-lite${US}img${US}${US}${US}${US}0.0.0.0:8001->8000/tcp"); IFS=$US read -r c img proj svc wd ports <<<"$r"; [[ "$c" == netbox-lite && -z "$proj" && -z "$svc" && -z "$wd" && "$ports" == "0.0.0.0:8001->8000/tcp" ]] )'
    st "custom app names validated"         'valid_app_name hp-1810 && ! valid_app_name HP && ! valid_app_name -x && ! valid_app_name "a b"'
    st "compose json: no ports is fine"     '[[ -z "$(printf %s "{\"services\":{\"w\":{}}}" | compose_json_ports X)" ]]'
    st "compose json ports parsed"          '[[ "$(printf %s "{\"services\":{\"w\":{\"ports\":[{\"mode\":\"ingress\",\"target\":443,\"published\":\"8444\",\"protocol\":\"tcp\"},{\"target\":53,\"published\":\"5353\",\"protocol\":\"udp\"}]}}}" | compose_json_ports X | cut -f1 | xargs)" == "8444/tcp 5353/udp" ]]'
    st "levels: thresholds and worst-of"    '[[ $(level_for 79 80 90) == ok && $(level_for 80 80 90) == warn && $(level_for 95 80 90) == crit && $(level_for 90 80 90) == crit && $(level_for 1.5 1.0 2.0) == warn && $(level_worst ok warn ok) == warn && $(level_worst ok crit warn) == crit && $(level_worst) == ok ]]'
    st "cpu % from /proc/stat samples"      '[[ "$(cpu_pct "1000 800" "1100 850")" == 50 && "$(cpu_pct "5 5" "5 5")" == 0 ]]'
    if (( have_py )); then
        st "host.json is valid JSON"        '( set_default_config; H_CORES=4; H_CPU=12; H_LOAD1=0.5; H_LOAD5=0.4; H_LOAD15=0.3; H_LOADPC=0.10; H_CPU_LVL=ok; H_MEM_T=8000000; H_MEM_U=6900000; H_MEM_P=86; H_MEM_LVL=warn
                                               H_SW_T=0; H_SW_U=0; H_SW_P=0; H_SW_LVL=ok; H_UP=93784; H_RUN=11; H_TOT=12; H_CT_LVL=warn; H_PROBLEMS=("pihole: unhealthy"); H_DISKS=$(printf "/	ext4	100	91	91
/data	xfs	200	20	10
"); H_DISK_LVL=crit
                                               render_host_json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"level\"]==\"crit\" and d[\"disks\"][0][\"level\"]==\"crit\" and d[\"memory\"][\"level\"]==\"warn\" and d[\"containers\"][\"problems\"]==[\"pihole: unhealthy\"]" )'
    fi
    st "page loads the host panel"          'render_index | grep -q "fetch(\"host.json\""'
    st "index.html loads nothing external"  '! render_index | grep -Eq "(src|href)=\"(https?:)?//"'
    rm -rf "$t"
    printf '\n  Result: %s%d passed%s, %s%d failed%s\n' "$G" "$pass" "$NC" "$( ((fail)) && echo "$R" || echo "$G")" "$fail" "$NC"
    _log_file SELFTEST "pass=$pass fail=$fail"
    [[ $fail -eq 0 ]]
}

# -----------------------------------------------------------------------------
# MENUS
# -----------------------------------------------------------------------------
menu_action() {   # run in a subshell so a failure returns to the menu
    local rc
    set +e
    ( set -e; "$@" )
    rc=$?
    set -e
    (( rc == 0 )) || log_warn "Action '$1' ended with rc=$rc (see $LOG_FILE)"
    return 0
}

show_banner() {
    load_config
    local cfg_state dash="docker not running" mode n=0
    [[ -f "$CONF_FILE" ]] && cfg_state="${G}configured${NC}" || cfg_state="${Y}not configured${NC}"
    if docker_up; then
        if docker ps -q --filter "name=^${CONTAINER_NAME}$" | grep -q .; then dash="${G}running${NC}"; else dash="${Y}not running${NC}"; fi
        n=$(docker ps -q | wc -l)
    fi
    (( DRY_RUN )) && mode="${Y}DRY-RUN${NC}" || mode="${G}LIVE${NC}"
    printf '\n  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  %s|%s  %sDocker Dashboard%s v%-8s    host: %-20s%s|%s\n' "$C" "$NC" "$B" "$NC" "$SCRIPT_VERSION" "$(hostname -s | cut -c1-20)" "$C" "$NC"
    printf '  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  Config: %b   Dashboard: %b   Containers: %s   Apps: %s   Mode: %b\n' "$cfg_state" "$dash" "$n" "$(enabled_apps | wc -l)" "$mode"
}

main_menu() {
    while :; do
        show_banner
        printf '\n  %sSetup%s\n' "$B" "$NC"
        printf '   1) Full install / reconfigure   2) Settings   3) Apps   4) Links (custom)   K) Secrets   C) Certificate\n'
        printf '  %sOperate%s\n' "$B" "$NC"
        printf '   5) Apply everything             (render, validate, start)\n'
        printf '   6) Update ALL containers        (apps, compose projects, docker-run containers)\n'
        printf '   7) Check for updates            (pull images, report, change nothing)\n'
        printf '   8) Status   9) Health check (links + host)   H) Host health   D) DNS records   L) Logs\n'
        printf '  %sMigrate%s\n' "$B" "$NC"
        printf '   E) Export this host to a bundle   I) Import a bundle\n'
        printf '  %sMaintenance%s\n' "$B" "$NC"
        printf '   X) Stop all   U) Uninstall...   T) Toggle dry-run   S) Self-test   0) Quit\n\n'
        local ch; read -rp "  Choice: " ch || exit 0
        case "${ch,,}" in
            1) menu_action full_install ;;
            2) menu_settings; continue ;;
            3) menu_apps; continue ;;
            4) menu_services; continue ;;
            k) menu_secrets; continue ;;
            c) menu_cert ;;
            5) menu_action stack_apply ;;
            6) menu_action update_all ;;
            7) menu_action check_updates ;;
            8) menu_action show_status ;;
            9) menu_action health_check ;;
            h) menu_action host_now ;;
            d) menu_action dns_records ;;
            l) menu_logs ;;
            e) menu_action export_bundle ;;
            i) local f; read -rp "  Bundle file: " f || continue
               IMPORT_FILE=$f; menu_action full_install; IMPORT_FILE="" ;;
            x) menu_action stack_stop ;;
            u) menu_action uninstall_dashboard ;;
            t) DRY_RUN=$(( 1 - DRY_RUN )); log_info "Dry-run is now $( ((DRY_RUN)) && echo ON || echo OFF)"; continue ;;
            s) menu_action self_test ;;
            0|q) printf '\n  %sGoodbye!%s\n\n' "$G" "$NC"; _log_file INFO "Session ended"; exit 0 ;;
            *) printf '  %sInvalid choice%s\n' "$R" "$NC"; sleep 1; continue ;;
        esac
        SECRETS_LOADED=0
        pause
    done
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION -- all-in-one Docker host installer, HTTPS dashboard and update-all manager

Usage: sudo $(basename "$SCRIPT_PATH") [options] [action]

Actions (default: interactive menu)
  --install [--import FILE]  Full install / reconfigure: Docker, settings, apps, proxy, page (optionally from a bundle)
  --apply                    Converge everything: app compose files, proxy config, page, timers; start/reload
  --stop                     Stop the dashboard and all managed apps (data kept)
  --update-all               Update every running container (managed apps, compose projects, docker-run containers)
  --check-updates            Pull newer images and report which containers are behind; change nothing
  --export                   On the OLD host: bundle app settings, secrets and data (encrypted)
  --health [--quiet]         Check every link now and refresh the page's status dots
  --status                   Show configuration, apps, timers and last update
  --dns-records              Print the DNS names the proxy serves (and Windows DNS commands)
  --host                     Host health now: CPU, memory, swap, disks, uptime, containers
  --custom-apps              Custom apps menu (your own compose apps behind the proxy)
  --cert-refresh             Fetch / re-read the certificate and reload nginx if it changed
  --cert-fetch-key           Create (or show) the SSH key used by certificate fetch mode
  --gvm-password             Set the Greenbone admin password from the vault
  --settings | --apps | --services | --secrets   Menus
  --list-services            Print the custom links
  --add-service 'G|N|URL|D'  Add a custom link: group | name | url | description
  --remove-service NAME      Remove custom link(s) with this name
  --detect                   Offer web ports of other running containers as custom links
  --uninstall                Remove dashboard, managed app containers and timers (keyword UNINSTALL)
  --self-test                Run built-in tests (no root needed)
  --version | -h, --help

Options
  --dry-run                  Show what would change; change nothing
  --yes                      Accept defaults for all prompts (non-interactive)
  --confirm KEYWORD          Pre-answer a typed confirmation (UNINSTALL, OVERWRITE, DELETE-DATA)
  --passphrase-file FILE     Bundle passphrase for --export / --import (first line)
  --no-metrics               --export: leave out Prometheus history (can be large)
  --leave-stopped            --export: do not restart the containers it stopped (for the final cutover)

Files
  $CONF_FILE       settings (0600)
  $SECRETS_FILE          encrypted secrets
  $SERVICES_FILE       custom links (group | name | url | description)
  /opt/stacks/<app>/                         app compose file + data (default STACKS_DIR)
  $DD_LOG_DIR/run-*.log   run logs (newest $LOG_KEEP kept)
EOF
}

check_root() {
    [[ $EUID -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "Run as root (sudo not found)."
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

acquire_lock() {   # acquire_lock FILE
    exec 9>"$1"
    flock -n 9 || die "Another $SCRIPT_NAME run is in progress ($1)."
}

main() {
    local action="menu" arg="" quiet=""; local -a orig=("$@")
    while (( $# )); do
        case "$1" in
            --install)         action=install ;;
            --import)          IMPORT_FILE=$(readlink -f "${2:-}"); [[ "$action" == menu ]] && action=install; shift ;;
            --apply)           action=apply ;;
            --stop)            action=stop ;;
            --update-all)      action=update ;;
            --check-updates)   action=check ;;
            --export)          action="export" ;;
            --health)          action=health ;;
            --quiet)           quiet=quiet ;;
            --status)          action=status ;;
            --dns-records)     action=dns ;;
            --host)            action=host ;;
            --custom-apps)     action=customs ;;
            --cert-refresh)    action=certrefresh ;;
            --cert-fetch-key)  action=certkey ;;
            --gvm-password)    action=gvmpw ;;
            --settings)        action=settings ;;
            --apps)            action=apps ;;
            --services)        action=services ;;
            --secrets)         action=secrets ;;
            --list-services)   action=listsvc ;;
            --add-service)     action=addsvc; arg=${2:-}; shift ;;
            --remove-service)  action=rmsvc; arg=${2:-}; shift ;;
            --detect)          action=detect ;;
            --uninstall)       action=uninstall ;;
            --self-test)       action=selftest ;;
            --dry-run)         DRY_RUN=1 ;;
            --yes|-y)          ASSUME_YES=1 ;;
            --confirm)         CONFIRM_KEYWORD=${2:-}; shift ;;
            --passphrase-file) PASSPHRASE_FILE=$(readlink -f "${2:-}"); shift ;;
            --no-metrics)      EXPORT_NO_METRICS=1 ;;
            --leave-stopped)   EXPORT_LEAVE_STOPPED=1 ;;
            --version)         echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            -h|--help)         usage; exit 0 ;;
            *)                 usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done

    if [[ "$action" == selftest ]]; then
        set_default_config
        if self_test; then exit 0; else exit 1; fi
    fi

    check_root "${orig[@]}"

    if [[ "$action" == health ]]; then   # timer: own lock, no run log
        acquire_lock "$DD_HEALTH_LOCK"
        health_check "$quiet"
        exit 0
    fi

    init_logging "$action"
    acquire_lock "$DD_LOCK_FILE"
    _log_file INFO "================================================"
    _log_file INFO "$SCRIPT_NAME v$SCRIPT_VERSION started action=$action dry_run=$DRY_RUN"
    _log_file INFO "User: $(id -un) (real: $REAL_USER)  PID: $$"
    _log_file INFO "================================================"

    case "$action" in
        menu)        is_tty || die "No terminal; use a CLI action (see --help)."; main_menu ;;
        install)     full_install ;;
        apply)       stack_apply ;;
        stop)        stack_stop ;;
        update)      update_all; _log_file INFO "Finished action=update failures=$UPDATE_FAILS"; (( UPDATE_FAILS == 0 )) || exit 1 ;;
        check)       check_updates ;;
        export)      export_bundle ;;
        status)      show_status ;;
        dns)         dns_records ;;
        host)        host_now ;;
        customs)     is_tty || die "Custom apps menu needs a terminal."; menu_custom ;;
        certrefresh) cert_refresh ;;
        certkey)     ensure_config; cert_fetch_key ;;
        gvmpw)       gvm_password ;;
        settings)    is_tty || die "Settings menu needs a terminal."; menu_settings ;;
        apps)        is_tty || die "Apps menu needs a terminal."; menu_apps ;;
        services)    is_tty || die "Links menu needs a terminal."; menu_services ;;
        secrets)     is_tty || die "Secrets menu needs a terminal."; menu_secrets ;;
        listsvc)     ensure_config; load_services; list_services ;;
        addsvc)
            ensure_config; load_services
            local g n u d; IFS='|' read -r g n u d <<<"$arg"
            g=$(trim "$g"); n=$(trim "$n"); u=$(trim "$u"); d=$(trim "$d")
            svc_index_by_url "$u" >/dev/null && die "A link to $u is already listed."
            svc_add "${g:-Links}" "$n" "$u" "$d" || die "Usage: --add-service 'Group|Name|https://host:port/|Description'"
            save_services; log_ok "Added '$n'"; publish_services ;;
        rmsvc)
            ensure_config; load_services
            local i found=0
            for (( i = ${#SVC_NAME[@]} - 1; i >= 0; i-- )); do
                [[ "${SVC_NAME[$i]}" == "$arg" ]] && { svc_remove "$i"; found=$((found + 1)); }
            done
            (( found )) || die "No custom link named '$arg'."
            save_services; log_ok "Removed $found link(s) named '$arg'"; publish_services ;;
        detect)      ensure_config; detect_network; load_services; detect_services; publish_services ;;
        uninstall)   uninstall_dashboard ;;
    esac
    _log_file INFO "Finished action=$action"
}

main "$@"
