#!/usr/bin/env bash
# =============================================================================
#  switch-dashboard-installer.sh
#  Installer and lifecycle manager for the HP 1810-8G / Netgear GS110TP port dashboard (Docker)
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

readonly SCRIPT_VERSION="1.4.1"
readonly SCRIPT_NAME="switch-dashboard-installer"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

# -----------------------------------------------------------------------------
# PATHS (overridable via environment for testing; normal use leaves these alone)
# -----------------------------------------------------------------------------
HD_CONF_DIR="${HD_CONF_DIR:-/etc/hp1810-dashboard}"
HD_STATE_DIR="${HD_STATE_DIR:-/var/lib/switch-dashboard-installer}"
HD_LOG_DIR="${HD_LOG_DIR:-/var/log/hp1810-dashboard}"
HD_INSTALL_BIN="${HD_INSTALL_BIN:-/usr/local/sbin/hp1810-dashboard}"
HD_LOCK_FILE="${HD_LOCK_FILE:-/run/switch-dashboard-installer.lock}"

CONF_FILE="$HD_CONF_DIR/hp1810-dashboard.conf"
SECRETS_FILE="$HD_CONF_DIR/secrets.enc"
KEY_FILE="$HD_CONF_DIR/.secrets.key"
LOG_KEEP=20

readonly PROJECT_NAME="hp1810-dashboard"
readonly CONTAINER_PORT=8810
readonly PAYLOAD_MARK="__HP1810_PAYLOAD__"
readonly PAYLOAD_END="__HP1810_PAYLOAD_END__"   # payload sits in a never-executed heredoc (shellcheck-clean)
# Pinned defaults. Override with --set BASE_IMAGE ... / --set CRYPTOGRAPHY_VERSION ...
readonly DEFAULT_BASE_IMAGE="python:3.13-slim-bookworm"
readonly DEFAULT_CRYPTOGRAPHY_VERSION="50.0.2"

# -----------------------------------------------------------------------------
# CONFIG MODEL (host/container settings -> $CONF_FILE). App settings (switches,
# users, poll interval...) live in the container's data volume; see app_ctl.
# -----------------------------------------------------------------------------
CONF_KEYS=( INSTALL_DIR DATA_DIR BACKUP_DIR BACKUP_KEEP BIND_ADDRESS HOST_PORT CONTAINER_NAME IMAGE_NAME
            BASE_IMAGE CRYPTOGRAPHY_VERSION BUILD_NETWORK TIMEZONE SERVICE_USER SERVICE_UID SERVICE_GID
            RESTART_POLICY MEM_LIMIT LOG_MAX_SIZE LOG_MAX_FILE SECRETS_BACKEND )
declare -A CFG=()
declare -A CONF_HELP=(
    [INSTALL_DIR]="Build context + compose file location"
    [DATA_DIR]="Persistent data volume (config.json, audit log); owned by the service account"
    [BACKUP_DIR]="Where --backup writes archives"
    [BACKUP_KEEP]="Backup archives to keep (oldest pruned)"
    [BIND_ADDRESS]="Host address to publish on (0.0.0.0 = all, or one IP; 127.0.0.1 behind a proxy)"
    [HOST_PORT]="Host TCP port for the web UI"
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
WIZ_TLS_MODE="" WIZ_TLS_CERT="" WIZ_TLS_KEY=""
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

host_short() { local h; h=$(hostname -s 2>/dev/null || hostname); [[ "$h" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] && printf '%s' "$h" || printf 'hp1810-dashboard'; }

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
        [INSTALL_DIR]="/opt/hp1810-dashboard"
        [DATA_DIR]="/opt/hp1810-dashboard/data"
        [BACKUP_DIR]="/var/backups/hp1810-dashboard"
        [BACKUP_KEEP]="10"
        [BIND_ADDRESS]="0.0.0.0"
        [HOST_PORT]="8810"
        [CONTAINER_NAME]="hp1810-dashboard"
        [IMAGE_NAME]="hp1810-dashboard"
        [BASE_IMAGE]="$DEFAULT_BASE_IMAGE"
        [CRYPTOGRAPHY_VERSION]="$DEFAULT_CRYPTOGRAPHY_VERSION"
        [BUILD_NETWORK]="default"
        [TIMEZONE]="$(detect_timezone)"
        [SERVICE_USER]="hp1810dash"
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
        printf '# hp1810-dashboard-secrets v1 backend=%s\n' "$backend"
        case "$backend" in
            systemd-creds) systemd-creds encrypt --name=hp1810-dashboard-secrets - - ;;
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
    [[ "$hdr" == "# hp1810-dashboard-secrets v1 backend="* ]] || return 1
    backend=${hdr##*backend=}
    case "$backend" in
        systemd-creds) tail -n +2 "$SECRETS_FILE" | systemd-creds decrypt --name=hp1810-dashboard-secrets - - ;;
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
                                          --shell /usr/sbin/nologin --comment "HP 1810 dashboard service account")
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
is_source_dir() { [[ -f "$1/Dockerfile" && -f "$1/app/hp1810dash.py" && -d "$1/app/web" ]]; }

# Embedded source: the end of this file holds "__HP1810_PAYLOAD__ app=X sha256=Y" followed by a
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
        is_source_dir "$SOURCE_OVERRIDE" || die "--source $SOURCE_OVERRIDE has no Dockerfile + app/hp1810dash.py"
        SRC_DIR=$(readlink -f "$SOURCE_OVERRIDE"); SRC_KIND="--source"; return 0
    fi
    if is_source_dir "$SCRIPT_DIR"; then SRC_DIR=$SCRIPT_DIR; SRC_KIND="checkout"; return 0; fi
    if has_payload; then
        PAYLOAD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/hp1810-src.XXXXXX")
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

app_version_of() { sed -n 's/^__version__ = "\([0-9][0-9.]*\)".*/\1/p' "$1/app/hp1810dash.py" | head -n1; }

sync_source() {
    log_step "Build context"
    local src dst=${CFG[INSTALL_DIR]}/src
    init_source; src=$SRC_DIR
    APP_VERSION=$(app_version_of "$src")
    [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Cannot read __version__ from $src/app/hp1810dash.py"
    if [[ "$src" == "$(readlink -f "$dst" 2>/dev/null || true)" ]]; then
        log_ok "Using installed source $dst (app v$APP_VERSION)"
        return 0
    fi
    run mkdir -p "$dst"
    run rm -rf "$dst/app.new"
    run cp -a "$src/app" "$dst/app.new"
    run find "$dst/app.new" -name __pycache__ -type d -prune -exec rm -rf {} +
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
      HP1810_SELF_RESTART: "$([[ "${CFG[RESTART_POLICY]}" == no ]] && echo 0 || echo 1)"
      HP1810_SECRET_KEY: "\${HP1810_SECRET_KEY:?start the dashboard with $SCRIPT_NAME (it injects the secret key)}"
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
    HP1810_SECRET_KEY="${SECRETS[APP_SECRET_KEY]}" docker compose "${g[@]}" "$@"
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

# app_ctl ARGS...  -- run 'hp1810dash ctl' against the data volume (stdin passed through)
app_ctl() {
    (( DRY_RUN )) && { run hp1810dash ctl "$@"; return 0; }
    # Attach the terminal only when ctl will prompt (--password-prompt); pass stdin only when it is piped
    # (e.g. --password-stdin). Otherwise leave it alone so type-ahead stays with this script.
    local -a xt=() rt=(-T)
    if in_list --password-prompt "$@" && [[ -t 0 && -t 1 ]]; then xt=(-it); rt=()
    elif [[ ! -t 0 ]]; then xt=(-i); fi
    if is_running; then
        docker exec "${xt[@]}" -e HP1810_ACTOR="installer:$REAL_USER" "${CFG[CONTAINER_NAME]}" hp1810dash ctl "$@"
    else
        docker image inspect "$(image_ref)" >/dev/null 2>&1 || die "Image $(image_ref) not built yet (run --apply)."
        if [[ ${#xt[@]} -eq 0 ]]; then
            COMPOSE_QUIET=1 compose_run run --rm --no-deps "${rt[@]}" -e HP1810_ACTOR="installer:$REAL_USER" app ctl "$@" </dev/null
        else
            COMPOSE_QUIET=1 compose_run run --rm --no-deps "${rt[@]}" -e HP1810_ACTOR="installer:$REAL_USER" app ctl "$@"
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
    WIZ_TLS_MODE=""
}

menu_https() {
    require_installed
    while :; do
        printf '\n  %sHTTPS%s\n' "$B" "$NC"
        app_ctl tls-info | sed 's/^/    /' || true
        printf '\n   1) Use self-signed   2) Import certificate files   3) Turn HTTPS off\n'
        printf '   4) Set extra names/IPs for self-signed   5) Regenerate self-signed   0) Back\n'
        local ch c k n; read -rp "  Choice: " ch || return 0
        case "$ch" in
            1) menu_action app_ctl set general.tls_mode self-signed && menu_action tls_apply_restart ;;
            2) ask c "Certificate / full chain PEM path" ""; ask k "Private key PEM path" ""
               [[ -n "$c" && -n "$k" ]] && menu_action tls_import "$c" "$k" && menu_action tls_apply_restart ;;
            3) confirm "Serve plain HTTP? (only behind a TLS reverse proxy)" n && menu_action app_ctl set general.tls_mode off && menu_action tls_apply_restart ;;
            4) ask n "Names/IPs (comma list; detected: $(host_tls_names))" "$(host_tls_names)"
               menu_action app_ctl set general.tls_san "$n" && menu_action tls_apply_restart ;;
            5) menu_action app_ctl tls-regen && menu_action tls_apply_restart ;;
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
                --label "net.certifiedgeeks.hp1810-dashboard.installer=$SCRIPT_VERSION")
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
    local out; out="${CFG[BACKUP_DIR]}/hp1810-dashboard-$(date +%Y%m%d-%H%M%S).tar.gz"
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
        < <(ls -1t "${CFG[BACKUP_DIR]}"/hp1810-dashboard-*.tar.gz 2>/dev/null | tail -n +$(( CFG[BACKUP_KEEP] + 1 )))
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
    log_step "Install / reconfigure HP 1810 dashboard"
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
# APP SETTINGS MENUS (wrap 'hp1810dash ctl')
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
    st "safe_path accepts /opt/hp1810-dashboard/data" 'safe_path /opt/hp1810-dashboard/data && safe_path /srv/hp1810'
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
        [[ "$out" != *TOPSECRETVALUE* && "$out" == *"\${HP1810_SECRET_KEY:?"* ]] )'
    st "compose: hardening + mapping"      '(
        set_default_config; PUID=990; PGID=991; APP_VERSION=2.0.0; resolve_ids() { :; }
        CFG[BIND_ADDRESS]=fd00::5; CFG[HOST_PORT]=9000; out=$(render_compose)
        [[ "$out" == *"read_only: true"* && "$out" == *"cap_drop: [\"ALL\"]"* && "$out" == *"no-new-privileges:true"* &&
           "$out" == *"\"[fd00::5]:9000:8810\""* && "$out" == *"user: \"990:991\""* && "$out" == *"pull_policy: never"* &&
           "$out" == *"image: \"hp1810-dashboard:2.0.0\""* && "$out" != *"build:"* ]] )'
    st "compose: hostname + self-restart"  '(
        set_default_config; PUID=1; PGID=1; APP_VERSION=2.1.0; resolve_ids() { :; }; host_short() { echo gold; }
        out=$(render_compose); [[ "$out" == *"hostname: \"gold\""* && "$out" == *"HP1810_SELF_RESTART: \"1\""* ]] &&
        CFG[RESTART_POLICY]=no && [[ "$(render_compose)" == *"HP1810_SELF_RESTART: \"0\""* ]] )'
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
        [[ "$out" == *"-t hp1810-dashboard:2.0.0 "* && "$out" == *"BASE_IMAGE=python:3.13-slim-bookworm "* &&
           "$out" == *"CRYPTOGRAPHY_VERSION=50.0.2 "* && "$out" == *"--network host "* && "$out" == *"--no-cache --pull "* ]] &&
        CFG[BUILD_NETWORK]=default && [[ "$(build_cmd | tr "\n" " ")" != *--network* ]] )'
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        st "compose: docker compose config -q" '(
            set_default_config; PUID=990; PGID=990; APP_VERSION=2.0.0; resolve_ids() { :; }
            CFG[INSTALL_DIR]="$t/inst"; mkdir -p "$t/inst/src"; render_compose >"$t/dc.yml"
            HP1810_SECRET_KEY=x docker compose -f "$t/dc.yml" -p hdtest config -q )'
        st "compose: refuses to start w/o key" '(
            set_default_config; PUID=990; PGID=990; APP_VERSION=2.0.0; resolve_ids() { :; }
            CFG[INSTALL_DIR]="$t/inst"; mkdir -p "$t/inst/src"; render_compose >"$t/dc.yml"
            ! env -u HP1810_SECRET_KEY docker compose -f "$t/dc.yml" -p hdtest config -q )'
    fi
    st "secrets round-trip (openssl)"      '(
        HD_CONF_DIR="$t/conf"; SECRETS_FILE="$t/conf/secrets.enc"; KEY_FILE="$t/conf/.k"; CFG[SECRETS_BACKEND]=openssl
        DRY_RUN=0; LOG_FILE=""
        SECRETS=([APP_SECRET_KEY]="k3y'"'"'w\"rd \$x\\y")
        save_secrets && SECRETS=() && SECRETS_LOADED=0 && load_secrets &&
        [[ "${SECRETS[APP_SECRET_KEY]}" == "k3y'"'"'w\"rd \$x\\y" ]] &&
        ! grep -q k3y "$SECRETS_FILE" && [[ $(stat -c %a "$SECRETS_FILE") == 600 ]] )'
    if [[ "$(secrets_backend_resolve)" == systemd-creds && $EUID -eq 0 ]]; then
        st "systemd-creds encrypt/decrypt"  '[[ "$(printf hello | systemd-creds encrypt --name=hp1810-selftest - - | systemd-creds decrypt --name=hp1810-selftest - -)" == hello ]]'
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
    run docker run --rm --read-only --tmpfs /tmp --network none -e HP1810_SECRET_KEY=selftest \
        --entrypoint python3 "$(image_ref)" /app/hp1810dash.py selftest
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
    printf '  %s|%s  %sHP 1810 Dashboard%s v%-8s  host: %-23s%s|%s\n' "$C" "$NC" "$B" "$NC" "$SCRIPT_VERSION" "$(hostname -s | cut -c1-23)" "$C" "$NC"
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
            r) ls -1t "${CFG[BACKUP_DIR]}"/hp1810-dashboard-*.tar.gz 2>/dev/null | head -n 5 | sed 's/^/    /'
               ask f "Archive to restore" "$(ls -1t "${CFG[BACKUP_DIR]}"/hp1810-dashboard-*.tar.gz 2>/dev/null | head -n1)"
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
$SCRIPT_NAME v$SCRIPT_VERSION -- HP 1810-8G port dashboard installer and lifecycle manager

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
  --ctl ARGS...          Run 'hp1810dash ctl ARGS' in the container (switches, users, app settings);
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
        restore)     do_restore "$arg1" ;;
        rekey)       secrets_rekey ;;
        uninstall)   uninstall_stack ;;
        appselftest) app_self_test ;;
    esac
    _log_file INFO "Finished action=$action"
}

main "$@"
exit $?
: <<'__HP1810_PAYLOAD_END__'
__HP1810_PAYLOAD__ app=2.3.1 sha256=1656694625edfac3e1a8cf424316ec2a6b7fbff2083c41a5324fe353e5df4de3
H4sIAAAAAAACA+w7a3faSJb5zK+oVl7SBGTAj2ToJhlsyzanbeAASTrreDVCKkCNkBhJ2Gay/u97
763SCzBJn0n6nNkduk8i1eO+675KOQ3sGQ/Hrsef/LBfFX5HBwf0N/zW/94/OKw/qb6u7u/XD2pH
NP769f7hE1Z98if8llFshYw9+X/6e8qa3/NXesrYdFF7U6tWHCuajgIrdJgd+LHl+jxk7tyacFxz
vHS9mI1WG4srrg8K8Twe6tGUqUHYYA6ZKBvBFodV4k34ulZ6SkBbA8NsX7XODWb5Djvpf+oNu+f9
Vu/ik/nB6A/a3Q6zQs4Wru9zh005POPC4JaHoetYI4+zOzeeIqxKhfBVrHDC1HjKWUoXW1hRxCPm
xlEe4952fBGPY9efRJqOUM+CkFlsvPS8FQv5Igycpe0iWkJWRsryMEE+jjvhUVxmXJ8QBMYWq3ga
+I19vbZfiTx3XhkFwewuCOd/i6ZW/fCo8YvY87b0vXXb6p/nqGs+SkjprN+9Ys++ZGsfSrR5m4Sa
h1W9qtdpvtXrpcN1GK2WSpetY+OSBeFEDxbcTy0p0smU9NiNPd5U1k1CYZ9LjH6P7nR4ZIfuInYD
v6mcBH4UeGACMdjFIghjllnXGHR20WOE4M05i8BC7CmPvgEFmFVE4J99yXH28A07rSWINoyais/j
CeezmlIqGZ0PrPdpeNHtnHY7w4/99tA4/jQ0TrqnRrMmQYr5953j92dnRt84zSbaPbPTNU9aJxeG
edruFyZO24PW8aVh4rMk0oR1J7+mqy56yL552hq2mnsgJas43uv2h8038FQq9d93pIXus8ocDHqR
nBym2OFqEQeT0FpMV83msy/bzEFI58WLDIjNFHdOOsnv18c8BOGAXE66vU/MWiz22B7+KUiwp/MA
nEWfWa/C32giARu6fjxmL5/+tDdy/b1o+tnn99xO0REMYU5oAvpixZRnf1M++y/ZW7a3jMI9L7At
jzZnyyRwgfX14eFXV85njhuyyoKl0qTtwZ3PahASaw36c22WgFerhdEddFcq0gBL4Ak6gV8Jg4B8
rsPH1tKLf2ZFvxYuffRqzBK+DWmJeHjr2uAlbTtY+jEt5pajl94PjH6e0tLHbv9XsCuio2T81usO
DEYW8aF7+f7KYNcKUa3clEoXRutyeEEGBjSCOgCJ5TX3qxG8xu6cB8u4eYQvGJrjyoKHbuA06zQf
8jh0edTcJws8uToFyFIGSpkpm2LA0Sm3vHiKuI3OEIyu2+4Mv7rvpiSgoww4vP3fjP/I94/GgUke
HIrH8j/xXMj/jg5rr5+ww//kf3+K/gt2/2fn/wf7h/XD10X916pHr+v/yf//lPz/JwpVGKS4f5uE
k9IPKwukleHAH0i61Ds+Yu/bGqXrHcyJQGfng1qtOuwxddC56mlpYiZqgQ8i9EGO0mCmKQOhabIR
94I75kYU+0Sa5cZW7N5yJhexCCKMPyEKp5Y/gQ0TAHJy0eqcG5fdc33u4NxpYEcii2uwvtE6vTLk
RIuAiokkfWPqiWctHUjsXFmrvI8gz5Pbi2Gb4g1b/0FwJpJREKmYREGQ/YqA7NiDgDnl3iK/Zm75
iDmpS6BuSQQHj0tAHrFxGMwJ2cllezcKEVjXac3qPTkPhc6I74YUcW8cQ9VSXINlUQwpAsOpiKlL
LLwsNoeKUJItxTmgF0QUB3bgMdXhduCAXaW89C71ul6rMmlJDUEO6NZFIzk3hoztAeFjd7JHg+8c
jqmP6zRHVsSPDlTFcuau3/gFyz+ocpy3isbYK2Z7LvfjCuRuEceEyXX2gEioh7DuDWYuGiRiAjcT
L6ME03KBZr+Hg3to+vjAt41nY5K4aBW5/jgQQMXYGlC5kLa/wz+bnRcR8FGpiU3EB6b+3cFw6yaq
Mmnf9Qta3Az8mxfRgnOn+Yu9DENg+G0BJEgMkrYEZCZGGkx+8WrBm7UXKB3Y+ouU0lsG9TXOVNEU
QXxUjrNpHC80AdyA9xX77aJPbNpWiAkgWIFyEoXjYTDjvoKG5sAu/o+l5bE4II0TIjjPqSZ0YSt9
WOWGAAKOXo/8HdvX//qqTJsKRYoCtb49w+OiokOyYkg/wUQjbkMayqBuw7WAQvvu/rIkSx4rnCys
MOLJu7DF5A0PGr+PPXeUjYBvlc9j24+95GXCYzTc5HUKxy63bTq37PQZJK8Lq06G3IXlOMB6uv33
CKoK+QxqnqC/lK9BuigEZx3M07eUByG+dFnkTnwrpTPCZk+KGCwkfVylO+JpCOrO4cSiIXlehh4w
phekdmeFPjq7EnkDkJo0Yn28jJdoCXLdkAD3gsAzoCZcxkEodpBIyC+HydJjUMTFcNhDYwKbuABe
oYYqSxCADCcHtKVUAtqBoHiqQ/3Ew1itlkFMYgTKQN+aczV5t0YR/q2aJvZkTVPTtFQC/nzhuegm
njI/+IfVYMZBtQ7HZ7RE5E4ZCrsF9x2wy1VlHHLOMDCy27otnZRWKuVDYZMpdX1fx94ChDV4lZrU
wVYu4ZGHqpI5aQV2Y/2P3QNYC/RCvuCGgY/LVSXXIaB6ioo9rXTZHgyNjtk6Pd2xSSzCbdgKgv+y
jdhZgI1QJKqPbMYVuBWLTQWE9dE43k0iLFAy+f8euL767coARBBAEM9Jt3PWPjcHUMdetQBbvdTv
XhoDeFKVW5ff8RCpCqB4tcCO8JlcKYrxR2RXRr/f7Q++vx+yPfAaMrwaYRiEqnFvc+H1GtQDUhSl
5a/Y2HI9OEsstrwZGBE6YUvGaB2WlIqgMEkS4HKgM4AfQWkTlkRa0FYoPLqI8iEfQyLg5J38FhTH
y2i1A8UggYVnC4C97HML3q+se3e+nLNLSgxOsOvxsgD8hIKbAPzB8pZ8DW7bv7VE8Md1S9A+xqBb
XIlsCIPIKP4BpjAwTvrGcNDIBSgIXYxC16tUqBQCRJ77Y0yGvPxxcJ9KxhDkRIkaE0rA/fpSXDoG
Fh2cKGczDhlsMOcyHZWHV/Bm/mp8WuvKE5IZ5wtqYQFAbGFJAYB2b7HhRdWD6//O7Vg0uuJcqkq9
Ju1nugDAtAXniQg8+lAwEIIJ91F9HMGQ+VEn7jbwlnMwRbT4EV4w/F1eWUDS/ncA7HoeA0ZnkdA5
tV37xln7N3TBQGPjttaQ4w4fQ7ni+m5smirmxGVCYYJnkiZGmVS4yl7wJ+LaZns0iVZn9FZm0jgp
aUoBcDrQrE1LyZqxBQijDYw0i9CazCHW+AEI61YKOq1KLDeCMLOKYj437l1wsqKATPOml3miXmLd
FYrsy4HsmagGPClIZFgH7sUJam4nN7TuHnfumX2gx1U0HYu5haoVUUTBMrS5kP6tks65Y+AS85a7
onQxBgiUWchItAJYdJHQ6GAsilbYWESGmwvTEl8Cl9+7UOSo+KwVCaC7gkifWzMOKKMcctpjBrPm
MFxybWPT2BF04yUDAabA1zU/9rudy0/sf8QbiKw1TF6M304uy6waHFWrm/DwcOCysUMQxw7GQ9Ak
2Mt4ukkzkTDV76DE5qpM+/QYtWlCmhZZY64evNE20WCVLXO2LZoloUH9+nPuOD6H4nAENofHdrkQ
dK6dTw0sgmRb2uQoE4+CoRpvZDCHayrLeFx58ziDwhaBRUz61E1rQ//RlEm7Llk2R0cHhICrMgvX
xcWdOsqlW3u39T0F3DVg0OXqhBhNFxd8qrZm1qY89E153lVAr2V+RXpD6VYWnuVS9ZCzNTDIdBg9
nNoJfE7nqMg66HEZ+jBeWhshMqRve1UgSk+wpwi2sMXFgBXZrqvkKIeJHOVkQEWq0SJo+Gt05tfq
5PIxGE3VHOHrvJKLy0d9JYKEDmxOloGgRAgsbOnPfLwygUJxbsU5R7DhrPOySqSTcEiEXXtgjgWK
blJhSdlkwpLSW/fmRVcq/fnXGLMtH6UjiWFFPitbYrBNDTLnXd6Zl0q9419Pz+pme2j0W8N2t4NJ
8T5eE1VhEvWJdm8m4V9NHqTgI8tDEy66i9Eq5pFaOxJ8OjNYkByexWjmjOsmlrCgGjpJdNIF0HUr
KxP8MtugUUBOLEYCFeCePXeePY/gf4U9Z+rGznJywLODjThSFWlbFjizbFqTUoHg6o5Xm3IpS0VI
+RTsyfImQRmcHhR1CWfCOaAEaZceYdGoKs9yNgKnADeyn5prnCpbLfXM8qCWTgb/JeFngpDck6TK
VOARFzmfJrEjbB0yQajouSk9nzPbAkrMSQDyGORSdKjNV4vksRWDpx4t40L2vsHyD0nPP7Qu26dk
Od8/9e60rgyzb4CCQk4yg9xVDZX/vm5V/suq/LNa+etN9qiblZsv1fJ+7QFtA290d2w1cxtNPb/x
ojsYPoZXfdfUv9TK9cP9h2dajgg1eyZQR7WH3Kz2Tv2s/4HV2l+eKekhQn9nTgMwEqq5ssIMx8oM
/2xgogvJcO/2QPwpB67h+egGqzTxRMOKjB4ycrgRlRy+zQV8PJyhhntwloYeMSZqvgsJQYCwpyif
z9fqNfDQqpxZlXFDv3mlfb5R3zUa6mcHxHb4oGnvnsF5EpwkZMx3FAJpp05HDlriWZ3rkzBYLtSa
thEnsvPxDUdfDibg6hom9JgjIP819oto1GTTGg4dHR7uHxIIoYGIL8riuqcpGNNDONqxi3WqqjQg
lLhjOUEfHYixZhMQcCCGJXJXRIafSAXAUn2HalARvO5G4BHA9Ylbo5Q8nMsI03ZoqyDdgmQPEski
SxseC3Px0ldkLJeOgsBTcydImgaBTUyaWpkmrZSsQ8Ub3Jk+CL5J1EomyK0nM8S02JDXkvqIAeNq
IXQAwEMQGuZ/JGPXn0JkivFRfjmCj/7S8yAP2ZQfYkrI2USGbGzuoUkR/SlwhfLwJgl1QlSqbEFd
DQmJQdr494pH1HHz6UXZRJKqJQNQxbVjFCGxFBCA8ZhelF2msSV54vcLbmMtAoTs+RCVJ2CJz0PK
GQTzaxpFY5RS8WD51C2zu6kV/7uot3A6fNmkzXmqJALnou5Gv+wRUUI1N19CDjMCNkEmgceZv5yP
OAkTZaTlXbIX4Gn28Y+p+61wRzy+49xnzx2SzXOH9CTkL7ShFTJCv6A6uiYrBJjEZz1WNkkw1zdi
dcznUeL/th8UDwp7TXg8iBgiiQuV689R+eaVUt5yRgS52LrC5DmWhwXvrRCbaIkB1kLdlMyQJSDV
a8UPtsdcf5lFAACvgx9UMwtGEGVWK7MjCKYKXsCKU0CxsyjDiDqtKsDAg4CNe5Pc3lULO2H1Ayli
2+OWTyI2qRufFzMOiBgaLUcgj88RCkNheYngOVCwRMpX48AsVlW4X2NvWQH5TpuhSEVoU5OM2Rz8
M5oO1D+hZWPeiuZTAJqitfyVium8DUGH7ddJIzYKnWj5RtyyTxnRQxh4ecxFO4XVG6ZKcozWE6Iv
4D8bTHkPpuXPUIr7+NppDZQHVnkrMilqrjiuHYtGifg0QkTvGV9FPzM+X8QrwhrRt9VOGCwWUHXk
0qZvORdfHnYnWUjC12Ul+MwU5bNghN1eFowFzcAWLlHyZ0WiRrVAVXGLhApPScdFzWGVSUtm+7Oc
4ZO5Z/5Q2OmGKRdqMBwqnjeg6BrtmHKUGwBA6szJCRYUtBvZUz7n3yEvyPmTPxYhHg8Q3xrKSeOI
C69Z6XNN+DtSdqtbMJ6qGrcgG3Jrwev8mDJO3P+xwbALdQ9T6cJzL3eLUWbVo2oVdBIHc9dm1AOF
Gt0OgyiqgJu0IX2ESGPPfsDHA+dGx+i3Ls2ztnF5it2XLySQp3hmG0w477CcfAeMD+m38EJ0Cn1X
D+6g+FM9az5yLHbbEIpNlXrdOKpS4ZRcq/UwQKIu1997eCsgoGtlgWsReJ6ZfAac4szhyqVLZbYP
/5Ng1/ZpcBZxdMBBCU6UBvjksgkWRylKeWtoyq+NTbyYbTyK8hBBV98g9G0bAfMBTX7kI/lBkeeO
OS5hKixYguK1FDUsMD1+y72CdHOoTYGb1oCIAW67c9ZF2Z0ax+/PoWKF1zL72Op32p1zFDrd/aYI
rKXjAmHWvTkbZTge4w2dV6168Obw9VF5bS+gPqzVkbF+QJ8n0ayOn8NZ+BEGeI/I/Sfw+Kt7rK2h
x5u4PIOPoa+RaMuFbRpJXCJ1BFaUa4R3ynKFtFIvMueBs2aom7JM1glxYmu0gl+dcEcpb72zSH4K
fcTRYLkdTE0vHQCWDe4nmDMVEdg8jPfwAbvudGUNlQQT/W6GgLQC3ZHlr52vDRnBEkExKt+4j0OL
nXYGMtjusXYvoqglrsEzCpEQd+zaqDLVDuZzSySTBfS46Gtio2sm+gAipUIyjMJssJ5xtYZsCrxq
4r4MIrjrcCY/BMlhxmuyRxn/A5gXoXuLWPGO5XGMdB7JouUHChEi3+FchDlu2SbN8gzeQci0AL0M
aACrFMgVIGhb4Yp8OriGNQrkqPQ0uw/EwUFGQn4fujgk4VKMYUI7Ab4LPuahVDo1zlrvL4fr3l+G
TCn7TWOTmYSWBmD5kIZVMjbpTsVXlJlDlb1r0O82Pyp6FwCZshKA+4GWJ8CGl4O8HWVQpZcVJO+S
GHmpZDXgeYORhoeVUHydxeQUw0tIjA7ZWcAvXiklbGw1REGhiauEaMRHPFlgu0t9Pq6RGugbg2Gr
n9dA5qrK2fEv545iOTscDyUQiHnVPZVfExX8VXIQkk5F0lJYixqNYgaWZV9LyM63Z18UXZRcuJER
hpyPiDA7M7I0sKVJ2Vfi1XqSlmMj57Af5eSxPDIV3k5qEwwpsZQHjxtM3PIg0+KiPwWnbSU476kb
xdp+va7/tppeVq/bqnrZPNhV0uOwkBQ+ZsISfyvXN8VbIBIZLPxK1b/ZZs7hSfui7sKUjwL5N/ea
JSFb+qAER/S14Cl/Yav8RVdEW2v7rut646bQvtphC8ktaT6WUQH3PKRPzqlxLcMu0NLuMckn+lww
FqJym3yI6Lyd5tsu0lxBtRs1oG4t8ENONQMs2xfYOmFv2X59t20HAX7mv9pgKIJYYd3Ddq14+pSy
NHbZmsmdxHwkXjuKa5aaL+CjjaqweIsSFVS5p5COFV1XUCJRcmW59xWPQ1E/LfZHUeAtMQuReQCm
RennXeIfUIvcAJO0PRSNvgDx7vRDRff/mCsqcIac0P29UBQx1hB87S5oRTxJ4lHKV60CQLJuT/p9
2svGy+2ky6rOFLVo0r9I+iwpCSIdsCDuFb5kzRJiRSS6WKd8mTXY7XXtptAkKRaZSbfkIQdAUoIp
AfZv1K1gitlKBia9RDa5bzeVJGAL0pN/g90An5gbp3++khuEUFwafGwPTy7MdufC6P8ve3+637aV
LY6C9VlPgSDHZSAhKZIabDOh6yiynPgfT9eyk6pWdHkgEpRYIgmGIDWUo9+vn6IfoV+hv/WHfpT7
JL2GPWMDJGW7qu69lXPKIoA977XXXvN68Z4vVCaEahbZYhAQNYMsiFF4cAy3JluJil3Cm2OcN9gY
OBgAJZqyR9EVHFuYHJNH38FIp5NZGJDbChtj7yBAoEl29OJ5/dWLH+LGFt4uLw06jY2AkCD5GI6T
M+IUQ+0MFQppE070sRC5ZlgEx1LkZ0KASlopYk8/vAgi8oS5iRvCvYnldnlyBdM7uzXtbJMlEBrJ
AvDHeHzbCMXWhud5q9VcIHtnjM9xyjIHSWy5GiWtSNUwcZ1gmRDxztlXpUaOWrBA7Lmi7SKQQiI2
oH8bi3VtsKgheFJvNWlix8/fwj6Vs3nhWylk5YXQ83+YC680LR3JfYsm3U0Qoy1n0pIVl+tO0eK0
x2hwKDZ3C2cpfd6ZzCM/5HYfII6+HXx4/xND60WCXyaDPfyDNhbtXfmLrC3w185j+Q5YdtZlTVPZ
1Nt3L36hpgasIkv4j1lEjJNpVdwi6SeAO0Ijo5dE43YMKpje4u7Q1vJI6R1uC77DLu9spNq/yEZM
D/GvnPVehesFRccookS0SmJKIpyMG6dIAnZhha92DCsWbA3G76j9AE5osc37hUrC+wI9KQa5rmLJ
piOFRkmTk6K12E9N0tJJ17wovzbM1RF7KKe9bIjG9cI8i23shdU7QKY4ysyZwknKGXsFF/A+UCJg
pGvwvBiCenvj5fzz68JlTtjcgptaYNbtMhyb9w6g/vyaTHUv+ahal4DVlroD5KKQJViPUE2UDoda
qs2Y8wTesREwoeWwFlinLj49EdjnlAyeCAEV6RNlFx8J7AfDExdYHFrEkkBQhJNkrRCHo8ZhrSPZ
LgAMCvCljUSpzHI6WtyGFhtB4/cTWvaUVjJBvDKVMEudrWR/uCE/tFILvWyoAVUWuDb3Iy6MX9Sf
oqnkePQPSWdF8+RamDSj8a2hjwQg/UWoo5RXCUFhQ/gZMD6+IC8sdY31Oa5FZFISMnrP4mKeLc8v
YgX/OVryovtcY5CmM/wRyZGQRYp84G006CghPSAhFTIK8rcStwitlyUiEe+0gEO8MMQR9EZ3Y05C
dqG0rT151wLlg0btGMpoAI9o8lAz7lZ5LbOiDG9wk17j7erYe6UQejY3xok4RlCYuhvE+cbwvvnG
OtaGmi29JZsmBFS0by4o2mC5yXK6K1fXxy7aPJ9QNK3J8QkI8hPaeQcI+AWbVJIFEfxtBL2gDqgB
73hWhXKRbSoQu3b/1yc88FOtAjO44bExP4YY3/wMSzbZhBIKbMTWEvcqWdlkCvwrm8HhCElOrWzi
YmmsUouLE6KRmhMqWLtbE5PgX2hHfDhVmlStw7Q0mLZHg9W2eZQK7RsfdR/SemrdHtTBLDQvv5xa
mmBquiCJXLc3feoL3alP2B9RQaxRt/Tpfh2tkDT5WNlScCxglMKA3BJ6HZRRTEnbCi0V2pRfivtV
0pRAaMVDR+8NIBUyipNOu9k8LZmygQ+Ls9Uf7Ylqk4qylbTwdbFh83NxwP42BYIuNMbv9QAFHVE6
NgOhF4+n+uaHcLKatC6FdaHcujOK/Rpf14YDm1Nx2mxwaAMWO1jkZoHMllcQ3Tya8L2L/csje8Rx
OkwNrpLF29WcUVbNhNkrq89lATQKaNe4M5ZS+rTU0ifb/mhH2x8t17wr5cjsm5ICqVHIRI9wKp8l
/TQPS5aPpolrt6xYC2Yq/Q3Qt6rFR+bZ4k4rDwKxqiUHAb9V9YS8tcXzliJWSRt5MKr4VIkG8nSl
+450QRLUzXCUjgfCApU8wUwxpaZQhOm6vuLXEVNO03SAMTiIgkJ2MiEqIrSs3i4Fgcdnr8Dnmcz3
5zusyAVdG2wYb7+4NaZpSKO1StC2KXkI8Yj0s3IdBBMopE9BZAQDkYsDHadTlJ7h2++QeQ/UiMjk
SnYeCEmMWAkoKK7wMo6WTSE5VktXcsEmN3Z6IqRvfOedJegHejKjdZ3xcvECuLd5DTgIWtgZ4A/u
4VQuK7SySgiCvnAP2PYz/y6wjUHRR3OQpcyiEjdF1KZ/9CxXBGaGx4DePoOT5mlswReZ4MVqoBrM
IjU9fX0TF/rxLo43m0MSaCNMNHiBTaRQMIGIRJIs3ElVWJSsO12H3b52gg8co+Cns8pfHG3tb8wz
hh6BGHWyq4rY31a4ORu2baHjeIpGCr1VXtKiPpZ168NA0U02u3H8WSdkQ9XVJoX6U3947v8wSSdk
NAFfVZyYxjs0mYiER+nXQb0ejDL491P/o+b+W0fhaYifHGNrrndoiCOi/TE2xPTolptT6tFteXLb
iy58ut89+/Wd5dFd8OIuhg3ACEENHhz6cvPzyzeHP/eO/mpf3rd4mejRjKaoE1i7tQ+v7dZgkP1x
lqdQznDz7eF2AbjkhaXye8orqPW7J7uKsK2iz7dqYRPHbwY9ilQxzpJBNLyIvX7QveXsfJ4M0ggq
iFn+Nwb2GvUnKZBJAz1vs6DuCx0c8bCWTQMWBSqIi4yVeXR7Wfq81T6/+lgH3ArKCoTYPVeKr0i5
tzwYxN+R9PghBpjjABP1q9ZDwothpT0dGgq1VLw57hPDa7CovDCZmj0VQyaBG6CKSz2lwPDm+miz
G0knnBumZxjcIq23Gy2hs+mQJdI1bDmMK5uOb4NruMEB15t6dPwMt4A1z/MT3REScdJGB4cgBqkM
fQRXbln1uOB1ouaErZ3rY4dUA+wCRTVDRYYsVjOUrc5hmKTz8xSRBwntEaZORBOnsaegpMPk6oqy
8vYsjFS2BR1wA1vGV4uUUUpbojFKi7EO1y4jThUUNZAFWVRrbFEL7NOzEXZdTGbkNSNvwW/hvoJ3
DXYLgqYwfNpoEJXgYyi6OrDG+3cfXh8WcLI/osaamIhw0GA5meF2AcK9QEfqARCd3XaNvG3Qniz3
xAZRQTnC36Zh4dNwvMwvogLGHua3036E3+HITjMz/AR8naezMTB9vBYaM+sNI1zJOwVw3LddFISQ
/x1vNAnvOUSbDHEY9RMAnsF3AAt1vCb4aGJBis8jAhHgwUWI0GJ9tcY2dWCvY+FipPMgiI+MjFUW
xm0Dz0ya9Ka5VU3YOT2HEb3OFs+z5XTgMXcyG7cIGIG0aHWIQVCUjuGowTW/6pokUscfqEVEmKAL
OfZHZzGJKf6t7+DYW8O7Vn6ybYOV23wF16AUTdRhKXbUrA3wFBDUy6ZeCqQsikf1HJ192tpsmhYx
wTM01OFGeBQYr5QvueOGc/Bmlvy+1OFts6EZbEueGDLeJsMGeJFSxE3CEDUO7IHWZMJpxT5bhXWh
0BPFVfFNLMoX5mKhASQ+o1OB/D2aZvH9Vs1eInGrCfQzdbFOMqjD5T0a3tZp0gG0nM41dsET1IBq
RKAFkyU6JuREB6IwYZLcyk4T4Tq2AvvUqo7mOodxnuZLipIixmQ3IHCh5zQQAUFGDUhkqBv5tHi8
dCNAc2ezKOyJN2FNfitIIA1jVx6g8NujVZINGhDsET/KeRGxIhuRXXe9HfNKSW/F4nLwd4NaKCnB
6440xmfBaAIieA6V1L819I7lQojinZNciuqUZ17ZNp6atK90d82JKeCQQgvxZo0YR1pDqm1bltMR
YBKDYOB40TDGpampssa5VONkyq44SHpvDZLfrB6k7LJihMwkqc5ViAiUH8Gg59mYSPautGnyj3n1
UBJ0x0hgEGRfQ3ZqWmY+B3ZmNLVHRZoNm9Z3OQVak8pyFHJu9eBkkzR7UU8tGYq0Fhk0eYH+C4WF
8/RKfA6LVCWjI5e1ekJrDZSs8oW3D0tSvcOPZIRkizsbArlP6ngt6cEA6AilFDL07Db48cMLTg/1
8kWwmaSHjZHggmKeR9wm4klEacmNSZIAHo+H449J0UqYi8M1lMvFjKFtD2tuh6yjPDbW4P6qtASi
OVYQSD5POzujvmOg/aO9PtJ50XZD2m/IYfIirKVpkiN7kEtLNxk/Q63xpWOYwKM8uUT+k3uC3yfN
U/S01hGrYN/ERWmPQ9jIdck8zeRmpaGakihzP3el7K9km7mcl9rBPiLuEcZY00MvdEPoQRZEHKCK
3nkFTaJvIGu2LDiVkiMVUUxE/rPjrVWuEJ1nBVynPr21EODqAH+yeVIjSKs6YbtpC2vdgZdckHC5
9S97IiBclF/XDBNgUp55ZqStA129iGsKqFQxpo6poOj9imz4fJSmFT1RThcRzJiCSsrF+D54vBr9
XXDMbte60Aw9wbfM42IACDkEc0H0OKxl2nQwUstlXhtlQ1HblgwG0q6P4Y6s++QYumy7Yo2r60Qg
KYVKstXzWQ8WSFK85ov0E2BdrQBdSVWtpyZXZonYKqpdg2SM5Psty5xIxKk79RKga4O5O0v5oThQ
v6lJ6ZEtNGx2W9K6pb0utFw+bmeVpc9Tfu3Fnvn12qgvRU9yC/LY0s0HfxigY64BUPinFqFSlYQv
BcFVKZySp16NgSqdLifkNx6tBi+87H1Ai2/ks18iMk3LjoZhWJv7JTuoZEmLxwJFGIWXpPKHs1Up
7s+8c0j9Jy9b7+R94gk0eo+rBGLWUYRKa57Ftc6ksVf3P5yWkYkNxZv2GIalc6g+/naz98UDvplA
6U26K5mBA00nI4qok15vlbaqhBw0CQ5XVTqOS023EWedXsfBH/QzF7YpSDSoJplHSpUTBJ4r8bu0
C6xyqQl+a+tMg2tgFb9VWUWL/0V612FmfM6FgYTZojEm9wORb2gasqobTSm4PcmxUgAosyf7g+zJ
24sMcuXsoQcZTDMXG9Dxx5BbG9HQOnaTeZVwvFCy2qiKD8XFSkJEUW1PjChudWu922U9Yd7975OR
CJz1tEhNG0ZGG6FpYWJD+lVpZ+O3BLIsY6r6j/3QIiVoJEzMSy2CvHUVa0hlWRUqA3PVLNM8Z7lo
wBXIC5uzY3xRjRKUmKcrmiLhrDEyIqH9N1vBmpl+VZ2zjwKqwo6GHwnIHXEIQl4peOYf6F84XJCb
IE3s7p9xUufpJLtKi0TfOkSa2mnkk1wCpIpiJdls6Sn0H7qv7EN36hLcvjHgSeVBrsWIrLOepQuJ
TBu5CPAaSgErEM/ZOPWKDoRpjggfLbxxlBc7m7GuLchdzxmnFzQcZ5xEFML+erHNEM8pfChfoZSi
aeVoqIbtGFfwi6OWDLzDFKO6NeFEUnAeg3pbDYmCX/XL0gEI5Ntq+fp67CoJp70ksuzFA/uiB8mq
fTTd1TSosFC9I0AmnF33MFo8vCgJ+19bYTOESjogxDHkFjSC9yrqWxr4TxTHd2tANXGEpWAtRREl
UggJQqYnMtJl/xy4MoVKpaqzzwF8XljykhJrw2cpSeGuZ/kdZ6hoqNYqbmvtViVUnopkBh64XFHd
ZBVcoKy4VNe4Dulsmsi7eCRX3YQeYL/fXSiRSikyIO2fH3rKgeWrIrCUX4VyCJvfg5+ykMPRdLBi
GdWkhT0upgAqOTpVx8a9LcuPjyCDlluVtg7pcIhaCZceQoEirKeL3sIwfIWGe9qvWidPEnJ/Qncy
KQzmVVP5PUw7B6U/V6ZLvCIa6vizqU8w40oLNUykwwRoV47LuBgIwlGd2HFeNNXJbu5dy1ld7/6U
DP9M3sJQEUgPIT1HOPboQ97V/hM2m4yRqkIy+6SWeZy+khzwKLTiagsopFF06V8RVYFy8douK8RK
UtaF/VYtMHzndDnDn65GHtqmvZ7urqD6MIIYZyLuCk0GgQDjExdc4Di6gf1ZemhJXxqzZyG8MSQS
3SBSEiOV68kS8pjAYIg9VEgQe8lDX3+ch43lRYKtqWyUpuBbMTyqXS3KZ2fqrvafMkiJwqwYgPwk
j76/aaTdkNc/ZBKbtkKYDntGXxTX+LqIlHMwVo68oKl0+biecjHYQ8k/bNuFqItB7qJK/6IYzVvJ
41dBq/QAFpDq7Yice1UNdvUlVpzlMczYdpnZr/D/cZEnhdTW1+cANVkD14zOMMpysFq5hhQOFUGb
tuDQxdimypXnhcbo1pPu5GX95at7kPXpcPjqWoK5uEAtljjoxX6bAOrNtPTG6vHWBuTnUgxLUG6u
rMM0Euc8AmVU8bWOIONEm59d63w+pDa9dnSl3ih0GyhpBV2D7T4N2nv767U8wtDHWTDOpudfKn8w
X59oFHP0+v3nj0hOevxxep70KTJDTzhKRRysQUd5wcyvGCDrYR6kk7N0MADSDZ0yYH8wuWMeZGOy
AR8nN8EbYEKPj18GO5pQybPgGuO+TEXWVUxGjPG5RgtFqvQX6GuW5+MG85Q9w7+GhmT5yfL4DDyw
uGkwXMkIGpht0UqShEVEDAoyZeLODo8wN8Sb10fF3ClYAUXN/dHsAiAFI7GSCVDnv4+PDl8e/XL0
stsMrZwq2CDM3DF+pfzuyuJU5jxv9FEi05OP5rFURfLRZDZOh6PxAnN+j86nKNCrBc/S2Txl99Vf
uWiFLxnOYjKaYvJkSRyIqcP+/cIv8OdVy7XntXK0lSZms2aInWUckS34o4vJ7ROoF0FvgKvevO29
PPrx4PBvveOjd78cvesdvnn9+ugQs4Q3b3Yt10poRwaZmqVwSWHyxh5ZNkX9ZJZQ4Lmsxh9rwXBw
oyH1XVpnACJS+SEVeYg3BOab4PQK6Q2c/fEtem7Q7de4WEwAsI+x6DEVBAYAvUf5ugPgXWTn52O0
e2ILwpzCrk/RHDuQ5tnYG7b2MFcppjEIGLa5PVjCNt4oUM9m5B98ojx4cU7Bn2EVms2W4SkDxaRI
JwpbB80DTItENwFOP9ZOt0b9dln95kGL6pOR5RKzgE/F8DiHl6QucDF9De9WNdxa0TANmlr2Nf24
vOl2xZjbq8bcalY1jGOOqlrWg4Zrxy90KKm/ozOe6dG0m7F3+u2KUe5UjXJn43G1feNqlYxrt2Jc
uxU7vutr7HFFY3sVje15Gms1Kxrbr2hsXzTWhzsinZp2+EjlyLRcKcXwwXYtl8T/dSzSmONB/2YM
dMQ3AQnVES0wzrONQseuLFB0qnOq4aT4rfAjcqkODh2oHEKXY968QQr3AeAh7YzFU5TGmbS53QcU
6iDDv/QZfwA0w594hS98CYq1MTQN3A62fQsE2zCLjOTFQ/T2xpzCKt61iiAsvn8LeDAEEvebIHoS
1IkIG4qeltPfMRbJfEwJTbGLBrxaAn9hRTAMjTigKO+e/h4NMSQBRv+4zaUUnN626O0447tTvW7T
a4pJ3F+otzunDrsTDkfzCdzNur1dqricoXRRvdzn1sifXr57dKqiJhoxmfAWsVZrnJzXgl4NnRMW
7soZuRhrYvVkoAkjUxIAw/yWwnuk6KjDq/2HqelBuQqVcvfCJIORut6VEUhmsJo6aeOKkOSjCTJk
M1hqLcyh2xK4+8EoZ26SXIB7xuOU6nEayZDSXnER8dP4HA6ya9Nin9bghJT6uOmnFCh1lkwpYB71
jDFa08EIIyrDDlKyOoqpOZw5LfcxQ9Y8vLOhK0+u4ExBZdwduRskQGmZwXTpb3GPeziE3Nxkis2T
l5wLubP5cjJJ5re1gDJtsi/Hx7uaudPz7JqMT7g9mDvOSjSuA7J6AOCKRPbXFdt/BUwQYEtOTlix
+WKUtPpXevUXt7PUXmwKLs1LZq81nkbcYow/3T5dQ+FE4h/AlOdUZedUbwQhKnq7i7rwyWJJD3un
pUvWOpUT5hfI+rU+z9o9Wrl2eBPQwt2QjOzGyIpKI2jSiG/Iov+k1Tk9Db4NTppAKZ8654/hw92D
+U0vw2WdwivU/N300vmcnlvi+ayfUEzMKS58EC5UhZ219oFqyDZpxfsZIGrkJnJ6tydanSXLPKU3
+6Jn/ebRqXXYClBfPE4i2AKeHZYuiWW9WnHR6N35PniisgKX7I/n8l1OVZwFsrsR3s/oXH3L0Xso
ks6gIz0j2AgDh3TSeawC5CisIkw11K75kdS9zo1wmHLPB17qqke+uPAoqVd7fGOKU8Tv9otX4OBG
fX1ENRbzJQ2E3z3mi46j4nBeesWZvZnKCN410rJiMHaRt6sRHFJM2Dy4yMYDHbyGWKaygDqsKebk
xUZOdopa2VW5ckTMx+7jBpweHYNSmhRLHU9XLJsbmEeIElS+P/WBond2qXs3XI+QDnXVqBytllQr
aWWbXUDk0OuKudgfZcqcLlxIWcLqTUoPYZXSE0WKUz3YhVjkUi7+wVcswRcD6soURAyNxSg/pQF+
nFLn6NE9mhZkNDz9dDSQQl2Ej7F+HKRXoz5/tnVrGLAjgbOVugJi5dIs96xm71LN3pOauQM1a8Vr
7spK55jZPIMzubjVcIrRPEoGEj7IO9vbIgh5sS/OW13Wbj+fD0vatVaL+Q8NSM6+qVU2jlY/yy5H
ae8C9k2oVk2aMZmbEgvN4ugdcQVCc82WhbJMN4RLzKoVF9rLV7SF37u8fKq8rxVaiOqGqIjdFr0q
iK7D76QVCDVhR0aiRFYCI7GDVC3gyEVn2eBW2LDM02E6T+fdcBvjgNygwAlQ083FnGOAdIoTcHeu
QHbj4cFPjf54BPR8g1LiHcJ7wwlSALxEgTY0i7PelaigKqhhSX/rd6cbZwgjgjY8JKALO9K634JB
vFze8bqpEhR66Vu5nF46JfwAR7l+cA5jxMuU8zoMkvxiG6GvJ2WgPWCzwoM+Cjqx2Dfb34RWhCLY
G3sJxLhPwhfD+iuMSTBKB/Xj0VSqLpuhv/ghnNn32WU6VWEkxWThvaGDTxaJGxiAnJEHt+WmM6KS
zSHPxxSiJo2wbtwQD2GS90cjxzpWjxFBYbqoY0pwng2ckrGIkLh9U7++vq6jCLauWh+UzPbNHIip
qfY1oB2rEE4DADXkGfKcHpxhTbbeFX8LIRdmFCEeWjpPF/gIJGjqBGZASKf81PmsgXcTUIiDlFdm
lGf1x4/3ntSJTBLhcsK4JGjAjAINLPMaP5B7NoErZv9jsYLQfWKXBZH6m2MhT3eP0hEVIF9aU4tA
4YWgssN4XaA7bpdWSlK6f4F+WzHygYbQikXUaf+CU6FwQjxY7Tn6aQMVm8znIym79ppXeUhhuMDQ
ExilSZRyUaXUUPSSRoQ0UPRw6scxByyBn9XR6mgjOQhdtffpKO9xKsZZcp5GclekcIfX38GsVIZY
wJ1mqxbsNNv4zw6r1jmxI6FmLCIb8gYxQazt3hIP8YJ7iW389P5V+BDbIBAwAi3BN/dqNSmeOQwj
mzTwD1LTnINV/Be7NSRdVFlpFSVg4RuMCNslAsXcUIcyKoKJS5jhid/fbZzt7wrcg6kEJBoSQbP0
6XPxkn8fjcArjCtsruTHI1QihSLN8zYt9F8sqsPCkSRDjKxxo63OMKV0VsZlrSHCIjEwME3/IniV
3KBWLaA9Dw6RZw3lrneKfqTlVK970H5Y5rfGYRPmX3ANJGzmNREd83EmZhlFp9k5mWtlGDDCZK7y
ldH/aBExPVYyWsjUtRPKn4ThVTBiviSRbCM9faa+6gZtUyzvTulguTDxB4+cDw6w1IgAPViE2443
Bg4FD2wYJMFCyKdDc4fFOyFXKG61NT0d+2tD3HMPGChZsL+zDCIiXbfG2SX7U+jTwlsv3/zYIIG9
7IHCAOH9ZTRlYi8AhJIAoHZHld74RNIYYsKWzN49kFSewG13q5CXaqLpaWJkBIUoxsKyweXtm2MX
f3CWCKJB8J8CBU+S6dyg49n32OrFu77csGevBIVgXLXeqx8bFfYBql089cZdbDTPV2/1hVsCmPqi
5XCTHKECKTOxFJtBgfwGN+B9z7PVe1eOosA63edw2lsl8Cas3Ww0R+0XzgkVa7A8yXniHpENT7l3
JT77anzqiqzAR2zGM8cwnoyRFpnAUeRkhtEg6fGTLw6jT5g3Up2rbg1emMLdIag0mySTKku/TMVW
a/JSkvli6cXiv1AMLKr1flVd2qWcTvHDtipBnS6ymbcnoX1a1ZVRrLSvvwB27TKLRG97ynKm2KsQ
0gucoYX02mCzKNEvX13unmytHwz+LIYBey7cHLfVQGQZ+VHYn1aHq0UDL5L8GsOVZrB+O1Nz1Hb7
MjSXyNKCAYLg11qwneSXANGGIqGmkn1O8+t0bn8sgDwN2ug7Lg6KxdukEODZFQIKKctzzFPY5dxh
ZK0+SBdwu3RD6ZOGNC4G2GcA9HLKZrg+ceOfsNlvKHbFEiX6RoTVtGWHymyJUe5ju+1vqXFWXdQ8
FmM4fVJ/nIpFIsWHfOB68gkVHGQJDQ2OsLl6yxgqpRhYLNLJjD3/gXhpu3TemlhcER0eaJekB4eG
RjnOWiq5oluKpFlKz0gp8bLZ3cFxR8TCoNWXx8Z49c1YeTt6rQ0IBAAoLz03i4zOANeLyep/Cg1f
cnjFqRSmgAaVLm6o4AHnIy8eWbdXA7L5HrUDXyL49Th5C3QU7TrDk1VWoCnp0oqlV+IF1e5K7ODJ
VOzxxpcBWbFJW0KHbnr5OE1nUbPxaC/eWnPRByMR4ZAX3zTQjJhKWW3wVNgX5ffgWShhhiKNV2KV
mP0C/X/GY/O6DcPwtYz5g5pjGI1grwOROBo6R1VgfpHMUiT4j6eTGc+1gcV1UF+kKpRWTJAkwgwI
rV3MbWfSodySRMMHX/yl1kSckobDrVD8FG5MhlOhjo1gD4ZUawIdYk9cgZw+Zmi+EuuBGC+3rCDF
drNGMekVg8Y9rgXQjO0epO4bGvrKtDjSCvN8ws3QIxvyfBDB5gh18Qc/vlXqcdmIvHNIbqQ0+PIr
sac1pbSXKne2XpGF5JsSFC8MWWRpfIrZjILMNfr8mh9rQTM2TDnEt4X+5u9BGYfoxvBZt2Z9XVhf
LaMPUcJ4V9Hr2Yjspnbadwq8zYR5ZmJ123SCSO0OVeCEp2yeJaBGPJ/6TLPYHoHOFeq9xXlV5gr6
6NnZnaOrneDD8SuRyDwOOEE8Z5efc/hSeaidbOuc9NxIYj4aHoxHcMojM5u5On1WRvP4O2VarlOa
X42S4PXR+x+PDt7V2TPkxesfaTQJKryOodChSHMuDSeO/8bJw6ltVHW1GjuN/Uar0Yb/4f+hgbW2
YXQ+7/BnbRvpfN/F7+YGq7S7drk9bscwvXQK7EMBhoQXzy0rMrNYm/6ltOd8LDxfKd+6RAOe74+s
8YaoYvcXfMzpOwX0ewq0qKtsuSgv0rZXB5tbCrsrX4Mt0eW0qlDbmQD0X1X8kRxkZaOP7UZ9m7jT
EgBDo7zo93AypYUe6UKT0kJOr1z8rLT4E9EmTbl8eK1Cq1ihfBS4oqpYee+tHafd0flFT14IJVX2
CBjxyJeXcRaBfUUKBwRoIv7xRB2T3sHLFwd4uEsbpoIHz169eN07fn/w/kOhsDwSIiqzH7VEQ4Cb
t8nigpEjuht1BL65zYHk/3GeLWcNBwFFrTjYdrHSMZG7UasVN0SPrygjF5DKu3ttGFSTOYkciIZF
XTDA4hO0t5inAhueZegKPx9h4hHOBjDPRdY35pdzVJcgauaOjg9+Oeq9f3d0hCsQqSXYxf9xxxKv
FD8RGhT0xtuf/nb84vDgZe/9395SWx/3a8E+sBb7T2pBq/XoLjC1rxS6e5ouDmE+fTSih3U8wnfG
z+d/rQXno/MErsMjUXwtgzeVqZ5J1i75m0vLiz20dWN/9fA8h6toMQttb3Sm36923KgD97R5s5z5
HU2l7hUJQv1kF6OJpiT29qWP055r6NOOppE7ghBv942kFxMkkVGYY9vGoU60UZVwjRos4VlZSS+8
7cejRdpAQuGXnUN6H/F2XO2wcywSHlc7irK7CGNrq+Qnzkh6L6beakM76xNj6wKFMEIVUAGrc78e
gfRCM4Fuy2bn/FHQKtbMWrHVY/X1Kx0tzWbLlSXGWGolYEZ+xZGlJfl8lozEY02SGXFVJmbg3JXL
yRkQkPWnAH4vUKnkOTiI8ixjR+LtxmmeS23eCgWdEYmkuLFfUyBpyp8pmzWQDyyTQDy4PIUmPUYh
rpCD7D7M1GDJWCYFw8S3q7P4fESThqwxFzYuDbZxaZ3GMhltJn3d9U43VC+NF89PoB80Sb4f/LDo
gcVFuBo4H23GUmWcAnsbXdkaMsOd/YrdOOPyBDml9WBB/NWutJNCgqhY+t5CnZDkoGWO+ZS03u4G
syhjR8pd0P1IozdMSKqWgg2KK9fidmHlZzAHpwxF2HLEtNAStv7hbzfNpif9tjTe5OvCTNWFM7pI
cmd5xHwo0XODXq1KDklBpeDLZW7Pjl4VffqsQRlnHQUlXGV7G413iibDg2CQ3Oa14EGzPYDbdzmX
v+Gqkz+hHXn++tjQ4/1dFHzi0wN+wLc7+/ol/sZ3++rNftM8rYC4WMsjjixyZDlTIeaEZxe3uY7K
O5LBtUn4SlXMvNB8lvB0AHTJc2tTVUacGzuTckMqohsiCI8WCRGnr6NDwIh0KzCNGSDwGnPq7EeF
0is7xsWI0jxAxU7VTfi14OXHo8s0OAeKq7mNBlfb9CckZr9lyxonZHXYyNNkjvG+w+i3wbfxb/k3
/yV1yHw+dDTTUeyE9JiKOGaTxjkS2kBY00pOPBZcUhdP57YVfA80HP3D60iHWYrFxap4MuDxhxNK
HTkqfCaaOhnARpsnjcjCk5G9knTQZX9Yz9ajTLUguyUTLAffAn7vWAs+TMbj4AyjTGC8CL4oYaMH
jviYpm3PjaMBwthWTJJcJTGESbOAPDhoDUO2qCOhOXYT5N56bGNMYsiPD8rsKwu2UDb1YutcbaGz
aeGCw6qge/Pb/EoKhMXtiTD4Db04/tsx48HcjJz3OW9QNYwrEWQMx0MjyGIZyiZTaALHIxb/zgiZ
l/eVzoPPUn51IqRdp3HRheFG+XAqBzsqbLhgGqpJFrq7Psb0ZPkXO92LSPa2xMspo76cehgBQ+Lm
VJMfqHXDI5kmaPg0squC6dLo6UWJ/WRiZLrSNJLGDkUZUooqt+aQZHAkre3IMG0aNev40HqjruUW
c9o3pNHMRD5aWk5rp2R4NSGiq1kCFy2ZMyRwQipoAMdFf1WnUoxlCKtqWhBliptqhiTJFBcZ3Y0z
Oy2TMIu66J+ofpzQSVyjaoBKYmhJBmum3M+W78UVdm8sW1KnhbqTAqcqS7SSVj5WdEVCL6cnFoSt
35Fsw+jHZatEGkBFqVyfMBwBG+5JKOGouNRNVONLy2rcHy0LlUOqWzwh0AvB56m8vEn9bZMAZ7Pc
rWPAsq4JQ2naKz2jZW7DefspGQ+f8U7Vgh148Xw5HosXd5oyovZFuBnRbDEqOsBlBUwS2r5h5Z3R
KNS4tIe6/jnyBF5d3KOHFQex2AnqmKCb/d015BY0ZWM04+xEHz57WJhtoVhy6i3qn7hTW5/llR0Z
J31VT2L2OztV9CxsAYY7XlxnwU67foZOIUI/20F5a7IIrucJwC8cRJEGzvapI+Xr1FG+mpAu1OZq
rGjwp7Wx+KdcKKX0rUAVDV7BMRJ0EZ6oGp4OJoXpUFLGVzxppbedVqkWPa1NKSam/hNCU0EzPw0e
F/yvtSaXxEgVvbECVzl+iXXB19YOhpZid35jaHIXNxXtK/Wt1by4Hm0YMdW5NgoTV6hTvLxTS++L
7Qp17hkFgg9HQ7KSRjWtoQAxKBl6JTsr3JgEVWsRytOMWI1RPxkL7D7E9MNBhqpZ1t5ikL4LdJ4A
qvovBTucCtqlaDxaqnwWzuQFlbN2VuIF8dtEymQegn2xriGPQJPo/fgetVdY0lAkLVo9Uk+LfCAy
FQivnF/ca5rOVCyo/2MxV4jp0ixncoI/To0VRfFoMRl4KlLzWgLUU+1JoGSqdJw5JCrxFkpBZCaC
IbYWA1YLxRipL4LsDO27lGFmaNES1DhKPnAoa2SzN1kvlEpQ/W+DUCjmFZv1AnDyeTpH7t+X2n5N
dsyYVkHsXWlkV5BI459C5FHDNq3d9BiUl+aozxcWgeTyo3pRcFVi37viPEpXpmIIBWmKMimkgGud
qqQsrFITZnCLLKA0GMuZCBUSlje7W9msRC3aYgSjjpBIgi3tECTZ+6OsD6/koXz0gbBRRbWsYUsp
e/UY01m2e3teg2A5DeqA7fJQTDTPzueozGDTxVYzyMMtf00EW8dsG+8Qy2zbMdkMw/BXShsvYzOa
BjZwMbAxThzUg2vUHFNo9SS/OMuS+YBcV4nsUZUpKn7o5kotCFlGA81hSbRvG2Bm5CcJuLdhmnJL
hX4NW4hXOC8ZGCMj70UJ5W/6i3RxvJijfxAFxHE9Lx3hYnbtCE+cowetx+rHl5UC0eV/jQRi0YNy
lRGosa+OQWgkDs0ljvfBvMQQFzq2LiCR7v6jk1NJSHs4/BAfdUkA8qOwhkXikiBdKL4xQO5wGETz
5RQ9t+RrzLUV23EHXJ25vQzZZS3gHtSu0T1YcImH4dsGu1jTNNflP4U7l6tu7B7xeU+CabHyaadB
3ZrayYBv/nbFOfDdQP/cYxDRcLpBi9gln1n2vY2ifeC/DuRL3o4H838x4DdYj+yyeE0WfC5tg/9B
cLZk8pt6K/pg8hKuOHFkQ842pT0dzSgdSvpWBjKCN8IUmKSvGLN/ONQpDuhBp3AQL3SCE/GCXWrx
kS1l6KUwvigIpOmjjnskGimkvTDfGkkuYre0TFFR7MUoRMY0harSpMbpnq1p9FvHNEZa6PN57uGJ
66lkLMYS69zkziLXAhH6u0ffY18uEiNI4I4nkkvJEogsHU5sQNRTY/7BydkgCa74jAktNkCAOHEk
K6f0D4zSrkg9mf2edIKjRzu2CJKGxGnB8AwTBKhVPq2JpBod6jnSnzlbSCwymha/09tTrx2Tswed
0s3RCAC2B0aprbC5IwtsS6GcTIh8QClzsZQbPkmTI/sISPs5eivM0m0TOi+wyzwZaFp3tSOCw1vy
Rp4lm6JvMkMR1845vSWD98/WiH7nOdIqEp6DMUTM5PGokZMJnxdHWaGBxyNx4BbARchkR/qYcSjA
OhDYFEeRIkhdjRa3233gpuGAjpIx1WwEB+Pr5DZHy6acEr2oXAG0huXHmQOtNsmuQiX/Kgb4p3j8
ODFUajn3K7fvylqUHIjEcoJnEjKh+Qn/Ml0PUBE31yIO1FDlIlaimZcMOJBFMw6+odAt4kSsEQ/A
Ho3ksEg/LCSOSGFs0mkhQACvDhmWfaEEFxS3jGWDdYQpuE7P0ylmZCcvvP4yXwCB1E/nCyAh++jW
NZoIf1fzHaz858+OcXz08nkPM0QgkQrHZBtHyYNs9AG7cIGfj/7m+Y6ZlrcOPxy/f/PKaoInxNXF
Z6MB8ZUqU+PPDsh/43F7T7qZ3ew1n0i1FBGPlMEI+OhkdnErFifAQv4SjYvkH5Nk0QA0PBnhicll
HczeggY+cPJH6LGWqJjmazTSSPLbyQQNNvuyvbRfUhkH10DSXxR8DXjmzYtnteDoZpEClzD4Ob39
kCfn+NJELFiv5h8mIMx+rbohsXzXKBGgmwvpQw4WgGHGxIpmeWOSXGJcgzyC3xRhCx4oAzQ+xHwx
dJvZI7SkovScveyS4/gxiqHUZViWxFMLmadsiKwONJnNMOLwZFbDhze9X9+9ef3yb8Ef/HT47ujg
vXx4/+7D68Na0Mz2ZfwnwljwbTigVobA64TXZyFFCRteGBnwLho0z4hmJicmLOe4c5qMJDtFqpU8
mQLKWMyTrkoOK3M1i9CPynAnygFnpsQcyYwrkbR3GNMlhsb07UeNJvwfeYx0Oq3QiRlimyRRVw4l
RGZRwgl8GjtDoKEadhtEZ+E7laz8M3QnU5tTTmZBRwLi6ZEDJi0it7E+cPbQ+YxPsbGpM7LZQGgM
554dxT6hHh0dzHTVm6UTaqRnoMEI9p2j23luO/ZCx9KNFI8HaW9w/3rqEb3me+QMF1FHx0sSdR9g
/hm47OGc4yTihk5hQCx4MmWhO1pOsvECEaoofcLm2YaI2kbdPDf97PUxtXXqy1y/WVMv3h4MBihF
FIY74uakb0dyaq+zxXPUbXQKw+ZK06vEMJrFVSLymrocDXokn+wtF31pRUvm9riWThnR2FlVY5ws
c0VrXEiOrUeqXPhBlzdw8pMZG1TSq3+QnRIBPT6rc07vu70e49leLwqRKSZznpga+gd03oBxxGaz
fMpmEliAJjhP54Aw0XSfwLtx/NNBe28foKxxkd5EMTDbMwzY6QTOZ+BBv1BsRjw25sP+7l5rF9N+
IT+NOGOU50tiTKggPxXL2SHf8Kbt8VXr9IAsldEQySZITYl/nFZwuVWedNg1tA0bEnkUPvhb/cGk
/mBAWlksJ7On4wp7i9lNo8Vub5wOZZjvSOxi3aRJY2WpW5jfRQJLjKKUjog9O5ydjDojOC7tU21n
ycoWuIgoccYsxngUKtUEQD7Q5z1jqeg+6MF9VmNEiRi/i5wkNNhPRRwIRaUfch6lCEPnA0l2HbPC
waDUDNzTCN6lgnCDD9cXqcCZUgYFjXwf7DTJkhmz4SajqaLnN7jYf/7gYM8+Hi6gl/hypfualkvP
VFFxca2yCJBhsXXnFa5F/GWlIaNl4xSbomHO1x3BqGLf+xVuD8LeUF8wfU/gBmlpTR7TBNucg1e8
Z/ts6pyLaEg8DZ7CFpTmr5VLWXN8WXz5wEQg07JEYIKyk+iGXZzRcipFJ3GGEkmE9aDLCN4fHx2+
BZh/15LXV0KSSJfycO5tj+XZQl7h9vUQjWYJ/2qMZj3xE675ojxXT7S6aXGJRTJuB7shAp5GTUo0
dcYsgWaqEDQ5tGCuCfWiI17obBBMs2AwA01axcIKHzMHiCgPAvXxrUeDOlE/Ve62SJyjxuGbV6/e
vO69Pnh1VONRn3T2d0+rPNIqWnvz7seD1y/+HwfvX6g2jbjLJsIIYzFglrdL8GioH/A+Ug/WDbVl
UEG8+oca+fywHI0pZrS8BCi5aCQeYnEVOC9ny7PxqE/QN7s0nxzdQIMRUo/9tbhvjrras7+49dzL
nMT69cCa3yAdL5JoMpouMYnqXnkTdP1QC9/6WsBD3lUco9sMALum8qpouwhAHF0WgXlAmxpfZCBf
Yz8k+ah/CPQkIEm47AD/JTLBAmI/wD6Y4ZOdTY3WNdNU1bhk4iI6ErDcSvQk3FhhzzAfKqVpnKTT
hey6z2Gte+hqOFoYX9b3gqQrwtc29pmcz9OUXupxEOrGAW7cVX8+NisGstceKkrky0FaeLn5grrc
cXQC12pDJGU8+PD+p9N7gICAJ2jzBQnxhiMg4kg2V3HOVnSDywF1JGmg6U4u5/DydHNhD+JaIbey
yKImGkeoDUcvjrdHrxxKo/GW6z3HgD2LxtufD48fb7B9dluvM+gJZR64PiXj7UshllyTVQMWzehg
lZreKiHK6AYidRT+P1M9TB/YElt18bNLKVGP5KE3HvdYJEWAbVBMBOfAgzLUww9NNv6C+Ao7TwIY
NNJ/cAN+GyynKS8JDJH6gmbnFPNoG5vdNsRfH3FAUOYOiUocYc6YH2d9D6LRZbhtB0Q9E8wwbHPc
+F7SY/DTNabwtCZWw21MvIa2xC9vU3b6WVq3VSx/rsZP7KB0a+TFCcurhbHDdrPIZIV8QfVlcdqa
XCqKqIvZky2xLZsW0Q2HwCI9n5RhmiCZaC0qW51mDtwvif4ljgWhEEHMt8rMOdhnTs3fJFDVxqok
8tqb1kcgYy6FkhD+vpTS3BMNx1yUGvJN8EJ2WleJ2wtLNZws2LJ8bXxHWEegO4G++R0icThqOvUm
Lj8myzKRt421voHuyVoBvq0qVrkSZG5lrAbm4aX1oGSbtJ8RUayxueGhF8OWcHta7O4neGkK//RL
ZPMLpHp6guM9CwXe7699zdCt0aek77jxMgWry5uu0b3GkAVO9PuguTaaEIGYg2wqgJ6b01KZU+s6
I2UQX2LA4mVjtFodw4zxvtHXVP1pEKEoH11UWH3It5q4CYXBR9xAZnicKxdU86bF4ICmhoqCzkyX
FHNO3VMU9gS7JrwSxSfi2h6HjERFMvJzEV5tnFN6ckppaDJOciW5OLCD2XAYFtNL4duaMMrR/xYq
86BDO+e4a7bgyyUucocfH788FLnC8PHtuzfv3xy+edl7//JYZPeOC1nICa0S+BBYRecnNFt8g0pT
8Yiqr1OvCakctCrqq1mzp1DIu7I6uYpYidCjeZR7G0QPMD4bHCG0/6+SihEVlSYDgakLQcdTabsV
MsTpiWuarEcZWwuiPIYpOnIG7OSJSEBTDIRgglPNaB/73fp8Xa7qjgNGfAlV8sGHZy/e47IGQfS/
jt+8Rscgog1H/0jrmJZkEMDtyYFWP7+ymIMIHiwHI2G76ongpLGkiYyM1IGLi3I5Zphg26iOD91s
MERJCzSzIo6NCGOjRsh6Qh7eN9/MUzvSCzrQkhP8Iu+ylXdB8v3+wU+dB686D44f/AMFU9zGluEw
iSP7ew6XzGA5meXRHGlzlFXigc0dllXzNryZdDCwDV1EBeKuQqpKr6YWYV1fjB6BSBpRmGhY794k
ueldnlGK6lazvUvohr9gPnAXVxU0vWpjV+t7D96+PXr9zFL4WojJo/xNQhIU0N3dlbyEqzu0xiY1
w7Qx3wbhb9PQ61EiMGapG4mBvfrJFAk0ajegpaFkNCKQQS0wloCoVSNuQqai3NcwrQ3TJjXKtF4p
Jx+qQwJoCM+3XmdM8aqaKpN1uxfE89E4lSpCj+DXqeSoX3C0NfSCq7fcYODzvoq3i2ebImKgYa9w
J3QMn3mNRkE9aMVl8xWKBGjZ42BjKPmhQK2sAzulzjj12GBzSZwZxeTYqhgJtuCMhcYxya5S8VVv
OdrAiv0eo+1Il8JzU0oybXRATSwXdsZJTAYfce4y9paEY32t1I4sfh8b7l84RsqaXLYI7jZS6iw3
2jtv25Tb7ngthu3lMEwCnMLU1FcGOPhPqB3PvNIrq2g54EEH8AYBOu/qyEllCILuS8wsy2YE9OiY
V+OaEOqgdERoxwp0ARX0T/p3UmD8Lo0usKTcN//0vROtdB5Dy0ChlaFrBm+EnMZU7hVWpuFZOQoR
XQOjCmKib4LhSscqKLnlefVFCKBnB8c//fDm4N0zzD+N+ZQx3ypi2C9A7rAT5gVFEUcv7SjXVtRk
C1/kTZgf4oOtEVWIjt1IQL4yFWE/ipc/ituJa+FWqyKU5+4V2Rk1fzTrtvfE+3Zjz/rQUhUqmjUC
KzjKOSsGQxj89Oyv5tdD5Rpuvn1OLuY6BoMGARWwTKwl63Gm6TUQCmO429GVurvT1quKmbHNKGbp
ddGzz40hh5sB5QBSoXahGH6q45ct5+W3QdQKvv+exhBzEUpHihEFKH0ihjzdNSLAUSwBETmAIgYE
kQgXAEhqAFgKuO1pFswJFsWEySaFXIMjUm2Sei6X7hLk3ae59WfKMY+ik2bIeVN2FfhLb/J0IeV9
2onvmuKj0SjNiNsFZ0DFrNNA0PZeD4iDayzmkcgpExop5bFUYVXpbQ0tQMQwrADm7PqO3L1IkUBS
BIp0QuOMQgEtkqNQMy/lKogQrjHlhWQUhtTF3Ba9MSDosZtieBXHwARcl5tzwrw6TWOwVefVlscx
K3fiX4owaggTbAfv9JJSWlurhlVJGXtLh9iIbLlKUlNyLghPFBm4vrzBZcbjHjIMvsgz1FavjKey
igKbk037QDWsVxw2YmYVOrrCWKlOqevkMl1dCgOaJXC2poCWU86dXlpmOE7O87IifdSezlNpD8M7
8rV0qRTOY7gjETs6IWMYd+jUcQQGXMxcJQsin+U0mQNQzB3XQco3nA56Os5vMQZw7yzLFj3B51HK
39ltYwAUKv6ISrjBsl2RLPDXQb0uPdJgIhJg65v/p06n7sMJT6AZUhs4fMkJiwti8LyDUX4pvzj0
mZGoylgRNu8qaoevk+lCBEUsUHn5NUmAKUUS7Xea+0IFlZJlcErtkahjK11C8mtKulRKpBny4FI2
VPdEYgpyYMmvtVMN2svQC+lYo9Q3iGeFU41IK6ndaVbL7Nk7iP7tZUOYSsxupz0djbsQb3tVm4Z/
jlD3K58cFQ1N6X844BVMTXpVWe+h5Mnp6gDTIs2N7A7otlQ3SU8yuYlctl6eLRGWhJuJYC660tnE
I7UgEDvRe4KxgmDHCvBG2J1YhNxyQ/cxFrzj3DQNtpiJUfsJmW2dYMFTH1WPTToxYskRSmYCOsW3
lleWWArhBEiueFjmt9JFVwbBY4yKk5O7GJv/ftWtcv30jNZpSkZvDoXpXklF16OnJCYUxs1BX7/F
BUm3gWyDxpM8/S4YZNOHC04TDDgpIfzuP5LeGFtrOF5VDddbEEM2rdhhCV013uSpBBxvhDcNDube
IxNbsvlfqc0nUz2EYjMUjxhWSdCRwsBX+7V54wExxYIe8MJoVd7IDtFR0gSSXKp/jEd4JcNvsvn9
cGgG8b2kOSvnxLuiTMIhloqT9x945lVLgd5cW97CcthRYEFtlhz7Aj1IYWB55exY2fcGJTu6DQ2m
uEsfZWAJfvT784UcGQvY+kFwmy7C+8Xyp6CfaJ1j+O4LB0YMjKw8F09OC/Gt7uKS2Ulne7prbS9W
cb/Yp0leNMqD1rxptta5d1f4ZwvnXWYuu2v7dMswVSuGIDLrAa+7ftPCA3Rl0+hV3t3UCX1Vq6bL
ebfMEf2TnN+1ICAuPbyFC7X88GqQyi6VOSTRGWpsfCo4cB4eCrypjGxvTBydnMYlt5PE8BV3+TrD
40Gh8dGDHFkoTnfcB1ZfCDYQa/vHMJsJrovH4ZBvJQOfTZl40mHPWUbBC+EQ8ZYYm+6jhQLE8snN
jMFQJraZSmiLAZtmVRVVnDf5u5fP+9SIKeyZTWu6UfgpsqVQkEBHdV3O0n681MFB3x0dvz949773
/MXRy2fHKuOt4gGpg8tYyd4tRlJ8vPPQbX94WGVvklRXCOKRrHMGcezsJeYMIVN1+I2lI0nMiUI1
Z/gYKlo0jOslm3rx+vkbMwz4JLk9S3ulzOfXwE5NZpg8iW5oFIdJ3pLCI2qhGQWIE/xnUKeDS8Iz
ZOIeou9OMgj6CXBOteD6YkQpim+Nbg7evpARxDADLawecI4YUhBjiWbL8SC4GA3SIB2gMHGSwM+z
2+BhfzF+SPnVkexEycE866NLX6MYH8bDAuutdfjmsjTvguOXAVwobFR++R1SuhnRS6EXCH3CA4l9
6p/ynxXMvYdRNnTKJ2MThSjJJfuKHBALJy+rklDYYokyOYQaD7evRZDVAy1yXp5BCkGfokD988Cm
DMaMKhnPSnrWGOU9kmJVTpYdT9ywEF5BxgouZU4yMU+QiDUiN3iiCoW1oBCOcT1aWlLGkuOgshX8
hkERl12zOnYEHPP+JVBwGCCtal05IqqRZBaWRwfEoAdx9eho3EBw9xY1/qv15EiGS0CoyWg3H++M
W2FAhq7sTMONEPnCPz1pMdR9Jm5c4naqrlwZJ/zE0QXX2CpSONqpRLYyI4TjC4dT4rn5Ut0aEZpF
3lQKoVsLdtpxIaE4aegVeaOsop2kxBGQ9vQRPlB8ZZWsOLt2rTwo3DWZ8/kyiAwWxMzCn6eBx19w
gNGJB1RbqK2sPLQoLnJfkCap5hRfuMUXVnF/jO452mhEMIRgG8aACaFoxPAsDKcJM/iTo6gA3KKR
hdPIYp1G4Ij0UEnmX7qZR0ipa0SF9cKwy/aC0RsjAHhhzZwqC7tKMT631I5/LCaAkEHepBCJ4sbA
XyPim4YyTwIJGaDb0gT3C8mRUW1Gj715cq0zBZvpk7dKw3SLwvxYlk6572ZTloG3+2bi5C1f9OzZ
LDcCbvPT4qb2KYmRt6oDZpckSiZeHwEFw2XxL/+IF9kiGZdnf3Y+L8zPmrbvMFOgXni6koG7+wUS
3S58514NSl9h65CoGYHYZ3HBxAlKeW83eI+JTZ528fbueEWW3AH6nQN5xgQtpXm+hptXxB3sBIht
iXrlhHfjdKuMvc9P6i2gu3nCnCMI/R+21hdz+maPwiU1e5+Eyehas1LOOy9LpagnD08ITdxXVLRy
ZeKiSlWJEfGC1hRBvLU+UbMmQVNBzLA/JtMyTEAIoVeXB6WJmhpRLl0mX1hqQP+uv2QsJOsSiSOz
jzvZmXpJMUOTVKoW1R1uNHxPoBofBf+eRL1vs2x8dJP2AQ/OIzSDvM7ml7D+XYzh2trnQBHCBZDs
wGZQwc1xAiPC18DXziLNa9A6Su9Bre1cTntsbFRQd9JZJFugFTS61A37CfNqe12X7a0SkicWnW7Q
6kf0B/nFNTb862CKhm+wkgsRHJpMrQaj1G8kK9uOSFAV9G/7YxWx28GBeFQ4fWOVhfMJNdSTpcPT
It+GhgIN1NMgDGBQ7ppuvB44YeDE8sc+wQs1BANO5qbReD5NZhi/z91yv/Z5k7OfXxPhbRjyGabj
xonPlToxZkPO3KOtJpmBLGijk9NiFD0pCwVqRooPej28UUeLMRJGrlSG3/uoInt7ijWd7aMAM3jp
G9uiDIRSCl1znfsoAUsohsWYMfFIzOI7Q2KR9BEc888kscAQ0YgyrSTVZpzoGnaIYlJAcOgJQmiu
G9ZD1yip/CivJykwRQO+cMk/p7fCuUzapvESS1fKQoOIuyiNItmLfY+ZhHztamNSYOKSgZnd1zjg
vOrIyPGyhG5Masnghe4QRCHkyKhpTHHoZ2E9Ehx2GmGbf94H+lftg0qPTEvR1dsnMjLzsLv8Z8Wt
yLGM0dB4iPkeQxn0uKtHGnBYVs8qvk3nk1GOp076xIooy+T1h/s6SeAqGxjsPK6IcD44S5X4P7hI
5xznWsR2x22NNxNN2XKnAnli0FuOAiGuUiCUJ7HR6oNI5ns0tAjYnYudSyOAszQSJbpyPSgvCZLE
wuSwAOqbir44WwMLv3SEeCs2/KbSsH8ZrEo7FgGpfkMWWmwzkt5cWCii7SYuho4EjKnYhQyBRGp8
tjGDpIyNbkcKh81wWpBh1OO7rS+4OmoBiDf85hualAESynCA6coILhMYYdchB+Fl3mWQjdG9LZ1A
D2Rn1qDrpxg7l6PkGcZyWLnsAiHwX+f+CMMQwz0Io+AGp34i/SWcCVyyBfCki8ywArZSe/jzgiB6
oY36TvXz09sADVY7rA0ZFC2OhWIhMjrCLEqYp8rpKC7mEim/AGELxr7AUtpgFu8K6VlB0cAAkOmU
y5cFjpM4a0z+XX5juiEWxIyY134wDyKe7nLOwBwbCEwHHFFjZG0txywvv9tPcFCnliyW4qnOc3TV
Xgg000IDdGGvEJo5m87ILBkp1mlPMcMRvS/NLH3C16kI831aFFXLHFtPRc2VayWSZ2GUHpVBixan
pEPF7nP7sbVLZYMUWviviiHoZQhrgxKXZBqvB66xdchWqLtcicxJKMImUvfwKPzwS5i0dVGXQFG0
/nWRCFagMz1igc5M/LWaWRfoXVnanBhTqBkTOL3z+p5/lOb6nYAH4k8MI/BVeE0kSMf0AViZMiO8
W0WiYM/rkSjXFxjVJKowTGCSYm1aRlCoHuoiXIcqsTxEvVjXxs2RxCW82DCdeCMm0jG4UovnsZJg
IFC4VVgj8HkkUadpP2GmmycLW8IMykCiy5yCk3J1Y8WiSVlRjivvOf0ShNV9zp8goLbWOX7rUFeY
/6ZKnhnbDjmxZ7qrMB7uqhDlGEBHVNs1v6EDQIlR4Qnrr4cePVLfE6PnmOSiAkmYYWA3gG0FjVE5
gMcFOPU7pLqA6xdlz6RglYCxK4bPtnXmA0qmu8qtacveeso/InEvnzlR7dTEl6K2lRWoSFwTYe0k
paZeOCYMlySxvYeq3vo3uZlKchFJ98miyFTrOupIkWMQBWGCzR42qOtAT+Xx6PxigSj34SIAMuiK
MS668LGj3EV2DTjcFq9uQu3TfNek9u97b4paxqVpQ4FPFWldp56dp3NvJGXNL5YL1Iy7Qky99B6n
KJKH2u8pWtJ45PVd4FDpReOAFVfAl0+78evRD5h0g+QtOfoOov/4wdsXXyouyrHoqtqJcQM3RTK6
8LjoDQWyuXNk9qMZ+nedkD5KxLztYa5i3IB00IO3I4PrWC92Sp8CZIsJSF8dM25FdilUoUh55Q16
7i3n4zwZppFp6NHP58PSgu1dg5hYrNYOiG3tCW+mHpuIfBPsN9eKjcKGX+f9yMMT0Kqf0PBOzZRS
cvKonoepoMwb/qBGm0J35bZwO/gW54FlaQEH9tc7F4lQdzXRIlTUGyDz3te4jJPvAQ0X8bVPd2bb
blQuh1xvmjvnnqXOCqagLDA4UXPGcNvGvErjbucl60wKYzH5orLYnIdakME8m5WsyMotL+nTapsy
hjkAz2FCOBziet2RQBLx5cmCf9dYfWMMw3A3yTkbVXhqijdk5+odrv2CAxCmMw8fqhxCBAibuaQB
1l3tbKmZ4MZj19DwPRkwnLqES+m4BGrCW4BXfDRbd4ElzCI25DTrMy/0nGXZOBrS4g1P2g7Amlpe
IHaBMcTm0DfNM5zPEpapfNnXm5UMy88efGgfOCTLEYzZBPfpaEoEtY0TPc5JqIFsUlLYWuBYfQxP
mqfBt92g5fZLH552dU+ofBfr5TW4p/UmiAB0WDG+4kHFVk9GM6w99G2q2Elo2biqUIWrxrMpPOlV
R/QwmincsPXuzcuj3ruD1z/jbTDvBCOOqgNEMDmOTZcTilAcYbljpL4wreuLQyzNoR22kYMZ9eHP
7Tht9HO8KoBuU0+ogAXOfBt+f4f22nMgvroi0FXNbgLjfGfTxt+5Cf2EhmJoFt6n0G/bf0+uEhY8
rGpQSW9km9aLezcLXxZATuSyVfP53o0yIyNaVA/3bo6gUTanHu7d3DC5GgG73MivzqlF8xk90CbJ
eboND9/eTDCn6dbd1tuDH4+OicTYphqUPrhxsZgQIX81Sq+FDeC28aWioIbnUG2AvfqyCls7UtO0
jsaKyiLZDKE6c9uldTJWTBSnswKgf3j8lqRywvmvjtHBHuLRevhdwMtov8IzYL0ZTc6NZ4om2Pku
UBK4UGRTtOoM53BL1jE2NSLmPHiI8jx4j/EQ68v5SL2AczupCyU1VzaCkBzMZioUy4/A0QRn6eI6
Tacy9og6GDXFVPCNDJwnZvgLLuBpnM5J57Eijgm2paKZLMZAo/cX4x7RJMKYSwZJNR4x5qbxKAzr
XaJkFVNB+Sq6NIK1g6Ko+XYVkyNCzdrlYFh4t41zJ0SKnBtK/eTvQs2eiBKrfgKSjWRAVLx+sHWW
0WIE2GLXPZE6Q/4sFhBLJsqIJ3/QEOHeQxZbdqoYKobRFAbeEB79ZNoTjXCIxHR6NZoDHiBmnYPB
9CiLhfDpEjLolgE0tATA0bskm4hP7CbetRZgjSCQhTDHVgNe6zEdXVZbgsSlLVsDVGKShCNjUOjf
jr3tyCcZka47wtciFFtkFhevfPbHeuVlBeOVzBiFqQ974qhGgOnFLHwH0wB7KNiQMYjgpygGv0RR
+i6Kb4kErohUfhId/QCoCJHEOwYr8do6tnOMjaBjoRjpZbZDIJ8Mgy3L6yPrZ2OzGvay3WpIcNKE
9jmAVE65MBgVDScw7m9Q3hUXvXYG6dmSfHaAvtQBLoXbvsgrBNQgtYLqfWxly/CQq9dRRDiD1Ujv
bYRljb+Xo3k/j7xPEHOWDW4Rb97OMHaIeWXn2dS9rEUyMBdZUusJKWexOSfRAfdAQTZFHDB8401r
4KDL6aAnpx9h4bJCF2mCOX3CQ07jUseI+qGY1Lp1XlLimZDSMURo+koJMeOV1dG9sY6NzLMxJ9qu
E4SHq2r+tf6cLtw3pNYiiunZ0eu/rVHPnKZZfZrl05GF0/0tvEuH6XyezutvM9jtWzHquXgbrrti
x2kfqILFrW4GyJYCl4VHGq8cvOPF714huLgCeFKDz4AfoGS/nBwOKQMnFcRivsRLpcTQ2xzsMeaZ
haWaJ9OcJPJy1DhrYLzqcJK7O629nf1msxkWI1jKwBac1k0qTUqDOBQGgPU9C6pL5EWdOSMJYEpw
zVBn/9PRwbOwpLNrjDdq5XC1DzweY+vAZ2d/rzjGLNIjLMHFDaNaqBnLqsIIyO5rjtlwgawU/ZGM
3qt1s072TnNnFci9zBgphbLRTQ912AxX7oI9l6H0jJZ2RoxN3Cx2xTDcvx790Hv24l0tKEYa8pIR
ayV19WBalcG1IiZzuSCRtplgY7e5i3FFrOAhlBQlvIvLQINC8eI4FJK1Ly1UEgSfbDOs9qKfZZej
Ev9hpelM2N6VqTCxq0wtHlJ1EQIijGUe4O9CzwGG89rDI092RCryZgMfRmya3w1jn4r0EhEajq0y
xutVtWDWuKaJCHIpV1tVgNshlkaQOfnIdRRgmXSuUviWSKSdOKyeARaSRMj/UL6qElcMgacWkl8p
i/X2hZ98CE0MlITTnpGuOyZbHZCzBLqArH5fjpSEEm7vlBUHXV9cLLsltfpymzaao3HyWtbJI1FA
IMZVOH5lGgnRoxKvnWC/JyFOCEOofW98wXenK4a0Yw1JDCan9RFGqPhzs7GRzopiXsGyXEySPt5u
GGGiNxidp1IRap1ZoHKO3z2vv8d1l5HlAKRIZXQabzQHshUHdhWljVNOIIVt855ussqKBeOaHQkV
Uo2G7BI8GYquOwfmkPD1nmnfxcCpEAHW0JbRh9U8d5z3MqgKYa06abqbJr48Dfb3gDoqM1G3bBll
MI9FlgVjtAsomO9fK3dPIlvoAuOOYqvPpmAUwtB3sqCdUlzlGG1BjRChIpThwCpWktgGeUusNeH0
Zib8CxzGyZm4uLINXyWYghdpGHwT368YrHLTwQSU0yTjrNpebQ627TKa2XLxSdFJLFAfZD2kWn3A
zvKzrPfj0XuX6hJvPZUEpbWcj8ejswbZ+DbggX4YGR3oX6vi724ttg/+PY9WtkUpBAq7xCMBqnwb
gGi8uPhHuILK0hRTmF3+NlV6itk4GbmAItsHQGX1x4q2iUr9houeUB6D0vZITF5sjolbQu9dLsPt
eN2rsZTXjLR8cELXTzNGKXdB/l9op0ck2Br37Mq7tjAixaBICby3wU+4Sqt6DOOtz71cFjgms9H2
xOdMpIzmFc2jlB2+6ScVfup8wxIws0WHMMtKJLV3ot+iuR4tnfWZF3NNp2lpIpIoUxVsgokAVNl4
/TDXbFo6a5YaxwivzVICoXonUJ21zEOvOWXJZpSxe/nFGr7Lvi2iqsoDN77fRNhxY62JCH1YSaKM
oc5vB6ciwauqZB7kBYuS+5BNh+SmdDjiKCqtTdnMj0evj94dvBRR3aRw5m4tQJAqtryscRnS8F6N
I7Bjy2Ttx4rtmvbGHY7S8SDX3rh2dLp4zS5KXHtp7x3X3vVaFNb/wrS/g1E/Kb8v4OMrXCrSIvE+
nmU3DWEB3SV31Stp/48JORGh4RIS9XOVjZdoC7vWEBZjXBYlLkQdDkUsEbJDtaSYRBB9XmhZ2YkL
PrEXzN1aR8QbVXydY0FO2dNkXH7QgTuQiNdhbVh9VT9cjE0Gp+xuw2XQuj8ZyKygRFAEbthqP2o0
4f9a2G6n02KatjzadBlXBh3W7N7jNW48Lw8GJ+psNBj4+a01MVyxl9VIrrBtQk+/BjLTmnv/pEvD
2XNkjMnIdkaLfhf+IviFd+QkhAkAN0saoFYt2GsSkShK+OORbhbvvmxzmubmSFeLu3jNex/gbj6i
Q8i2DpSpi0ZdC+Q0f5dT5PnF692i64olXabh7Zvj96WsBoBzPsOUwFGI5UJP9Q/r1f7gqwy45uj9
0Tr1uaTbhC4gktuli4ts8LnYn9HM9g8zEMZqCQQp83Qo1MGtX9gcGeBoabZLYVMMKMsp7QFaorDa
lZLKbwzAFEpByB6MZNd3awjf2asN1pswBIEHR0/w43p2SViNA2UF9lZmBahrgbh+98JYaHW3VPBz
dJcty6a5mfTZ6NhjX72x6LfiFvjIodARgO6kjupjeJwu6kL637GG3EOkF1Kos7v7rtMk3VaR7f0T
K2e8hKi5mGfFvftX4fWqyiJLiBwkecKR6p1jyi3nc0AIKuyewaPNrnsXcKt6Ba3r3/miA5UQBCUH
1/Nseh6Wxoen5C+YMJVUCCVMpcrLYs8Ho+HxXMruMQPCKjsgI3X4xmLekgDbHncwf2vCPQxNYZVr
mJhBnaMKYzoZ9qKiVMih5Rd271NwX7AWkZjD0uQKqyG6ItkCEmsez6jVREfVxCqOw3pzrsDrnjOs
KMN1TnHSWTFJ44pI/Gh7/el9KJ0deyJ+mSneH1HNhQllwwruYR1r7d9HWEp/4HgO5hvhbLlGbghz
8mud3Y1OIeWXAkpIhBf04KOvC1L2gGQnnUCGySBVQlAqYq/YOpn/qWLfqvesZL9oodCGz7dUhdKo
MKf4bDbJOv19mQHCnBm+8mQ5wXp2lJFK7Tz8PL3naV6M821pWeSHWbavFHKNHpclq00zcb1zXcJX
BYX2p8v0tvrmUU7mOVO6kZJoIWaTUg2+M2nYQtZBfXZs8xJjgIcfjt+/edU7PHr3Pr5P4E7qAwe/
soufj/5Wxh5aciZKfNAAFiPCtk2rrbCydrVYc5XntXm1Qrf10YRww4aBP1Tcj3zJijM2nz1Rzxx9
Dzgoiv8hv+o3lAfnImnv7euq/Hh6d99bvMyidxOp370pATxH85RBdVF2ebC2pofZRqb5cg6UNcyG
kpNhfEHzNHnF7CLwMABinihFf1kSwn9jmDPW6bOQb/+sPVaW3pWXO8oAtQ14xVVf1ErjHOvSkt+M
NRfJlzMyH0Xvkofxd6jJI4tPJXTuwC0oR/npeyVbWmOTcNY+PwavkOJ+RKuwj2U3CCOefPkKG/EX
RhNgYShgq2qjISMVFMMsfCIxSYJlQx+0rW8w67VSp5RlOFOyHqIQMEa0txxHQ/DmmKOLd90kc0ql
RJxWrjRQ5m0s/tZEp3E54yPG3jXURrREunc5QHqNP3TmKAwsu84W6wGKToocvNloXM5FiUlbQ0C3
sm+++Qb3Df/8k1AkQ0cdPTDUat/rdr4Ump+r2IIJMVOlnvuXol2G7E6bouWchHA6QjNI7zpmA7Jw
xAeyJtpsd06lx4ZY6xIxn38ISK+v1z+VrOjc3/EnGBdvoNi4r0JDdCFj+27U/q6vfcm1PPwNw8V4
O3NC1W7U5876c4qM2F7rSeCLHe412yUdqsr/zT66DBY+E20SqwqrSPRqT85dYVBf+2Tlo0H3Qf5d
8Bbul+72d8FPcIO9mY5vvwuOgac8hqPcZe+N74JXyU394DztPhhQrDenB5+BWx/zoYTQFLp7cARl
6YnCCuqCGoaF56yDUSL0TtE3Q0gRjZALhXIlO9p+Yp0FtJKcJNNbEeE9oAHAeizmcHucJxgkKEG+
wtlyyXQHXYcNVdy4JzWeksG6ldTN4KlUYtmtwteUGT3LrMiu/Fn+YOOuajHzSruu8saxTf0+XIwm
QC7VgYBL4OZAO5vYk3QPN9M0lXfCWPiwXfH+kytz0tlpUxbosB56r0PW6Ogr0BvjvxSKZM42GDHB
smtHvi5gfVKuD2cMoTStVuBJPhmSJnM9ScQqO7Em3FV2w/mYGyQiKjEkaUGU3YB/i1bK593tKbAI
axEShnlcsVdpGWdaGNohkVaaGK2n5BJrCKsXu4pzR01ZifrCMHyZZbOzpH9ZJye9dDqYZdAAzmBA
iRm1py26p1PcNkzUmGMOR/Lhy6ZAw02Fa/9ns5Qps5IZzVZZxHyS3csn2Lx4NdFmMGsS4RqoWmaq
APCm7BySB6CQjIY4UuXfUqGcS6W49i1Ab4XpO8bOjk86+7te8SsPTS3scoYrylnjSsjKQuIDbmKy
zCkW/3KGvXryzknSRletKdqtFqCt/sYkzr3sBmQIe7YzkiksPNvVDXg5fLxQCKDk80AsRR4yp5pM
1EejcLL48bqvQBMqLGIx+nwhsnBJeHkOh+gijwLOSDxooxTU/dBdVCNwTO8CzBfhunBkVh6F/0Dz
BtC8kX6sGrRVnE9h627H+fz3B3wev7DeNU6A65RK34UEi0Dy8lRnotbayossJ8VSDvw+vxGkLRrB
UlIhis0YmhTFRtqeQvKXWqBSq7NKI6V3RgBlaU27YUeUKF7oXnghhfF4LbCTyMtngin5gE7D9+pw
ProKhSRQSN9sGeDsWgSmcFgeL03H21YLOG70NcftvjbS1tc4FJ6hGSQiVre6HsOMo5Yw5IGe2aU9
ZixdPXAe8CUP+HKNAdOy+YFbxX2TEiCUexUlT75sN0WFA9ZlMRQA2sInfjJdA5w8YMoUMclTXx5V
0bGeXHozyheUltuPwUVDHMM9Xy8hmJstgy8Y1dNpeeYMGxkAisWcgrj82rXJwiYECSW1EV0LibDC
HhFNxwzlTR+YkqPl9mS5u6ZggvMJ8Gv/SMUAIjlCOasutuy5kC/FBHozRbMXYXnLL9PuUTrFnohd
G+XXvCAAtF4Z5nWJCuFaC7R76ZRzXGp/BHgzv50t8Ox6snCORIDDDZoOQ+/oLiuawPWoGNll1ch6
a7fsGVg6HKou4XfKsaLEFuN6e/0dML3YcHhSSOtwWpWiajUfLBKFm9LfsiQT0L3fRJwioQEcyzlg
wTUkMeWaCG6nTmdDBWbHpZU0Dd7H9IIu5hWeaoaEgLPkAM7IdDptnvnargxzV/lUhlLJCRrpvEpE
09sIyRBaYMhJBgMXLSijSzqw5m3ULcEBaPW/tbFiaZWB4D22Gmaz3k5Xq4Q3NrksUadibCncO7pN
Wp3PfFXcFz/rzSf7W7H7OE6OT+YDA5vw6dKjCxwwnnUpOk2WdOUM/j0ACFfED0GYxniULfOuXKh1
kYXOInfN13aPNZiDUKa+kirNzw+Jwg1lLWCU7pqTTF8jYq732Jt7rD13babQEBD5ec/qhppLm2Zm
ZWkFwewhlte3ptz8DtBInCPxVGmJXFtGkkT7Pzmqok/bXhyGwMzC9t0zxBVWjTjWrjP0+N8Ei4uA
Cu7o8HB7eZhSHrW0hustoU8GLgvHMzLQdQmJjc1j2c66PhOqG8dLQpA/+M1klwgC1AvNlH468Ais
LKDHhxeqoUcg4JNLUygjwd9Yf5O7vIxP/6XoeI01rpJbWoZ5t9lSZlsbpON0kQbwZh5gsuOkT8lP
wrj6PjDhId5aH3Y+w+ara6Fi+/9F14KoI2LTfpmcPMdH7345+vwJePA2O1uOxoPeHLPcTDgGUW8w
mpuhIuU7kiKLn3CCnh28P8DAh1QmyxsYIRg+5aoNIVvoSbeILXYxvaFw2MgL/pDdqMKxDicM3xlw
j/HJaA7qGsVMyZEMwn2Af40aRrRtldbiRoUT55DdYhmybAHXXzITKYvNIrEKcP4ckwMFsFgcxRGo
NqIFOiLfT/CQKj8MhvNsEoig1QfPXr143Xt7cHz865t3z3DlEjie0wGUkFhHKUhVoAVpN12w4DJM
OekKKYmUbXdqaFGl1fKAZEILaER2rL7ozmbXpZmHWm1zKxTtobxR1A95ExWPfJjf5ot0ElYRCaoZ
uuT0k4eyDtUWiqmWzMkTwtMwWw8x7vwoGdepq7pHBDsccHUjhCc8ven9+u7N65d/C/7gp8N3Rwfv
5cP7dx9eH9aCZrbfbDoZ/eD7cEBNDQcYudsfCnR4IVZuhilBwt9MbRPGnRbRvSOZNonNciQ0UkcF
oKtxBmPMr0nxqpn/COAcsc6IEmEF0jSC3M3FWelPBj0KvB0ZYbALBwvpGwu38JChwXM0Z4bdfQk/
8QpDzu1lepWOI3iZLDAeMxeqlQfrwcDcY6yDbJls88Xr529iiWcqzvOW5F5gjM9kfgJPER1nXXrn
8K/L9NZKJoD5BNM8G8MdCW/NGP8qtD/HQEbDZYzCz6HOjfj+1XnA+O0qyEXzhTpTZ1zNglTdxn3g
dU1YVXCqLSm2hGk9YufZLFqdycFI4lBc/669ETKZg/GbO5SJBt5L83mKL03B4qPo5Yvj90evAUc+
e1cLxMPbN+hUVQxzbzTX4LSGPTbJz03PAG3U3+WyEgHBwPTq9Bd49+X5uHF8/JKCEN4sInx8++7N
+zeHb172ML4N3fXvYrNWAyB4NFlOjID1WA1K/8Iv8OdVq9e2KuGpobVCWQPASgGGdR/CmQDtuxaU
beIG9hHODr+JzM81GXMf7Xwcn52C9r8/shIm+HMlIAKjzyEHAccUv6jQJvv8kUBQteD4p4N6e2+f
4+obGRBUNvH+6CTMkylcl8RE0aNy5fKzBljGcuiiSsKJq5BQd41sDohcjQODZ6X8vAoNcExnCagl
DJCP0CxD5JeerhA3JHeye+A7cfAxLydp/cuyd7LkZol50LEkB1nuhvwU2gk8jRaVk4nO04LZMCP0
/lpOakGPUsoYS6K3FoskY7xpMAnuCC6eGqXZpBCUrN4PuBkDnEpGb7u+lKQbZeqEem3wn0g8Hb/4
8f3Ru1c1HnxcWfDF6/dWOT0hw/oNJoU+CildBXA6H+Sd7W3458FgG4B5EEgtY02g+YCCZSGJiMms
axXB7Mo3WiGuAharEVdpX5xaz+mKWEJBPU4wNATzviUhvvQHcSmZh11sCWKGHmbwvVIWOMMRLOXY
KMqWKDLDamx5ScNFHmTLBaZXxiZuZQLmPAuuUwATTFwLBA6aFwITwvGT8zHc9L6BzHsUcSZyKK4+
I150Us6XsxkGx5EH2znMWS44X+PyVKSl11vMB/nS7U27lNHWo4XkdXoWfHjxHfJJdA5gms8Qyc4D
USm3DSnDQhbdR3smc9MUBBrmikvGFGonEuYk3V3NxRzqEDyUXH2U6y4e5iQRwJHxIgaE/RGhEiwG
M3iFgwLsQfDOFh+xYmEYqZHVP8JpEVRKMKNkJx3EOF8HMVr9qjj5Mpg7Cdj1YMoi5ivUjUyYaKwr
T6DvEmdaWzltCbiK7JubNeCocBJWcHZWJCwizH9EHidsGT28e6/fvD5ytxsHIwI7Neiy1FtpG71a
+ECCgPhbk0egC71bzLHb/H1al0wCJ1i/GiXMKswtmzPKTS4sSzRcHuSXFmgJAFxI3Qh9JAvBaJ4u
MUXOCE6IRBEsfoobJG8kkppqk63wFTCIaACloHRTiDRI602AUpL3BZishEQ3Hrk1WDzU0KLviO8b
zCV+aAiUI+Kg1bzRrVhp0TXSfnxc02KPN/GTnArULcQGyR2GiLsyPYAwFu9+tEN4d4JCIiOcrMea
XIRwvzPxaI6sCS0X0BYqSYmRpb4YyxsKif1E3HIWfrwLnZU3b571qEd301n0i+mzMNwkoqLd5g4J
jXFAwvaJzQ0IT2nr8/I2xbPRbk1EBld8Pce4Nhn7VdBXBnM/HjHIyajZuhxZ/xdX3Jhqu9lcuZ6F
Y0PNavQ6m6MVccjd3xJtkwkzuXA5la8t/Nc0C7W+jCj38OWLDjK7X0aa20OwFAZXtImos84mMynD
JJkYy1j4q2EDtBiQpMdNhyHgP7/NG1SEIH8MtEJUoEYIMufCS/K3uRJTVfTKo/N0i31CJSzYEH8j
LowSMDjyuvczT9GQRMjziVUQyTaUwZw5eb+LyhI5PoxfwKrXCYZsLBJgyZZ70MyNQOMG8yx5FgKt
J4AfKF1+qZLwLP+aSy172Gipw+PXr95e7ZB1R9K/RZblS685dHH/5R5OgNgA1u1Kr/RVMXS9qBhG
I0AAwErHSuxu5GG4YgPa4h6EtynzYlcCjUyzkvrIDnrq10IpBZhHN+zQfoN6yKtYOA+as8NCV5qa
QmzWWyARE82za9hYcRmKbq5Hg8UFBWCaJDcRc4Dz6AK1+t+ox/nJ6DTmfikJMzYUxxzp/1qwl0ZV
mbD5wk7YLDs+NdFsEBhzu4gb478v4RLgUWGvK9oScja3MViS4JvgmipfY01uUJS25mEQ8p4R9ctH
1LdHNMexiEUXBlh4kHqLTFpUGedZ2/zfqRHh2asRi48aZjbQ7YlghcLKIYiUFwD9pTfaH0CzP5Hj
G2A8ldpKRKYHgfxJbZmmIIbNRRBpjwHShTvuAxU9KV8C/kFtCUcC6VHAc7McBdQDf3P8BozHip69
7gXyWfdpORzQg/7G/gemM8Kq/siEvma5IRin/IpRooF7GRRs+weJmPxxQRigTgB60OD3qgSlszeH
B5OL6srd49QUUhfbEbF51mxIk1aW64Q6LLhxCAfRXONg2w8H502tFFFjEPx68O71i9c/djg3mVRN
kRhkORNiBpINf4c6KhIxAfeXITmLyh7KVFV06YnLR0J8IjkseKr5RoidUzcnVtlTc00wibVYD6Jm
TQ7YR1D/q3jPFaxkq7mKrPfFxK8ZHNq/C/flkKcevgqYDW2odE+OTTNQsFv3UYtK+8Ayff7h+zfv
DIddNrrAzJ5QEc0KoUdyX6Z3zjHH91BM5pvfkkcCyhLrmF9k16aEqzpxBxJ02BtuiaP8oIvXkCRA
S+i/PECTnnaNAusgJZr7wmQqEaZzjZ8Ipe+pqYKXBlx2JhDfaODYPqi3m7lwkMT8rIpWJBcgrVO+
PDWNHGX3MvCTt387Wci9+leBpUoG4NS3rDLJswL9SJyGDKYOSpwqanVBvhieSUr9wGnAEVeQCHQc
pGJ7+j4fqtL5t/ZznEUbZyHmkWuj6lwb5Kv7Rrhj6euHp/DsxfHBDy+Pnm3iNhhywm+iaLqUElyu
PwbKcmid01j0XPigwsgUV4+MdApLJ0x3nHVbqnXzBmdyF40Xa2l74S5lAIm4gOKahcON58043LR3
aV9a+AsaVQd3s08UEUsKsGoOvMeetKwyQJdwYStNnCwmClDxOA9ED12Y9K6G9Ad5QwILDvgyNo7O
1UkLAyFg9p7ihnCjEuC4MTmJhmXVjDm4+YMUI6vAORhpJKgrA6A6Md/bxgshVwnX2QRAyOsjWJpt
j1kIgdnhp5mStmHz11BB+7Qbcfp0bD68N7A5UQrhDyqdrmTJl9PLKaqDsO6DOW5EGjzEYB8IVQ+J
GJLjc3fBwnLYGRG16yxWbi3Wxqshi1hh+xolkfvJws0jNCsDC08+tuvyDHm+FfVAFe5OAbDoNBWG
H0RUlvxlYjfARHkcQdccvNT+1onfZxx9n8ndR30bdYITM8ygGwFXnMzifJazARqshSuIga/x5gp+
Pvpb8MvByw9HwYn+2Wg0TgNMaDlLRnNCaEjXy9iNyTzlZJ0YgRSJfbIpwS5joEbhXF6kc40cxwkS
UycShE7htqDog/SCokVSkptTC+AQ42PNGE5De+WRUlk79Qx44FHaOG/QNMURbkhzmWAbKVcOc92Y
pROrAEK6/n6J303AOLvt6RCcRq5UE1f/A7gCnMBJs9Npo/MX/m7h70KCG/MsXpYdwo3QEpbA9oik
WufI3h9VOe5lemlMT2ua48e72ObBratTxCrF2AO6Ce9NtyIKqT8C6bqHUwTXLDmaGwfOrHDKv8fM
h+LGQekmVSonAfCah541aUi3PZpYltwh6xN/yLQvkksYMjtHC9PWRNs7SEuLmEhOMWI7MZ+H8iu9
u5bAvS4k2qx7ILgCSZuBrr4ograws42ZC2QQ3TQWfi6/t4XWeB2Iwnu6T1EiQoRS54iTNBrw8GkB
pDAnuy2vdXiQWtDyUJvVbvLlXvKcWfCEnOVZnHl6yrxBJpzlURRYHkybKlqiSa61E1ZlCaGYmVc7
aFf2IN8Wp0I3xf6DNaNxEl5ab0g4WZLJJrUEcGXdt/v+eIFCaETd4AiXg9m2fXSNUVDwJrLRRIFZ
qJfEEPJKzqqG7hRUzBctoWzIcjg4BJFE2FowFqXjGEQEST0IQ5iuuDsx+rL4ghI4G0BSYJbnk2kt
MDhZP7hQxAOH0cVhr0BjhhlGyPaR8pDiG/mzJuM1BOGrF8fHL17/uJI3hgoEMOjNtJ2EdyRo8seD
qJXEiViFgqtZ7JrWpHl4/GnmrrpH+XUSfo1Tf33w6gj/0sLjj5+Eocvhm9evjw7fv3jzGp+Ojw7f
sdgSLa3h/RG5xLx98xJlCacraE8DVzmSMjovKrjMjVboubydG2nmxhdphohMfF0ZXUaEP8zXIorw
RDFCx3YHQBgplq0Y0ZVOdFcCMcFvLxtGeexDeVZN0tx2jRhXSgck1VyGSuqeQaO2ygNCWYocqaOx
RGBSDa5+rw6QxYIgXJLfvOioarYbhfZyh7r1CVG94iINhuCI+1NKfzmyJlNAmQsnWNf5m4KG4YWq
MzOJQGIxxyZaQ6blhB9TVvyAybuiyIzt0vOT2amRP0iEZ6cvRCd2oflYatDj9Q8zOpqVhHCr0vz6
9HXqBpDPjOcD41DX+Cd+WE8CcexQYtsBmmQIE3KX9b9vLBfXTGVDTuTzRVwRQAItIZrKla4tMpvT
LW2wzWkxAfDm+/y5d8kMumKAyDphV1jVY71biyGq3viaGY7F7EJYD90PMNaIpGLMfi1X/nvGURHw
JcRNAgnpAa0PTsITvbO1KmxKyS277tK5gVD86+SdJFeVkywZR9UcKViWo00m1xviyqqD6KnuSO6D
9AuaDI/HvEH5WoTPqY/iESP4/HTPHBmeZuHmpAmWdnpfjvJ+cdfExj4/ePHSUqdZAdZKdGqFuGsl
CWRoGVplTNZiNPWlal4nWhtq3DlKWuXk3vwcuLpC8vt7MCDDc/41qdIeQi/ocoMK0Pw2FwU+i326
2TRaOF4n81T0KJga+j3Jvel5yrnXijUv2/IHK1aAbcJLLsh5vyixQuq6s6ZgxuLETk7K9JLsFIL2
JkMycQgf/K3+YFJ/QI79Izrn/WRMn5YiRCn7rVOC5jg+rdg0pUT1Bko4Rdbww/HROyQo3715Sdwh
+TZvxugVacNSCuCtvPpxZAbKLU2b8aU0Rl51kIrMYI1JEKMiaNCmyqFimAancQrWYPSwHtUnhDea
9Csb8qcRf6Ub+Tq91nTc5ptJpmRqjBttMVxvF+jwpD2dhPaZWoJ2t+39LtdFb1VFjFqxS6XBo9YD
CDs+k9vXBqSdjNAkNBaRitKkAaBmG8LAgIldvzqtJPoM6WDFpn4a8Vdc6PuspRvuqHw1KwnADSfs
Xg1OlmxJ3JHf1zpB9H3ZIaluZfR8VuMBnamEZK5crejVfFocJH1TVKYc7aV6o4Uj2N/qkRdJyiCS
yZvTQSewkBaXNMUa3IvgUYDOM3DY1QgtHAv+klZD9CDi9as9kA6Ulm0xNFZqXWz6fKFqc5QUdLam
VWSFyo7dMIEg4+wBSgFQNmjts8beg2jLow2G8auPLC0cRWMMROfIvAeuSxxKgt+/fyvZPJoU5pkd
AcYTnjRQ0HsMWpajemmAGAwVMk3O054KRNNlG+ryYBj+VAyrt9mbacR77jfflzWyLpgbRcXiVfev
NJ/V+S6ctHi1YKP8db4d9+bk23SHC7EJPPEJCliRpL2uSR1cVhNEJiw896vElXUaGae18N+24G2Q
8dnFf5UMdmLojSYGlzFRsnj6zWLftcyquIm1tLMcMd5VaniY/XI9ho1/Y48XBGkxnJDvUrCs8abn
EnANUxVSDTQ+Dr8IOqfhGWsNPOaMpIhFU39D4e9by4iqmnH81YRqaF9kLS6lIdCiKs9a5gtFhUKb
ES3tQgvnUS6P1Kl8p/UGbIhdPACfgPe8uE8dLAwk04NxRmWyN7VmfA5hmfKLbGFf9/4KHi3cJstY
ihB8SOEexvAYH3hDW3ixtebWIckn/ZPdw7SQ9lRm4dWoNIq4pgJF6VYuBKp4ua7ErUoldL2WTkhp
c+bI7kStWlHteE16R2F8/a3XrENi1J0BWckjBv2LpTmisVCelNgXxLhwIcjtXORXHf9484UaVOl4
flsI5HVCXRuJ22a8OIzZeYFDfQnP7pP2iHSD49H0UjZBNIMQKWLDUqtOZWpUYpaSvl12r73/RBP6
hTKMWKlxkTY7J2q+3unWq+b77M2vr33zXWN+9eLU6mvPbcsnZHK3+3SrSG0FD/SljUWVSE4cQIZm
nj8BoP4kdcUWUHotHTDMimnsQLE98cfLF69/JvOGt0ds0GDi0ko6oM55Kr8YqavI3HlK7q+rKV0h
4vERuIKcNEjGtalEKPRFaELlvXeRUrzaUJrNIfU9SPM+0KTIzodC+E3lpPkEW/XIIy6XPNwqJeY7
BGYoFhOgNtcp9JQMWvwUVx3CP6nIpQEfxhmjUdRsT814E4gxyccKu5cif/5ZaMV7sOhK8sHvdZvr
WzCssDvwk/g7Gi2YRgyFOdEXbxNAw/H2M825jv0lHVaHLyEtHPnK5jB2Fj6hkI0PI/4S5+98ns74
QojjFYRMWkG9lA5uMc7rpEHRjbvsh+GL50br/RhiSO46xuWjFH9lMRWPj14+72H0LLzu+0v4MoHS
57zJ0pw+jNnkDbgIGUbSRJxiA1TMVrmTq4vnyTRQxSOjV/gQegxU0CHbbFR4vxgT9UEGg26ge9LM
kjQphv7c7sVNY3VOi4vEpVxOitedU1DjuDKQp46EV7A1ilTQTQymnOdL4YCPgTnZTql3lmKIQPnE
sTdRhJjc5nC/DNmEioNwVnmOtSyvSisO6CVzUEZQDnopAnMw6uVixjUzFkviXXWc+2iIIaZY9CkD
Ld+miyAaEfulQ2sDop1SsDIRg4xj+a11iOmcTBzJq3YSZ8sMCuIazs/8jt+0TegmYvh+lzVFZval
LVHUmJKGEA4oUytMDlg6Pmx0vswDKcdSk23FHkt46RFhOIl81Meio05yLdBnuBwHHH44fv/mlcAC
a2p/Q+FJs7rZn4/+ZjpNrBTnG/u5hhZEme3LM9ShdTYD2ZqHRn61QtjKo6OqinC2RZt/Hpewt7Ji
7cILPI3xb1Mddfe3qYxkacWkxCroYHVLB9HOIa6OpBiJDs5bmJVnIvxKYwX1SgXoXfM8zdNzKyxa
H49Pj/OlpdN8OU97iHV7jHXNTS+5njyotYYYsO8GRHbQZt8MfbwW6NDQCauUpaeXt0J6HRhXR2Di
K9ZlbryX3sjKTojkNXaAoax+1SoGpuNPvauWw28QakKyXSUfBepknPSlupIfZP6Ncl8wdP/qZxNg
X9CBhWM0lPXJkdGd7sywKGEYvqC6QRJctTAWpgrsS+IfIPXGyYgCaypVah5jKuuMVllkg4S9uWoL
wJLRKDVS5lGsF+TjqmUGxoiGOjatpryl4uvKSC7jWTA470JphHOz54WwoO97jHAOs6cDYDgffRTY
RaIUODqXo9mM0kw0axIqcP2H5B5v3OvTbErmIMW6W1YaHNoR56ZzJNKWyxCuA0kbKUoJoLfQXQjV
hJFXwK6BTdoe8YUSJ83T6KpVeO0JFhGttAsvJtiligNvBl0ndASy75Z3PrzDsQ2QyjEXZeBmnPIs
iDeWRHmC04EuZc5cMlkfi1Z/ZRaEd8UgE7i4ZTEmvEl7McN7ka8ikkPA5Lc+oyuvkZs/dy46V+af
nt67EGhrHWpFAkV+57FQziszXhfNVZzyPYz27SO5PZlm8hO72qmnL88O3C+XrwMl0v0qv/YIodHk
ydAuKLGCPTxJ+ihQ4EGwqUg0nJYlrXHuaH25lTlgyp6QHlMILhSQiFF0+dedFQBPU2YyenyUogJb
AjC8Vtmo8aouoM5Y3QUKWUtBkwh1VoiXhwKhDmJ/u6S8GNSQ6jLZEZnc8d1FjtZkbQKL/9AJqvql
UmK9fF5/f3T8/ssEUuUcN+MhWrdaETyZBFhORwv8xNlBWAgoOQegHBH0VECv5CzHv1GvhyRNryf2
BiWS9B1YKOSamjVqSATXh7ZzN9kLi+/IOlsii3w5QgMBNZ6GwNzv4ffLDGNxwXDyfoY6SapHhA5G
7epSO71vGrNbtDPKZizapeRfVFJuYm42/x6oG2z73XIKV2YEzZ5l+Whx220r3Qm/S4WSKsY0ExEN
sxhqFxpvXCf58bLfT/N8uBxH8ReNvfvq4MXrL5lFbZbMcx3njXTDsCT0tnEwP19ikoW3XAZwP1B2
OokEoQwlN+6GP70NKHra4x/xYsozEbRCSJiV0Fim1yE7z0R0EYX1unaik6hKvxG/uuEDGkacBxQW
SWehKGuVHOuobdxho21Cnr0F8D4KLjFArGgBHnhl8gjmCBgSDhfhy9+Xo3k6MHgmKEk1xEKGJD+h
sHLjWTfEvGsybYK7BG5Nju+sqmKGBYA5JZgx8hsAX3ONtsNlI2AcYA0Cd3tRR/cA6yjaNfV6c0VC
s4EKUbklc0DhBehUhbeqGutelGkDhTjXGSQEdxNgQGAxjn5OGXzGJUvPMeL8y0+x+HJ7/ujxKseC
D0EyHqPHAd49OXl8Y+KqQPq6SiFXESJFWPZSkHE6prhVsmMU24mMIDL2ybaKE0JRG+gaMjUvpTM6
TxfOnnC8GJoRsF0YhUV2YhP1/pmh2Kh8+YzOhGmvXLtOdUgbMRIzHow1mqC1t3pAzheKxIGO9oio
u+E3pXtlWxpX7VpFXRVvet0tLwmeodaPkqMj1A9KgzNtKaLd3QjWlzmnSpGU4ggLC4bSk8NRFH2I
y+6NXCc0UOSeM+VfPg7Jq7nl/LqXzVAkD+CgM1H6F166IfcvshHcp12hsGLDilidYV4zKhxIjYE0
d5IcJNWJK/pCx+i6kGry8phu3dwTOUJ+ePaW7yxklegN28/prlv7LVMy7ukruUrrykdc9Gb5jXN/
t0Cq/AG0asfqB0t6AsmyMWbRV9DTvWTkuBfKhvOHSIbzRyACiVe2wAxgnRlAHr/FE9rDX7NRzUeK
fcU87IN1h2S4n1tgwSmViJJfryEzcrQ4pnglkaIF0zixeePiIsGQ7hyA7gwOMAceHgTRw4esoc6r
YcB1by+BSH3nGkDpXsQGdHSCHQWIMcy43V/dhwgpbXQg3ujWr3Z4CaMfj1ut5vu3HTbHrZ4iMlt1
tu20WhfRDazW8R3cHxeJNfrJYA/+Zdks/IBbhABqmq7YwdGVr18RSMHqV2QD6GA51fV3gZgmjiER
ULyq0zUumFLljSDE0mQglGyUVI1oImquEwD1rNOcGmtmvAV0dNXuB8TbExmFPM7teoOuutk0aaGi
+BH0FzzCS3YCbu/PsSjF9A3GAgURFkGaUeBBSqykloaywC0u4vUGW7kY1aO11sg75iiFAhhsLkdb
loTzoVk7aY4SLQp4pJPlYolmPL30pj9e5uibez7Plmb06/PClFRY9aptBRqMU6YJiqKqQR1fvaJF
TC5I+RXJA8zbMvoNw+3vKKYL3XEugRWF2CJLHXWVnWBVPcLSJlFWMaUh8ghnSf8yELoPedeXCCZL
exMwtiFwaQBjiOogNi5CjgQnA97KaTZ0d6wk2XyfjA1xCDnTgs7TG/nSrezObdNm5JwmhUvZ6jkU
q1r8L6ZoHE2RCE4GNZWwMULjRMSpD2HrH8ZV3Sj24y8EhBz5lyMEMN27zIvku3XFCuJdiQBYEin6
XBIRv8zvQcQvy6l4ij0ngxqE7Psqdskgyaljqw3b285dD52EowLRCudHSdWjU/OxMXy28pM+y/Gn
XrqffP9pKFpuAoHGUpTx0hZzgXxxwpwFuzotZ9uGI6HbvIVS3Y+i4cXtLCWbPn8LC1bCy32wHR+9
/KzwFLKEGJhylOXoJiOWl0sQZLAnUwIj6j5kC9Fc5umjhUAbp+llLWBL6HusxmpJjYcZya+qb4RF
clbPU5gTCjFlJsGyUdd0wPbqdalbLAwdBAETBl8hBCmqPHAlQ9jBen4dPA4+zLDfRhBuEE+eA/wI
yUGHKMhFOpVXnbU1PonUZ4dMB3mXrZMDiA4QBcL6dY0xFvtgy1NbqIZpnuEP57yAX/NRafMAP5hH
Rc9T3wt7zbIqaLDqFyMpU1Pr0ODecH5xsupEoalhI1M+N8uAi9uTIaSDb6X5G0aUJRs1y+4menv0
KqDc6+x+RcZ2iLiUbakwbPPPkW1VV4j4PKNlcyclr1YWRIJZ8toIlc/f1HByi6MqK5iSAaPmq3T3
hW1HNQYRhYwzxjIG3AFkerJhMEnn56gRtRRNyUwY/kxgH1CTd9Ul83KhowFKRGVkkeqbBv2goGBU
gdsDUgdbb5wl+ajP1jMRe0PIL8+Ofvjwo18PFskyL14/f6OK9CcDYfOLag6Rf00UFOmQKkwYh2iW
sEAtTpL3URwU58EDHhKRHfgEZzoHWimWR8/y1PAPo+Pzj2B1KHx2YqO5TQi1S2kbZnrRinEInUvF
UEzNbGlDUvLjs+gtqLsq4z+YraJ2pnRkKv2PmUjIsLUquK5s7rYiemubPTgO1p+7F+Uls7UFq9Ej
V4lej1aj18OD1euJJcGmUNkW0XEDuuhP//nv8/6XzGbbKKAbjxZpY3b7Rfpown/7u7v0F/5z/u63
m49af2o+au7stHdb+/i+1Xy00/5T0PxnLMASRflB8H/X/Q/DUG5/UEcybgIECFJMaBKVTvu39eE8
ZWEaSTg5n3sQ/Xj0HtP7vP/hw8ufg+tkfInuMu/jxtbWm+n4NrhGISXJahRbPQVaHAjcH47esTFq
uj1I8Y8tsIMuxC1T48t5AbQOVN/ifBlI02EqxKmIJR8QDsobwQtUZGYzIE3ORjCZWzQ0AjKifwmU
SXKe4L0OI1iQ0J1C8UHbpG9vbKHd7JYgQ2AZ5ossG+fyxRy6yibyKc+gwcXWVq+HXgpo8X0SHkOL
h7Qq5D0JT0cyagg+vNcWejjGc/ZOeQPsyOIYyNgpRSo+zJY4/p228bC/a8ukwh+T5XnKRbDR96P+
JdkAviGz9xckRHgxOxgM5rCA5OL5pnf84fCn3psf/tfR4XvzzYvXx+8PXh+SA+jR62e9N897r178
4PTHu9QT28ERw603p4DA+2Ng4wM16+iIbhC4ObSdM+5rnQiJYAiU+XIOBAxtW13Eh1H2B9DolBxE
x0iNwM4hmXYbk2Wz2ZVY00h1qzt7nXGlRvAr6vAlTCXAWGXTcy2aD5JxngF5lF3mQPldpiQrFR0d
vXv35l0PVuj9h2M0OG1ibPNM7moLngBEfiBdYZs+HS/7F6+ZedyBF2fJ4BehG9/tBCRFx0MBj3sd
zN6Et6pH3rhPbR2Q9RKUfQSPNGjKSl8LHsvnl+n0nJQ4T+SbI2HcjaNrypdiCIVuWi3q5xDN7liR
1cJZjKZoGQQ0MGyBHH1rh4bPcSU/TJMr2D4hgm7hzHA1R4vn8BY1dsWecLpLOD+yRNDCOaLYNJuP
/kHdq1V9RKNa/Ar8r+zisTMsWuI7Muaqf87/CKsMRGYRAWa998n5eSpspRcJ6gI4NaPUpfd6I4Cj
Xi9C6lHkMonNRFPjocjx0+WPZtX0d1Uxw5xBxTyQOCQqQclF6YlLsqWt0XqXm2gUOrkA1Cu6KbaP
HyP61oDZ1YwW49hsBA7TvLSR8EEePZhzaBM94Iak6KxW1QEWWDASKxybS9y8abZVQQNHlhXe1YUF
Eiwrua/7lyiypOhuUxVVaLmsaEsVFci5rKCelULdZUV33O73d8uK6kn1FN51ynpAldg5A1KXM2JT
VSmWMhu1MX95KQxwHt+tLfuywTg2ekgCRfIeAe/oXkPe0i+EsyWU11eUUxJolDfDV6OzX0akc3r9
4eVLdVDfPvvQIypF/Hh99Ffx8O7o+O2b18dH/HRslCFqBpf2AN1Mbg5a9G+b/t2hf/e+APpRJBFA
Omf7xSRgU533eBp8D30/bhYW/+wWaJjoZCrM5VF30g2mjUXW4y/RtHEGezqmGyOKg2+DR3GwvR08
hsv8bOTINkRj2FHwB+Uhg/biU6wFP2Qi4sX4KiKMMUtu0VNIjNJuAwpQPZrImDyRuDC+FL9lgxii
gqvJGfNwYSaYfB62oDiLxzwLa/jGtLmkmCNgIRJQCdWM6HVZ7PbMXrvSzsUSxt41DH+7aTbRAPaM
FN8nzdPgz7R3LI85k/1no4HoB36JAWACNIp6gtz1TWwGQphTMRmerBHCT6TZ6efplpE6jtqIAV7a
rouWjosWhW9ePGN6PAAyHehoII4X11mQzPtAoXOgA+ywFptwhcNN5vPkNjqhXnBu3wS7TdpSfG6d
nmr9FrSFQ+cv7c6pIyjqI0j7YjCYw5ym5wlGwg5wvFDHzMx8sZxecna9Pq3wo+faWQvfPX3aDR4Z
oTVGGPt03nczqkEr0v9DAH6kW3QTGBSahYVppDcLrK3CIlCbsedk4WkS2y9Ia7oZoyt90K+KgV5N
wNoj4JKFDX/0q1qASDp29xxJR7GW+F255U2ZocM7W+c0t9uzw1FgNnp5cV+V1IhomujmOncT2ZtX
eVl10XzxhiGUg5RBzUQWV4pa8bZm9Bh33Pzfom6DtyFSLpFOK1yKJ8THV7wqG+Euh6YsG5IgUcpn
uF8zEcOKGSo6prS93WZNcKyNEfC+vWQBd+aKViNF89QkTVPTNEtN0yRxSbdXTE+aCHZFlz2XZyze
Jx9tCqJDGLUWuJQCvW9RKhuDLqC37bsTMYxTuMcFniockn4yxfPBcCER4RWiQevcCgY4Utwk3IaD
ZQ+PE+vS0RcG0CcQ/vOz0RRzcBDDK0L7dZvyGSO43eCjdKJoaU5W1u0o60dCyYLTaATPAckKksVu
fttomzKWTrMpakXQzWqeb8O9Rk+cazNXbsNXZ6S7CIWXtoChHRicHzwzuswdTMaXViaCLcspCFXN
YInkGzamV8t/uPUaUif+QuacsZjLf1bVosUx28Z5wgpI1TtsLCqv5P6uwBQGHGhcoV5uFU+muaoO
WmNAsKa9W6PGiHYaLOMvRIGScEdRoBTRHPs/WwLLMMtyfUnBA4ykHTwlggO+F64dLQ4KF/PltE++
RtQHBf8zmBiofQLt8dU9HM0p9KJ4iWH6+AM9dIX2AEbABf/s0MQY5ll/efTcCo+EfHKTIhrCuHfx
B/cw9U7DO5WzhCfBpKBBiyh6FbaxgcIssZdiHh3R06lFMBrzmm4V8zqoNmlG9tKLb/dYf3bZsGgT
wtb2SLn905rVnSRchQwQ8AAHWtZMSrag/a0YDJtfAjEn7aDEhmM1oCaFDpVcjk74GxDaeIvxwwP4
far3//tAUtUnbVmkDu+4HXRqkYlYECedke87dtQyiVEuhvFKgu+/R9IeCMAzSf65AbbOCjAnRyxp
SGjHphnNYUipSSOU8WDmUcIYM8HRYUPyphHLzHiV9shebTo+LDApBsKwwRArenkh8t9HiogWsVls
erfkPraIHF18r1CcOPFCuf1COS29ccGr2M1ukQ3WIh2T3JkusiQyBsxR/fHM0CO2tiu4Mv+s0DoP
hTw1kuDQvyQE2N03Tlx/TEEJsFwnMIgnrNLRJBTW7ZiEFDbT0eTUHfHM7sSg8ah8N90NLK6VR2Rg
y2mKNVqlNaS0plinCIJaYrNVAj0WmEuCSiMzoErqT4PBqL+QV2ItWElumRSBRWJpSqx7YlJRp7Gk
fuiITfJzjuPjXH/2yn6Fc95pVuA5k8eSyhJx6xGpVyPTGN0J9dtUJXCe3iIzRUiJycMvd8BmQWhr
jpP93SpBlXRvyLJ5CvyuC4xWFLg6G7ujMEtoInhOMVVqAtUwTz4HPI5nEhoxThW1yhV0o9SPYVSw
gJNJm5k7xdT0qFSbdtsdIZYyjD3kICUitzARyl5qDkrmVmOb0f+ojURcLEzbzse2xpoTdhHpiFNB
FB6G8RCbCx/UPttxsDTEF3uh7fageuSJjMNRrIhQIEZn92acIk+tkTEnuYRQTP68E8ccuYbFcjZO
DWmXpD/o9WYSLxV9aYo22Yt5mvKhPktUfCVgQVCeZ3dcM56prDmQ7KRD9FRMkRPPSM9CQtBYUlpf
gvJmfbqh22RVMk8CthhBWymlG328LiLWSTfwD65bq9kEEqmF9MtO09beWHJ/9B+wkWg2X3Rb+y1O
o5UtF92dRhMxKplXdluuOgsbgOFYSUfpg9aqdh22RxUh9TlRyBH+jO2von8kd8dZsojEs1NKDEw0
I57M+YqTIear0aTGQAky22fdpkkyjwYy+Cz1goseCwqQ/zPihyJ1QXHerGvLXgTrdrKlAHBzn1UE
OkY7U3IaZirmPF0kQNdQsDe1ATW9nrVAC3iO3xz+3Hv247uDV4VQx2+Oy8McF64uIQFBpe/4Kg0e
5CquuzECTJVhhKRKJqPxLcfAo//HQdMmwWwkWa8Ck4nx8p9I1i3OAoeLb52cM/CmQT7vbAFgQk8x
hGhPx4S3AMgf/92bZsDodDpYYKxSHCjP0R9hia81xLqd8txURMT1ZimlcKH252n/CjFrtL+3t7NX
HrypdJTyPyAAkKWyCStN2/r+kzGxJRhUd1Cav9HglmAQJ+ZFRTgVTxpiVfqo7jn6ZKrlqns/gxv8
cmv9L2JuAsAEqHQ2S0y5xkEqPVDrnKDytI66OWnzgnGpibAkMxe2nYE+HgyCiF5LZ2jiiNNrsuaC
MTvmL/E6Lgr2kBXascP+0mZatMVpMQsLAKRpVEMxpDwVSXzm++DG2xrcoHZQl2PyxI68L6OpS+x7
grXqQQvj2OHAm0B44qvvu0x/SlmlCKX+l7CQNlZ5bBlWOo7Nimns4zN0iau2WIdPzDDZEgxWBmXh
y3WUk59cPUMLOxkAgVyOc5Lzyq0nYGN3GFoEN9lCWYcV9QSNREuu6LxTffVSDDe6db/J8P7U02RG
7iO87TDTdfddQMbFAI4Zsf05TjFlD084Wo4hwXaB/1QSa2NgxCjy9S2JAKX/B45PBIFn4TTuIQ7y
1KSV0IRRzAApQzRCu+kZYvJue9ee1MF4bAnkgyXA4FxUxrxpQjZvjRYOMFBgS8kHYeGtVfcGy+W9
c2PZ/0kELYoZnhJN4Iw99iVAhmY7ZSnSUN3v3qVyqiTX99VF9WVCKkbDXEOkkKkg1NccggwDu+QE
NjZdj2fYeLNcnNTpmMdr4miyOxQ9pwMUUObUUwYdznFXeW/5hGjGwfwPNcGSdZRL5Zw73ndYOzE6
Iy6LOj0GQHXWhPFjAeOmVCP+/BHPpD999OEYSMyvg3fPD4Od3dYuvegEP706OKy/erZXf7Jf4weM
D4wPz46O64c/HErHaGDCsOqjx/vNIFIF2+L1zuP2fhAdQJVW+3H98PkPcUPa3qLF2nh0FgRfA0j9
nnSCo91mW32cJH1EHj364S0CV8uyv/B/Q7KAqtMPu8gW0yaYN4VNgx5vHXx4/1Pv7bs3798cvnlJ
JqJUB+8HwHWRHCmjUhwQi9AZHMLJYA9Y5Ij+ovFlzFG26R38bZkv2+1d+R5/ogVlbAbljuTPWgAI
ill3fLXzWNXDn7VgR7a412rLL/izFuw+ju+23r578Ys1I4zHS/dbQlks1H9fU0yObmBsURDJnYu3
ABbEWtGy8HhajZ3GfqMF/9tptPbgB/5fE0OxG+5Xgyxl4wTh0yqCF6RwavDuY/vhiEy6lfP9tnS2
l1GwYmGF6uuyzV1CFy+mSEz9CncYRiMrrbDDFWT4ZzMUC3uKltbctWoeTc9H0/TFs4oKe1wB5wSY
CH3oKC4bmc0GEdNudrQBJEPpBYZa6Wfjqpnvc+vAEmA41GLLZogMVIyJR7NpKchR0VYXGUa4j3SY
D7I2NUwL4dpTKOKg0e5QASs0SCB00hQnvhW8Gv2g7koKESvLrVC+6iFo3at8Z+qmzACyhRtABguR
QwPQI2WVENuiIk6c6sY0vY70ZIW6eIl262fLIQeojmD83wTR/i7qr8gq6xqVt20lLJzhEWo1dx/v
PdrHMvu7Sk810jwrljOugWyIzUcjaHp/N4abSLSsClzIgLOozoPSHazxLRQ2ounSUFHpKLqU5sCN
wegcbxQpWqMg2hikGHeZXE1TAmOSs7t7bdgUF1aIcjWQoYCoDr/hTex22AN80+uPZkB4cn8jaRdF
LA6BbnY+T2YXt42L5B+TZNEAQJ2M0D4sb3DFXAZUPaTHGjnn5kVXxdIW8Yiks9FCttdIxudAwS8u
Jqrp9/MREBlwqZkOcxzKnXlnxJGzeXI+gQsEeDWKlgqkfDZGEsLsdPVwihNcOSCxFbwAkfqGSwpw
sxOLNWnAjRyN0F5DYPWfW92f292fd/ACQ9ocSFFsUuxN8gX2Rs/kUzaIZqOafv7Dv2ZXvKOwt0JP
t3HA+wF7AUVpFwzj2t4sy12jC+ahWA1MJF6P4s/JByA6bT2WsFuD90VdFrZa0P9jybpgg8ekLoA3
lsvNLzssmI60jNr28AHsSfI9oAAaIqIYEDh/AJnxBxMvfzCl8geTJH8w/fEHci0NunIoDNgfAGn8
jlxxKiXZeBPXqKuevKq6REjJlzIDPbZXoz50QfOdVa7IMWwiJndt6XmkZ5gYkZphsa1sR/zVbSmZ
tiX3JpKjS/N170K7IFEEcEVYayLycKmA9vCo1PJaPA8LgTWtRVpVE+Plq26VWwo9iUQRNqG8QvQs
CS2LrpFp18wZxYUR0PDVCOhJjMAmbNccgUsBiUFYi1MxCKJi5VKs6FJ2JSLw5IFNA4Zx+WpTYl4L
0nGH8BBbL9EY/PEq2yZfVLtgsswpvqKyEX+M8SfmGJl3nocVC0Ajs86WHJn1cpORmTTquuNiXpkX
41oIMHs8AqQvrVVycIHdhqZdup6zc5ZlZLbfdDrG091DaQEeLPQnaTRjxUVF3KbgPAFebqf9GlNd
cEPD+mXTUV9+cKd0uRwrkdClOLrFcfXyZIzKKqEuPAfcAr/ORoscKFO3yUl+/gnaxk/XiuLG5sE2
rYdG+2Lh8aXrfrSAUYybahnUYnuMoaIF+ihEVKahFhcQGlx5tsIU84dxn+KmMYhe2mZ4Q7ExLG8G
DR5fdR2AcbRXLjCp34U8JH70QVQ+2jnaiPVEFT819W0+oLHoepebcw7MxTS2yf5p7JPJqbNfoj2z
wHSN/sUJXa9/w/XF6AgxS2u/XJFUioYRvQDwB/mFjDLMQj81x9h/9ulv1fknsKkFBRj8fAdIGK1v
C9WfeYg4DQpDdN7PZmk5OFuYIzKeUGdKWvHnzn/+awCDeQysFK8iBSAiWtjOKxuBnXQen9asF487
rX0blMWgWI7XQEVsFD598SIUc7EGVzMnYn5wZOFXwq8pj5Lgfw/O2Bazxsai/xjNIh5rjfp2xLmz
BE9wVCfQo0WNkSl/bGv1pn0kwT28rcxOA9DnjRgDnyU7z62jT5nwLvsGOxfW9w1KMQwnKop5mFuV
6/W/hebSGHf41fpLSzBjryqMxepbzNvgG63Nhq0tX4SyBSidsAZ1IeISoM5adixShb1XwazELrhc
iOAfS1qGrUhhx9fQ6aHtOArCddo2Ut+GG4Jj4YB4IRNWwQG6wknDtReLVQaA8FmuP8/0W3qlV/9L
wY4Y/krY8Y1/7bFrmKFoXQJimApa7c2De1ILZC6cW46/Son+kMkz8/z9UzxrvoR3TeJzqSl3qzkr
d6ZhfEDULq0CWS3LpWN5rU0YaQzGiK/rc5vZlaSB4ykDHShHGe1MgcqDLqcJinTfsKC8ZUJsHLVs
LkuYVaNPQNtGFabBNQmLxgmHfmN/Ne4QqonERCQXojq7sSGMNZGSZBJiz/JEmtaQ2NukjGMrfycy
MfNkIkBuy0JjOKo/m67B2hjJrik7EejURzNsOUZHPeFc6XWG9Fu4GLW4C/V1kvTR5bqS0m2dmpNq
mV4MHH+XpCYC4Cp2XclYtgwUNAyANk0nZ+NUctO4Mg6zms82gE3nvOBSVjm30RqXHEHjFO6yHMw5
BOaQ7S/GNju3xnnJQbPHxRiyYuD7e3vNR677Gh2P1ZOxW9qJY+/FtHKMO9T9+cAeQz7DtxLk4i3X
uUeAnDcWn4IFxC6GxUY2xnNrfJX0mWgsNgEalxfV06QfUTxZjZupVbJ0Wlty0hFNF3xF1CiggHm/
UfhJadpiOYtx4BeAVbHxWvTctIQ7XqeHDR0fpFF/jg4Qhf7sqIseN7qrvHOVKgc6HM3O+kO52vEP
5hwGc14czFUal7CNXyP4/DjOzpLxM4Ahsy2kCHqFpsxwknxy/F6CSeesV3QPLG32rFc2QhxicnMM
NM4ntkIntni94VgJ7UJ7T4PExbloJjjLKfBycS1KlvVrpeR/i2gpRSFe8Obw/dH74Pj9uxevfzRb
/124cdjQM8srZjLC3ILB8dH/9uFIOi+x72E6JlKOUCWZXaNJliVGc/Sx+w76h/EMYWmHZ4UR/e7Y
IlNf0j5Ib/sw6QzPCsaNcADIN63IVhhjjbhnuyp66QzPHKKrILyyNSd0FbjXPw+4jE5xAZi/Sj8Q
10WEu3RAG504Cabg4u74zNM0EYaZe5UAqxAeo0KWn97MKOq3KVIvYbz+kc4zIjR1jBNElZ4yJ3IP
ACt31O/W6SmRGhL9R8YXDKuo6zhkU/mtwKvHncbr3w6G+J/u+FPf4nKH/WwChdKeqAyvbMJhjUUW
NshsTVKqucAI3Dn6T3lObhmuJVRrIVkDZNoFkFnwBdXcXWPQCi40My4YjbfPPjiAoTgQ3hkpX9BH
eJB3BikmsjcOUBWhjBiSiHhzLSR93XQ65zVqKvIY61aQ00Z5+mWcYN8lIIuX33ZoEJ/eLKQB0xqt
ld8pqjWM4mdyrdKVEZFQ6m3R4XFz8lbPO7P01BzRCk/Htbwd1/J4XM/rscrzcZX349oekJYX5E2V
F+QKT8gb12v9k7whLY9IpnvCjhKuhHSM4QX9pWgt4p6Cd8adFdIpQgdJccHgacIidKMUzrnXc/Ke
3pLFxtf2nlzfY7LYid+DUgvybzjDoPRvE65IgiXr/Mev7D9+ZV/cr0yo6Iin3MyprNJtyrjKHSvY
ULoDI3B0VnotEeB9Hvc1gbjIP41/V3evfWT+T+mEVu5qBvzzfZzNDJ3qtrYl3rqPv5nCgSr9vGMN
MHGdeIU9Q4kjrwnLFlZtCHXABG8G5UFETyfsW9M05f7Ctx6+F2LFsHeautlOV+BHISDXUkppog17
IL69eCYDl3NY7IKli2G94PZe4/HwjSqf6D49/WQHaikY14YNXi6Nyqj9iy0mO1ks0Nxao9Ud56hv
uL8b+nWvDxLVnt0OJJjIxOfuim4SxQOc0bgdTzu47oTbovNBeCuGHleuJM9QgG64ZJDfJdGKodBJ
MFLI3FGLkYs2hM+j4zdR9G/g2NRyL7932bS1gVWx/AYxWAG+G2HREvsyiR55xv4tZLL1lHQNyo3Z
HHa32vqnYDRizqnEaMeyITFm7bUkKXeG/o+f7pf20wWUZzoIXSTozCTyASc8iH+eV67KT/GtTFAh
zbdxuo7VFb4yrbLw2ZY24RvbjhY6+U/qnP/L5P+hPCjbX64PzPLzaG+vJP+P+G3m/2k+2t9v/SnY
+0/+n3/i/k+AOWk9bjU/fxao6vxPrb02frPyP7X2mrv/yf/0z/jv66+2l/l8G66O7XR6Fcxu4Sqc
7mBOpFcAD8FPbwOEifrjH4Po7ctGu9FqxsF1ehYcvH1B9k7zbLDsc65x5EvyWTbN0zzoJzO4moB/
IZYxQbpqLDx9G1tbH3L4cnarU0giBHJWJ6C7B7ecEmp+K9vVSaRQ1IOe+RfwcJ3MBYshRh0YIByQ
v/bbg+PjX9+8exYc/+2Yckqf1OsY/3icAYUWvD6l3E8yA+X8nMQa8hmprv1d5SF+gRQDhscVL5bz
Mfo6chWa5cViMWtQWsO5dAX7AdrANKHvmK/6CSY3RtXbe9ka5RClKltbMEbK54jO13rdgQ3ldQd+
/TDL6+R71Oq12r3HdU74Cff2oH6x/SDffg589+LBg3bzDSWl3d4WVbctGkm5CO+idzA6Ru80HuEP
OHXbreY+LPctBqhsBrDUc/i1Cys7mvKPPO3n2+1me78Oo2u337eedNrtzu6TenOv0yx05BlmK9Sp
YBDEjgkoSpOVKOes8HinD/TOVzNkPfLbHCmibog7Xs/xFca8oG3tttlBrBu22o8wpWijJb2vmq6h
s3JP6QZ+zw/REXKG/Mv+rDrlZBX82/HJonzS3eDjrEPCO4LtmeZ0W7XgSXxn18EswlilxVUozRT/
AEZF2Bruql978uO+evVI/XrMH50O4IhilEK29FpEsRvOjYKS5mLU6PGBJsfrjFwIEFib7kwK8UlX
H6TGS3jhdi2OT9d3QiLhTUcyIWkHd8FHymR/jIYagyQFFqnHneKocDG8kenMWvynl3BQ2ZOWMxNu
zcoI9d8zSj4not6R+ZiMSOvPnKRgs/NgoB0MYChGVBD08XTr2wPQi8nrFUEV4Nm6hcn0YO9SCkHJ
K2LkqXdabXC3BSYDi5hjy2beoclOL5YLzGXu31+5wP1xllvGuOnNbDRPexI83R5Y0C+BySNekhUb
lBzQMvOVgOIO+lrs/ZYR0Rdx00+RH3k7nCH7yp9boQBrwTeJh4FEDLNVqIzyf1ELFWqoOx7cdtFh
FOZoJhe2uHtyORnouPRj4F2n9VYY++UI2ElP3s4RVvHKe6DHCpENNXIBIIKJnOHwyvRxUKuqW1nj
ENW/00VdpLMLURe8fbGYjL8j7z3AQ91RntUfP957smIibosqIR5KJThSZ1xSX1fPo5Ii15jEtkGc
O4X8dDesn2WXo7QAm0YgIMSbd1ueBMuUDYdEEyzn5oGQlAUmg82GsXS6FdFOvwtLlB6oKemGMsVO
uWbiskYZWLCQCKaq2u5iPJlyBQ7GUbpEu5arqjhRhfUh9Y0C6VpwczH3TAFxcZ9nnqejQej3LJNe
vPm1OtqVUaM4GZmnJRiE9g+21z2fD99nl+mUzQrv0774SFdLYTkGGeoQyqAF7RlMSrIBD9pgE97J
qEGumRcFg7Jqcprx3/NxtGwAwprfes5AX150Eog9Z+BaXeJK+x/CDABWljwe71bxN3Kh2e5Tgupt
IoZC/3peJ1PK9EA0duNsf1cgsigkeqmDGbRgJMpTWCK6mNw+6FfZqfid93WQXgEJjJCFg6L+KGts
2dfyE8S3zrXnzilzRNTQGgdPu1hXEYdraDD1fUvoLmqjw234Lk36F8Gr5GY0WU6Cl0R0UvT4MK5s
0hgM0KKDyDp08db6I3DXtYZoygsLlv0eZsSq0dmoDvime9tBc268AEMGoQZcEuFKoGN3Hwl7QK2j
mUDY2WCCkv96QGvG5P663aIAfBvJN/yRlnQLd5VDGBfuB4e6LocWisQc6oiPctmvmeE4mQnNEJAG
wEzQdwRh+K0+hUigVUAPeTeESP2/Opvlz5fj8TOMr3dzmAFamMsmVXeEXt0uytW9uBgSwYQPBtt/
T/qXvT413XuQ94C+bMym59tvkTrvBFAA+Nt2a2d7v72982R7Z3e7tX2wXGTB6/Qcvh9NdeTLGRIC
wCaQyf8mEB42a60/Wn/89LaHvPfjH3EAfyAmCv8Qrls46Jhe1MLNQaMELICxvhTmYZ8FNJa4b+U7
U2X3sJx1ViETyRxiw992gz3mDcuByNzjJm5ii/7Zaz2WmxV+mIXcuQCaZwiXNR/o2eXK8BeRPWa/
/P9N/of+TwGKNSGMa4BZdnD/2sK23S2D4bram4GVhB4FOiZIXW4KTwLDVUHUTIRI//0kxGJlStKS
4cqNgr+t9s5eC3asDf/jNStdcGMjV2IFscEtt7Dwqqug/aNddOUJp8Mw9pJab98cf15aaw2KaSpW
20fTOwyKb27Ix60g6Fi0QnwJcflTTQXFa1JwuDCKhGMmcxNCDjPYl1Bya1FHJhWCNiDJfBARAyuI
Efi0PjmyPoHgoURc59wvTopUHVR0pNGrMEvTAXMhYeugeQAHDvNW6e8j+RX444rYFu4kdulUowc6
3COTkgtfHUOEZOxToY5TKWugQVAhpppD4P43XkZaDVzGv5BEljLlmr1tePRFVz9tbW2NUHbMicdp
dL3eJBlNez2xVAkiRSnjbxzMz5cTOJpv8UlaIyUzpJB7ifgW8ZhqlCa1i/lQS0oJJiUs+S5IybLP
9Trq7UO0qB4myzGsSZMkg83yCkqFYQxO12+LejjfmcAiUFuiLkxsqAXvUdLQIZASSfbiT8WyCHF6
0sBxCkl60tBZPGZzhBkSxQfSaEFINSOrRa4/aQgB7nC8zC8MQeTEK7GEUf9HS//P0v/2zvNWq7mY
fV4dcLX+t/2otb/v6H/bu3uP/qP//TfQ/75OF+cprM+PxwAX79+yZy+HS4+u2n0i7652tj8cv/ou
ePG8jiHfR9P+uAE328F4lKBJ/Ouj9z8eHbyrH//64v3hTy9e/0il8uQqlfH/42qVMDB5i/ntxopg
A5ZZGXxSr8+zYLY8G4/6p/R0zTbKi5QecUh1jFEftJp/tFp/TLMpfyAN4Hkyh3nX8+vT1ZkzoM7V
Tp0MwVj9R8/kzZhfJPqpjqiXlNT8jkJLYCRR9cQlfj76W7WqepTDOsqnLFchz8neXD3d5qXabAq7
tgUliIxpjKYw9gXGo8jEm8FojssQlT0nZzn+jXo9JFN7vRgpU9nxdIICZ4qwnrvR1V88JymDUEm3
6X/wbwgf/up+2eHQ4fDx2Ye3L48K31vNxiP+8SS0lMwCfEu1zPOsGzJgwI06v+6GAi5QpwBQ0UOo
6AI/Cs+sd1bQEJYrmz2hRDlZBxrnZdfC2agG58dV8zC9nwkd5xxVVPNMiUBxhOrBrnO140YCxKwM
O51g9X9fCw5EuQYbUVTZu9EIkRgXVW/Udd6wYsVai3K1cxJi62g+erUjqMklJtK1n6kDn3uU9z9Z
E4dmtqSG6nIVYrDlMR3NQqaVMnr3Pm6ih+9vN63WbzftBH7vEAFLtM85mpk+KjpxclMcsRdVtmi2
y2Fb7L2zYQNK2i/swsIooWiRoMwNRh3grx0H9hbw3K17Ghvwqz31qsLYoBY8kT9aTfHR6TShy4GH
GYZrjZOqoD91FwUNJNV0dMtwUoFOFgugs2XQm9hbVozCKItvPGU98T0JMbDhMwZz93ykuwTmiIij
Y5vd7O619xFdwTuSdLX8BSgNQXhHIK2adIe3CrD6i7kECLbkGK213p9sysGFbL888XTwvPfiNXrW
VHgZqkaIb7CMP+IKCw6sAMuFf+mCigvmG8Iygy4PhZ9cV5pFhvyire/jo9zuA0YgabM0J/lcERyR
LroapdfqlpqMzgqOTrZyeSlFfZGx/UHdgIwYNhz2HaWMT3qw//g/3dqJfX9SXo5TQuRv+ot0cbwA
3u48CiX593aeHSfDNHhcpzX/cXSenI0WwfEEQZAZSsARAMDtxs5OLfhhD7NuNExtfqHHtu5RJoH2
nZQmPjSrGtpRDaksy9FyVlFh1z/XKZK86WXloPe8VRVmrqi5X7LARE9YATIkeozCc2amR4B041VH
F+qdtJunZER4+PZD8ALl1sOkn9q6fiyG2IALXo2TaUB5Z0wPUeqpFkTTCUkZYlLEw7angwiqN+By
muRR7IjSZhe3FEQY3TVaTesTGkghpiQROxbTIcNZ8kQeNC39moTGIyEWbrtuHqoJbrfrBhIx8R+2
8m03eMTob8sv4F3MCc+OClc4bOKDHPZOyDRePK8Fo5g3EZf3PJ1HI1+Ntq+Gte0fgAjFe/p4nMHf
ZoDaLlR2qZNVD15ifDPafjVpWo/pxNflTtUgcRM9dXar6qCixu64tdf0rs+jqmb0Nss1bsW+Rh5X
NYIb7d0Z79aoXOxRvyICrGhht7qFHR2VpxD6z9jvZnUrq8Dqr34o8e/0I289lU8+6q9YXn8l1G61
/Pv7ZJ26e81VG1Ret+2t2l5R1d/hzr1q7Xlr/Zgsz1PYPqKerKPgb+Xxyh3VpKY8DQVdpuiniNK4
E9EDs8HFk0LwqvCiOLfFgP2KpHScbU8cGvbbIDQoA9lJYb98tYrVXOK56M722QgqElQpaootQI3Y
wMbV1WOVGIdGyRs6OApHVDA2uocB4ubFglzdDpx3xRtAcaF2Qm9kQVYa0sh6VztOSAXhk9yoTOZr
NpRMc0zVAfWEj6zOM2/6eev+vIthKs6udrzDtrMNzFU076sd863jv0qh+ItkqmSOY06M4vdpLYSn
EGuDnfiiUYhoCRFLJMilshb8gsFqxO8X6IpKv2NvLIX1IUKUhv+frYIJUfR8UAY/s0JZcjt3C58X
g0VNfLEFJyrATQG7bBZmwwQygJseu4+L9ksS2sV8iikYxDOKMZZvfUqb+7JNIa5S6exoF3MjkMV1
TwR/VW3jswMhZXEagrX/+1qHa1hrYmZQkVpp4kBrhGouXzGs4+/OZ+psx+psmhJDK0IgQ1f+CMjw
wRsAGUPsOl7yO6SsxnY/14hb1ohdBCf3e35t4EYMW9ItIkdRsIYL7PhCcMDm8a0/ioUP/zlBISij
E0aESkcouMW2Csga0ZYIK2FPu7wtgb//G2/NUX+SLi6ygZZnWzB+z3utAoOZQA/wjoYca9WcWTXP
KXQqXTdm7XxWjg49YUKDmY4TGpmBQq3J5OnvxVaxJ2POv1tSPSeykxuChKf5u9sidvO71TOL0Hsr
CgpIYDxNIZy3rN0Up8KOS59Zcb7Mg4TCagVQVDZv6CgjFLZG5Ag2ORJgwlRUGxG8ng+DdmPiQ6OG
UaN85HxuXFMaDs/nhDvxCxWVYRKFzDvJZHB7Wn8nnsGpnXAe+5d+AZGrKYlLT+ta+Pyq3e+I6EU6
7TplRByn034x8xmmzBIJv2BB7ORfhqBwNQqZSCSFIj89XUqK1JVSlwnl0uzmDZXr2qCPRNET4yva
FuK6XuJS4fdTO8L59IaiwThrhkiLFYoN/tObj84vgHLDFhB87Nzb3hDdmOUkPxlhpJYT8fOU87aK
eIf4UgbdF1Cps4Yb9j02LpUhmMx9IKDrCmj/8cgJqKMyl/sAq7M6i/dEh8zJG3ZmetP0Lh17RvL6
6K/OaNg36ESue/XoTqtbx9zvLlzNcm+4FTQjc2RxnIvcG2SoKtqdk5HWCFnEueG7BFPQ+L0SpEuu
ibPImxDht3azY9zYU8uMNBLF9Ts+8u7MeJQLOkQvSjH637QW6Bng2qTT5SSdY7IRp27NGw9Q4rCv
FL2CG6Twhq32K/EkkCdivxZMS7GZDH+zweKh2GAkfEDRXf8ievGcGPlHjVJHNAryg7wd1pwL37IG
yZtPWqelfjpYT7p3ac0lrATuv8TvrVrQrjB1V+uA7vFT3xoQMie+r7QR/0rYGlUMSkSucMm4GJhv
7Fu1v7L84/GXXzdSYgoIMvJiU6RXIi9imbGIAPZpsL+77oree81IV6vXTJori7SlHH9sjFqJ2L+c
jiiJxPzI4HaDEtEUWyIhCvIqAkq0tm1vQcOregQHO2o2dqS7+XA0HeUXPWwlLnhK6xnk6Ypz23pU
enDx3KpQVWscXeYS/SyWIAGP3755fXwkREJGQNxTi8Eo0JXCyETJnZjy26xRk6o1Fs/vO/5FFfjf
+pX0ChZ29EjnKUZlc8eIiY5Hk+U4QUsmUaYTzJfT6YjoRbT2htfjDCMNUEQQMmbDgYqvKr99wVxD
T8BYhNhvM1Eoy1PWvvloPutfYCfKLQB27ASkVtcQqcCdkNS+ELEie1Cq5S0rw86uGQ3VG8PPjoJa
JqhaPeyqUAJe6YGQHhdj3srZaEHjmlORgoYStaUZHZjK8SrHToAIEduikB51ZWQIOxTEJ4Z9kAYT
xfAaNA0V6OFfZ6WPxp+mkb0w9ysvfW2VFvaApcWV8ahZiwwG+xfZCKiwbsSPaOtD4QinqdT5eJoj
hwGjJW1v+Pm8CISJamUBMtAzGsX06qvK19nsrqIUGesZrWLSxVXlrVZLXBts80cAtaQh5GJGMr4d
MsmimXd0AREGEl6RsEDW5YzqXbFfzLCqD6IOmxl29Hu2mXRONVsoOs2rtJNu82xvaVgxdvR7eoEk
nd3hneXdISx2ooSkIwnJOhNNN+EDu2WU+XaQXerVTtHFQ9oCsavHcjDbVr4e3OIqB4//eHT8W/p/
4L+9ixm6PqOZ/Wd0Aan0/2jttR/tthz/j53m/t5//D/+Gf8BRfrDcjRe1DG0OJl7oojDAIPg3XJK
1FInMF7T3Y7l4VhH6J0uHC/qkwCFpvRFKsdiw3NB5IAZj87kG4qa1yd7cflqlMlff8+zqcet4WK5
GI1LnByAnFe/l2ezeUYSEI8LRDqZoatCtUuEDPYn5rS19dPRuyMUL63tBrGOUwU26i9JX7bUWun1
B07gYuayjcqrgrgPGQ1RBiPUTn/l5aXTjFlHIny7iuvbUcLJakePt7+ixa2O4qccNN7DTmCmpxLv
DJfUhEVD22OxfY3J5QB/Y6bu4eimG/Ia4WbVQ4NWBjaNrA784dguZg1SnvTMYtiT0QKGFJsui+Qv
AWNjPsFrVdWrBaPzaTZPeySIzaVWZYv5s8WH2atssAR2QjSUIa99NZpn05Pwp7c4gd7x0eG7o/e9
n4/+RprNEEGQnKLqGKMZmvp0+xjrP7UZuSC380hCfQNfHiZK14OToNuCPJaRAsm8O4UZKeeLo9+X
yTiCFebS6IMssgZRdIFagDI+FHrVpNuzsehGN1Cxnw4+paOm7qh50D5ouQkU1m9mRzWz8ynN4L/c
TKt02iLIfo/ig1dExONe33Ep6JZPOhu42Bymb0ysAnxC2lF7FCqoTYHDvFmQ8XDLEzSlZYVzQTte
N6BLa7sssIwb5eXmj4KXebhjtS+j4Lh97Gxv7zT37LZ27Zq4sk6t3e3tlvq/GyswByKeC8l36IWB
lfCCAB76aH4SAtUN94qpSijACcbZvDoJZ8k0HcN5p4AvItX3nH3j8/BUmlzf1chbhyP7kJuODgRE
vjoc2efOt5Uk78r9exm2tpvbH2bbvr2hiC1/7EABDN4BRfhFDctuwwJv727DSm8/2uZC1v/BGm4Z
wW767iqKMZUtI68Quv6c8JRPOdRIReE+FZ7fIPrF4u11ys4SYASx9GPvwrEIr3CBFCYjyoVqrZpO
GBXYMe9wSJ2O8MIxFqrABQr1k1lCGiZsO/5UhOAZ//cYm/Epj9ZBTBxcq3IpZBlfJOPtjMIT1/Nr
EbG4GLA4Gw22WxSIeBuw3/bNdiWWheUYy3iUCBzUasBtrqg3HM0n6D9M9UTvRUx8QVDKt9100Lue
J7N1LiKzYuQLZ0R33o8rLpBCK9jIT8l4aDYCb4Ofnv11VVODdLxIor0a2nl9/32w00YrzL0YHfXi
L0pT/JKMRwPaodVkBYokCiiKdOWXnNej9QS2af9xo9nYI2Faft1qjJOp+Mmho0R03ce7u+RhdzIc
NJudTuvUeujg19gTSNZA4LBsVzh4GlaUXcJiwT/WuDC2Cg2MsokEZzQCiqu922maD0/wP3yBXE9n
e/uGRvOPf8iB1aGlivEwhrAHBDVgRPiv7+ImcD3LsnG+DrwaF1sUPsYATS2ErhOgUx6fxutXpUqn
6yClQ0I2K5EStNn0g/aLHAVqegQ41ygcTS/S+QilwqRG76F4jWnwzzQo7maS3J6lBWwBdP+Es6lw
wHtvyGFoqVDuY0hiX7i/FYIkWIFtJvdQB+oxpxolsu2JEENB+Bgv/fJVyq+BGOlfpHbepOJVC8Xc
xjE43eNP39KKOeMhEmJvNeUbcz6fv8vE7otSjp5Tfs/W3ZdFh8cpssHVLBbxif7436hpEVxzZIFf
MkeSw1+pITlYF2AvkrwApBcMo/ipJwMERWE/m88BKgK4kPKSm1XhTDiAw9vSurXgIq6ggnwNkCnH
fSrSzp4n8zNysXRnf5bd9ObZcjrA4MjieoeOMBWSuyhQlJeFt++H7EYkCmVRgaKms0uKmXXTEBmm
o3D233n+8Pq3cD6oWDWoZ9qQhFC7c9XqhHHFWcVeZFbqBV1O/r7WkDAk02wBaJPlC6XK0/ucQnES
vatmjV7fqqMpYG6n63tISaydhlcklRtC02fABbrbC8TRqj7K12VN2CCrzqEhQeTIkKok7F8jpxYa
OIO4jBQQmBoYp8Zx78WrN8+OUAaJz9HlELW5vQlGeQeGPttvNlc0s3JvLFgGihPB7Cb8/Nv1BTEu
Q+fxIpunnwfrWt9ggWrS6R56qMmog4ORikywaEjh4qdjbL7Jev35khkShhig9hYY5d+fNIIGRtrV
6ntQks7hnZl9Jb+ucydWbP77IINVgznwDKZt0gFoad1F70ZxbrgtCt/J4TG96PI15q+MrHmQFXsV
HeQ7XYUuS4+aUTIFOJAzpdU2yJ5QZDanEJtB2G6ac+0PVVZSbgmti6IqacbwHGg86ikVJr3cFfK3
Z8bWpcOh3TK8gOt5dKXopGJTFf1GUP1Eh0KE3uiFnJh8VtQncKDOXrSbgi/KCxeeZxFx2T4ChFKi
D3XX+9KaWDtaMd3CIruT19Pr5dly3uc1ZUMO33gxdpAwcTCIEfGmPrveaDNWjm7jrSlMhvbEGB5M
TjyFVs5JdBNDxVxjsJzMcnNk8C1BniGKq44gkzV4+tKBd+Hm6STTM7egtmpHi+vCXKhHlocnIv88
WBIJLtUkfPkITBh8DwKOURQE4d3dfcdPp9do/bQmmxcBkO5s2bQDfKpmREh1B4b6+uCYgsdnTriR
ItDMT8KzFGNwYq8olBwuMHYXAUkoWlLtlMK/MQRcvsfk6f45V2MHV8Mcy91nu508498huif4Jmjv
fclu9vcc+urzdjHNKANPy+lk3fvqLi4zXM6X86sR2tqieawnNtln32mHKkKU6Ukb1b8ong1RNgrP
02k6T8Y0x1k2HvdG6Bt3BW/wlO/x7bwY09xfJmdh1WHuX5w4bZyipBU1fXvxZ93NtYbfuvvyfRIs
/XO6WozzXh/aw53YRjvc7X5jlk4UPH6NPm7BZJTnaMWxqmVxteXUtCBLOkyA4J4LIQL0iW9vAQg3
xOKq/VNN9QgCpyAxRAPEvAesyoINv1fcTOToK7REKHC2fuC13vKfal03m1FObIwQksAn/p1T1fbn
QzuERezBzrNx2g0xyJkyPP0MHQmCwezqs/Io3PCNtdiklKnAnuZC86zdgd1rpapAD7hwOdaDZ69e
vA4BDLEZAjzVkg16/XmW5z1hJtVj7wUX/EgsxMINk4s2hRaSCfbOzuFZKMhHPk7TWQQklKG7pH78
tNc/HNrrCf5fyZEkWZrRff8CfRcHvWyKlgKXUfxJBIhipv5RWEti93vzbMF6rvJDXIriuAWMvH55
BjPd3yUTY3x3CcsFb9p3Tnw2IxJcu9n0qo6wvshnB9R5Nu+GpBih7rsE1dPuCHl9YPNvkbh53Cxf
Vym2Sm9GUkkneqD8B+SOFVYJaNdoYCdcuUVcY5GMxlEr5n0hZXjryZOKqmMpMjCqI6k1/Q2vsNaT
xyTZarn7yqZuvauWu6WzSjneVauBbJKLikhwgdlSgAFEM77hhb1pirWKijf6I82TMa9RvLgUn4dm
IEPg3e5KI+mGKpx2T9i+s128PHSTqrrqWHSCE31O85ZzUDles1dbdfL49G69KL9G+21P+2133mT9
Ao3D2jqLr+1PkVkdoUKily8G6Aw1yhocnuvFm0JUQ8B8NhAUxXyUcCpEeAk/VXwjMcKph5p8VFH5
JJfoiXBDjrjBEeIgSyw2CZby9J6iEo9kyBYwMOR9ptZbhdbtvGVFCQP1XqsUEX5Z9d77l8f/pxYy
T5LLtDdLRjLwR3+KEmDA2clkNk4b03RhWimQ9TApB7LzeTK7uJXWwzd7zSflpRoXyT8myQLjCU1G
C+IbpZ0z4CV0H4UtHaHqlu7TTRoCcLidTFI4zn3ZZtqvaAAHinEtZOHXcIrevHimfWz5Nab1IbNw
pcmBdU8xo+KU/P97wk2MdIfw/vjo8G17b/9dy6Q50N2T+sNOohP182ABwz1bwi0tem8cvnn16s3r
Hiauxy2IjeM6zVAGLsfTUD/gfaQe8J9/ZNO0sVwY0SDR/C6iXg/hxIyGGAAsRR8AzKkbN/IlheFl
UcE0bgA7tUzn6pHd5miCl+aDG8qhwXvXmy4nZxhGNIahLXpst8JypQjGar4lARO+BBrAmgLbLKEt
WPdJIYEWkYuA0dMpxiTieR3zFA7GC7zLECCMpX72+pieaD1hWYEughUYi2A2jXx0Po0uawIEG8c/
HcAGWmm2ZIiTvpw+h/CxYLVxhJ7T6H359uiVJ5T9ZUNCyqrKziFovOV6z9GoYdF4+/Ph8WO3yOvs
aCpDo9HIbWpG0g+kOLrSZlkOcvBeXMbdVI7bAXsjq45KEcLWlM4D1zUdhOsYEeUJoPBn6Hvy8uA1
kGPa7CUQdlu1bxrj5IxMvlATSX4q8FAzitY8RT+P6Q8N7ywZ0JH4KvznyD1oMYGy6S+h8MQSwaGX
RdDXRzm4TRf/1DHl2YQOa+6TyI2HPd564DRTBPh5CiQm/HueFkCuj16HgEyAIUmFjRQc6yUlhFft
2DS2b+srLCyg3U31fTCeCh0f2rjySHEHemTy2p/77ZiRMjGHWaPaaB4+zUtIMSJmxBTXKU+TFKX0
kpUU/pE2ZC7KI37tjdMh6eoeN5vVNjb325eT9mksYJbAYFBlQLRuF0azrvcRCo8Dwf5rKFsIQ408
HzeOj18eMksQiTdv3715/+bwzcse0HC946N3vxy9i826hAlJDtmDloHnk1BbkKzQURXMYwHUOecr
h/xSxJbRURsKtIslQpaRfBZ0RpFigL0QA8UpWSuMY2yXyvonoxxuoP7Flx7FWfj3Jbk5XPpO3co5
ADFBaxm746fN6wRA+w6D4WieL8rxgnnsiH+yKeHTeOsT0Tkyjlq4rceP0pBt+LLN5Rp9DHSwXl4c
waVjs2haU9Uqfr+rvpjnaZ6N0XV8bOp7UfBSU5OwbM1YIhtVdxpXheI7m2eXKfCvVJxi8GkyIpAW
XDp+HixozbhArpP5lCGkZOjl0+WmVlMtiJuX0yX53YTcY0GuPwP+YpD2svGgxH1klYDAlgc0Ztks
0gC0ulie+MVPDlO8jjAKurDlKStlp+SwxxYZlkxjDeLQmQ8nVI3kGekK9U9C6p9aIIBcvj6j1//e
01ZnZss0Cp5OZi9RTLvSQwLDMvW11aoLVVdnFAoyKks5RBGzasp3V4Vmr7faT2LS8BfTnRjFrRQW
GJKkyOFE3rxt+MJsSMfjbwfffBPs7wZ1zAtRHAAmiSkiPj2gdTLHeJrdseel88bsAP2zalK7mO+h
xVnnpCmIXtHZAWcZirSliG8ET2gElP7t1A4GKltyYr+r905srrDfnEzMEYgwh+QgtrtXQ5jg4JlV
svWJFVAZL19qtrqGHfuLutMVzrOFDFk18YdVLPKP2eKkEnKhF4LUNZswUvbgjPLrcJOaFuyergbe
jQbV5kFtCMgbdFEE0tOVULqKolPVVcArl4EsgV3Mg7CDGfT24H9t+F+rqI6kQBC95DxByq6HIQl8
GbDMCDecbFEEsJLRsCoSB/TN04VT8CUr1NkgJyIajrBk7LZX2FL3Of9gEfjiUoh0gzt5HXj8DT95
4muZ3pob7USutXphLqkb9BvXyfiyBHHjmqBacp7OgNcnK5vuzoqVOLni8LHCj5n6OT3p7CANDZPG
JuFPm//suJFWvco7agNVdM4urA+peNv3J54IbUiwR8U8pI1HDmJXyU/K9woIQwTCejYd32LdxTzq
TxocJw5WLt587O8Z+DxuFashGV0Ki2BMMS3nKCFPczw9ZUBbbeI/aVBEOJuMkQfzfgqQNY/3esoN
PT5ZfDC/kjoNedG52V6ZdvPFCME1FmnTxaEl505jtVWjIpaWGIWDQmrEr4y7oYi2soqpo7BdzEB0
KfRowaZ1PPZ5Y3M0Ephx3KAiVVQshxjXwQbglFE4ZDPNXBxbLBrml/s2+OXlwetgJNPM5UF+OZrN
/KId5XWNHDXSxJb3tcwbuMJjW9a1PL4L+fNmMOIZhnrTMzppsSWrfNw5LRU/zVoy1ADFlcXH1U75
WIqctDl9hcfbu1ykNtuRHVZPXo79CSzAJB2MKAQALONZtZEQDu1sxG6c+7vrdbFrRVAoBgFIF+x6
grA5w5QQ+QINiHyRUwcWLFogOiBBCVu97dc44eYKs2SxE7SXFAGVrZJFDlrHy9fPrk04JqyVElF8
EDNY3QLHhd6n6BJrpBYQtrEDCgrLnej1sRdhHSeGiRkolkbRKvoh8+bM06sUXcGzacn2WKiCMKBU
hq23NcK72NiOdZe/+TmWvzBxFeVQefoRpArL0LKLwsjYW5qJdxVEu3jE3Ni2XMJ1lmlghmosHU5c
NQkrv4RzG1ijWgFu5okrLapil1RNDQkjI7Z1qE5wb5CiLVZYcNbg6Fn3C3rko/TUEqjwr74N2vo0
ou4+IVi8e9NqqRE5KlxltzUZ3QASIGqiGNTHb0ri81ytBcKiRBqTmHYktsBe0meCDnr7K8Ansmn1
i1noD4m+ufG1dofbuStrq+BZ9fZXX1GvNenFzLAigynJlNB3a7dAjujaDs2kt2kz8K0i7oIQqXSy
e5OCeEESrpDlcz2Rb4mcA/slgR+eePyQOOv48fO3wVJ4CznzG7CE/JmEpsgEAqcoEZCYlMLd3CmF
bP54I03POsENsX03yPMBGoPv+QVidNOm664y4grWOcFNAgoku6xgDBnrcHEMsCWKr7qKj1+/ehtM
8VYMRKCQnG7ln94qh9cq3o6qazFZLTAHQBirMOSiUw0B0EfLxdaOMa1Xfp4C6d8fYbTAiknhBA7e
vtj+8cOLoA/7hFMa5QFZ1QQ419sAB/Cv3lW9Tea6MfvJaxevkANYDYmIVYCr7AZP+Bj2xskZBlSL
hRtO+BqTeydzGcR4ZWduX5L2Fu3WrPNlJieUZ4rEHnAlTPMNZyXtzVVPlQV6+byP06xGKJH0G6xJ
+90wXnla8NZjk7nR8ABTDWy532GKmAEhmfLJIlM5zmIjqzBjDY/ABSNDNZhnMz5zaqHq+WiQBpbT
mOYR2JuM0F0Uvv4RnddwN58j3xMssuAsmU/Zpp3N21eBENAd13Dw0yIXIdelwEhU0qKU7qRF2lB7
TKX1haUqhYQv9TdoOW5wntY8FPM9R+rnWih7BZShi305E4ksfFgEWQAEzy+KSSoOy5NVh+XJpofF
BS99ZgoY2gBPwuwEnhtApGd7nCpfB0mA6wynJlnwdsDOsCml8rcMJst8QTk8ZssFna9sDKctzfvz
EZGpgaU1V/cLyty5hfxEzGCXUkpH4Tt6PcD8snXsPxRZekUO32+D/Wb8LwYH32bvWEi6MIl4ozWA
RXSmXcdpu4eFtucsPQdESNduB2ht3A9KA0OT+bdfqFUISy1MrbBo8Sq8TVR3G8MszklcaB2Pstvn
p7ed4BLzq2B8cvO+qJ6pieC1m8vqcDob+CO3kbqWU7mLP0uQJC8qcf20fcRVMr2NUmDU+ywRpZwS
2AYnEqE7N0WfVGazmdziBYqprMBsK22LEAJT3AvTAasZr6fSeJvOSQYjMjZ75y9d1cXknwgOuBST
ahmiUevRqlr+IL224OKLE8iWH2T73xGJ7qPvMoY45mMkYwy7Q8UQ6BhxuCgrkOqXSiVSeZgjug5J
ducXBK2WwklpGqs/TFUAHBZsXQQTZvp9lRwPK0S7HPwijDcQd/K9vnsqq35BUZYa4014X0GWvQnM
SJU7CnzhsIwXpRIPTxyKr6HlTvCYWBDNp2zam0+C4xtBrdX8J8anLB+aI/ZpiciZ/6qh9THvB/kC
OLZtv+yU6oR/sbIyGSEN2C+V8k456ZbCt0JyItxLKbsSpZJyEifhJX31c3r7BEDGge35sL+z29pF
68HeVYp3RQHHpJh2kvNoNpALvkhvorDp/69d6fIoNfWouKRFpQiT8q0Kx7TI6EM4SWbjNL+dL2mT
J4M99HVJMe8sPzRwJFVMTLjX3h/upengybDfT+H34yf7u/32k53mo8ePBo/bZ19utLBdLT1cflo9
3v39J3vD9Kz/pP34cbqz337cbu/sDfuPWnutYav9ePfJo7Odx8OdYWhl5SCTB5GfvBZ8882lmQQ8
kcZnCFldBVcMR3Cks3427groUsDF4jgTvBicVHkCsuJEFNCJBhTYCWOAog2GYSiXSCvXy+tiEj7T
yOOXHZ+ZxzffJJ5wOMv5aHHbG6dX6TivNKpC6oFTmlFKMgxmHclDR9nZSDQiDqF8RjB0vrf39q0i
XIXsGx304tp5XO10dWLLX3Z4O7p6TF38Jy418ypN9NiXNIKAlIm7+7oL/Y768qdl/Gy2XrA8uut4
jd7QAKraSEvEL2jHm5g37a1j3uS3/RRK2D07w0IpoWdbDHkUfb0EM+bczMYAqMVULx6IEcBSChWT
xlW73wOWCulWqE5cQYVpIFxIbDn9MbSwAd4iv2JUYEQKGBiTPgM4jdgGJRgCI4SUcQl6w1AOJnJQ
7QF+oECboYi0uklbAljpvkzzzVuRl+1ZdkaVRaYZEuJe7QScG3L9QeAhvyOLfkY7AaGdMC4mlL+8
pqzBFJ4AV7wqO+t97fkUwOpjT1fDakM3P80M4/XQyrXAxNYbW/P5BB4AsMEoD7LhENMrkg7HIzta
z/RP27WV3D8b2gB+ilGwZ0OcC9eNqPRFepMYnq6kKrUHrV3/lkYAi0XV1zWGtJX10FA6713tfAZ8
VsBYQoVrGSa6Nok2JeMDhI0NEjE36GpqvYwmlxjQoMt9Qh3HZHGVvdoKln6Vec5OhXnOKpEAhoU8
BMZonoRl1dfV06hLFc2kpeBgh1RTbaMXuxVMnbAGHPABc2Bgw42/x9avLRtdJfIQU10BGCjgSBbo
2JkvgsfVpjqbnGPWfPWGo3Q8yO+R02MNZr7KC5OTd5j2IKjmku9oP8wXtB/mC9oRVnHuOIHsNJW/
IpMdtkPp46fnuZmtZDyAoRdHh+YqsUCmaR1ICl7CPMBgZnjR/ctFJ3qpOiKSs7EFX6YDZQ0kTojb
6790KQxTo5Y5qC9hSnZfHcm6EZpLjpgV1N5DcXzG5o17txqrlgoOnGtRB763os7JiAh8vETQuUIs
fL8BgimksKLhG2HJSyKSrxOMfKOA5BZ9wKjKkvEZ6+IsDDF3bgxyZ1DVCqB0IAaQ2x79/lWjkum0
7wYxLzH2Suxg9SjNsC1pK7SRG617YRFtle566pf/VkJadOX4MB2jg6BIc3t9McIJIbIYUOydabqo
4xNxIwMyPRAxGZSiSKtzhABqiqagUNynzink9TWuJMw+3xX5nhv8JxJPB897L16jt6t4Pn5z+HPv
2Y/vDl7Z9SnPfWSzSaZHLNkucR/IDuFfinwVA3lpN9QfZ7mJ0vDwueEgBwKvDhr41euSjh/K/dCH
FyJwZ5icAxsjzFSD5WDWUTPoPBj8Ng2DBzT22F/9IQff+QDAFSxbwfFPB0yxiYi/wcHRMdNs4sVv
U7NCO3j1bM+u8KxQ4WFJ1+H8eim6xfK/TefZUrTKz/ltjgG5AoAKXCugE34z7aYwNC3uiMrl3XhL
C3cigBCz5g3p35f0Z3uQXm1Pl2SoEtYP6d8+eWbRQtfrwlcFlvPZaN4NMdrY6Wqql4NEdo1hPDv6
5fWHly/xvhuk87nnU8VFiWIQXIZaUeq6bBlUmRKkLttSC6BotRJZ52pZsdmxuas8jJq1sYJbsPnF
VlFaQp6eOhjtTjP2y2S8MlqT7+uvL6FRVAfA6qX3K9P8gU/6Uj6KKr18GRNaIu3VMF0tYKI7yCfb
ZSFt273w4DCttdMOMJlbTaC1+V4vW0VJMvrGlwaIOAvnCeDt9kpTW2j53N9yQZq+L9dXNv3lnYFX
zPFGG9J+jahtlAdKyV7FqE4ztpQNkj5ijntwq4hzGgu0rJmi9igufrxORotoz1l9K2v9oCxdvaG/
JTpDwNinefYWPEcS4Vw+zs5H025be5Hc18m3Px4JjeDsuvv2V68vL2cki/QIlF8Z3bFYFd6Ra0pX
OqbIM1FwhsS97i2y8/NxirPAcMJuoB9DDVUZALghMycjcXebq3DjYpyVVXVK8tg28BN5xWsiM3iF
C1ffLxJb7f26Xu9FE6IiFrQGIOLorO5fxfYGcEjJyCyPLf/OfkPszMaNNIvbTaDKIUtRYTWa3665
4cb+ulBM7WDAO+7480CJMWt7DpzkUunx0ciKWaeNTHz4LB/AxVLq1Ybz5zQhsWfuSnQpz+ONJbbs
4P2FmKLkJLY+hykVyhRLdsUOK51ejfrpaLCO1dTZMi+ARAJXVs0BjFrJb8MuwLNonnerpv8DDMi3
Rz6ATIpH5cyAoy8YOFv7ov3Lw2evd3edeZwe75lyxu/1uCor2ZkhlHKvMJ/Vmp3XEZ0mN7xlV0cP
VzEp5JUohtHTnmwezt/2RPRuU7xVaZibL9gY2Gv+akqACq5pC+WStihxRStGt5kp21hifmbI/GBD
4uY7PensUrRItojif+n2lX8rQrga7bDtudzHcHUK7mora9NW+oyTgJWbSruFd6sKF/0yTUf9XWPg
XwcYsHsOxCy5JAZRwr5ghy9fBNfZcjyIMd7jbNS/TAfBclYjJxZxLQaAhs7hNRyUT8tPsyILTTHZ
pJmkc7fEJLRVszKwDxqUId6A+/vQHtUwX1RLloG/BqlHZSC1+aJMoRWaOn5Dh6TboL8Yh3fliYCM
+Iiuzj2ZogtrIALKEQeFjoUs19a+TRfoKYgAw6F977fclQvFs0KCyp7WGgsijI1YtXNvYKgcnfAx
JtPf8RhXyENXe83yNwc6JgjJKCpl1AhXC6UE1b4ghYw8zfi03PR8iIGfVQKi/MvREz/Ms2voVpMN
vd4IiIpeT/KGKC91bjkh/8U/9od+ll2OCmE1+FM+R8lvaKQbBwiWJqnp4iIb4I2L0razbHBLpidA
BkItOgWkd+n1F2ySYjMQSBoIE5bGT+/fvwX0NpXUhCnnUWM3KGNjEzH/4Uft/zEamnNyVIkn4SG9
pgTdRjGzNs0YfYrU/AuN/LV+ePzuef09BvE1moKiGkKBRnMXFBrHNUL5CZ50/ObcX1zJyD+L5WMR
DtP1QMHJTFHUW39/O+Mp8WIHALthMpuNhQHfNinNDK5J4KDIs384hFpwAcgpnefdCzueEYkv4YjM
ALTN4SxuEK7mQiknIiOaJ7NPn6EyNxyFx+miLrYitrau72OyJHjmQM+jgCoKvwtjk+ZBG6ZuEM0p
qv0SiEMYUY1to41ucyvVRb+g5RDyE7x9FbDj0q0N7eaBgzHUgp6EDTwzxfpctUKSLk2kawwTeMXk
kUEpChHwL8l4mRJBVFbdmBFx92JKLCyfXdsD/7scNU0+fPvm+D0pH5LZaJtq011gJNPiZswsVbPr
O7EuTtQZ3GN0yms3m76dZmzz95MQfxl5OIyFsCR3iDdKuan/pnK87DZ7dYgfov44N1HSOC/jsPAT
MVj4QxDu+FOyV1TVw13h+1Lmqu9hrlT7n4G30m15Wau+wVrROFWcGIeD8re3UZpOX9U1s3T6qmK2
x1BnfRS/fJ2ic6zLffn2sFjLR44CSuXGDmYztxmsYzRIcbu7gp8A4gqYRbgrgKfILlvtHWeUuI+C
SXx/IehCBOzjdH4F83UVujUsSFkTgEIcjKEEDCz2NAmDSifZVFhaIpmDSMoqJ0gCXSWnPnsCFkzF
8EIOTQwyAtgF1Np16vbQZ/8K8QH3zojRlnp7D6Zk0MvOpuijSPepLSv5VmDu+biW8fbNVm+WnKfs
mikvDoelP4M1ExRYpMiT2MShvRoRJmeE+cMfjxiDViYlh1oXTIW+lNEfKar2ThNNMAXmjWPnivH0
IkpW+D/VEP+WelByQIV6Pu8HD/HTQ2jVoDaOhQ18/W0GFMZtpeDaGRlez6M+/Lkdp4Ds85CzLJQN
pqqNRmP7YoZSVT6tt6Kp3eZuZVN8pcm28EZjkkFVLwTca7Z7QiCOUuRsnBag4WoFNLijuGrwHawQ
GYmr6R9zGOvXN9CfZz35Qr+qmHo1UP69JE0sme02MRZIv1KYdOWjI2ZsrftROufLG0nEEdtTd0pH
CJTu5MrsrNGVOUlmsMP1qtuQJqxBKQmPezKd45xVw0Amt0xde56rjomfzGYkMoMFKx149sWWWHVv
DUrA1OfqdgX88dKLDNMa6ljbt66Mbq8KTX3yRJYzuXrVuCzzACgRDH8ZY3rH7t5aGFGdqA/2aDkg
RvmQMdiGpP+ED4H3WDm7+zl6WYliXJwifRwcCXhWhcHRS2KlUFzaH5ZEIquMl+BAyycsDOWi3mmq
5a/a7pO0XBy1FyNLVR4dhWcnY6PUdLbhE4zgJCd7erfhdBmpbpupn9x0zu2mCVvOnbrDSvCSxEFJ
NTJNJDKt5joArjgDUVJxK9yLSBIq03Ta71whTW4IbKDHuKrO7LqH2TfXrMRGA4WExNq+2LXoLcwi
ud/m+QGT8cI9m2y1iVVdjAn+XyZnwVs6f3f324PSlPZVCaZN72F3Nibql6u9TSmvSfKNGd2BGOAz
fVe+W3+X2ra/37crFYa1UvlpuJqdJQOKBnFXcRf+3Y02Wg4pvtFZAxs4acrbe3v0v5YtjGhtlM2t
EDDBnOHsug4YsE4dax0EzWyta/fT59YO10LVvrOhdniw/ip61W/t8JNWNND6LLjtvPRKyvKsqgun
3fTeODzJOjaw4ubFIuaNJBVSnlmfVmHSnsh9uTIX+ibIw41P6Q4Ihgu3eHudc/Ts6OXR+yMfFGwC
sata2RBBW5JEfVR3HYwCxeqz6/uiZtby68U1vVbUANa7xHCjeeh1fbecmMBXThk140LI9eYuiRDz
L0RwrIV2aACuBD1cTEiUi/IFfNSiTXNb2KVrM0T0mbqGQoJh9eGNxYYSkIVcUNG3bn0jbP7Bmdo2
N/dRzUVJl9e6JRbrSIesALJCq0whf2douDENsGtXd7/u6eZJCEZXbbLoajy8z4pIiP3o7u+d2cHX
wRgdiqnwPUeNS28ssnPu9rQxJq8NSdP81sSfQZSyHoM/SbcViOMK9ZfzeTpdsHXDjLxZp+k1PQr5
WntnPTnUpt3pOVT1ubloAQ64p2pWotjDu+C+HVRLLIvb6WyiMdlyINpnWn6ajHuoUkmng1k2mhYT
8kCFGdBV0SK7jIvp8T6T2YGtSbfXUg5TipBIV2zwe2UCgkcF2Ri+QGs0Kjke1W8AFsqIQKm0/2jb
BXQ8tgDQ7F/rbJRcP1yMhSVDJ4AV80SrKFP7ezXvhqJaGgTE7qq5indH+V4KRrSroS0orzqGXJ58
zHZRifJRWBfBkgDZcDYaDFIUPxYIKK5X0NWVia6k/f49JZOPVsbYNM2PYuL/GSgo2S5BRcHeXjYt
lX7uUTrDnNHqCAllF5yMfylppFNoM4LklOEyR3rIub75cR35hNv0PGUa0kpDsalyDBoKcGCjIZ4o
vCT+jlliOabNNE0HTtDU+wqhRF9hjfNFT4Bf2px9F+OyiQmTfhkP66IMmSTJYGIYjxpe54ZVKymk
A1YPs3UuGinKBR2Ya6I1GipleY/V2+k0X5IXyHjY47zYJp8wGM1LlO0Fi2lWt+vDwfp2tjiTuai7
Vv5tfk8ZtvsmAH9u5fvihhvL83Hj+PgloeKbRSTevH335v2bwzcve+9fHveOj979cvTOqkuYk0aJ
dBKcK7mEzoCFhzgiZ6h0PU9mPeEzbn6uif3qYfoJxyu/TJ2/viq/PNKctQjsbK1SGvXFgvQT9IS3
90JWbgCL27/soXCEAv+7se3KrvLjsru8xLbBvNnJiRpH1sURrHfPS2Oo4v1u8ldSS2uyU1pj+1nu
8w0v7fmK8BnC81fd6RY+9CUNQosASnlWZuNXkfuX0+tZFRfzUR9mO0+mOWkypMUB+6F+Dagq+On4
/THx/sYZr/YlLdiPOFfiI2BH+pcefqTM48UUdrOFAPp5YmhCWIzcscZaYTGCBpNkh3zm6vbPkkH9
wQBDIIwQi9OcR4YvelwhaqNWT+oI6LuVKcXPVlkUFKvfZ0H2nLjJhy9ffAFXKHSoYJuvg/cHvWcv
3plBj+Q77RQFt86a7lCDcAPvXU9fMLB7ux3Nl9Oe9vz9BnD1FQVnGE27QOB2TEvYWgBULvQ5yhrs
wv3iDbrfWY+6/HgAXBWO8Bbt2QYm/y/fOG3Ruwr0T8SBQKbjEVrvwBKjhxSHmYgwOmStrAAMPYL/
eQIszPu8qxO8Fil7Ly7CKg9ycxI8V9emdN6v4aohArpCO1pcKxiB8ezGSgPeczjOrr2AWaDd5caF
6GJBEUQXHOWC5aANYc5ZE+acfNxWqrxWtWoIGjAqiHiq00qEEnDe/hp8G4S/TT+xU3HsG7a2DSOk
SV7eMLHmxTYto91GZYoqYCRo+AOP+zrOSbn41Ng1id5KkTY8VKdahnE0aSj3G5tQ1oWDTTtxbk6B
VzYeiRAssBLpcVjp+64H07p3F/vrdtFcl+vdP90U3CgMoIaLSbJY8KaTZNM0Qi5C/Jp6M4FQxxlc
rdNseX7R8p2ONQDlIrvmgXC8MlX179K9gyUkZaAhNckbakt48Yr2eiVqrMen9wN+UvJJyIDlT4Xd
S5jyC+Gw9cmgsmpVgYJvUHrE6KGhFV7A2j2MNwWu8ypcRj3lcP/N8HLAvHafiColK8oxnYCG2e43
ZulE4UsVpzcZzcljEO7HwSZ7tV53ThGUr6gSl1xijYOjbx0D++59ImKUkovyUvdb7ZI5f5ErsHD7
rdemaUrGR+qxNtXCjH39bJ4WBzw9d0IuU7yj5vrhlhVYMfm43u08LUbirdc5cmTNCsFZr3OwKBGE
c31LBpEXWNQXtxKGqJieMxPlXvztT7oC1CUg4ov/Nl2VWE1AM1Kt/vVcA6UiPRtW8thuclfnYPjM
+DFy4RWtXqHoOnvNdwXv8T2XwBlRq9lsvuLhANE/Gyf9FF7+SBBEn8i0BN8gg4uqhRQug/uPXgPo
jod+ue9MuCBAn45l3f6E8QlN40YjbFcuM4uVgecedMJ7wSWnXK+GR320re3xMmGwVg6jOz3f8WKr
2noRuNdMlbTukS/NqPTFkefOZtiTgWYDTIZYcmcjNMm81eiqDjfjfVGn2pHfpmox/13wKGPFHbZ1
CACetjmC/72QTJEhxC1db56I3r6tmO16mHlH8L351efC0b8tmNL4bfEpF4ciYMQQKbTnm+Fw1MdM
7p9prLz8HNfWyAO84m6U+HtHJCDADD+lQ9sMCiRnpPbFPUnyhKj8OJ/hWHwJ+GxVrnsxE88nn5/i
yvllVmwD99tnuCWtNArW6pbcYTvuJbaeDKXO2QuJli9ldxzifmN5EClBBSpAu1o8cc3y7oS1Ll9D
ZQwW29mi+LsYld0MP+QPzX6vQIRbIwxkQkmCe2RW3OuhuLfXC3kzlLKAhMDx1p+q/0tms+3r9Gz7
T1/wP0yN+Ghv708iS6L7l38/au7stHdb+/T+UfvR7p+CvT/9E/5bIvkSBH/6v+l/cv/ZfuZiMRl/
mf3f390t2//27s4je/9bQO7t/ylo/mf/v/h/3381yPqL21ka4N4/3foe/wTjZHreDdNpiC8AV8Ef
tK5Bo915ni664XIxrD8O5WvERl1WiCL1zYqrKRS7Hg0WF12Om1mnh1qAMZhGybie95Nx2m1hI+Ty
9PSAQoWMs/Pvt/nF1veE8eeYn2gEbYYB8BjDrvJvHyZX+LqRX52HAc4Bik2S83QbXnx7MxmHVgvk
UZ9fpOnCbUf72kOFbTFfNFgQs0/nwWjQDafJVfiUv6dz+DQYXQWkqO2GGA0BKgfB9xctcx7whC+t
khgL9ymh6sL7+oX4At9G0xlQvzyrPE3mQAPQKH4PA5IKXGTjAaY0fT4aL2CAEQeY4VtLBteqBS/e
/h//z/93HAbJfJTUyYFT1eDILLBNmP5N9wu3TtpfUFfkb2vXPeLieAuTqPnp9xkROU9bzeb32+K3
eBdwU+ngabv48eme5x2UM15uc301MhqCXK/JEvVaT61lIpOYs+yGFwoY4AxAEd/BEIIDeKzDts8B
Br7fprZUy2fLxQLGK5o+W0wlOPEHbg+D/ibQ5TvZBn8UW7kNe1nc1QVK3NH0SK8vvZLfkRfjjVAF
sAiB4PeLOfzv4inGq4cTcUEPmJBBPXA0bvV4QHuuHt+TsZJ6fEdh29TjM3Iu4sdt7GmbezVGwYG4
cObZNQAIj2cAh3ucA7R2w0ehsxkvM7KWAoiD1gaqXT5JotVtmr+zaOKH/DPMMgRQ0Tg+8Q7QL2iR
v0NBZmeCfN7Xh7mfTSaAE/6OI97mAiUl+cpzCm6Lc7/N6PD/Zvf/3/MvRf9V3P87cOk793/z0W7z
P/f/P+M/lCOiEGzUX4TfbUVJfjvtB1EcdJ8GH7coqw1gqI//BexfDhxWMhvdAX/109vv4FuCiQXg
dwNv9EjwVzF+GacLMhtEphZTsXyH5iHD5ZQQVMBWlFEaUw8U7yxKG0JQ8ec/BykL46Txyf/810f5
9Y7lGPgCf9z9z3eFBlQ11eK3+BHtJIO/BP8TRFgZn+7i/wk6qNXiNlQtHl3wxx/wDT/dmUNnl0w9
dF4etKVKG/xNj2iA3BnO3hgSeT79hR3JAkw9I151RGdqHHj9ZENsmTxHya4ohJoDKPq/jt+8bvCr
0fA2GsQ8TNwR2j01WvbYFENdzG/FLzns33HYFDbxw7sXh9lklk0xucN/ReHXv4dxgyx7GtDNJMKI
IkQMQA38zISBKPKd1ShZlxNgAKxIU+7/KQTx+K+P9Pfuz7/Dz9/v/ieWrWDzdN/EAFbTdP7T+1cv
0SCgIQiVBnDG54sLWAr9apLMohQh9n/wjjJusIG6oLJpBnsxCaYZ38YABXk/AsBY5LzVsda2kPFq
YLzZjk6+rZ/+Nvi4exf/1zZ+/K8WcPF3dMuZ3Ylm0wb5HogCzjBCVYitckX3hbL2SKlJjDNf2qk6
VcWmgFypy2Y4emt8pxuWbwoNy+rCD1lUUEdA9oO3/P/ELPMwk411goerSYbXmaRAG7q1hwwMd0E/
wQNMxw3xzCJLcphhY5LmORDcNbJjiL+jI2odUzQYGywxwi5UpKRrL4TCOSK0BHXwhCKsEZUYNwSZ
GCu0BVyOqiPQIdVBdmk5QWvqC/KNicUpg1HUAqBpm2I8iAIH6RnORB6oZDA4uoKaLyn7FFrxEvGK
ieBFBzRUkZ8IFvoM2oJ/eTTyNXZXC3a4o1i2L09ksQ/2JYROsKIqL4hZb4XxqH/plhfLVNG8XHO+
AMSa6I34busuxn//9J///i3pP0U2/9Ppv9ZOC2WDtvyn1X70H/rvn/Hf9jeBjhGIuj7MpXmRjjFL
XgejsdeCaXIFqBZxL8YLTsbZeR58s71lU458+//0Fj0dNfmIWJCcU5gKlETCf2GpvBbMgZGjshH+
wptQYte48fsynd8ekwQgm0d5bNQuVD+Yz5PbxnCeTaJVLR2Mx9CY0VpKkZdzbEZk88qDv/zFogi2
T/78/dPw4en2OWVvgeF+DP8cdsI/J5PZd2Et/B5/jxf48yn+PMefD8OH8PP3ZUbvH+L7r3eefBfe
nfRPzf7nyRSzWn5kn/MOqT2FSz6FwyIlbCdo3+kq/QRNtYlwhMF89RWsMJDN2NDJhAnK0+Bpl1/Q
03ce4hDJs2K4ZZuwzWZI8X2UxYS3TYdzmSaA28kNvE5+DuiFB7ADKw4gkqMdQjJJ69l8hP4/d5os
5sFOUg6aRz+x9eArJHSRXIyx24boyxNIXFTVLZKcAqsvp4N0OJriNf7RbqQQBbzoH/Qd1aC2ui6J
TSvD97raNkXnDlN0geAlhCZiPTDpHURE/G6zhbP9ihREZDKR/zpaXESmm1SMAx+L+IkNFFLiUMXH
79AfLbsOpul1QIGsI/YgUcaPoTNETYrP2fERyBwkqMT5jD7excZgv5o3ssu40AdQ2fgXT1QUogMZ
sS1yZrHNPf1dcSKa2SOabZLD0TlLBhK8iEEUzASVCM2RLHAZKJeLpLXYQe5onE4oxeFgdIWTXTRG
yHqF3AI+A510sIBtO1tS5lFh9CwDVBRLsGhzdJWyJhIT+2Ex1S9ufANAJZ0ODi9G40G0UGu8aKBv
hgAsBMv8/DvKpQvk7Wv2yGNrXGRAMcsV4BRcgtDkOi2Cj6bRuMBh8i+b8ONdc3oIaVmhbbg3m9Dy
DlGghV0g9eN88oywd0TSdQzWLshoZi1eokgU/RiBnpvLjRIbi/DwFtDrKMdUyXk2vkolirfZ4PId
w55DxeYNLO7uf76/2JFsDI4NWQt48/1MvBQjxdczg0UxBK0imUT4dLUsF0136/Nu2AyfHibTfjq2
Jbl+gXDwXx95YXAb+Rdt5AzY42R+G96V9dKSfJOxyDgP0SWLPP9HLUsp4A2MpSun2VPBR9B+nJFY
gvlCjieA3pknPLLTUDBBZ3jYBg3eaIqST9GSsRQAX2MOp0EGIwDQFyxH+TigoMHQCFiJnPYR1bfo
oMH7SXbFbRst48F5lQ2A94IP/6UG3X3YfHgKzQ/ixhBWKo9ElTsPyEvjCAHzRYnNeqDqAdRDYnmC
22w5V70wvBoAmS/PwqdvKDGRCoGDfolUK+mTTX4AxFbAfplk72koEfzqDmyhi5He+ss5QC8HRzHG
wFoNSyeivJxIgi6qYu7fDCj+GeBh1JtwQ8qeJFxrDBiD5elrQAyyWhA9/pY0hBjJap7H640Hm3HG
A682H0sbFoSxHGGrzRaF6q81CmOLofMJXI6qEfz91N7D+2EouVOEnQpYyoOcJBbyt5MncL9JqNXr
4sNAq/EP3th6bHQUsymhHyTK6dhrfLG1Hp7QWMDuhAbudOEKqPWZBigWFIWAcqpJIkrgYVr625T8
d41vbetb2/goMRIiSmgCicxpGxGmKI5bTqVtWiA0j0UOq0qRIyZIfDWATmFcKAkJIZo1paZVMZHE
Ye3gfGsI6h2Y3F1soWkmupSNaSDDAMa6T1O0Vj0ZJW+Tle/kvrpY2lp4A0HbiBlGD0T56+SKrsQr
R5YOzKbYDVS3izvqK/gtpejfGYVRuU8u4SfhNq6XymBhp74YqNcUS3FbWYIpTb2bZoNLcGkV4hze
Hxu/leG1KnB6yoOD0dpUGk5Ff7IvlEQdZODXBso0wVa7SzKoQeQRiYzZ9VoEiEV57vejybmt4LTs
I5LxohtCKRTEPl3d3vfbVPD77UQhM9wapbeGhbeH+CqB1XiKcn341BiSjUE0xmMKuCIan7SB6yVJ
Pb5TlBbOn2cMNU+ap3dKQIzPO6dEKzCcIOXFv5iEvvMWeciDEqdEWGY85Ao4upPW6R1OypBYwzNM
zYezYQn6aRVSR6MLwJfLdbH6clKnLzTGiySfZbPlrBuiHFu8TG9g2QcparvRyy/UWyXjZcR3wf/x
//r/eohWY1w4poAF1KpjMU6j1PVFFj49ZvoD+MgkB8LX1x/09TT4//1/AvUJGSt8bayKJpq9s55d
V9xAVRXREp/GiBSSc2lZV5egeRdTgT7EUsfI58BiqJe0DOKegQLG1SKI55RsWIHbAdAhRhyxG9bi
M42XWIPzmkahWGIogE15eEu5nYAnhHTpK6cptJWCo5PrxmJE0859XE7yS1LbaRYqbDY8AW8GIS4W
DLbOvIBtutoqScHxyu7qFbecjK33na32uasQh7hrxLisG1ThNWTGBa4gLkRfDYheCLEgpCPTzsUa
SNAeLKImXIvZByCI5hiAI4p1gRxmm0YtSbswHA4FwJHJirjFhnEwdAkFQ/Z6hZ3C0IX7X5lSl5Tt
9s1Jl0xB6aqjD0oZjXPvWqKbSao6FG9Q6f9fhuJfyYAtYQLb86E4cFoLzkncS1o33Wxwd/cf5c+/
vf5HHYQvoAKq1v+0W/vtgv3v3qPWf/Q//5b2PwINaDMg0nRzVk7U8tQCQXupZ4yb+xyF5PCmWQuY
NHyfUkJMNnsRd/cyR9n7/7+9N1tuI83SBPuaT+EB5aQAJQACIKkFDCmakqgQOyWKTVIZFa2UEU7A
QSIFAmg4wCUomqXNRd9Pd12O2ZjNRb1C3dejxBPMI8z5zjn/5u7golBmdlkJmSECvvzr+c++QHon
Prvs2Uj6J7PdeAYsd4qBnRrPGoOzT2HuaCYP6Xf5NFrGV6DrV4PzpEeYGSlc3nrPrbjnVrLPfcJz
b6Gjn47no175lK+WgrFsz0/MUKiZH36ImDig7tEwUSrPgxeKF8wX1GyI8tTEliJ9ztYsOSkrFVCm
mYiUOB9lKKFa4s1DIqBSk659MfOEXlmOwFXW7+IipDu6gKpYjbo+7W/xS9qp+mh8VrZ3hfJYZV1O
9gSLnhOh7cCj+WiaxESGkS/DOHvkBcqy7072HYYfSowA0/lEQBAxxPptkMoXaNHpS5aGu8XlHT4z
5B8Eb8r1Aj+o0AflXlleTM8i+G7REOomy0jFLiyGl57VTRpJmIToJ0wvNIQ//MGsmdfcBK3RMxzS
WFE/lAlbYJSLmU8IaOYTeluiwXMPuPrQmLF9DuuAH1eBIuU4xjH8QD2C/YdPOTvM8ZfBqD+upxep
vcMXDI/GV7hUQTWq1+tmzCz2TXBcJnXR4onP00cVweBrFayur3ZhG+F3NCbqqjuc95KUGKkKhxgM
RlnvM5oys4CypHjTjkH8xsLH+Q6sLLmBXnpp5/Dkp+RCnuNki4QR2uDWJvzaeuZZmSJxyoU7AJz1
7tUroJnsHgIt0bVJQnCBFeJtNWmOs71MBSHm2qA5T+rT84PJJI2+c2jy1//xvzBixaRl8whjt+jX
//F/hTdnehPssNez8cgslthMJIO4aOrArn53CbxeJ2G3jBydYgajK0aIF0tJemaUHLrGFXOHg95L
aI9dPktexKGvftgxvfJT+CLbgO7K7GlJbetFnnRFB1ANxmqWn16rRu41vliRF7gTky1IHnSJtqxm
wvXfiVgYMfMzY7gqdVQr4c0o2/Z9VtdYrcuYJD7T2o59jGNunv1//88//09V2qi6I9NuMp0egLZm
W6Xr/WF8ZBuG7pJtvmmU0pFLJO890rawo3xxB0GLrAfSnTB6JP/+ZBjsj0hdo/EoKVm3RB9R/Nu/
evoov53UPD00VrX8M1PzDM6Lp9ZSRYK1vF05fVCII86Ok5Ec/fmkF8u2ePwBY3midlHNe4QBLI3i
ozHPbYQMsaWw2fkEnobSMONQvfADUwe+AiHrDCaiH4xQypZjtE2EDMAZvuv8VaLj8Xya/lCtP2B3
1WPfu5VO1UVa1cRsnuOxOuukR5Yrs8TUkauKPtDx1UgYAl0uPdshGCHmJzK4TkqOiHK0nrF0Wjpl
qF9BwwSF3K5FDAyWRvFkm2JKXJ/M0+Ny53vNtGmawL3fXRbRW15VNt/oqfamyfcmMbHGPXtbSAtu
8Ddz0ov1b+gWwVzfH7fc6H3aCcC2mO77ZXosgFqueeTexE8Lu8GxzlJg4JsszihlhmCetS12rj/O
xJccJV4jnHzjwCfkBUMLD+Hg6JjnQ2+n8SlgJIuF5HLpmd6WeGmOJJIDezgtRGv+vOx50UHJXTkb
NERqwZzg313iVDtkEOgxf3dJQHcVxOYxmzDi4eP7gVhvZQt97gKXHjMO46tXRk2pQPnMuLlfWa3Z
0XTQy7i6CzgbZMSONwErqX3peLGO/pE5mcwu2K3aPK5mJxnK/SXjm9254S2XICe6SGb1312SRAFF
vqkxyqp2q7y3RpJ7Nq3es40eir1w3SFjNoHiva7bqIfY0zXOxnSwMo7/S8ZMkMfsvTGwqKVJrLqe
T0RZPZ/4tCD/HnNUwZu4Iu/iWwaeF7Qy7vczjQxSbUMx4PWjgDdQ8D5d0PE7kcecUV8ymR6qetEm
r3feU9l9IoTH4BPm319wWWHLSSvTw6xctqu58JHaXnXXyRTxoPCou2gzXSpqWQCayI6wnOXBCHh0
CJdHbbIakcxTM8n2K3VLhGgQTrGtpmKn21ahkglK8GSoArcLpOqJCmS7ofEOyZsp+4NRD0wloZdq
JAFJvp0SYkN4LPFC+RzCw7lICWDJ07NQzZrSuflA0lGqeINfUtFICs0/fSq9faRj8kEUKPj3Y9EI
3fiDsX3gIX9k8VUnoZOu4475zt14bnckthKy+W4Sys0As15NilJmhfTOdVy3qtHNJT70qP7kiFae
Fl4FYD4yWvSepMrxBusMI6zLVucdMdCLxDjqWx+m3mA6I8mDrhidSSCH+vNEP/DrQEjIImtPNfrO
HDJrM/Y9F6SV4eEwt14gF8S2jzWqa3TCMp/ILrwSZbg8cI0sHC8NYItT/pVN4SMCjH03mAa8jwo6
5yi4P0TlAq7B7lfunu+uKNhnfMaKDz2dH0obagmfSLo3tGZyjbL4akRftqe/GXClkgLZl/8Ycfdj
1Ta/B+FLXsG3g2nMgFr69a//LE1yaPcoOZIh0A/6jvYglKJyFKFpr7nd82g52j+PJp9myym/otKy
p1RE0/RqsbS8HBUKywVdMEWjLkRnKM3wtUxDcnNmbha0JAJZpilk5FnQEG7x2rwAT87uZ/7LXXvV
dPbRB5/eMMOTYMtZOVL+8KkanX6sSLRdb6Zc4SdmymfPvu+ZcLRTvtLz7ew+DNGxtWebvsNMC72R
O+9jeOJWb6F3wZNZGqVngRr+slPM6LDgbnRZ2N3Pvk/fII3geVIbj4YXeWcf0czxMXFEFuPMNPlS
zowcem/Kbk7GtwQWb3VIXffaszIYkJ1TKdC5CdUxwPgsD/kSn/dGpXDG+8c0TR7bAAzm9BPUELYT
T+wjSjeOBhyycJ8YnsTJhsfJNDEkXqn3NeuxObrDcpDYvWAprp37lU8KWSYtmrrak2neHpMWsYSD
6NJ6yRJqj7+/yWPX92Ao9Nrl6Vp3qMOMM5Q1uBBpbXvOu4Z1aUd/cBeZVKvO2ueA5OQNj1DBIevY
1TMOf6Fflw0P9O7f5KngelF3Na8RofLXBEpaFw1dn4DCR+xVvB4My6Pn+VaJSp6wI5gYRbytSOgA
JHj4peRtLgfI6078lexYhqnKB2Nn4qb9KpV+rsBL4QnakdXOy/5OtAwfrrXD1WSex3OuTuDeGj4S
LKN50PBICL7Gc+sZO46nIJsm/JR+c7WOmaqH3EwpUDlhbf5SF6YH77EPSkX9FzPcZSRJ1HssvE+T
qyqdZinJJe8TW8XdQHiYT1SARby/dHAggcvwlEREDFRyJNSz+ehwPJ51TDSxr5+Sccj0oVnJDIiH
E5XQAzOvJTM0KFSKHpZ4DzcFF/aeC/Btrmkgh28wA72/1FGh/kZhILSDfj5lNzvph/ba9VtASHDE
mHxfc+zzHrtf6xQp/MU8do/5ZAYScDZHYtibWQimCpAWQRXW8xgqC/n50zvNnF7fs0mzGN90cjXO
D7O5yp2wmKWtayWnaBLCG8EYL4zHXxcy5Vcd/zBOFx5GwGw801O3/W7/plM3vc2pqxceu+xAmCtH
hKPfZHZgBX12ik4zHr72YJVecb5O0WQsOmU2Aya9xuAjh0YhaMFpzpxPTUZ1x8NzvRudbbPAe6AA
y7QMlnGjsv4FN1Fhw0E45wZLlj3feRlu4PaQFrs9+J4h/vDP7fD9UygDXpSlwfojVBY7GOhSAYPT
RnsmnbLzYIhqkdfUcoQU7J5xh5M+NE3InSY9uGZY1yaPWJV2/s6ecsb/y/MV/3vnf2qsPWpl/b9W
V7/lf/z75H+kDY/OT4YjWJ1ms0l7efns7Kx+tlIfT4+WkZBvmcMHINM+H58/LTWiRrTSov+Xnn2P
imQRXWuVoounpSelSPI9llqPSyTfQSR6WmqulqIpPbNSYnHjaeles996svKotPzs+yNzaWW1++jR
odfiGrfYXLFNrroWH0qDTbRgnm82b/nC8pH30qPbvGTG2G88jlcP/U5bK3d5/1Hv8eoTGQOt6P8u
qeXM+ScWLDn/B+V/ffQol/9jpbH67fz/B8v/6nvq//tLATsbj4eH8bSUTfiqVk1+Xb87i/O1wUYL
U8Aqw1SYB9baX4tSvjrj7FLGQs+1syVtKmz9zv5ZFNck2VCF0Qx9wPLJUU1OT2+ihzE0y0F4krFj
msl/j+Tl5nnWofFj/O1ZgeXazzwqJnc08GwJ/UK9xW9DppMcvSvyW61azzh4O7sb88OSPsWh3G5X
oE6yngEsHutzVtek2U0XBiyrVO29BmPRM2vKCdLThp42BMtJJust2Fq/rVJ0Ep+LHZdI1GoGTJL6
UT2SVPrVaHtjrxq5sg6ZAGg2b9+YIleVaN4AJN54j/7V2QRBW5zuFcskK24X6NOpaaPHjma9YXZL
2CZg+sH34nNkA62Xbp/bt+eCrSHyZ3L73rIJKEKe+a96aW0BhH+/zLZ+MMcN2W0N/eegqn8M/W8+
aj7K0/9v+V//w9F/RHkS2v+3f43+d2UFPDTDB8am9g6oAt+yecj7Obw6MrjpuHnLqO1wPSSrPL0/
sWs2GxPWH8UmLcnrnQiqFUvw6zZxjlIlpkPzEucTz5OcYvIyL+lGm8jg7MQy1+PJgNidwS9KSqJ0
kgyHnGjTBDfb1FX5sdGy7mRSeOTHlsnjYcbnLt+Q5yTb/6LkHvwFQc9EXYaJx6csSBaUycfhk8gj
DbmmTQtJhZBEQzKKsLqg6K+crzzE//+Q/N/NtdZaPv/32jf8/w+I/8tG/vX9RElHyUwdrZ5fbPXK
hNkqpnTVwmdwdOipo/F1D9GhYL3pwgfmoeG5/1WMudDt5xxHaKS+wwBU/jcbfSQFoJ/Jr2qyJsJF
SxT0LntimI6wXZCM8Oq6ZIqu1iDOfi4f+KVBw+3r19PP7121Yf3XvDRxxuSsher2qQa/QrLBqCAn
QClr0Tl37jX5fU7OXU6bcL+ZLuWysRWthBQnKXse3Vf/HpMcG/xv4zT+BiLA9fh/tdFqPMzg/1aj
9U3/9x+O/7dRAv+uyz+5aeSrP83iw9RwkiiEg1KsIRcZKhbskxoMSd+eljIqPlNlSdMIqayQpMVK
jFu0b2rV59rXjEQqjJjHvrgf0KmFnUAw+fKmYcla2DQIy94XN6117Bc1/qPcLlAD4dt3tVpk9ieq
1UQNG0asSYEwURfHhzW32XY0N5YQQ9SZg4JsbJlqItFBelZjp1UXhXJj8qtb6cKoXZSgjBEyup/A
3XeYy7J6tzSG1CIqcXJQkSxJXq1499Jbi4tubcde0a3X49QVziIuYpSElbacoGouGFdYd0VCI+3v
2xXeollr7a3bVdEycWYW1pTjvRbWAkU8QM6d/y8BOQ8vFEMejnYvOryI4Ax0YYIcZvBx6o2TFH7C
Y7ozHfQSuBad1PNheqJtYeWKG21his5BMuyVwlGwrn2PzsZJkg1bDEI4Z1BDazU8IXApv2Rr3kXM
DBtk84z/5Grgec/II/n6dtk8akEgaDKcKPbBV28MBbGLRTMPjBCYujFB0BKTtFB69if+G+2/2ctU
xStajsXV9myDhhngXwczmLuiIijYP05UR3U8mKRRzDVwa5oNlxDPbNCHSJSwB/kwgTVhBq/zcb8f
zUdEylOouiKNa+5Fg1kIKF++MqYA/DP1lYrKLpftLddmND85TKYla2aSBnVp7M8TFGtusr2G/rYa
pbuBgh3nb4YFUGIY0ZBNfs4VBu80W98CxU3doCfUuMkbpuoghOST6P1WhIiK6FijoUKQ4rpK7EGp
a2HCMeq3XZschlDU6aUrvAlXFBnq8nHUuk6TM45/8k2ttuViFWdWt2nayRj4oFPg8pwJkV2WrRVD
3iq/8QLKnJ6AlhdavSZn7NQMyxn9KczQeN0mG2JgA4/p73E0Grus0uM+NnwwjcZno3oEJ0J6Ixlx
efWkd+MGwxrJdvnbmvGmCS0dLNlpMrtD0mXVP4ndM8cb+8TLWT/zBJvZ3jtRa+Wi70aqlbsGgV7I
8d2NQZs7/kwwSMHEJ4El95mpeJImTOgjl/Hp3/7Vq4FCfDWKhIHhWe55YVFEM0a9CJXU+e3Y5PLF
2+pMza9K8mMbkcRvzWX+ky9lGzPcYlCVdXc8dKzjC84t37uG7/PYvXmG27s1m8cSzZ2gRgWku0GN
Ck4L2LoXjmZntpNW55RtUF8qY9jh5+FuVrO+IyYyfTQ+u0k4KHBBmdXO4umotOiNxZwkTQ4ZK7jX
3ASVMuS8HGY1+PGrn0MOV/r8rXKXdyfrsxoSdZSevaV/bRb8RQyujIlfMFzKMD2QBhz6Dnlaj2HD
MjjurSwy8kwwewALFcv+Lmq1O09n4xNUN8BfnxOMyoMTHPzkFq0wi/Guj1jGIVyJALrViJ1fDpPj
AaGAWKIR0gSBi+cXlS/gyzWjcSqpD6K4z2W1IwXIW7IeuvRpPMLpv2476ZHSs83z2VQUbmm0HG3t
pIu3tphFk3a8TeafPiMV8hPYunpyHoNtqI+SWTVqPmnVmw8f1xv127GsboKyakQjvMCRYq6fGJfz
mXnGpZngAHaOfAEW56gCXKqDbvKj9t7WDosHh8Co4Ie+Np8AvHOUsMebgXZ/LrepKVPcrMB46dkW
//XXhL3bblGq5jrGRChFalWUd2RPVLt1J1JjFWZ3IzZWkQZyU4waTctfgByPjO/fDnwm+PtdD5Jp
wkp1/MPzvXtoT8eXSmZHNUm7Bu1RNNCIEl8cvb0Uqk0ZKYK+H5gGVRBdUUF05WHjrpJo2NxvlUeP
aqiYA5LCdXOi4aCfcG60MqLmv2Tq3J5R4kirByo9HyB1hSzAmpHEG43Hd12BolZ/+zoMiYhJNFrE
ZuWUiBfdSoD5PnE+/LuvBbWpK8FNHtCUD/rUx3wKJXMACc3GV4Dg4RiaBR7ul28gNRIMWufvbZ5V
o6yufo1BD1kdEg2JRRjeinnid9wYD/jNPO/07OXm8/c/ZrWEz7a2X73LXfxpY3d7azv/8Obu7rvd
L2JXLB2FmFQuUKH0aF3ldqrAW6n/ZiiOTz4R0bfiWTr4hY7yHwfPvwgS0JguM0t8DL+fDhUKHq5a
0F19vPbo4R1PcdDibz++sT/vNPqUTL7oxMaZGX9KkkkW6u9wUgskmO404RS3CwWYBfYjYFa8m1mr
r8VjHX0VXYxyCbdkevJqClh/IonRPmTBodejYaXViI3NkZZrQKYTSILdxFV3o4cP4+6nOdTbU5+N
tc4WkdZEgZ1DNF9gYm1qtKhsjMlSxGQ8LdJ71mq8Ova4TjLMm7E/Mgen5paEAImzrT3LhkjU0jMr
DpwNekkQMgHDnvBNviGuOHri2SZiMyIGO5skpjQYHSdTOEPOlWNPQ6tRPRNoIZwejWmxSL7g/KUs
zg5FAL4dEjev6HHT94sx7AJBR5sQhFtgubrL+Fl3rqbIu/Gm+q7OQ74bX1efRV1pXaOb/9JhS/JS
MZreddj8rg5bvtthLxZRnUC61rzZ1lBAGElYHItwKZkZhLRyeH8bJ79+i42MTmqc0O2ahcF9Ee72
tt/uME65Oz3wmjEcLf0+kAsBUXi4trayll2qh83bbO8tJ4O0xjIXxYK3PGXmXX8C2oIT5kKFzkrp
2elKVKbNPYZXJOThXtWZASqLDK+tLr3Y6iKX/snJfDSYXVQlCwug7ialz8IzToO99QnXtaQ/pys3
LagY4rCiNFnfEnf7E2Sb8RdXLgQn6EYsEAKOpBO98ST9uNdsNvZ32mKsA34/nA+G0Hbe1mLHFj5d
AbpElLb+FRcZ8AOmzELR7YGWX/UXVdoqBtf0OKZ9fL2xCCxPemtEmF6uLbpP77fWHnITNfpyzWNr
zZY8Rl8WPca51Z/h3zsD/LO381RLV/J2ApLup4aDyWSqLNvtp6kBpdK4Kl9z+4jPOyXGQk797beO
XwuwJbdTvHU9xMe+3NxbtJgxJzfe3Ks1W4//Fguuaxil84mYuWgsfJzq0XaSECsVB9B75+X11uRa
hbM8QlKBv+AiJSxY9KVr7deuW7RpFFH082BRvM4t6gBrHOhivxTpMfW4Ifv7WbTH2uJU7YfEfeeq
Bt+KGqDFu5KDaymBC6CVfEqLwbyguHF2/tyaAX6kR5I2efqnyYIETmLLQHpDySulRlQ60pKF7ZYL
9Ownkmmg+YHrTpXRujaVRkMU4WMyMRAkMp2PRi73u1p3kTBKajB4eEaSR92WMJwlh9eutnpUGZew
23Ew8lLGMawYoZSeqdBznXPYb3cg+22rsNgd7IaVWOz29YWrcQH8epGki3ErMOuXrMJ187/O6esu
zPmtfb1C9sqIxV9lLxe5c92eiSz24ioc8deXH+HSpIj1TBIjZLHyFxGes5vCQ29Jbuz6X4d0UTok
6XtLiF/PrJmyl3MuuxO9Ofsq6gUk7C09C+sIpXeHFW7G0lZtjOXRtCj3xGMQkWb1cSiO3EhIJGWF
eO/YbOgc6yxxz5z+fecF4D2tR/vHSWq8hPKph/vT8UnolnAbSmLnOxK2KatHtbfDZB7pYq8Qz/Lp
cpygBbxWrM9dCBIjWaaXg5SW/EIdBJQ7d5445dYqx/DEtEdTKOXOK/Xonbpa8VKJz5QQeV1Au1yS
gZ61hbcivb4lGENUviengL5prSL1MNqFr5cdjfAC99NcYnza/12MH7xErFmqMwth3xLV5xkhsiTV
k2nbsawRd1T/bUgNrgI2COA3cHOJ9d0w2TyfRWweZudoo5H1sckXax9Rxw9FYWbJF2AFedsoIOWH
n5em0GDBzZvAhyRlp1VTQoh/WpASXwItQ7lwin4MPzV5fRh/UQqZAlPDMOnProl50YCXrhclclPc
y4LWbEYa/nt364dpx0kTizPxuBQ1YiXwPXHEIaXQVIDHCo0FBd4rC80EO5tvAXIn8awe+T6E/cGU
FrLcR/JXwll0hAnA+4NRUqniWNLPGXKwWxUgluEUL5J4WY+2ODU9nx64oYnZfMAXU3YhLjY08Ixu
yt/UrXXxlD/YZRlimKoC5yGeJjG3LS/pgZCFg28SJwpcrNqu4fN888et7ejF5u7+1qutFxv7m3y1
KKEGXEa104J0Gf3BUP3PeTA1+Q0l22T2tFSfJCfVOl2nf5JptT7DYfaTiCHJVgAZ/P7Ni8UqhB23
Odcukqcb4K93W6Od3a0/0fpEf9z8+SusEQ2gcI3o+qLlQbJpf1kWYaPuV0FGRZij+5sRhzm86ih9
e6wBSeE6y6LIJZ45ce5bE0VSUSThHUn71nVQNldjWTafzaJUNoF97Lo4leJUNqHy/ObBYZ9L6hmu
A/OEaL2vo5FnjbOHOMnnfECMe3zuhqrUs8LxjSM0Qtc8K3RF5cd/8HjGSuHKhsLW/MuEreuH12L/
FdT4y0tN1w+llR1L6zaDWXRy53+zkzv/7Sf39lT+75SJzno6fOW0Rd8+f6v8H3+DFFDX5/9YW2mt
5PN/P3r0Lf/HPyD/U7begKT3ufxdNfod/UeycRVFB6pSKqEqqvrpidQQuoqeRq93kA9HUgG93qkj
10e5ZGBLkjyhzHC3f6TlRqrMMEBUz/wGJTclSeB/vrwc1X7jJ0L6Db+CIuoc7ceHZS7Dq/mCfve7
cqmOByPFzcg8Nd2Mu8flQ6zKIeoXbMxoxeh+Ui4FaSBK1WiPEzGVXb0lakuqWKATWyeQevnANMT4
w3/0OtKCkNfULpvUBz2udsgu9siSJM1L68cDyDgXpujzHiJNy7K6JZSKuGdfkGJVt5n1TXWdzFoG
E9f5ChTtbzzfQ91Al8AERahN+D59l1BGFKxmgwh9MR7+H10r1Oqr6fjkdZweU2Nh3+iBYK47nPeS
tOyyRCGEJaXRJuVmBZVri++gLIodGo/b60sSPZ0NRr3xWcFaoCExbNGwvdcqDLtyqizYSdEHUwyH
j4JXz+PHTVfOQ011PtBYd1UfYFCm6VkmPdknJLoa2t3AK64cSiYhVplGUUcqn7qu+IdPH5GFy142
26TXbTW/K1veFKU5TNIRVLTg2mL6liuhw4Gn5raGeJifr7HrXinWr3HizX5a8BmMGGxOq1GPQefU
VZihecmvOY0UioZerpq2KiKlxGEvKKAtRQ8dnL5993LzzZ4FUbuS7B6YuucG6R5M80+jE86UJq+V
Kx9OeJ2lREqJF/3yqpIrH7ruo7PsJgTllpDdDIMwO+nqPdosMNkSKXg8U3Way0262tCloBWOXs0U
sy5o4ofwKspKplJPcjZ1Qbc9KYnMBb5tnXRcoV9QJ/LeZHVJ9nk8YQvFmxLu7w7/Qlga4ntalgK8
B6In18W14ytqeNHL5jVTDmzCNYMrQdffL8963sxCy4cZsxZ5L56Sg4tUIKgQOmxRW32oYiuQB/1T
mwJ1ZfMc5oyV9T3xBMpWUDmqo/5Y//avpuR63bqVVa5yl+FKQSTr/YSE1Bcx1/i7Wg6egKou+wSv
lTgTtrolbnXem2Teg16C5td82CxcqrTueTi4IlYofpXxLoDjARfCwgspJ0wIPCBkAGq+pekR3qBB
6G9CHuZr5SrVrbYxBm2spTwvjgF4XL7JYu0TXhBDOYoh153N3OGihYin5z9O04K1HNMgSPKxUTld
/FzlqjCJBS8hq3DM6I1eBOM33yt3XperPPTR+VFp+wBpKrKT5UQZ0fhTqRBQywvBtASXQfbSo4la
f88SE3aUhAsWKNvw738fLWjY3WEfIb7MDl7U5f2CDB/PRsux9oRa998V9NTLLkBhO4qqvbbuF60T
LO7iaibPVW7CN2k9Y6d1mE/OWva2q91eyQ1CIfPXv/6z6b9ww9VaVTxV3uvx6IaJSnw+TXdRR57e
pdh2U5jGRFK7JensaSkkN2LKuVXI7eKGIc3kG97sDX5rwz3onLPtvuQqdJ4GCGQU2Sa8MsxLBkvd
l/QVtGzjIRb0aelRKbOr22OXmOUi0Tjrkov9KNVdF/fzFerHk2Qk7AhRRJON14p7wEsydBqMyHmO
XTGl3zn2Q5nMfp3jgcqVgOsoLk3PSA/LLEXNTTf+2INWOE9xQTpgw9qINbISFhsOjZJmkImkipU+
bcn5YLYl+zCHr4fPcJC7/4zQDu8pwUh8ld/Qr/47Dvtn3/PowneO3FxLMIKWFcFnmzUkwWvTXfTf
N5Qk24C5zi/aH/6bWbQULtsCpJUZveKhurEMmrcNfmp7KZ/7wkdmt5C5TxaCgpYZuwfMr7KMBAvT
AfHjhoWruErqJ6aSeujiZouqG/bvRFg7YHbV7OfqqpsBmMGWdVmV6HjsYvh8cfLjvuO3cnBnGbEf
gl8BxDouLLfSPof2neXQwnX36XDYf54fyFBtTJT4RwxnpRS0B5gqnAwzPT8Ev5CUmyMeghaYsS1q
gRmDH4JfYC2P4/B9ZnsLl5NueMuJX6jRSkfQwb54LWeW87uU7zAXES5h4Fld9wymrmv7Jh33X//6
/2b+H5UJjbNKo1fxIV2kTPjsAA2mZQNonkik8oh34omVKRi5zwNRGzlOiZin73yZNXhDWodmhQP8
yra7GyYdMl53mDi62jl7nQwnPgXSkMlM0fQsFfCrpudFdreYk1EotY9wkq3sx8RIYxQ1F7vTDLCv
Fv147JPR7hxTv7xyCqR7xsEsknKuTok0cIVKB0F2+Aqa+TBwFeRHqNqsz6xbHdAEg53wCaTnPepq
PNpC1cDGdBpf1OHOVb4U/pO4gKtqVD6oRgNGiwOi3E3Blp/otzIundBOOOkmQxOiTNjyk2HyCyy/
mbpYzEZNRkC3n65KIe6djJym6yq082td708i8MOqJVbIDEYOttmD0mB7Qy6nCh1QiMirUSraIT0a
J0EhepJ3nsoDBNrFWFNkGG/70VVU1yCErAaRur1G6fwd3vE12LYxOMTera2FTZ2u3HVUpyuVSgBt
GtlSueEtbG8BYrbiXaUYlfoEM4eW/d2Z4OgZdpc2KNB6oeZ5+RyzOxemEP3qw7nZsG9nljstoAmE
zvazoSzweGKfTmBhE+ySBAE99ZKVCco0aBrqZBoQhzecfpVr7UFTggQEGjTCyRi5CSDKwFOgIFdj
KZwZOxpkp8VAhk53rCG/DUCnKxv+vEpWXcTem5GT9/0+TKBmthdpcDfBW0DBvXpkY9eEFTQxiASK
Eh/E1eWZOSiHC/zUu8/pSeytireyZlr7x95YiWLTyg6Bi11UKjveHE1jIh46N42DjHamSZ/6P12p
+3TJowqFc/V0ypZaeExsoTCF9Fta8mJvcAiv1QXbdP/Lovzv23WRndh3z4w4yE1X37DlsgsEytiA
qkuVEMbC8cp5sE1oeXzm7UFxN9A32o645ZjTStYygOUGwUJbyT/rx3H6BtnIgM8LiWw6PkmEwmZo
a0gnb8RbBtt/Z3rMNKBo/UYsHr5VdBANwL603uMmLbcIhs5ruxQ2VgiEpjVmcwzi8KO/PCd1+nkB
oToJ/bw91+xKPeJ0s5I4A8pbYr7Cp3lk/t7/3VzjdTnAR/FSF3HAnqiVZSvZHBswegWmV2NqNNXl
s3wkJHBiQ33uWPm0D2jZBODDFqzhse4rB0d+dGxhD138jv5eOxLblYB0wPqY6V3D+7g1U04nYIMq
lYxxkzmfmzmeQBzwCDe97jgmX6qzxD+sb4SY9C+k5T8UCC2OAi6i7Lkx4+iMZ0LEzzSoMhMIXPIs
EBjwD1HnBsL9u0vBvgFNdYT0qu4bNQzJlHQc1ehGYo/GzOMF91mXGHvoFXkz4YdikkMqog1jzOt2
Z6bJbD4dufJLi/Y6e/pCFmTBBoSvaI8/iJ28UBoVImZDMDgOqTDUS9Zle5y7wa7p1NAF/VfO1FKA
SwExE053W/4KsHgLzi4c9AJ+ziEsjXO7EU8IPuCX5UW22tz+tQC/8Mx34ovQq2IhilHeHFKxrqbU
SivU29ryaADEdqCutbdE+drO6mmJt2KPG+3EKVfbRdpZ87SxrLXzilagJpicWLmau2/6ccXfsppW
HbDrKqMwbS/SsJqZGucR4ZTaeWVqNWK2sh0qTl2JOasgahMPappjLN8uknp5DO0iVWRuKTJP0PtO
ydgu1kdK/79VMTLx1F6LNCT6sFOUeFRuoqouR99UaUwHb3A0Kk+q0aVP5NqFRE/XC/vdzms7vY1X
pWbVy/YffixBbOepo9kVYhHaecH5KijwN1loSp14Os7vnKxt5y/v54XbCjvEEc8nr/qlGcWliaiJ
e9OJ68I/YKP8y1Z+zjxoGrzyyIq0mmHhPHVlllOx4/QERDtWf5z5IQajKxiY0LxoYk1tDrt9lZKY
1xvDFtTBBC7NYGEfFAzx8X3cdt47HzdDupZhqCPaQmv5fnfrxfhkQoAxmtn3CYFUnAMbreIlkUeY
O3MLvp67QRu9HvQvJTnDAZS4h+jKY9GscreLsvA4w+z4Wi7B0b7HpsWJGF9N8/78XTXK6ZQA/LrV
RY1KW5LSFJN07lkSF1C50QmzaMx+QxyheF0zWf9fv9ZpxhRajWCgfho2rWBaZCYtrUe5eqswsNPe
/vrXf6G71NxtS6/eFuQm9eR8kKq9Wa8uqly6GDCWeW4+/KGTv3AJ08viycKjIT/fjhYPA/X83eVf
6qgBUE8vUkCQulHpRU/WrZPYCi/qaqnyofExfAzO12fx1L3MZPtKpVO9dkIXTtKOg2w9PcUDP4x7
BSPXyqymjSxk36WpHKhHiOrkZHuXWRgQMTl/IFBr5ObT4LkfsDycPQlwrbjbYYAGqCyAg0pUAevt
SJgPr18CZ5cGaNvqMeBoa6QICMBnnPb4iXb07o9ROQdUVQ8CKh1xTbNv4BZv61WnGn3H8GzpX2aD
pdfwZW8j0QDOq4c+ZbKoP7QzHZ8MCBNN2VU7mWmGlfK0GjVbjUYlU0I360560/4kWVx1CCCrz+Lp
EXFijASBsY1f+7oUID6sBAIkrjnPdWCKig8+eRGLPVZTJ2JlXq4UNYvtdVBymEN2dCmDHxkxfn2o
Cod0HXRlnrwWykKMVAR5udbuDIEezOUgzsMiBTjksIj2lNZznJ4bI5ugL/2q1bLUQdBLuSQ+V8ap
qBp1dpOTMQnV/nSpqauCtCM/RFuzNCtrQw8g/Av0IOM6rYz2UdIph6CrkOHDwcvNN5v7m7fmsMIp
OybnpY4Cr4XPZLgduwV32zJz4r+Sr79RlpgYI7B+yt/unPk6V6s7CGMUFqgObIQKcTzFTvQ5Dy3j
7rseivpO/fvdd74f73qBV5V1pF3oNuV8ctdz0oI6ry1eAmVvbRm6LD+ac1BFEJf6g82AxEvFrQRs
gLhtAnrK+faIQWK/3H4/1CK5inI3E3jdsOwsBZmaxoynhCfDXD/30hmBBRIGccMIcrjNNNk7dT2g
YaaW3HUT8UHQvugD3VeR6xxMG8KYU4YVq7GqixVXVumzSGVVvVkZdbXuSdhfIA9baTqEgcy7gei6
SAwV7dCyF4828TGh6mGhSOqVFuC/u2C/r4j3OGwu71SkoVYmrJHAar4oQodbYD+buQ3ECSJw5p7/
v0ThuCvM/rzeoVn6Lpz3oyKP9ovx3HPyzkfG2O4QGql+7J5j92h+UuK+u1JWDypAYjBfIrzRXXwQ
NRvEVtZnYzaQJritUZmVa+NxvsBvfO77d/urVOzjfbe2PRfvoOmbV79kk52Jo8DVrTzDc25L4IAB
RuV5xntbg3Pn1NXc99Vd7MXNWTxyftwKltfpm+SJYifveeDkHYykZFKKLPY7zo0eJNN7zuMhv/tu
bodOkJlpApeYlqm1OBh5sZcLj3ybYNeiqfIwb4oR98NFmThKoROirHDohlhGP30zQDe3StYhUcZ6
e7GaoSIUqud3V1PpkLOKqvk/UPSbO9mP5+jQI4t9jB8zpy/7cqHsN7+bNMErQ7KE/vRlCbR09QNS
HF5wWREtngeD8ODkhEZA6G548RXEBp72zTLD/DZCw/zrSw1RgFn+pmxSEX8ivuv2YstwLZfX4TRz
lEnCG8NYJonV69CSydboHH1Z31NoAiIrOSUAs2844u0APV2tZy0qd+evnCInxy9dCx3+eH29aW42
ReSLjUSMstg+JCYrLKwL258m2KTScm7hoDcQ9Wbh+H39iMk2cHkjl1qN8qtbtZi7nVs7p1DJ2hJC
hGfPDK9EMWu50JAwv70d4SvxmZoaICtA2yj+BfKzyeFAy3ik/KZeWs/qVD9Bp+oHWmfTEhAOE1g2
tvoPnz5WouCnpc1H9MNRSFuqKncm1dViYo8mkKrLKqgOgZzYzShwAPV2aNLuQTqeT7sJ4uPFRcVQ
1aNbCoG6jB5iswv3N8JtVcEcV19rGyZwmX9atBuLzDhZ9WVeHDNr4CMRo6PUOrsH8OQUi2z2motr
FYMdEsNKjeiwrCyxW1zCt807m2vFhb+CHfsxU0/MHtxA8X3d8f27SYZc7TV7XjXNRnBaTbYH3mQS
7nNHtRp1oVipe+kf3dnSwtFOz3JUN9Wj1/UBFBnO3qdrWQ9kVwf5WhdW176QCL8SdQDu4CORcuZD
Ca6JYITqSMp2msjL7JbACf1+4L9+tWjmvYPHP3503EC3wm3XJ/P0uPxBvFqp+W6dxu/HS3MwTJ1O
Kw7Tx2r0obSVpnPm7egyDftA2bcfwllQ3936gB/9uMBb40PpT/FwQELOaDbAAen87rILv5sDrt1w
BTV9l/ivi/QAKWuvInytdHgMWlVGBsGVZj5W/E3g2uShmoBna+MWT03cYm/2zAYrfr9Mv77vGSH+
lK/08pGKyrUko57YZS3gZY4dAStNxDiz8a0U9STKKFstS3suW4iQVQ8yw47OlBJpgffg3kl6xPDh
7eysjsfYeoy7ssPuontQJ6A4xn+6ZCvRC2YK0Yt5zwMSJhpe011263ObF30frTT8Hjp+7tnkfDKY
sttSVLDl9Y42fJYhfNyaDCIC23F2rdM4P61T9UFF9+wGl/PMYmF6hEvi0YG+XgkEUYtPrvEHTIwc
eUuUYaVCx7yHaMMjvJJ+6uuQXZ/o3ZbUXRrs1i5Ar4TDBHe286j1KkMjc1RPAbF+OzbzZjrloAC1
0O9mS18sA3sl1f1TTev1glV8xI5B7begdPwP0XMu+j5NI1bkx+knLgWPyXMaX6SBjo8Iz9fRpOus
lJGQ8+piX3ygXVieeu9aZh5aHT9Lsqolb7MLX6hHtmhbSsffwm6igM5pqCuhNq57bSoEm/U7o2hy
w+jeXQ2kDfpqII8b/YB8ylVw5fFHMKZEzO95+asRtyC5tZm03fPSNsstpJH++NHpwXHrWtTin+0C
thl0KUk/ND6KOqlfoTYxOMfeyJ72eQnd4lxZ/KLz/dro5WaXAMBsd57OxifAMhhG2+wZj0gRDK2Y
uY7FyyGX4n0LUU9HkkhzkMFffLaxiEPKPCDc0lXBiencWjzu3tXNzidlXwuNyeituV/QTZEAMhqf
/RBRl9OL8SjhQACn1LMVT1BteJpg4mndayqLttQ9SVKCPC1k0H22F8SuzXpmJnvt0m2Qn12q9TsQ
jYyKS7ClTkKdAAPmTI4bPP1kLsQlLbPCyemBEB6Cyxx26cddyRug8vZhTp3XHUML63shGYyYVS6p
/i+6qkaPYU7Kjl/H2KBHYWAizvvMwOOtXJ9WGs716eyYUEpUdu1ENbT8ffQQCXIzjmWeR6YimgQu
SqXl4yQezo5/4aMd0wKwsb7G3iWlK1V+T9VpcdFs7Rzdvp7T83dz6loLnbqiRb05YTc801cV/Pst
N/PfNf/z7GKY1Ltp+jfo4/r8zyvNlUePsvmfmw+b3/I//z0+yw8iSQsEKhURJETvt6IHy0vt6Xg8
A96p1Q6P2vf6q/21/qN1+sXJiukCf+yFFl150o/7h7gyGH1q36MdfNzs4SfnEmvfW+s/fPhoBReG
RPPa93r9pJVwspJabT6hF/pPemtr6/yL+0we9teSLi70xmej9r3H8ZPGE/tbHkn6jf6KtEEErX2v
SyDU4Gfop4y8lyQJNwsRvn3vcHVtpfHE/JZHkv5K0sKlw5gGevik2W129adpo0sj4W4gQ4xm7Xut
tYcrCU9Xrsis3bKwgdU+xq+mxzGNvN2ImpPzqEX/TY8O43LzYbW1Wl1tVOuNh5Wq3FwpuPm4Iq0g
i197PuC/6STuJtW9V2/pe40kmfkwnlbfJqPhuEpMTzomebhqnyPEuvSf2UCINA/IJJDWiB6OpzXj
+9OLp58q2HS7+2b/G306k2ve/jcfNeNW09//ZrfVaD2x+588Sp4kibf/T+K4Gffc/rfiVn8lXtdO
AAErq91Hjw49CGi2VlqtloOAR73Hq0+aAQQ0E3ri0LTCMNBvPI5XD30YWIlbreZDBwP91uHK2mEA
A4R8HjX6Fgb6jx/RDH0YWImbT5pPTEcGClYOH7f6D2+EgoeNeK0frzsYQNCTCAVXSw8uD8fnJMj+
At/cw/G0l0xrdOVqCbURqiiUcHlCBHMwajeulvjnYdz9dDQdz0e99mk8LWOLKuu8lfqbRlFZ7xN7
2W6uTs6Xm/XVtSi9IGb2pDYfVGtgppOaXKiW9pKjcULHvlTdHR8Sj1QFh15L4em1fjIY1Y6TwdEx
tdRonB5fLcWXfkcy68rVUl00LZc9ibLnCUbfiUQaj2b0AINB8DJfwbsA0UsMt9aPTwbDC3OfLuP2
aH4id0+Rh4f+0gUaXbc9iw8B8fidXi0tES4bxafAXnX6ezkZpwNwHe10Rsz7xfpsPGk31n+hxekl
5zSd9dwyMihX1u0ezEhSauM80kka9CJ5CNDLR9FMtT9MztfjIXHstQEtaNrGkiTT9aN40n5ILzfp
n3U8VDub0iX8sz4hEQPb/Vjv0ywPp8TpyzzPZMUfNRq8iYCNpN1co2YEEGpTvk8vr99mEHguBx0Q
jGqE18ZTZs14w8woosHJ0eXZoDc7brca9LJCAL47FHIS04T4mdXHdKNyqe/CvSsAgyudWjD2xhXv
kVsW4nuxMGbRMOZgkQhf8itRnQtBXgIypfvGOhJT9Ifjs9p5G4Vd/Oei+NI0g2YfoRVYYU+S0Vx6
T4+nOLQNs7ZQnUozV0t+h8FKY5irvG1BV3noLlzndX9ITaywgtw07g0IXzzOtdw+xhwviyG2lT/8
mdfVjHH799d9OCSezLTHhGTKC9du0kW7lPawkYQaoy/vZlQPH4kP6TzR6qwrKPDJ7MbDbplwzP9B
Ah0tS+WG07n4WIZLqat7bhCvPCw/KusOiJpPGh7E4cQaRNFq5KaiRRIsSBySgPNpXRuiKcim82ls
A5z8ufD+6xwa+XUPYD4PGYIqCkdzA4gEr50djy+zMBhl0YQCsIeBWm481yJHPUn6DJ8TIOfZeDw8
JGYbCFq/h6cqgyRxyHhkjEELkJuZAgYmD91idFfofBYPC040iGV2EIUESxqIDi+Lz831dKreI97K
9D0YYVA1H4IeO4z7OAcAawRdASIFVUCR9AEdIAW5JgMJ9VKfT/LwMJ9UriK+CyYqfx9XzRPEQOUf
oIvmPjFHBcxIrGsku53DGeYGh9l/YMfXNImn3eOPhuYIoWGj4OWNECmwBV3adEx7QsClp5P5H81E
td6dT1NqZzIeAHJA6GY09+tQySL8k9vyHO4O0TsOzdkxwW2NF0IJnYzAnFlpoRDUEBGp1b7yS63s
13pBA+ZW/pohEBxrCZ33tHiPi1rl63IBXK62cjQuBLOiBnA59z77QFuEBOHnCQ5iZpv5URC0S4s+
s3i1aAH8Zh+adj4Y596Pl2PalcHsol1fM0AyGgN5Ez+R9HSbmI2vnQ7SAb1T5SjbzDUG5sw1qQqU
uWhqT2YuZ35fjuczFpNaGdjkpyrrehv7kSazNq+Pd57Qyceqd8F4NwUXpXJ9cEkPog7dDvaSTTLe
cfpbn5xHhvw5ohpM0JRFNiiDkb8RVJhaCKgXAUQGW9ZWsHicwzMk6LT3nNbOXkWR7nX8UyMiRFfo
SFP785NRSkwC06n+1HCGeZrFem5HsvB845b0iofRJmF+RhtewwJchi82zEPE8R0OLzPMm+m0Bj7r
ER8BfRjZjy55RjKRdmv9FvjWvN2dDS89KUCxtt4UwpansY+LSXlIdYukjIerImXInhRvA23A1cK5
Na/8NfLXpAFWn0NUiulyCKdPnjzxILWpnFMhm7TggBQjevRfH3+6zKLLYixq34AKI3gHFwrf4huu
J6LtOdS+AOXzS/AGMpoIy3FFjRCkfR4xYMGzOEE1L+FiyNC9pVwx9N0l6gP3iG219IJPWnhGDS9X
DCXTZJLEM2TxHMNQPKySGEBwVmYIrhIMVSrXibnc+WL4o7Xq0jgDAfWLZJnMKrauE2TsWohQigEg
sLqIs1D2jB+ZxEhr40jgwzW9Uzu+XKhZOIyJOtAILX+eZZlD9r/ZsEOqHUfHrctClUa7EYqcaw33
Dtv5FumHsgev8GyZhug034ahtM8zi32ZVQzc3KUvAHIb1GYan9IOXV4L7tI7bdxJelTIWOdODHbz
GjpqxcjMkAu3CG5/hR0XaQl0ol+pa05YchtCq2f3sTmzDTmvRm903bmVPq5tdjXT7JUOLa/euMvR
fVyE/1SDXcAVEa/lr+Gq8K0+SCnN9JSzj1azukA+k73BNGHP37ZMdJGGsGU3od0+TPrjaXLZFaeJ
dqm0nlfciCqVDwQm59SROpyVHBFoRA22aqwsWouKDiCqj3wMYUmrQww3y9jrTLsNO1hv2qZTv+nm
NfqOQj20tDH122jcqY1baQc4jV2x4A54Iclbn7BbtUDE18cw6zzvwDeNEFQo//mdmQcXd6lKgeDp
bM/MYeQVi/zO4Ty98ESxtXWV1Gvs9ZQa9bRsAZiyy2KoXLXguBainsYi2iBNEs7tD+Oja1plaF+z
IskjB+2PCrU0i/QiyDuURIqN3IyB9xH7WUSfrAjbKMIDyiCx1xHrP+Tr5Z2Zi9uKbZbZeGxXg1BR
eRUMetXocU/Polq0Qu2CmdLMyPRsculeeNi64QUCNxpTbzoOTgMbRhtV/K++umYfjo5XrJ2MkM1q
uP1MG/RBeJjdzAZkCVXLb+FaIWTNyIK+NNu4Rqa5VavMWvaG9U+nt6GT4FNCeXTV47VofcQqleG0
ufmoNysy00V6s3cZcmxfiOZipktpsYD4l3k6G/QvaoYIMTFLRr0FnCaOqHK+2izhCDquocmJbTpL
nJr08mYOTifJIg42ry5JzS6L1eHX8T/+IIXbkaYg6y1A8ut5hK3vLNK4FjKGkMbH0xMIAjmesRjY
MUhMwrf7JieCYWzA0zLSEQ8TxjV1uCV6WoBms9HwAY35ZV9Su5JXouNmlszrO6u84rqdKEldaHn7
AjtEgR1WezD2nIVmmrAzp5ObTeNROomnBKPr1+BtY8DMDKjWtHPUEXwIqok/hePkx8tFajNppVDF
VUBkgcsv/25yqLF7m33kfq4TKj1mtOlb4u6kJ9NerhEyvYfydgkANaDiMmtPXuJb9eGAxFAnUQ/j
SZq0zRff/JdFq+71aHZ8mTUOLqJEngIvc1h9uHp8y7NQZILwx+X0KbdtMaNHJdQRtjgVjWX3eDDs
of2cyjLoHpg7vcyPskCU9t67HSkX6TvJ2RtvJDe+ktDZmuI5Uo4A+ck3Gjxh51pedUcMcfAEp7qr
htf68WCY8Yth1J15dZr0WVVTpM+zD8qKXRZam+xDvWRGXX65OmXdIfuVx6yip32tHU6T+FOb/63h
gqyUlMPBSvE3Hl3WpShU3XHNtgVWXqEe3BIhII+RXHnIijs6epWvompbvQ2Ka7WC4SwmaIYbvaWr
Ttim74rT8lxxMp1PLrOs3fWHYiV8Xawf12CdFTcdVv3yjPwW2J7qoUCf6XnooawnfIjusfe/E7b6
g/OkpxIWRCdFO1hEJrHgYtr8DUzuP5Vra4VbzdQxOElHgTrlieGD81xbZq5GLmtI/zJKvRjVW2mR
eOodjCckzVgHEqgyZcIcM2VlvuZVpJcXmtEDU2l/TJzrtI4/t5Be8uoiX2zz6GCBGV5Iou8d89DZ
4pSNNq8Ls3JZeC80qt3gJ1dIoVQywv5Hz6Q9cSSsqsAbXrXmiYaDUWvD/EcbMNcJj2N7DN3MESkz
0hv8IXXi3r4hIu3jZSCxrOYVr0Xaj3tESyXeNcpaeBpG8jEqkskwq/kK1Wwt7wDwfM1asE+zddJr
i6fojS5nFl+iuuCnwQw+seve99p4OgCxtstp7vGousP4ZNJurQc/LF/HAoAjVoG443ShmHIdJ1uP
m8ftG72w9+Ljhyo3Zb0SdcI4wNOTOteYCLA1d+juXWs6DR6U41XgbFWfsI3q9ur0VVZ3OyW6NEDz
R3HNWx3g1dxr4gh6s75VAWY1xFnM6t1OX8p98mmwLOyauHrmTthiq/LkGqueLlKLF+nK05IUYSxN
n+C5bOsVaE5yrFI8HJoDltZHzcb1I2g2svYJ79XI6Lir+WtZnfWNZpKbx7JWYCq5eQ1zNlewb0AW
1Yfc/WLr61rrLtZXyHdi0M8AoMNJ7AjxHz7+q94bdz/RsToajafJ36iP6+O/Go1ms5GJ/2qsNla+
xX/9PT4PHiwfHEwuOGD04GCJfj6o0086y4PZ0oP6SW/pzdaLze29zSUJE6tZRwxCalxCgVjS9Pjb
Qfp3+tnd3Hj5dpP2+W/Yx7Xnv9lorqyuhee/8ajVan07/3+Pz70oe66XljailEjkMIkePOAMYg8e
cGAoq+2RmIMOPTKqTHF/J+K3H/9IDyH658GD7WR2hNKsWk+ZrtvKGdHWjCu1plGCXAdcpuZ+usRZ
1atI2p9yppajwakpsPrgQc8v2/rgQZV7QTXWBw+0UDONSC3O1JdwL+hoOh+lqHcdR8c0qwTpFF4y
rVuyeReqkcFhPW72JB7RHHvR4UWE8DVOMGMeJokTsRO13pRGN4oc8lta+hxx4dPoc/R6fIbsMoPU
NvU52uGJfF76XKvV7H/0Tmbxyjtv6q36eYXe2Pfr2I7PRhqWy7NCYc/RONrbe12NXrzZwuRdEewq
ybKcK2Ka/Pd5grwlJCzEs+gsRkkJZOnsSRLDmFZwMptPEyRUkRfiYcQjIKYRXXmVkqE6TSNJj5LS
9LAsNMrHkcwiv9+4KvWbMS+vSqkus02uuM6ll7msbjqfSL6QSjuilR314Oq39ar2dus5wxxgZJ5W
TRnuyTJ8Rrg1Kb3r6iWlAiLbm/s/bm7s1vZ+2tp/8Xpr+0duqkObMpohLdILzrrU4eLBSLw8G2vh
y3g6m08kl8cRTYXWo/zk17/+L/qLxJB7r3Zoi5aWno9nx1K7UGoDpwNXqBSymT1O61ESYxFlLY8Z
IB884DcfWJsaAdF3H2yh5Y9lYsrSZdsEiXtHlaWlGr1nn6k/eIBoYEkaYlpHyu6RZArRGtmP9RxN
kmnEHn/yEkbE6yankfaUzxe9dJzQFKYKxPNJNeJ1dkeMjgGehhs+CXiJ7igukRT0KdGuUgK2kXa2
QU0ghwjx/0jJRLDACSRYF55K4Wb0g2Zw+LGYkvkNx9BMbCrD5dSs3OoLJGShpeTLABAMQVTbBAAz
W6d5MKvibbqQwxZ0r86L6ipZm1V9A8lal670fsKzpSbev/gRKVC2N/bw512/P+gm0cZOiQdPQDwe
VWkueDIsJg0IkGGHBaVvqCS9LtDuFZ9G5lxGv6xyMKWzdZFwczzVfuSOnkn+LrUtHzwAFM+yGCZ3
iHByO4P+xnAQpx06kyiIzgXAGd3IdgHnzJIRh0RDZUZnHeuAnGMV2WhsqG6EbJWMToqAYyBy9ukQ
8IbYRSDMJl0InRDcA4hkK0bSk31j4gQo0aINZvf2g8LeJkUXDt6ClGF02lHYYnTEncPbVAuI8xi2
dhSl4KbF++7o8Pw1pSKKEB0l0wk1NgNEGIiWuhkMcRjhz3pZ4qOFmGIb/DGVk/pRncZ8Nhj2cHQr
bnk0TQOXo+fFklZ3bPJKXqpTOgsC8iizjjNCJBFJDKPD5HhA84mj/Td7EfJKTdME5WDPL2Rh94yl
XwFM+8MaKI5DnwQie0rZqwYGTfkMqf1Bf2SP8Kbmt4vGAmA8/8OEBi67CxUOgTVjHzYC1aMXSnIA
KJMBl86h0zWE96XMKdhCfXjEOCnSDEV246YJbWmM8FCpwNDnxYsVA3CtDH4UGZ4ZDdCjn6NdZKH+
HL2gofbGhPbpmqXguH86SM5ovJ+jN+MxYaNZpqa8PGTKAtDXDYC7QjOf+6qPA7h/nDO0IvY6KHql
FSF8YRPWIwNv8oKDNDFKM4V8lSGivRI05oGyAz1hVpCzN9p5AdgBIqP9uT9DGRzrzpcvYOXhT7P+
9qH0OBkO0XEnndPiZdlMZI6g9zoR7LipjEOI7hzVsFILWeAeJF0WHUzGNhZzybIxoaMHBlPFccwh
zqfQ00bKWzLo9pHygpsaT9j0lMhtcIleqW6Z1IZZf0xBqCwbu6SOsU63arEbutTRc5y3h7OmCP7u
mVTSZ8djWu9ewlkIR7KoS5wCio7P1o45gMgpbcnRDSmqCe4A7use5IWPEtdxnCg5BnLUVzFM5LXG
ibJn3SI4Wt9TLlBe3t952yJQjzWFRK9Gg+ulTFdRJyFNhxVFyIbRthy2mcGuZcZHY2TrJI5gNBbr
cNztjucjRYy7BP41Ptv8DKfakzQVTPaIa40PB8PBbEADhl/gBAxJZzSuEUtRQ5lXeoGgsCOtvU1O
xti3wYkutqTI4uAxXWhlcZMUdYr5nLwbCcLTa9jBT8gayXyNPI6maPBHmqENxYdoyJb7dtvQGycp
ThGdTUJdNKaA8PaJDZI1SIdj2u2lpWfRn6RictqOOnsvdrd29g/+tLm7t/Vuu5PbIB5G58AUWT44
4Ec6yOjkUvrUJxedevR6gDRgF+3ow4vXG9s/br559yOJ/B/L/i/awyVCbEtL9+5FmjEvBTL5sEvC
xGAqKb0/lu9NvZ8V3P+vc7BijG7p9n/Hr5pkdcXdV4Mp0tHNkgntPjITmwkQ4qLH+7hd49s1vl1z
t/n9jHhBr4zkSu0opSuzCT/1E1Moukk7V5sP+BqTHrrE5i2+4hg9uoxjXOMffG/LLGub5TxeXKJy
9KBd8BoLgHSj1h1KFxuTCUth5U53NuxU6GFafdyt0W9+wpJSTrhDBy+hhwzertmL+ixhLRiYuXo6
PycXanyBn3k/OYK1kddubr7znbeDI6AeIu+Mgk+b9Ua9QU+dmOs1XK+dNhsNfv45cWxEToXocJY4
eviQL/Ic9aL0OtJFQK/mu27vUDHuJJ4dp7yjdIVb4CuyFcTke5wqKhyyGI3dGZ/V6FZNbtUGqUrY
FQE9xtN8iOMLkw3xJIbtfRTLYk7tMzV5hvv2nhEwGs90nIwNGEdjtLyy/IZ3nd/Q2sT0zEy+Vdz5
8I8E5P/PvnxPv9/t0aX3h4TW5sCSL5PDAbEQ5fik93A1WiacfPJwtcLy80a3S3iGnga+E7HbHfBp
UmMthsrcs+PpeH50LAS1w69vWf0FGBpwm4N+dDJIocBhOVxUHtGLTcJsDBeQ55BoTxX/9e74pGpJ
KCFu4khToWeHc+I8z4kZmx9BCCnHqFQJjEsIjhArY0Y+58TuV/FYCqo7rBqiQJIi8ZTzWdKqRkfx
2SdiKQie5jOW0PAHltr5Od38ZUACILWESgijnj7BJKwHPqTm8XmsSYkIKRB1Y45LV2uZR8u16Gje
hZPUpXg9P4zKiGEj7pu4Hhr6zsUOH2HQxDEdlsnxRaeS7Yc2wrQuPG2ZFpwTxTuWR3vgtJSQOJ3g
T9hemWg0a9jmKKsFaosO5lxZBXrDY81EgO3R4GmqmsKYOlKtTaVepItpR6KIsS/3VWjoMD/ZYa6R
pxKzLgbsZ411SQCFEzrrM6Wfksc8M0vqlCTaUfT+JU3iYdOtBC/BZz4rHnlYWgrhewB5NNSyYcjM
/hJm1ZIa9FRycpj0esLqzJiB6RnNlYisSns5cyqrLoGF6M0l1VWyWEAErtPp0NYfLwFQo1o/3Xvz
LpK8p8vL0/gMVo/j+SEWRX0BATrL31MLz5a/B6Z5tgzMspzlZpevt450j0/GvegP59H1jzGjXL++
LVcA4J4QqtqzqFmJXs1povocZrm09BY3m0h/nWLX26Dlhyz29XqE21NlZFkaILj+hTOS1UwbVa5B
J3hACEV/POwRp7HuRG/s1WKZuuyx1HTICmVcphXCSPb7tD1bvL0jGmuzbkYCrH1hcdpkmjADAu5d
8LmA4/pSq66ptoWZpy08hXpG2Usr9Ti2mbnb9aWVumA6eY1xwvrSatgYcynQneDQECYFgCjW5HnZ
Qkp8kIzGoSda5GPWoI2QgG+tLgchzeT/ZfoJnYHceL/7xo43XC6rXBBYXnr69Jmt8vEBxZk/KnbS
sjULNsc9vbdg95gxakdzpmG1I9r7atR8Qojm4WPiK1oN18ILOwvhri/ollVTtu3p8l9uPyb4Xqbn
/DIGZW+s1ehxa5XLF0RwCqwY9Uo7am20nz9vbzTa9Xq93dhsP2pRM94kBHscSgZ4LsqaytpHzPWz
zK9b6hQ1XIXLypqSJb4upyhEWN3xZOB04IQPO8vzdLqM/LbD5fSwADF0GDMJ4+sgCcTEqIYIlpYW
iMi//vVfOqqwH12cQYlB205YnkQo9j6UrF5tK2PfhDpq5id9uyApiWjup8QYY/SowibSHc65Nke8
tOhwx6w+coAu2glbBov5GL+gNa+zKotZQUiLt9RZTmbdPCodENEZwK0cbdZMKyTSgZpcJ04w1mB6
pIeoHv1kGJsFE6kyx2NUoj5MqLSlkHQ/KDBi9D44ZND+sUphlGTEM51zAFWsASRMtUcjiaBMOBoD
jDyV26//438aed8o09S0hsLJjolO0vuEWlCfOLP4VbCAM1QH5NsYWB1IbmtU3I1a1Xo9n1+pR+9T
2P/ABANPjSSMmEYiAaCRRLNXlR8nFmku6qVojtqzWJScEurBgzrwqqqm7X7TFrAuX5Q5tBhs/qNH
TlQnD6yZHzyr7MzIx1atjvHI7kCe3jfmGAGYUDfVduzAIg0VSXG87GYnXMW8mgXMGjG5J5PZ9W2o
3qDHWigiSyTueOh0rYn27Go9vm1bR/GUqFXY1sMG54iFPVIF5KDtJ/mRMyshbGI7kkup5RND2Lrt
wIbxIUZFH2+SrS9bNEhfUP4sXadGZEHeW9vHWbPNUtI9Hkf3h+PRkRlD8z7x39cNgHljTCceJud0
jWsSWm2uN5l0RuhS6AWhqAwTLlDo2ibs8Ck1vLQx0LBlxbOaekaNiLh334Zq8LWx8XoW1ZTNXel4
aTRGnlijrB+pFANqI3YciJZsVWcOg3AIGo+HaZ2FAJbruHSKMSFUoTZnE5uTCtKZWEymhM6H6dJg
JPXSIzhxisJ/GoOhEWkiZjmXydc732oFO5NKRjjVtASs7hP8BMO2+UKrYI599MLXtD54QNxlkVjT
FlW4viwDYJMtCCYUjcs/YWjC0HorDKWfKRaAR4n3YAnp7cu1ijzs9Ke4/3JzT3lB9Urwlat0nwSV
oHAvLYLZdpasUlPuFzTnBBx6mRGVwtF9diaYx8MKT4iVo0yZIAXWWOMnczacrjIVumrM07MnRXaK
Hnl2J130keYe8KsxNxjzWIgRxILnnAMicCno01sGFvNolXjsRAWwYmxlGApDcJbEnwyEOeDrEywd
EsZnxgkmtFYXVNjCWD2086GKgOdIkEYbm3u1ZuuxeA8YgZvZPzYEMCXG0RzxEfe1U4HRq7yAaPIP
FJnWt/CT3UDaUU4Kr7CI82XU5zdi+z9L5YZaDbvPd8bgC/ipwale6NF08mRBH0E5nTtiaztSwYmd
XNsdK5YWgNR61Ml1nXkhY8BAOnM625sjBpbxEqC/AFTx9uF4dlxhfkIUB8T0d7KY3J85X+g4sxxh
UtlIvlEVfwtieOCxz65ArzjFWFYhyKhMFfV0s7PSicqK4HlYXM9KIasCYOm0up26A7aYtR/KexE2
UygXtIFnpQygCBVieWIOyvRNrzA1+xxpASGLNVgJGWIGGh+BiBshgW/npLdGogyut1qr5tvaQ/22
8thcW2u2OgztHQRO0BT0ELSBPtlbibAp+tx0W0j99SCN+P3FfEHPcCVocTtJYNfKjFmn4XZ7OQsl
nyN22mGttueEVM1g52irDw+rzMuMlvBiVa2zfldwlUnh7GV2OqtB+8x0FeiP9jTTf11esShqBPIe
GRB+vWMYAded7YZBwG0pNHB8D/5M1oGJCW7gJBFtsOCUWC8ghRhmC5iRCq1YKdx68p5TjLrjgTKL
2ft77LDVEVcc6YUOMmqD12Uf0Ifxkit3mvWV+sN6s76K/9Za9LVB31Y6FRF9SMSYqYmAHia5WJ5p
6jOzaaJ+AsSUYI+M9kSkMrjAEQOUijX2BNrEKRaedlrkmKivfkPHibWtCwc0IS4y4fD8zKKofYhV
DNIFES8uOMcOFewNNk0OWavPUqi/K0SBqpZoYtjqmVEz90HksZVaVgduhOp6Y/i+OhsqpwlqArG/
YS+BwvWFldWshxWxeWc0Pqigp8T+tuVPBoThYaU8T1UfyJyA4In56NNofDZaEkUY9ExquhrS5Ic+
NTUmUJF/q6IhY1wElglzyzGI71nTx5woCdOEecFljX2usap8XfSn5vKfWkx7X9jDluEORUKMxbT8
U+ZgnsGnYIkEUCjYVTFqGCJPz21k+JBRYJ6PqEc6OpnUDHKnUReQO1aGKl0FJVsylMwOpcJTdxZK
N2XDLAJO2NEu66vleWoJCBO35W7D8MM0KfAWU++JpcBpoZLhqdTHCZSkqoZCGhtrhmQUg4wsL3tp
vCnsEKxzJXe9ZJRA4BcJ+yXJYsssLYr4z2LyfURkOjZKvUNZE9aPu4lkJYHnESuKjy9ShAWqXoFP
VHk0lmP8Yuc9APFPbza23fvUm3hGDtIlSY1rfF6w6rTEcFujrewcNYGB6E8DRK+xzD8rwOzio8p+
kdWoNyd0d16NHq7WDgcz9Y+MmEc33kZ6RAkIxPltSee0HA36/7TPzlvL0Sbcl94MPiW4xZ6iBiKK
/P/UeVS5wZo6BYoHKQmnYigHo7IDd27r4vSTYjAc10JnZavShbZxueM7P20Mh458GZfc1FgVJVW6
KAzVsbOsClczct7rKp80+mOqhbm2IgWGa70+130tECQBFI/zTpR1UN9kU9jyS+szLhO0Dj88QXa/
6oTeW3scHs27Ar8skutYWkoDlyDzy3NFKvALIjYDTmUcDjdN+oR2jnUYRtjgURhHgY7nAPaK1WPx
IXUkR+yQOcPh+IxbYAGZDUOfRVEAEvhZfemcFcZpC6EUZTeWz6KpsNIO+jAytPHgB/PQo5cAVugf
9LyqKhqQXNXVCB4R2BPnytTTIla93iehjhC1rt3yYSlZs8uNs6m+Lgx2ykpHeuuBBnQ/sByT1Djk
c2v9e5wmNXD7sWo9mharCkWfKuWQquwdyY6bymRW2VBGS1VV1dDIOVp5foTwebI2MtO0rz0+TDAl
GKgMOwkJjhb1fDaNzcxdbdmquolWFX5tdenxmZmP1qTnzgYzIEEsnKC2U1RvN85Mw0E/wST4lH3i
qQCUhWrzGbVuh7QxUrSP8YYYmTTUweKLVGfBh2MmBz6PPDqe8t3j8oE5gnWZFfvttqPNF9EOzD9V
bO6gFz1urbFxiN3vCAn1+CARUgHCJzyPcdBZWWmICYkOKtfIvuAICgVHa6UWx/cO23BwATi92XoE
75l6Ez/abfxh/4YHD7w9Wt7aAUBlfDYQ3IrW4UUxgN1PTT7G8mJdLdTN+NV/fbltfejhHKdsBzWO
ZU4O21GgfxCoAuvZBu8xG6Ys//sGjk7V3BEkVGJHsGF8SP+Nqr4hruQeZXgTcbAjNWKBdH5mt0zf
SteHoZmQ2GAkrPl85CyqxCai0vZRXfCM8VyGJ2/C7rsqwNLpaetW7my+5YKzxgYXGmdAr6W8eW/x
YqjiUArO+u8TVYZ6kY7ojIWb7vEYu8JG50q4hOqIjcnx3OoTEp6hBKCh4bsuDPHtWBXnaC12EmYu
FjtVV635pvN8a/vlwcbLl7ube3tPHZTdaadlEOADZPqGSCjlZ4NrjZC3Ev0XBU7SsPtFSb9PmFfk
FMYoiuyFRQDPncU1dylR65TPZ4axFlyF+VDbrK2VWT3oRMi9mZpxZIzjYD8Juk8TbcB66jGZYw2t
v2wPvcVbWno1n7JLuTIJOsXn0/En4ucFzn2QAQYlqXAAx2dwZbBnzSVapAx+IzmPIcRW1VxIlxFb
RTLl+JS9oLKCMyHH1Lh9LjClqowDLAUplNWs48jzXhcmPGZJE3d1YWXzsc88pU3GcOYhQ3bsQ2oK
PzPO1Iq3/YEgNqnPLB3rWw32hAFed248/jQQ2+/rvX0mbSzZSidMH7llITVdeXpgSXWH/RuhwcHb
QjxGMzk8UGMbrMPEEJ76SRfpyaPJQKIWdC7ja3xOBsbblg6yjHkXBAKWDSzImJmE2FKNfLgFsw0d
RCIqVquJigLm8w4897onCX2twG48ubBQYOw5cH3wfMBYZJqPFnvA3wr1MNVibAlqWPX9YqD11kOT
Cp12ghQQxLYvrSl+YOlKE7K6wLLducQ9RO/z8UvrBAPsZ4pSzgqimFpvPGefMk6AoXoMOQn1aGMU
cTpbiW9grb3QXMnWI4gGtgJjqh6fGV/xdyNPNTXjysh0ezpjz/IBmG6MhOkQ25oI1riMTkWcvrdG
2TgqaoR4IouliGdOklENKl3aKB2P96bbIBFXcoPFREUZaIZsvfiAjbJC8f1URYCqOJJbDsDos8Rt
nBZhPj0Fc2+l7MFMJXI0bQwSdExZpz8a5zQBIujXdUhG85pXnsSpW+H7adCCF/SVVQZgwUQZgPZM
BO+QFy+KdjOqgQWaANoEFQwDfRjhDqMRKI7ErGvQGDEW3B2oaTJME/aKEfWKVWy85+CxMeN9FJuq
mChDR5MIbMzQEaFoBGoGVjSdU2wcXrBLYqveqjdsSIAGc7qnAIbTQc/Immfwm2XTrj8+Hr+3JnW3
dqxH5OXDMUpt3F6oQFm3vkNifGOTmOk6XRAVKDA8lmBV8SQ5sScucJ+QoMNqYUgim8OwcSJR65Hb
0DeKeo7Kr3faHLzxGN6b8MXStwxj4+z3EqsbbSPE8u1mSQ0JYl9yT7FX1HLueqqvd8xhDriEkEdo
CqfgRfpwlA/OhGrAJWhHo4XUTglWRiJQgWkXBAwsLUmwEF9DmiSN+YWuGFxOfTE1QMUaEw/FxwyS
NMtcIs6jic8F8lUTFhTr28XM5OAXNFlWy39VnPM1Gg/O2r4XpfGMrhoLclVcI6viF1lVAYbBoirH
krnhlnTr6yiaTg9Udm5kDx48jLwYUAKb6N/+lV7PxAzi4oqGsdHXVRsxSD/WHD+4zKSVrqFZk58A
41mR8UBlf4HB7CaE4+GNFHi2g1xDblR/cePy6U9sVRrSZ9DU9rjGGVK89zjoqjaZi7RHQr31KIcn
o2rD5xOm2eJMvkZA+5D+e6Trhv468m086UiPepF3GRH2+iBbUj5bGK563LE4XVYDn1FgqlDrhOae
SHOcJf7D9kcR/UTex08AmG2VHqo6XUDVj0mYs5OA+OHvSJOMID7o6f2wHX2YT/78GT74Hz9Ku6J8
0hBg4g0uIJ8fMRoj5EXoBFIEYlbTT+Kj3jYyQDYekIkvjoh1rOOtyIQElkWoV5CFH5DVylqFU8UL
e7g2HlB1lzwYpFNglP3jmNGzBGRwBgWNrWXGWnRDLl6ZF8suVWrWihdn71iDY1RR3RevYSXV7BrN
6NOuQNBWBnECbzLAuuNGJP3+/Y5hwQazimuA2c9Rf+y0AMqMvtjc3Y/+uPmzu5HVMfz5M8TQjKLh
zdbefl6joIw7eoVme1f6Fq9yeVpDjaJXW2825eTK78DmT+wwW6o6JDvvv9vdFJH8vbRmg5Lw+h/N
k++3t7b39jfevCEeemc+ZRcWdmsfiQlZ8xSYpmksO+93f9ysvdzY35Dm96X53vQCkThmu4wLFow3
DByjngqDbF4yhi0DEs4SbzAmLSNUpXoEJxPvUvTZI124AmgeSzgkho2UeXzA5R5Nm4i+cwhSFGS3
GJyPWhWlN9B+2tnoTxtv3m8Gh14Qq40ptk2Aym7s/rhXr9fxPJ1e7h/UyCxAmTmqVNS7HoBNE1pa
xcUqUKmOFufKRR1psG5nb/PF7ub+3sHzjRd/3Nx+2XEtMdqtSWaQIQ7Iu/f7TOnEeJjJ1eLr4wwX
YyOCJarEtgxHaF4ZPeDRH3/SlZIHX27tCgkInK6ZhtbiUXrGZiILQTEkhhGQiL7ObueqXieuIRMx
6LmoiqFB7B6p9UCybAt0K3XE0TKL7CEeO9Wq5LZAxR+RqAM1yi39jb7XLX0WLfjciySmKkrOk66a
c8dSidKjSqxn0HCxJe+FqAYXsWzXLlw1CsYg7kOf2bYLMMt61XSYr/9Qq/0lHY+YoNE+MKVkk5RZ
OtBjhFOLGMD6hjhlJniZNYz0jc6UHGmoIhkuxbLkCIAvxHDfR3KQ2O/FP1PRB/eVjgzjeNYt8GPK
09QhfRwY/XzUXFMF443Oxux29OfPeRMzDWM+otdr+rpznPc8RNIwkFz7lIsgqn/+jCX68+e4Rwge
/PufP4tE/+fPBjl1YAQHmYlevyNsryEEOC5sNZGjI+kuQAWUHIjdRH6AwxuJKZWl0FhNNuD11ZrT
MQGFHd+brVl9LC2wJahT4Lm1YGEIgYuxj+hAJ2HDHktOduxG7w+MxUPj7xIzJ44uwA+goP6yYvEW
0eCqd8tKJpoNSv3anWuUJlIJpbz7eUt/3W/USAou1oMpgXRox2b6NqcEKzRLTxkq35g8W9ySep3m
eZmqpN/hKFODXgTHdyQBEpNFk79JkyLVLVwRvCzLmrPWuWP8FeXQ//mzWqoV58KVgoe0bdcdigHj
GEPI+s+fRxr8yh4gJp3I52s6DBw0Vv78udX1egM4Gl7YuEgqbFkPSe+3dQpkWMt4Ka4H4OVgRh8D
+HkA+qAjrlVMEVcyDjllZXvgBuOcRGTZ2foo5zV3UjtKeWHWFws9sWoq3+NxOP0RN2TzQzA6RHKH
3GHqqPSdc2axwOVg3jD8RnTp+KzlAsYy4BG9hwxOYZnVZ3AseVnPZaoI2NcOidyjHrSyzNGIgpZH
pdIOPRwPhtH2R3w9miaTaH/zn/aZgEgLtdMmM6O4z57y3eSjTG1p83wAG2IPdslOg3Zwzo5LMBp2
HA2PpKwDXW0hK4PYujhHsSgP8mkBcPmeJ4Ety+DLHnlfEC+VvVDHWQFr8cI6gqaJY7ZYMVEO1CFr
Fd3qkDlUAYs12EauZn3EH9mb0hCVIpVEYOhibQ2oxcHOu13m2joNNnw1+A6CAZmVMxpWo+lE3Nj8
kOAcyUskpIxzlrFVRaWK+WgIly2AzwHwSgdvqZ0O49jferv5395tM6fbS5SQ+JKuiX2NyuzCyfkN
pVQG3aClP5mo+N5RWeKAGUIaN6QE+wMc6/udA2UWO8uElvKxgHjw17/+yzJkEP6xfBpPl0USSgse
17Okbf9xc3OHG5fl4lsv3m3vb2xtb+4eiORHbW693fhx88AIgp2iVvf9w3Q/dXZwMcrMCiK97zP3
NDXmcs10ssgOY4y5g5mZwd7mAQ+Mh/hi9+ed/Xc/7m7svP7Z5TcBUrkgyWnUXqk3V2rpcHBSOxyP
PxHuOeHX1gAzLaaidCrqYbMnMUywbCySDI6d/ywuyu0OUa2jJDVDeb/15uXB9ub+T+92/9gR32OG
Y1WwcFQn8wPCxGps8MkcYZvKr7BVF8pk6zQgbe9t7v5p68XmwXv6wiO2F7ZeBr9/xG+7OdgbNi6h
Zpv+0f2FrLuxi4PzZuvFz/yOQHxNmWvR9sEPcTRW7z85PffTrPnWpL5C9g2T0ok7ebv59uDN1tst
lt3fvPvx4O3GPx3sbf23Tf+3kc07zdbjE/aRaPCfFQuLeeENCHc25i9B6qCO5BQSrKPZIjoiIN1z
scNW/8eyUuRzz6Ag66F8BDymbjC0hqLovCWuYvMQj1L9gtjl0M4rYNW9A7jHygMSL1Z+/ev/WnnY
aFQMD88G0ANleg/EzT7qrD5255Ydxw5O4vMDEIr5FOzcsrmsrjn2xTW+xzKCffuAXXb49tb2q3f2
FuMubvjTIb8mFxAnIG01W4J113xSragz66qT+V11NlreOEKyhJYlhDjrS+CaTmOeBbbv8CITIvs5
2gz9aay2ZxFmsc3iIk8EP1TLoH0or0FYPmffD5mKjmJihbyMV5gHd1YkWwB4mTdvC3gqMjEmgNeG
3RKRnw5mwlt3mOF1hsD0eDC5LpuhArWIXHj/sQ+uloMUGeyziwRRcPfkRpWOIxuuwSiDF2vHpsNa
HPUi8oGH6XzvL4CQ4f3hBayMsIYKsBmClbDIBiT6VMmR1hf/P2ZHZMRGYhOs/dl8UYrQGbBsYR4a
TNrCI5Zf78ggPpw+/KjX/F2pBttQDdfs9Y5Gc7DNSFIZOuk1twNetlhx/Mw/7S87LGYGk7uoqEFf
TOrVQDmdDULxxEo8ZqIffdmiGhXJFvVgj7EOJB0d8LpAxUFC2IHqEWmENm6VF0GBnDji5sMmYqK8
BlTs4jbw24hb/APDsj8gJS1uOxcm1QbtqRrolegj/OFQIvSP9uLuhcb+mFZpMXTnXADOJnsqPC2I
7JGtMRoIXo20Y5M6s+nhNnkSnch0oLK7agKC7NZR2W5d3qSc2oQ3RjvghwAo6dEsP4wt5tMRXMXE
mWg8sa60mQAGqCbZj1ccDvREsYIFzsbTJBEvi88qt/gpysR1JJeuWmJIBykHdhpPJMFcCTAQtJDJ
w9Vyibeu/b1Z7WelCqewi60xK1YvojphU5LSxMPGGkLgTuAnSLLWTva6NjYnp02xJ4UdvGCW5VAr
SU0sCUhjmzpEE2RTf+XXG7ua4NDxJkS1EGyOWRakob1F3gnNCJtNOwH7OAzYzyXylaOQjAMwlsND
8+xjqcOFyzv8M6jBKRG9IIukyQ95y2ySLCi+IlRHeN8E4NVePH8R/SF6/XbjRW3v9QZx1RWXTRLn
S3zlLOA7Cn9qFajMPCdpzrlPNNlQtyaj08F0PMJess/TwATD+YmGVTTxzbkylJcLkl9qvB/t9s7z
P7581dIJSFLMVKfxZk/QxYynIy82iKWrAqBFnihIKlQ3/pJ2aQPft3b0mqj6O04NuUcHfG8wS57u
zaaDrnr2iUOceIiow6L4o7zY231FM4WPIoescba5nnO7EeCWp6VBemVHtm40jqSAlIlwjTh9+sXQ
TPaNsJec0HJrR7OoiL5CAxrq/mRkMTTZpshEEsBFR0oyInj5j9TBdF1dvYzbgEOSxkHMYg7ncC57
raCRertIHWBTcK5eFMVSqLNGyB9oVmHxIebssDQpVjQTCWbcK6pe+3axp4f4Pd6czZQkvBszmHZm
J5N+Gi3TH+al48kBlrUdwUJZmMYUYBIhHw5ETlEzxXwKvESmVcWUJ16yU1Ey2VyRS0svNSGedcl1
J7TMjBi6mA+HHfFhHWWtRTdnFmJ+zORMGqQmVZJ1AZ4gvYEeXvGh4Axr5zPrjJHaXJTszhi4YLA+
dYG/BQfOveIsSeyh1aifswtjvVk/N57Gnk+uTQUw9utbXJsuK8jsL2nMVbcG/QTcW1NRG2iuqw6H
lsK74TgWx+84J4SoL3xVcx4Yf7LAC9Y2g/IMtLpnMVGIiXU+rxrVXOAaLntfmA10aUn+stNybFLl
CZowS8DNM8Xv2LodMBxgTkKFBiYcUsJ/7MEBqGfhxuabGvtGvtpJRLg1CtqPClVmLKAt06jxyLWG
S6e4LXgnPQb6rM1v04lN++VSUGeDlLLRNVZi9COCBG/KsBLj9OhuOoJLfcpTBPJ2TMIaMwkcz2wr
65qVTr2k1HVcdjyfz5UzL6ifhfHH9BSV+SP9M31OTnq92uvXb9/u7dXpINaPfiFRiYEL9LCiITSC
o9mbXo7XLFbbEOEgP4WYc+OpBoFdDu1jwKC/QZLPWLwyONtgJu2+yt3mjmMwwEKAFxGWgHDCPtZK
mPpp9xjGruHgk1/8wG0HZ3xnYm4Yt6zGCutI3KtBKNItbc8hB6XONPskJM/l/Z23VkNqetYt0bAI
fZJQOcsimZ6tRizTZ1FbyI2Ipuq82b4jTeQ8GozHjORVZKqhwot68QIfqcOA6WTgtCRO0Q1SUWiE
6HD+RcgZGQaP8ys6Z1bjhMEAA5Rp2q7DnUKHX/seXnPPOpyGkQOuuqoc0MGBZNSIoqUW+DRSoiC3
opJC4x/Ey+R5C5U/5Z2FKsqlOPgOMzVqjshajhF1aXMNccNTN+cIpDG+5EkECf096J4mQiDU2gGS
IK6/usGEtudTeB7a2XiOTOrIneFdlwY2bkVDMITUmCbFrS6ZxIjBA4xK9r0g27OEESPmL6v4uYul
6hofpHLDqVWLm1TXjjqhU9rMP0SdurnCOsG+l6Oe+vkTL+cxUSubzQh5ZvkN0RMs7mlBWkJq9Z0u
X4ioXHLEmZcMEQoNpprISJ/JCilyswyhmE6xPaamIFe/OGHd2o+mo7pZRy4RZZxermkvnXY5kvu5
D7KeH4BNu6u+TOzsYxyaKteOFBRVPfeZe4BPDi+18WB1jsIFNLESEguhdmUpY3Bzv8QOLVvltXBz
9cvudFalHb5yWmzvWghoi1tmqoWi5x/q4jErQeMcFROV/8veu204mxqHXzHv0dNFwGRyyj9Ac6HX
n3WxLSNMiQCj1eDj77e6yGgo+yk3VWezKPk6n975lLHXZ05prkYy7yC/EZCMOj9u7ke6ocsMpz/0
EqCTQe9pVptzBj2O8juSWaPmzgLtyaDXWWYjyZC+qagsYCoJFGx34j29DJ9cjlpi59wOwyf4YNTk
DrKV8sE0WjgkEcq3QG8H3sAmG4P/tM6S6D87MIijs2ilNaVOMDx9nJv/Af8+3f490c2ntaYmVwoq
ltHLO+/2it/uaEYRaeTD73lCT8ejj7/n0T79XqnnM9O+IHbr2MjluPSE2fA6Lsw0H1lx2FAWorXK
wXBuK35s5iiKbr7kntEhu+0XtbYJdTCZCLvxdDrgOkudF+m0vw/9RQeiKnzw6Zl4aD2cTG0Nteuj
y7NY0opKft2M/zq91x9CqsBLM1EzCvqMVdIXlUPXZS0paWofaejXv/5LCQoCLvvFWS4klW6Yqi0q
q76cMN1pq1sBV+gfkneHf0m6YTU/gK2kLBQrJ2deYXX0RbqtNgf6+kaTWuhPRtTdmf56P0GeHwdp
fAQG/f2LCcDdZjIBmQag2kwkgiM5VYlcZ1jTzEt8AZE9/u/Xg6PjPcAJa8rHsxXcTF9yphL/ubez
uXzZGi2/m882OU+JNvFCrl2+78bprPqWoGjA355Px3EP3652PvFJ63OUooGslRanQbEnzp0rdVmL
bOhZVGaYdCFm67Au73fEvigeCOKaYkC3UnzU6KUoWJX695hSLzl/1omeRiQrRq1sU9lTwOFO2lYm
xxUcWJ5qav1yU1UnIhwWp8PCC5KoTYDzhabEKq9UbPoNOLVpQqIyF3OBcWRIwhtKuVQ4qAD5sKgP
Lp6IfLcrEBCHrARnIFuXMwK2pJdMEAMz6nKWqLDGwRKHNCMZI1rZ2NyrcLLRPo1f0/5wNpEaEHzP
qf41y2GClJBs9eCMChcSxs9s7uAXObXlrsb9a62CJTS5++pFtLLaXJVkIacsMgL/snL57cu1ZeT6
fvJQwoxV4VxrZfO9ldHMo8cPG/QmzYAV1GXTNGcmWLK661fP9dbj1sOKMQtVbeb72tlgRAADjHgx
6gpCEuf6qXhbm0oLo2TGLoNiryLadWrClaAVXTJXRXKSshx1LRdyQxkTSeaeo+VLv/7z//3rP/+V
/h/dVBPA8Z1/4CQf3Yvu0ORXm3qRLl5dhYKiCl6H4vvDUk3hR0OdnAsOnaUivx71yKkaQxbOSsXr
BxBOP/9PajI7W61flOlYZ9E2/IycFdHJYKomKYK4rm7sbFXZqRyhedluzpLD5UV+7uAZBl3OAJrV
qC+zNn2dM+CK5r1im/5nbZoBaEHjMLfSNmH3jwx9Szj10QktulrKxLTuxsqx29Hij0Q1E+mbpUtu
GLa8cxT5tZ6iyFT1Zm2X5AO0WV5jE5/FubylolTH2Iw7DjA6fpaaUGDg6HjN9gEL84CZEk87eLNC
ORfxAb358gA3f//76OTU+319VQ2eouQCmEzHvXl3QCBozJJ2xJP4ghXkjF/hKTglojFIAQOiBmOV
jiqkrV7VaoX1TB1xKbUYpqpBT9DVUBVSGMGfOJuQWHIIc3A6pUjc1FQtMz/BCLphvhTuxRZDmY84
lZjaULbZaoLYivmMA9I1977MJh1wjBCKICNOZdxVrqmTnA9mUpsA26G2Fy02pFknEiQkSKR2y4Vk
3h3VsxURhsS+e147OkjVcaHs3VSUTmE8DZRFTpKUeGzDGvIRg9YoB1BQB/kytl7lnNtF5Z3UPC3V
mzDVfjz1a4S+3rF5VKEQl/ipfH1kwJ4pjewVgMORdaQNBpixqS8hybU1CxDba4i2TGhE1t7opfUz
Q/DJrq2A/HbruUzLJYOWIWBGSAcHdSwGXzwaZkJ4AJzoMJJ4JRjmp4kFMrEaKm1zAkLAiDhWo40M
rssbyHkNYs3Jr7U6R1WnagxgTBsr3pi4yrSlojw4yfsMHXfmMV2eujG4Wfd+k2NM4gOImYENI0YS
iql6D401gYTEGegZmibDC82eYur+mh0w0gcOj1tneosOo3KCaZa7Nvp0ak6bIWagbOWYR/XzirHe
TBnh0zxMKkynYhOBJ5c2BrCTjuuSkIJdTFJ5kt0DPMzje12834KvwoMHbx1bIb5peC+bMT0jPIlH
EDxGMllKZaHeaAEov1ih79YRC+RKZBWXNaQWjFgKJyY1K2cSSkAPl5oMyi45BWc16ZjyoNOEwEgy
RdJyxoGEdxKfD05ok2RcLFmUJKEZsAriZkcX1qHD1HgUDbyNGTZpYsRrkZiIQfdC8DIGnnWhJSga
yK4LGbzvkhbpq+qNGzruPmXn3DkjAz/O2xpwTPVMEYIFI0gxSpS5hel9Gj2WwBgtFkbcP8NVGh1j
yw4TBNzRP3WUKF/uDw6R4px5tJGttgxL9xERNVCWOSASolg6M2yqYsq7EGkbt+rCAwcuL8JKQ6na
QstdEPuaDTRkLm9t7fpI1zJBKXgzZZ6MWnF9Kbr7554plyAIig18Y4m0ZX3KpwH7QHA54cpSt8fc
NDEjr3cwsQNxgD744+bPT88jcWVfybCymKtO9Z4yDvOBMzBLyIdEJ9/3ZbX7lSXTILgx4S4xYTSO
hvG3Gd2fnN33im/cw2lEDJRmpwGNnYzhZpTJZTxb0PqBOmhyDw+RXzrcIGk9UJ5AKiW+cByVOHaj
SwdyekY/xLumVLllTygWcrpS0xIcJ5yUnX5LiFacpjaCqckjqdfrEjCo+psyiBTRpgpzf//p22fR
x5cK/lZ9NOjzcHWV/9In83e12VpZ+0+NR42VldZq8yFff7S2tvafosbfYwHmQMVR9B91/+9pcg4i
miQHDodgxTjdnc1mqzYINlERBT8bi8lzhNqnTFXUw5d1z8ZcqHn2LC1AqcCigsadawlMR0qzTCb8
+i0qHVfVB2ygKYBteheS4Wh+priy8tpR5+3Gf3m3W3+7tU3/7mxI8iBQQs9/kVPSIyqHUP1pq75C
P3796z9HrUbrYY0G3lrhnw6XqoKnPzgXP/kN9kmi18SVLIadazTmJGaJZG3qDzkqnfjwnklOxuzV
jsl/lkZHU+KpoANnnwlkt/asYzLlyRzGMcMgoa0pJx6MR6pOH85PRrAQ4m/KLuvE0sAzhu0h3dh4
rBBnRJIe7fjDx41oci7DKhsubSpjFQWkDrZS1YrYxDv46XuJR46Rc0tT9nGqDSHVh8Tif2JVwyw6
vpgcJ8ge5YRdSbHWZR6urxYCpHuT9FwsjYq3AmY4Hg9ngwlYqG14Ok/ji6j0b/9a8mXn+YQrt6rv
YiYxvVYniJ0RQsEMTbIukFiAQ8IRbtc4LyEyYPaSM+bVu1N1rkZdnWOkQ6BVQ60J3U0BBWfhY6Ci
5vckksOASCHwNXzgaxQBn9C8IO90RkQIQbHh10UyorstVlNluPBDDIznfVCnQgSz93tv+Sj6Ouoi
1bBV+t6oI46MjjhUDzM7d72KuLW6TELo8srj1eW1ZlZh7LTEquu2qmGrD/Z0wUZmZ30w5ihAoiUm
SE5ib3FwU+yMRyuexnBELReUVigup2BLKEgt0SXRC6Y2ij4sqFBdXDHBZj10vKq3mItV1uXFYnxG
hNcetm3shXGxDQM8onJnpbOMWjSVW8Z6qOfqyPOF083g5eDKPqENKRegUfFq5EhdycMLTdLHYhGd
2cwoxbMsmWiZAOJWZXrZIJnUFGU1MSQaA3qYhPVi1p0ehXOexNa72bDF3rG0if69s2kzz12fjdFa
aoPcizZBLDSOsVhO2XE5l4+xICgF3lxBCj3nJejqSUjWx4EYkquRq90g6NdkZzQShswTODqfQ1HV
ClC1MW423u4FGSw0HaumYuQNrWhJFk6qCP/VkY2NWXcpM20ImficeekkVdqXLnntpDBM7GInTN4L
JRRWMyg2x54STUMFJloTBr6vPGaskHQgRlzYwy+ITRGbJmez4GyjB+kUzkqq0KIz4zzBKoxNl+PJ
YFnTvq0radbGJB2FKkmiDHDXvfzNNqd9kIwRQS9+LaqqljLOIksPWXn1BU0pGDn/VVP/1AD6MQoY
16NX42mmpJHZFEmUcjQd9ASaObGC5NbkgCJO9MrFklHjzma2HHpRUIyM9jNJKVNRtiYuhj0Wt7Yg
aWbsqhvFbIce9jQoQR4fpFqrOfayLcuS0impc5XdMMNIlEkt4mUUCSuuBdXWsolECvKIgB50tId8
ChEvYU9HVWEMB4zDWFZOj+NlxMH5CWM6loid2UQLvBxniUSyvIX+xEagmcDBI9b/Qgtn3XlZJ4w8
q0QYkQkDmfQIb7DY4GEOXtVlqYGUBAmUOJE3tE0p63fKOGOrjyuFbFJDuTBac1MAStJt+rnhgvJq
5RUvGKtiswQmhvYJtGfh2tQ2SuU2GFlb4jB3Aljtnpwz9U+DIj3pJOnCi5kIrGyF16Nt8GmmzCIz
JxVgcC6pNR2pd64W42QI4JKHef5wxecPW8X8YcbJRRnFyQAKTJ8zbClnmHWKUa4EufQlorcduaQ9
hPMZqiqm8I5RApk0xKIwp5e9GLEby9y0i+r3VKOwLI9xhEE6G9TWEa6N/ceR51vr7hiHk2rUlzLR
GY8UM87AeQRpnNmRKedB0tHQvYEgrqlkxjYE0k6a3TtsJGDJU6uXgJfKHn9NK8fmCo1YtOjLhMZt
b+7/uLmxW5NkO1vbP2KBBPtna7KJE1RHC6gpzdFSaZ3iKmlalU3rdKppQq1ChZ3oMtRhuYxPFZty
/TRF6sLAKtm1hVIkyiqxZahsAIBZshdeGVqlXYW19GwlPsc2rheW0NP46kwZPZ5TWLUl52UDdUPs
uc7U+giDNYBtjWLPN3cZ/3Wr0Y+b+/zP8/dv/kgneEicEkGOREtY2WHJN465CUltGyaHF0aCcHcN
MSVJuALKJDRRCke5whpZfl8mxp46UXyYsgs9RFq1fm66St+anlhD9dc13h4byfagmIcyVq8mwrcn
sZ6YTHXvTLEmkeALRDvux+Q20yhKzgbNXE5qkqGK7U4i2wiTsRKCXwH34IyoIXcjtBCx+bpoKqgQ
LHJGGtdy1YY7hWxJOvhFYNfYCCH1cKpGk+uSgdMkPqsWJ1kzOdbWizgGmZmX6gyT8ZOcLSDxscN+
nK6NJ+CWyZVXUqLfkfAQK2d6TZqSFF5+3fHIi4tMOZhJPGtZbSKp1F1xRBBsT9J5NThPem3D32Oe
iufNyhGrBT7rZJCmLpg2zDLHlTekSKQUtffNwWC9kX6ZcU08gnwI65xxPNUKWlzScSbqCwL4T5pZ
TdkCYBsOSOWSjuHIOZe+EAcjY3dDdGSlTBNj61dO9M7yNPElBEmax69w6gYITK5d32UVHKxWacQq
Wc5TB0incTAV35zAMO/64kqcqPXHTvpOvkExwwGLRuO5wrRwXvTs6uMqsuLzVq08QWXVM5N4mbGa
4/YyR9i4FlQD3kdTdZTROceyRH8Q+zaYKexCOkOmsyjuTsepBCCezIfsFi5cYrWwDqYUx+IDAgrG
ZFyEUV0pNY2zb261GMlW8DCtpJ4+K3BV9QRpeQ2Wfbiqp2AHyzF5GQUkixjneENBGAA79cn1N+Fo
o3UHNF63gKU1+rcdx4QBwDjHO13V0gHW/i3HXCcaT4/m8PJM29Rlsy6IYFGm7LLBF22D86SUpcMU
FVhJEbdlsG4XXiKjbDZtAfkFGbVVTTLWRUGLK3UtsR2k1tb0FdZbfcZpEBjDp594LYMM284HwM8y
qEkGRRPA7krzUYzcAD1wAXlsx5jdZtTPITwh/7ms3LQHtvLlDWm5tYSArQMOJtmWAzjjNPyVUFYR
gFNzyqtQ+yq5faF8yEk3UgHOuIwgctCJ55wrJmSTAuwB7dUMJY/gPcTOGuIp1slk5jWoWh/y35td
SPQ/R7mFFJFYbqI526w15RLZ7DpHnDs46NkMiFtDzPrFCSVN8F5PsobgtnmDNTGTwcTg6z3jK+A5
F3DsZlYuavlyUbNYLsom7vA16L5c1NQTW5Tog/kDk5bMZtJqM4OSqXvns/yuuh2A1tS3y2QIydS6
Y126EcJd6Tph0v3ydcPxeMIyjtbdUs+4YJjIymWSbDgnzp4pEAVnMVVZ2trQrjYUd2nqQ00TODIL
S2aj1zVH40W2fBxXODLRvVXLIPJpuHNJOO2Tkz1qhy44XtXi7DKUTwOWre6VdcHKq5391ADABAWV
uaTLwuJWOgQhZbYQUa5SlimRxduQ2LQguDUeGd2l0kam2mrkIhi1jAtiqW0ApZlnAIrrPAElcQV5
CfgVASvdT3P4cqX3UH7M5D6xGHNRrcu2sVgSNZtDKyJVGa3hQSbIBSZZ5eJSw61nHY0XJGowsuSi
WoCHiHXWaoDs2i4lAafmvcDZy1hW4SoLfzyTDtNkqMjEGdNhup9qMEjPFVoL3cOMq5xRO/wkkCO4
HuImVst2wHUFxtMwNJ4XzXCqrspl3TEVkl5at2UnmRq9mZ+Aihm/bKEv1kPU7W6OjAaVjdC2vE+u
slZVwxlmjOkPbVm0mVlYV18IGnTVwgpdLS4y1Nl5vx+xFtypL1H2gOsMcSMsTElVoaDqEIOtqXnE
ZisxSGRLawXlsABsXu0fr26HqxBSmBlmgXToBh2kAbe5kG+bF9kJgsA0naWIZRthZxyp8ki9uAwK
0+AXDqg6535WEN2jc9sxC4dkW+wK4KvrbV1BKyysPPGEhRUVFoJziHQLzEGzz6ZqffTYclSSYkGd
swSIgiCAhhGLKzI6XjuKp4fw2uCMyeuW4183uG/OmW0S5vgEEU0lDcN0MDGITZMrdV3RQhKWGDnT
kUIaMTf0dV9xYcBpxtlZ8HVjRwUCpDtKHf4mQaGAvzda1C1b8JVrMTFHFx8CQ/OIsaT+6pWdNnCQ
w16SRkjZTvWIINQ14IAA6I1FpvV9HiSknBGJif9fVDORoxZGtyxKi1Ml8SJihdRClWHsO+cyyxMD
IX+2qqTkwBLc7ydBc2eLy4JipW5VrCYqe/m+2ZFDiyZapETr5NkDLO72qihWFla8uW3Bm+p1pXlU
L0cCgmgVwsKlNh+RSQ+WL1mGhfFLaZkMVV42NGk3Q56CLM+3Te9cnNK5qoYK5tOJtbDer29eHajb
s++IhRyETA0LfKIzqGuf8zqNkGcDCI/dmcSjh6Ov2GvIwHgpPgSHVZK2R2MvRwcRbHFqzkgMrcdO
YhD05ZZEKvTSo4Ze2/opftkwVgN4i6LWbvgFD9j5SZf0cDroHSWO/y4w3CyQSfaCOjaZSm2CbHi5
ltS0YoKjWBbWnNDwqqL3+sPB0TELKbuuEJE3CBdKXbXMo3AsNloxG6GDsKZZ1fbDSLH0gnaMM50p
WvQCGTjix7pi6eJAQWUizFDCkbWJYcTkPVSZ10lu2jBFG7poYMWFolVNlJrUJe1qUsN8hKPNoilJ
ryQPFgdg1VQYEQ2SixTT8C/jf+4iqYx6bRRGYEV3D5CKXHgUhOHrAqOq+bCoakFQVGB4kKPIZZu5
OG5P3Qc4oitlRpDFdqDTeAoxfdgT+ADra5UkhSWYOCbCCbOWNy8oxQQdgV/HSnGhqrYCQJfUWRYk
XG1GTYQIpz+pLCwO+WPNsdL9xL6eXEVzOj6VcpizdXUoYIcVo0rThzNdqV2Aa8wYV9QaTFcnJ0hd
qgjLIE5UmRAzn4pm5mDoA704ORG7GuMUUHnJKkUso9KhjqblgdMUVLgcdimceSNSJztV08gGnNcm
w/kR8jWDTWUgYAyoXb7YZBUKoR2OvdFjbcSNDIJFaXh5jZOMmUUo+TWp/SdUO1sKehxkNNY2HY36
IlhFOfHgffh7aI3tMK9SmC3HqzjpVUTJFeBGThZkdYRPqxoldJ1p0jZaxAJgJcumiAOskcey1OJh
llro4Y1P48FQlAa56FEbxMkOsewKXLUWCCahVYN6Dsc92AMkZ5bHuGlTIeoHpBcQkYav5WoUUxRT
3BMGE5d+h50As8wr8s1ULIdiKpoa7XRN0sZ4I5B4y0ywuaGcnRMSw0jYpnMWOnVLMlItJs/OHExW
iiqlepX3VCmOam2RFySFI0unfDadc1m2SOycKaMYakvUliYrVtlL8sUuNl6WrKorLFipCjnlbpIp
yaSD1LgpITd/1Rb25iw9HFk1njHwZjP2+PiC4d7U7vaOK7IRO7NP1cUUn8VcqMwe/zhNzEpiHeuS
tyn1vNxZCzgEWLmyd4aWGIOnFMgIamfw2hYW5VgnMJ3ZBOfqhdVLRhZNEkR1bMxeUFvjqWRhB5Yy
B4bJoOb6PEyOB2zd5TFLSQ1zBoNEZRJ3avStG7TbPWa+IM+xGw3sGidJjTOjmXcsbR67Ws6y4kck
KU7WffRh8xbSmGBMS8X+G5Ubjzjh4b7Nw3ZN4rBBmk2hHOQPRE7AlnA+rLrnjGSeJUuhW+slTm21
RIeZsiy+Q7O6sdMvTTyLnStKPdtBxjPmR/zUshJfyfBuzA+xn47WCJv+ygxGfxFPgVglUlgKBicm
Z4+fQY84UkLBsOiyiz0nL4+nISUTmcFSCMMN+kSD3U7gz8LpMhcJxkrtWUvt23NjjxwRo4O4WuOY
2E2sC2yPF5qXvJJRkAKphem2ka+eqHWVdVNVzbxXFSf38ch8i01J8kxBCZMCjXUjWuTE4XLWMkxj
lkH8mjLIe6HVsBck2GtH2QrRgkcmXM6b9zvlDU+zxaEtV2iqg6IqN5hBRpyji1Atxuwob6hvcuo4
LaljBAapYTOqRZUlYfnHS5I1V/ktkwJ5f/9nuUs7el9CWWJnjpKKbLlqZph+aAnMGxyxl3ggn2PV
7LKXaVWTVPrJKd1euXSl7N4uaefEhDofIbIYekZtoG5a1r46VqERZMO8n5rNW5BnMwYrpETLy5up
rfb4IVkAmyaTdhJO8qk0kE07KckmBzNrvk290C8XcE/DsarWosTpltmqi4bHK4LLYNRqKT/VNhMf
w42vk8b95ABT7lSNQpDVfzWo/6oWn0jxb3GaAHk6JpE0EcAyOToZOKsWKM2bps6F7xWgaRmms5qi
InjjRkdzdiIQ8JO9dUNRG3amvi9PzVIQjv71QptNRmtnfWyoPvG5xkzl06BLEk9kUy3Iu1jmciZx
1CJK9p7m1gmSJXfw2iEvEmcJOW1izJnEz2ES9Br7yos7NMw6TFHorKMAC5MB5SdMqDNK5B0a9fi6
IojUZU7nKg4h8QL/YsnXui3TI3y+DMfVKjH5Pq2TTiaEo7BYysKSB/WCkgZYklyId6cq2XB5xTXp
qOQcPbNVyU9jYh7B9ww40oywgB4zi8xZo2xwiJRrrEamXKOAlXhc8BDDAgZ2Mn4lg1fjqcmHIFwI
O1dJYIXJgMBZ5U1pgugP2doEqjI3UM21CDSJX2EBgv996gn8lCuYfB0NlvTlSnmdU4yz+RCkMpmX
qgE3kugw6XUW5DReDjsvX7VYWdvY0DI5xY1xGPIVeKVqpGXBhAHTsDDxojXcWDWbSHsZvuriocIP
6prQIoF2wJ3nL4h/Bogqc4eCbTX1p/OwtOJvxj3iEMBME3iiwE0eqnJOvmHlD+bEmB8SEstsgUqV
XL/Zlm2uck1lracMxAVQI7rNsVeDESuwIN5weJksPpgOrcxkvpuCRbwywtw6bOcXPgUUCsaBpoPH
Ky4o4kDH3IFJf8KWQ0jlbgFScfmy8/zx/ZZvGOLm2burB32OYV9jY2ioo9zlyC9PY3gEKOY0KQur
Z+GPY9Jlptj7I9FvuPWMxFPsaMzE31UGDx0saeQo8xpLXRFXVtn5iwgCJqrJOSLYCgDgkgQsQGi2
+A4PV8fkVEXi/8/8kTjBuXwxdaPxkbEoQrSM3sAewDSM17LimcmS7pmztfKv1Q6afHBeYJgqTlHP
S86GuO6bKCet0MX7Zqp7MVpX13FxaDrxYudMHTjnD4rumCnSeMOZsRAah1KVnTVqlK0h2bJLfnwa
JvmOZ0agb8pTyMqGzhqGh+SAMSGQZcJuaaHpE3bPio8J4HgPywDrLVLoNuD6XFU3/bSwlgpiK47V
BUhKqljUKKZxziEmDXjxM6mtRiQRrUJLhGDfULvGlq6hA/1PtVdT2p+aLA6h8peb26DCo3E6GvT7
+FLjarpTuB1Y0zW6WVnRHDLWhYqY1ZRjQgpcXGM/kwyxk5yGper5D/q2YRvGUFXvN2xZxmIsijQi
o0b/OAOoDe1JyxmURaPXzGv0WvxzSzKRAyUlcZogjpwredRYgnbml7JNIzYcHLJmn2VV4U1YmSeM
qEluJoVDsXbsRiIBiI4JMbExBfUweNLPSc7ocqQTMxhegAcLMczKu6LeQPGYb7SzsODIt7wtf/uP
5oH8m/Zxff6XxupKs5HJ//Lw0WrrW/6Xv8fn7dZ+9IY4uxHhkaUX48nFFEbjqNytMNaBfugoST41
6YrQnqSH32mdblSWlnagXLHMCSyjREmOpvGIGQsOmyLGAB5m4GeQCGR0wbEA9ML4EAKlEjYkcmTT
LLQ64/6ME3GIdiEddwesiiMpfW5zHKubB3vVlvb0jVKFO+mRHLqkal9zy1JdMGCgOswBOJ7d3Hb5
I4WHwnKkS9QoMQhVtbeejHuDPv4mPC0tUl5Fwgtq+nAOqSLl7FdYV6aOy6BkyXC4pHWx1AxtRqdO
RWOszclgpkvEzNDZsTIfdiaDdKlP3ATXRefpjmnJuEeoWQ0DJTluNAM6oWImmpK+Mz4cczii2W3i
Wgaq2OQNmLhd1VvpMZSMh4kJCpJiid50puge9IYpE8iC5NoLp4n0oa83o713r/Z/2tjdjLb2op3d
d3/aern5Mipt7NHvUjX6aWv/9bv3+xE9sbuxvf9z9O5VtLH9c/THre2X1Wjzn3ZQUz56t7u09Xbn
zdYmXdvafvHm/cut7R+j5/Te9jsCaZSzpkb330XoUJva2txDY283d5H2an/j+dabrf2fq0uvtva3
0eard7vRRrSzsbu/9eL9m43daOf97s67vU3q/iU1u721/WqXetl8u7m9TxztNl2LNv9EP+DF9OYN
ulraeE+j38X4ohfvdn7e3frx9X70+t2bl5t08fkmjWzj+ZtN6Yom9eLNxtbbavRyA5YYfusdtbK7
hMdkdNFPrzdxCf1t0P9f7COrMk0Dtd936Sdxtu929+2rP23tbVajjd2tPSzIq913b6tLWE564x03
Qu9tb0orWOoo2BF6BL/f723aBonR2nhDbe3hZUzRPEy7WavVuN4b9Kkk1Vx4uaG0DhzxCgyVEk0J
P2ZJ+Yn0O2yeOZyPesag62DWmOelwu6SOJmnmpHYVADQA0ZQHUUn8xlCkuD++ePOm1qr3qiNpzVE
F01RL08rsx3RKZ8f1mmUy/99Pu4RX5TMlvVVCF6C49DIW2nET3hX0Ii+sCxJ7Wr6Ex4k8WTQ689/
+YVaIhSb+RS0ZF9Y3sW3V/SNmtm5+Hnj7Rt+53bNXMQnQxoN/uD1Acdx6Ou1F2/f3/C6zmPC7y3L
60tLyK4L3Y8uVFu177r8vdyCm1JxGhgds6THKZhYnUbMIUZjX1def5CqwgCFIuLpFDIH13WVkDb2
+XAYFpRhSSzyAlADUyrPPSPYzK91J8DWiw4HI/DDUgMLRvx0SSdnGP2TQ/ZegXWAXSRFWwM3EjUp
UbM073r00nSnktySse9fqDFLlXc2nHiQeO5OvuIc4vkEGmxRvUP0JCpm3psZS8XS22QWs15+miCQ
+9TEw0OyY7eEd/QGUXXm+avRj+Mxpv4cjkjV6C3Jkt3nUzpNv7Be/AVXH90gfn9DK395VlAJBFHl
j4gCoM8BoRmIGghmFhpccObVAItKucOBtVUiu0hvPBWTelXiJ1n2F2pmZrG0cRL/AmyxM0zOq3x5
jHKLSEzdx1uYpT78TVT49vn2+fb59vn2+fb59vn2+fb59vn2+fb59vn2+fb59vn2+fb59vn2+fb5
9vn2+fb59vn2+fb59vn2+fb59vmP+/n/ASr7RDQAGAYA
__HP1810_PAYLOAD_END__
