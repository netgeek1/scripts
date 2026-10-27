#!/usr/bin/env bash
# =============================================================================
#  switch-dashboard-installer.sh
#  Installer and lifecycle manager for switch-dashboard: a port dashboard for HP 1810-8G and Netgear GS110TP switches (Docker)
#
#  Version   : SCRIPT_VERSION below is the authoritative version string
#  Changelog : CHANGELOG.md (per-version history)
#  Docs      : README.md
#  Author    : netgeek1 (Claude.ai)
#
#  Usage     : sudo ./switch-dashboard-installer.sh              interactive menu
#              sudo ./switch-dashboard-installer.sh --install    full install / reconfigure
#              sudo ./switch-dashboard-installer.sh --help       all CLI flags
#
#  Requires  : bash 4.4+, Ubuntu or Debian (amd64/arm64), root (re-execs via sudo)
#              Self-contained: the app source (Dockerfile + app/) is embedded at the end of
#              this file. Docker and other prerequisites are installed when missing.
#  License   : see LICENSE in the repository
# =============================================================================
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="switch-dashboard-installer"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

# -----------------------------------------------------------------------------
# PATHS (overridable via environment for testing; normal use leaves these alone)
# -----------------------------------------------------------------------------
HD_CONF_DIR="${HD_CONF_DIR:-/etc/switch-dashboard}"
HD_STATE_DIR="${HD_STATE_DIR:-/var/lib/switch-dashboard-installer}"
HD_LOG_DIR="${HD_LOG_DIR:-/var/log/switch-dashboard}"
HD_INSTALL_BIN="${HD_INSTALL_BIN:-/usr/local/sbin/switch-dashboard}"
HD_LOCK_FILE="${HD_LOCK_FILE:-/run/switch-dashboard-installer.lock}"

CONF_FILE="$HD_CONF_DIR/switch-dashboard.conf"
# Pre-2.0 installs were called hp1810-dashboard; migrate_legacy moves them over.
HD_LEGACY_CONF_DIR="${HD_LEGACY_CONF_DIR:-/etc/hp1810-dashboard}"
HD_LEGACY_STATE_DIR="${HD_LEGACY_STATE_DIR:-/var/lib/hp1810-dashboard-installer}"
HD_LEGACY_LOG_DIR="${HD_LEGACY_LOG_DIR:-/var/log/hp1810-dashboard}"
HD_LEGACY_BIN="${HD_LEGACY_BIN:-/usr/local/sbin/hp1810-dashboard}"
SECRETS_FILE="$HD_CONF_DIR/secrets.enc"
KEY_FILE="$HD_CONF_DIR/.secrets.key"
LOG_KEEP=20

readonly PROJECT_NAME="switch-dashboard"
readonly CONTAINER_PORT=8810
readonly CONTAINER_HTTP_PORT=8880
readonly PAYLOAD_MARK="__SWDASH_PAYLOAD__"
readonly PAYLOAD_END="__SWDASH_PAYLOAD_END__"   # payload sits in a never-executed heredoc (shellcheck-clean)
# Pinned defaults. Override with --set BASE_IMAGE ... / --set CRYPTOGRAPHY_VERSION ...
readonly DEFAULT_BASE_IMAGE="python:3.13-slim-bookworm"
readonly DEFAULT_CRYPTOGRAPHY_VERSION="50.0.2"

# -----------------------------------------------------------------------------
# CONFIG MODEL (host/container settings -> $CONF_FILE). App settings (switches,
# users, poll interval...) live in the container's data volume; see app_ctl.
# -----------------------------------------------------------------------------
CONF_KEYS=( INSTALL_DIR DATA_DIR BACKUP_DIR BACKUP_KEEP BIND_ADDRESS HOST_PORT HTTP_PORT CONTAINER_NAME IMAGE_NAME
            BASE_IMAGE CRYPTOGRAPHY_VERSION BUILD_NETWORK TIMEZONE SERVICE_USER SERVICE_UID SERVICE_GID
            RESTART_POLICY MEM_LIMIT LOG_MAX_SIZE LOG_MAX_FILE SECRETS_BACKEND )
declare -A CFG=()
declare -A CONF_HELP=(
    [INSTALL_DIR]="Build context + compose file location"
    [DATA_DIR]="Persistent data volume (config.json, audit log); owned by the service account"
    [BACKUP_DIR]="Where --backup writes archives"
    [BACKUP_KEEP]="Backup archives to keep (oldest pruned)"
    [BIND_ADDRESS]="Host address to publish on (0.0.0.0 = all, or one IP; 127.0.0.1 behind a proxy)"
    [HOST_PORT]="Host TCP port for the web UI (HTTPS)"
    [HTTP_PORT]="Host TCP port for plain HTTP, used when HTTP is set to redirect or on (empty = not published)"
    [CONTAINER_NAME]="Docker container name"
    [IMAGE_NAME]="Local image name (tag = app version)"
    [BASE_IMAGE]="Python base image (pin by tag or @sha256 digest)"
    [CRYPTOGRAPHY_VERSION]="Pinned 'cryptography' package version"
    [BUILD_NETWORK]="docker build network: default or host (host helps behind a local proxy)"
    [TIMEZONE]="Container timezone (audit timestamps)"
    [SERVICE_USER]="Service account the container runs as (nologin, not in docker group)"
    [SERVICE_UID]="Fixed UID for a new service account (empty = system-assigned)"
    [SERVICE_GID]="Fixed GID for a new service account (empty = system-assigned)"
    [RESTART_POLICY]="unless-stopped | always | on-failure | no"
    [MEM_LIMIT]="Container memory limit, e.g. 128m (empty = none)"
    [LOG_MAX_SIZE]="docker json-file log size before rotation, e.g. 10m"
    [LOG_MAX_FILE]="docker log files to keep"
    [SECRETS_BACKEND]="auto | systemd-creds | openssl (vault encryption for the app secret key)"
)

# -----------------------------------------------------------------------------
# SECRETS MODEL (encrypted -> $SECRETS_FILE)
# -----------------------------------------------------------------------------
SECRET_KEYS=( APP_SECRET_KEY )
declare -A SECRETS=()
SECRETS_LOADED=0
CONFIG_LOADED=0

# -----------------------------------------------------------------------------
# RUNTIME STATE
# -----------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
CONFIRM_KEYWORD=""
SOURCE_OVERRIDE=""
SRC_DIR="" SRC_KIND="" PAYLOAD_TMP=""
WIZ_TLS_MODE="" WIZ_TLS_CERT="" WIZ_TLS_KEY="" WIZ_HTTP_MODE=""
COMPOSE_QUIET=0
LOG_FILE=""
REAL_USER="${SUDO_USER:-root}"
PUID="" PGID=""
APP_VERSION=""

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
cleanup_tmp() { [[ -n "$PAYLOAD_TMP" && -d "$PAYLOAD_TMP" ]] && rm -rf -- "$PAYLOAD_TMP"; return 0; }
trap cleanup_tmp EXIT

init_logging() {
    mkdir -p "$HD_LOG_DIR"
    chmod 750 "$HD_LOG_DIR"
    LOG_FILE="$HD_LOG_DIR/installer-$(date +%F_%H-%M-%S).log"
    : >"$LOG_FILE"
    chmod 640 "$LOG_FILE"
    local old
    while IFS= read -r old; do rm -f -- "$old"; done < <(ls -1t "$HD_LOG_DIR"/installer-*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)))
}

# -----------------------------------------------------------------------------
# GENERIC HELPERS
# -----------------------------------------------------------------------------
is_tty() { [[ -t 0 ]]; }

