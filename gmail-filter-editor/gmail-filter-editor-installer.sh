#!/usr/bin/env bash
# =============================================================================
#  gmail-filter-editor-installer.sh
#  Installer and lifecycle manager for gmail-filter-editor: a web UI that imports Gmail's
#  mailFilters.xml, lets you edit the filters, and exports a file Gmail can re-import (Docker)
#
#  Version   : SCRIPT_VERSION below is the authoritative version string
#  Changelog : CHANGELOG.md (per-version history)
#  Docs      : README.md
#  Author    : netgeek1 & Claude (Anthropic)
#
#  Usage     : sudo ./gmail-filter-editor-installer.sh              interactive menu
#              sudo ./gmail-filter-editor-installer.sh --install    full install / reconfigure
#              sudo ./gmail-filter-editor-installer.sh --help       all CLI flags
#
#  Requires  : bash 4.4+, Ubuntu or Debian (amd64/arm64), root (re-execs via sudo)
#              Self-contained: the app source (Dockerfile + app/) is embedded at the end of
#              this file. Docker and other prerequisites are installed when missing.
#  License   : MIT
# =============================================================================
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="gmail-filter-editor-installer"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

# -----------------------------------------------------------------------------
# PATHS (overridable via environment for testing; normal use leaves these alone)
# -----------------------------------------------------------------------------
GF_CONF_DIR="${GF_CONF_DIR:-/etc/gmail-filter-editor}"
GF_STATE_DIR="${GF_STATE_DIR:-/var/lib/gmail-filter-editor-installer}"
GF_LOG_DIR="${GF_LOG_DIR:-/var/log/gmail-filter-editor}"
GF_INSTALL_BIN="${GF_INSTALL_BIN:-/usr/local/sbin/gmail-filter-editor}"
GF_LOCK_FILE="${GF_LOCK_FILE:-/run/gmail-filter-editor-installer.lock}"

CONF_FILE="$GF_CONF_DIR/gmail-filter-editor.conf"
SECRETS_FILE="$GF_CONF_DIR/secrets.enc"
KEY_FILE="$GF_CONF_DIR/.secrets.key"
LOG_KEEP=20

readonly PROJECT_NAME="gmail-filter-editor"
readonly CONTAINER_PORT=8080
readonly PAYLOAD_MARK="__GFE_PAYLOAD__"
readonly PAYLOAD_END="__GFE_PAYLOAD_END__"   # payload sits in a never-executed heredoc (shellcheck-clean)
# Pinned default. Override with --set BASE_IMAGE ...
readonly DEFAULT_BASE_IMAGE="python:3.13-slim-bookworm"

# -----------------------------------------------------------------------------
# CONFIG MODEL (host/container settings -> $CONF_FILE). Filter data lives in the
# container's data volume (filters.json + backups/).
# -----------------------------------------------------------------------------
CONF_KEYS=( INSTALL_DIR DATA_DIR BACKUP_DIR BACKUP_KEEP APP_BACKUP_KEEP BIND_ADDRESS HOST_PORT CONTAINER_NAME IMAGE_NAME
            BASE_IMAGE BUILD_NETWORK TIMEZONE AUTH_USER SERVICE_USER SERVICE_UID SERVICE_GID
            RESTART_POLICY MEM_LIMIT LOG_MAX_SIZE LOG_MAX_FILE SECRETS_BACKEND BACKUP_FORMAT BACKUP_PASSPHRASE_FILE )
declare -A CFG=()
declare -A CONF_HELP=(
    [INSTALL_DIR]="Build context + compose file location"
    [DATA_DIR]="Persistent data volume (filters.json, in-app backups); owned by the service account"
    [BACKUP_DIR]="Where --backup writes archives"
    [BACKUP_KEEP]="Backup archives to keep (oldest pruned)"
    [APP_BACKUP_KEEP]="In-app filter snapshots to keep (taken before each import/export/restore)"
    [BIND_ADDRESS]="Host address to publish on (0.0.0.0 = all, or one IP; 127.0.0.1 behind a reverse proxy)"
    [HOST_PORT]="Host TCP port for the web UI (HTTP)"
    [CONTAINER_NAME]="Docker container name"
    [IMAGE_NAME]="Local image name (tag = app version)"
    [BASE_IMAGE]="Python base image (pin by tag or @sha256 digest)"
    [BUILD_NETWORK]="docker build network: default or host (host helps behind a local proxy)"
    [TIMEZONE]="Container timezone (export file timestamps)"
    [AUTH_USER]="Basic-auth username for the web UI (empty = no login; password is kept in the vault)"
    [SERVICE_USER]="Service account the container runs as (nologin, not in docker group)"
    [SERVICE_UID]="Fixed UID for a new service account (empty = system-assigned)"
    [SERVICE_GID]="Fixed GID for a new service account (empty = system-assigned)"
    [RESTART_POLICY]="unless-stopped | always | on-failure | no"
    [MEM_LIMIT]="Container memory limit, e.g. 128m (empty = none)"
    [LOG_MAX_SIZE]="docker json-file log size before rotation, e.g. 10m"
    [LOG_MAX_FILE]="docker log files to keep"
    [SECRETS_BACKEND]="auto | systemd-creds | openssl (vault encryption for the web UI password)"
    [BACKUP_FORMAT]="host (restores on this host) | portable (passphrase-encrypted, restores on any host)"
    [BACKUP_PASSPHRASE_FILE]="Root-only file holding the portable-backup passphrase, for unattended backups (empty = ask)"
)

# -----------------------------------------------------------------------------
# SECRETS MODEL (encrypted -> $SECRETS_FILE)
# -----------------------------------------------------------------------------
SECRET_KEYS=( AUTH_PASS )
declare -A SECRETS=()
SECRETS_LOADED=0
CONFIG_LOADED=0

