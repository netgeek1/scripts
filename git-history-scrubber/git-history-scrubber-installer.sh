#!/usr/bin/env bash
# =============================================================================
#  git-history-scrubber-installer.sh
#  Installer and lifecycle manager for git-history-scrubber: replaces text (a name, an email, a leaked
#  secret) in every commit of a GitHub repository with git-filter-repo, verifies nothing is left,
#  backs up the original history as a git bundle, then force-pushes the result (Docker)
#
#  Version   : SCRIPT_VERSION below is the authoritative version string
#  Changelog : CHANGELOG.md (per-version history)
#  Docs      : README.md
#  Author    : netgeek1 & Claude (Anthropic)
#
#  Usage     : sudo ./git-history-scrubber-installer.sh              interactive menu
#              sudo ./git-history-scrubber-installer.sh --install    full install / reconfigure
#              sudo ./git-history-scrubber-installer.sh --help       all CLI flags
#
#  Requires  : bash 4.4+, Ubuntu or Debian (amd64/arm64), root (re-execs via sudo)
#              Self-contained: the app source (Dockerfile + app/) is embedded at the end of
#              this file. Docker and other prerequisites are installed when missing.
#  License   : MIT
# =============================================================================
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="git-history-scrubber-installer"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

# -----------------------------------------------------------------------------
# PATHS (overridable via environment for testing; normal use leaves these alone)
# -----------------------------------------------------------------------------
GS_CONF_DIR="${GS_CONF_DIR:-/etc/git-history-scrubber}"
GS_STATE_DIR="${GS_STATE_DIR:-/var/lib/git-history-scrubber-installer}"
GS_LOG_DIR="${GS_LOG_DIR:-/var/log/git-history-scrubber}"
GS_INSTALL_BIN="${GS_INSTALL_BIN:-/usr/local/sbin/git-history-scrubber}"
GS_LOCK_FILE="${GS_LOCK_FILE:-/run/git-history-scrubber-installer.lock}"

CONF_FILE="$GS_CONF_DIR/git-history-scrubber.conf"
RULES_FILE="$GS_CONF_DIR/replacements.txt"
SECRETS_FILE="$GS_CONF_DIR/secrets.enc"
KEY_FILE="$GS_CONF_DIR/.secrets.key"
LOG_KEEP=20

readonly PROJECT_NAME="git-history-scrubber"
readonly PAYLOAD_MARK="__GHS_PAYLOAD__"
readonly PAYLOAD_END="__GHS_PAYLOAD_END__"   # payload sits in a never-executed heredoc (shellcheck-clean)
# Pinned defaults. Override with --set BASE_IMAGE ... / --set FILTER_REPO_VERSION ...
readonly DEFAULT_BASE_IMAGE="python:3.13-slim-bookworm"
readonly DEFAULT_FILTER_REPO_VERSION="2.47.0"

# -----------------------------------------------------------------------------
# CONFIG MODEL (host settings -> $CONF_FILE). Rules live in $RULES_FILE, the GitHub token in the vault.
# -----------------------------------------------------------------------------
CONF_KEYS=( INSTALL_DIR WORK_DIR BACKUP_DIR BACKUP_KEEP REPO_URL REWRITE_MESSAGES IMAGE_NAME BASE_IMAGE
            FILTER_REPO_VERSION BUILD_NETWORK TIMEZONE SERVICE_USER SERVICE_UID SERVICE_GID MEM_LIMIT SECRETS_BACKEND )
declare -A CFG=()
declare -A CONF_HELP=(
    [INSTALL_DIR]="Build context location (src/)"
    [WORK_DIR]="Scratch area for the mirror clones (original + rewritten); owned by the service account"
    [BACKUP_DIR]="Where git bundles of the original history are written before every push"
    [BACKUP_KEEP]="Bundles to keep per repository (oldest pruned)"
    [REPO_URL]="Repository to scrub: https://github.com/OWNER/REPO (no credentials in the URL)"
    [REWRITE_MESSAGES]="yes | no -- also apply the rules to commit messages"
    [IMAGE_NAME]="Local image name (tag = app version)"
    [BASE_IMAGE]="Python base image (pin by tag or @sha256 digest)"
    [FILTER_REPO_VERSION]="Pinned git-filter-repo version (2.47+ for --sensitive-data-removal)"
    [BUILD_NETWORK]="docker build network: default or host (host helps behind a local proxy)"
    [TIMEZONE]="Container timezone (bundle timestamps)"
    [SERVICE_USER]="Service account the container runs as (nologin, not in docker group)"
    [SERVICE_UID]="Fixed UID for a new service account (empty = system-assigned)"
    [SERVICE_GID]="Fixed GID for a new service account (empty = system-assigned)"
    [MEM_LIMIT]="Container memory limit, e.g. 1g (empty = none; big repos need more)"
    [SECRETS_BACKEND]="auto | systemd-creds | openssl (vault encryption for the GitHub token)"
)

# -----------------------------------------------------------------------------
# SECRETS MODEL (encrypted -> $SECRETS_FILE)
# -----------------------------------------------------------------------------
SECRET_KEYS=( GH_TOKEN )
declare -A SECRETS=()
SECRETS_LOADED=0
CONFIG_LOADED=0