# run CMD...  -- execute (or print in dry-run). Never pass secrets as arguments.
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
run_logged() {
    if (( DRY_RUN )); then run "$@"; return 0; fi
    _log_file RUN "$*"
    if [[ -n "$LOG_FILE" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        "$@"
    fi
}

# write_file PATH MODE OWNER:GROUP  (content on stdin), atomic
write_file() {
    local path=$1 mode=$2 owner=$3 tmp
    if (( DRY_RUN )); then
        cat >/dev/null
        printf '  %s[dry-run]%s write %s (mode %s, %s)\n' "$D" "$NC" "$path" "$mode" "$owner"
        _log_file DRYRUN "write $path"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "$(dirname "$path")/.hd-tmp.XXXXXX")
    cat >"$tmp"
    chmod "$mode" "$tmp"
    chown "$owner" "$tmp"
    mv -f "$tmp" "$path"
    _log_file WRITE "$path"
}

# ask VAR "Prompt" "default"
ask() {
    local __var=$1 __prompt=$2 __def=${3-} __in=""
    if (( ASSUME_YES )) || ! is_tty; then printf -v "$__var" '%s' "$__def"; return 0; fi
    read -rp "  ${__prompt} [${__def}]: " __in || true
    printf -v "$__var" '%s' "${__in:-$__def}"
}

# ask_secret VAR "Prompt"  -- hidden, confirmed; empty input returns empty
ask_secret() {
    local __var=$1 __prompt=$2 __a="" __b=""
    if ! is_tty; then printf -v "$__var" '%s' ""; return 0; fi
    while :; do
        read -rsp "  ${__prompt}: " __a || true; echo
        if [[ -z "$__a" ]]; then printf -v "$__var" '%s' ""; return 0; fi
        read -rsp "  Confirm: " __b || true; echo
        [[ "$__a" == "$__b" ]] && break
        log_warn "Entries did not match, try again (Enter on an empty prompt skips)."
    done
    printf -v "$__var" '%s' "$__a"
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

in_list() { local n=$1; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

# safe_path PATH -- refuse to rm -rf system or top-level paths
safe_path() {
    local p=${1%/}
    [[ "$p" == /* ]] || return 1
    case "$p" in
        ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/var/log) return 1 ;;
    esac
    [[ "$p" =~ ^/home/[^/]+$ ]] && return 1
    [[ "$p" == *..* ]] && return 1
    [[ $(tr -cd '/' <<<"$p" | wc -c) -ge 2 ]]
}

# -----------------------------------------------------------------------------
# VALIDATORS
# -----------------------------------------------------------------------------
valid_abs_path() { [[ "$1" == /* && "$1" != *..* && "$1" != *" "* && "$1" != *'$'* && "$1" != *'"'* ]]; }
valid_port()     { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_ipv4()     {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o; for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
valid_bind()     { valid_ipv4 "$1" || [[ "$1" =~ ^[0-9A-Fa-f:]+$ && "$1" == *:* ]]; }
valid_name()     { [[ "$1" =~ ^[a-z0-9][a-z0-9_.-]{0,62}$ ]]; }
valid_user()     { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }
valid_id()       { [[ -z "$1" ]] || { [[ "$1" =~ ^[0-9]{1,6}$ ]] && (( 10#$1 >= 100 && 10#$1 < 65534 )); }; }
valid_uint()     { [[ "$1" =~ ^[0-9]{1,4}$ ]] && (( 10#$1 >= 1 )); }
valid_size()     { [[ "$1" =~ ^[0-9]{1,6}[kmg]$ ]]; }
valid_memlimit() { [[ -z "$1" ]] || valid_size "$1"; }
valid_image()    { [[ "$1" =~ ^[a-z0-9][a-z0-9._/:-]*(@sha256:[0-9a-f]{64})?$ && "$1" != *'$'* ]]; }
valid_pyver()    { [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; }
valid_tz()       { [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$ ]]; }

# validate_key KEY VALUE -> 0 if valid
validate_key() {
    local k=$1 v=$2
    case "$k" in
        INSTALL_DIR|DATA_DIR|BACKUP_DIR) valid_abs_path "$v" && safe_path "$v" ;;
        BACKUP_KEEP|LOG_MAX_FILE)        valid_uint "$v" ;;
        BIND_ADDRESS)                    valid_bind "$v" ;;
        HOST_PORT)                       valid_port "$v" ;;
        HTTP_PORT)                       [[ -z "$v" ]] || { valid_port "$v" && [[ "$v" != "${CFG[HOST_PORT]:-}" ]]; } ;;
        CONTAINER_NAME|IMAGE_NAME)       valid_name "$v" ;;
        BASE_IMAGE)                      valid_image "$v" ;;
        CRYPTOGRAPHY_VERSION)            valid_pyver "$v" ;;
        BUILD_NETWORK)                   in_list "$v" default host ;;
        TIMEZONE)                        valid_tz "$v" ;;
        SERVICE_USER)                    valid_user "$v" ;;
        SERVICE_UID|SERVICE_GID)         valid_id "$v" ;;
        RESTART_POLICY)                  in_list "$v" unless-stopped always on-failure no ;;
        MEM_LIMIT)                       valid_memlimit "$v" ;;
        LOG_MAX_SIZE)                    valid_size "$v" ;;
        SECRETS_BACKEND)                 in_list "$v" auto systemd-creds openssl ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# DETECTION
# -----------------------------------------------------------------------------
detect_timezone() {
    local tz=""
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ -z "$tz" && -f /etc/timezone ]] && tz=$(head -n1 /etc/timezone)
    [[ -z "$tz" && -L /etc/localtime ]] && tz=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
    valid_tz "${tz:-}" && printf '%s' "$tz" || printf 'UTC'
}

detect_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

host_short() { local h; h=$(hostname -s 2>/dev/null || hostname); [[ "$h" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] && printf '%s' "$h" || printf 'switch-dashboard'; }

# host_tls_names -- FQDN + global host IPs (minus docker bridges) for the self-signed certificate
host_tls_names() {
    local -a n=() ip
    local f; f=$(hostname -f 2>/dev/null || true)
    [[ -n "$f" && "$f" == *.* && "$f" != localhost* ]] && n+=("${f,,}")
    while read -r ip; do [[ -n "$ip" ]] && n+=("$ip"); done < <(
        ip -o addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth|virbr|cni|flannel|cali|tun|wg)/ {split($4, a, "/"); print a[1]}')
    local IFS=,; printf '%s' "${n[*]}"
}

have_docker() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
docker_up()   { have_docker && docker info >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# CONFIG
# -----------------------------------------------------------------------------
conf_quote()   { local v=$1; printf "'%s'" "${v//"'"/"'\\''"}"; }
conf_unquote() {
    local v=$1
    if [[ "$v" == \'*\' ]]; then
        v=${v:1:${#v}-2}
        v=${v//"'\\''"/"'"}
    fi
    printf '%s' "$v"
}

set_default_config() {
    CFG=(
        [INSTALL_DIR]="/opt/switch-dashboard"
        [DATA_DIR]="/opt/switch-dashboard/data"
        [BACKUP_DIR]="/var/backups/switch-dashboard"
        [BACKUP_KEEP]="10"
        [BIND_ADDRESS]="0.0.0.0"
        [HOST_PORT]="8810"
        [HTTP_PORT]="8880"
        [CONTAINER_NAME]="switch-dashboard"
        [IMAGE_NAME]="switch-dashboard"
        [BASE_IMAGE]="$DEFAULT_BASE_IMAGE"
        [CRYPTOGRAPHY_VERSION]="$DEFAULT_CRYPTOGRAPHY_VERSION"
        [BUILD_NETWORK]="default"
        [TIMEZONE]="$(detect_timezone)"
        [SERVICE_USER]="switchdash"
        [SERVICE_UID]=""
        [SERVICE_GID]=""
        [RESTART_POLICY]="unless-stopped"
        [MEM_LIMIT]="128m"
        [LOG_MAX_SIZE]="10m"
        [LOG_MAX_FILE]="3"
        [SECRETS_BACKEND]="auto"
    )
}

load_config() {
    set_default_config
    if [[ -f "$CONF_FILE" ]]; then
        local line k v
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
            k=${BASH_REMATCH[1]}; v=$(conf_unquote "${BASH_REMATCH[2]}")
            if in_list "$k" "${CONF_KEYS[@]}"; then
                if validate_key "$k" "$v"; then CFG[$k]=$v
                else log_warn "Ignoring invalid $k='$v' in $CONF_FILE (using '${CFG[$k]}')"; fi
            fi
        done <"$CONF_FILE"
    fi
    CONFIG_LOADED=1
}
ensure_config() { (( CONFIG_LOADED )) || load_config; }

save_config() {
    local k
    {
        printf '# %s settings -- written by %s v%s on %s\n' "$PROJECT_NAME" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(date '+%F %T')"
        printf '# Edit with the menu (Settings) or: %s --set KEY VALUE\n' "$(basename "$HD_INSTALL_BIN")"
        for k in "${CONF_KEYS[@]}"; do printf '%s=%s\n' "$k" "$(conf_quote "${CFG[$k]}")"; done
    } | write_file "$CONF_FILE" 600 root:root
    log_ok "Settings saved: $CONF_FILE"
}

set_conf_value() {   # set_conf_value KEY VALUE  (validates)
    local k=$1 v=$2
    in_list "$k" "${CONF_KEYS[@]}" || die "Unknown setting '$k'. Valid keys: ${CONF_KEYS[*]}"
    validate_key "$k" "$v" || die "Invalid value for $k: '$v' (${CONF_HELP[$k]})"
    CFG[$k]=$v
}

show_config() {
    ensure_config
    local k
    printf '\n  %sContainer / host settings%s (%s)\n' "$B" "$NC" "$CONF_FILE"
    for k in "${CONF_KEYS[@]}"; do
        printf '    %-22s %-34s %s%s%s\n' "$k" "${CFG[$k]:-(empty)}" "$D" "${CONF_HELP[$k]}" "$NC"
    done
}

# -----------------------------------------------------------------------------
# SECRETS (encrypted at rest; systemd-creds w/ TPM2 when available, else openssl)
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
    ( umask 077; openssl rand -base64 48 | tr -d '\n' >"$KEY_FILE" )
    chmod 400 "$KEY_FILE"
    log_info "Created local secrets key $KEY_FILE (root-only)."
}

# secrets_encrypt_to BACKEND OUTFILE  (plaintext payload on stdin; never touches disk unencrypted)
secrets_encrypt_to() {
    local backend=$1 out=$2 tmp
    mkdir -p "$(dirname "$out")"; chmod 700 "$(dirname "$out")"
    tmp=$(mktemp "$(dirname "$out")/.secrets.XXXXXX")
    {
        printf '# switch-dashboard-secrets v1 backend=%s\n' "$backend"
        case "$backend" in
            systemd-creds) systemd-creds encrypt --name=switch-dashboard-secrets - - ;;
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
    [[ "$hdr" == "# switch-dashboard-secrets v1 backend="* ]] || return 1
    backend=${hdr##*backend=}
    case "$backend" in
        systemd-creds) tail -n +2 "$SECRETS_FILE" | systemd-creds decrypt --name=switch-dashboard-secrets - - ;;
        openssl)       tail -n +2 "$SECRETS_FILE" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -a -pass "file:$KEY_FILE" ;;
        *)             return 1 ;;
    esac
}

secrets_file_backend() { head -n1 "$SECRETS_FILE" 2>/dev/null | sed -n 's/.*backend=//p'; }

load_secrets() {
    (( SECRETS_LOADED )) && return 0
    SECRETS=()
    if [[ -f "$SECRETS_FILE" ]]; then
        local payload line k
        payload=$(secrets_decrypt) || die "Cannot decrypt $SECRETS_FILE (backend: $(secrets_file_backend)). Was the host key / TPM changed?"
        while IFS= read -r line; do
            [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
            k=${BASH_REMATCH[1]}
            in_list "$k" "${SECRET_KEYS[@]}" || continue
            SECRETS[$k]=$(printf '%s' "${BASH_REMATCH[2]}" | base64 -d)
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

secrets_init() {
    load_secrets
    if [[ -z "${SECRETS[APP_SECRET_KEY]:-}" ]]; then
        SECRETS[APP_SECRET_KEY]=$(openssl rand -base64 48 | tr -d '\n')
        log_info "Generated the app secret key (encrypts switch passwords inside the data volume)."
        save_secrets
    else
        log_ok "App secret key present in the vault ($(secrets_file_backend))"
    fi
}

# -----------------------------------------------------------------------------
# UPGRADE FROM hp1810-dashboard (installer 1.x)
# -----------------------------------------------------------------------------
legacy_present() { [[ -f "$HD_LEGACY_CONF_DIR/hp1810-dashboard.conf" && ! -f "$CONF_FILE" ]]; }

# legacy_map  -- CFG holds the old settings; swap the old default names for the new ones (custom values stay)
legacy_map() {
    local k
    declare -A old=([INSTALL_DIR]=/opt/hp1810-dashboard [DATA_DIR]=/opt/hp1810-dashboard/data
                    [BACKUP_DIR]=/var/backups/hp1810-dashboard [CONTAINER_NAME]=hp1810-dashboard
                    [IMAGE_NAME]=hp1810-dashboard [SERVICE_USER]=hp1810dash)
    declare -A new=([INSTALL_DIR]=/opt/switch-dashboard [DATA_DIR]=/opt/switch-dashboard/data
                    [BACKUP_DIR]=/var/backups/switch-dashboard [CONTAINER_NAME]=switch-dashboard
                    [IMAGE_NAME]=switch-dashboard [SERVICE_USER]=switchdash)
    for k in "${!old[@]}"; do
        [[ "${CFG[$k]}" == "${old[$k]}" ]] && CFG[$k]=${new[$k]}
    done
    return 0
}

legacy_secrets_decrypt() {
    local f="$HD_LEGACY_CONF_DIR/secrets.enc" hdr backend
    hdr=$(head -n1 "$f")
    [[ "$hdr" == "# hp1810-dashboard-secrets v1 backend="* ]] || return 1
    backend=${hdr##*backend=}
    case "$backend" in
        systemd-creds) tail -n +2 "$f" | systemd-creds decrypt --name=hp1810-dashboard-secrets - - ;;
        openssl)       tail -n +2 "$f" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -a \
                           -pass "file:$HD_LEGACY_CONF_DIR/.secrets.key" ;;
        *)             return 1 ;;
    esac
}

# move_dir OLD NEW  -- rename a directory if it moved and the target is free
move_dir() {
    local from=$1 to=$2
    [[ "$from" == "$to" || ! -e "$from" ]] && return 0
    if [[ -e "$to" ]]; then
        log_warn "$to already exists; leaving $from in place (move its contents yourself if needed)."
        return 0
    fi
    run install -d -m 0755 "$(dirname "$to")"
    run mv -- "$from" "$to"
    log_ok "Moved $from -> $to"
}

migrate_legacy() {
    legacy_present || return 0
    log_step "Upgrade: hp1810-dashboard -> switch-dashboard"
    printf '  Found an hp1810-dashboard install (%s). This will:\n' "$HD_LEGACY_CONF_DIR"
    printf '    - back it up, then stop and remove the old container;\n'
    printf '    - move its folders, settings and encrypted secret key to the switch-dashboard names;\n'
    printf '    - rename the service account (same UID, so file ownership is unchanged);\n'
    printf '    - build and start the switch-dashboard container with your switches, users and port names.\n'
    if (( ! ASSUME_YES )); then
        is_tty || die "An hp1810-dashboard install needs upgrading; re-run with --yes (or interactively)."
        confirm "Upgrade now?" y || die "Not upgraded. Nothing was changed."
    fi

    # old settings + secrets
    local saved=$CONF_FILE; CONF_FILE="$HD_LEGACY_CONF_DIR/hp1810-dashboard.conf"
    CONFIG_LOADED=0; load_config; CONF_FILE=$saved
    local payload line k
    payload=$(legacy_secrets_decrypt) || die "Cannot decrypt $HD_LEGACY_CONF_DIR/secrets.enc; nothing was changed."
    SECRETS=()
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
        k=${BASH_REMATCH[1]}
        in_list "$k" "${SECRET_KEYS[@]}" && SECRETS[$k]=$(printf '%s' "${BASH_REMATCH[2]}" | base64 -d)
    done <<<"$payload"
    SECRETS_LOADED=1
    [[ -n "${SECRETS[APP_SECRET_KEY]:-}" ]] || die "The old vault has no app secret key; nothing was changed."
    declare -A was=()
    for k in INSTALL_DIR DATA_DIR BACKUP_DIR CONTAINER_NAME IMAGE_NAME SERVICE_USER; do was[$k]=${CFG[$k]}; done

    # safety backup (old layout) before anything moves
    local bk; bk="${was[BACKUP_DIR]}/hp1810-dashboard-pre-upgrade-$(date +%Y%m%d-%H%M%S).tar.gz"
    run install -d -m 0700 -o root -g root "${was[BACKUP_DIR]}"
    if (( DRY_RUN )); then run tar -czf "$bk" -C / "${was[DATA_DIR]#/}" "${HD_LEGACY_CONF_DIR#/}"
    else
        ( umask 077; tar -czf "$bk" --exclude="${was[DATA_DIR]#/}/.ctl-token" --exclude="${was[DATA_DIR]#/}/.config.lock" \
              -C / "${was[DATA_DIR]#/}" "${HD_LEGACY_CONF_DIR#/}" ) || die "Backup failed; nothing was changed."
        log_ok "Backup of the old install: $bk"
    fi

    # stop the old container
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker container inspect "${was[CONTAINER_NAME]}" >/dev/null 2>&1; then
            run docker rm -f "${was[CONTAINER_NAME]}" >/dev/null
            log_ok "Removed the old container ${was[CONTAINER_NAME]}"
        fi
        docker network inspect hp1810-dashboard_default >/dev/null 2>&1 && run docker network rm hp1810-dashboard_default >/dev/null
    fi

    legacy_map

    # folders: the install dir first (the data dir usually lives inside it)
    move_dir "${was[INSTALL_DIR]}" "${CFG[INSTALL_DIR]}"
    local data_now=${was[DATA_DIR]}
    if [[ "${was[DATA_DIR]}" == "${was[INSTALL_DIR]}/"* && -d "${CFG[INSTALL_DIR]}" ]]; then
        data_now="${CFG[INSTALL_DIR]}/${was[DATA_DIR]#"${was[INSTALL_DIR]}/"}"
        (( DRY_RUN )) && data_now=${was[DATA_DIR]}
    fi
    (( DRY_RUN )) || move_dir "$data_now" "${CFG[DATA_DIR]}"
    run rm -f -- "${CFG[INSTALL_DIR]}/docker-compose.yml"
    move_dir "${was[BACKUP_DIR]}" "${CFG[BACKUP_DIR]}"
    [[ -f "${CFG[BACKUP_DIR]}/$(basename "$bk")" ]] && bk="${CFG[BACKUP_DIR]}/$(basename "$bk")"
    if [[ -d "$HD_LEGACY_STATE_DIR" ]]; then move_dir "$HD_LEGACY_STATE_DIR" "$HD_STATE_DIR"; fi
    if [[ -d "$HD_LEGACY_LOG_DIR" ]]; then
        run install -d -m 0750 "$HD_LOG_DIR"
        run find "$HD_LEGACY_LOG_DIR" -maxdepth 1 -type f -name '*.log' -exec mv -t "$HD_LOG_DIR" -- {} +
        run rmdir --ignore-fail-on-non-empty "$HD_LEGACY_LOG_DIR"
    fi

    # service account: rename, keep the UID/GID
    if [[ "${was[SERVICE_USER]}" != "${CFG[SERVICE_USER]}" ]] && id "${was[SERVICE_USER]}" >/dev/null 2>&1 \
            && ! id "${CFG[SERVICE_USER]}" >/dev/null 2>&1; then
        run usermod -l "${CFG[SERVICE_USER]}" -c "switch-dashboard service account" "${was[SERVICE_USER]}"
        getent group "${was[SERVICE_USER]}" >/dev/null && ! getent group "${CFG[SERVICE_USER]}" >/dev/null && \
            run groupmod -n "${CFG[SERVICE_USER]}" "${was[SERVICE_USER]}"
        log_ok "Service account ${was[SERVICE_USER]} renamed to ${CFG[SERVICE_USER]} (UID $(id -u "${CFG[SERVICE_USER]}" 2>/dev/null || echo '?'))"
    fi

    # new settings + vault (re-encrypted under the new name), then retire the old ones
    if (( DRY_RUN )); then
        log_info "[dry-run] would write $CONF_FILE and $SECRETS_FILE, then remove $HD_LEGACY_CONF_DIR and $HD_LEGACY_BIN"
    else
        install -d -m 0700 "$HD_CONF_DIR"
        save_secrets
        local chk; chk=$(secrets_decrypt) || chk=""
        [[ "$chk" == *"APP_SECRET_KEY=$(printf '%s' "${SECRETS[APP_SECRET_KEY]}" | base64 -w0)"* ]] || {
            rm -f -- "$SECRETS_FILE"
            die "Re-encrypting the secret key failed; the old settings are still in $HD_LEGACY_CONF_DIR (backup: $bk)."
        }
        save_config                                      # last: its presence marks the upgrade as done
        rm -rf -- "$HD_LEGACY_CONF_DIR"
        rm -f -- "$HD_LEGACY_BIN"
        log_ok "Old settings removed (they are in $bk)"
    fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local imgs; imgs=$(docker image ls -q --filter "label=net.certifiedgeeks.hp1810-dashboard.installer" | sort -u)
        if [[ -n "$imgs" ]]; then
            # shellcheck disable=SC2086
            run docker image rm $imgs >/dev/null 2>&1 || true
            log_ok "Removed the old hp1810-dashboard image(s)"
        fi
    fi
    CONFIG_LOADED=1
    log_ok "Settings moved. Building and starting switch-dashboard..."
}

# Re-encrypt the vault with the currently configured backend (e.g. after enabling TPM2)
secrets_rekey() {
    load_secrets
    [[ -n "${SECRETS[APP_SECRET_KEY]:-}" ]] || die "No vault to re-encrypt yet (run --install)."
    save_secrets
}

# -----------------------------------------------------------------------------
# PREFLIGHT / DOCKER ENGINE  (same approach as docker-base-install.sh)
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
    ensure_config
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die "bash 4.4+ required."
    detect_os
    local arch; arch=$(dpkg --print-architecture)
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || die "Unsupported architecture: $arch"
    log_ok "OS: $OS_ID $OS_CODENAME ($arch)"
    ensure_prereqs
    init_source
    log_ok "Source: $SRC_KIND ($SRC_DIR, app v$(app_version_of "$SRC_DIR"))"
}

# tool -> Debian/Ubuntu package that provides it
declare -A PREREQ_PKG=(
    [curl]=curl [tar]=tar [gzip]=gzip [openssl]=openssl [ip]=iproute2 [awk]=gawk [sed]=sed
    [base64]=coreutils [sha256sum]=coreutils [flock]=util-linux [find]=findutils [getent]=libc-bin
    [useradd]=passwd [groupadd]=passwd [dpkg]=dpkg
)

ensure_prereqs() {
    local -a pkgs=() missing=() t
    for t in "${!PREREQ_PKG[@]}"; do
        command -v "$t" >/dev/null 2>&1 || { missing+=("$t"); in_list "${PREREQ_PKG[$t]}" "${pkgs[@]}" || pkgs+=("${PREREQ_PKG[$t]}"); }
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || { missing+=(ca-certificates); pkgs+=(ca-certificates); }
    if (( ${#pkgs[@]} )); then
        log_warn "Missing prerequisites: ${missing[*]} -> installing: ${pkgs[*]}"
        run_logged apt-get update
        DEBIAN_FRONTEND=noninteractive run_logged apt-get install -y --no-install-recommends "${pkgs[@]}"
        log_ok "Prerequisites installed"
    else
        log_ok "Prerequisites present (curl, openssl, iproute2, gawk, coreutils, util-linux, ...)"
    fi
}

install_docker() {
    log_step "Docker Engine"
    if have_docker; then
        log_ok "Docker present: $(docker --version | sed 's/Docker version //') / compose $(docker compose version --short 2>/dev/null)"
        if ! docker buildx version >/dev/null 2>&1 && dpkg -s docker-ce >/dev/null 2>&1; then
            log_info "Adding docker-buildx-plugin (BuildKit builder)"
            DEBIAN_FRONTEND=noninteractive run_logged apt-get install -y docker-buildx-plugin
        fi
    else
        log_info "Docker Engine + compose plugin not found; installing Docker CE from download.docker.com"
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
        DEBIAN_FRONTEND=noninteractive run_logged apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        log_ok "Docker CE installed"
    fi
    (( DRY_RUN )) && return 0
    if ! docker_up; then
        log_info "Starting the Docker daemon"
        systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
        local i; for (( i = 0; i < 20; i++ )); do docker_up && break; sleep 1; done
    fi
    docker_up || die "Docker daemon is not running (systemctl status docker; journalctl -u docker)."
    log_ok "Docker daemon running ($(docker info -f '{{.ServerVersion}}' 2>/dev/null))"
}

# -----------------------------------------------------------------------------
# SERVICE ACCOUNT
# -----------------------------------------------------------------------------
ensure_service_account() {
    log_step "Service account"
    local u=${CFG[SERVICE_USER]} uid=${CFG[SERVICE_UID]} gid=${CFG[SERVICE_GID]}
    if id "$u" >/dev/null 2>&1; then
        log_ok "Account '$u' exists (uid $(id -u "$u"), gid $(id -g "$u"))"
    else
        local -a gargs=(--system) uargs=(--system --no-create-home --home-dir /nonexistent
                                          --shell /usr/sbin/nologin --comment "switch-dashboard service account")
        [[ -n "$gid" ]] && gargs+=(--gid "$gid")
        [[ -n "$uid" ]] && uargs+=(--uid "$uid")
        getent group "$u" >/dev/null || run groupadd "${gargs[@]}" "$u"
        run useradd "${uargs[@]}" --gid "$u" "$u"
        log_ok "Created system account '$u' (nologin, no home, not in docker group)"
    fi
    if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        log_warn "'$u' is in the docker group; that grants root-equivalent access. Remove with: gpasswd -d $u docker"
    fi
    resolve_ids
}

resolve_ids() {
    local u=${CFG[SERVICE_USER]}
    if id "$u" >/dev/null 2>&1; then
        PUID=$(id -u "$u"); PGID=$(id -g "$u")
    else
        PUID=${CFG[SERVICE_UID]:-10001}; PGID=${CFG[SERVICE_GID]:-10001}   # dry-run / not created yet
    fi
}

# -----------------------------------------------------------------------------
# SOURCE (Dockerfile + app/ from the repo checkout, installed copy under INSTALL_DIR/src)
# -----------------------------------------------------------------------------
is_source_dir() { [[ -f "$1/Dockerfile" && -f "$1/app/switchdash.py" && -d "$1/app/web" ]]; }

# Embedded source: the end of this file holds "__SWDASH_PAYLOAD__ app=X sha256=Y" followed by a
# base64 tar.gz of Dockerfile + app/ (+ docs). --build-standalone regenerates it.
payload_header() { grep -m1 "^${PAYLOAD_MARK} " "$SCRIPT_PATH" 2>/dev/null || true; }
has_payload()    { [[ -n "$(payload_header)" ]]; }
payload_field()  { payload_header | tr ' ' '\n' | sed -n "s/^$1=//p"; }
payload_b64()    { awk -v m="$PAYLOAD_MARK " -v e="$PAYLOAD_END" '$0 == e {exit} f {print} index($0, m) == 1 {f = 1}' "$SCRIPT_PATH"; }
script_body()    { awk -v h=": <<'$PAYLOAD_END'" -v m="$PAYLOAD_MARK " '$0 == h || index($0, m) == 1 {exit} {print}' "$1"; }

# extract_payload DIR  -- verify and unpack the embedded source into DIR
extract_payload() {
    local d=$1 sum
    mkdir -p "$d"
    payload_b64 | base64 -d >"$d/.payload.tgz" || return 1
    sum=$(sha256sum "$d/.payload.tgz" | cut -d' ' -f1)
    [[ "$sum" == "$(payload_field sha256)" ]] || { log_error "Embedded source is corrupt (sha256 $sum != $(payload_field sha256))."; return 1; }
    tar -xzf "$d/.payload.tgz" -C "$d" --no-same-owner
    rm -f "$d/.payload.tgz"
    is_source_dir "$d"
}

# init_source  -- sets SRC_DIR/SRC_KIND (call directly, not in $(...))
#   order: --source DIR, repository checkout next to this script, embedded copy, installed copy
init_source() {
    [[ -n "$SRC_DIR" ]] && return 0
    ensure_config
    if [[ -n "$SOURCE_OVERRIDE" ]]; then
        is_source_dir "$SOURCE_OVERRIDE" || die "--source $SOURCE_OVERRIDE has no Dockerfile + app/switchdash.py"
        SRC_DIR=$(readlink -f "$SOURCE_OVERRIDE"); SRC_KIND="--source"; return 0
    fi
    if is_source_dir "$SCRIPT_DIR"; then SRC_DIR=$SCRIPT_DIR; SRC_KIND="checkout"; return 0; fi
    if has_payload; then
        PAYLOAD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/switchdash-src.XXXXXX")
        extract_payload "$PAYLOAD_TMP" || die "Could not unpack the embedded source from $SCRIPT_PATH."
        SRC_DIR=$PAYLOAD_TMP; SRC_KIND="embedded"; return 0
    fi
    if is_source_dir "${CFG[INSTALL_DIR]}/src"; then SRC_DIR="${CFG[INSTALL_DIR]}/src"; SRC_KIND="installed"; return 0; fi
    die "No dashboard source: this copy of the installer has no embedded source and no Dockerfile + app/ next to it. Use the release installer or pass --source DIR."
}

# build_standalone OUT  -- write a self-contained installer (this script + embedded source)
build_standalone() {
    local out=$1 tmp sum ver
    init_source
    ver=$(app_version_of "$SRC_DIR")
    tmp=$(mktemp -d)
    local -a items=(Dockerfile app) f
    for f in .dockerignore README.md CHANGELOG.md LICENSE; do [[ -e "$SRC_DIR/$f" ]] && items+=("$f"); done
    tar -C "$SRC_DIR" --exclude=__pycache__ --exclude='*.pyc' --sort=name --mtime='2000-01-01 00:00Z' \
        --owner=0 --group=0 --numeric-owner -cf - "${items[@]}" | gzip -9n >"$tmp/p.tgz"
    sum=$(sha256sum "$tmp/p.tgz" | cut -d' ' -f1)
    {
        script_body "$SCRIPT_PATH"
        printf ": <<'%s'\n" "$PAYLOAD_END"
        printf '%s app=%s sha256=%s\n' "$PAYLOAD_MARK" "$ver" "$sum"
        base64 -w 76 "$tmp/p.tgz"
        printf '%s\n' "$PAYLOAD_END"
    } >"$tmp/out.sh"
    chmod 755 "$tmp/out.sh"
    bash -n "$tmp/out.sh" || { rm -rf "$tmp"; die "Generated installer failed a syntax check."; }
    mv -f "$tmp/out.sh" "$out"
    rm -rf "$tmp"
    log_ok "Wrote $out (installer v$SCRIPT_VERSION + app v$ver from $SRC_KIND $SRC_DIR, $(du -h "$out" | cut -f1))"
}

app_version_of() { sed -n 's/^__version__ = "\([0-9][0-9.]*\)".*/\1/p' "$1/app/switchdash.py" | head -n1; }

sync_source() {
    log_step "Build context"
    local src dst=${CFG[INSTALL_DIR]}/src
    init_source; src=$SRC_DIR
    APP_VERSION=$(app_version_of "$src")
    [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Cannot read __version__ from $src/app/switchdash.py"
    if [[ "$src" == "$(readlink -f "$dst" 2>/dev/null || true)" ]]; then
        log_ok "Using installed source $dst (app v$APP_VERSION)"
        return 0
    fi
    run mkdir -p "$dst"
    run rm -rf "$dst/app.new"
    run cp -a "$src/app" "$dst/app.new"
    run find "$dst/app.new" -name __pycache__ -type d -prune -exec rm -rf {} +
    # The embedded source has fixed timestamps (reproducible installer). docker build's context sync treats a file
    # with the same size and mtime as unchanged, so give the copy fresh mtimes or a same-length edit is missed.
    run find "$dst/app.new" -exec touch -m {} +
    run rm -rf "$dst/app"
    run mv "$dst/app.new" "$dst/app"
    run cp -f "$src/Dockerfile" "$dst/Dockerfile"
    [[ -f "$src/.dockerignore" ]] && run cp -f "$src/.dockerignore" "$dst/.dockerignore"
    local f; for f in README.md CHANGELOG.md LICENSE; do [[ -f "$src/$f" ]] && run cp -f "$src/$f" "$dst/$f"; done
    log_ok "Copied app v$APP_VERSION from $src to $dst"
}

install_self() {
    [[ "$SCRIPT_PATH" == "$HD_INSTALL_BIN" ]] && return 0
    run install -m 0755 "$SCRIPT_PATH" "$HD_INSTALL_BIN"
    run cp -f "$SCRIPT_PATH" "${CFG[INSTALL_DIR]}/src/$(basename "$SCRIPT_PATH")"
    log_ok "Installer available as $HD_INSTALL_BIN"
}

current_app_version() {
    [[ -n "$APP_VERSION" ]] && { printf '%s' "$APP_VERSION"; return 0; }
    if [[ -n "$SRC_DIR" ]]; then app_version_of "$SRC_DIR"; return 0; fi
    local d
    for d in "$SOURCE_OVERRIDE" "$SCRIPT_DIR" "${CFG[INSTALL_DIR]}/src"; do
        [[ -n "$d" ]] && is_source_dir "$d" && { app_version_of "$d"; return 0; }
    done
    has_payload && { payload_field app; return 0; }
    printf unknown
}

# -----------------------------------------------------------------------------
# COMPOSE
# -----------------------------------------------------------------------------
compose_file() { printf '%s/docker-compose.yml' "${CFG[INSTALL_DIR]}"; }
image_ref()    { printf '%s:%s' "${CFG[IMAGE_NAME]}" "$(current_app_version)"; }

port_spec() {
    local b=${CFG[BIND_ADDRESS]}
    [[ "$b" == *:* ]] && b="[$b]"
    printf '%s:%s:%s' "$b" "${CFG[HOST_PORT]}" "$CONTAINER_PORT"
}

http_port_spec() {
    local b=${CFG[BIND_ADDRESS]}
    [[ "$b" == *:* ]] && b="[$b]"
    printf '%s:%s:%s' "$b" "${CFG[HTTP_PORT]}" "$CONTAINER_HTTP_PORT"
}

render_compose() {
    resolve_ids
    cat <<EOF
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION -- do not edit; change settings with the installer.
# The secret key is injected by the installer at start time and never written here.
name: $PROJECT_NAME

services:
  app:
    image: "$(image_ref)"
    pull_policy: never          # built locally by the installer (--apply / --rebuild)
    container_name: "${CFG[CONTAINER_NAME]}"
    hostname: "$(host_short)"
    user: "$PUID:$PGID"
    restart: "${CFG[RESTART_POLICY]}"
    init: true
    read_only: true
    tmpfs:
      - "/tmp:size=16m,mode=1777"
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    environment:
      TZ: "${CFG[TIMEZONE]}"
      SWDASH_SELF_RESTART: "$([[ "${CFG[RESTART_POLICY]}" == no ]] && echo 0 || echo 1)"
      SWDASH_SECRET_KEY: "\${SWDASH_SECRET_KEY:?start the dashboard with $SCRIPT_NAME (it injects the secret key)}"
      SWDASH_HTTP_PORT: "$CONTAINER_HTTP_PORT"
      SWDASH_PUBLIC_HTTPS_PORT: "${CFG[HOST_PORT]}"
      SWDASH_PUBLIC_HTTP_PORT: "${CFG[HTTP_PORT]}"
    ports:
      - "$(port_spec)"
$([[ -n "${CFG[HTTP_PORT]}" ]] && printf '      - "%s"' "$(http_port_spec)")
    volumes:
      - "${CFG[DATA_DIR]}:/data"
EOF
    [[ -n "${CFG[MEM_LIMIT]}" ]] && printf '    mem_limit: "%s"\n' "${CFG[MEM_LIMIT]}"
    cat <<EOF
    logging:
      driver: json-file
      options:
        max-size: "${CFG[LOG_MAX_SIZE]}"
        max-file: "${CFG[LOG_MAX_FILE]}"
EOF
}

write_compose() {
    render_compose | write_file "$(compose_file)" 644 root:root
    log_ok "Compose file: $(compose_file)"
}

# compose_run ARGS...  -- docker compose for this project, secret key injected via the environment
compose_run() {
    local f; f=$(compose_file)
    [[ -f "$f" ]] || die "No compose file yet ($f). Run --install or --apply first."
    if (( DRY_RUN )); then run docker compose -f "$f" -p "$PROJECT_NAME" "$@"; return 0; fi
    load_secrets
    [[ -n "${SECRETS[APP_SECRET_KEY]:-}" ]] || die "App secret key missing from the vault (run --install)."
    local -a g=(-f "$f" -p "$PROJECT_NAME")
    (( COMPOSE_QUIET )) && g=(--progress quiet "${g[@]}")
    _log_file RUN "docker compose ${g[*]} $*"
    SWDASH_SECRET_KEY="${SECRETS[APP_SECRET_KEY]}" docker compose "${g[@]}" "$@"
}

container_state() {
    local v; v=$(docker inspect -f '{{.State.Status}}' "${CFG[CONTAINER_NAME]}" 2>/dev/null | tr -d '[:space:]') || v=""
    printf '%s' "${v:-absent}"
}
container_health() {
    local v; v=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "${CFG[CONTAINER_NAME]}" 2>/dev/null | tr -d '[:space:]') || v=""
    printf '%s' "${v:-absent}"
}
is_running() { [[ "$(container_state)" == running ]]; }

wait_healthy() {
    (( DRY_RUN )) && return 0
    local i h
    for (( i = 0; i < 45; i++ )); do
        h=$(container_health)
        case "$h" in
            healthy)   log_ok "Container healthy"; return 0 ;;
            unhealthy) break ;;
        esac
        [[ "$(container_state)" =~ ^(exited|dead|absent)$ ]] && break
        sleep 2
    done
    log_error "Container did not become healthy (state $(container_state), health $(container_health)). Last log lines:"
    docker logs --tail 25 "${CFG[CONTAINER_NAME]}" 2>&1 | sed 's/^/    /' >&2 || true
    return 1
}

# app_ctl ARGS...  -- run 'switchdash ctl' against the data volume (stdin passed through)
app_ctl() {
    (( DRY_RUN )) && { run switchdash ctl "$@"; return 0; }
    # Attach the terminal only when ctl will prompt (--password-prompt); pass stdin only when it is piped
    # (e.g. --password-stdin). Otherwise leave it alone so type-ahead stays with this script.
    local -a xt=() rt=(-T)
    if in_list --password-prompt "$@" && [[ -t 0 && -t 1 ]]; then xt=(-it); rt=()
    elif [[ ! -t 0 ]]; then xt=(-i); fi
    if is_running; then
        docker exec "${xt[@]}" -e SWDASH_ACTOR="installer:$REAL_USER" "${CFG[CONTAINER_NAME]}" switchdash ctl "$@"
    else
        docker image inspect "$(image_ref)" >/dev/null 2>&1 || die "Image $(image_ref) not built yet (run --apply)."
        if [[ ${#xt[@]} -eq 0 ]]; then
            COMPOSE_QUIET=1 compose_run run --rm --no-deps "${rt[@]}" -e SWDASH_ACTOR="installer:$REAL_USER" app ctl "$@" </dev/null
        else
            COMPOSE_QUIET=1 compose_run run --rm --no-deps "${rt[@]}" -e SWDASH_ACTOR="installer:$REAL_USER" app ctl "$@"
        fi
    fi
}

app_user_count() { app_ctl show --json 2>/dev/null | grep -c '"role":' || true; }

# -----------------------------------------------------------------------------
# HTTPS (the app makes / serves the certificate; these wrap 'ctl' for the host side)
# -----------------------------------------------------------------------------
tls_get() { app_ctl get "general.$1" 2>/dev/null | tr -d '\r' || true; }

# First start: give the self-signed certificate the names/IPs people browse to
ensure_tls_names() {
    (( DRY_RUN )) && return 0
    [[ "$(tls_get tls_mode)" == self-signed ]] || return 0
    [[ -z "$(tls_get tls_san | sed 's/^-$//')" ]] || return 0
    local names; names=$(host_tls_names)
    [[ -n "$names" ]] || return 0
    app_ctl set general.tls_san "$names" >/dev/null && log_ok "Self-signed certificate names: $(host_short), $names"
}

# tls_import CERT KEY  -- host PEM files -> validated by the app -> tls_mode custom
tls_import() {
    local crt=$1 key=$2 d
    [[ -r "$crt" && -r "$key" ]] || die "Cannot read certificate '$crt' or key '$key'."
    resolve_ids
    d="${CFG[DATA_DIR]}/tls"
    run install -d -m 0700 -o "$PUID" -g "$PGID" "$d"
    run install -m 0600 -o "$PUID" -g "$PGID" "$crt" "$d/.import-cert.pem"
    run install -m 0600 -o "$PUID" -g "$PGID" "$key" "$d/.import-key.pem"
    local rc=0
    app_ctl tls-import /data/tls/.import-cert.pem /data/tls/.import-key.pem || rc=$?
    run rm -f -- "$d/.import-cert.pem" "$d/.import-key.pem"
    (( rc == 0 )) || die "Certificate import failed (see above)."
}

tls_apply_restart() {
    if is_running; then stack_restart; show_urls; tls_fingerprint; else log_info "Applies at the next start."; fi
}

tls_fingerprint() {
    (( DRY_RUN )) && return 0
    is_running || return 0
    local info mode fp days
    info=$(app_ctl tls-info 2>/dev/null) || return 0
    mode=$(awk '$1 == "tls_mode" {print $2}' <<<"$info")
    [[ "$mode" == off ]] && { log_info "HTTPS is off (plain HTTP)."; return 0; }
    fp=$(awk '$1 == "sha256" {print $2}' <<<"$info"); days=$(awk '$1 == "days_left" {print $2}' <<<"$info")
    log_info "Certificate ($mode, ${days:-?} days left) SHA-256: ${fp:-?}"
    [[ "$mode" == self-signed ]] && log_info "Self-signed: the browser warns once; check that the fingerprint matches, then accept."
    return 0
}

tls_show() { require_installed; app_ctl tls-info | sed 's/^/    /'; }

wizard_tls() {
    printf '\n  %sHTTPS%s  (your switches use https; the dashboard does too by default)\n' "$B" "$NC"
    printf '   1) Self-signed certificate made by the dashboard (default)\n'
    printf '   2) Import a certificate + key (PEM files on this host, e.g. your wildcard)\n'
    printf '   3) Off - plain HTTP (only behind a TLS reverse proxy)\n'
    local ch; ask ch "HTTPS" "1"
    case "$ch" in
        2) ask WIZ_TLS_CERT "Certificate / full chain PEM path" "/etc/ssl/certs/fullchain.pem"
           ask WIZ_TLS_KEY  "Private key PEM path" "/etc/ssl/private/privkey.pem"
           WIZ_TLS_MODE=custom ;;
        3) WIZ_TLS_MODE=off ;;
        *) WIZ_TLS_MODE=self-signed ;;
    esac
    [[ "$WIZ_TLS_MODE" == off ]] && return 0
    printf '\n  %sPlain HTTP%s  (a second port next to HTTPS)\n' "$B" "$NC"
    printf '   1) Off - HTTPS only (default)\n'
    printf '   2) Redirect - http:// on its own port sends browsers to the HTTPS address\n'
    printf '   3) On - serve the dashboard over plain HTTP too (logins cross the network unencrypted)\n'
    ask ch "Plain HTTP" "1"
    case "$ch" in 2) WIZ_HTTP_MODE=redirect ;; 3) WIZ_HTTP_MODE=on ;; *) WIZ_HTTP_MODE=off ;; esac
    if [[ "$WIZ_HTTP_MODE" != off ]]; then
        [[ -n "${CFG[HTTP_PORT]}" ]] || CFG[HTTP_PORT]=8880
        ask_valid HTTP_PORT "Host port for plain HTTP"
        [[ -n "${CFG[HTTP_PORT]}" ]] || { log_warn "No HTTP port: plain HTTP stays off."; WIZ_HTTP_MODE=off; }
    fi
}

# Applied before the container starts (no restart needed)
apply_wizard_tls() {
    [[ -n "$WIZ_TLS_MODE" ]] || return 0
    (( DRY_RUN )) && { log_info "[dry-run] would set HTTPS mode $WIZ_TLS_MODE"; return 0; }
    log_step "HTTPS"
    case "$WIZ_TLS_MODE" in
        custom)      tls_import "$WIZ_TLS_CERT" "$WIZ_TLS_KEY" ;;
        off)         app_ctl set general.tls_mode off >/dev/null; log_warn "HTTPS off: use this only behind a TLS reverse proxy." ;;
        self-signed) [[ "$(tls_get tls_mode)" == self-signed ]] || app_ctl set general.tls_mode self-signed >/dev/null
                     log_ok "HTTPS with a self-signed certificate" ;;
    esac
    if [[ -n "$WIZ_HTTP_MODE" ]]; then
        app_ctl set general.http_mode "$WIZ_HTTP_MODE" >/dev/null
        case "$WIZ_HTTP_MODE" in
            redirect) log_ok "Plain HTTP on port ${CFG[HTTP_PORT]} redirects to HTTPS" ;;
            on)       log_warn "Plain HTTP on port ${CFG[HTTP_PORT]} serves the dashboard unencrypted." ;;
        esac
    fi
    WIZ_TLS_MODE="" WIZ_HTTP_MODE=""
}