# -----------------------------------------------------------------------------
# RUNTIME STATE
# -----------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
CONFIRM_KEYWORD=""
BACKUP_FORMAT_OPT=""        # --portable / --host-bound override BACKUP_FORMAT
PASSPHRASE_FILE_OPT=""      # --passphrase-file
SOURCE_OVERRIDE=""
SRC_DIR="" SRC_KIND="" PAYLOAD_TMP=""
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
    mkdir -p "$GF_LOG_DIR"
    chmod 750 "$GF_LOG_DIR"
    LOG_FILE="$GF_LOG_DIR/installer-$(date +%F_%H-%M-%S).log"
    : >"$LOG_FILE"
    chmod 640 "$LOG_FILE"
    local old
    while IFS= read -r old; do rm -f -- "$old"; done < <(ls -1t "$GF_LOG_DIR"/installer-*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)))
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
    tmp=$(mktemp "$(dirname "$path")/.gf-tmp.XXXXXX")
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
valid_webuser()  { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]; }
valid_id()       { [[ -z "$1" ]] || { [[ "$1" =~ ^[0-9]{1,6}$ ]] && (( 10#$1 >= 100 && 10#$1 < 65534 )); }; }
valid_uint()     { [[ "$1" =~ ^[0-9]{1,4}$ ]] && (( 10#$1 >= 1 )); }
valid_size()     { [[ "$1" =~ ^[0-9]{1,6}[kmg]$ ]]; }
valid_memlimit() { [[ -z "$1" ]] || valid_size "$1"; }
valid_image()    { [[ "$1" =~ ^[a-z0-9][a-z0-9._/:-]*(@sha256:[0-9a-f]{64})?$ && "$1" != *'$'* ]]; }
valid_tz()       { [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$ ]]; }

# validate_key KEY VALUE -> 0 if valid
validate_key() {
    local k=$1 v=$2
    case "$k" in
        INSTALL_DIR|DATA_DIR|BACKUP_DIR) valid_abs_path "$v" && safe_path "$v" ;;
        BACKUP_KEEP|APP_BACKUP_KEEP|LOG_MAX_FILE) valid_uint "$v" ;;
        BIND_ADDRESS)                    valid_bind "$v" ;;
        HOST_PORT)                       valid_port "$v" ;;
        CONTAINER_NAME|IMAGE_NAME)       valid_name "$v" ;;
        BASE_IMAGE)                      valid_image "$v" ;;
        BUILD_NETWORK)                   in_list "$v" default host ;;
        TIMEZONE)                        valid_tz "$v" ;;
        AUTH_USER)                       valid_webuser "$v" ;;
        SERVICE_USER)                    valid_user "$v" ;;
        SERVICE_UID|SERVICE_GID)         valid_id "$v" ;;
        RESTART_POLICY)                  in_list "$v" unless-stopped always on-failure no ;;
        MEM_LIMIT)                       valid_memlimit "$v" ;;
        LOG_MAX_SIZE)                    valid_size "$v" ;;
        SECRETS_BACKEND)                 in_list "$v" auto systemd-creds openssl ;;
        BACKUP_FORMAT)                   in_list "$v" host portable ;;
        BACKUP_PASSPHRASE_FILE)          [[ -z "$v" ]] || valid_abs_path "$v" ;;
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
    local a=""
    command -v ip >/dev/null 2>&1 && a=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)
    [[ -z "$a" ]] && a=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    printf '%s' "$a"
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
        [INSTALL_DIR]="/opt/gmail-filter-editor"
        [DATA_DIR]="/opt/gmail-filter-editor/data"
        [BACKUP_DIR]="/var/backups/gmail-filter-editor"
        [BACKUP_KEEP]="10"
        [APP_BACKUP_KEEP]="50"
        [BIND_ADDRESS]="0.0.0.0"
        [HOST_PORT]="8085"
        [CONTAINER_NAME]="gmail-filter-editor"
        [IMAGE_NAME]="gmail-filter-editor"
        [BASE_IMAGE]="$DEFAULT_BASE_IMAGE"
        [BUILD_NETWORK]="default"
        [TIMEZONE]="$(detect_timezone)"
        [AUTH_USER]=""
        [SERVICE_USER]="gmailfilters"
        [SERVICE_UID]=""
        [SERVICE_GID]=""
        [RESTART_POLICY]="unless-stopped"
        [MEM_LIMIT]="256m"
        [LOG_MAX_SIZE]="10m"
        [LOG_MAX_FILE]="3"
        [SECRETS_BACKEND]="auto"
        [BACKUP_FORMAT]="host"
        [BACKUP_PASSPHRASE_FILE]=""
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
        printf '# Edit with the menu (Settings) or: %s --set KEY VALUE\n' "$(basename "$GF_INSTALL_BIN")"
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
# SECRETS VAULT (web UI password)
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
        printf '# gmail-filter-editor-secrets v1 backend=%s\n' "$backend"
        case "$backend" in
            systemd-creds) systemd-creds encrypt --name=gmail-filter-editor-secrets - - ;;
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
    [[ "$hdr" == "# gmail-filter-editor-secrets v1 backend="* ]] || return 1
    backend=${hdr##*backend=}
    case "$backend" in
        systemd-creds) tail -n +2 "$SECRETS_FILE" | systemd-creds decrypt --name=gmail-filter-editor-secrets - - ;;
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

# secrets_init  -- a login user needs a password in the vault; generate one if missing
secrets_init() {
    load_secrets
    if [[ -z "${CFG[AUTH_USER]}" ]]; then
        log_warn "Web UI login is OFF (AUTH_USER empty). Anyone who can reach port ${CFG[HOST_PORT]} can read and change your filters."
        return 0
    fi
    if [[ -z "${SECRETS[AUTH_PASS]:-}" ]]; then
        (( DRY_RUN )) && { log_info "[dry-run] would generate a web UI password for '${CFG[AUTH_USER]}'"; return 0; }
        local pw; pw=$(openssl rand -base64 18 | tr -d '\n/+=' | cut -c1-16)
        SECRETS[AUTH_PASS]=$pw
        save_secrets
        printf '%s\n' "$pw" | write_file "$GF_CONF_DIR/initial-web-password" 600 root:root
        log_ok "Generated web UI password for '${CFG[AUTH_USER]}': ${B}${pw}${NC}"
        log_info "Also saved to $GF_CONF_DIR/initial-web-password (root-only). Change it with menu 2 > 3 or --password, then delete that file."
    else
        log_ok "Web UI login '${CFG[AUTH_USER]}': password present in the vault ($(secrets_file_backend))"
    fi
}