# -----------------------------------------------------------------------------
# RUNTIME STATE
# -----------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
CONFIRM_KEYWORD=""
REPO_OVERRIDE=""            # --repo URL: one run against another repo without changing the setting
SOURCE_OVERRIDE=""
SRC_DIR="" SRC_KIND="" PAYLOAD_TMP=""
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
    mkdir -p "$GS_LOG_DIR"
    chmod 750 "$GS_LOG_DIR"
    LOG_FILE="$GS_LOG_DIR/installer-$(date +%F_%H-%M-%S).log"
    : >"$LOG_FILE"
    chmod 640 "$LOG_FILE"
    local old
    while IFS= read -r old; do rm -f -- "$old"; done < <(ls -1t "$GS_LOG_DIR"/installer-*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)))
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
    tmp=$(mktemp "$(dirname "$path")/gs-tmp.XXXXXX")
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
valid_name()     { [[ "$1" =~ ^[a-z0-9][a-z0-9_.-]{0,62}$ ]]; }
valid_user()     { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }
valid_id()       { [[ -z "$1" ]] || { [[ "$1" =~ ^[0-9]{1,6}$ ]] && (( 10#$1 >= 100 && 10#$1 < 65534 )); }; }
valid_uint()     { [[ "$1" =~ ^[0-9]{1,4}$ ]] && (( 10#$1 >= 1 )); }
valid_memlimit() { [[ -z "$1" ]] || [[ "$1" =~ ^[0-9]{1,6}[kmg]$ ]]; }
valid_image()    { [[ "$1" =~ ^[a-z0-9][a-z0-9._/:-]*(@sha256:[0-9a-f]{64})?$ && "$1" != *'$'* ]]; }
valid_pyver()    { [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; }
valid_tz()       { [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$ ]]; }
# https only, no credentials, no spaces/quotes/$: the token travels via GIT_ASKPASS, never in the URL
valid_repo_url() { [[ -z "$1" || "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *..* ]]; }

# validate_key KEY VALUE -> 0 if valid
validate_key() {
    local k=$1 v=$2
    case "$k" in
        INSTALL_DIR|WORK_DIR|BACKUP_DIR) valid_abs_path "$v" && safe_path "$v" ;;
        BACKUP_KEEP)                     valid_uint "$v" ;;
        REPO_URL)                        valid_repo_url "$v" ;;
        REWRITE_MESSAGES)                in_list "$v" yes no ;;
        IMAGE_NAME)                      valid_name "$v" ;;
        BASE_IMAGE)                      valid_image "$v" ;;
        FILTER_REPO_VERSION)             valid_pyver "$v" ;;
        BUILD_NETWORK)                   in_list "$v" default host ;;
        TIMEZONE)                        valid_tz "$v" ;;
        SERVICE_USER)                    valid_user "$v" ;;
        SERVICE_UID|SERVICE_GID)         valid_id "$v" ;;
        MEM_LIMIT)                       valid_memlimit "$v" ;;
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
        [INSTALL_DIR]="/opt/git-history-scrubber"
        [WORK_DIR]="/opt/git-history-scrubber/work"
        [BACKUP_DIR]="/var/backups/git-history-scrubber"
        [BACKUP_KEEP]="10"
        [REPO_URL]=""
        [REWRITE_MESSAGES]="yes"
        [IMAGE_NAME]="git-history-scrubber"
        [BASE_IMAGE]="$DEFAULT_BASE_IMAGE"
        [FILTER_REPO_VERSION]="$DEFAULT_FILTER_REPO_VERSION"
        [BUILD_NETWORK]="default"
        [TIMEZONE]="$(detect_timezone)"
        [SERVICE_USER]="gitscrub"
        [SERVICE_UID]=""
        [SERVICE_GID]=""
        [MEM_LIMIT]="1g"
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
        printf '# Edit with the menu (Settings) or: %s --set KEY VALUE\n' "$(basename "$GS_INSTALL_BIN")"
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
# SECRETS VAULT (GitHub token)
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
        printf '# git-history-scrubber-secrets v1 backend=%s\n' "$backend"
        case "$backend" in
            systemd-creds) systemd-creds encrypt --name=git-history-scrubber-secrets - - ;;
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
    [[ "$hdr" == "# git-history-scrubber-secrets v1 backend="* ]] || return 1
    backend=${hdr##*backend=}
    case "$backend" in
        systemd-creds) tail -n +2 "$SECRETS_FILE" | systemd-creds decrypt --name=git-history-scrubber-secrets - - ;;
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
                                          --shell /usr/sbin/nologin --comment "git-history-scrubber service account")
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
is_source_dir() { [[ -f "$1/Dockerfile" && -f "$1/app/scrub.py" && -d "$1/app/tests" ]]; }

# Embedded source: the end of this file holds "__GHS_PAYLOAD__ app=X sha256=Y" followed by a
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
        is_source_dir "$SOURCE_OVERRIDE" || die "--source $SOURCE_OVERRIDE has no Dockerfile + app/scrub.py + app/tests/"
        SRC_DIR=$(readlink -f "$SOURCE_OVERRIDE"); SRC_KIND="--source"; return 0
    fi
    if is_source_dir "$SCRIPT_DIR"; then SRC_DIR=$SCRIPT_DIR; SRC_KIND="checkout"; return 0; fi
    if has_payload; then
        PAYLOAD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ghs-src.XXXXXX")
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

app_version_of() { sed -n 's/^__version__ = "\([0-9][0-9.]*\)".*/\1/p' "$1/app/scrub.py" | head -n1; }