# set_http_mode off|redirect|on  -- app setting + make sure the host port is published, then restart
set_http_mode() {
    local m=$1
    require_installed
    if [[ "$m" != off && -z "${CFG[HTTP_PORT]}" ]]; then
        CFG[HTTP_PORT]=8880
        save_config
        log_info "Publishing plain HTTP on host port ${CFG[HTTP_PORT]} (change with --set HTTP_PORT N)."
    fi
    [[ "$m" != off && "$(tls_get tls_mode)" == off ]] && log_warn "HTTPS is off, so the main port already serves HTTP; http_mode has no effect."
    app_ctl set general.http_mode "$m" >/dev/null || return 1
    case "$m" in
        off)      log_ok "Plain HTTP off" ;;
        redirect) log_ok "Plain HTTP port ${CFG[HTTP_PORT]} will redirect to HTTPS" ;;
        on)       log_warn "Plain HTTP port ${CFG[HTTP_PORT]} will serve the dashboard unencrypted" ;;
    esac
    if is_running; then
        write_compose
        run_compose_logged up -d --no-build --force-recreate
        wait_healthy; show_urls
    else
        log_info "Applies at the next start."
    fi
}

menu_https() {
    require_installed
    while :; do
        printf '\n  %sHTTPS%s\n' "$B" "$NC"
        app_ctl tls-info | sed 's/^/    /' || true
        printf '\n   1) Use self-signed   2) Import certificate files   3) Turn HTTPS off\n'
        printf '   4) Set extra names/IPs for self-signed   5) Regenerate self-signed\n'
        printf '   6) Plain HTTP: off / redirect / on (port %s)   0) Back\n' "${CFG[HTTP_PORT]:-not published}"
        local ch c k n; read -rp "  Choice: " ch || return 0
        case "$ch" in
            1) menu_action app_ctl set general.tls_mode self-signed && menu_action tls_apply_restart ;;
            2) ask c "Certificate / full chain PEM path" ""; ask k "Private key PEM path" ""
               [[ -n "$c" && -n "$k" ]] && menu_action tls_import "$c" "$k" && menu_action tls_apply_restart ;;
            3) confirm "Serve plain HTTP? (only behind a TLS reverse proxy)" n && menu_action app_ctl set general.tls_mode off && menu_action tls_apply_restart ;;
            4) ask n "Names/IPs (comma list; detected: $(host_tls_names))" "$(host_tls_names)"
               menu_action app_ctl set general.tls_san "$n" && menu_action tls_apply_restart ;;
            5) menu_action app_ctl tls-regen && menu_action tls_apply_restart ;;
            6) ask n "Plain HTTP (off|redirect|on)" "$(tls_get http_mode)"
               [[ "$n" =~ ^(off|redirect|on)$ ]] && menu_action set_http_mode "$n" ;;
            0|"") return 0 ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# LIFECYCLE
