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
__GHS_PAYLOAD__ app=1.0.0 sha256=3886660ef5286d2800e502c4ecb150536b14abb62ee5b2b0b54f821b024f19c6
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
fB4+D5+Hz8Pn4fPw+af//B/skbIKAMgAAA==
__GHS_PAYLOAD_END__