sync_source() {
    log_step "Build context"
    local src dst=${CFG[INSTALL_DIR]}/src
    init_source; src=$SRC_DIR
    APP_VERSION=$(app_version_of "$src")
    [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Cannot read __version__ from $src/app/scrub.py"
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
    [[ "$SCRIPT_PATH" == "$GS_INSTALL_BIN" ]] && return 0
    run install -m 0755 "$SCRIPT_PATH" "$GS_INSTALL_BIN"
    run cp -f "$SCRIPT_PATH" "${CFG[INSTALL_DIR]}/src/$(basename "$SCRIPT_PATH")"
    log_ok "Installer available as $GS_INSTALL_BIN"
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


# set_token  -- prompt (or one line on stdin when piped) for the GitHub token; empty clears it
set_token() {
    ensure_config
    load_secrets
    local t=""
    if is_tty && (( ! ASSUME_YES )); then
        printf '  Fine-grained token: github.com > Settings > Developer settings > Fine-grained tokens,\n'
        printf '  repository access = only the repo(s) to scrub, permission Contents = Read and write.\n'
        read -rsp "  GitHub token (input hidden; Enter on empty = clear the stored token): " t || true; echo
    elif ! is_tty; then
        IFS= read -r t || true
    fi
    if [[ -z "$t" ]]; then
        unset 'SECRETS[GH_TOKEN]'
        log_info "No token stored: public repos can be scanned/rewritten, but push needs a token."
    else
        [[ "$t" =~ ^[A-Za-z0-9_]{20,255}$ ]] || die "That doesn't look like a GitHub token (letters, digits, _ only)."
        SECRETS[GH_TOKEN]=$t
    fi
    (( DRY_RUN )) && { log_info "[dry-run] would save the vault"; return 0; }
    install -d -m 0700 "$GS_CONF_DIR"
    save_secrets
}

have_token() { load_secrets; [[ -n "${SECRETS[GH_TOKEN]:-}" ]]; }

# -----------------------------------------------------------------------------
# RULES ($RULES_FILE, git-filter-repo --replace-text format)
# -----------------------------------------------------------------------------
rules_template() {
    cat <<'EOF'
# git-history-scrubber rules -- one per line, git-filter-repo --replace-text format:
#   find text==>replacement        literal (case-sensitive), e.g.  Jane Doe==>janedoe
#   regex:pattern==>replacement    Python regex, e.g.              regex:\bJ(ane|\.) Doe\b==>janedoe
#   glob:pattern==>replacement     shell glob
#   find text                      no ==> : replaced with ***REMOVED***
# Put the longest/most specific rule first. Lines starting with # and blank lines are ignored.
EOF
}

ensure_rules_file() {
    [[ -f "$RULES_FILE" ]] && return 0
    rules_template | write_file "$RULES_FILE" 600 root:root
}

rule_lines() { [[ -f "$RULES_FILE" ]] && grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$RULES_FILE" || true; }
rule_count() { rule_lines | grep -c . || true; }

# check_rules  -- every rule needs something to find and a single ==>
check_rules() {
    local n=0 line body bad=0
    while IFS= read -r line; do
        n=$((n + 1))
        body=${line%%==>*}
        body=${body#literal:}; body=${body#regex:}; body=${body#glob:}
        if [[ -z "$body" ]]; then log_warn "Rule $n has nothing to find: $line"; bad=1; fi
        [[ "$line" == *"==>"*"==>"* ]] && { log_warn "Rule $n has more than one ==>: $line"; bad=1; }
    done < <(rule_lines)
    (( n > 0 )) || { log_warn "No rules in $RULES_FILE."; return 1; }
    (( bad == 0 ))
}

show_rules() {
    printf '\n  %sRules%s (%s)\n' "$B" "$NC" "$RULES_FILE"
    if (( $(rule_count) == 0 )); then printf '    (none)\n'; return 0; fi
    rule_lines | awk '{printf "    %2d) %s\n", NR, $0}'
}

add_rule() {
    local find repl
    ask find "Text to find (exact, case-sensitive; prefix regex: or glob: for patterns)" ""
    [[ -n "$find" ]] || { log_info "Nothing added."; return 0; }
    [[ "$find" == *"==>"* ]] && die "The find text can't contain ==>."
    ask repl "Replace with (empty = ***REMOVED***)" ""
    ensure_rules_file
    (( DRY_RUN )) && { log_info "[dry-run] would add: $find==>$repl"; return 0; }
    if [[ -n "$repl" ]]; then printf '%s==>%s\n' "$find" "$repl" >>"$RULES_FILE"
    else printf '%s\n' "$find" >>"$RULES_FILE"; fi
    log_ok "Rule added ($(rule_count) total)."
}

delete_rule() {
    local n
    show_rules
    ask n "Rule number to delete (Enter = none)" ""
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    local target; target=$(rule_lines | sed -n "${n}p")
    [[ -n "$target" ]] || die "No rule $n."
    (( DRY_RUN )) && { log_info "[dry-run] would delete: $target"; return 0; }
    local tmp; tmp=$(mktemp "$GS_CONF_DIR/.rules.XXXXXX")
    awk -v t="$target" 'BEGIN{d=0} !d && $0 == t {d=1; next} {print}' "$RULES_FILE" >"$tmp"
    chmod 600 "$tmp"; mv -f "$tmp" "$RULES_FILE"
    log_ok "Deleted rule $n."
}

edit_rules() {
    ensure_rules_file
    local ed=${VISUAL:-${EDITOR:-}}
    [[ -z "$ed" ]] && for ed in nano vim vi; do command -v "$ed" >/dev/null 2>&1 && break; ed=""; done
    [[ -n "$ed" ]] || die "No editor found (set EDITOR, or use add/delete rule)."
    "$ed" "$RULES_FILE"
    chmod 600 "$RULES_FILE"
    check_rules && log_ok "$(rule_count) rule(s)."
}

# -----------------------------------------------------------------------------
# IMAGE + CONTAINER RUNS
# -----------------------------------------------------------------------------
image_ref() { printf '%s:%s' "${CFG[IMAGE_NAME]}" "$(current_app_version)"; }

repo_url() { printf '%s' "${REPO_OVERRIDE:-${CFG[REPO_URL]}}"; }

ensure_dirs() {
    log_step "Folders"
    resolve_ids
    run install -d -m 0755 -o root -g root "${CFG[INSTALL_DIR]}"
    run install -d -m 0700 -o "$PUID" -g "$PGID" "${CFG[WORK_DIR]}" "${CFG[BACKUP_DIR]}"
    local d
    for d in "${CFG[WORK_DIR]}" "${CFG[BACKUP_DIR]}"; do
        if [[ -d "$d" ]] && [[ -n "$(find "$d" ! -uid "$PUID" -print -quit 2>/dev/null)" ]]; then
            run chown -R "$PUID:$PGID" "$d"
            log_info "Re-owned $d to $PUID:$PGID"
        fi
    done
    log_ok "Install ${CFG[INSTALL_DIR]}  work ${CFG[WORK_DIR]}  bundles ${CFG[BACKUP_DIR]} (${PUID}:${PGID}, 0700)"
}

# build_cmd [nocache]  -- prints the docker build argv, one per line
build_cmd() {
    local -a a=(docker build -t "$(image_ref)"
                --build-arg "BASE_IMAGE=${CFG[BASE_IMAGE]}"
                --build-arg "FILTER_REPO_VERSION=${CFG[FILTER_REPO_VERSION]}"
                --build-arg "APP_VERSION=$(current_app_version)"
                --label "com.domain.git-history-scrubber.installer=$SCRIPT_VERSION")
    [[ "${CFG[BUILD_NETWORK]}" != default ]] && a+=(--network "${CFG[BUILD_NETWORK]}")
    [[ "${1:-}" == nocache ]] && a+=(--no-cache --pull)
    a+=("${CFG[INSTALL_DIR]}/src")
    printf '%s\n' "${a[@]}"
}

image_build() {   # image_build [nocache]
    log_step "Build image $(image_ref)"
    local -a cmd; mapfile -t cmd < <(build_cmd "${1:-}")
    run_logged "${cmd[@]}"
    log_ok "Image $(image_ref) built (base ${CFG[BASE_IMAGE]}, git-filter-repo ${CFG[FILTER_REPO_VERSION]})"
}

have_image() { docker image inspect "$(image_ref)" >/dev/null 2>&1; }

# run_cmd SUBCOMMAND [ARGS...]  -- prints the docker run argv, one per line. The token is passed as
# '-e GH_TOKEN' (value from this process's environment), so it never appears in argv or ps output.
run_cmd() {
    resolve_ids
    local -a a=(docker run --rm --name "${PROJECT_NAME}-run"
                --user "$PUID:$PGID" --read-only --tmpfs "/tmp:rw,exec,size=64m"
                --cap-drop ALL --security-opt no-new-privileges:true
                -e "TZ=${CFG[TIMEZONE]}" -e "REPO_URL=$(repo_url)"
                -e "REWRITE_MESSAGES=${CFG[REWRITE_MESSAGES]}" -e "SCRUB_KEEP=${CFG[BACKUP_KEEP]}"
                -v "${CFG[WORK_DIR]}:/work" -v "${CFG[BACKUP_DIR]}:/backup"
                -v "${CFG[WORK_DIR]}/.cfg/replacements.txt:/cfg/replacements.txt:ro")
    [[ -n "${CFG[MEM_LIMIT]}" ]] && a+=(--memory "${CFG[MEM_LIMIT]}")
    have_token_quiet && a+=(-e GH_TOKEN)
    a+=("$(image_ref)" "$@")
    printf '%s\n' "${a[@]}"
}
have_token_quiet() { [[ -n "${SECRETS[GH_TOKEN]:-}" ]]; }

# run_tool SUBCOMMAND [ARGS...]  -- stage the rules for the service account, run the container, clean up
run_tool() {
    ensure_config
    load_secrets
    local url; url=$(repo_url)
    [[ -n "$url" ]] || die "No repository set (menu 2 > 1, or --set REPO_URL https://github.com/OWNER/REPO)."
    valid_repo_url "$url" || die "Invalid repository URL: $url"
    if (( ! DRY_RUN )); then
        have_image || die "Image $(image_ref) not built yet (menu 3 / --apply)."
        resolve_ids
        install -d -m 0700 -o "$PUID" -g "$PGID" "${CFG[WORK_DIR]}/.cfg"
        install -m 0400 -o "$PUID" -g "$PGID" "$RULES_FILE" "${CFG[WORK_DIR]}/.cfg/replacements.txt"
    fi
    local -a cmd; mapfile -t cmd < <(run_cmd "$@")
    local rc=0
    if (( DRY_RUN )); then run "${cmd[@]}"; return 0; fi
    _log_file RUN "${cmd[*]}"
    if have_token_quiet; then
        GH_TOKEN="${SECRETS[GH_TOKEN]}" "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}" || rc=${PIPESTATUS[0]}
    else
        "${cmd[@]}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}" || rc=${PIPESTATUS[0]}
    fi
    rm -f -- "${CFG[WORK_DIR]}/.cfg/replacements.txt"
    return "$rc"
}

# -----------------------------------------------------------------------------
# ACTIONS
# -----------------------------------------------------------------------------
need_rules() { check_rules || die "Add at least one rule first (menu R / --rules)."; }

do_scan()    { log_step "Scan $(repo_url)"; need_rules; run_tool scan; }
do_preview() { log_step "Preview"; run_tool preview "$@"; }
do_backup()  { log_step "Backup bundle of $(repo_url)"; run_tool backup; }

do_rewrite() {
    log_step "Rewrite $(repo_url) (local only; nothing is pushed)"
    need_rules
    run_tool rewrite
    state_set last_rewrite "$(date '+%F %T') $(repo_url)"
    log_info "Review with: preview (menu P / --preview), then push (menu 7 / --push)."
}

do_push() {
    log_step "Push rewritten history to $(repo_url)"
    need_rules
    have_token || die "Push needs a GitHub token with Contents: write (menu 2 > 2 / --token)."
    log_warn "This FORCE-PUSHES rewritten branches and tags to $(repo_url)."
    log_info "Before pushing, the tool re-checks that nobody pushed since the rewrite and writes a bundle of the"
    log_info "original history to ${CFG[BACKUP_DIR]} (restore with menu 9 / --restore)."
    log_info "After it: every other clone must be deleted and re-cloned; open pull requests should be closed first."
    confirm_typed FORCE-PUSH || { log_info "Cancelled."; return 0; }
    run_tool push
    state_set last_push "$(date '+%F %T') $(repo_url)"
}

list_bundles() {
    [[ -d "${CFG[BACKUP_DIR]}" ]] || return 0
    find "${CFG[BACKUP_DIR]}" -maxdepth 1 -type f -name '*.bundle' -printf '%T@ %f\n' | sort -rn | cut -d' ' -f2-
}

do_restore() {
    local b=$1
    [[ -n "$b" ]] || die "Restore needs a bundle name (see --bundles)."
    b=$(basename -- "$b")
    [[ -f "${CFG[BACKUP_DIR]}/$b" ]] || die "No bundle ${CFG[BACKUP_DIR]}/$b"
    have_token || die "Restore needs a GitHub token with Contents: write (--token)."
    log_step "Restore $(repo_url) from $b"
    log_warn "This FORCE-PUSHES the branches and tags in $b back to $(repo_url), replacing what is there now."
    confirm_typed RESTORE || { log_info "Cancelled."; return 0; }
    run_tool restore "$b"
}

do_clean() {
    ensure_config
    log_step "Clean work area"
    safe_path "${CFG[WORK_DIR]}" || die "Refusing to clean ${CFG[WORK_DIR]}"
    log_warn "Deletes the local clones in ${CFG[WORK_DIR]} (bundles in ${CFG[BACKUP_DIR]} are kept)."
    confirm "Delete them?" y || return 0
    run find "${CFG[WORK_DIR]}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    log_ok "Work area cleared."
}

state_get() { cat "$GS_STATE_DIR/$1" 2>/dev/null || true; }
state_set() { (( DRY_RUN )) && return 0; mkdir -p "$GS_STATE_DIR"; printf '%s\n' "$2" >"$GS_STATE_DIR/$1"; }

show_status() {
    log_step "Status"
    ensure_config
    load_secrets
    printf '    %-16s %s\n' "Installer" "v$SCRIPT_VERSION ($SCRIPT_PATH)"
    printf '    %-16s %s\n' "Image" "$(image_ref)  $(docker_up && have_image && echo built || echo 'not built')"
    printf '    %-16s %s\n' "Repository" "$(repo_url || true)"
    printf '    %-16s %s\n' "Rules" "$(rule_count) in $RULES_FILE"
    printf '    %-16s %s\n' "Token" "$(have_token_quiet && echo "stored ($(secrets_file_backend))" || echo 'none (push/restore need one)')"
    printf '    %-16s %s\n' "Messages" "REWRITE_MESSAGES=${CFG[REWRITE_MESSAGES]}"
    printf '    %-16s %s\n' "Last rewrite" "$(state_get last_rewrite)"
    printf '    %-16s %s\n' "Last push" "$(state_get last_push)"
    printf '    %-16s %s\n' "Bundles" "$(list_bundles | grep -c . || true) in ${CFG[BACKUP_DIR]}"
    if docker_up && have_image && [[ -n "$(repo_url)" ]] && [[ -f "$RULES_FILE" ]]; then
        printf '\n'; run_tool status 2>/dev/null | sed 's/^/    /' || true
    fi
    return 0
}

show_runlogs() {
    ls -1t "$GS_LOG_DIR"/installer-*.log 2>/dev/null | head -n 10 | sed 's/^/  /'
    local f; f=$(ls -1t "$GS_LOG_DIR"/installer-*.log 2>/dev/null | sed -n 2p)
    [[ -n "$f" ]] && { printf '\n  %sPrevious run: %s%s\n' "$B" "$f" "$NC"; tail -n 60 "$f" | sed 's/^/  /'; }
    return 0
}

# -----------------------------------------------------------------------------
# APPLY / INSTALL / UNINSTALL
# -----------------------------------------------------------------------------
stack_apply() {   # stack_apply [build|nobuild|nocache]
    local mode=${1:-build}
    preflight
    install_docker
    ensure_service_account
    ensure_dirs
    ensure_rules_file
    sync_source
    install_self
    if [[ "$mode" != nobuild ]] || ! have_image; then
        image_build "$([[ "$mode" == nocache ]] && echo nocache || true)"
    fi
    (( DRY_RUN )) || docker run --rm --entrypoint python3 "$(image_ref)" /app/scrub.py selftest | sed 's/^/  /'
    state_set last_apply "$(date '+%F %T') app v$(current_app_version)"
    log_ok "Ready."
}

full_install() {
    log_step "Install / reconfigure git-history-scrubber"
    ensure_config
    [[ -f "$CONF_FILE" ]] && log_info "Existing settings found; press Enter to keep each value."
    wizard_repo
    save_config
    stack_apply build
    if is_tty && (( ! ASSUME_YES )); then
        load_secrets
        have_token_quiet || ! confirm "Store a GitHub token now (needed to push)?" y || set_token
        (( $(rule_count) > 0 )) || ! confirm "Add a rule now?" y || add_rule
    fi
    log_step "Done"
    log_info "Workflow: S) Scan  ->  W) Rewrite (local)  ->  P) Preview  ->  7) Push (typed FORCE-PUSH)."
    log_info "Manage it later with: sudo $(basename "$GS_INSTALL_BIN")"
}

uninstall_stack() {
    log_step "Uninstall"
    ensure_config
    log_warn "Removes the image, build context (${CFG[INSTALL_DIR]}/src), work area and the host command."
    log_info "Bundles (${CFG[BACKUP_DIR]}), settings, rules and the vault are kept unless you also purge them."
    confirm_typed UNINSTALL || { log_info "Cancelled."; return 0; }
    docker_up && run docker image rm "$(image_ref)" >/dev/null 2>&1 || true
    safe_path "${CFG[INSTALL_DIR]}/src" && run rm -rf -- "${CFG[INSTALL_DIR]}/src"
    safe_path "${CFG[WORK_DIR]}" && run rm -rf -- "${CFG[WORK_DIR]}"
    run rm -f -- "$GS_INSTALL_BIN"
    log_ok "git-history-scrubber removed."
    if confirm "Also purge settings, rules, vault (token) and the backup bundles?" n; then
        log_warn "Purging deletes the only local copies of the original histories. This is permanent."
        if confirm_typed PURGE-DATA; then
            safe_path "${CFG[BACKUP_DIR]}" && run rm -rf -- "${CFG[BACKUP_DIR]}"
            run rm -f -- "$CONF_FILE" "$RULES_FILE" "$SECRETS_FILE" "$KEY_FILE"
            run rmdir --ignore-fail-on-non-empty "${CFG[INSTALL_DIR]}" "$GS_CONF_DIR" 2>/dev/null || true
            run rm -rf -- "$GS_STATE_DIR"
            log_ok "Purged."
        fi
    fi
    if id "${CFG[SERVICE_USER]}" >/dev/null 2>&1 && confirm "Remove service account '${CFG[SERVICE_USER]}'?" n; then
        run userdel "${CFG[SERVICE_USER]}" || true
        getent group "${CFG[SERVICE_USER]}" >/dev/null && run groupdel "${CFG[SERVICE_USER]}" || true
    fi
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

wizard_repo() {
    printf '\n  %sRepository%s\n' "$B" "$NC"
    ask_valid REPO_URL         "Repository URL (https://github.com/OWNER/REPO)"
    ask_valid REWRITE_MESSAGES "Also rewrite commit messages (yes|no)"
}

wizard_paths() {
    printf '\n  %sPaths%s\n' "$B" "$NC"
    ask_valid INSTALL_DIR "Install directory"
    ask_valid WORK_DIR    "Work directory (mirror clones)"
    ask_valid BACKUP_DIR  "Backup bundle directory"
    ask_valid BACKUP_KEEP "Bundles to keep per repository"
}

wizard_container() {
    printf '\n  %sContainer%s\n' "$B" "$NC"
    ask_valid IMAGE_NAME          "Image name"
    ask_valid BASE_IMAGE          "Base image (pin)"
    ask_valid FILTER_REPO_VERSION "git-filter-repo version (pin, 2.47+)"
    ask_valid BUILD_NETWORK       "Build network (default|host)"
    ask_valid MEM_LIMIT           "Memory limit (e.g. 1g, empty = none)"
    ask_valid TIMEZONE            "Timezone"
}

wizard_account() {
    printf '\n  %sService account%s\n' "$B" "$NC"
    ask_valid SERVICE_USER    "Account name"
    ask_valid SERVICE_UID     "UID for a new account (empty = auto)"
    ask_valid SERVICE_GID     "GID for a new account (empty = auto)"
    ask_valid SECRETS_BACKEND "Vault backend (auto|systemd-creds|openssl)"
}

require_installed() {
    ensure_config
    docker_up || die "Docker is not running (menu 1 installs it)."
    have_image || die "Not installed yet (menu 1 / --install)."
}

# -----------------------------------------------------------------------------
# MENUS
# -----------------------------------------------------------------------------
menu_rules() {
    while :; do
        show_rules
        printf '\n   A) Add rule   D) Delete rule   E) Edit file in %s   0) Back\n' "${VISUAL:-${EDITOR:-nano/vi}}"
        local ch; read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            a) menu_action add_rule ;;
            d) menu_action delete_rule ;;
            e) menu_action edit_rules ;;
            0|"") return 0 ;;
        esac
    done
}

menu_settings() {
    ensure_config
    while :; do
        show_config
        printf '\n   1) Repository / messages   2) GitHub token   3) Paths   4) Container (pins, memory)\n'
        printf '   5) Service account / vault  6) Edit one key\n'
        printf '   A) Save + apply   W) Save only   R) Re-encrypt vault   0) Back (discard unsaved)\n'
        local ch k v; read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            1) wizard_repo ;;
            2) menu_action set_token ;;
            3) wizard_paths ;;
            4) wizard_container ;;
            5) wizard_account ;;
            6) read -rp "  Key: " k || true; [[ -n "$k" ]] && { ask v "$k" "${CFG[$k]:-}"; ( set_conf_value "$k" "$v" ) && CFG[$k]=$v; } ;;
            w) save_config ;;
            a) save_config; menu_action stack_apply build; return 0 ;;
            r) save_config; menu_action secrets_rekey ;;
            0|"") CONFIG_LOADED=0; load_config; return 0 ;;
        esac
    done
}

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
    local inst="${Y}not installed${NC}" mode tok="none"
    docker_up && have_image && inst="${G}installed${NC}"
    load_secrets 2>/dev/null || true
    have_token_quiet && tok="stored"
    (( DRY_RUN )) && mode="${Y}DRY-RUN${NC}" || mode="${G}LIVE${NC}"
    printf '\n  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  %s|%s  %sGit History Scrubber%s  v%-8s host: %-20s%s|%s\n' "$C" "$NC" "$B" "$NC" "$SCRIPT_VERSION" "$(hostname -s | cut -c1-20)" "$C" "$NC"
    printf '  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  State: %b   Rules: %s   Token: %s   Mode: %b\n' "$inst" "$(rule_count)" "$tok" "$mode"
    printf '  Repo:  %s\n' "${CFG[REPO_URL]:-(not set)}"
}