# -----------------------------------------------------------------------------
ensure_dirs() {
    log_step "Folders"
    resolve_ids
    run install -d -m 0755 -o root -g root "${CFG[INSTALL_DIR]}"
    run install -d -m 0700 -o "$PUID" -g "$PGID" "${CFG[DATA_DIR]}"
    # The data dir must belong to the service account (e.g. after a UID change)
    if [[ -d "${CFG[DATA_DIR]}" ]] && [[ -n "$(find "${CFG[DATA_DIR]}" ! -uid "$PUID" -print -quit 2>/dev/null)" ]]; then
        run chown -R "$PUID:$PGID" "${CFG[DATA_DIR]}"
        log_info "Re-owned ${CFG[DATA_DIR]} to $PUID:$PGID"
    fi
    run install -d -m 0700 -o root -g root "${CFG[BACKUP_DIR]}"
    log_ok "Install ${CFG[INSTALL_DIR]}  data ${CFG[DATA_DIR]} (${PUID}:${PGID}, 0700)  backups ${CFG[BACKUP_DIR]}"
}

# build_cmd [nocache]  -- prints the docker build argv, one per line
build_cmd() {
    local -a a=(docker build -t "$(image_ref)"
                --build-arg "BASE_IMAGE=${CFG[BASE_IMAGE]}"
                --build-arg "CRYPTOGRAPHY_VERSION=${CFG[CRYPTOGRAPHY_VERSION]}"
                --build-arg "APP_VERSION=$(current_app_version)"
                --label "net.certifiedgeeks.switch-dashboard.installer=$SCRIPT_VERSION")
    [[ "${CFG[BUILD_NETWORK]}" != default ]] && a+=(--network "${CFG[BUILD_NETWORK]}")
    [[ "${1:-}" == nocache ]] && a+=(--no-cache --pull)
    a+=("${CFG[INSTALL_DIR]}/src")
    printf '%s\n' "${a[@]}"
}

