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
__GFE_PAYLOAD__ app=1.0.1 sha256=48a6fcc8862b10ab492922471de00637e0c3f1fc828330198576ed1ad2fb7f97
H4sIAAAAAAACA+w8a3PbtrL5rF+BMseVlIqU5GeqhD5VHKXx1K+xlSa5rkcDiZDEiiJZgrTsqvrv
dxcASVCinfS0zZ05N+pEFoHFYnex2BfAvg5GMxaNXY89+cc+Lfjs7+6Kv/BZ/7uzu7v3pHXQ2tnZ
3m3vi/aDg52DJ6T15At8Eh7TiJAn/08/T4n9d34qTwmZzKnrmaBSMYtM5rhxEJFR4MfU9VlE3Dmd
MAR7lQAEGd6XwZuuD8vieSyy+JTUgqhDHKGoZAijHGLGpbNY9cpTgbp71Rscn3Z/7BGXk9D1feaQ
KYsYob5DglsWRa5Dhx4jCzeeEtMUWE0aTUgtnjKSzU5CyjnjiNONuY6Xszh2/UndIhf38TTwAXI0
A844oTCNmtL1CQ3DZsR+S9yIzZkfcyu+iy3E9wbopWSceN49iVgYBU4ycpEkQUsDUejzgZwcF9DH
DcKsicBASCim7uxY7R2Te+7cHAbBbBFE8x/4lG7v7XdeyjGHCN5NADjiHXJK45icjt4mkyn5lhx5
NHEYqXX9eBoFoTsCGf7NOtG9/FFjxX6Q6sqby/NT8q9lDruqiMHdi4vBz73Lq+PzM7tttaxWpXLS
fdU7IUE0sYKQ+Zl6cUvolxW7scdso0RJDPJLhYjPg4MdxkeRG8Zu4NvG8TwMIpQ6jBbqEzGT3WEb
+RGxE/x6I2bg1t3c+wz8oH9c4P7XUuNs9RkjqVxD2/jUGhqVSu/sZ3Lxsf/2/Oz1+Vn//eVxv/fq
Y793dP66Z7fVVLL/3dmrd2/e9C57r/OO44vB2fngqHv0tjd4fXxZ6Hh9fNV9ddIb4G9F/ADgjn7K
oH58A6O6/a7ddGhMtcaL88u+/bz1HFbw6PziY+n2IM14vtlauXx3phR+h5hz2B9huk+JGZWPId9+
S6I5MccPoMxpIE38rohJRtN5ACbmktDvog+iAxkAVPOZ40bEDEnGFTSOpsHCJ23wY+2O+F7rRVwH
rVahNWVDTAr/rPAejJBSiwrsv7PAN6MgEObRYWOaePELUrRMUeJzgirJhWlCIjiLbt0RGLnRKEj8
WAAz6liVd1e9S53Eyvvzy59gVQUBld6Hi/OrHhGr8vP5ybvTHrk2BLnGTaXyttc96b8Vyws0uj7o
+S317J0Wh8fYnbMgie19fEBHGpshi9zAsdt72BSxOHIZt3eEChydvgbMinmjQQyNf3ycMurFU5xU
Qk4S3x0FkY995hC/W5b4r4O0itYFfrfFTxN0H7jl+LALX2ozQQfYFnAdJqiACQsoJnbYbZNP53Ig
yItxbnrBBOMg0YZfQFgH/gE9/8X+H1fgn54Dg7yDvb2H4j/5uxD/7e+1If7b+xr/fZH1lzvw/yr+
34Zgf339D/b3t7/G/18k/v+mmfCoOXT9JvNvU89UMQyjIsMbGdqQnoywTYjf/1w8VPlZurUOuCdG
BgPl5QaDyucHpCfg1XzOAPK4L0iTRBDwUQxdUPo8TvxRHAQeTxumczpKf//Kwbeq30EGwadJ7Hrp
k44sSVynMo6COQEuLE7v8B8CcyUDAmEiDVlFAoGbTjhzADbt7nki1OhHwDd46V5fAo49ymcpzBt8
aJBLxsMAOGwIKt3xfYNgsCLCfc58Z4AjB+C8GPAX3VcqmhyJDR4QvGLbqKhgDFp0OWMghjEcNAfc
glV2o8C3JiyuGWmcBu5uvSsdJd0lBgP1euWq3+33Bm+OT3oSWUjjqfVr4Pq1FBygx2rxkRWjXnnV
Pfrp3UVOQOmYIWRPScgB/LT7YSCHXAE8xBu1dco0CCRur4WUdd/13w5EnFPOZdZfwqreZ2TILrpX
V48hw/6HkKk+gazS7UNWA4s0jeOw02wuFgtrsWNBjN/cbrX2mt04mBsVSASuNCA+mrI55dYkCCYe
s0bBHK00xxH7BkaIR9QHRRlRj0DqCDFXfA9ZgwMbFZWQQD6q9mQNMhlYDRdSTTdCdYIoErLSESY3
vG5VLi7PLwbnl6+F4K5FyGSgsiH1cYDfPBn+CmonAjTK+1P2HibCJydg/CyI39JblrVKBNz9XYRR
+PcciKOYd6nnd76b4urGMYUAGfYINrC7kQcb/2hKY54i8uiQeWLkNEg8pxuNpu4tyxtOaTTr8ksI
+/K2K7Dn+VM/onya0SWazhjsjauQzjXE3oLec4lNJnxUEqWN2OhVOOcQ9Z4gnf2gG4aeiGTHQbSg
kdMXAhxRLAakWxzGQYCLSYUtd39tMPDpnA0GsNVjGrujwTjwYCVtQz7CnkAHDbng2J1cC+0/goSu
d9YfnPTOfuy/NW4AVbtFnsHX9q76U0ElMf/ih0yZB8vHK2DciB8sBi4PavWOYBxC+yTyMxNsZT8A
rpY94Nfvgc+sJB7VLR5HY2ypGVsfza25ueX0t952tk47W1f/A2xWxDxsHsb3A+Sdrc21NGT+a3Tg
J8oMfhhCddDniIdVbn/g+foGlzBIolEGmoRImyOB1YxeQJ3ihC6yG2fWit25POa13PopMI22AtWi
U5SWMIvXxgEBqJuY2TuuP7GNJB6bz406+ofxdAMpWlALqauNp6l4OGw3NY/4VqQAqXM6A6cccc2u
CsIHwczuRwmTZIlB15kcUHeylRUAkCZBm2bpvyOGBY3GGlfQBOwsPocdwYeTzENJcgM6G2DaHdj5
9jaO50nEBpSPXNd+Qz2uSAWeIhZ6dMTkZJr8lTCk26hB3gczKElAfHDl0xB2bkxGSRTBJJJpMmSw
Lxl4atDDBCzgLUNOwDqhLbQwrvjP1h6ydbaxCLnbK10GVF8Q89hYlu8gbbNUtz5uzbccc+vt1unW
VbW+MpeS4ZV0sXJZRRwDViK83y4oXMHj6kQhBXVJDKa9HKjhYNqYgw7XA4KBDW1ACgpBIJgnLG2K
UdcdU/PHN7lsxOLNg1tWe5ACwKOwKkEiSWplRx6j/gB9G6+J73x1X8Oj3G/klnoJllwhDB2j3pAh
RH8wkL9QwWjge/fKFXKs2abe0mX5ggdJDLwvVxl/EJDdIoNyYvCr0Fm3wI3OeU1b/RlKLI5qM7FW
bqj2D35u0ZUbqEq3WIFGBSEM6UP42xxO6doM54AxYhD+hE2/YFGtLpoEZ0Y+L36wMuj6CcvFncTX
M9zMt7pAoVXJM6QRZwNRDx1AjFqL6CI1rlhnsiE8tdDvIyf+RHSnuwEBrJhOyDdCX5dLDGhWq9WY
oR3NNwN1gcGfcUV6URRENQOCA0LVQkijrJaiIydlMkBGCaEUqE8wFiIvEfGhZUgCpMnHBXrI5Esw
gBCEjsGu1HQylc/I2KHpfLgqOfkS7FpOgoKsUYErZndxAZ8AqOMyQXi3sfIpGknfY3gkRCki5cEa
BIIIH5YD9yb6suubTEdd5w4NZxzdo6YyP5mjIWO1TAbU84rTIaxRF0FGFNttTZGlmmdbIJ0ilJhh
2BpCCFUBYRp3GvWiaqJ8GnJnAs5QRsVSaI30UfTKALkwVu0HhC4iLdX5dASaUiBVsoG2QPy6xvYb
VFox2ya+VLgWhFdMKE1PyHMJsl11iJOEHgTY4DeyCLu6RJyrKqTBMxbGMqSW6K01Th4kWKdNkZZL
XWVOiqCl4WKggomohV+74BWmDNbdEEigS/xdFWyoVMDGpg4pQzCAZBttUGZOeyKLFStOCQdIj5m/
JQE4AvLh9IQguDtMQAw1sZOrstas0gse33usnpnSNBgSKGu3Ddi0Vdyk39Iw4C9gwatGFR8R/wtj
hW78CA8mLo+7g596HzEDqv2V9CNPPYrpBaR0R308psgm+dsyi5KsYl0R/kqSUZpgbEzwWL5Rr5wB
40X+wRPWCoKvkz9grR7L1wrpWRo5S38CWjj00DmuOepLEaVwkupN9ViVaaRqVskC+QalwQWGxBTs
snITNeneMQrBIoAUx1DXNIxRN2MEzZ8rW6ksCvXva9L2zOrSx6PFKIqgozvTdA8afkDSFFpt8aeI
LTcKC4goA78KXhziNvQtlHOwxg6JA4g40avJbBssb4AHNuh9cKnJIgpgs91jQWgyYc46uTPxC6hc
X76M/PBhkuWUudMDimoeBO1KBrI0kWP6K5sO8ByS9l6rVU5MVn/AY3cBR0ZTGgGBmKPVy6MVcQau
RStrRk3xDZ5M5CrF/GVIOVOVoywFhUjqmTgAK2hIRq/x8t9Yt0vPZattq1XNs5rqu/4b83n134eG
NgBjFCwM+tyuPlLYqUoYPEfKAR8r7lQPte1t/BK/FCfZh6d5KZa/bMo2DXCMkK5zCFFaB4WmoW4A
1ucdJbjOstqoykAcI1Ehqu+IKzXBRU2IqD9hQlVSWdfrq5dNwL0+ncogD5diGQAmbVCA2f6Ti6fH
ARjz6K0qFCpXIJhKwh5qLlYDQGIABjEfLpXn0ZBXsaMKnqcqGBFgjyISxJRiEj05KglYjgupbhbJ
FiIGFS7Ga0WN1qMx3bqNpZyk269rM2LJDxQRlHmW72atpgfin2Wx0Q2stUrxNGg5nwBUBicfX+CN
fKfvmVQ/RYB4uOaTpCQxeJoEEFEBh3O7KlmtHr5sph3lwzY0vkThUy38LLXvLFNF39BkDc+n9HmN
N4jtgHVkRv3SwG42xKbmwG3eyTwH6qJdXcqIbFaHuFKEg1mTDBVnN9DTPDTyFVOrfvOg4qk1yYxd
1vmyKXKrotk1fvENaRMAtI7lHmj4e+qHuAOEQVdXLwbYUBunpZofsgMbaxFR1HNfUoZDsAXkVHtG
owmEsc+ezRb4S9spoLNZ6b5TlkdktfjN4F/xnkZJNeOKReig5i6XldYEJNwRDGBJPRLFAyx+4YpS
cS9sIX3iXmunGPqLVFSe3qgLO+7vosZUgAqwfEBFuoKnVKizkKOzgbyxBUkjzipSG5EgNnJW69k9
IW3OB9GklBbQoExKM69g9hmiwoM7UDFMjoCrdG1RFrut9kZwuvFZGu/fvzc1JJjUV19R7o4AF/Xm
tlFy9GhUV/X1wtvY39AOXbGVBv09qhzBwjNe+QFr8cIYN+V1ld9hM6G6qqe1krU6zhN1z4TbRjAD
KaVxhjquwyxIQwv4ftC3i8COxdK7NdwlB4M1RFM4RYCYTYy1pvHcM9amoqHbFKXR0jkBplgVR6+k
18pl47Wh+BHVDsVTqQyy2cPk07MDTHH2YeDcazsLqUPMNTCLIyYqqxBhux7WlPMyq1Jrl4uLU/6I
1RBNgzjuKBZhSEmvFE56ilBviDSkXlqcR7YYFrts49gH4+06qtQc0nuUFI7ebbUelZ6qT6HwlrOO
qBBqZKTVq7QK+UD4LuKqrCxWX6XIUy4Q+7WqJ6hgAn4LrI+UFx4JQVal2xwpEgEOMqDPDuugSXms
FkB6MP1Eo16mOKpw3iDKI9tcO79oEHHZzcaQVWe4nmtbwFN1k5lk+Q4TXSLbUGudhJq6iWJ3phnM
KKhXEn5KO84CUS4HSFQBVlCMeeAwfaYgmsuJsAMXVR2CqDnBta9XLRulFcP1km8SWnhBrqbiR0jo
sYbVE3/QjlOObR1McP3gN9ohr056eJ/RxPvJmLcLhERl+5je4o1EdFOPMz82jkSej5KSKD6cnnTI
EiZb6XIYAs3qQAfUjJnZYj24e0D8Ung2MSCenuhVcnHmApLAbZWdP4EaXysVvmmIWHgwY/dcGoxc
e3U9yhWdOo4ItVuVDXVP06vCpgDMAP15c6/7YhyrovGUkU3HrJOZJTGbZcgUgQUM1ADxJoTkDOLU
9vrJhGafHkjVNq2Y/JkBzPlEHHSd4gI5ZCkmWxGfLZTYYNe/IEs95QSVU1Dsjo7ivBQLoITPXGDV
sWQ2jqcqOTG6RBprZGVb5AH6ZHEKKdRJWeVEqhkBqzpSRqywqXBj54HanzRpc8Y5nTAbqMg3r53+
aKgNYQ/LrJmswZZaM9mlW7M/6z6lw3lk7znYnDsqeDYKpxfoccbleypzy444XYN94eJJNEIBKmhV
nuGpOjySFUIu7M1iGoAdVdensLrg36dVQxfSWOmFRa0tEjeySOKD5caq3EzW5FB/ENNc1hEDcfKh
SOgQX1Dsb+Tpa5qlzlBWquLk6O5VogK77WOFPuDXquVGelZRKhW1+4IPXbclyBtkgKRjr1dZ1zxx
PSu0IB2YCKBo84VBfgdKLsYnwxgp8NLCLPoihceGqdByb2+nAhhIfVgO1VoiO0MRCVBn9YhaaNym
aqDsnkJ6o2aQfiFTeWzEmp29USvUdn1eMJQUZIfu2h1F8z84gBfveVTKciPogD0Ng+L7kNl4hdxT
aVITx5QnR5A6QKTO7SU4SlFLMF+7gI+7ooYLGlWl2VHGC5KaG9tYCoZWRvUTOZfxwUyZ7d1JI2fI
QLNQ52vogFfSympwuOT1VUkGkd/d27RDGDoPFMADl2tcvnbR4EEVVXjs65tSm5p2P3qLAS9WYr4i
TV5pkKjwNGVJsRmBuQyi8iRF9SkOa+JKhcqV6Jhp9x2xAIW9EkRaHmhfvxGp345ADHn9HtF9Y5PU
zxQFiCpRw9+f3N6vBKFi+BjCZhWH7hb2GMZeOdMbl0twnuJdnM/xb2PjUqIE/4rMrIwy0WPCEZVK
WvRkvmwtUkyHrbnewp2sx8nU3aw4JR15bqav6qbwPRePozlae3iyaDS5vW4LbyayD9UkzkPkdQ/D
YbfZrSIx0MYXTtKEWS/64nmFdmtXxeieNk69HqPVv9RF5cjz3KGlPHuOEvvK76/iW1iYWIjXaPJw
sJBZZJe9iugteBTXv8bpVdX29oF4K6fdWeKUq6wu0iDp60G74kZYVBLBgsggPI1rLXHRxJJlEuR2
u9WSImzXtZC+mLFspCqVUtztElniumhZFGhhlPi1KWiinb5kBPQjP3bZFeRNIaZJVSEclatqJLgD
OkS96HWdrf8fUlJ/ADE3hvBVzEaqwWjBds35zjjZRvUELtIbo4KVwQC8GWiM4kdqbuXPvP+x/l7c
F37/GzrX3v9otw8Ovr7//UU+4m0E296x2tZ2JX3hzra3d8RrtvlLDbbdsg6sduXJ189/3ftfsmD8
z70G+Kff/8OT+v2v7/994fXPzwm+qP3f3znYWfv/f7S3W9vtr/b/S3xefvP6/Kj/8aJHcOEPKy+/
MU1S9ubfrXjHjPzx+f8fCWKagA/REo/i2wHMN7ABsl34AykyFTeBOIvTFwfSZpne3rpsIbJ9oo7Y
bWPhOvHUhnjJHTFTPGBJAvJk6pl8RCF+aiMSeV2ghIv0JkHlpbi4eAgRUwdvzC5NczjpPG2N27vt
71+YZkh95nWetg/azvYuPHuuzzpPt+nOzo4Dj3iXt/OU7bPvGT7Okxh6nw+/36c7L8Tr5J2nu+Pv
R2NEhaU8gN2DsRQeIYvGp72d3SE8BbPO053x8Pu9FtZIni2HwZ3J3d+x2jsUp/wmtGAXlnOWc8gu
XL/TejEGeXTau+Fds23t7mF8GLO5mbgNEwsOzJQNjSs2CRh5d9y4DIZBHDT4/7b3bc1tHEua+4xf
UWppLEACGiR1sQ1Q0EAkZXHM25KUNQ4eDtEAGiSGABpGA6J4KE7M00Ts00ZszL5txL7t/oR5359y
fsH+hM0vs6q6utHgxT72zEYQ51gEuuualZX3ygpGcSUOJ/1eHfrO6QQaYO0z6VWYfqneiQbRRP/G
FNm8JcaJq24/Hg+Cy1pvEH6pnwbj2vLK+Es9GPRPRxWOjK91QuQGqI+DLqKm+L1a/o4K2ZlMp9Gw
tkyP4wieMukIoC3Nj4dXoFQ3VpBaTBTq/LI+jcY0/z9XmFbVXtUxnAr8vDX8k4xXnS1fAUqAZlhb
fk3DMNBTPLIlxSD3gW9X7sSxmKW6U5dK8wrMaPijst+ejq6c0T5eWVlpv3g1Dzs97UXzFZhMgm5/
FtcwPAO31wAbVap3ZpOYmhxHnHNB1rw/OqPlmybjqZ0hrO5KN+cOgrCwlJTzSRUhAFxezQEa5eoL
6utZPe71ek5TXYSI5fYJE1E9+8AZLCERoji7V9E46PSnlzXCXjNPneYCpfuj8WxajsNB2JmWAcxg
EgYpoC91lpeW/8pAB6q6QK4zfUHCjL/BoOw4GDV6wbA/uKzN+pVhNIpimk5YXotG1GcQl+2jHDSC
rnZl98hLvUcYFdtBzjb7Ln+XCTLbPbWEsc9tBbQowDxic2QcBpPO2THRkS9CPGsvXi5J5xxde5XM
2MGIQTAmndZ8WbhT7wF5zAlo2xtEF7WzfrcbjngMZ+Vp18LmW2ro+ztSj8840UPkv8KQqhGRqGO5
9M9B2JtK+1fp9agv2PcXYf/0bFojUcSd7ePlNu31ILsv4f+sCK7WRtEo5J4msi8VzSfVQmfl5Qqb
w6ddf5RDdmQBXmpcoULUsF6VFYMmnbP+2OJJfwQIVNqDqHOekF4C0rcJxcPPF0A0kL3MUjDmpMjZ
yxfLL1cyiFu/OCPsqzBO0yQtfmEo/nmaHAYryy+XkreD9iANgu6LYCVI3hOFSL1/GSz3lnvynjbh
b9htdUQ9Vdq0Zc9r/C/ywHRty6p9dfPyv1qSaYCBp4riQR6H8IPONL6aB5UhJExGfDZKWix/Bfg7
uKq399zIULVLUk50erVoA/4mYsh4YAa1pEc87I+K335Hb8rfv/p84YyhVsMguiTmuaOZnLaD4lIZ
//NfO6WVf5ZsaxELXt9xY2e2o9tmu5sho8Ljv1TOpPi3K5/PEioTzKaRW7s3TWovZUYEGSN/OLnU
+R9Jg+j3LitaSOWXlXDEmNbrh4MuCbhX96SOVlYRaaWeHqvGt0F4St3cKrwky6pea0Q9nfS7loTg
Rx3/ENYM6QlhLzU5G44IK77l/noTniwoMuPJPD+yrSo+V3PzmF5YQhZ2zuO7jGMSjsNgWlwp01BK
PBaWkl6mGtJdz63Rt/kcNE3G3XaYY2qqa/DGn0QXL+4EsmUNMvU9QKXHiiYeT6MgJrQzEm2v/4W0
hwkjq0Y/2QmvsyRZJMy7oBBYXe1lpkR0Xsog0MsE2R1hKBELXr7G2M1swdWsyL2ylGIG8L4YdiAT
9MOJlQ0xnEqePOgjscDtmKulHGxIs9biIdCqkMwXa1S/jbNfF1arWudbrWoVFEqVVkjDCXTB1bPl
fK2RnuO1iLGqQ2wnfuNpkdpT/e4bj9QCCSDxGvqU099vb/3ln//XalUqcX3GLCWuYXaoc1X5hiRk
Y1Jx4VsuZ/zGLASzA1mJuOSORvcunt3mYOA15KsKBoNU7+ny77TXtqG/3FC0KfnkvIb+kipKeGAh
AmVK5sTfGgRyejtXTNZQCsJddyC/bXFZICxJYRXyMjfQ7X829Ums9Rrs7EhBVMRbafYXT3HM3JlO
pXHA7+xJrrIQCwQDSSYUWinTpMhysjIwQXhyyFEbHxjbdFEqHEnonMTtewShgTnqTACVlwvKQorw
Gp/gYTPRPrfU6M7GoddYN7FQtxUfRXLGsbETyWzT5QnYPFH9K7Pi3a7XeK52bIyWu+RmNTVYQGhr
y+5iL8QK6nFz1IsyZfPw+IAGroy6aBBaBhx2M4NJ199nP7vXkL8y88w+nNvJotHajbweDtL904Nw
Gub2v1olxLQIigZYlfpENBHT5JerVcFiMa6Bphg5hC1k+jvqdgeneM34tYpAUEXAO4vwhgvJEJF6
6z29NBjrbI2zblLkEKYuogboz6yiHmxmP3UThDYSS2NVxIvGmjm/95d//lfSXqfEJGMlQULIqMug
1UWtw9JtHGzSazie2VVeEkQAEe5w/LrXeE//UjN40dB7mvefvEaSmaAyfiOHFBe3hY15GOW2Q69s
K87+nW/DnHxsHMiX3NZMIdukrbWw3bOACNyHQMewEXuMc1tGMduqc/RyccOjiLpdj8IYR1DPiJrm
totStt2cQ5zz7TcOiJmatty3ztpCKEpVTcinhYx7pLgxRy8JqSxZyryMT2IiXqekuYETT8+C0Q0l
Cbgc5ZculiJxdoQCF3eAnuYgo9mwDTpAis8bbynDQoqQg0p3mC6fmL7vVIdtr7H97oYC51Tgx5sK
0Pt3ly5byJu+QwHyfjprK8KwZX6OKPb9+EsevqR4MdduR19SyOwcyG8o7IUkrC0P0e7UbOpYekOt
80ns/ogfwr0wjeeavmHSEEs9LQKKOKEzBEWTGLuWT1t4qW3sqSIScqvVTtQNG4g4q/WiyA+/BKQZ
8FFEHBGkV2Vd5CpQ7Wv9jOMgd/dLvna5DPpDJPO1Z6ankfqnzJFpPzX81aol2AspeFNEnN9EprUo
wfkHjDSRQ2akmF0c/RNA0T+26GtmX+0FSNFUXTtDYncOvg1jRCguHgxJP15jTc6Q0n5TQZyHPq4c
x1WSTTqXUSGzqXO2rsLuV+4evqnKP3AXPKYTJFCLRgFBb08Uhnu3EEedPuof8N97Vyfa3+9pbcJr
fOSDM/G9W4E2SnuD5I7Z8P61x8S5I0CA/mhsnG8hl2ClpYWLLg8ByS5oc+SLDFQmkRhsYow00g1n
8ZSzM+AwHkEnZNRDURwZIWV5EoKn/HsQynRCkoY60PHqanNE5VQxkDelX00y5xKcNBR+cIge/fyN
7XKSFBo1vOr96W9sTHKsEFkXAfw3t5ckaWko/s6HKEFm8fA3Np6f36Wh5DnJzBOT9jUY/VUmMt+V
zOmWnu7NQHYJ+yZO5jScSwiRbJ52TRBX+qRGgziy117yPlFBxYapHKZjHGl6u9KvCamHJErSXnqR
2abMWdP5bN6wqr5aNc3cMBGjkUEZ+gR122xZ0b1dbShfMeolEr3RGGVZ5IdH0+6QMn4OkbozgxyD
8FCd9/fd5Wa3+FRrdE9LfmcQxWGxBM416oSDtEJ6q3HpgIR1Vg2txBeAOhywwJ9Sba1CWoUCCe1T
dEdomoRDnFMHjSb8GJDQb4ySqm1Yi9VUY+xapKjmqqbGNJZJEX0HtXTM/RJO70C5T1kWaPTjpFzj
52hm0j6SqAKFiEBraq+JHWuJQNZIDnYpOZPpuw0J29E0Pdfur230sEQveeldC6MqcRwJY+FTnGbV
zFFOxRs77ObZltS+FLLZK61BKbWRf68hykHK3IHxET5VlKOGZTmJB36ZOaUXZ3kTLV9KwG7qeHsV
9Ziz2TSdIadHmgbnIScyi4YB+3WRJAmp1pIVumHDmo2kp9Ph3Ta36xZtN10rOjfImtRYvLFkz7gW
pxt2jjFQ3W/nuI3fsF8WivSauWyYU7FpGd6RlSej92xlyQpjugGYBDGSHNFrMjqMsv3ZYjcja76P
xlvEC6W3HdETbtxKzQEfBGTYiV5BxUnRoEeqyCpAlfhJGl9d8GYQl9TMEe54AtLqQ4fdsMcRaEh0
hmyjvsEDlJFZk0oXDvi0m2h50ygq4xCPPmvXHwxI44OZg+vgYKzUg1GTcZDx/o9AeRn63VFe+w5u
wHbrZrgfulunxM2YzszxXJTKFE/YIopOaM7WSTRxB+Dl24LX+GhRmu03+CH8KwlpNhC7wTK+aJUg
F9wd5NoHcwPIrbvmfiA3XiPJt1qM+V4jwlngJBJBik+m9BuIz04+3Qg6O4YgupQKmyO3NL8xSyLn
0d2N+0fsk5TYdeOSWa8AfKNW5iysyg1jjYI3k6zA/c7Uqxc6REWm6gnOl6k3DWWlyl9m4eTygOlx
xOfldckw7piyB5K4N1Zv33I+WZM5u3r0zWrDe3pcPS2rDgoWr7xvvJr3TTAc172yt4rvgym+NvD1
FF+RptNk6Swjhaf3zeMX39e966POcYl6190jfyLO8+rsgZw8MMkdmEodmJuuU2frzOSddNJOZm8J
SJv7jg0YmmuHisehs3pmk3rm5PRMpfRMZ/ScT+h5cwLPG/N35qXvdKwSdgo/7ux+wsUdoP4H4bR4
5Ps+wFtW9IXmd2zXHE9Ptt5t8bF1gntNQ38a1XgBNPxryUIk61ADQL3y/FrUPHgIrh2Ami5SoKx5
FqZZkNY8NiJMGLoJcGuegNiBcM0TdZ5PQ2dgXfO0Ws5wvwHsNc8B8uIFqHESaqsLJzNcax5yTulc
S13N06Y6WqscQxzNSb6UF9vZap42tGUKiRmt5okdLfNSrGTo3ZjJMOACAUunFaIRC32ucSbimueV
mQDW+OYDk4Xk6JhqcSXtsHTwqqTfEDx+5Pwko9lgIOlI1vtIs70sBaAzEz3Z7Ooiuhowpk8agn1a
4BRusPoxhStyHotwMnnDWctLVwVOg0wAx1nUJ0VPgkS8Ul1Nfajw+sQ7vaSaeMhUd0cO6lM7iqgZ
/fEUUn3jPfNWX0uQSLPOsY9EO5WcET6UM6fFqX9yxr2cnEnCW/MCWdUbeQ3BwuuVdaffLS0tUZ8v
Xi0tEciuC0F8OeooO9lg3NcHoaPxNH5zde3MFMAJLgJ4XcNp58wpV8Io+73io4kfnZeuFEA6RFIO
HdZySACp4xjuFT8uSisTTvNfLJV8PsStvn6lt9cduGKvrhVOW1zw8krW9SFNGpEy+qTzBIMvVKtO
AjRYZ2ISmULietl58WUTzlxiOxc9GEw8lbqrpEeHqWWRVMU6AR7GfBPGUkGTCIJKMv4qxhaW5koZ
TGk9uYp9ycEC9Djgb4Qfz83T5576P/+mBGeuP6O0PnF73eJh6m3h60PldWgIXeTbB7AsLJCmtTsb
hGD2AhOMyAlYyY7Lo5IidM6jo905AihnHzmoKYshCHplkj1dFWw28RRyLViQsroScY/IyEccUNbZ
JWpJdolDkpyIyrhBRnyRBC0IQqJqf3ewu+PLRQAmd11Yuk6tND53gAaRHk89Z+xc51P4/jTainBQ
B1PWIotuUDC6SDTjTi2rHmERqX91TXjch8CF0NepB8oExFmod8U1p5sq5WyKgAj/JW2LZP3hhdsK
R6dT2sI0KL2hwH41shbPsVCPjn61/OJrR2VcPC9BYuvOSGArjsrnjAEjglxxfHR+/PUrBLoBD6Ws
lngqdpTUA0I03CH+ZnksPepj2lXDUCaL4cz13+ykuifhIVsDu3qXh+Ej5xWVdko8YtnHp4YAhlTj
JjKKuGVxXIaFKYwd6nTBeb4NUU0gUVIX/ngWn+EKisSZCi+eo3I72W28ktOGzCbVhASJ3aWBFM7o
vNi2qZaNpXlylSp4LQfhVLHB5VumtbHviE18cayfkZeSYWoXyXOdXJwFqGw7uZLUXLuZ90kXSRWk
SB1AZXF6gCeWmnqkv5v9oJvXW8KBK+JLbEZV42WvzrBvTKuy3rbGRtrMKMVMrs8U6UbFH4FoDrKw
UizXXFheZbgOku5tEL4Xe0x6dQ1kaM3QQo3ESLDbD5GKSfLO+5CfikBe6UWuYinaH1+/LpWeLxNq
u0OWtxi37i683O0hPRHGcM9+s9RMGFoCEMPgEnD8ouWxX4i0yA0W1PRQU+iLcLIWwFtRt+URCqmr
SFikrpaU6AJeCeTrHKI+Zc8O35TjwnsYjIvFXrlfEo20V0Zq7ItaasPrSdK2Pz9i2BR7pWPsKfAi
jSG/lEz7+GPo8gStZkA28R2gEekpHp2XPx9L/+ckMHjPP2fmnlDnX5iAFUlnOPqsqfHCknZoAjBk
6GB30+KBTvwLTdznq3LM5+KqFjI0Ow2buSZMHOjiVh5Z2Phc1LShlYTSlb4n6CIWfCsG5bYjo1gM
CfQVUqxYoOvHHslngd8nQQy34EgfR7rIMWA6B8p6usl2bpNtabJ9vyb1tivSOBto+a1aplbo16r8
quDnEm4K0NqQlku4AQgPtMUkbFgZd5nFff2c2BGp60bXmkd53tppWJuVeCc3V5VKx3pTGxE48dMB
z0bh5MPhNjRz6ZKbHaDZVib84glS2BcHpWuv0SpJeikPJFNzuvTgNP7JgrKaZqNY0722XJsan2Xi
AGMjvRtPWnvSwH+b2uRdAzymnJf0L//y3+hHyNbT2H2oHYKcwe4ddDoSHpsSiBFKCe2lQE38XG1r
myW8edzlIe62ZI8sXmbj8BsqaEefQx1AxZrAteQYkmnLSlLrB+HAbBOBC98jj59gj5eyaawSAbkF
G6jfLWlUuxl+/KaxOuVDCKvTibV7Uj8mQB5WyRt8H/Qegf4kRsho33raB+JBrcpzhKxWp2duRxxN
QD099hqP+Z37UMJsjbAy99rEgpmwMnnd+GSj2PWDVJ9VmigeyKT55MWTK4YpEFjoYHTxYYqryUoJ
ul5THS5Mfxlucx5FsffrtmS5rpUYr6MeQSgPz6+hHj650jvIPOuya6xjNjN8Li2z9Vkj0dHrWXXE
YgKLQG9ZPXUfXdsSLbFi6PZSwe4l30SbayabxKGnXj1KNZ0Segz8iJv2yxeuRQKJjDXVSdg1H4J8
k2WTxrpo6VKR5XcjyAvjJtY5kIdMDmir0wIMrmu8yYTucOlrvdXSUmKJu9YisanPR3d0/bQASWRf
Inzfip1a26ivTUfSJn4WrziQtuZtv/PKHDJb836Ur/TtnXddOkokUebj8wNMqT65Iz3LBK62G3ON
uFpebhu6gAlQTTeh6VBnGrvqzVjzC35hmnOPWeA4rRq0aWf+3//5X//NQkdqXWsflLsUWcP0zU1j
j6FFCEE5lZn15jWa7jmDbdrOXLLyt4NaVzxMxr4bp/zk6pxRxDHhv/XagdBCjxEzGYLm5gwAa4W/
beJgNgacSaXciRntNmUgSOm3dqr87saZnXuK05UYXi57yizEuTMCV60gDjMRWg1W8eQKnOnaeMim
3bvwGBPeH4PFpBgds7k7sZvuXI8jjLz/fPk69y12CQrwbjHkH0j1NAUYCd2SWHw9/afpBqkNhqrL
Qua7k3aeXF0wRSN4Gp4DOWJRJbSbeBEZxoGEl8kxG+sSVNkyJMfbxbQnuAiz/vd/uaEOYqczXmnT
hDhQGn/5H//dcUPKiJnVtnIsXMxAFYkwpHUWsjJK0O1u4M0WG4YJdT2Wo2APN5K+tuPDnE7KYjA5
DacS1Abr2/TsSOSDY6u9Q550NOnpGRLskkQ+9eO643BwxftziOHmVU0t1x1HxbljptW4LjY96sqO
p98VNUFLSCVXspMMxRDQ8/2qVIHmwXmypxOP5HBgxpRFk+nEjp3wv24SYNu9jG4bDlR0RMrbRDZA
7nWqSpOyj7q8iEWWG+enpgUPDfRJPtAnR3qjA+os1k8nJacFM3GA351CPQM2xjIsPa4Znwb9UVzE
7i/RAv7qSS1aLs3e3AmZgQXumL/MGQ1wC+kmX4Si9Si92npJaEKBrD7vyBJfU41tWZwrgO1Ic0s3
H2NbYuhfni+X1VIZF4HWiHtfjqeRPyG1JBp+/Li5XnR865Xqadnje00hW9XUFSFXqtEjau1YJK9r
Yj0Zn4ILIm3FtsShy+ZGzERC5KLxpVeyCG/mARJByglfWTQZWiugc5fiW17FRTMtL2NQeYu3eKTX
BTDR2wlItz1I05D7IvOUjYeP5ovqXEzMvHARil3ozD5VZqC/5A5Q6pf11HRRY9zKIYgc/OWWzxDY
MDnZmUjlLhKCGrmOVdmIiYze5901h/Pz6C4YRfvuynrKkhOfWf2EW/WcY6DsGEvO9rJCcgNJfGzO
mypZoDGtj6V84SAxBGmbDa4eOQoHdiXG2iyjySaRnYEPiUNQ2EodJdLFLZF5w9dh02v4bry6qOn0
3lwr/Jnpo7WRmDDyki2QETTH8/pMRiwzio22CZISd3795snV52trPPnTyCu50OaQ8jnflFXvzFne
EmzrF9tRNxhkHIyIlWDUyKhqsqh/3RXJhzkhRtGB+lsNb1ZTQdYNxLVt2K7g59LcEqfWhMZS1Iax
/ihkRXx+lZgMTQWuKUYN3zfq+XzcuFj9hz/Fz4pH//DmT/Hx8xJ9f1P0n5WeVIVIDEEjhkcrx3qM
GNnwaPkYI3IeG36aaKFXKuOo+PoVggNOndYdj4V9PGx7Kc/6GGv5xFmMXKIRz9pDvkDXilHMd+Ux
yLPG2EcstSCmf55/yz1EBldy3F3g0uMJS3brkkYNdPpmPG12u6TGqkFIbIePb2g/GeFlEQagMnGk
stLOw7KcdcQNIX/m/POJAlzyvTlxzHGj/VWGJv63nI4sMS3dTjaTsr65YnMMWDJpSddmhez+3H8s
yL+Qc1q+qTMslHx9fgS+IqY6llkguGaewUgcE0fiIAKfZvMel0qZWBzdtD6aMd8670G+vMrnF0XD
8uQZFWcOZ8sDW9P9OKX5QqyjpWMRO51iLv6ivDm0kV1mp4qP0JC6KS2HNOasbDl2PIfU2kmnia1M
0H2fp+iQWEE7NBt9ob1ag1M9caeVun7ZS8+jnrcsLtAMdxIuAQ/n4NQXcP2UkIGIFH/imI9686Sg
Z2K5QHDWifoCwXpde8Gnvqall36qLxJDZ+lIUhGB+Db6Nyh0XDOavR4rI7QNQrk1BEVf2eXGoOwe
IAiF40p63WwQiQi9ExOqgYCHiW98gMb4/pYvJKV3zquEIwuvovnKWCSAial9Ek8i3eRFhFznSHFs
k80GRnUjsdXidiI5+aIv/HMC3djbmQn+St3UNA+X3xycc2XHY+74qbmjuy5Zg5dzu8Ib3NyTYrlX
uvK1Hf4ktVCGmct97FKWRaY2C0tKPX5y1fZH1zWFv+aqIr1MZeWV5sUoy+35/q3Wr7zpyacOzVdj
yE8Odsk9Ru1Qtxt2a38a/Wn05AoTucbXlno+dylFa/dHCEwSDm8CFHBhlK+UhIrzbWJf+JkcTFJF
hHFj0F4qo4/HbvOS37KS0yOjqtG0SzrUKeVPV8ZhvEh/tgJIGiUFpRMp568aYyihnXbfzKvz+mYl
QjKN0XJPRt59RiVxoGvZLrnNiCQ8j+Q7r1p66+NWFegMmYOCXj1lP7ASspye0ecui14AAh34Z5MQ
9Pnj/pYuIDoB/baTbg+iNodtBH43uhiBeCi5ZAePLJNU3AhJMdG52wj34JjsRwzmFABybl4qYbtS
yefFhWXN5Uts/1wSGsxL0DKtENaPHER/chXDdNYqm9vxYLc9vzabRPxO1/6fRrLL9J5qrq8fWM8t
rA1dYz0gGY/2DYlecXJqSRB9Gqngc0QiVXLaz2+VjCicykPmCiAp3rowMtJQzgHkL/ppMVzEIXVd
L+Q4zhb1sqgxWACNyeNYWs0Qe13HNPHHhVhiSxWy3r+sGKeVCEtJWtros9DtmODJ21bJlSlSMlWO
uY1rsRT9aN4L4BqObCDtDbJvXoySPdJoJq0PR+ZP+ncNtQBEUw5hAyhjmTNp1HhLELn3PYfoYvj6
5OTdojQaNjzDZsJwozR0g4fRnNCoJVELqAXyrn2/WN5NYVO2Wp5QmiOO0oS1dGxnz8OF9mhfJLPQ
ynjZnMU0JfRRzpKxRJgFmUZun2BloLFLt8XvuSJL4voWLBB9ZeC2y30NWC7ChGjfp2rAeB7V1ej5
c8OAWWWkOnoW33yjBj5fCRmD+7P6TOIqrvLObYveUXk2waKoDf5KurhFkTTcQI6YZJmB0ON5wVbf
a2e2mjmZuZCAJsiWFE1hmxUedcvXixUDe0egK//zQM5zQpt06UQBMA8SiZPDkPKOE2fT8XKe0ko7
nF6E4cjmQX3p5sK+KQWxJ0c69XZtW59rfj4Itsa1jb+2DWetvvYuc1rQ2etsjI3MFNVlOPU9u5Mt
eBb752TNMl66dp57pS2432bl0nIPPUAI7tdv1Zo5is9HOUjOxrgIxWZjfQQ/zUFYjrxBLWylblQk
sIyQ9+rj/uZaRDLICOIaQcncsdjKKkiOvpjVFTWNTGGnTrGR0QVFTBVlcDJJ1MHJZIFCqDeIHP29
aXu4XNjbD4fR59A9FSzkEdJUyHlk36qizXxg0xwIVEteCqzZ7SMXHM5D5+4w0EyM54TLk3M5ciAn
h62NSh8kzuHG3K8+uJtwKKHJcuSHbToQ9eu6rBzbXVCYzwQlpZ1TzGmaoxIOlxS4H4tL6t3G49wR
wizPB5hyZm65mpxsypuvLnI9JyEJoZZV8jWSssdZ1gvn2JNDLcQ4skYMqk0USR8mJiIjKY2rcpnP
He9/Ihl+Gv9+13/d//6vpW9fv15+uP/rj7r/S9Yf/57IHZV/6P1fy8srL76du//r1euH+7/+iI/n
eQW+O7siTKsirAqXlSrGC1WczEY1Nb4kKjh6oSpDhSM6eIWA2Q5fc1KJVdUiUqlw5xvCCujdGPgi
8y2KC86Vu/orEu3DVmR+m0EUCieH23sQq3UBf3jexXfkKOv1v7zxTnthBSUrXqmQ3ON6xHe4rjcP
mx48hWjEeeuPo7Hc8tr8ePjh5OPBxj5xkx0Enc2Vmi+B+1rlZuZRHJJ+uVRO3/JsfnT7E74T+uQE
Az85wQ3cPrHmkpkkFiGIVTO553bj5dJKoXDQ3N7b2oCgTABcfYt70PUB1zdPl/2lp4rFLJJz3zz9
ePi+8t3Tt43VXkhSHJUcxW+e6pt7Ly4u/IsXfjQ5ra4sLb2qNkkKfiplatR1UhA8axjE/mkUnUpO
Uyx3jFqvn9r71raTxPmxuWhtVbhnQ+7SPlyt8t9VZpSN6d+msqTKw9WqrlJYhfP+srHakUyfl7TE
k+Gbp4KnT6mgedGYH4Dtv99tTIPTGpp2hl+mkX9Xk5Zqy6tVKrWqFQa0q78VVjHLmk58dynJsp5C
qHuqD1k8DdwpPK02cmuw5merbI56k6DaHFCBmGrkd5LKumCrguMv6sR1ZdsK8GbfVAEObrfwsI3S
VQH8H7YAK/dbgOQYazJ0nfNCUpYcfTmWL4qTnCiEjV8iaFz1p98E4yiux4uAks41aNs/D8NxZRim
gFPFjmqAgukrw2XTFjtlVgPLCg61JOObvkzcnP1zbz23XjPUe3MlTryaKvYjnzM6b+4W8Qbkocdm
cHxjn16NO7kuz/kwlLkz8UQU1OFsMO2Pg8mUU9RU0BxfwM6Bf6o5Hh+CdBcNVfXxE6en9KgxP9Ig
P46LyGTl3DKPnz5y0DThbPRZhiBVAXpdKVMo75532zhXlOuwc7ugUdIqbfwyIy1AN8c2c3vZuOiJ
R565Wv24TENK3aee7ktgfsKqwEkw6p4I1cl2DrnfLKz0W1ZCfUuLB2hcLSfQdcu4ytwpLAdGkgk4
qRR4Coub5TvmjzytXHrHhAUrN4yCisqcvOMjnSaJgOKliO7cEvCVMyekrIxP+vEJaVEx0qpnoXIb
RNphDxaFN+qod+Sx9YuYLFI7cxK0G6fvzO/YtgcG9yYHjaxbFTWRhINNHQuHSc0kYwx6U06/8Fca
4hz4BQZl6Sd3mTZHRS9Nbzxd/Gj5OLswnJXxBN6d+CRxvdx3YRajMygKJ35cOFRO/thVSwiA1HDQ
qqg3N9rxbHqC68HiE/aO8wbjw4L3HfA9touzLEdLx3ZR/RkbSYtJSqI3Hg8K5vvojefN06nZNOPu
YfSKk4Lj20a1YCx5oN2JGLpuOio1Lt1QEkkdUCINcdkKJ8Yjc1849zhG/F5z6ne9e+9QqhQT0zqi
7o71bvW7Ichk8QZKRo37TKiLnhZJwAGX52iXxA6cjIjes0pzQhVv5SZZyLS91S/VBsxOLg1H0pAF
3dGI+tNLLEAwAq/J9tiOhrDGtp+mBXWPBHWP5HJ7//JAHa0+2tg53Dz8WQXKC+jjNeyTtvK+Cer0
f69xLMJ845t2XQshT+8xPRrN7XMTI+WJNsueQFshphBg7MHgrgzaQQNjAPb9v1l5b3w2QAlj+Z2H
98sFGE5a3SwO4xNp5UTHZ5xIiOAfQ15MXNWV3tc1dYVdWVMkfYTBMMVgia6mssPUdIipfs5pYmom
vvT6+lcQo8ndWOOdxRWEBt1UWGiBjizQtIDlrRcLWcfIpFBxeEe6ARMxBFZyr4l5bugTQfKQVKTr
XyubzRdOUagcInQzqHRcwFFOaAdEseU58Ws2Oh9FF6MTo5WIfBqfBPECBJ/rtOkL6TMAJSTl49yE
Y8Hftv0OEC8jdNCrL941TebouPTbGkZijfczUnBCORyOlxxQblovFPqkKJ1A1zo5UTC5n5zgbqyT
E0/mZBUQPCWe8J8ePr/vB2fhzsNJ/3REVPh3tP8vtv/CAvwiY/9dern0YP/9Qz7PnlVPTsaXnaBz
RluyQD+f+fSz4J/2p4Vn/rBb2Npc29g52MizElf6I4LeYBASVT172Kv/P372N5rr2xu0zr9jH7f4
f16/gm8w7f9bebHysP//iM9jlbOvC4WmugjbaoyYfBhF9NkZdRnNJurZMxMQyiLNs2e+0rnDJSAa
QQ9SIohVKxPC2yqb6NPpWcAHEkOFeyTLBX345AKPqR81Is2mzNmAdCh2IKW5Hrf/NKax6Cw/djD6
It3YV5tThSSHahRNlQnPlnE19zbLhV24qfgsk/qB7dJqbRDNujjMA8UOxmJO6M9HryQt0QWOSMU2
Izq7mwoF6mcyG8WYbaDOgkk3JOlKrTNfVfo8dTiheWti2eW2hsEogD2lfclHnCBvVUxhmvcwHM0q
3Un/cziyFSeFYus2KtwiSas9o9e4PQADjRFjSQoclR/xggjDr7SDODQ1UY8HFZM61TmrdIP4rB3R
TGh2d3fmFR4d6WuTEV5/XKSO4qo9UjU6pRIVu2A+rdTHMQdcz6GILHqfbx169kwb0Kk8o0bfJJnC
0j17xkYretfHrX+qmL2JRAWTEJEcInWXfNVU8SgYx2fRNBuCw4PD4SsMrak4cT7jPnI+acS5+Yzc
mXsvYJmRz1zKKSfnYKdPTs6VVSoNTImnrVNNFtlnJOHcNLF29KUs1zoBGcuITCGEknDtspPxsWxT
XXe4M+OgKZvbzQgCe8k9TnyNBeZphgrtAxPqnAFVRE+gLkVRwG3JE8Ile/fTTB8Y6wrs3s0G54Cd
3LUsOaVp1PA8VMQuVU5WJhk9Zo1V5mDgQAJmeRtPojhOhVPpeEuaV8u9NLCVxOUyOGmSPB6TkApj
MsnFYC4ggpAkBS3OnTsZIjzVKKzlpCR7ug3dWS6/Wlqq2FsZ5eLGsoTfcWZMvkZOMmTxXR9ZxNTo
xpQNs6VpRpNsxHZcNhcwxBIpfYmjKDqGXy4VEdqomzvQqM1TBirHfIsOIuzrBNp5zNeGekFxQZ2y
bhLH3CUwEAvEDhtZK8IKqsfnYPl9NwlzIxwQQw91L+fgiYA8fqw2hcwUCq1WiwTFeNaNlF+9jZS5
3qzHBAgqBoh+Dpk41mnXRBGR9eWSej8j8OmqhccA5GwEijcCmSh25dwpDmiCU3y39N2rMtGQUwLt
06A77I+eCloE6hTRYxxROybVF9uYVO27jrZiftK3yzDGXAuFQ4KKLVUrFJZ9tcb3BTK8dg9U8WOb
NPxZdT1s9wNCt2DYff2yGkyGr18KQdC1YzXsxzGwivbfJPxl1o/7jEYrvgFvbHjO2oZ6TohIyxmH
VTCD7hc1Hsxowjok0Zx10cofDFU4YKWr921ffuEFjZfPzsR6gYUBafRs0TrHl7QnhyZ0kPZoxKDl
PXQWDUGeoqlBY+lPcRJ8IkWHnNhCM0jLRIkCF1766gDIpQkqySIfN+2ioDVCwmfPwhGfzw0RsUsr
TKMptmQ83UqHMDMmaeNwb7vShldL7qtWwWcaP/JW8LbcHYejg4Mt2B40DkyiaFphvn8eXuoxJh2D
yMhJMpxQ5phvWaVYU2GICIR4iPKWtB28ClpUeEXQJF6pZxUO22EXGIowD53OnKq1cB4gD92q8aTT
Eu7elRb6Qw4ElNBz3Z+GJmbEIksAKgA+hr/iLZUbk/zCawd1NDkJIFK1qrN4Uh0gT3c1bvdHeYOh
pQeFF38VOEvMQhuir7GQ6L7FOyevLlEFAF61dHzJ6lkUTxs17MyqFkT6p5B7mHw8Vu/Csz49ZOkT
Z8knMdhQ9OWSNlikxrM2CRxnVl6DQAIhBfDgUvqG3hTq+h3wQFz8eRqG57E/CqctQQFGOAJxB3eM
ohTRAJdw5UVLVSq4uuzd5s76SXN9fX/j4EAtr3zrL9H/lm+qhfNBl0IpfgxDueaTBLN+pwLXrSZS
JA7g/DwRXYZCIJOquZdQsWAMyASDWMAkXG02CEVyDUwiTSHIn6LJeW8QXTBBEn6CJGfEQX5bmk7a
gSgzRaywSdOZcDkmVp9kL8ubVIpObF84YA03AVLUFmMRCK5U/6dqVoIsMeViYQ6kxAwBY9K93NSs
1jdSzVZG4YVp+hX2jYCtTG1nTs3Z4G9IldglU2QlzVFUAALNw/RShhosQnIdBQvbyYgeetLPaEnj
Z6YMaytCgbS8LLIM71F7Tx+TYBntKfFR2bKuTFLYiegvAd2muWvJnsLd10JGLCYRMCGMXiY36Jqj
gjTI98llugZ7IHvLGRhocAUjcoZf+EJKc8qwH+u70LrJ9WdCaPR5sa5uBFHhMY4lsNqVXJo2G/FF
8JiZlin704J79ZrsgG0SIXhbF3B+jJrhT0aWUFVqgwP8T2fEOvizUkpy2RY1qzP8oZzQ31JBic+H
q70oKbk6Wyli6/sh03DwSsWGtxI9f1XiO3On9PU1vkYY0rcozOQ9FeHzHZfFWW71fUltRTSU7Od9
Se9UxisaqkabqtGm9TYjeGOf0XC3adxTnyu/K+mb3ZTalxFADlQfS+rjyIBGHZbUYXQKvbk7uawQ
zVfqALAhPZajQ5FK+T/PCPhM3gjka1ubhcJX4oDDIYjHV/WJ9TmtpX8tfK1UKvwfFWol0tQRi1PH
LVTo/xlEGfvXCHUkrDPvL2vppWwkEc0oNXdUulEmuC2CAn2fyDKg4f2wIoerhPmgRj1VJJB7BCvj
GZilJtOaASdKBdbS9MSNtORbNG5Ja+5DrB9/HWD9jnZ4hlv9Xti5JGnbNkNoXhEU1MMGp/lx42f1
U3Pr4wbq/IRU31Wl7SeBI1ERnLC4ZguqIpMiC4aS6cTgL1oj5M6VuYq4nGg8ZakJBgtJ7IO77miX
lzSVcydpllHw7v3m1oY6Ym39WE9EI+LR7sdDmTuMAZGIUGGOVSDFGGj/h4QcuhN9qIZQhbVfku6O
7SIL8qJ/dPKB6mp5kIbpn/6ZJ4RZjs8mMIkkMmXLP+2F7eC8JSYn3RJueeRUBDwK3f8kJGFRI5Ju
gEfKqJmIFZaUdOVYFXaBNDAz+0oa4ZNEyTqyhMmoxoGAJJmOpy6hG89wL2ufcJaGwavV+rizuXNw
2NzaSlY5NltTg4aQwH321QiD1KGO/CachjhcovJJPDgNtN8VliWGJhmZWQnsF2D3qEv6H6EIra7M
yShXos+mzF2JiiSLHIiECmVXN6tJDIm/LSYH8kULzeub+/Jbn8XC9vi0u7+OfnfHcjXnVyZBhnIT
5b9JlnP3HGxZsdaQCbqymCJLDwCSL1PREeCw5BPzNRA5pKz8qnTGI/q2HQawRbhUzlA6V2rklfmw
e3B4sre7z3BrLbEUucRvICAzHWRNxtmlRMW1FBxqlLJR6dwIq7ktVbxgAkoYQfTdSpmzOJzUFYdn
KQSnCn3TsmevJ+0hUv4EgEZzCzUUYCeXcGM8WqSN9kcV1nKMgUIafddc+/HjnjRbtT9/3NjYk24+
BxMbOpKnR6DS8lIadc05SoHC3t5JttVXukJmQLyn9KgONk42t5s/MMFoycmH2gt/+UUlHvSHRD2i
c9pkQ7zdIxi1CWzBKchI62/js2Dl1etaS3X7p6GhD9sb2ydbm9ubsqD0nquu2e09pP1O2NUJxlL+
YGNtf+PwgEe+sbMuKzibRvwlrd+qIum3Je4buaPieNBKgfb97v52U/oFvZIJaRLZIpw9J3pm6Wcr
nw7S/LoGkYWR25GLtZsQWywdHedFzBJb0BVdGmREJBExF2hle/m12n5HCz0dUuf0T0+b7Tk/F5g/
wSRo9wd9mCvL4GNxoTWKIIxXxpP+5z5ul49FZTTmA75DNxpVuEtYKvudMBEKuGMekoPS4DiAiOxk
mPaxoQJSM7sFrtDqctRRVxwYF2f9zpnie+eIMnD4V8WGf2mPBcztwaAib8XoS1qmNnmzWRpzG4sd
YXmJwCByKTJHxaAgewH1K1iChL1Z+agaTju5WzDnGZK69lIoV3XFAiL0S69xTdHNDcchodwUh186
aGsjbXsh2pIWGExzNxgzqmjnHYvCHK3+hVoRKQ6YUgbPqd7WjPZmaDuLfzlkDvqDMeQh7QdrGch+
yS2tmmVvVFNEqpx6ZagOQy11DTugVl5Az5hgEeHMHanlcZVnPpVJUy2IzywHFleWmBSV9F5rDhiT
pqyu4aA18V7a+eJK4W46U9Zph+2JhhA9KNWMYlgJ4gqil6Bh/R3Nc4TR4xgzLZxrKLGOMV+9A+Hq
91iyuAhGUD2MTkuNnPbF4gUM7vU5byCpa2zuTvvRxL8mhwF4V4MmkESh8USbkp/KEWXY80KT24Y2
oJ/Mz0T6icNsgrlOOsPu6Jwm2RFdgo/qsxXhX/715yZtXwKUjrN0Gqq0YZsLoJI/e/aPJD5hg4+q
7F159qxmrb+sTLJ/T2SR/RlRwPWDLVDZw13t96sDapd6Boxdobla3aAVr98WUZ9RHBYKRP7/I0ZI
rH1o7vywsbX7w+8YAnBL/M/rFbxL+/9fPZz//KP8/3KnPXIWF5rEcUeR5IkXdTKGd/ECBEGcpOrw
IhKj9oi5EqiA3mm0ceOQmCbtoMFlTQiUpXnYX62Dtf3NvcOTnzb2DzZ3d1qgJrf7s7kdorXcgnOg
R6qDRciZZcuX+7Fo69ZADumsUPhJKsKINRhEFySVNf9ud9/f3tyhf/eah2sfWrJjE13k8zIkb638
8I9lTpO1srTyurK8XFl+xT9ZEDCOOHNBICeeE6+i2LCb1AY3wRN63/9SI0qmVWCiiqQrnWr3QRhb
epuOdchYEI3Tsua6Kx3fJmu25gcRcXZgsuNSWccliSS7iD6Ax1fzt2HQNexAYq2dZHzsxjDRHiOC
ImwbYgsWPYkjQNqQ9y6ox9Fs2A612xDcpGOpfCqvHrw2ThQvQhgwckm1h7qnkfGn5KXXg3UUcpvx
U8MCykthGErVJEWTaFqwBJTXrfA8JMbjbnc9on7GiQ4EcX3oIt+hNwh4ceIJFry85PfGYUQrT+Jo
bxCcalf68jLHwRot/IIa+L50O3Iu5SGnZG2bhEimGwomJlIH16IOD+4SfGIDSli3n3RtUEkxP6KE
hpYNJ+HAZQMvrbzTdk0cYbFR/ePZcMhu2EtIB4JBOdaFFs3MsG34sLLmA1mqsDfon55Ndcs3uVzL
MOudqZf+y+clxzmW63otw6fq+lyNmYejAMTth2GnHbAY0b6jqaT9qTd5U+/mRIU9V4cg1RL9C956
UofKczoVq1pjrHmOWiVgD4x+yjEOdvOIFOc4q1wnKSvT4qUNs3pCRoOtkgLreGKN09s6WSUPy0Ti
se7kZlUfE+e/9Z5b4S5IBsq23jParTIta9bHmdqBLCcTJM7fV8taY8vzxlgDMKtYYSOhabY6stls
kUVUI3jaJhqc4ioOMSWShsDUirZOHTJ3F6ol3H0ck4NIfRLoI+DebDKwhll0rmMyamyxnLd9BsoY
BByLZ7JqWlNPLAOq2Nw4qKy8el1Ze7dWVnvvflx/v1I5+NCkR4iAIQmujMvTwXcYcsjDKo2QrN7v
QZjAbKkGWrH7nR1EdijaousYXZF5kvZ3SPsTE8HM1rXjYchnOXDSuWuuwpCe2WPVpTYmM4kcsYR4
XuFCTAjxcfHUVxJHRk2tvNKD9HPMpmx20DSNmLRDuPMNpX5aHAD51Xxd2M283buoPXpYLEaXcuLR
y4YVIRk52y3UnN0Ck9oQEyf78YgSpILaAif+LK4rfRRFjRNOd0P016+I+WrPBufaZ6cddUVxpEhS
vQ5Cu+gFB3OZUK5aWr5ZGKaVSDlxOT8kKy8eK3ES58Viue5NAAYaoo7IKoI7DMIKkg4w0ZpO+u0Z
lgPNNnUIlmYYic3ARF8FkFpvD76SR7w7rCvk4yZ6ECN3MFAfDg/3hCYrpsnFViqHSaua/N5rHhy0
OKkgn6dTYGyCtj3aZ7AJg9qCvhlRLaGc6PN7B9VrDAw+O17B2XEJ0pSz42XBWVp63GVbnreXiWjF
i6g3PY4bKnvc0H84WPA7fvTpjt+1j1v0/5XlpeWM/v/62xcP+v8f8tnePExsVGvR+HLConKxU2JN
4g5R33vhhOVjhGvEHMtP+t/pJIDuUwbD5vtfQItPJS0snKfEUmJcjtSG2CrGQ9xwVaCSHJMQR73p
RaDpH1GdqNPnmBCT8juQPM0S2sCK4YGugVOZ1Ek3DAYFLTCbV5aSgZJO+proSNQwxmBes6ArPbDk
BYjEBWqUqGKZx8nJXfq9y7JhyNr7VuZLZIX4c2D4QEDLHK8qTGVQ6EgMIM81GZ1wReplDIBONYhi
PCHle5ieST8u9GbEE9nhh+lGBDIbim7EYjF1YGrEA7ucfh3uScjvfBUyz0UWnPQL9pNgCFiAcbKq
+lV8BsbYDm2YNQv4znQm6B66GeRSluRYBMtMk+Sfww8b6mD3/eGn5v6G2jxQe/u7P22ub6wrr3lA
v72y+rR5+IFEYEUl9ps7hz+r3fequfOz+nFzZ72sNv5+j0PsdvcLm9t7W5sb9GxzZ23r4/rmzg/q
HdXb2SWshseNGj3cVehQN7W5cYDGtjf2Yfk8bL7b3No8/LlceL95uIM23+/ukxi619w/3Fz7uNXc
V3sf9/d2Dzao+3Vqdmdz5/0+9bKxvbFzSBriDj1TGz/RD8izW1voqgD+uruP8am13b2f9zd/+HCo
PuxurW/Qw3cbNLLmO5L9uSua1NpWc3O7rNabcDlyrV1qZb+AYjI69enDBh6hvyb9f+1wc3cH01jb
3Tncp59lmuX+oa36afNgo6ya+5sHAMj7/d3tcgHgpBq73AjV29mQVgBqlVoRKoLfJDDYBtX6RnOL
2jpAZUzRFH5gzg+fh8/D5+Hz8Hn4PHwePg+fh8/D5+Hz8Hn4PHwePg+fh8/D5+Hz8Hn4/Af8/D+1
wftdABgBAA==
__GFE_PAYLOAD_END__