main_menu() {
    while :; do
        show_banner
        printf '\n  %sSetup%s\n' "$B" "$NC"
        printf '   1) Full install / reconfigure\n   2) Settings (repository, token, paths, container)\n'
        printf '   R) Rules (what to find, what to replace it with)\n'
        printf '  %sScrub%s\n' "$B" "$NC"
        printf '   S) Scan        (report every match in all history; changes nothing)\n'
        printf '   W) Rewrite     (rewrite a local copy and verify; changes nothing on GitHub)\n'
        printf '   P) Preview     (diff of the files that change)\n'
        printf '   7) Push        (bundle backup, then FORCE-PUSH the rewrite)\n'
        printf '  %sMaintenance%s\n' "$B" "$NC"
        printf '   B) Backup bundle now   9) Restore from bundle...   C) Clean work area\n'
        printf '   3) Apply (rebuild if needed)   4) Rebuild image (no cache)\n'
        printf '   8) Status   L) Run logs   U) Uninstall...   T) Toggle dry-run   X) Self-test   0) Quit\n\n'
        local ch f; read -rp "  Choice: " ch || exit 0
        case "${ch,,}" in
            1) menu_action full_install ;;
            2) menu_settings ;;
            r) menu_rules; continue ;;
            s) menu_action do_scan ;;
            w) menu_action do_rewrite ;;
            p) menu_action do_preview ;;
            7) menu_action do_push ;;
            b) menu_action do_backup ;;
            9) list_bundles | head -n 8 | sed 's/^/    /'
               ask f "Bundle to restore" "$(list_bundles | head -n1)"
               [[ -n "$f" ]] && menu_action do_restore "$f" ;;
            c) menu_action do_clean ;;
            3) menu_action stack_apply build ;;
            4) menu_action stack_apply nocache ;;
            8) menu_action show_status ;;
            l) show_runlogs ;;
            u) menu_action uninstall_stack ;;
            t) DRY_RUN=$(( 1 - DRY_RUN )); log_info "Dry-run is now $( ((DRY_RUN)) && echo ON || echo OFF)"; continue ;;
            x) menu_action self_test; docker_up && have_image && menu_action app_self_test ;;
            0|q) printf '\n  %sGoodbye!%s\n\n' "$G" "$NC"; _log_file INFO "Session ended"; exit 0 ;;
            *) printf '  %sInvalid choice%s\n' "$R" "$NC"; sleep 1; continue ;;
        esac
        SECRETS_LOADED=0
        pause
    done
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

    st "bash syntax"                        'bash -n "$SCRIPT_PATH"'
    st "version is semver"                  '[[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
    st "conf quote round-trip"              "[[ \"\$(conf_unquote \"\$(conf_quote \"it's \\\$x\")\")\" == \"it's \\\$x\" ]]"
    st "every CONF_KEY has a default"       'for k in "${CONF_KEYS[@]}"; do [[ -v "CFG[$k]" ]] || exit 1; done'
    st "every CONF_KEY has help text"       'for k in "${CONF_KEYS[@]}"; do [[ -n "${CONF_HELP[$k]:-}" ]] || exit 1; done'
    st "defaults all validate"              'for k in "${CONF_KEYS[@]}"; do validate_key "$k" "${CFG[$k]}" || exit 1; done'
    st "repo URL: https ok"                 'valid_repo_url https://github.com/netgeek1/scripts && valid_repo_url https://github.com/a/b.git'
    st "repo URL: rejects creds/ssh/http"   '! valid_repo_url https://u:t@github.com/a/b && ! valid_repo_url git@github.com:a/b && ! valid_repo_url http://github.com/a/b && ! valid_repo_url "https://github.com/a/b c"'
    st "safe_path refuses /, /opt, /home/x" '! safe_path / && ! safe_path /opt && ! safe_path /home/username && safe_path /opt/git-history-scrubber/work'
    st "abs path rejects spaces / \$"       '! valid_abs_path "/opt/a b" && ! valid_abs_path "/opt/\$x" && valid_abs_path /opt/x'
    st "image pin accepts digest"           "valid_image python:3.13-slim-bookworm && valid_image \"python:3.13@sha256:$(printf 'a%.0s' {1..64})\""
    st "rules: comments ignored, count"     "RULES_FILE=$t/r1; { rules_template; echo 'A B==>c'; echo; echo 'regex:x+'; } >$t/r1; [[ \$(rule_count) == 2 ]] && check_rules"
    st "rules: empty find rejected"         "RULES_FILE=$t/r2; printf '==>x\n' >$t/r2; ! check_rules"
    st "rules: double ==> rejected"         "RULES_FILE=$t/r3; printf 'a==>b==>c\n' >$t/r3; ! check_rules"
    st "rules: template alone = no rules"   "RULES_FILE=$t/r4; rules_template >$t/r4; [[ \$(rule_count) == 0 ]] && ! check_rules"
    st "run cmd hardened"                   'c=$(run_cmd scan); grep -qx -- --read-only <<<"$c" && grep -qx -- "--cap-drop" <<<"$c" && grep -q no-new-privileges <<<"$c"'
    st "run cmd never contains the token"   'SECRETS[GH_TOKEN]=ghp_SECRET123456789012345; c=$(run_cmd push); grep -qx -- GH_TOKEN <<<"$c" && ! grep -q ghp_SECRET <<<"$c"'
    st "run cmd: no token, no -e GH_TOKEN"  'SECRETS=(); c=$(run_cmd scan); ! grep -qx -- GH_TOKEN <<<"$c"'
    st "run cmd: --repo override"           'REPO_OVERRIDE=https://github.com/x/y; c=$(run_cmd scan); grep -qx -- "REPO_URL=https://github.com/x/y" <<<"$c"'
    st "build cmd pins base + filter-repo"  'c=$(build_cmd); grep -qx -- "BASE_IMAGE=${CFG[BASE_IMAGE]}" <<<"$c" && grep -qx -- "FILTER_REPO_VERSION=${CFG[FILTER_REPO_VERSION]}" <<<"$c"'
    st "build cmd nocache pulls"            'c=$(build_cmd nocache); grep -qx -- --no-cache <<<"$c" && grep -qx -- --pull <<<"$c"'
    st "openssl present"                    'command -v openssl'
    st "openssl vault round-trip"           "KEY_FILE=$t/k SECRETS_FILE=$t/s; printf 'GH_TOKEN=eA==\n' | secrets_encrypt_to openssl $t/s && [[ \"\$(secrets_decrypt)\" == 'GH_TOKEN=eA==' ]]"
    st "push/restore are keyword-gated"     'CONFIRM_KEYWORD=nope; ! confirm_typed FORCE-PUSH && ! confirm_typed RESTORE'
    if has_payload; then
        st "embedded payload checksum"      "extract_payload $t/src"
        st "embedded app version = header"  "[[ \"\$(app_version_of $t/src)\" == \"\$(payload_field app)\" ]]"
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
    docker run --rm --read-only --tmpfs "/tmp:rw,exec,size=64m" --user 10001:10001 -e HOME=/tmp -e TMPDIR=/tmp \
        --entrypoint python3 "$(image_ref)" -m unittest discover -s /app/tests -v
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION -- replace text in a GitHub repository's entire history (git-filter-repo, Docker)