# set_web_password  -- prompt (or stdin with --yes) for a new web UI password
set_web_password() {
    ensure_config
    [[ -n "${CFG[AUTH_USER]}" ]] || die "Set a login user first (menu 2 > 3, or --set AUTH_USER name)."
    load_secrets
    local pw=""
    if is_tty && (( ! ASSUME_YES )); then
        while [[ ${#pw} -lt 8 ]]; do
            ask_secret pw "New password for ${CFG[AUTH_USER]} (8+ chars, Enter = generate one)"
            [[ -z "$pw" ]] && break
            [[ ${#pw} -lt 8 ]] && log_warn "Too short."
        done
    elif ! is_tty; then
        IFS= read -r pw || true
    fi
    if [[ -z "$pw" ]]; then
        pw=$(openssl rand -base64 18 | tr -d '\n/+=' | cut -c1-16)
        log_ok "Generated password: ${B}${pw}${NC}"
    fi
    SECRETS[AUTH_PASS]=$pw
    save_secrets
    run rm -f -- "$GF_CONF_DIR/initial-web-password"
    log_ok "Web UI password updated (takes effect on restart)."
}

secrets_rekey() {
    load_secrets
    [[ -f "$SECRETS_FILE" ]] || die "No vault to re-encrypt yet."
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
                                          --shell /usr/sbin/nologin --comment "gmail-filter-editor service account")
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
is_source_dir() { [[ -f "$1/Dockerfile" && -f "$1/app/app.py" && -f "$1/app/static/index.html" ]]; }

# Embedded source: the end of this file holds "__GFE_PAYLOAD__ app=X sha256=Y" followed by a
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
        is_source_dir "$SOURCE_OVERRIDE" || die "--source $SOURCE_OVERRIDE has no Dockerfile + app/app.py + app/static/index.html"
        SRC_DIR=$(readlink -f "$SOURCE_OVERRIDE"); SRC_KIND="--source"; return 0
    fi
    if is_source_dir "$SCRIPT_DIR"; then SRC_DIR=$SCRIPT_DIR; SRC_KIND="checkout"; return 0; fi
    if has_payload; then
        PAYLOAD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gfe-src.XXXXXX")
        extract_payload "$PAYLOAD_TMP" || die "Could not unpack the embedded source from $SCRIPT_PATH."
        SRC_DIR=$PAYLOAD_TMP; SRC_KIND="embedded"; return 0
    fi
    if is_source_dir "${CFG[INSTALL_DIR]}/src"; then SRC_DIR="${CFG[INSTALL_DIR]}/src"; SRC_KIND="installed"; return 0; fi
    die "No app source: this copy of the installer has no embedded source and no Dockerfile + app/ next to it. Use the release installer or pass --source DIR."
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

app_version_of() { sed -n 's/^__version__ = "\([0-9][0-9.]*\)".*/\1/p' "$1/app/app.py" | head -n1; }

sync_source() {
    log_step "Build context"
    local src dst=${CFG[INSTALL_DIR]}/src
    init_source; src=$SRC_DIR
    APP_VERSION=$(app_version_of "$src")
    [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Cannot read __version__ from $src/app/app.py"
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
    [[ "$SCRIPT_PATH" == "$GF_INSTALL_BIN" ]] && return 0
    run install -m 0755 "$SCRIPT_PATH" "$GF_INSTALL_BIN"
    run cp -f "$SCRIPT_PATH" "${CFG[INSTALL_DIR]}/src/$(basename "$SCRIPT_PATH")"
    log_ok "Installer available as $GF_INSTALL_BIN"
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

render_compose() {
    resolve_ids
    cat <<EOF
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION -- do not edit; change settings with the installer.
# The web UI password is injected by the installer at start time and never written here.
name: $PROJECT_NAME

services:
  app:
    image: "$(image_ref)"
    pull_policy: never          # built locally by the installer (--apply / --rebuild)
    container_name: "${CFG[CONTAINER_NAME]}"
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
      MAX_BACKUPS: "${CFG[APP_BACKUP_KEEP]}"
      GFE_AUTH_USER: "${CFG[AUTH_USER]}"
EOF
    if [[ -n "${CFG[AUTH_USER]}" ]]; then
        printf '      GFE_AUTH_PASS: "${GFE_AUTH_PASS:?start with %s (it injects the web UI password)}"\n' "$SCRIPT_NAME"
    fi
    cat <<EOF
    ports:
      - "$(port_spec)"
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

# compose_run ARGS...  -- docker compose for this project, web UI password injected via the environment
compose_run() {
    local f; f=$(compose_file)
    # dry-run first: in a dry-run install the compose file was only "written" (printed), so it doesn't exist yet
    if (( DRY_RUN )); then run docker compose -f "$f" -p "$PROJECT_NAME" "$@"; return 0; fi
    [[ -f "$f" ]] || die "No compose file yet ($f). Run --install or --apply first."
    local -a g=(-f "$f" -p "$PROJECT_NAME")
    (( COMPOSE_QUIET )) && g=(--progress quiet "${g[@]}")
    _log_file RUN "docker compose ${g[*]} $*"
    if [[ -n "${CFG[AUTH_USER]}" ]]; then
        load_secrets
        [[ -n "${SECRETS[AUTH_PASS]:-}" ]] || die "Web UI password missing from the vault (run --password or --install)."
        GFE_AUTH_PASS="${SECRETS[AUTH_PASS]}" docker compose "${g[@]}" "$@"
    else
        docker compose "${g[@]}" "$@"
    fi
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

# -----------------------------------------------------------------------------
# STACK
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
                --build-arg "APP_VERSION=$(current_app_version)"
                --label "com.domain.gmail-filter-editor.installer=$SCRIPT_VERSION")
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
    stack_up
    state_set last_apply "$(date '+%F %T') app v$(current_app_version)"
}

stack_stop() {
    log_step "Stop container"
    ensure_config
    [[ -f "$(compose_file)" ]] || { log_info "Not installed."; return 0; }
    run_compose_logged down
    log_ok "Stopped (data kept in ${CFG[DATA_DIR]})"
}

# Restart via compose so a changed password / login user is picked up (docker restart keeps the old env)
stack_restart() {
    log_step "Restart container"
    ensure_config
    write_compose
    run_compose_logged up -d --no-build --force-recreate --remove-orphans
    wait_healthy
    show_urls
}

show_urls() {
    ensure_config
    local ip b=${CFG[BIND_ADDRESS]}
    if [[ "$b" == 0.0.0.0 || "$b" == "::" ]]; then ip=$(detect_ip); ip=${ip:-localhost}; else ip=$b; fi
    [[ "$ip" == *:* ]] && ip="[$ip]"
    log_info "Web UI: ${B}http://${ip}:${CFG[HOST_PORT]}/${NC}$([[ -n "${CFG[AUTH_USER]}" ]] && printf '  (login: %s)' "${CFG[AUTH_USER]}")"
    [[ "$b" == 127.0.0.1 || "$b" == ::1 ]] && log_info "Bound to loopback: publish it through your reverse proxy (e.g. gmailfilters.<domain> with the wildcard cert)."
    return 0
}

filter_count() {
    local f="${CFG[DATA_DIR]}/filters.json"
    [[ -f "$f" ]] || { printf '0'; return 0; }
    grep -c '"props"' "$f" 2>/dev/null || printf '0'
}

show_status() {
    log_step "Status"
    ensure_config
    local cfg_state="not installed"
    [[ -f "$(compose_file)" ]] && cfg_state="installed"
    printf '    %-16s %s\n' "Installer" "v$SCRIPT_VERSION ($SCRIPT_PATH)"
    printf '    %-16s %s\n' "State" "$cfg_state  (last apply: $(state_get last_apply || true))"
    printf '    %-16s %s\n' "Image" "$(image_ref)  base ${CFG[BASE_IMAGE]}"
    printf '    %-16s %s\n' "Publish" "$(port_spec)"
    printf '    %-16s %s\n' "Login" "$([[ -n "${CFG[AUTH_USER]}" ]] && echo "${CFG[AUTH_USER]} (basic auth)" || echo "OFF")"
    printf '    %-16s %s\n' "Data" "${CFG[DATA_DIR]}  ($(filter_count) filters loaded)"
    printf '    %-16s %s\n' "Account" "${CFG[SERVICE_USER]} ($(id -u "${CFG[SERVICE_USER]}" 2>/dev/null || echo '?'):$(id -g "${CFG[SERVICE_USER]}" 2>/dev/null || echo '?'))"
    printf '    %-16s %s\n' "Vault" "$( [[ -f "$SECRETS_FILE" ]] && echo "$SECRETS_FILE ($(secrets_file_backend))" || echo "not created")"
    if docker_up; then
        printf '    %-16s %s / health %s\n' "Container" "$(container_state)" "$(container_health)"
        is_running && show_urls
    else
        printf '    %-16s %s\n' "Container" "docker not running"
    fi
    return 0
}

show_logs() {   # show_logs [N] [follow]
    ensure_config
    local n=${1:-100}
    if [[ "${2:-}" == follow ]]; then docker logs -f --tail "$n" "${CFG[CONTAINER_NAME]}"
    else docker logs --tail "$n" "${CFG[CONTAINER_NAME]}" 2>&1; fi
}

state_get() { cat "$GF_STATE_DIR/$1" 2>/dev/null || true; }
state_set() { (( DRY_RUN )) && return 0; mkdir -p "$GF_STATE_DIR"; printf '%s\n' "$2" >"$GF_STATE_DIR/$1"; }

# -----------------------------------------------------------------------------
# FILTER FILES (host-side import / export without the browser)
# -----------------------------------------------------------------------------
# api_call METHOD PATH [curl args...]  -- talk to the running app on its published port
api_call() {
    local m=$1 p=$2; shift 2
    local host=${CFG[BIND_ADDRESS]}
    [[ "$host" == 0.0.0.0 ]] && host=127.0.0.1
    [[ "$host" == "::" ]] && host="::1"
    [[ "$host" == *:* ]] && host="[$host]"
    is_running || die "Container is not running (menu 5 / --start)."
    local -a auth=()
    if [[ -n "${CFG[AUTH_USER]}" ]]; then
        load_secrets
        auth=(-K -)   # credentials on stdin, never on the command line
        printf 'user = "%s:%s"\n' "${CFG[AUTH_USER]}" "${SECRETS[AUTH_PASS]//\"/\\\"}" \
            | curl -fsS -X "$m" "${auth[@]}" "$@" "http://${host}:${CFG[HOST_PORT]}${p}"
    else
        curl -fsS -X "$m" "$@" "http://${host}:${CFG[HOST_PORT]}${p}"
    fi
}

# filters_import FILE [replace|merge]
filters_import() {
    local f=$1 mode=${2:-replace}
    ensure_config
    [[ -f "$f" ]] || die "No such file: $f"
    in_list "$mode" replace merge || die "Mode must be replace or merge."
    (( DRY_RUN )) && { run curl -X POST "/api/import" "file=@$f" "mode=$mode"; return 0; }
    log_step "Import $f ($mode)"
    api_call POST /api/import -F "file=@$f;type=application/xml" -F "mode=$mode" | sed 's/^/    /'
    printf '\n'
    log_ok "Done ($(filter_count) filters loaded)"
}

# filters_export [OUT]
filters_export() {
    ensure_config
    local out=${1:-./mailFilters-$(date +%Y%m%d-%H%M%S).xml}
    (( DRY_RUN )) && { run curl -X POST /api/export -o "$out"; return 0; }
    log_step "Export filters"
    api_call POST /api/export -H 'Content-Type: application/json' -d '{}' -o "$out"
    [[ -n "${SUDO_UID:-}" ]] && chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$out" 2>/dev/null || true
    log_ok "Wrote $out ($(grep -c '<entry>' "$out" || true) filters)"
    log_info "In Gmail: delete the old filters first, then Settings > Filters and Blocked Addresses > Import filters."
}

# -----------------------------------------------------------------------------
# BACKUP / RESTORE
# -----------------------------------------------------------------------------
readonly PORTABLE_MAGIC="GFE-BACKUP v1 portable"
readonly PORTABLE_ITER=600000
readonly PASSPHRASE_MIN=12

# list_backups  -- newest first, both formats
list_backups() {
    [[ -d "${CFG[BACKUP_DIR]}" ]] || return 0
    find "${CFG[BACKUP_DIR]}" -maxdepth 1 -type f \( -name 'gmail-filter-editor-*.tar.gz' -o -name 'gmail-filter-editor-*.gfebak' \) \
        -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-
}

prune_backups() {
    local old
    while IFS= read -r old; do rm -f -- "$old"; log_info "Pruned $old"; done \
        < <(list_backups | tail -n +$(( CFG[BACKUP_KEEP] + 1 )))
}

do_backup() {
    ensure_config
    local fmt=${BACKUP_FORMAT_OPT:-${CFG[BACKUP_FORMAT]}}
    if [[ "$fmt" == portable ]]; then do_backup_portable; return; fi
    log_step "Backup (this host)"
    [[ -d "${CFG[DATA_DIR]}" ]] || die "Nothing to back up (${CFG[DATA_DIR]} missing)."
    local out; out="${CFG[BACKUP_DIR]}/gmail-filter-editor-$(date +%Y%m%d-%H%M%S).tar.gz"
    run install -d -m 0700 -o root -g root "${CFG[BACKUP_DIR]}"
    local -a items=("${CFG[DATA_DIR]#/}" "${CONF_FILE#/}")
    [[ -f "$SECRETS_FILE" ]] && items+=("${SECRETS_FILE#/}")
    [[ -f "$KEY_FILE" ]] && items+=("${KEY_FILE#/}")
    if (( DRY_RUN )); then run tar -czf "$out" -C / "${items[@]}"; return 0; fi
    ( umask 077; tar -czf "$out" -C / "${items[@]}" )
    chmod 600 "$out"
    log_ok "Backup written: $out ($(du -h "$out" | cut -f1))"
    log_warn "The archive holds your mail filter rules and the vault with its key: keep it private."
    [[ "$(secrets_file_backend)" == systemd-creds ]] && \
        log_warn "Vault backend is systemd-creds (host/TPM-bound): this backup restores on THIS host only. Use --backup --portable to restore elsewhere."
    prune_backups
}

# get_passphrase VAR new|existing
#   --passphrase-file, then $GFE_BACKUP_PASSPHRASE, then BACKUP_PASSPHRASE_FILE, then a prompt
get_passphrase() {
    local __var=$1 mode=$2 __p="" __src="" __b=""
    if [[ -n "$PASSPHRASE_FILE_OPT" ]]; then __src=$PASSPHRASE_FILE_OPT
    elif [[ -n "${GFE_BACKUP_PASSPHRASE:-}" ]]; then __p=$GFE_BACKUP_PASSPHRASE
    elif [[ -n "${CFG[BACKUP_PASSPHRASE_FILE]:-}" && -f "${CFG[BACKUP_PASSPHRASE_FILE]}" ]]; then __src=${CFG[BACKUP_PASSPHRASE_FILE]}
    fi
    if [[ -n "$__src" ]]; then
        [[ -r "$__src" ]] || die "Cannot read passphrase file $__src"
        [[ "$(stat -c %a "$__src")" =~ ^[4-7]00$ ]] || log_warn "$__src is readable by others; chmod 600 it."
        IFS= read -r __p <"$__src" || true
    elif [[ -z "$__p" ]]; then
        is_tty || die "A portable backup needs a passphrase: --passphrase-file FILE, GFE_BACKUP_PASSPHRASE, or BACKUP_PASSPHRASE_FILE."
        while :; do
            read -rsp "  Backup passphrase: " __p || true; echo
            [[ "$mode" == existing ]] && break
            if (( ${#__p} < PASSPHRASE_MIN )); then log_warn "Use at least $PASSPHRASE_MIN characters."; continue; fi
            read -rsp "  Confirm passphrase: " __b || true; echo
            [[ "$__p" == "$__b" ]] && break
            log_warn "Entries did not match, try again."
        done
    fi
    [[ -n "$__p" ]] || die "Empty passphrase."
    [[ "$mode" == new && ${#__p} -lt $PASSPHRASE_MIN ]] && die "The backup passphrase must be at least $PASSPHRASE_MIN characters."
    printf -v "$__var" '%s' "$__p"
}

# portable_encrypt PASS < plaintext > file   (header line, then openssl ciphertext)
portable_encrypt() {
    printf '%s kdf=pbkdf2-sha256 iter=%s cipher=aes-256-cbc\n' "$PORTABLE_MAGIC" "$PORTABLE_ITER"
    openssl enc -aes-256-cbc -pbkdf2 -iter "$PORTABLE_ITER" -md sha256 -salt -pass fd:3 3<<<"$1"
}

is_portable_backup() { [[ "$(head -c ${#PORTABLE_MAGIC} "$1" 2>/dev/null)" == "$PORTABLE_MAGIC" ]]; }

# portable_decrypt FILE PASS > plaintext
portable_decrypt() {
    local hdr iter
    hdr=$(head -n1 "$1")
    [[ "$hdr" == "$PORTABLE_MAGIC "* ]] || return 1
    iter=$(sed -n 's/.* iter=\([0-9]*\).*/\1/p' <<<"$hdr")
    [[ "$iter" =~ ^[0-9]+$ ]] || return 1
    tail -c +$(( ${#hdr} + 2 )) "$1" | openssl enc -d -aes-256-cbc -pbkdf2 -iter "$iter" -md sha256 -pass fd:3 3<<<"$2"
}

do_backup_portable() {
    log_step "Backup (portable)"
    [[ -d "${CFG[DATA_DIR]}" ]] || die "Nothing to back up (${CFG[DATA_DIR]} missing)."
    load_secrets
    local out; out="${CFG[BACKUP_DIR]}/gmail-filter-editor-$(date +%Y%m%d-%H%M%S).gfebak"
    if (( DRY_RUN )); then log_info "[dry-run] would write the passphrase-encrypted archive $out"; return 0; fi
    local pp; get_passphrase pp new
    install -d -m 0700 -o root -g root "${CFG[BACKUP_DIR]}"
    local st; st=$(mktemp -d "${CFG[BACKUP_DIR]}/.stage.XXXXXX")
    chmod 700 "$st"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$st'; trap - RETURN" RETURN
    mkdir -p "$st/b/data"
    tar -C "${CFG[DATA_DIR]}" -cf - . | tar -C "$st/b/data" -xf -
    [[ -f "$CONF_FILE" ]] && cp "$CONF_FILE" "$st/b/host.conf"
    ( umask 077; : >"$st/b/secrets.env"
      [[ -n "${SECRETS[AUTH_PASS]:-}" ]] && printf 'AUTH_PASS=%s\n' "$(printf '%s' "${SECRETS[AUTH_PASS]}" | base64 -w0)" >"$st/b/secrets.env"
      true )
    {
        printf 'format=1\ncreated=%s\nhost=%s\ninstaller=%s\napp=%s\ndata_dir=%s\n' "$(date '+%F %T %z')" \
            "$(hostname -s 2>/dev/null || hostname)" "$SCRIPT_VERSION" "$(current_app_version 2>/dev/null || true)" "${CFG[DATA_DIR]}"
    } >"$st/b/manifest"
    ( cd "$st/b" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS )
    ( umask 077; tar -C "$st/b" --numeric-owner -czf - . | portable_encrypt "$pp" >"$out.part" ) \
        || { rm -f -- "$out.part"; die "Encrypting the backup failed."; }
    mv -f -- "$out.part" "$out"; chmod 600 "$out"
    log_ok "Portable backup written: $out ($(du -h "$out" | cut -f1))"
    log_info "Encrypted with your passphrase (AES-256, PBKDF2-SHA256 x$PORTABLE_ITER). Restore anywhere with:"
    log_info "  sudo ./gmail-filter-editor-installer.sh --restore $(basename "$out")"
    log_warn "Without the passphrase this backup cannot be restored. Store the passphrase separately."
    prune_backups
}

do_restore() {
    local file=$1
    [[ -f "$file" ]] || die "No such file: $file"
    if is_portable_backup "$file"; then do_restore_portable "$file"; return; fi
    log_step "Restore from $file"
    ensure_config
    local list; list=$(tar -tzf "$file") || die "Not a readable tar.gz: $file"
    grep -qE "^${CFG[DATA_DIR]#/}/?$" <<<"$list" || die "Archive has no ${CFG[DATA_DIR]} (different DATA_DIR?)."
    if grep -vqE "^(${CFG[DATA_DIR]#/}(/.*)?|${GF_CONF_DIR#/}(/.*)?)$" <<<"$list"; then
        die "Archive contains paths outside ${CFG[DATA_DIR]} and $GF_CONF_DIR; refusing."
    fi
    local vb; vb=$(tar -xzOf "$file" "${SECRETS_FILE#/}" 2>/dev/null | head -n1 | sed -n 's/.*backend=//p')
    [[ "$vb" == systemd-creds ]] && log_warn "This archive's vault is host/TPM-bound (systemd-creds): it restores only on the host that made it."
    log_warn "This replaces ${CFG[DATA_DIR]} (filters and in-app snapshots) and the installer vault/settings."
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

# restore_host_settings STAGE  -- fresh host: adopt the backup's container/host settings, minus host-specific ones
restore_host_settings() {
    local st=$1 saved=$CONF_FILE
    [[ -f "$st/host.conf" ]] || return 0
    CONF_FILE="$st/host.conf"; CONFIG_LOADED=0; load_config; CONF_FILE=$saved
    CFG[SERVICE_UID]=""; CFG[SERVICE_GID]=""; CFG[SECRETS_BACKEND]=auto
    CFG[TIMEZONE]=$(detect_timezone)
    case "${CFG[BIND_ADDRESS]}" in
        0.0.0.0|::|127.0.0.1|::1) ;;
        *) ip -o addr show 2>/dev/null | grep -qw -- "${CFG[BIND_ADDRESS]}" || {
               log_warn "BIND_ADDRESS ${CFG[BIND_ADDRESS]} is not on this host; using 0.0.0.0."; CFG[BIND_ADDRESS]=0.0.0.0; } ;;
    esac
    CONFIG_LOADED=1
}

do_restore_portable() {
    local file=$1 pp st line k
    log_step "Restore portable backup $file"
    ensure_config
    command -v openssl >/dev/null 2>&1 || die "openssl is needed to decrypt the backup (apt-get install openssl)."
    get_passphrase pp existing
    st=$(mktemp -d "${TMPDIR:-/tmp}/gfe-restore.XXXXXX"); chmod 700 "$st"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$st'; trap - RETURN" RETURN
    portable_decrypt "$file" "$pp" 2>/dev/null | tar -xzf - -C "$st" --no-same-owner 2>/dev/null \
        || die "Cannot decrypt $file: wrong passphrase, or the file is damaged."
    [[ -f "$st/manifest" && -f "$st/secrets.env" && -d "$st/data" && -f "$st/SHA256SUMS" ]] \
        || die "$file is not a complete gmail-filter-editor backup."
    [[ -z "$(find "$st" -type l -print -quit)" ]] || die "The backup contains symbolic links; refusing."
    ( cd "$st" && sha256sum --quiet -c SHA256SUMS ) >/dev/null 2>&1 || die "Checksum mismatch: the backup is damaged."
    local b_host b_created b_app
    b_host=$(sed -n 's/^host=//p' "$st/manifest"); b_created=$(sed -n 's/^created=//p' "$st/manifest")
    b_app=$(sed -n 's/^app=//p' "$st/manifest")
    log_ok "Passphrase OK, checksums verified: made on ${b_host:-?} at ${b_created:-?} (app v${b_app:-?})"
    local fresh=0; [[ -f "$CONF_FILE" ]] || fresh=1
    if (( fresh )); then
        log_info "No install on this host: using the backup's container settings (paths, port, login user)."
    else
        log_info "Keeping this host's container settings ($CONF_FILE); restoring the filter data and web UI password."
    fi
    log_warn "This replaces ${CFG[DATA_DIR]} (filters and in-app snapshots) and the web UI password."
    confirm_typed RESTORE || { log_info "Cancelled."; return 0; }
    (( DRY_RUN )) && { log_info "[dry-run] would stop, restore data + password, build and start"; return 0; }
    (( fresh )) && restore_host_settings "$st"
    SECRETS=()
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
        k=${BASH_REMATCH[1]}
        in_list "$k" "${SECRET_KEYS[@]}" && SECRETS[$k]=$(printf '%s' "${BASH_REMATCH[2]}" | base64 -d)
    done <"$st/secrets.env"
    SECRETS_LOADED=1
    if [[ -f "$(compose_file)" ]] && docker_up; then stack_stop || true; fi
    ensure_service_account
    resolve_ids
    local keep; keep="${CFG[DATA_DIR]}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    [[ -d "${CFG[DATA_DIR]}" ]] && mv "${CFG[DATA_DIR]}" "$keep" && log_info "Previous data moved to $keep"
    install -d -m 0755 "$(dirname "${CFG[DATA_DIR]}")"
    install -d -m 0700 -o "$PUID" -g "$PGID" "${CFG[DATA_DIR]}"
    tar -C "$st/data" -cf - . | tar -C "${CFG[DATA_DIR]}" -xf - --no-same-owner
    chown -R "$PUID:$PGID" "${CFG[DATA_DIR]}"
    log_ok "Data restored to ${CFG[DATA_DIR]} (owner ${CFG[SERVICE_USER]})"
    install -d -m 0700 "$GF_CONF_DIR"
    (( ${#SECRETS[@]} )) && save_secrets           # sealed with THIS host's backend (TPM if available)
    save_config
    stack_apply build
    log_ok "Restore complete."
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
    run rm -f -- "$GF_INSTALL_BIN"
    log_ok "Gmail Filter Editor removed."
    if confirm "Also purge data, settings and the vault (your loaded filters and snapshots)?" n; then
        log_warn "Purging is permanent. Make a backup first if unsure (--backup)."
        if confirm_typed PURGE-DATA; then
            safe_path "${CFG[DATA_DIR]}" && run rm -rf -- "${CFG[DATA_DIR]}"
            run rm -f -- "$CONF_FILE" "$SECRETS_FILE" "$KEY_FILE" "$GF_CONF_DIR/initial-web-password"
            run rmdir --ignore-fail-on-non-empty "${CFG[INSTALL_DIR]}" "$GF_CONF_DIR" 2>/dev/null || true
            run rm -rf -- "$GF_STATE_DIR"
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
    log_step "Install / reconfigure Gmail Filter Editor"
    ensure_config
    [[ -f "$CONF_FILE" ]] && log_info "Existing settings found; press Enter to keep each value."
    wizard_network
    wizard_login
    wizard_paths
    save_config
    stack_apply build
    log_step "Done"
    show_urls
    log_info "Next: in Gmail, Settings > Filters and Blocked Addresses > select all > Export, then Import XML in the web UI."
    log_info "Manage it later with: sudo $(basename "$GF_INSTALL_BIN")"
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
    ask_valid BIND_ADDRESS "Bind address (0.0.0.0 = all interfaces, 127.0.0.1 = reverse proxy only)"
    ask_valid HOST_PORT    "Host port"
    ask_valid TIMEZONE     "Timezone"
}

wizard_login() {
    printf '\n  %sWeb UI login%s (HTTP basic auth; the file shows your mail rules and addresses)\n' "$B" "$NC"
    local def=${CFG[AUTH_USER]} v
    [[ -f "$CONF_FILE" ]] || def=${def:-admin}
    while :; do
        ask v "Login username ('-' = no login)" "${def:--}"
        [[ "$v" == "-" ]] && v=""
        valid_webuser "$v" && break
        log_warn "Letters, digits and _ . @ - only (max 64)."
        (( ASSUME_YES )) || ! is_tty && die "Invalid AUTH_USER '$v'"
    done
    CFG[AUTH_USER]=$v
    [[ -z "$v" ]] && { log_warn "No login: anyone who can reach the port can read and change your filters."; return 0; }
    load_secrets
    if [[ -z "${SECRETS[AUTH_PASS]:-}" ]] || confirm "Change the password for '$v'?" n; then
        local pw=""
        if is_tty && (( ! ASSUME_YES )); then
            while [[ ${#pw} -lt 8 ]]; do
                ask_secret pw "Password for $v (8+ chars, Enter = generate one)"
                [[ -z "$pw" ]] && break
                [[ ${#pw} -lt 8 ]] && log_warn "Too short."
            done
        fi
        if [[ -n "$pw" ]]; then
            SECRETS[AUTH_PASS]=$pw
            (( DRY_RUN )) || { install -d -m 0700 "$GF_CONF_DIR"; save_secrets; }
            run rm -f -- "$GF_CONF_DIR/initial-web-password"
        else
            unset 'SECRETS[AUTH_PASS]'   # secrets_init generates and shows one
        fi
    fi
}

wizard_paths() {
    printf '\n  %sPaths%s\n' "$B" "$NC"
    ask_valid INSTALL_DIR "Install directory"
    ask_valid DATA_DIR    "Data directory"
    ask_valid BACKUP_DIR  "Backup directory"
}

wizard_container() {
    printf '\n  %sContainer%s\n' "$B" "$NC"
    ask_valid CONTAINER_NAME  "Container name"
    ask_valid IMAGE_NAME      "Image name"
    ask_valid BASE_IMAGE      "Base image (pin)"
    ask_valid BUILD_NETWORK   "Build network (default|host)"
    ask_valid RESTART_POLICY  "Restart policy"
    ask_valid MEM_LIMIT       "Memory limit (e.g. 256m, empty = none)"
    ask_valid LOG_MAX_SIZE    "Docker log max size"
    ask_valid LOG_MAX_FILE    "Docker log files kept"
    ask_valid BACKUP_KEEP     "Backup archives to keep"
    ask_valid APP_BACKUP_KEEP "In-app filter snapshots to keep"
}

wizard_account() {
    printf '\n  %sService account%s\n' "$B" "$NC"
    ask_valid SERVICE_USER "Account name"
    ask_valid SERVICE_UID  "UID for a new account (empty = auto)"
    ask_valid SERVICE_GID  "GID for a new account (empty = auto)"
    ask_valid SECRETS_BACKEND "Vault backend (auto|systemd-creds|openssl)"
}

require_installed() {
    ensure_config
    [[ -f "$(compose_file)" ]] || die "Not installed yet (menu 1 / --install)."
}

# -----------------------------------------------------------------------------
# MENUS
# -----------------------------------------------------------------------------
menu_host_settings() {
    ensure_config
    while :; do
        show_config
        printf '\n   1) Network (bind, port, timezone)   2) Paths   3) Container (image pin, limits, logs, backups)\n'
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
        printf '   1) Container / host    (port, bind, paths, image pin, account, vault)\n'
        printf '   2) Web UI login        (username on/off, then restart)\n'
        printf '   3) Web UI password     (change or generate, then restart)\n'
        printf '   V) View settings       0) Back\n'
        local ch; read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            1) menu_host_settings ;;
            2) wizard_login; save_config; [[ -f "$(compose_file)" ]] && menu_action stack_apply nobuild ;;
            3) menu_action set_web_password; [[ -f "$(compose_file)" ]] && menu_action stack_restart ;;
            v) show_config ;;
            0|"") return 0 ;;
        esac
    done
}

menu_filters() {
    ensure_config
    printf '\n  %sFilter files%s (%s filters loaded)\n' "$B" "$NC" "$(filter_count)"
    printf '   1) Import a mailFilters.xml from this host (replace)\n   2) Import and merge (skip exact duplicates)\n'
    printf '   3) Export all filters to an XML file on this host\n   0) Back\n'
    local ch f; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1|2) ask f "Path to mailFilters.xml" "./mailFilters.xml"
             menu_action filters_import "$f" "$([[ $ch == 2 ]] && echo merge || echo replace)" ;;
        3)   ask f "Output file" "./mailFilters-$(date +%Y%m%d-%H%M%S).xml"
             menu_action filters_export "$f" ;;
    esac
    return 0
}

menu_logs() {
    ensure_config
    printf '\n   1) Container log (last 100)   2) Follow container log (Ctrl-C to stop)\n'
    printf '   3) Installer run logs\n   0) Back\n'
    local ch; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) show_logs 100 | sed 's/^/  /' ;;
        2) show_logs 50 follow || true ;;
        3) ls -1t "$GF_LOG_DIR"/installer-*.log 2>/dev/null | head -n 10 | sed 's/^/  /'
           local f; f=$(ls -1t "$GF_LOG_DIR"/installer-*.log 2>/dev/null | sed -n 2p)
           [[ -n "$f" ]] && { printf '\n  %sPrevious run: %s%s\n' "$B" "$f" "$NC"; tail -n 40 "$f" | sed 's/^/  /'; } ;;
    esac
    return 0
}

menu_uninstall() {
    printf '\n   1) Uninstall Gmail Filter Editor (keyword UNINSTALL; data kept unless purged)\n   0) Back\n'
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
    # each test runs in a subshell: an 'exit' or a changed CFG value cannot leak into the next test
    st() { if ( eval "$2" ) >/dev/null 2>&1; then printf '  %s[PASS]%s %s\n' "$G" "$NC" "$1"; pass=$((pass + 1)); else printf '  %s[FAIL]%s %s\n' "$R" "$NC" "$1"; fail=$((fail + 1)); fi; }

    st "bash syntax"                       'bash -n "$SCRIPT_PATH"'
    st "version is semver"                 '[[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
    st "conf quote round-trip"             "[[ \"\$(conf_unquote \"\$(conf_quote \"it's \\\$x\")\")\" == \"it's \\\$x\" ]]"
    st "every CONF_KEY has a default"      'for k in "${CONF_KEYS[@]}"; do [[ -v "CFG[$k]" ]] || exit 1; done'
    st "every CONF_KEY has help text"      'for k in "${CONF_KEYS[@]}"; do [[ -n "${CONF_HELP[$k]:-}" ]] || exit 1; done'
    st "defaults all validate"             'for k in "${CONF_KEYS[@]}"; do validate_key "$k" "${CFG[$k]}" || exit 1; done'
    st "port 8085 valid / 70000 invalid"   'valid_port 8085 && ! valid_port 70000 && ! valid_port 0'
    st "bind 0.0.0.0 / ::1 valid"          'valid_bind 0.0.0.0 && valid_bind ::1 && ! valid_bind 999.1.1.1'
    st "web user rules"                    'valid_webuser "" && valid_webuser user@x.net && ! valid_webuser "a b" && ! valid_webuser "a:b"'
    st "safe_path refuses /, /opt, /home/x" '! safe_path / && ! safe_path /opt && ! safe_path /home/username && safe_path /opt/gmail-filter-editor'
    st "safe_path refuses .."              '! safe_path /opt/x/../etc'
    st "abs path rejects spaces / \$"      '! valid_abs_path "/opt/a b" && ! valid_abs_path "/opt/\$x" && valid_abs_path /opt/x'
    st "image pin accepts digest"          "valid_image python:3.13-slim-bookworm && valid_image \"python:3.13@sha256:$(printf 'a%.0s' {1..64})\""
    # (render once into a variable: 'render | grep -q' trips pipefail when grep closes the pipe early)
    st "compose renders without login"     'CFG[AUTH_USER]=""; c=$(render_compose); grep -q "GFE_AUTH_USER: \"\"" <<<"$c" && ! grep -q GFE_AUTH_PASS <<<"$c"'
    st "compose requires injected password" 'CFG[AUTH_USER]=user; c=$(render_compose); grep -qF "GFE_AUTH_PASS: \"\${GFE_AUTH_PASS:?" <<<"$c"'
    st "compose hardened"                  'c=$(render_compose); grep -q "read_only: true" <<<"$c" && grep -q cap_drop <<<"$c" && grep -q no-new-privileges <<<"$c"'
    st "compose has no secrets"            'SECRETS[AUTH_PASS]=topsecret123; CFG[AUTH_USER]=user; c=$(render_compose); ! grep -q topsecret123 <<<"$c"'
    st "port spec brackets IPv6"           'CFG[BIND_ADDRESS]=::1; [[ "$(port_spec)" == "[::1]:8085:8080" ]]'
    st "openssl present"                   'command -v openssl'
    st "openssl vault round-trip"          "KEY_FILE=$t/k SECRETS_FILE=$t/s; printf 'AUTH_PASS=eA==\n' | secrets_encrypt_to openssl $t/s && [[ \"\$(secrets_decrypt)\" == 'AUTH_PASS=eA==' ]]"
    st "portable encrypt round-trip"       "printf 'hello' | portable_encrypt 'passphrase-123' >$t/p && is_portable_backup $t/p && [[ \"\$(portable_decrypt $t/p 'passphrase-123')\" == hello ]]"
    st "portable wrong passphrase fails"   "! portable_decrypt $t/p 'wrong-passphrase' 2>/dev/null | grep -q hello"
    st "build cmd pins base + label"       'c=$(build_cmd); grep -qx -- "BASE_IMAGE=${CFG[BASE_IMAGE]}" <<<"$c" && grep -q "com.domain.gmail-filter-editor.installer" <<<"$c"'
    st "build cmd nocache pulls"           'c=$(build_cmd nocache); grep -qx -- --no-cache <<<"$c" && grep -qx -- --pull <<<"$c"'
    if has_payload; then
        st "embedded payload checksum"     "extract_payload $t/src"
        st "embedded app version = header" "[[ \"\$(app_version_of $t/src)\" == \"\$(payload_field app)\" ]]"
    else
        st "source checkout next to script" 'is_source_dir "$SCRIPT_DIR"'
    fi
    rm -rf "$t"
    printf '\n  %s passed, %s failed\n' "$pass" "$fail"
    (( fail == 0 ))
}

app_self_test() {
    log_step "App tests inside image $(image_ref)"
    ensure_config
    docker run --rm --read-only --tmpfs /tmp --user 10001:10001 --entrypoint python3 -e GFE_DATA=/tmp/gfe \
        "$(image_ref)" -m unittest discover -s /app/tests -v
}

# -----------------------------------------------------------------------------
# MAIN MENU
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
    printf '  %s|%s  %sGmail Filter Editor%s  v%-8s host: %-21s%s|%s\n' "$C" "$NC" "$B" "$NC" "$SCRIPT_VERSION" "$(hostname -s | cut -c1-21)" "$C" "$NC"
    printf '  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  State: %b   Container: %s   Mode: %b\n' "$inst" "$ctr" "$mode"
}

main_menu() {
    while :; do
        show_banner
        printf '\n  %sSetup%s\n' "$B" "$NC"
        printf '   1) Full install / reconfigure\n   2) Settings (login, password, container)\n'
        printf '  %sOperate%s\n' "$B" "$NC"
        printf '   3) Apply             (re-render, build if needed, start)\n'
        printf '   4) Rebuild image     (no cache, re-pull base, start)\n'
        printf '   5) Start   6) Stop   7) Restart\n'
        printf '   8) Status            9) Logs\n'
        printf '   F) Filter files      (import / export mailFilters.xml from this host)\n'
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
            f) menu_filters ;;
            b) printf '   1) This host only (default for BACKUP_FORMAT=%s)   2) Portable: passphrase-encrypted, any host\n' "${CFG[BACKUP_FORMAT]}"
               ask f "Backup type" "$([[ ${CFG[BACKUP_FORMAT]} == portable ]] && echo 2 || echo 1)"
               if [[ "$f" == 2 ]]; then BACKUP_FORMAT_OPT=portable; else BACKUP_FORMAT_OPT=host; fi
               menu_action do_backup; BACKUP_FORMAT_OPT="" ;;
            r) list_backups | head -n 5 | sed 's/^/    /'
               ask f "Archive to restore" "$(list_backups | head -n1)"
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
$SCRIPT_NAME v$SCRIPT_VERSION -- Gmail filter (mailFilters.xml) editor installer and lifecycle manager

Usage: sudo $(basename "$SCRIPT_PATH") [options] [action]

Actions (default: interactive menu)
  --install              Full install / reconfigure (wizard, vault, Docker, account, build, start)
  --apply                Re-render compose, build the image if missing/changed, start
  --rebuild              Rebuild the image without cache (re-pulls the base image), start
  --start | --stop | --restart
  --status               Settings, container health, URL, filter count
  --logs [N]             Last N container log lines (default 100)
  --settings             Settings menu (login, password, container)
  --show-config          Print container/host settings
  --set KEY VALUE        Change one container/host setting (see --show-config), then --apply
  --password             Set the web UI password (prompt; reads one line from stdin when piped), then --restart
  --import FILE [merge]  Load a mailFilters.xml from this host into the running app (default: replace)
  --export [OUT]         Write all filters to OUT (default ./mailFilters-<date>.xml) for Gmail's Import filters
  --backup [--portable]  Archive data + settings + vault to BACKUP_DIR. --portable: encrypted with a passphrase and
                         restorable on any host (BACKUP_FORMAT=portable makes that the default)
  --restore FILE         Restore an archive (keyword RESTORE). Portable backups (.gfebak) also restore onto a
                         machine with nothing installed: prerequisites, Docker, build and start included
  --passphrase-file FILE Portable backup passphrase (first line), for scripts; or set GFE_BACKUP_PASSPHRASE
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
  sudo $(basename "$GF_INSTALL_BIN") --set BIND_ADDRESS 127.0.0.1 && sudo $(basename "$GF_INSTALL_BIN") --apply
  sudo $(basename "$GF_INSTALL_BIN") --import ~/mailFilters.xml && sudo $(basename "$GF_INSTALL_BIN") --export ~/new.xml
  echo 'N3w-Passw0rd' | sudo $(basename "$GF_INSTALL_BIN") --password && sudo $(basename "$GF_INSTALL_BIN") --restart

Files
  $CONF_FILE    container/host settings (0600)
  $SECRETS_FILE             encrypted vault (web UI password)
  <DATA_DIR>/filters.json                         current filter set (autosaved by the web UI)
  <DATA_DIR>/backups/                             in-app snapshots (before each import/export/restore)
  $GF_LOG_DIR/installer-*.log    run logs (newest $LOG_KEEP kept)
EOF
}

check_root() {
    [[ $EUID -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "Run as root (sudo not found)."
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

acquire_lock() {
    exec 9>"$GF_LOCK_FILE"
    flock -n 9 || die "Another $SCRIPT_NAME run is in progress ($GF_LOCK_FILE)."
}

main() {
    local action="menu" arg1="" arg2=""; local -a set_kv=() orig=("$@")
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
            --settings)      action=settings ;;
            --show-config)   action=showconfig ;;
            --set)           action="set"; (( $# >= 3 )) || die "--set needs KEY VALUE"; set_kv=("$2" "$3"); shift 2 ;;
            --password)      action=password ;;
            --import)        action=import; arg1=${2:-}; [[ -n "$arg1" ]] || die "--import needs FILE"; shift
                             [[ "${2:-}" == merge || "${2:-}" == replace ]] && { arg2=$2; shift; } ;;
            --export)        action="export"; [[ -n "${2:-}" && "${2:-}" != --* ]] && { arg1=$2; shift; } ;;
            --backup)        action=backup ;;
            --portable)      BACKUP_FORMAT_OPT=portable ;;
            --host-bound)    BACKUP_FORMAT_OPT=host ;;
            --passphrase-file) PASSPHRASE_FILE_OPT=${2:-}; [[ -n "$PASSPHRASE_FILE_OPT" ]] || die "--passphrase-file needs FILE"; shift ;;
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
        set_default_config; CONFIG_LOADED=1
        if self_test; then exit 0; else exit 1; fi
    fi
    if [[ "$action" == standalone ]]; then
        set_default_config; CONFIG_LOADED=1
        build_standalone "$arg1"; exit 0
    fi
    # Resolve host file paths before sudo/cd can change what a relative path means
    [[ "$action" == import && -n "$arg1" ]] && arg1=$(readlink -f -- "$arg1")
    [[ "$action" == export && -n "$arg1" ]] && arg1=$(readlink -m -- "$arg1")

    check_root "${orig[@]}"
    init_logging
    acquire_lock
    _log_file INFO "================================================"
    _log_file INFO "$SCRIPT_NAME v$SCRIPT_VERSION started action=$action dry_run=$DRY_RUN"
    _log_file INFO "User: $(id -un) (real: $REAL_USER)  PID: $$"
    _log_file INFO "================================================"
    load_config

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
        settings)    is_tty || die "Settings menu needs a terminal."; menu_settings ;;
        showconfig)  show_config ;;
        set)         set_conf_value "${set_kv[0]}" "${set_kv[1]}"; save_config
                     log_info "Run --apply to put it into effect." ;;
        password)    set_web_password; log_info "Run --restart to put it into effect." ;;
        import)      require_installed; filters_import "$arg1" "${arg2:-replace}" ;;
        export)      require_installed; filters_export "$arg1" ;;
        backup)      do_backup ;;
        restore)     do_restore "$arg1" ;;
        rekey)       secrets_rekey ;;
        uninstall)   uninstall_stack ;;
        appselftest) app_self_test ;;
    esac
    _log_file INFO "Finished action=$action"
}

main "$@"
exit $?
: <<'__GFE_PAYLOAD_END__'
__GFE_PAYLOAD__ app=1.0.0 sha256=8f8245b4a4fd5e0d55c2db38dda4e75f405d6851164516856a27ce8bb93a82eb
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
ABgBAA==
__GFE_PAYLOAD_END__