stack_build() {   # stack_build [nocache]
    log_step "Build image $(image_ref)"
    local -a cmd; mapfile -t cmd < <(build_cmd "${1:-}")
    run_logged "${cmd[@]}"
    log_ok "Image $(image_ref) built (base ${CFG[BASE_IMAGE]})"
}

run_compose_logged() {
    if (( DRY_RUN )); then compose_run "$@"; return 0; fi
    if [[ -n "$LOG_FILE" ]]; then compose_run "$@" 2>&1 | tee -a "$LOG_FILE"; else compose_run "$@"; fi
}

stack_up() {
    log_step "Start container"
    run_compose_logged up -d --no-build --remove-orphans
    wait_healthy
    show_urls
}

stack_apply() {   # stack_apply [build|nobuild|nocache]
    local mode=${1:-build}
    preflight
    install_docker
    ensure_service_account
    secrets_init
    ensure_dirs
    sync_source
    write_compose
    install_self
    if [[ "$mode" != nobuild ]] || ! docker image inspect "$(image_ref)" >/dev/null 2>&1; then
        stack_build "$([[ "$mode" == nocache ]] && echo nocache || true)"
    fi
    ensure_admin_user
    apply_wizard_tls
    ensure_tls_names
    stack_up
    tls_fingerprint
    state_set last_apply "$(date '+%F %T') app v$(current_app_version)"
}

stack_stop() {
    log_step "Stop container"
    ensure_config
    [[ -f "$(compose_file)" ]] || { log_info "Not installed."; return 0; }
    run_compose_logged down
    log_ok "Stopped (data kept in ${CFG[DATA_DIR]})"
}

stack_restart() {
    log_step "Restart container"
    ensure_config
    is_running || { stack_up; return; }
    run docker restart "${CFG[CONTAINER_NAME]}" >/dev/null
    wait_healthy
}

# First run: create the first admin user before the container starts (it would otherwise
# create 'admin' with a random password on its own).
ensure_admin_user() {
    (( DRY_RUN )) && { log_info "[dry-run] would create the first admin user if none exists"; return 0; }
    local n; n=$(app_user_count)
    if (( n > 0 )); then
        log_ok "Dashboard users: $n"
        if [[ -f "${CFG[DATA_DIR]}/initial-admin-password" ]]; then
            log_warn "The container generated the first admin password: $(head -n1 "${CFG[DATA_DIR]}/initial-admin-password") (user 'admin')"
            log_info "Stored in ${CFG[DATA_DIR]}/initial-admin-password; change it after signing in, then delete that file."
        fi
        return 0
    fi
    log_step "First dashboard admin"
    local user pw="" generated=0
    ask user "Admin username" "admin"
    [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] || die "Invalid username '$user'"
    if is_tty && (( ! ASSUME_YES )); then
        while [[ ${#pw} -lt 8 ]]; do
            ask_secret pw "Password for $user (8+ chars, Enter = generate one)"
            [[ -z "$pw" ]] && break
            [[ ${#pw} -lt 8 ]] && log_warn "Too short."
        done
    fi
    if [[ -z "$pw" ]]; then pw=$(openssl rand -base64 18 | tr -d '\n/+=' | cut -c1-16); generated=1; fi
    printf '%s\n' "$pw" | app_ctl user add "$user" --role admin --password-stdin >/dev/null
    if (( generated )); then
        printf '%s\n' "$pw" | write_file "$HD_CONF_DIR/initial-admin-password" 600 root:root
        log_ok "Created admin '$user' with a generated password: ${B}${pw}${NC}"
        log_info "Also saved to $HD_CONF_DIR/initial-admin-password (root-only). Change it after signing in, then delete the file."
    else
        log_ok "Created admin '$user'"
    fi
}

show_urls() {
    ensure_config
    local scheme=http ip b=${CFG[BIND_ADDRESS]}
    [[ -f "${CFG[DATA_DIR]}/.scheme" ]] && scheme=$(cat "${CFG[DATA_DIR]}/.scheme" 2>/dev/null || echo http)
    if [[ "$b" == 0.0.0.0 || "$b" == "::" ]]; then ip=$(detect_ip); ip=${ip:-localhost}; else ip=$b; fi
    [[ "$ip" == *:* ]] && ip="[$ip]"
    log_info "Dashboard: ${B}${scheme}://${ip}:${CFG[HOST_PORT]}/${NC}"
    local hm=""
    [[ -f "${CFG[DATA_DIR]}/.http" ]] && hm=$(cat "${CFG[DATA_DIR]}/.http" 2>/dev/null || true)
    if [[ "$scheme" == https && -n "${CFG[HTTP_PORT]}" ]]; then
        case "$hm" in
            on)       log_info "Plain HTTP: ${B}http://${ip}:${CFG[HTTP_PORT]}/${NC} (unencrypted)" ;;
            redirect) log_info "Plain HTTP: http://${ip}:${CFG[HTTP_PORT]}/ redirects to HTTPS" ;;
        esac
    fi
}

show_status() {
    log_step "Status"
    ensure_config
    local cfg_state="not installed"
    [[ -f "$(compose_file)" ]] && cfg_state="installed"
    printf '    %-16s %s\n' "Installer" "v$SCRIPT_VERSION ($SCRIPT_PATH)"
    printf '    %-16s %s\n' "State" "$cfg_state  (last apply: $(state_get last_apply || true))"
    printf '    %-16s %s\n' "Image" "$(image_ref)  base ${CFG[BASE_IMAGE]}  cryptography ${CFG[CRYPTOGRAPHY_VERSION]}"
    printf '    %-16s %s\n' "Publish" "$(port_spec)"
    printf '    %-16s %s\n' "Data" "${CFG[DATA_DIR]}"
    printf '    %-16s %s\n' "Account" "${CFG[SERVICE_USER]} ($(id -u "${CFG[SERVICE_USER]}" 2>/dev/null || echo '?'):$(id -g "${CFG[SERVICE_USER]}" 2>/dev/null || echo '?'))"
    printf '    %-16s %s\n' "Vault" "$( [[ -f "$SECRETS_FILE" ]] && echo "$SECRETS_FILE ($(secrets_file_backend))" || echo "not created")"
    if docker_up; then
        printf '    %-16s %s / health %s\n' "Container" "$(container_state)" "$(container_health)"
        if is_running; then
            show_urls
            printf '\n'
            app_ctl show 2>/dev/null | sed 's/^/    /' || true
        fi
    else
        printf '    %-16s %s\n' "Container" "docker not running"
    fi
}

show_logs() {   # show_logs [N] [follow]
    ensure_config
    local n=${1:-100}
    if [[ "${2:-}" == follow ]]; then docker logs -f --tail "$n" "${CFG[CONTAINER_NAME]}"
    else docker logs --tail "$n" "${CFG[CONTAINER_NAME]}" 2>&1; fi
}

state_get() { cat "$HD_STATE_DIR/$1" 2>/dev/null || true; }
state_set() { (( DRY_RUN )) && return 0; mkdir -p "$HD_STATE_DIR"; printf '%s\n' "$2" >"$HD_STATE_DIR/$1"; }

# -----------------------------------------------------------------------------
# BACKUP / RESTORE
# -----------------------------------------------------------------------------
do_backup() {
    log_step "Backup"
    ensure_config
    [[ -d "${CFG[DATA_DIR]}" ]] || die "Nothing to back up (${CFG[DATA_DIR]} missing)."
    local out; out="${CFG[BACKUP_DIR]}/switch-dashboard-$(date +%Y%m%d-%H%M%S).tar.gz"
    run install -d -m 0700 -o root -g root "${CFG[BACKUP_DIR]}"
    local -a items=("${CFG[DATA_DIR]#/}" "${CONF_FILE#/}")
    [[ -f "$SECRETS_FILE" ]] && items+=("${SECRETS_FILE#/}")
    [[ -f "$KEY_FILE" ]] && items+=("${KEY_FILE#/}")
    local -a ex=(--exclude="${CFG[DATA_DIR]#/}/.ctl-token" --exclude="${CFG[DATA_DIR]#/}/.config.lock")
    if (( DRY_RUN )); then run tar -czf "$out" "${ex[@]}" -C / "${items[@]}"; return 0; fi
    ( umask 077; tar -czf "$out" "${ex[@]}" -C / "${items[@]}" )
    chmod 600 "$out"
    log_ok "Backup written: $out ($(du -h "$out" | cut -f1))"
    log_warn "The archive holds the vault and its key: keep it as private as the switches' passwords."
    [[ "$(secrets_file_backend)" == systemd-creds ]] && \
        log_warn "Vault backend is systemd-creds (host/TPM-bound): this backup restores on THIS host only."
    local old
    while IFS= read -r old; do rm -f -- "$old"; log_info "Pruned $old"; done \
        < <(ls -1t "${CFG[BACKUP_DIR]}"/switch-dashboard-*.tar.gz 2>/dev/null | tail -n +$(( CFG[BACKUP_KEEP] + 1 )))
}

do_restore() {
    local file=$1
    log_step "Restore from $file"
    ensure_config
    [[ -f "$file" ]] || die "No such file: $file"
    local list; list=$(tar -tzf "$file") || die "Not a readable tar.gz: $file"
    grep -qx "${CFG[DATA_DIR]#/}/config.json" <<<"$list" || die "Archive has no ${CFG[DATA_DIR]}/config.json (different DATA_DIR?)."
    if grep -vqE "^(${CFG[DATA_DIR]#/}(/.*)?|${HD_CONF_DIR#/}(/.*)?)$" <<<"$list"; then
        die "Archive contains paths outside ${CFG[DATA_DIR]} and $HD_CONF_DIR; refusing."
    fi
    log_warn "This replaces ${CFG[DATA_DIR]} (switches, users, audit log) and the installer vault/settings."
    confirm_typed RESTORE || { log_info "Cancelled."; return 0; }
    (( DRY_RUN )) && { log_info "[dry-run] would stop, extract, restart"; return 0; }
    stack_stop || true
    local keep; keep="${CFG[DATA_DIR]}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    [[ -d "${CFG[DATA_DIR]}" ]] && mv "${CFG[DATA_DIR]}" "$keep" && log_info "Previous data moved to $keep"
    tar -xzf "$file" -C / --no-same-owner --no-overwrite-dir
    CONFIG_LOADED=0; SECRETS_LOADED=0
    load_config
    load_secrets
    ensure_service_account
    ensure_dirs
    write_compose
    stack_up
}

# -----------------------------------------------------------------------------
# UNINSTALL
# -----------------------------------------------------------------------------
uninstall_stack() {
    log_step "Uninstall"
    ensure_config
    log_warn "Removes the container, image, compose file and build context (${CFG[INSTALL_DIR]}/src)."
    log_info "Data (${CFG[DATA_DIR]}), settings and the vault are kept unless you also purge them."
    confirm_typed UNINSTALL || { log_info "Cancelled."; return 0; }
    if docker_up && [[ -f "$(compose_file)" ]]; then
        run_compose_logged down --rmi local || true
    fi
    docker_up && run docker image rm "$(image_ref)" >/dev/null 2>&1 || true
    safe_path "${CFG[INSTALL_DIR]}/src" && run rm -rf -- "${CFG[INSTALL_DIR]}/src"
    run rm -f -- "$(compose_file)"
    run rm -f -- "$HD_INSTALL_BIN"
    log_ok "Dashboard removed."
    if confirm "Also purge data, settings and the vault (switch list, users, audit log)?" n; then
        log_warn "Purging is permanent. Make a backup first if unsure (--backup)."
        if confirm_typed PURGE-DATA; then
            safe_path "${CFG[DATA_DIR]}" && run rm -rf -- "${CFG[DATA_DIR]}"
            run rm -f -- "$CONF_FILE" "$SECRETS_FILE" "$KEY_FILE" "$HD_CONF_DIR/initial-admin-password"
            run rmdir --ignore-fail-on-non-empty "${CFG[INSTALL_DIR]}" "$HD_CONF_DIR" 2>/dev/null || true
            run rm -rf -- "$HD_STATE_DIR"
            log_ok "Data and settings purged."
        fi
    fi
    if id "${CFG[SERVICE_USER]}" >/dev/null 2>&1 && confirm "Remove service account '${CFG[SERVICE_USER]}'?" n; then
        run userdel "${CFG[SERVICE_USER]}" || true
        getent group "${CFG[SERVICE_USER]}" >/dev/null && run groupdel "${CFG[SERVICE_USER]}" || true
    fi
}

# -----------------------------------------------------------------------------
# FULL INSTALL (wizard)
# -----------------------------------------------------------------------------
full_install() {
    log_step "Install / reconfigure the switch dashboard"
    ensure_config
    [[ -f "$CONF_FILE" ]] && log_info "Existing settings found; press Enter to keep each value."
    wizard_network
    wizard_paths
    wizard_tls
    save_config
    stack_apply build
    if (( ! ASSUME_YES )) && is_tty; then
        local n; n=$(app_ctl show --json 2>/dev/null | grep -c '"host":' || true)
        if (( n == 0 )) && confirm "Add your first switch now?" y; then menu_switch_add; fi
    fi
    log_step "Done"
    show_urls
    log_info "Manage switches/users in the web UI (Settings) or here: $(basename "$HD_INSTALL_BIN") (menu 2)."
}

ask_valid() {   # ask_valid KEY "Prompt"
    local k=$1 p=$2 v
    while :; do
        ask v "$p" "${CFG[$k]}"
        validate_key "$k" "$v" && { CFG[$k]=$v; return 0; }
        log_warn "Invalid value for $k (${CONF_HELP[$k]})"
        if (( ASSUME_YES )) || ! is_tty; then die "Invalid value '$v' for $k"; fi
    done
}

wizard_network() {
    printf '\n  %sNetwork%s\n' "$B" "$NC"
    ask_valid BIND_ADDRESS "Bind address (0.0.0.0 = all interfaces)"
    ask_valid HOST_PORT    "Host port"
    ask_valid TIMEZONE     "Timezone"
}

wizard_paths() {
    printf '\n  %sPaths%s\n' "$B" "$NC"
    ask_valid INSTALL_DIR "Install directory"
    ask_valid DATA_DIR    "Data directory"
    ask_valid BACKUP_DIR  "Backup directory"
}

wizard_container() {
    printf '\n  %sContainer%s\n' "$B" "$NC"
    ask_valid CONTAINER_NAME       "Container name"
    ask_valid IMAGE_NAME           "Image name"
    ask_valid BASE_IMAGE           "Base image (pin)"
    ask_valid CRYPTOGRAPHY_VERSION "cryptography version (pin)"
    ask_valid BUILD_NETWORK        "Build network (default|host)"
    ask_valid RESTART_POLICY       "Restart policy"
    ask_valid MEM_LIMIT            "Memory limit (e.g. 128m, empty = none)"
    ask_valid LOG_MAX_SIZE         "Docker log max size"
    ask_valid LOG_MAX_FILE         "Docker log files kept"
    ask_valid BACKUP_KEEP          "Backups to keep"
}

wizard_account() {
    printf '\n  %sService account%s\n' "$B" "$NC"
    ask_valid SERVICE_USER "Account name"
    ask_valid SERVICE_UID  "UID for a new account (empty = auto)"
    ask_valid SERVICE_GID  "GID for a new account (empty = auto)"
    ask_valid SECRETS_BACKEND "Vault backend (auto|systemd-creds|openssl)"
}

# -----------------------------------------------------------------------------
# APP SETTINGS MENUS (wrap 'switchdash ctl')
# -----------------------------------------------------------------------------
require_installed() {
    ensure_config
    [[ -f "$(compose_file)" ]] || die "Not installed yet (menu 1 / --install)."
}

menu_switch_add() {
    local name host scheme verify timeout prot pw model mch sport save ver suser auth priv pk=""
    printf '\n  Models:\n'
    app_ctl models | awk '{printf "    %d) %s\n", NR, $0}'
    ask mch "Model (number)" "1"
    model=$(app_ctl models | awk -v n="$mch" 'NR == n {print $1}')
    [[ -n "$model" ]] || { log_warn "No such model."; return 1; }
    ask name "Switch name (letters, digits, . _ -)" ""
    [[ -n "$name" ]] || { log_info "Cancelled."; return 0; }
    ask host "Host (IP or name)" ""
    ask timeout "Timeout seconds (number|inherit)" "inherit"
    ask prot "Protected ports (comma list, e.g. 8; empty = none)" ""
    local -a a=(switch add "$name" "$host" --model "$model" --timeout "$timeout" --protected "$prot")
    if app_ctl models | awk -v m="$model" '$1 == m' | grep -qw snmp; then
        ask ver "SNMP version (3 = authenticated + encrypted, recommended | 2c)" "3"
        ask sport "SNMP UDP port" "161"
        ask save "Save to the switch's startup config after each change (yes|no)" "yes"
        a+=(--snmp-version "$ver" --snmp-port "$sport" --save-config "$save")
        if [[ "$ver" == 3 ]]; then
            log_info "GS110TP: enable SNMPv3 for the admin user; its auth password is the admin login password."
            ask suser "SNMPv3 user" "admin"
            ask auth "Authentication (sha|md5|sha256|none)" "sha"
            ask priv "Encryption (des|aes|none; GS110TP supports des)" "des"
            a+=(--snmp-user "$suser" --auth-proto "$auth" --priv-proto "$priv")
            if [[ "$auth" != none ]]; then
                ask_secret pw "Auth password (8+ characters)"
                [[ -n "$pw" ]] || { log_warn "An auth password is required."; return 1; }
                if [[ "$priv" != none ]]; then
                    ask_secret pk "Encryption key (Enter = same as the auth password)"
                fi
            fi
        else
            log_warn "v2c sends the community in cleartext. Limit it to this host on the switch."
            ask_secret pw "SNMP write community"
            [[ -n "$pw" ]] || { log_warn "A community is required for SNMP v2c."; return 1; }
        fi
    else
        ask scheme "Scheme (http|https|inherit)" "inherit"
        ask verify "Verify TLS (yes|no|inherit)" "inherit"
        ask_secret pw "Switch password (Enter = use the default password)"
        a+=(--scheme "$scheme" --verify-tls "$verify")
    fi
    if [[ -n "$pw" && -n "$pk" ]]; then printf '%s\n%s\n' "$pw" "$pk" | app_ctl "${a[@]}" --password-stdin --priv-key-stdin
    elif [[ -n "$pw" ]]; then printf '%s\n' "$pw" | app_ctl "${a[@]}" --password-stdin
    else app_ctl "${a[@]}"; fi
    confirm "Test the connection now?" y && app_ctl switch test "$name" || true
}

# ---- port picker: list switches, then that switch's ports, then act -------------------------
# switch_names  -- configured switch names, in order
switch_names() { app_ctl switch list 2>/dev/null | awk 'NR > 2 && NF {print $2}'; }

# port_picker [SWITCH] [PORT] [up|down]  -- prompts for whatever is missing
port_picker() {
    require_installed
    local sw=${1:-} port=${2:-} state=${3:-} ch cur label table
    local -a names; mapfile -t names < <(switch_names)
    (( ${#names[@]} )) || die "No switches configured yet (Settings -> Switches, or --ctl switch add)."
    if [[ -z "$sw" ]]; then
        is_tty || die "Usage: --port SWITCH N up|down (configured: ${names[*]})"
        printf '\n'; app_ctl switch list | sed 's/^/    /'
        ask ch "Switch (number or name)" "1"
        if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#names[@]} )); then sw=${names[ch - 1]}; else sw=$ch; fi
    fi
    in_list "$sw" "${names[@]}" || die "No switch named '$sw'. Configured: ${names[*]}"
    if [[ -z "$port" || -z "$state" ]]; then
        is_tty || die "Usage: --port $sw N up|down"
        printf '\n'
        table=$(app_ctl ports "$sw") || { printf '%s\n' "$table" | sed 's/^/    /'; die "Cannot read ports from $sw."; }
        printf '%s\n' "$table" | sed 's/^/    /'
        [[ -n "$port" ]] || ask port "Port number" ""
        [[ "$port" =~ ^[0-9]+$ ]] || die "Not a port number: '$port'"
        local row; row=$(app_ctl ports "$sw" --tsv | awk -F'\t' -v p="$port" '$1 == p')
        cur=$(cut -f3 <<<"$row"); label=$(cut -f2 <<<"$row")
        [[ -n "$cur" ]] || die "$sw has no port $port."
        if [[ -z "$state" ]]; then
            local def=down; [[ "$cur" == down ]] && def=up
            ask state "Set port $port${label:+ ($label)} to (up|down); currently ${cur,,}" "$def"
        fi
        [[ "$state" =~ ^(up|down)$ ]] || die "State must be up or down."
        confirm "$([[ $state == down ]] && echo Disable || echo Enable) port $port${label:+ ($label)} on $sw?" n || { log_info "Cancelled."; return 0; }
    fi
    app_ctl port "$sw" "$port" "$state"
}

menu_switch_edit() {
    local name f v pw
    app_ctl switch list
    ask name "Switch to edit" ""
    [[ -n "$name" ]] || return 0
    app_ctl switch show "$name" || return 0
    log_info "Enter a new value, '-' to keep, or 'inherit' to use the default."
    local -a a=(switch edit "$name")
    for f in host scheme verify-tls timeout username protected notes rename; do
        ask v "$f" "-"
        [[ "$v" == "-" ]] && continue
        a+=("--$f" "$v")
    done
    ask v "Polling (on|off|-)" "-"
    case "$v" in on) a+=(--enable) ;; off) a+=(--disable) ;; esac
    ask v "Password: (k)eep, (s)et new, (d)efault" "k"
    case "$v" in
        s) ask_secret pw "New switch password"; [[ -n "$pw" ]] && { printf '%s\n' "$pw" | app_ctl "${a[@]}" --password-stdin; return; } ;;
        d) a+=(--clear-password) ;;
    esac
    app_ctl "${a[@]}"
}

menu_switches() {
    require_installed
    while :; do
        printf '\n  %sSwitches%s\n' "$B" "$NC"
        app_ctl switch list | sed 's/^/    /' || true
        printf '\n   1) Add   2) Edit   3) Remove   4) Test one   5) Test all   6) Name a port   0) Back\n'
        local ch name; read -rp "  Choice: " ch || return 0
        case "$ch" in
            1) menu_action menu_switch_add ;;
            2) menu_action menu_switch_edit ;;
            3) ask name "Switch to remove" ""; [[ -n "$name" ]] && confirm "Remove '$name' (and its stored password)?" n && menu_action app_ctl switch remove "$name" ;;
            4) ask name "Switch to test" ""; [[ -n "$name" ]] && menu_action app_ctl switch test "$name" ;;
            5) menu_action app_ctl switch test all ;;
            6) local pn pl; ask name "Switch" ""; [[ -n "$name" ]] && app_ctl port-names "$name" | sed 's/^/    /'
               ask pn "Port number" ""; ask pl "Display name (empty = clear)" ""
               [[ -n "$name" && -n "$pn" ]] && menu_action app_ctl port-name "$name" "$pn" "$pl" ;;
            0|"") return 0 ;;
        esac
    done
}