Usage: sudo $(basename "$SCRIPT_PATH") [options] [action]

Actions (default: interactive menu)
  --install              Full install / reconfigure (repo, prerequisites, Docker, account, build, token, rules)
  --apply | --rebuild    Re-sync and build the image if missing / rebuild without cache (re-pulls the base image)
  --rules                Show the rules        --add-rule        Add one (prompts)       --edit-rules  Open in \$EDITOR
  --token                Store the GitHub token in the vault (prompt; reads one line from stdin when piped; empty clears)
  --scan                 Report every match in all branches, tags and commit messages (changes nothing)
  --rewrite              Rewrite a local mirror and verify 0 matches remain (changes nothing on GitHub)
  --preview [--all]      Diff of the files that change at the tip of the default branch (or every branch)
  --push                 Bundle backup of the original, then FORCE-PUSH branches + tags (keyword FORCE-PUSH)
  --backup               Bundle backup of the repository now
  --bundles              List backup bundles   --restore BUNDLE   Force-push a bundle back (keyword RESTORE)
  --clean                Delete the local clones in WORK_DIR
  --status | --show-config | --set KEY VALUE | --logs (installer run logs)
  --uninstall            Remove image/build files (keyword UNINSTALL; bundles, rules, vault kept unless purged)
  --self-test            Installer tests (no root)     --app-self-test   App tests inside the image
  --build-standalone OUT Write a self-contained installer (this script + app source) to OUT
  --version | -h, --help