menu_users() {
    require_installed
    while :; do
        printf '\n  %sDashboard users%s  (viewer: read · operator: + ports, audit · admin: + settings)\n' "$B" "$NC"
        app_ctl user list | sed 's/^/    /' || true
        printf '\n   1) Add   2) Change role   3) Reset password   4) Remove   0) Back\n'
        local ch u r pw; read -rp "  Choice: " ch || return 0
        case "$ch" in
            1) ask u "Username" ""; ask r "Role (viewer|operator|admin)" "operator"; ask_secret pw "Password (8+ chars)"
               [[ -n "$u" && -n "$pw" ]] && { printf '%s\n' "$pw" | menu_action app_ctl user add "$u" --role "$r" --password-stdin; } ;;
            2) ask u "Username" ""; ask r "New role (viewer|operator|admin)" "operator"; [[ -n "$u" ]] && menu_action app_ctl user edit "$u" --role "$r" ;;
            3) ask u "Username" ""; ask_secret pw "New password (8+ chars)"
               [[ -n "$u" && -n "$pw" ]] && { printf '%s\n' "$pw" | menu_action app_ctl user edit "$u" --password-stdin; } ;;
            4) ask u "Username" ""; [[ -n "$u" ]] && confirm "Remove user '$u'?" n && menu_action app_ctl user remove "$u" ;;
            0|"") return 0 ;;
        esac
    done
}

menu_app_settings() {   # menu_app_settings general|defaults
    require_installed
    local sec=$1
    while :; do
        printf '\n  %sApp settings: %s%s\n' "$B" "$sec" "$NC"
        app_ctl keys | grep "^$sec\." | sed 's/^/    /' || true
        printf '\n  Current:\n'
        app_ctl show | awk -v s="[$sec]" '$0 == s {f = 1; next} /^\[/ {f = 0} f' | sed 's/^/    /' || true
        local k v pw
        read -rp "  Key to change (e.g. poll_interval; Enter = back): " k || return 0
        [[ -n "$k" ]] || return 0
        if [[ "$sec.$k" == defaults.password ]]; then
            ask_secret pw "Default switch password (Enter on empty = clear it)"
            if [[ -n "$pw" ]]; then printf '%s\n' "$pw" | menu_action app_ctl set defaults.password --password-stdin
            else confirm "Clear the default switch password?" n && menu_action app_ctl unset-default-password; fi
            continue
        fi
        if [[ "$sec" == general && ( "$k" == tls_cert || "$k" == tls_key ) ]]; then
            local c kf
            log_info "Certificate and key are set together; paths are inside the container (copy files to DATA_DIR/tls)."
            ask c "Certificate path (empty = plain HTTP)" "/data/tls/fullchain.pem"
            ask kf "Private key path" "/data/tls/privkey.pem"
            [[ -z "$c" ]] && kf=""
            menu_action app_ctl set general.tls_cert "$c" general.tls_key "$kf"
            log_info "Restart the container to apply (main menu 7)."
            continue
        fi
        ask v "New value for $sec.$k" ""
        menu_action app_ctl set "$sec.$k" "$v"
    done
}

menu_host_settings() {
    ensure_config
    while :; do
        show_config
        printf '\n   1) Network (bind, port, timezone)   2) Paths   3) Container (image pins, limits, logs)\n'
        printf '   4) Service account / vault          5) Edit one key\n'
        printf '   A) Save + apply   W) Save only   R) Re-encrypt vault   0) Back (discard unsaved)\n'
        local ch k v; read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            1) wizard_network ;;
            2) wizard_paths ;;
            3) wizard_container ;;
            4) wizard_account ;;
            5) read -rp "  Key: " k || true; [[ -n "$k" ]] && { ask v "$k" "${CFG[$k]:-}"; ( set_conf_value "$k" "$v" ) && CFG[$k]=$v; } ;;
            w) save_config ;;
            a) save_config; menu_action stack_apply build; return 0 ;;
            r) save_config; menu_action secrets_rekey ;;
            0|"") CONFIG_LOADED=0; load_config; return 0 ;;
        esac
    done
}