Options
  --repo URL             Use this repository for this run only (REPO_URL setting unchanged)
  --dry-run              Show what would change; change nothing
  --yes                  Accept defaults for all prompts (non-interactive)
  --source DIR           Source checkout to build from (default: next to this script)
  --confirm KEYWORD      Pre-answer a typed confirmation (FORCE-PUSH, RESTORE, UNINSTALL, PURGE-DATA)

Example: remove a name from all history of netgeek1/scripts
  sudo $(basename "$GS_INSTALL_BIN") --set REPO_URL https://github.com/netgeek1/scripts
  printf 'Old Name==>netgeek1\n' | sudo tee -a $RULES_FILE >/dev/null
  sudo $(basename "$GS_INSTALL_BIN") --scan && sudo $(basename "$GS_INSTALL_BIN") --rewrite && sudo $(basename "$GS_INSTALL_BIN") --preview
  sudo $(basename "$GS_INSTALL_BIN") --push

Files
  $CONF_FILE   settings (0600)
  $RULES_FILE       rules (0600)
  $SECRETS_FILE            encrypted vault (GitHub token)
  <BACKUP_DIR>/*.bundle                        original histories (git clone --mirror FILE.bundle to inspect)
  $GS_LOG_DIR/installer-*.log   run logs (newest $LOG_KEEP kept)
EOF
}

check_root() {
    [[ $EUID -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "Run as root (sudo not found)."
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

acquire_lock() {
    exec 9>"$GS_LOCK_FILE"
    flock -n 9 || die "Another $SCRIPT_NAME run is in progress ($GS_LOCK_FILE)."
}

main() {
    local action="menu" arg1=""; local -a set_kv=() orig=("$@") pv=()
    while (( $# )); do
        case "$1" in
            --install)       action=install ;;
            --apply)         action=apply ;;
            --rebuild)       action=rebuild ;;
            --rules)         action=rules ;;
            --add-rule)      action=addrule ;;
            --edit-rules)    action=editrules ;;
            --token)         action=token ;;
            --scan)          action=scan ;;
            --rewrite)       action=rewrite ;;
            --preview)       action=preview; [[ "${2:-}" == --all ]] && { pv=(--all); shift; } ;;
            --push)          action=push ;;
            --backup)        action=backup ;;
            --bundles)       action=bundles ;;
            --restore)       action=restore; arg1=${2:-}; [[ -n "$arg1" ]] || die "--restore needs BUNDLE"; shift ;;
            --clean)         action=clean ;;
            --status)        action=status ;;
            --show-config)   action=showconfig ;;
            --set)           action="set"; (( $# >= 3 )) || die "--set needs KEY VALUE"; set_kv=("$2" "$3"); shift 2 ;;
            --logs)          action=logs ;;
            --uninstall)     action=uninstall ;;
            --self-test)     action=selftest ;;
            --build-standalone) action=standalone; arg1=${2:-}; [[ -n "$arg1" ]] || die "--build-standalone needs OUT"; shift ;;
            --app-self-test) action=appselftest ;;
            --repo)          REPO_OVERRIDE=${2:-}; valid_repo_url "$REPO_OVERRIDE" && [[ -n "$REPO_OVERRIDE" ]] || die "--repo needs https://github.com/OWNER/REPO"; shift ;;
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

    check_root "${orig[@]}"
    init_logging
    acquire_lock
    _log_file INFO "================================================"
    _log_file INFO "$SCRIPT_NAME v$SCRIPT_VERSION started action=$action dry_run=$DRY_RUN repo=$(repo_url 2>/dev/null || true)"
    _log_file INFO "User: $(id -un) (real: $REAL_USER)  PID: $$"
    _log_file INFO "================================================"
    load_config

    case "$action" in
        menu)        is_tty || die "No terminal; use a CLI action (see --help)."; main_menu ;;
        install)     full_install ;;
        apply)       stack_apply build ;;
        rebuild)     stack_apply nocache ;;
        rules)       show_rules ;;
        addrule)     add_rule ;;
        editrules)   edit_rules ;;
        token)       set_token ;;
        scan)        require_installed; do_scan ;;
        rewrite)     require_installed; do_rewrite ;;
        preview)     require_installed; do_preview "${pv[@]}" ;;
        push)        require_installed; do_push ;;
        backup)      require_installed; do_backup ;;
        bundles)     list_bundles ;;
        restore)     require_installed; do_restore "$arg1" ;;
        clean)       do_clean ;;
        status)      show_status ;;
        showconfig)  show_config ;;
        set)         set_conf_value "${set_kv[0]}" "${set_kv[1]}"; save_config ;;
        logs)        show_runlogs ;;
        uninstall)   uninstall_stack ;;
        appselftest) require_installed; app_self_test ;;
    esac
    _log_file INFO "Finished action=$action"
}

main "$@"
exit $?
: <<'__GHS_PAYLOAD_END__'
__GHS_PAYLOAD__ app=1.0.1 sha256=b4572f59c6cccff59b0835aec6d548a09e467e2966342e7762e8b670c4af22e8
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
Mlg9hcGeb8/AIrOlySzZgYWgFd4q5rzwN09QHgq+5jDckhwz9cBXAf6DKlo65xswzka2fbDEFDDG
xCUTbolJDgL30f37n/Gjvft/0TG2yP/7ey+ep+T/5y8e5f9f53PSaMeKqUNiLecsweT7BRb0trnQ
xq5yQLKw6fduSc7gEtJIIOkzIicMMofTEFvAb7VfoAp6JhreY6bWMRm+w2C4uPHmYpsnJj7oj5Bn
HvzSEqy6LnLIxC/P4nNLt0AULQ0y8L2xo5ks81NkbQQqnI/6gsJiZs38zLKJjMAoENsROtQp0cUS
zxOuS0SF8V+fl8WOcEhQCYZsPuotwU+H7B2HfWU+axf8jz8eO9QD5CRN3szstCd3gL0BjyZbxKL6
zbUWBqKVjEJnuJzrBPVYLsnzAY8IA41hOkTJgaUhtcpIuH7xzfV6hOV5LXLahMhZhmTiDckpPlX9
U3jtSaZ42TDt6GgtZ47hISGDuVZgF1nTklomcbftN3XVOnvdfldr1lWjpc6bZ28bR/Ujlau16Huu
pN412m/OLtqK3mjWTtvfqbPXqnb6nfpT4/SopOp/QXHMljprOo2T8+NGnZ41Tg+PL44ap9+qV9QO
BfPYgEKdts8UBtRdNeotdHZSb0Lt2a69ahw32t+VnNeN9in6JFlH1dR5rdluHF4c15rq/KJ5ftaq
0/BH1O1p4/R1k0apn9RP2yRlntIzVX+LQp3Eyh0fYyindkGzb2J+6vDs/Ltm49s3bfXm7PioTg9f
1WlmtVfHdRmKFnV4XGuclNRR7YRrJdLTM+ql6eA1mZ1696aORxivRv87bDfOTrGMw7PTdpO+lmiV
zXbU9F2jVS+pWrPRwoa8bp6dlBxsJ7U4406o3WldesFWq8SJ0Cv4ftGqRx2qo3rtmPpqoTGWaF5+
JPmPn8fP4+fx8/h5/Dx+Hj+Pn8fP4+fx8/h5/PxzfP4XmHpOIQDIAAA=
__GHS_PAYLOAD_END__