menu_settings() {
    while :; do
        printf '\n  %sSettings%s\n' "$B" "$NC"
        printf '   1) Switches            (add, edit, remove, test)\n'
        printf '   2) Switch defaults     (scheme, TLS verify, timeout, user, default password)\n'
        printf '   3) Dashboard users     (viewer / operator / admin)\n'
        printf '   4) Dashboard general   (poll interval, sessions, lockout, audit, TLS cert)\n'
        printf '   5) Container / host    (port, bind, paths, image pins, account, vault)\n'
        printf '   6) HTTPS certificate   (self-signed, import, off, names, regenerate)\n'
        printf '   V) View everything     0) Back\n'
        local ch; read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            1) menu_action menu_switches ;;
            2) menu_action menu_app_settings defaults ;;
            3) menu_action menu_users ;;
            4) menu_action menu_app_settings general ;;
            5) menu_host_settings ;;
            6) menu_action menu_https ;;
            v) show_config; require_installed && { printf '\n'; app_ctl show | sed 's/^/    /'; } ;;
            0|"") return 0 ;;
        esac
    done
}

menu_logs() {
    ensure_config
    printf '\n   1) Container log (last 100)   2) Follow container log (Ctrl-C to stop)\n'
    printf '   3) Audit log (last 50)        4) Installer run logs\n   0) Back\n'
    local ch; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) show_logs 100 | sed 's/^/  /' ;;
        2) show_logs 50 follow || true ;;
        3) app_ctl audit --tail 50 | sed 's/^/  /' ;;
        4) ls -1t "$HD_LOG_DIR"/installer-*.log 2>/dev/null | head -n 10 | sed 's/^/  /'
           local f; f=$(ls -1t "$HD_LOG_DIR"/installer-*.log 2>/dev/null | sed -n 2p)
           [[ -n "$f" ]] && { printf '\n  %sPrevious run: %s%s\n' "$B" "$f" "$NC"; tail -n 40 "$f" | sed 's/^/  /'; } ;;
    esac
}

menu_uninstall() {
    printf '\n   1) Uninstall dashboard (keyword UNINSTALL; data kept unless purged)\n   0) Back\n'
    local ch; read -rp "  Choice: " ch || return 0
    [[ "$ch" == 1 ]] && menu_action uninstall_stack
    return 0
}

# -----------------------------------------------------------------------------
# SELF-TEST
# -----------------------------------------------------------------------------
self_test() {
    log_step "Self-test ($SCRIPT_NAME v$SCRIPT_VERSION)"
    local pass=0 fail=0 t
    t=$(mktemp -d)
    st() { if eval "$2" >/dev/null 2>&1; then printf '  %s[PASS]%s %s\n' "$G" "$NC" "$1"; pass=$((pass + 1)); else printf '  %s[FAIL]%s %s\n' "$R" "$NC" "$1"; fail=$((fail + 1)); fi; }

    st "bash syntax"                       'bash -n "$SCRIPT_PATH"'
    st "version is semver"                 '[[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
    st "conf quote round-trip"             "[[ \"\$(conf_unquote \"\$(conf_quote \"it's \\\$x\")\")\" == \"it's \\\$x\" ]]"
    st "port validator"                    'valid_port 8810 && valid_port 1 && ! valid_port 0 && ! valid_port 65536 && ! valid_port 80a'
    st "bind validator"                    'valid_bind 0.0.0.0 && valid_bind 192.168.0.5 && valid_bind :: && valid_bind fd00::1 && ! valid_bind 300.1.1.1 && ! valid_bind host.lan'
    st "image validator"                   'valid_image python:3.13-slim-bookworm && valid_image "python:3.13-slim@sha256:$(printf "a%.0s" {1..64})" && ! valid_image "py\$x" && ! valid_image "Bad:Tag"'
    st "size / uid validators"             'valid_size 128m && ! valid_size 128 && valid_memlimit "" && valid_id "" && valid_id 990 && ! valid_id 0 && ! valid_id 70000'
    st "key validation dispatch"           'validate_key HOST_PORT 9000 && ! validate_key HOST_PORT 0 && validate_key RESTART_POLICY always && ! validate_key RESTART_POLICY sometimes && ! validate_key NOPE x'
    st "safe_path rejects / /opt /home/x"  '! safe_path / && ! safe_path /opt && ! safe_path /data && ! safe_path /home/alice && ! safe_path "" && ! safe_path rel/dir && ! safe_path /opt/../etc'
    st "safe_path accepts /opt/switch-dashboard/data" 'safe_path /opt/switch-dashboard/data && safe_path /srv/switchdash'
    st "path keys refuse top-level dirs"   '! validate_key DATA_DIR /opt && ! validate_key DATA_DIR "/opt/a b" && validate_key DATA_DIR /opt/hp/data'
    st "source available (checkout/embedded)" 'is_source_dir "$SCRIPT_DIR" || has_payload'
    st "app version is semver"             '[[ "$(current_app_version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
    if has_payload; then
        st "embedded source: sha256 + layout" '( extract_payload "$t/payload" >/dev/null 2>&1 && is_source_dir "$t/payload" )'
        st "embedded source: version matches" '[[ "$(app_version_of "$t/payload")" == "$(payload_field app)" ]]'
        st "script body stops before payload" '[[ "$(script_body "$SCRIPT_PATH" | tail -n1)" == "exit \$?" ]]'
    fi
    st "prereq map covers required tools"  'for c in curl tar gzip openssl ip awk base64 sha256sum flock useradd; do [[ -n "${PREREQ_PKG[$c]:-}" ]] || exit 1; done'
    st "config save/load round-trip"       '(
        HD_CONF_DIR="$t/c"; CONF_FILE="$t/c/x.conf"; DRY_RUN=0; LOG_FILE=""
        set_default_config; CFG[HOST_PORT]=9443; CFG[BASE_IMAGE]="python:3.13-slim@sha256:$(printf "b%.0s" {1..64})"
        chown() { :; }; save_config >/dev/null; CFG=(); CONFIG_LOADED=0; load_config
        [[ "${CFG[HOST_PORT]}" == 9443 && "${CFG[BASE_IMAGE]}" == *@sha256:bbbb* && $(stat -c %a "$CONF_FILE") == 600 ]] )'
    st "invalid value in conf ignored"     '(
        HD_CONF_DIR="$t/d"; CONF_FILE="$t/d/x.conf"; mkdir -p "$t/d"; printf "HOST_PORT=%s\n" "'"'"'99999'"'"'" >"$CONF_FILE"
        CONFIG_LOADED=0; load_config 2>/dev/null; [[ "${CFG[HOST_PORT]}" == 8810 ]] )'
    st "compose: secret not embedded"      '(
        set_default_config; SECRETS[APP_SECRET_KEY]=TOPSECRETVALUE; PUID=990; PGID=990; APP_VERSION=2.0.0
        resolve_ids() { :; }; out=$(render_compose)
        [[ "$out" != *TOPSECRETVALUE* && "$out" == *"\${SWDASH_SECRET_KEY:?"* ]] )'
    st "compose: hardening + mapping"      '(
        set_default_config; PUID=990; PGID=991; APP_VERSION=2.0.0; resolve_ids() { :; }
        CFG[BIND_ADDRESS]=fd00::5; CFG[HOST_PORT]=9000; out=$(render_compose)
        [[ "$out" == *"read_only: true"* && "$out" == *"cap_drop: [\"ALL\"]"* && "$out" == *"no-new-privileges:true"* &&
           "$out" == *"\"[fd00::5]:9000:8810\""* && "$out" == *"user: \"990:991\""* && "$out" == *"pull_policy: never"* &&
           "$out" == *"image: \"switch-dashboard:2.0.0\""* && "$out" != *"build:"* ]] )'
    st "compose: hostname + self-restart"  '(
        set_default_config; PUID=1; PGID=1; APP_VERSION=2.1.0; resolve_ids() { :; }; host_short() { echo gold; }
        out=$(render_compose); [[ "$out" == *"hostname: \"gold\""* && "$out" == *"SWDASH_SELF_RESTART: \"1\""* ]] &&
        CFG[RESTART_POLICY]=no && [[ "$(render_compose)" == *"SWDASH_SELF_RESTART: \"0\""* ]] )'
    st "compose: http port published"      '(
        set_default_config; PUID=1; PGID=1; APP_VERSION=3.0.0; resolve_ids() { :; }
        out=$(render_compose); [[ "$out" == *"\"0.0.0.0:8880:8880\""* && "$out" == *"SWDASH_PUBLIC_HTTPS_PORT: \"8810\""* ]] &&
        CFG[HTTP_PORT]="" && out=$(render_compose) && [[ "$out" != *":8880:8880"* && "$out" == *"\"0.0.0.0:8810:8810\""* ]] )'
    st "http port validation"              '(set_default_config; validate_key HTTP_PORT "" && validate_key HTTP_PORT 8080 && ! validate_key HTTP_PORT 8810 && ! validate_key HTTP_PORT 0)'
    st "upgrade maps old default names"    '(
        set_default_config; CFG[INSTALL_DIR]=/opt/hp1810-dashboard; CFG[DATA_DIR]=/srv/custom/data
        CFG[CONTAINER_NAME]=hp1810-dashboard; CFG[SERVICE_USER]=hp1810dash; CFG[BACKUP_DIR]=/var/backups/hp1810-dashboard
        legacy_map
        [[ "${CFG[INSTALL_DIR]}" == /opt/switch-dashboard && "${CFG[DATA_DIR]}" == /srv/custom/data &&
           "${CFG[CONTAINER_NAME]}" == switch-dashboard && "${CFG[SERVICE_USER]}" == switchdash &&
           "${CFG[BACKUP_DIR]}" == /var/backups/switch-dashboard ]] )'
    st "upgrade reads the old vault"       '(
        HD_LEGACY_CONF_DIR="$t/legacy"; mkdir -p "$t/legacy"; printf k3y > "$t/legacy/.secrets.key"
        { printf "# hp1810-dashboard-secrets v1 backend=openssl\n"
          printf "APP_SECRET_KEY=%s\n" "$(printf abc | base64 -w0)" |
            openssl enc -aes-256-cbc -pbkdf2 -iter 250000 -salt -a -pass "file:$t/legacy/.secrets.key"; } > "$t/legacy/secrets.enc"
        [[ "$(legacy_secrets_decrypt)" == "APP_SECRET_KEY=YWJj" ]] )'
    st "tls names skip docker bridges"     '(
        ip() { printf "%s\n" "2: eth0 inet 192.168.0.20/24 brd x" "3: docker0 inet 172.17.0.1/16 brd x" "4: br-ab12 inet 172.18.0.1/16 brd x" "5: ens19 inet 10.0.0.5/24 brd x"; }
        hostname() { [[ "$1" == -f ]] && echo Gold.Lab.Lan || echo gold; }
        [[ "$(host_tls_names)" == "gold.lab.lan,192.168.0.20,10.0.0.5" ]] )'
    st "switch_names parses ctl table"     '(
        app_ctl() { printf "%s\n" "#  NAME       MODEL" "-  ---------  -----" "1  office-sw  HP 1810-8G" "2  garage-sw  Netgear GS110TP"; }
        [[ "$(switch_names | xargs)" == "office-sw garage-sw" ]] )'
    st "port picker names unknown switch"  '(
        app_ctl() { printf "%s\n" "#  NAME" "-  ----" "1  office-sw"; }; require_installed() { :; }
        out=$(port_picker nope 3 down 2>&1); [[ $? -ne 0 && "$out" == *"Configured: office-sw"* ]] )'
    st "compose: optional keys"            '(
        set_default_config; PUID=1; PGID=1; APP_VERSION=2.0.0; resolve_ids() { :; }
        CFG[MEM_LIMIT]=""; out=$(render_compose); [[ "$out" != *mem_limit* ]] )'
    st "build command: pins + network"     '(
        set_default_config; APP_VERSION=2.0.0; CFG[BUILD_NETWORK]=host
        out=$(build_cmd nocache | tr "\n" " ")
        [[ "$out" == *"-t switch-dashboard:2.0.0 "* && "$out" == *"BASE_IMAGE=python:3.13-slim-bookworm "* &&
           "$out" == *"CRYPTOGRAPHY_VERSION=50.0.2 "* && "$out" == *"--network host "* && "$out" == *"--no-cache --pull "* ]] &&
        CFG[BUILD_NETWORK]=default && [[ "$(build_cmd | tr "\n" " ")" != *--network* ]] )'
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        st "compose: docker compose config -q" '(
            set_default_config; PUID=990; PGID=990; APP_VERSION=2.0.0; resolve_ids() { :; }
            CFG[INSTALL_DIR]="$t/inst"; mkdir -p "$t/inst/src"; render_compose >"$t/dc.yml"
            SWDASH_SECRET_KEY=x docker compose -f "$t/dc.yml" -p hdtest config -q )'
        st "compose: refuses to start w/o key" '(
            set_default_config; PUID=990; PGID=990; APP_VERSION=2.0.0; resolve_ids() { :; }
            CFG[INSTALL_DIR]="$t/inst"; mkdir -p "$t/inst/src"; render_compose >"$t/dc.yml"
            ! env -u SWDASH_SECRET_KEY docker compose -f "$t/dc.yml" -p hdtest config -q )'
    fi
    st "secrets round-trip (openssl)"      '(
        HD_CONF_DIR="$t/conf"; SECRETS_FILE="$t/conf/secrets.enc"; KEY_FILE="$t/conf/.k"; CFG[SECRETS_BACKEND]=openssl
        DRY_RUN=0; LOG_FILE=""
        SECRETS=([APP_SECRET_KEY]="k3y'"'"'w\"rd \$x\\y")
        save_secrets && SECRETS=() && SECRETS_LOADED=0 && load_secrets &&
        [[ "${SECRETS[APP_SECRET_KEY]}" == "k3y'"'"'w\"rd \$x\\y" ]] &&
        ! grep -q k3y "$SECRETS_FILE" && [[ $(stat -c %a "$SECRETS_FILE") == 600 ]] )'
    if [[ "$(secrets_backend_resolve)" == systemd-creds && $EUID -eq 0 ]]; then
        st "systemd-creds encrypt/decrypt"  '[[ "$(printf hello | systemd-creds encrypt --name=switchdash-selftest - - | systemd-creds decrypt --name=switchdash-selftest - -)" == hello ]]'
    fi
    rm -rf "$t"
    printf '\n  Result: %s%d passed%s, %s%d failed%s\n' "$G" "$pass" "$NC" "$( ((fail)) && echo "$R" || echo "$G")" "$fail" "$NC"
    _log_file SELFTEST "pass=$pass fail=$fail"
    [[ $fail -eq 0 ]]
}

# App self-test inside the built image (protocol, crypto, API, roles, CLI against a mock switch)
app_self_test() {
    log_step "App self-test (inside the image)"
    ensure_config
    docker image inspect "$(image_ref)" >/dev/null 2>&1 || die "Image $(image_ref) not built yet (run --apply)."
    run docker run --rm --read-only --tmpfs /tmp --network none -e SWDASH_SECRET_KEY=selftest \
        --entrypoint python3 "$(image_ref)" /app/switchdash.py selftest
}

# -----------------------------------------------------------------------------
# MENUS
# -----------------------------------------------------------------------------
menu_action() {
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
    local inst="${Y}not installed${NC}" ctr="docker not running" mode
    [[ -f "$(compose_file)" ]] && inst="${G}installed${NC}"
    if ! command -v docker >/dev/null 2>&1; then ctr="docker not installed (installed by 1)"
    elif docker_up; then ctr="$(container_state) / $(container_health)"; fi
    (( DRY_RUN )) && mode="${Y}DRY-RUN${NC}" || mode="${G}LIVE${NC}"
    printf '\n  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  %s|%s  %sSwitch Dashboard%s  v%-8s  host: %-23s%s|%s\n' "$C" "$NC" "$B" "$NC" "$SCRIPT_VERSION" "$(hostname -s | cut -c1-23)" "$C" "$NC"
    printf '  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  State: %b   Container: %s   Mode: %b\n' "$inst" "$ctr" "$mode"
}

main_menu() {
    while :; do
        show_banner
        printf '\n  %sSetup%s\n' "$B" "$NC"
        printf '   1) Full install / reconfigure\n   2) Settings (switches, users, app, container)\n'
        printf '  %sOperate%s\n' "$B" "$NC"
        printf '   3) Apply             (re-render, build if needed, start)\n'
        printf '   4) Rebuild image     (no cache, re-pull base, start)\n'
        printf '   5) Start   6) Stop   7) Restart\n'
        printf '   8) Status            9) Logs / audit\n'
        printf '   P) Port up/down     (pick a switch, see its ports, change one)\n'
        printf '  %sMaintenance%s\n' "$B" "$NC"
        printf '   B) Backup   R) Restore...   U) Uninstall...\n'
        printf '   T) Toggle dry-run   S) Self-test   0) Quit\n\n'
        local ch f; read -rp "  Choice: " ch || exit 0
        case "${ch,,}" in
            1) menu_action full_install ;;
            2) menu_settings ;;
            3) menu_action stack_apply build ;;
            4) menu_action stack_apply nocache ;;
            5) menu_action stack_up ;;
            6) menu_action stack_stop ;;
            7) menu_action stack_restart ;;
            8) menu_action show_status ;;
            9) menu_logs ;;
            p) menu_action port_picker ;;
            b) menu_action do_backup ;;
            r) ls -1t "${CFG[BACKUP_DIR]}"/switch-dashboard-*.tar.gz 2>/dev/null | head -n 5 | sed 's/^/    /'
               ask f "Archive to restore" "$(ls -1t "${CFG[BACKUP_DIR]}"/switch-dashboard-*.tar.gz 2>/dev/null | head -n1)"
               [[ -n "$f" ]] && menu_action do_restore "$f" ;;
            u) menu_uninstall ;;
            t) DRY_RUN=$(( 1 - DRY_RUN )); log_info "Dry-run is now $( ((DRY_RUN)) && echo ON || echo OFF)"; continue ;;
            s) menu_action self_test; docker_up && docker image inspect "$(image_ref)" >/dev/null 2>&1 && menu_action app_self_test ;;
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
$SCRIPT_NAME v$SCRIPT_VERSION -- switch port dashboard (HP 1810-8G, Netgear GS110TP) installer and lifecycle manager

Usage: sudo $(basename "$SCRIPT_PATH") [options] [action]

Actions (default: interactive menu)
  --install              Full install / reconfigure (wizard, vault, Docker, account, build, start)
  --apply                Re-render compose, build the image if missing/changed, start
  --rebuild              Rebuild the image without cache (re-pulls the base image), start
  --start | --stop | --restart
  --status               Settings, container health, URL and app configuration
  --logs [N]             Last N container log lines (default 100)
  --audit [N]            Last N audit entries (default 50)
  --settings             Settings menu (switches, users, app, container)
  --show-config          Print container/host settings
  --set KEY VALUE        Change one container/host setting (see --show-config), then --apply
  --ctl ARGS...          Run 'switchdash ctl ARGS' in the container (switches, users, app settings);
                         try: --ctl --help | --ctl keys | --ctl switch --help
  --port [SWITCH [N [up|down]]]  Enable/disable a port (audited). Missing parts are prompted for:
                         lists the configured switches, then that switch's ports with names and state
  --ports [SWITCH]       Show ports (name, admin, link, speed) of one switch, or of all
  --port-name SWITCH N NAME  Name a port for display ('' clears)
  --tls-info             Show HTTPS mode and certificate (names, expiry, SHA-256)
  --tls-import CERT KEY  Use your own certificate (PEM chain + key on this host), then restart
  --tls-mode MODE        self-signed | off  (custom is set by --tls-import), then restart
  --tls-names LIST       Extra names/IPs for the self-signed certificate, then restart
  --tls-regen            New self-signed certificate, then restart
  --http-mode MODE       Plain HTTP next to HTTPS: off | redirect | on (on HTTP_PORT, default 8880), then restart
  --backup               Archive data + settings + vault to BACKUP_DIR
  --restore FILE         Restore an archive (keyword RESTORE)
  --rekey                Re-encrypt the vault with the configured SECRETS_BACKEND
  --uninstall            Remove container/image/build files (keyword UNINSTALL; data kept unless purged)
  --self-test            Run installer tests (no root needed)
  --build-standalone OUT Write a self-contained installer (this script + app source) to OUT
  --app-self-test        Run the app's tests inside the built image
  --version | -h, --help

Options
  --dry-run              Show what would change; change nothing
  --yes                  Accept defaults for all prompts (non-interactive)
  --source DIR           Repository checkout to build from (default: next to this script)
  --confirm KEYWORD      Pre-answer a typed confirmation (UNINSTALL, PURGE-DATA, RESTORE)

Examples
  sudo $(basename "$HD_INSTALL_BIN") --ctl switch add office-sw 192.168.0.51 --protected 8 --password-prompt
  sudo $(basename "$HD_INSTALL_BIN") --ctl set general.poll_interval 15
  echo 'S3cret' | sudo $(basename "$HD_INSTALL_BIN") --ctl user add matt --role admin --password-stdin
  sudo $(basename "$HD_INSTALL_BIN") --set HOST_PORT 9443 && sudo $(basename "$HD_INSTALL_BIN") --apply

Files
  $CONF_FILE    container/host settings (0600)
  $SECRETS_FILE         encrypted vault (app secret key)
  <DATA_DIR>/config.json                      app settings, switches (passwords encrypted), users (hashed)
  <DATA_DIR>/audit.log                        audit trail (rotated)
  $HD_LOG_DIR/installer-*.log    run logs (newest $LOG_KEEP kept)
EOF
}

check_root() {
    [[ $EUID -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "Run as root (sudo not found)."
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

acquire_lock() {
    exec 9>"$HD_LOCK_FILE"
    flock -n 9 || die "Another $SCRIPT_NAME run is in progress ($HD_LOCK_FILE)."
}

main() {
    local action="menu" arg1="" arg2="" arg3=""; local -a ctl_args=() set_kv=() orig=("$@")
    while (( $# )); do
        case "$1" in
            --install)       action=install ;;
            --apply)         action=apply ;;
            --rebuild)       action=rebuild ;;
            --start)         action=start ;;
            --stop)          action=stop ;;
            --restart)       action=restart ;;
            --status)        action=status ;;
            --logs)          action=logs; [[ "${2:-}" =~ ^[0-9]+$ ]] && { arg1=$2; shift; } ;;
            --audit)         action=audit; [[ "${2:-}" =~ ^[0-9]+$ ]] && { arg1=$2; shift; } ;;
            --settings)      action=settings ;;
            --show-config)   action=showconfig ;;
            --set)           action="set"; (( $# >= 3 )) || die "--set needs KEY VALUE"; set_kv=("$2" "$3"); shift 2 ;;
            --ctl)           action=ctl; shift; ctl_args=("$@"); break ;;
            --port)          action=port
                             [[ -n "${2:-}" && "${2:-}" != --* ]] && { arg1=$2; shift; }
                             [[ -n "${2:-}" && "${2:-}" != --* ]] && { arg2=$2; shift; }
                             [[ -n "${2:-}" && "${2:-}" != --* ]] && { arg3=$2; shift; } ;;
            --ports)         action=ports; arg1=${2:-}; [[ -n "$arg1" && "$arg1" != --* ]] && shift || arg1="" ;;
            --backup)        action=backup ;;
            --tls-info)      action=tlsinfo ;;
            --port-name)     action=portname; (( $# >= 4 )) || die "--port-name needs SWITCH N NAME"; arg1=$2; arg2=$3; arg3=$4; shift 3 ;;
            --tls-import)    action=tlsimport; (( $# >= 3 )) || die "--tls-import needs CERT KEY"; arg1=$2; arg2=$3; shift 2 ;;
            --tls-mode)      action=tlsmode; arg1=${2:-}; [[ "$arg1" =~ ^(self-signed|off)$ ]] || die "--tls-mode self-signed|off"; shift ;;
            --tls-names)     action=tlsnames; (( $# >= 2 )) || die "--tls-names needs LIST"; arg1=$2; shift ;;
            --tls-regen)     action=tlsregen ;;
            --http-mode)     action=httpmode; arg1=${2:-}; [[ "$arg1" =~ ^(off|redirect|on)$ ]] || die "--http-mode off|redirect|on"; shift ;;
            --restore)       action=restore; arg1=${2:-}; [[ -n "$arg1" ]] || die "--restore needs FILE"; shift ;;
            --rekey)         action=rekey ;;
            --uninstall)     action=uninstall ;;
            --self-test)     action=selftest ;;
            --build-standalone) action=standalone; arg1=${2:-}; [[ -n "$arg1" ]] || die "--build-standalone needs OUT"; shift ;;
            --app-self-test) action=appselftest ;;
            --dry-run)       DRY_RUN=1 ;;
            --yes|-y)        ASSUME_YES=1 ;;
            --source)        SOURCE_OVERRIDE=${2:-}; [[ -n "$SOURCE_OVERRIDE" ]] || die "--source needs DIR"; shift ;;
            --confirm)       CONFIRM_KEYWORD=${2:-}; shift ;;
            --version)       printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "Unknown option '$1' (see --help)" ;;
        esac
        shift
    done

    if [[ "$action" == selftest ]]; then
        set_default_config
        if self_test; then exit 0; else exit 1; fi
    fi
    if [[ "$action" == standalone ]]; then
        set_default_config; CONFIG_LOADED=1
        build_standalone "$arg1"; exit 0
    fi

    check_root "${orig[@]}"
    init_logging
    acquire_lock
    _log_file INFO "================================================"
    _log_file INFO "$SCRIPT_NAME v$SCRIPT_VERSION started action=$action dry_run=$DRY_RUN"
    _log_file INFO "User: $(id -un) (real: $REAL_USER)  PID: $$"
    _log_file INFO "================================================"
    load_config
    if legacy_present; then
        migrate_legacy
        case "$action" in
            install|apply|rebuild) ;;                      # these build and start anyway
            *) stack_apply build ;;
        esac
    fi

    case "$action" in
        menu)        is_tty || die "No terminal; use a CLI action (see --help)."; main_menu ;;
        install)     full_install ;;
        apply)       stack_apply build ;;
        rebuild)     stack_apply nocache ;;
        start)       require_installed; stack_up ;;
        stop)        stack_stop ;;
        restart)     require_installed; stack_restart ;;
        status)      show_status ;;
        logs)        show_logs "${arg1:-100}" ;;
        audit)       require_installed; app_ctl audit --tail "${arg1:-50}" ;;
        settings)    is_tty || die "Settings menu needs a terminal."; menu_settings ;;
        showconfig)  show_config ;;
        set)         set_conf_value "${set_kv[0]}" "${set_kv[1]}"; save_config
                     log_info "Run --apply to put it into effect." ;;
        ctl)         require_installed; app_ctl "${ctl_args[@]}" || exit $? ;;
        port)        port_picker "$arg1" "$arg2" "$arg3" || exit $? ;;
        ports)       require_installed
                     if [[ -n "$arg1" ]]; then app_ctl ports "$arg1" || exit $?
                     else app_ctl switch list; printf '\n'; local sn; for sn in $(switch_names); do app_ctl ports "$sn" || true; printf '\n'; done; fi ;;
        backup)      do_backup ;;
        tlsinfo)     tls_show ;;
        portname)    require_installed; app_ctl port-name "$arg1" "$arg2" "$arg3" || exit $? ;;
        tlsimport)   require_installed; tls_import "$arg1" "$arg2"; tls_apply_restart ;;
        tlsmode)     require_installed; app_ctl set general.tls_mode "$arg1" || exit $?; tls_apply_restart ;;
        tlsnames)    require_installed; app_ctl set general.tls_san "$arg1" || exit $?; tls_apply_restart ;;
        tlsregen)    require_installed; app_ctl tls-regen || exit $?; tls_apply_restart ;;
        httpmode)    set_http_mode "$arg1" || exit $? ;;
        restore)     do_restore "$arg1" ;;
        rekey)       secrets_rekey ;;
        uninstall)   uninstall_stack ;;
        appselftest) app_self_test ;;
    esac
    _log_file INFO "Finished action=$action"
}

main "$@"
exit $?
: <<'__SWDASH_PAYLOAD_END__'
__SWDASH_PAYLOAD__ app=3.0.0 sha256=614e41c39747cd97843d129e44432eac627969219738aef42fedd1456ea8d4ad
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
6+fr5z/n5/8PvdU1iQBoBgA=
__SWDASH_PAYLOAD_END__
