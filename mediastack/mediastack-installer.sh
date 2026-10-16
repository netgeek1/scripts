#!/usr/bin/env bash
# =============================================================================
#  mediastack-installer.sh
#  Installer and lifecycle manager for MediaStack (github.com/geekau/mediastack)
#
#  Version   : SCRIPT_VERSION below is the authoritative version string
#  Changelog : CHANGELOG.md (per-version history)
#  Docs      : README.md
#  Author    : netgeek1 (Claude.ai)
#
#  Usage     : sudo ./mediastack-installer.sh              interactive menu
#              sudo ./mediastack-installer.sh --install    full install / reconfigure
#              sudo ./mediastack-installer.sh --help       all CLI flags
#
#  Requires  : bash 4.4+, Ubuntu or Debian (amd64/arm64), root (re-execs via sudo)
#  License   : see LICENSE in the repository
# =============================================================================
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION="1.1.0"
readonly SCRIPT_NAME="mediastack-installer"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH

# -----------------------------------------------------------------------------
# PATHS (overridable via environment for testing; normal use leaves these alone)
# -----------------------------------------------------------------------------
MS_CONF_DIR="${MS_CONF_DIR:-/etc/mediastack}"
MS_STATE_DIR="${MS_STATE_DIR:-/var/lib/mediastack-installer}"
MS_LOG_DIR="${MS_LOG_DIR:-/var/log/mediastack}"
MS_INSTALL_BIN="${MS_INSTALL_BIN:-/usr/local/sbin/mediastack-installer}"
MS_LOCK_FILE="${MS_LOCK_FILE:-/run/mediastack-installer.lock}"
MS_FSTAB="${MS_FSTAB:-/etc/fstab}"
MS_DROPIN_DIR="${MS_DROPIN_DIR:-/etc/systemd/system/docker.service.d}"

CONF_FILE="$MS_CONF_DIR/mediastack.conf"
SECRETS_FILE="$MS_CONF_DIR/secrets.enc"
KEY_FILE="$MS_CONF_DIR/.secrets.key"
LOG_KEEP=20

readonly PROJECT_NAME="mediastack"
readonly DEFAULT_UPSTREAM_REPO="geekau/mediastack"
# Known-good upstream commit (2026-04-24). Override with --ref or UPSTREAM_REF in the config.
readonly DEFAULT_UPSTREAM_REF="8e908ae60bf4eeb304453b6b260af0f107406a8f"
readonly PG_CONTAINER="postgresql"
readonly AUTHENTIK_CONTAINER="authentik"

# Folder layout. Mirrors upstream restart.sh at the pinned commit. The *_BRACE
# strings are the exact upstream text and are used only for drift detection.
readonly DATA_BRACE='{authentik/{certs,media,templates},bazarr,chromium,crowdsec/data,ddns-updater,filebot,gluetun,grafana,headplane/data,headscale/data,heimdall,homarr/{configs,data,icons},homepage,huntarr,jellyfin,lidarr,logs/{unpackerr,traefik},mylar,plex,portainer,postgresql,prometheus,prowlarr,qbittorrent,radarr,readarr,sabnzbd,seerr,sonarr,tailscale,tdarr/{server,configs,logs},tdarr-node,traefik/letsencrypt,traefik-certs-dumper,unpackerr,valkey,whisparr}'
DATA_SUBDIRS=( authentik/{certs,media,templates} bazarr chromium crowdsec/data ddns-updater filebot
               gluetun grafana headplane/data headscale/data heimdall homarr/{configs,data,icons} homepage
               huntarr jellyfin lidarr logs/{unpackerr,traefik} mylar plex portainer postgresql prometheus
               prowlarr qbittorrent radarr readarr sabnzbd seerr sonarr tailscale tdarr/{server,configs,logs}
               tdarr-node traefik/letsencrypt traefik-certs-dumper unpackerr valkey whisparr )
MEDIA_SUBDIRS=( media/{anime,audio,books,comics,movies,music,photos,tv,xxx}
                usenet/{anime,audio,books,comics,complete,console,incomplete,movies,music,prowlarr,software,tv,xxx}
                torrents/{anime,audio,books,comics,complete,console,incomplete,movies,music,prowlarr,software,tv,xxx}
                watch filebot/{input,output} )

# App config files upstream restart.sh copies from the YAML folder into app data
# (source in FOLDER_FOR_YAML : destination relative to FOLDER_FOR_DATA).
APP_CONFIG_MAP=( "headplane-config.yaml:headplane/config.yaml"
                 "headscale-config.yaml:headscale/config.yaml"
                 "traefik-static.yaml:traefik/traefik.yaml"
                 "traefik-dynamic.yaml:traefik/dynamic.yaml"
                 "traefik-internal.yaml:traefik/internal.yaml"
                 "crowdsec-acquis.yaml:crowdsec/acquis.yaml" )
# Files that carry example.com and get the configured domain substituted.
DOMAIN_FILES=( headscale-config.yaml headplane-config.yaml traefik-dynamic.yaml
               traefik-internal.yaml traefik-static.yaml )
# Upstream helper scripts: kept as *.upstream; replaced by wrappers that call this installer.
UPSTREAM_SCRIPTS=( restart.sh create_guacamole_database.sh secure_authentik_database.sh get-apikeys.sh )

# -----------------------------------------------------------------------------
# CONFIG MODEL (non-secret settings -> $CONF_FILE)
# -----------------------------------------------------------------------------
CONF_KEYS=( FOLDER_FOR_MEDIA FOLDER_FOR_DATA FOLDER_FOR_YAML DOMAIN CLOUDFLARE_DNS_ZONE CLOUDFLARE_EMAIL
            TIMEZONE LOCAL_SUBNET LOCAL_DOCKER_IP SERVICE_USER SERVICE_UID SERVICE_GID ADMIN_DOCKER_GROUP
            VPN_TYPE VPN_SERVICE_PROVIDER SERVER_REGIONS EMAIL_SERVER_HOST EMAIL_SERVER_PORT EMAIL_ADDRESS
            EMAIL_SENDER DISABLED_SERVICES REMOVED_SERVICES UPSTREAM_REPO UPSTREAM_REF UPSTREAM_VARIANT
            EXTRA_PACKAGES CHOWN_MEDIA_RECURSIVE SECRETS_MODE SECRETS_BACKEND
            MEDIA_STORAGE MEDIA_REMOTE MEDIA_SMB_DOMAIN MEDIA_SMB_VERSION MEDIA_NFS_VERSION MEDIA_MOUNT_OPTS
            MEDIA_MOUNT_REQUIRED DATA_STORAGE DATA_REMOTE DATA_NFS_VERSION DATA_MOUNT_OPTS DATA_MOUNT_REQUIRED )
declare -A CFG=()

# .env keys driven from CFG on every apply
ENV_MANAGED=( FOLDER_FOR_MEDIA FOLDER_FOR_DATA TIMEZONE LOCAL_SUBNET LOCAL_DOCKER_IP VPN_TYPE
              VPN_SERVICE_PROVIDER SERVER_REGIONS CLOUDFLARE_EMAIL CLOUDFLARE_DNS_ZONE EMAIL_SERVER_HOST
              EMAIL_SERVER_PORT EMAIL_ADDRESS EMAIL_SENDER )

# -----------------------------------------------------------------------------
# SECRETS MODEL (encrypted -> $SECRETS_FILE)
# -----------------------------------------------------------------------------
SECRET_KEYS=( VPN_USERNAME VPN_PASSWORD PLEX_CLAIM CLOUDFLARE_DNS_API_TOKEN EMAIL_PASSWORD TAILSCALE_AUTHKEY
              WIREGUARD_PRIVATE_KEY WIREGUARD_PRESHARED_KEY POSTGRESQL_PASSWORD AUTHENTIK_SECRET_KEY
              HEADPLANE_COOKIE_SECRET SONARR_API_TOKEN RADARR_API_TOKEN LIDARR_API_TOKEN READARR_API_TOKEN
              WHISPARR_API_TOKEN MYLAR_API_TOKEN MEDIA_SMB_USERNAME MEDIA_SMB_PASSWORD )
# Vault entries that are not .env variables
SECRET_NON_ENV=( HEADPLANE_COOKIE_SECRET MEDIA_SMB_USERNAME MEDIA_SMB_PASSWORD )
SECRET_PROMPTED=( VPN_USERNAME VPN_PASSWORD CLOUDFLARE_DNS_API_TOKEN TAILSCALE_AUTHKEY EMAIL_PASSWORD PLEX_CLAIM )
SECRET_WIREGUARD=( WIREGUARD_PRIVATE_KEY WIREGUARD_PRESHARED_KEY )
SECRET_REQUIRED=( VPN_USERNAME VPN_PASSWORD CLOUDFLARE_DNS_API_TOKEN TAILSCALE_AUTHKEY )   # compose :?err
SECRET_GENERATED=( POSTGRESQL_PASSWORD AUTHENTIK_SECRET_KEY HEADPLANE_COOKIE_SECRET )
readonly SECRET_UNSET="not-set"
declare -A SECRETS=()
SECRETS_LOADED=0
CONFIG_LOADED=0
LEGACY_ENV=""

# -----------------------------------------------------------------------------
# RUNTIME STATE
# -----------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
CONFIRM_KEYWORD=""
REF_OVERRIDE=""
LOG_FILE=""
REAL_USER="${SUDO_USER:-root}"
UPSTREAM_DIR=""
PUID="" PGID=""
FOLDER_FOR_MEDIA="" FOLDER_FOR_DATA="" FOLDER_FOR_YAML=""
DET_IP="" DET_SUBNET="" DET_IFACE=""

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

init_logging() {
    mkdir -p "$MS_LOG_DIR"
    chmod 750 "$MS_LOG_DIR"
    LOG_FILE="$MS_LOG_DIR/installer-$(date +%F_%H-%M-%S).log"
    : >"$LOG_FILE"
    chmod 640 "$LOG_FILE"
    # Rotation: keep the newest $LOG_KEEP run logs
    local old
    while IFS= read -r old; do rm -f -- "$old"; done < <(ls -1t "$MS_LOG_DIR"/installer-*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)))
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
    tmp=$(mktemp "$(dirname "$path")/.ms-tmp.XXXXXX")
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
    [[ -n "$p" && "$p" == /* && "$p" != *..* ]] || return 1
    case "$p" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/var/lib|/var/log)
            return 1 ;;
    esac
    [[ "$p" == /home/* && "$p" != /home/*/* ]] && return 1
    return 0
}

valid_abs_path() { [[ "$1" == /* && "$1" != *..* && "$1" != *" "* ]]; }
valid_domain()   { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
valid_ipv4()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_cidr()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
sed_escape()     { printf '%s' "$1" | sed -e 's/[.[\*^$/&]/\\&/g'; }
gen_hex()        { openssl rand -hex "$1"; }

ip_to_int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
int_to_ip() { local n=$1; echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"; }
cidr_network() {
    local ip=${1%/*} pre=${1#*/} mask
    mask=$(( pre == 0 ? 0 : (0xFFFFFFFF << (32 - pre)) & 0xFFFFFFFF ))
    echo "$(int_to_ip $(( $(ip_to_int "$ip") & mask )))/$pre"
}

detect_network() {
    local r cidr
    r=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1) || true
    DET_IFACE=$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$r")
    DET_IP=$(sed -n 's/.* src \([0-9.]*\).*/\1/p' <<<"$r")
    DET_SUBNET=""
    if [[ -n "$DET_IFACE" && -n "$DET_IP" ]]; then
        cidr=$(ip -4 -o addr show dev "$DET_IFACE" 2>/dev/null \
               | awk -v ip="$DET_IP" '{split($4, a, "/"); if (a[1] == ip) {print $4; exit}}')
        [[ -n "$cidr" ]] && DET_SUBNET=$(cidr_network "$cidr")
    fi
    return 0
}

detect_timezone() {
    local tz=""
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ -z "$tz" && -L /etc/localtime ]] && tz=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
    printf '%s' "${tz:-America/New_York}"
}

have_docker() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
docker_up()   { have_docker && docker info >/dev/null 2>&1; }

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

set_default_config() {
    CFG=(
        [FOLDER_FOR_MEDIA]="/mediastack/media"
        [FOLDER_FOR_DATA]="/mediastack/appdata"
        [FOLDER_FOR_YAML]="/mediastack/compose"
        [DOMAIN]=""
        [CLOUDFLARE_DNS_ZONE]=""
        [CLOUDFLARE_EMAIL]=""
        [TIMEZONE]="$(detect_timezone)"
        [LOCAL_SUBNET]="auto"
        [LOCAL_DOCKER_IP]="auto"
        [SERVICE_USER]="mediastack"
        [SERVICE_UID]=""
        [SERVICE_GID]=""
        [ADMIN_DOCKER_GROUP]="no"
        [VPN_TYPE]="openvpn"
        [VPN_SERVICE_PROVIDER]="custom"
        [SERVER_REGIONS]=""
        [EMAIL_SERVER_HOST]=""
        [EMAIL_SERVER_PORT]="587"
        [EMAIL_ADDRESS]=""
        [EMAIL_SENDER]=""
        [DISABLED_SERVICES]="whisparr"
        [REMOVED_SERVICES]="readarr"
        [UPSTREAM_REPO]="$DEFAULT_UPSTREAM_REPO"
        [UPSTREAM_REF]="$DEFAULT_UPSTREAM_REF"
        [UPSTREAM_VARIANT]="full-download-vpn"
        [EXTRA_PACKAGES]=""
        [CHOWN_MEDIA_RECURSIVE]="no"
        [SECRETS_MODE]="vault"
        [SECRETS_BACKEND]="auto"
        [MEDIA_STORAGE]="local"
        [MEDIA_REMOTE]=""
        [MEDIA_SMB_DOMAIN]=""
        [MEDIA_SMB_VERSION]="auto"
        [MEDIA_NFS_VERSION]="auto"
        [MEDIA_MOUNT_OPTS]=""
        [MEDIA_MOUNT_REQUIRED]="yes"
        [DATA_STORAGE]="local"
        [DATA_REMOTE]=""
        [DATA_NFS_VERSION]="auto"
        [DATA_MOUNT_OPTS]=""
        [DATA_MOUNT_REQUIRED]="yes"
    )
}

load_config() {
    set_default_config
    if [[ -f "$CONF_FILE" ]]; then
        local line k v legacy_excl="" have_disabled=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
            k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
            [[ "$k" == EXCLUDE_SERVICES ]] && legacy_excl=$(conf_unquote "$v")   # v1.0.0 name
            [[ "$k" == DISABLED_SERVICES ]] && have_disabled=1
            in_list "$k" "${CONF_KEYS[@]}" || continue
            CFG[$k]=$(conf_unquote "$v")
        done <"$CONF_FILE"
        if (( ! have_disabled )) && [[ -n "$legacy_excl" ]]; then
            CFG[DISABLED_SERVICES]=$( { list_words "$legacy_excl" | grep -vxF -f <(list_words "${CFG[REMOVED_SERVICES]}") || true; } | xargs)
        fi
    fi
    [[ -n "$REF_OVERRIDE" ]] && CFG[UPSTREAM_REF]=$REF_OVERRIDE
    [[ -z "${CFG[CLOUDFLARE_DNS_ZONE]}" ]] && CFG[CLOUDFLARE_DNS_ZONE]=${CFG[DOMAIN]}
    CONFIG_LOADED=1
    return 0
}

ensure_config() { (( CONFIG_LOADED )) || load_config; }

save_config() {
    local k
    if (( DRY_RUN )); then log_info "[dry-run] would save $CONF_FILE"; return 0; fi
    mkdir -p "$MS_CONF_DIR"; chmod 700 "$MS_CONF_DIR"
    {
        printf '# %s configuration -- written by %s v%s on %s\n' "$PROJECT_NAME" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(date '+%F %T')"
        printf '# Non-secret settings only. Secrets live encrypted in %s.\n' "$SECRETS_FILE"
        for k in "${CONF_KEYS[@]}"; do printf '%s=%s\n' "$k" "$(conf_quote "${CFG[$k]:-}")"; done
    } | write_file "$CONF_FILE" 600 root:root
    log_ok "Configuration saved: $CONF_FILE"
}

# resolve_runtime -- derive working globals from CFG
resolve_runtime() {
    FOLDER_FOR_MEDIA=${CFG[FOLDER_FOR_MEDIA]%/}
    FOLDER_FOR_DATA=${CFG[FOLDER_FOR_DATA]%/}
    FOLDER_FOR_YAML=${CFG[FOLDER_FOR_YAML]%/}
    if id "${CFG[SERVICE_USER]}" >/dev/null 2>&1; then
        PUID=$(id -u "${CFG[SERVICE_USER]}"); PGID=$(id -g "${CFG[SERVICE_USER]}")
    else
        PUID="${CFG[SERVICE_UID]:-?}"; PGID="${CFG[SERVICE_GID]:-?}"
    fi
    detect_network
}

eff_local_ip()     { [[ "${CFG[LOCAL_DOCKER_IP]}" == auto ]] && printf '%s' "$DET_IP"     || printf '%s' "${CFG[LOCAL_DOCKER_IP]}"; }
eff_local_subnet() { [[ "${CFG[LOCAL_SUBNET]}" == auto ]]    && printf '%s' "$DET_SUBNET" || printf '%s' "${CFG[LOCAL_SUBNET]}"; }

require_config() {
    if [[ ! -f "$CONF_FILE" ]] && ! (( DRY_RUN && CONFIG_LOADED )); then
        die "No configuration found ($CONF_FILE). Run the full install (menu 1 / --install) first."
    fi
    ensure_config
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
        printf '# mediastack-secrets v1 backend=%s\n' "$backend"
        case "$backend" in
            systemd-creds) systemd-creds encrypt --name=mediastack-secrets - - ;;
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
    [[ "$hdr" == "# mediastack-secrets v1 backend="* ]] || return 1
    backend=${hdr##*backend=}
    case "$backend" in
        systemd-creds) tail -n +2 "$SECRETS_FILE" | systemd-creds decrypt --name=mediastack-secrets - - ;;
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

secret_is_set() { local v=${SECRETS[$1]:-}; [[ -n "$v" && "$v" != "$SECRET_UNSET" ]]; }

# looks_placeholder KEY VALUE  -- true for upstream sample values
looks_placeholder() {
    local k=$1 v=$2 up=""
    [[ -z "$v" ]] && return 0
    [[ -n "$UPSTREAM_DIR" && -f "$UPSTREAM_DIR/base-working-files/.env" ]] \
        && up=$(env_get "$UPSTREAM_DIR/base-working-files/.env" "$k" || true)
    [[ -n "$up" && "$v" == "$up" ]] && return 0
    [[ "$v" == "$SECRET_UNSET" || "$v" == *1234567890abcdef* || "$v" == *01234567890abcdef* || "$v" == \<*\> \
       || "$v" == "email-password-here" ]] && return 0
    return 1
}

# secrets_import_env FILE -- pull real (non-placeholder) secret values from an existing .env
secrets_import_env() {
    local f=$1 k v n=0
    [[ -f "$f" ]] || return 0
    for k in "${SECRET_KEYS[@]}"; do
        secret_is_set "$k" && continue
        v=$(env_get "$f" "$k" || true)
        if [[ -n "$v" ]] && ! looks_placeholder "$k" "$v"; then
            SECRETS[$k]=$v; n=$((n + 1)); log_info "Imported $k from existing $(basename "$f")"
        fi
    done
    (( n > 0 )) && log_ok "Imported $n secret(s) from $f"
    return 0
}

# secrets_init -- import, generate, and prompt for anything missing; then save
secrets_init() {
    load_secrets
    local k v changed=0
    if [[ -n "$FOLDER_FOR_YAML" && -f "$FOLDER_FOR_YAML/.env" ]]; then
        local before=${#SECRETS[@]}
        secrets_import_env "$FOLDER_FOR_YAML/.env"
        (( ${#SECRETS[@]} != before )) && changed=1
    fi
    if [[ -n "$LEGACY_ENV" && -f "$LEGACY_ENV" && "$LEGACY_ENV" != "$FOLDER_FOR_YAML/.env" ]]; then
        local before2=${#SECRETS[@]}
        secrets_import_env "$LEGACY_ENV"
        (( ${#SECRETS[@]} != before2 )) && changed=1
    fi
    if ! secret_is_set POSTGRESQL_PASSWORD && [[ -f "$FOLDER_FOR_DATA/postgresql/PG_VERSION" ]]; then
        log_warn "An initialised PostgreSQL exists in $FOLDER_FOR_DATA/postgresql but no password was found to import."
        log_warn "A new password will NOT match it. Enter the existing one now (Enter = generate new anyway)."
        ask_secret v "Existing POSTGRESQL_PASSWORD"
        [[ -n "$v" ]] && { SECRETS[POSTGRESQL_PASSWORD]=$v; changed=1; }
    fi
    for k in "${SECRET_GENERATED[@]}"; do
        if ! secret_is_set "$k"; then
            case "$k" in
                POSTGRESQL_PASSWORD)     SECRETS[$k]=$(gen_hex 24) ;;
                AUTHENTIK_SECRET_KEY)    SECRETS[$k]=$(gen_hex 48) ;;
                HEADPLANE_COOKIE_SECRET) SECRETS[$k]=$(gen_hex 16) ;;
            esac
            log_ok "Generated $k (stored once; reused on every run)"; changed=1
        fi
    done
    local -a prompt_keys=("${SECRET_PROMPTED[@]}")
    [[ "${CFG[VPN_TYPE]}" == wireguard ]] && prompt_keys+=("${SECRET_WIREGUARD[@]}")
    for k in "${prompt_keys[@]}"; do
        secret_is_set "$k" && continue
        [[ "$k" == PLEX_CLAIM ]] && log_info "PLEX_CLAIM: get one at https://plex.tv/claim (valid ~4 minutes, first Plex start only)."
        ask_secret v "$k (Enter to skip)"
        if [[ -n "$v" ]]; then SECRETS[$k]=$v; changed=1; fi
    done
    for k in "${SECRET_REQUIRED[@]}"; do
        if ! secret_is_set "$k"; then
            [[ "${SECRETS[$k]:-}" == "$SECRET_UNSET" ]] || changed=1
            SECRETS[$k]=$SECRET_UNSET
            log_warn "$k is not set (placeholder '$SECRET_UNSET' used so compose validates). Set it via the Secrets menu."
        fi
    done
    (( changed )) && save_secrets
    [[ -f "$SECRETS_FILE" ]] || save_secrets
    return 0
}

# -----------------------------------------------------------------------------
# .ENV FILE HELPERS
# -----------------------------------------------------------------------------
env_parse_value() {
    local v=${1%$'\r'}
    if [[ "$v" == \'* ]]; then
        v=${v#\'}; v=${v%%\'*}
    elif [[ "$v" == \"* ]]; then
        v=${v#\"}; v=${v%%\"*}
    else
        v=${v%%[[:space:]]#*}
        v="${v%"${v##*[![:space:]]}"}"
    fi
    printf '%s' "$v"
}

env_get() {   # env_get FILE KEY
    local line
    line=$(grep -m1 -E "^${2}=" "$1" 2>/dev/null) || return 1
    env_parse_value "${line#*=}"
}

env_format_value() {
    local v=$1 re='^[A-Za-z0-9_./:@,+=%-]*$'
    if [[ "$v" =~ $re ]]; then printf '%s' "$v"
    elif [[ "$v" != *"'"* ]]; then printf "'%s'" "$v"
    else return 1
    fi
}

# env_set FILE KEY VALUE  -- replace first KEY= line (dropping duplicates), move any
# inline comment to its own line above, or append if missing.
env_set() {
    local file=$1 key=$2 val=$3 fmt tmp
    fmt=$(env_format_value "$val") || { log_error "Value for $key contains a single quote; not supported in .env (use SECRETS_MODE=vault)."; return 1; }
    if (( DRY_RUN )); then _log_file DRYRUN "env_set $key in $file"; return 0; fi
    tmp=$(mktemp "${file}.XXXXXX")
    MS_K="$key" MS_NV="$key=$fmt" awk '
        BEGIN { k = ENVIRON["MS_K"]; nv = ENVIRON["MS_NV"]; done = 0 }
        index($0, k "=") == 1 {
            if (!done) {
                line = $0; sub(/\r$/, "", line)
                rest = substr(line, length(k) + 2); c = ""
                if (rest !~ /^["\047]/) { i = match(rest, /[ \t]+#/); if (i > 0) c = substr(rest, i) }
                if (c != "") { sub(/^[ \t]+/, "", c); print c }
                print nv; done = 1
            }
            next
        }
        { print }
        END { if (!done) print nv }' "$file" >"$tmp"
    chmod --reference="$file" "$tmp"; chown --reference="$file" "$tmp"
    mv -f "$tmp" "$file"
}

env_keys() { sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1"; }

# -----------------------------------------------------------------------------
# UPSTREAM (pinned, cached, overridable)
# -----------------------------------------------------------------------------
is_full_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

fetch_upstream() {
    local ref=${CFG[UPSTREAM_REF]} repo=${CFG[UPSTREAM_REPO]} variant=${CFG[UPSTREAM_VARIANT]} tmp sum
    if [[ -n "$UPSTREAM_DIR" && -f "$UPSTREAM_DIR/$variant/docker-compose.yaml" ]]; then return 0; fi
    UPSTREAM_DIR="$MS_STATE_DIR/upstream/$ref"
    if is_full_sha "$ref" && [[ -f "$UPSTREAM_DIR/.complete" ]]; then
        log_ok "Upstream $repo@${ref:0:12} (cached)"; return 0
    fi
    is_full_sha "$ref" || log_warn "UPSTREAM_REF '$ref' is not a pinned commit SHA; content can change between runs."
    log_info "Downloading $repo@$ref ..."
    tmp=$(mktemp -d)
    if curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/src.tgz" "https://github.com/$repo/archive/$ref.tar.gz"; then
        sum="sha256 $(sha256sum "$tmp/src.tgz" | awk '{print substr($1, 1, 16)}')..."
        mkdir -p "$tmp/x"
        tar -xzf "$tmp/src.tgz" -C "$tmp/x" --strip-components=1 --no-same-owner --no-same-permissions
    elif command -v git >/dev/null 2>&1; then
        log_warn "Tarball download failed; falling back to git clone"
        git -c advice.detachedHead=false clone --quiet --filter=blob:none --no-checkout \
            "https://github.com/$repo.git" "$tmp/x" \
            && git -C "$tmp/x" -c advice.detachedHead=false checkout --quiet "$ref" \
            || { rm -rf "$tmp"; die "git clone/checkout of $repo@$ref failed"; }
        sum="git $(git -C "$tmp/x" rev-parse HEAD | cut -c1-12)"
        rm -rf "$tmp/x/.git"
    else
        rm -rf "$tmp"; die "Download failed: https://github.com/$repo/archive/$ref.tar.gz (and git not installed)"
    fi
    [[ -f "$tmp/x/$variant/docker-compose.yaml" && -f "$tmp/x/base-working-files/.env" ]] \
        || { rm -rf "$tmp"; die "Upstream $ref has no $variant/docker-compose.yaml or base-working-files/.env"; }
    if (( DRY_RUN )); then
        UPSTREAM_DIR="$tmp/x"; log_info "[dry-run] upstream staged in $UPSTREAM_DIR (not cached)"
    else
        mkdir -p "$MS_STATE_DIR/upstream"; chmod 750 "$MS_STATE_DIR"
        rm -rf "$UPSTREAM_DIR"; mv "$tmp/x" "$UPSTREAM_DIR"; rm -rf "$tmp"
        printf '%s\n' "$sum" >"$UPSTREAM_DIR/.complete"
    fi
    log_ok "Upstream $repo@${ref:0:12} fetched ($sum)"
    check_upstream_drift
}

# Warn when upstream restart.sh's folder layout no longer matches what this script creates.
check_upstream_drift() {
    local rs="$UPSTREAM_DIR/base-working-files/restart.sh" line
    [[ -f "$rs" ]] || { log_warn "Upstream restart.sh missing; folder-layout drift check skipped."; return 0; }
    line=$(grep -m1 -o 'mkdir -p \$FOLDER_FOR_DATA/{.*}' "$rs" | sed 's/^mkdir -p \$FOLDER_FOR_DATA\///') || true
    if [[ "$line" != "$DATA_BRACE" ]]; then
        log_warn "Upstream data-folder layout differs from this installer's list. Review DATA_SUBDIRS:"
        log_warn "  upstream: ${line:-<not found>}"
    fi
    return 0
}

state_get() { cat "$MS_STATE_DIR/$1" 2>/dev/null || true; }
state_set() { (( DRY_RUN )) && return 0; mkdir -p "$MS_STATE_DIR"; printf '%s\n' "$2" >"$MS_STATE_DIR/$1"; }

# -----------------------------------------------------------------------------
# PREFLIGHT / DOCKER ENGINE
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
    [[ -f "$CONF_FILE" ]] && chmod 600 "$CONF_FILE"
    detect_os
    local arch; arch=$(dpkg --print-architecture)
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || die "Unsupported architecture: $arch"
    log_ok "OS: $OS_ID $OS_CODENAME ($arch)"
    local -a need=() c
    for c in curl tar openssl ip awk sed base64 flock sha256sum; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
    if (( ${#need[@]} )); then
        log_warn "Missing tools: ${need[*]} -- installing base packages"
        run_logged apt-get update
        run_logged apt-get install -y ca-certificates curl tar openssl iproute2 gawk sed coreutils util-linux
    fi
    local avail parent=${CFG[FOLDER_FOR_DATA]}
    while [[ ! -d "$parent" ]]; do parent=$(dirname "$parent"); done
    avail=$(df -Pk "$parent" | awk 'NR==2 {print int($4/1024/1024)}')
    (( avail >= 20 )) || log_warn "Only ${avail} GiB free under $parent; images alone need ~15 GiB."
    log_ok "Free space under $parent: ${avail} GiB"
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
    if [[ -n "${CFG[EXTRA_PACKAGES]// /}" ]]; then
        local -a extra; read -ra extra <<<"${CFG[EXTRA_PACKAGES]}"
        local -a missing=() p
        for p in "${extra[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
        (( ${#missing[@]} )) && run_logged apt-get install -y "${missing[@]}"
        log_ok "Extra packages present: ${extra[*]}"
    fi
    (( DRY_RUN )) || docker_up || die "Docker daemon is not running (systemctl status docker)."
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
                                          --shell /usr/sbin/nologin --comment "MediaStack service account")
        [[ -n "$gid" ]] && gargs+=(--gid "$gid")
        [[ -n "$uid" ]] && uargs+=(--uid "$uid")
        getent group "$u" >/dev/null || run groupadd "${gargs[@]}" "$u"
        run useradd "${uargs[@]}" --gid "$u" "$u"
        log_ok "Created system account '$u' (nologin, no home, not in docker group)"
    fi
    if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        log_warn "'$u' is in the docker group (root-equivalent). It does not need to be; consider: gpasswd -d $u docker"
    fi
    if [[ "${CFG[ADMIN_DOCKER_GROUP]}" == yes && "$REAL_USER" != root ]]; then
        if id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
            log_ok "Admin '$REAL_USER' already in docker group"
        else
            run usermod -aG docker "$REAL_USER"
            log_warn "Added '$REAL_USER' to the docker group (root-equivalent). Takes effect at next login."
        fi
    fi
    resolve_runtime
}

# -----------------------------------------------------------------------------
# DEPLOY FILES INTO FOLDER_FOR_YAML
# -----------------------------------------------------------------------------
backup_file() {   # backup_file FILE BACKUPDIR
    [[ -f "$1" ]] || return 0
    run mkdir -p "$2"
    run cp -a "$1" "$2/"
}

replace_in_files() {   # replace_in_files OLD NEW FILE...  (literal, idempotent)
    local raw=$1 to=$2 old new f n=0; old=$(sed_escape "$1"); new=$(sed_escape "$2"); shift 2
    [[ -n "$raw" && "$raw" != "$to" ]] || return 0
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        if grep -qF -- "$raw" "$f" 2>/dev/null; then run sed -i "s/${old}/${new}/g" "$f"; n=$((n + 1)); fi
    done
    (( n )) && _log_file INFO "replaced '$raw' in $n file(s)"
    return 0
}

deploy_files() {
    log_step "Deploying MediaStack files to $FOLDER_FOR_YAML"
    local ref=${CFG[UPSTREAM_REF]} prev upgrade=0 bdir name src dest f
    local domain=${CFG[DOMAIN]} prev_domain
    prev=$(state_get deployed_ref)
    prev_domain=$(state_get deployed_domain)
    [[ -n "$prev" && "$prev" != "$ref" ]] && upgrade=1
    bdir="$FOLDER_FOR_YAML/.backup/$(date +%F_%H-%M-%S)"
    run mkdir -p "$FOLDER_FOR_YAML"
    run chmod 750 "$FOLDER_FOR_YAML"
    (( upgrade )) && log_info "Upstream ref changed ${prev:0:12} -> ${ref:0:12}: refreshing upstream files (backups in $bdir)"

    local -a fresh=()
    # docker-compose.yaml always tracks the pinned ref (local changes belong in an override)
    src="$UPSTREAM_DIR/${CFG[UPSTREAM_VARIANT]}/docker-compose.yaml"; dest="$FOLDER_FOR_YAML/docker-compose.yaml"
    if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
        backup_file "$dest" "$bdir"
        run install -m 640 -o root -g root "$src" "$dest"
        log_ok "docker-compose.yaml (${CFG[UPSTREAM_VARIANT]} @ ${ref:0:12})"
    fi
    for src in "$UPSTREAM_DIR"/base-working-files/*; do
        [[ -f "$src" ]] || continue
        name=$(basename "$src")
        [[ "$name" == README.md ]] && continue
        if in_list "$name" "${UPSTREAM_SCRIPTS[@]}"; then
            dest="$FOLDER_FOR_YAML/$name.upstream"
            run install -m 644 -o root -g root "$src" "$dest"
            continue
        fi
        dest="$FOLDER_FOR_YAML/$name"
        if [[ ! -f "$dest" ]] || (( upgrade )); then
            if [[ -f "$dest" ]] && ! cmp -s "$src" "$dest"; then backup_file "$dest" "$bdir"; fi
            run install -m 640 -o root -g root "$src" "$dest"
            fresh+=("$dest")
        fi
    done
    (( ${#fresh[@]} )) && log_ok "Copied ${#fresh[@]} upstream working file(s)"

    # Placeholder substitution (idempotent, every deploy). Domain/IP changes rewrite old -> new.
    local -a dfiles=() hfiles=()
    local ip prev_ip; ip=$(eff_local_ip); prev_ip=$(state_get deployed_ip)
    for f in "${DOMAIN_FILES[@]}"; do dfiles+=("$FOLDER_FOR_YAML/$f"); done
    for f in "$FOLDER_FOR_YAML"/*.html; do [[ -f "$f" ]] && hfiles+=("$f"); done
    if [[ -n "$prev_domain" && "$prev_domain" != "$domain" ]]; then
        log_info "Domain changed $prev_domain -> $domain: updating config files"
        replace_in_files "$prev_domain" "$domain" "${dfiles[@]}" "${hfiles[@]}"
    fi
    replace_in_files "example.com" "$domain" "${dfiles[@]}"
    replace_in_files "YOUR_DOMAIN_NAME" "$domain" "${hfiles[@]}"
    if [[ -n "$ip" ]]; then
        [[ -n "$prev_ip" && "$prev_ip" != "$ip" ]] && replace_in_files "$prev_ip" "$ip" "${hfiles[@]}"
        replace_in_files "localhost" "$ip" "${hfiles[@]}"
        replace_in_files "127.0.0.1" "$ip" "${hfiles[@]}"
    fi
    log_ok "Domain '$domain' and host IP '${ip:-?}' applied to config/bookmark files"
    # headplane cookie_secret (32 chars) from the vault
    if [[ -f "$FOLDER_FOR_YAML/headplane-config.yaml" ]] && secret_is_set HEADPLANE_COOKIE_SECRET; then
        set_headplane_cookie "$FOLDER_FOR_YAML/headplane-config.yaml"
    fi
    # Keep upstream scripts usable for env-mode users: patch their hard-coded folders.
    local -a up_scripts=("$FOLDER_FOR_YAML/restart.sh.upstream" "$FOLDER_FOR_YAML/get-apikeys.sh.upstream")
    for f in "${up_scripts[@]}"; do
        [[ -f "$f" ]] || continue
        run sed -i -E \
            -e "s#^(export )?FOLDER_FOR_YAMLS=[^ ]*#\1FOLDER_FOR_YAMLS=${FOLDER_FOR_YAML}#" \
            -e "s#^(export )?FOLDER_FOR_MEDIA=[^ ]*#\1FOLDER_FOR_MEDIA=${FOLDER_FOR_MEDIA}#" \
            -e "s#^(export )?FOLDER_FOR_DATA=[^ ]*#\1FOLDER_FOR_DATA=${FOLDER_FOR_DATA}#" \
            -e "s#^(export )?PUID=[0-9]+#\1PUID=${PUID}#" -e "s#^(export )?PGID=[0-9]+#\1PGID=${PGID}#" "$f"
    done
    write_wrappers
    state_set deployed_ref "$ref"
    state_set deployed_domain "$domain"
    state_set deployed_ip "$ip"
}

# set_headplane_cookie FILE -- secret passed via environment, never argv or log
set_headplane_cookie() {
    local f=$1 tmp
    if (( DRY_RUN )); then log_info "[dry-run] would set headplane cookie_secret from vault"; return 0; fi
    tmp=$(mktemp "${f}.XXXXXX")
    MS_V="${SECRETS[HEADPLANE_COOKIE_SECRET]}" awk '
        /^[ \t]*cookie_secret:/ { match($0, /^[ \t]*/); print substr($0, 1, RLENGTH) "cookie_secret: \"" ENVIRON["MS_V"] "\""; next }
        { print }' "$f" >"$tmp"
    if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
    chmod --reference="$f" "$tmp"; chown --reference="$f" "$tmp"; mv -f "$tmp" "$f"
    log_ok "headplane cookie_secret set from vault"
}

write_wrappers() {
    local name action
    for name in restart.sh stop.sh create_guacamole_database.sh secure_authentik_database.sh get-apikeys.sh; do
        case "$name" in
            restart.sh)                   action="--apply" ;;
            stop.sh)                      action="--stop" ;;
            create_guacamole_database.sh) action="--helper guacamole" ;;
            secure_authentik_database.sh) action="--helper authentik-db" ;;
            get-apikeys.sh)               action="--helper apikeys" ;;
        esac
        cat <<EOF | write_file "$FOLDER_FOR_YAML/$name" 750 root:root
#!/usr/bin/env bash
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION -- regenerated on every install/apply.
# Upstream original (if any) is kept alongside as $name.upstream.
if [[ \$EUID -eq 0 ]]; then exec "$MS_INSTALL_BIN" $action "\$@"; fi
exec sudo "$MS_INSTALL_BIN" $action "\$@"
EOF
    done
    log_ok "Wrappers written: restart.sh stop.sh create_guacamole_database.sh secure_authentik_database.sh get-apikeys.sh"
}

install_self() {
    [[ "$SCRIPT_PATH" == "$MS_INSTALL_BIN" ]] && return 0
    run install -D -m 750 -o root -g root "$SCRIPT_PATH" "$MS_INSTALL_BIN"
    log_ok "Installer copied to $MS_INSTALL_BIN"
}

# -----------------------------------------------------------------------------
# .ENV RENDERING
# -----------------------------------------------------------------------------
readonly VAULT_NOTE="# NOTE (mediastack-installer): SECRETS_MODE=vault -- secret values are stored encrypted in /etc/mediastack/secrets.enc and injected at runtime. Blank secret values below are intentional; use the installer (or ./restart.sh wrapper) rather than plain 'docker compose'."

render_env() {
    log_step "Rendering .env"
    local envf="$FOLDER_FOR_YAML/.env" upenv="$UPSTREAM_DIR/base-working-files/.env" k v n=0
    if [[ ! -f "$envf" ]]; then
        if (( DRY_RUN )); then log_info "[dry-run] would create $envf from upstream and set managed keys"; return 0; fi
        install -m 600 -o root -g root "$upenv" "$envf"
        log_ok "Created .env from upstream template"
    fi
    (( DRY_RUN )) || sed -i 's/\r$//' "$envf"
    # Merge keys introduced upstream since this .env was created
    local -a have; mapfile -t have < <(env_keys "$envf")
    while IFS= read -r k; do
        in_list "$k" "${have[@]}" && continue
        v=$(env_get "$upenv" "$k" || true)
        if (( DRY_RUN )); then log_info "[dry-run] would add new upstream key $k"; continue; fi
        printf '\n# added from upstream %s by %s\n' "${CFG[UPSTREAM_REF]:0:12}" "$SCRIPT_NAME" >>"$envf"
        env_set "$envf" "$k" "$v"; n=$((n + 1))
    done < <(env_keys "$upenv")
    (( n )) && log_ok "Added $n new key(s) from upstream"

    for k in "${ENV_MANAGED[@]}"; do
        case "$k" in
            LOCAL_SUBNET)    v=$(eff_local_subnet) ;;
            LOCAL_DOCKER_IP) v=$(eff_local_ip) ;;
            *)               v=${CFG[$k]} ;;
        esac
        env_set "$envf" "$k" "$v"
    done
    env_set "$envf" PUID "$PUID"
    env_set "$envf" PGID "$PGID"

    if [[ "${CFG[SECRETS_MODE]}" == vault ]]; then
        for k in "${SECRET_KEYS[@]}"; do
            in_list "$k" "${SECRET_NON_ENV[@]}" && continue
            env_set "$envf" "$k" ""
        done
        if ! (( DRY_RUN )) && ! grep -qF "$VAULT_NOTE" "$envf"; then
            local tmp; tmp=$(mktemp "${envf}.XXXXXX")
            { printf '%s\n' "$VAULT_NOTE"; cat "$envf"; } >"$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$envf"
        fi
        log_ok ".env written (vault mode: secrets blank, injected at runtime)"
    else
        for k in "${SECRET_KEYS[@]}"; do
            in_list "$k" "${SECRET_NON_ENV[@]}" && continue
            env_set "$envf" "$k" "${SECRETS[$k]:-}"
        done
        if ! (( DRY_RUN )); then
            local tmp; tmp=$(mktemp "${envf}.XXXXXX")
            grep -vF "$VAULT_NOTE" "$envf" >"$tmp" || true; chmod 600 "$tmp"; mv -f "$tmp" "$envf"
        fi
        log_warn ".env written (env mode: secrets in plaintext, file mode 600 root)"
    fi
    run chown root:root "$envf"
    run chmod 600 "$envf"
}

# -----------------------------------------------------------------------------
# SERVICE EXCLUSION (compose profile override; upstream compose stays untouched)
# -----------------------------------------------------------------------------
readonly OVERRIDE_MARKER="# managed-by: mediastack-installer"

list_words() { local -a a; read -ra a <<<"${1//,/ }"; (( ${#a[@]} )) && printf '%s\n' "${a[@]}"; return 0; }
disabled_services() { list_words "${CFG[DISABLED_SERVICES]:-}"; }
removed_services()  { list_words "${CFG[REMOVED_SERVICES]:-}"; }
excluded_services() { { disabled_services; removed_services; } | awk 'NF && !seen[$0]++'; }
is_removed()  { removed_services | grep -qx -- "$1"; }

svc_state() {
    if removed_services | grep -qx -- "$1"; then echo removed
    elif disabled_services | grep -qx -- "$1"; then echo disabled
    else echo on; fi
}

set_svc_state() {   # set_svc_state NAME on|disabled|removed
    local n=$1 st=$2 d r
    d=$( { disabled_services | grep -vx -- "$n" || true; } | xargs)
    r=$( { removed_services  | grep -vx -- "$n" || true; } | xargs)
    case "$st" in disabled) d="$d $n" ;; removed) r="$r $n" ;; esac
    CFG[DISABLED_SERVICES]=$(xargs <<<"$d")
    CFG[REMOVED_SERVICES]=$(xargs <<<"$r")
}

compose_services_list() {   # FILE -> service names under services:
    awk '/^services:/ {s = 1; next}
         /^[^[:space:]#]/ {s = 0}
         s && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {sub(/^  /, ""); sub(/:.*/, ""); print}' "$1"
}

render_override() {   # render_override COMPOSEFILE -> stdout
    local compose=$1 s n=0 body=""
    printf '%s\n' "$OVERRIDE_MARKER"
    printf '# Regenerated on every install/apply. Services in DISABLED_SERVICES / REMOVED_SERVICES are\n'
    printf "# parked in the 'disabled' profile so they are never started.\n"
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        if [[ -f "$compose" ]] && ! grep -qE "^  ${s}:[[:space:]]*$" "$compose"; then
            printf '# %s: not found in docker-compose.yaml, ignored\n' "$s"; continue
        fi
        body+="  ${s}:"$'\n'"    profiles: [\"disabled\"]"$'\n'; n=$((n + 1))
    done < <(excluded_services)
    if (( n )); then printf 'services:\n%s' "$body"; else printf 'services: {}\n'; fi
    return 0
}

write_override() {
    local f="$FOLDER_FOR_YAML/docker-compose.override.yaml" compose="$FOLDER_FOR_YAML/docker-compose.yaml"
    if [[ -f "$f" ]] && ! grep -qF "$OVERRIDE_MARKER" "$f"; then
        log_warn "$f exists and is not managed by this installer; leaving it alone (service exclusions NOT applied)."
        return 0
    fi
    if [[ -z "$(excluded_services)" ]]; then
        [[ -f "$f" ]] && run rm -f "$f"
        log_ok "All services enabled"
        return 0
    fi
    render_override "$compose" | write_file "$f" 640 root:root
    log_ok "Disabled: ${CFG[DISABLED_SERVICES]:-none}   Removed: ${CFG[REMOVED_SERVICES]:-none}"
    local s
    while IFS= read -r s; do
        [[ -n "$s" && -d "$FOLDER_FOR_DATA/$s" ]] && log_info "Removed service '$s' still has data in $FOLDER_FOR_DATA/$s (left in place; delete it if unwanted)"
    done < <(removed_services)
    return 0
}

# -----------------------------------------------------------------------------
# STORAGE: local | smb (CIFS: Windows/NTFS, Samba, macOS, NAS) | nfs | external
#   MEDIA may use any type. DATA may use local, nfs or external (no SMB: PostgreSQL
#   and Traefik need POSIX ownership/modes that CIFS cannot provide).
#   Managed mounts are fstab entries tagged with a marker line, so they mount at boot.
# -----------------------------------------------------------------------------
target_path()  { if [[ $1 == MEDIA ]]; then printf '%s' "$FOLDER_FOR_MEDIA"; else printf '%s' "$FOLDER_FOR_DATA"; fi; }
storage_type() { printf '%s' "${CFG[${1}_STORAGE]:-local}"; }
is_remote()    { [[ "$(storage_type "$1")" =~ ^(smb|nfs)$ ]]; }
fs_type()      { case "$(storage_type "$1")" in smb) echo cifs ;; nfs) echo nfs ;; *) echo none ;; esac; }
fstab_marker() { printf '# mediastack-installer:%s' "$1"; }
CRED_OVERRIDE=""
cred_file()    { if [[ -n "$CRED_OVERRIDE" ]]; then printf '%s' "$CRED_OVERRIDE"; else printf '%s/%s.smbcred' "$MS_CONF_DIR" "${1,,}"; fi; }
is_mounted()   { mountpoint -q "$1" 2>/dev/null; }
mounted_source() { findmnt -n -o SOURCE --mountpoint "$1" 2>/dev/null | head -n1; }
svc_run()      { setpriv --reuid="$PUID" --regid="$PGID" --clear-groups "$@"; }

normalize_remote() {   # normalize_remote TYPE VALUE
    local v=$2
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$1" in
        smb) v=${v//\\//}; [[ "$v" == //* ]] || v="//${v#/}" ;;
    esac
    [[ "$v" == */?* ]] && v=${v%/}
    printf '%s' "$v"
}
valid_remote() {   # valid_remote TYPE VALUE
    case "$1" in
        smb) [[ "$2" =~ ^//[^/[:space:]]+/[^/].*$ ]] ;;
        nfs) [[ "$2" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):/.*$ ]] ;;
        *)   return 1 ;;
    esac
}
fstab_escape() { local s=$1; s=${s//\\/\\134}; s=${s// /\\040}; s=${s//$'\t'/\\011}; printf '%s' "$s"; }

# mount_opts TARGET [fstab|test]
mount_opts() {
    local t=$1 mode=${2:-fstab} v x
    local -a o=()
    case "$(storage_type "$t")" in
        smb)
            if [[ -n "${SECRETS[${t}_SMB_USERNAME]:-}" ]]; then o+=("credentials=$(cred_file "$t")"); else o+=(guest); fi
            o+=("uid=$PUID" "gid=$PGID" file_mode=0775 dir_mode=0775 iocharset=utf8)
            v=${CFG[${t}_SMB_VERSION]:-auto}; [[ "$v" != auto ]] && o+=("vers=$v")
            ;;
        nfs)
            v=${CFG[${t}_NFS_VERSION]:-auto}; [[ "$v" != auto ]] && o+=("vers=$v")
            o+=(hard)
            ;;
    esac
    [[ "$mode" == fstab ]] && o+=(_netdev nofail x-systemd.mount-timeout=30)
    x=${CFG[${t}_MOUNT_OPTS]:-}; [[ -n "$x" ]] && o+=("$x")
    local IFS=,; printf '%s' "${o[*]}"
}

render_fstab_line() {
    printf '%s %s %s %s 0 0' "$(fstab_escape "${CFG[${1}_REMOTE]}")" "$(fstab_escape "$(target_path "$1")")" \
        "$(fs_type "$1")" "$(mount_opts "$1" fstab)"
}

fstab_current()    { awk -v m="$(fstab_marker "$1")" 'f {print; exit} $0 == m {f = 1}' "$MS_FSTAB" 2>/dev/null; }
fstab_mountpoint() { fstab_current "$1" | awk '{print $2}'; }

fstab_set() {   # fstab_set TARGET LINE|""   ("" removes the managed entry)
    local t=$1 line=$2 m tmp
    m=$(fstab_marker "$t")
    if [[ -n "$line" && "$(fstab_current "$t")" == "$line" ]]; then return 0; fi
    if [[ -z "$line" ]] && ! grep -qxF "$m" "$MS_FSTAB" 2>/dev/null; then return 0; fi
    local what=removed; [[ -n "$line" ]] && what=written
    if (( DRY_RUN )); then log_info "[dry-run] $t entry would be $what in $MS_FSTAB"; return 0; fi
    [[ -f "$MS_FSTAB.mediastack.bak" ]] || cp -a "$MS_FSTAB" "$MS_FSTAB.mediastack.bak"
    tmp=$(mktemp "$MS_FSTAB.XXXXXX")
    awk -v m="$m" '$0 == m {skip = 1; next} skip {skip = 0; next} {print}' "$MS_FSTAB" >"$tmp"
    [[ -n "$line" ]] && printf '%s\n%s\n' "$m" "$line" >>"$tmp"
    chmod 644 "$tmp"; mv -f "$tmp" "$MS_FSTAB"
    log_ok "$MS_FSTAB: $t entry $what (backup: $MS_FSTAB.mediastack.bak)"
}

storage_desc() {   # one-line summary for menus/status
    local t=$1 ty; ty=$(storage_type "$t")
    case "$ty" in
        smb|nfs) printf '%s %s' "$ty" "${CFG[${t}_REMOTE]:-<no share set>}" ;;
        *)       printf '%s' "$ty" ;;
    esac
}

ensure_storage_packages() {
    case "$1" in
        smb) command -v mount.cifs >/dev/null 2>&1 || run_logged apt-get install -y cifs-utils ;;
        nfs) command -v mount.nfs  >/dev/null 2>&1 || run_logged apt-get install -y nfs-common ;;
    esac
    return 0
}

write_smb_creds() {
    local t=$1 f; f=$(cred_file "$t")
    if [[ -z "${SECRETS[${t}_SMB_USERNAME]:-}" ]]; then [[ -f "$f" ]] && run rm -f "$f"; return 0; fi
    mkdir -p "$(dirname "$f")"
    {
        printf 'username=%s\npassword=%s\n' "${SECRETS[${t}_SMB_USERNAME]}" "${SECRETS[${t}_SMB_PASSWORD]:-}"
        [[ -n "${CFG[${t}_SMB_DOMAIN]:-}" ]] && printf 'domain=%s\n' "${CFG[${t}_SMB_DOMAIN]}"
        true
    } | write_file "$f" 600 root:root
}

stack_down_if_running() {
    docker_up || return 0
    if docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" | grep -q .; then
        log_info "Stopping the stack so the mount can change"
        run_logged compose_run down --remove-orphans
    fi
}

svc_write_test() {
    svc_run sh -c 'f="$1/.mediastack-write-test.$$"; : >"$f" && rm -f "$f"' _ "$1" 2>/dev/null
}

# storage_release TARGET -- unmount and forget a managed mount
storage_release() {
    local t=$1 mp; mp=$(fstab_mountpoint "$t")
    [[ -n "$mp" ]] || return 0
    if is_mounted "$mp"; then
        stack_down_if_running
        run umount "$mp" || log_warn "umount $mp failed (in use?)"
    fi
    fstab_set "$t" ""
    run chattr -i "$mp" 2>/dev/null || true
    [[ -f "$(cred_file "$t")" ]] && run rm -f "$(cred_file "$t")"
    run systemctl daemon-reload 2>/dev/null || true
    log_ok "$t: managed mount on $mp released"
}

storage_apply_one() {
    local t=$1 path ty line cur old_mp
    path=$(target_path "$t"); ty=$(storage_type "$t")
    case "$ty" in
        local)
            [[ -n "$(fstab_current "$t")" ]] && { log_info "$t storage set to local"; storage_release "$t"; }
            log_ok "$t: local folder $path"
            return 0 ;;
        external)
            [[ -n "$(fstab_current "$t")" ]] && storage_release "$t"
            if ! is_mounted "$path"; then
                (( DRY_RUN )) && { log_warn "[dry-run] $path is not a mountpoint"; return 0; }
                die "$t storage is 'external' but $path is not mounted. Mount it (fstab/autofs/systemd) first."
            fi
            log_ok "$t: external mount at $path ($(mounted_source "$path"))"
            return 0 ;;
        smb|nfs) ;;
        *) die "Unknown ${t}_STORAGE '$ty' (local|smb|nfs|external)" ;;
    esac
    [[ "$t" == DATA && "$ty" == smb ]] && die "SMB is not supported for app data (PostgreSQL/Traefik need POSIX permissions). Use local, nfs or external."
    [[ -n "${CFG[${t}_REMOTE]:-}" ]] || die "${t}_REMOTE is not set (Settings -> storage)."
    ensure_storage_packages "$ty"
    if [[ "$ty" == smb ]]; then write_smb_creds "$t"
    elif [[ -f "$(cred_file "$t")" ]]; then run rm -f "$(cred_file "$t")"; fi
    line=$(render_fstab_line "$t"); cur=$(fstab_current "$t"); old_mp=$(fstab_mountpoint "$t")
    if [[ -n "$cur" && "$cur" != "$line" && -n "$old_mp" ]] && is_mounted "$old_mp"; then
        log_info "$t mount definition changed; remounting"
        stack_down_if_running
        run umount "$old_mp" || die "Cannot unmount $old_mp (in use?)"
        [[ "$old_mp" != "$path" ]] && { run chattr -i "$old_mp" 2>/dev/null || true; }
    fi
    local need_mount=0
    if ! is_mounted "$path"; then
        need_mount=1
        # Guard BEFORE touching fstab: never hide real local files under the share.
        if [[ -d "$path" ]] && [[ -n "$(find "$path" -mindepth 1 -not -type d -print -quit 2>/dev/null)" ]]; then
            log_warn "$path contains files; mounting the share over it would hide them."
            if ! confirm "Mount over the existing local contents anyway (they stay on local disk, hidden)?" n; then
                log_info "To move them onto the share first:"
                log_info "  sudo $MS_INSTALL_BIN --stop"
                log_info "  sudo mkdir -p /mnt/ms-migrate && sudo mount -t $(fs_type "$t") -o <options> '${CFG[${t}_REMOTE]}' /mnt/ms-migrate"
                log_info "  sudo rsync -rltH --info=progress2 '$path/' /mnt/ms-migrate/   (add -og for NFS/no_root_squash)"
                log_info "  sudo umount /mnt/ms-migrate && sudo mv '$path' '$path.local-backup'"
                log_info "  sudo $MS_INSTALL_BIN --apply"
                die "Local files present in $path; fstab not changed."
            fi
        elif [[ -d "$path" ]] && [[ -n "$(ls -A "$path" 2>/dev/null)" ]]; then
            log_info "$path holds only empty folders (local skeleton); removing them before mounting"
            run find "$path" -mindepth 1 -depth -type d -empty -delete
        fi
    fi
    fstab_set "$t" "$line"
    run systemctl daemon-reload 2>/dev/null || true
    if (( need_mount )); then
        run mkdir -p "$path"
        # Empty + immutable mountpoint: if the share is ever missing, apps cannot fill the local disk.
        [[ -z "$(ls -A "$path" 2>/dev/null)" ]] && { run chattr +i "$path" 2>/dev/null || true; }
        run mount "$path" || die "Mounting the $t share failed. Use Settings -> T) Test to diagnose (dmesg shows the kernel reason)."
    fi
    (( DRY_RUN )) && return 0
    is_mounted "$path" || die "$path is not a mountpoint after mount."
    svc_write_test "$path" || die "Service account $PUID:$PGID cannot write to $path. Check share permissions/export options."
    log_ok "$t: $ty ${CFG[${t}_REMOTE]} on $path (writable as $PUID:$PGID)"
}

write_docker_dropin() {
    local f="$MS_DROPIN_DIR/mediastack-mounts.conf" t p
    local -a req=()
    for t in MEDIA DATA; do
        p=$(target_path "$t")
        [[ "$(storage_type "$t")" != local && "${CFG[${t}_MOUNT_REQUIRED]:-yes}" == yes ]] && req+=("$p")
    done
    if (( ${#req[@]} == 0 )); then
        if [[ -f "$f" ]]; then run rm -f "$f"; run systemctl daemon-reload 2>/dev/null || true; fi
        return 0
    fi
    local want; want=$(printf '[Unit]\n# Generated by %s: Docker waits for MediaStack storage at boot.\nRequiresMountsFor=%s\n' "$SCRIPT_NAME" "${req[*]}")
    [[ -f "$f" && "$(cat "$f")" == "$want" ]] && return 0
    run mkdir -p "$MS_DROPIN_DIR"
    printf '%s\n' "$want" | write_file "$f" 644 root:root
    run systemctl daemon-reload 2>/dev/null || true
    log_ok "Docker now waits for: ${req[*]}"
}

ensure_storage() {
    log_step "Storage"
    local t
    for t in MEDIA DATA; do storage_apply_one "$t"; done
    write_docker_dropin
}

# storage_test TARGET -- trial mount in /run, write + hardlink test as the service account
storage_test() {
    local t=$1 ty tmp cred="" opts rc=0
    ensure_config; resolve_runtime; load_secrets
    ty=$(storage_type "$t")
    log_step "Storage test: $t ($ty)"
    case "$ty" in
        local)    log_info "Local folder $(target_path "$t"); nothing to mount."; return 0 ;;
        external) if is_mounted "$(target_path "$t")"; then log_ok "Mounted from $(mounted_source "$(target_path "$t")")"
                  else log_warn "$(target_path "$t") is not mounted"; fi; return 0 ;;
    esac
    [[ "$PUID" =~ ^[0-9]+$ ]] || { log_warn "Service account not created yet; testing as root"; PUID=0; PGID=0; }
    ensure_storage_packages "$ty"
    tmp=$(mktemp -d /run/mediastack-test.XXXXXX)
    if [[ "$ty" == smb && -n "${SECRETS[${t}_SMB_USERNAME]:-}" ]]; then
        cred=$(mktemp /run/mediastack-cred.XXXXXX); chmod 600 "$cred"
        CRED_OVERRIDE=$cred write_smb_creds_to "$t" "$cred"
    fi
    opts=$(CRED_OVERRIDE=$cred mount_opts "$t" test)
    log_info "mount -t $(fs_type "$t") -o $opts ${CFG[${t}_REMOTE]} <tmp>"
    if mount -t "$(fs_type "$t")" -o "$opts" "${CFG[${t}_REMOTE]}" "$tmp"; then
        log_ok "Mounted"
        if svc_run sh -c 'cd "$1" && : >.ms-test-a && ln .ms-test-a .ms-test-b && [ "$(stat -c %h .ms-test-a)" -ge 2 ]; r=$?; rm -f .ms-test-a .ms-test-b; exit $r' _ "$tmp" 2>/dev/null; then
            log_ok "Write + hardlink as $PUID:$PGID: OK (*ARR hardlinks will work)"
        elif svc_write_test "$tmp"; then
            log_warn "Write OK but hardlinks NOT supported: *ARR apps will copy instead of hardlinking"
        else
            log_error "Service account $PUID:$PGID cannot write to the share"; rc=1
        fi
        df -h "$tmp" | sed 's/^/  /'
        umount "$tmp" || true
    else
        log_error "Mount failed. Check server/share name, credentials, protocol version (dmesg | tail)."; rc=1
    fi
    rmdir "$tmp" 2>/dev/null || true
    [[ -n "$cred" ]] && rm -f "$cred"
    return $rc
}
write_smb_creds_to() {   # TARGET FILE (no logging, used by the test)
    {
        printf 'username=%s\npassword=%s\n' "${SECRETS[${1}_SMB_USERNAME]}" "${SECRETS[${1}_SMB_PASSWORD]:-}"
        [[ -n "${CFG[${1}_SMB_DOMAIN]:-}" ]] && printf 'domain=%s\n' "${CFG[${1}_SMB_DOMAIN]}"
        true
    } >"$2"
}

# wipe_path PATH -- delete a folder; if it is a mountpoint, delete only its contents
wipe_path() {
    local p=$1
    safe_path "$p" || die "Refusing to delete unsafe path '$p'"
    [[ -e "$p" ]] || return 0
    if is_mounted "$p"; then run find "$p" -mindepth 1 -delete
    else run chattr -i "$p" 2>/dev/null || true; run rm -rf -- "$p"; fi
}

# -----------------------------------------------------------------------------
# FOLDERS / PERMISSIONS / APP CONFIG FILES (storage-aware)
# -----------------------------------------------------------------------------
make_dirs() {   # make_dirs TARGET DIR...
    local t=$1; shift
    if run mkdir -p "$@" 2>/dev/null; then return 0; fi
    [[ "$(storage_type "$t")" == local ]] && die "Cannot create folders under $(target_path "$t")"
    log_info "mkdir as root refused on $(storage_type "$t") storage (root_squash?); retrying as $PUID:$PGID"
    run svc_run mkdir -p "$@"
}

ensure_folders() {
    log_step "Folders and permissions"
    [[ "$PUID" =~ ^[0-9]+$ ]] || { (( DRY_RUN )) && { log_info "[dry-run] service account not created yet; skipping folders"; return 0; }; die "Service account UID unknown"; }
    local d top dty mty
    dty=$(storage_type DATA); mty=$(storage_type MEDIA)
    local -a ddirs=() mdirs=() rem=()
    mapfile -t rem < <(removed_services)
    for d in "${DATA_SUBDIRS[@]}"; do
        top=${d%%/*}
        (( ${#rem[@]} )) && in_list "$top" "${rem[@]}" && continue
        ddirs+=("$FOLDER_FOR_DATA/$d")
    done
    for d in "${MEDIA_SUBDIRS[@]}"; do mdirs+=("$FOLDER_FOR_MEDIA/$d"); done
    local -a mtop=("$FOLDER_FOR_MEDIA"/{media,usenet,torrents,filebot})
    make_dirs DATA "$FOLDER_FOR_DATA" "${ddirs[@]}"
    make_dirs MEDIA "$FOLDER_FOR_MEDIA" "${mdirs[@]}"

    # --- App data
    if [[ "$dty" == local ]]; then
        run chown -R "$PUID:$PGID" "$FOLDER_FOR_DATA"
        run find "$FOLDER_FOR_DATA" -maxdepth 2 -path "$FOLDER_FOR_DATA/postgresql" -prune -o -type d -exec chmod 2775 {} +
    else
        run chown -R "$PUID:$PGID" "$FOLDER_FOR_DATA" 2>/dev/null \
            || log_warn "Could not chown app data on $dty storage (root_squash?). The export must map writes to $PUID:$PGID."
        run find "$FOLDER_FOR_DATA" -maxdepth 2 -path "$FOLDER_FOR_DATA/postgresql" -prune -o -type d -user "$PUID" -exec chmod 2775 {} + 2>/dev/null || true
    fi
    if [[ -d "$FOLDER_FOR_DATA/seerr" ]] || (( DRY_RUN )); then
        # seerr runs as internal UID 1000 and ignores PUID/PGID (upstream note)
        run chown -R 1000:1000 "$FOLDER_FOR_DATA/seerr" 2>/dev/null \
            || log_warn "seerr needs $FOLDER_FOR_DATA/seerr owned by UID 1000; set that on the storage server."
    fi
    if [[ "$FOLDER_FOR_YAML" == "$FOLDER_FOR_DATA" || "$FOLDER_FOR_YAML" == "$FOLDER_FOR_DATA"/* ]]; then
        log_warn "Compose folder is inside app data (legacy layout); keeping its files root-owned. A separate folder is recommended."
        run find "$FOLDER_FOR_YAML" -maxdepth 1 -type f -exec chown root:root {} + 2>/dev/null || true
        run chmod 600 "$FOLDER_FOR_YAML/.env"
    fi

    # --- Media
    case "$mty" in
        smb)
            log_ok "Media on SMB: owner/modes come from the mount (uid=$PUID gid=$PGID 0775)" ;;
        local)
            local cur; cur=$(stat -c %u "$FOLDER_FOR_MEDIA" 2>/dev/null || echo "$PUID")
            if [[ "${CFG[CHOWN_MEDIA_RECURSIVE]}" == yes ]]; then
                run chown -R "$PUID:$PGID" "$FOLDER_FOR_MEDIA"
            elif [[ "$cur" != "$PUID" ]] && confirm "Media folder is owned by uid $cur, not $PUID. Re-own the whole library now (can take a while)?" n; then
                run chown -R "$PUID:$PGID" "$FOLDER_FOR_MEDIA"
            else
                run chown "$PUID:$PGID" "$FOLDER_FOR_MEDIA" "${mdirs[@]}" "${mtop[@]}"
            fi
            run chmod 2775 "$FOLDER_FOR_MEDIA" "${mdirs[@]}" "${mtop[@]}" ;;
        *)
            if [[ "${CFG[CHOWN_MEDIA_RECURSIVE]}" == yes ]]; then
                run chown -R "$PUID:$PGID" "$FOLDER_FOR_MEDIA" 2>/dev/null || log_warn "Recursive chown refused by $mty storage"
            else
                run chown "$PUID:$PGID" "$FOLDER_FOR_MEDIA" "${mdirs[@]}" "${mtop[@]}" 2>/dev/null \
                    || log_warn "chown refused by $mty storage (root_squash?); folders must be writable by $PUID:$PGID"
            fi
            run chmod 2775 "$FOLDER_FOR_MEDIA" "${mdirs[@]}" "${mtop[@]}" 2>/dev/null || true ;;
    esac
    log_ok "Data: $FOLDER_FOR_DATA ($dty)  Media: $FOLDER_FOR_MEDIA ($mty)  owner $PUID:$PGID"
}

# put_file SRC DST MODE -- as root, or (on squashed NFS) streamed in as the service account
put_file() {
    local src=$1 dst=$2 mode=$3
    run install -m "$mode" -o "$PUID" -g "$PGID" "$src" "$dst" 2>/dev/null && return 0
    (( DRY_RUN )) && return 0
    svc_run sh -c 'cat >"$1" && chmod "$2" "$1"' _ "$dst" "$mode" <"$src"
}

copy_app_configs() {
    local m src dst
    for m in "${APP_CONFIG_MAP[@]}"; do
        src="$FOLDER_FOR_YAML/${m%%:*}"; dst="$FOLDER_FOR_DATA/${m#*:}"
        [[ -f "$src" ]] || { log_warn "Missing $src"; continue; }
        [[ -d "$(dirname "$dst")" ]] || continue     # folder skipped (service removed)
        put_file "$src" "$dst" 664
    done
    local acme="$FOLDER_FOR_DATA/traefik/letsencrypt/acme.json"
    if [[ -d "$(dirname "$acme")" ]]; then
        if [[ ! -f "$acme" ]]; then
            run touch "$acme" 2>/dev/null || { (( DRY_RUN )) || svc_run touch "$acme"; }
        fi
        run chown "$PUID:$PGID" "$acme" 2>/dev/null || true
        run chmod 600 "$acme" 2>/dev/null || { (( DRY_RUN )) || svc_run chmod 600 "$acme"; }
    fi
    log_ok "App config files placed (traefik, headscale, headplane, crowdsec); acme.json 600"
}

# -----------------------------------------------------------------------------
# COMPOSE
# -----------------------------------------------------------------------------
# compose_run ARGS...  -- project-scoped; vault secrets exported only into this subshell
compose_run() {
    (
        cd "$FOLDER_FOR_YAML" || exit 1
        local k
        for k in "${SECRET_KEYS[@]}"; do
            in_list "$k" "${SECRET_NON_ENV[@]}" && continue
            if [[ "${CFG[SECRETS_MODE]}" == vault ]]; then export "$k=${SECRETS[$k]:-}"; fi
        done
        docker compose -p "$PROJECT_NAME" "$@"
    )
}

stop_excluded_containers() {
    local s cid
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        cid=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" \
                            --filter "label=com.docker.compose.service=$s" 2>/dev/null || true)
        if [[ -n "$cid" ]]; then run docker rm -f $cid >/dev/null; log_info "Removed container for excluded service '$s'"; fi
    done < <(excluded_services)
}

verify_services() {   # verify_services TIMEOUT_SECONDS
    local timeout=${1:-180} waited=0 s st
    local -a svcs bad
    local -A state
    mapfile -t svcs < <(compose_run config --services 2>/dev/null)
    while :; do
        bad=(); state=()
        while IFS=$'\t' read -r s st; do [[ -n "$s" ]] && state[$s]=$st; done \
            < <(compose_run ps -a --format '{{.Service}}\t{{.State}}' 2>/dev/null)
        for s in "${svcs[@]}"; do
            [[ "${state[$s]:-missing}" == running ]] || bad+=("$s:${state[$s]:-missing}")
        done
        (( ${#bad[@]} == 0 )) && { log_ok "All ${#svcs[@]} services running"; return 0; }
        (( waited >= timeout )) && break
        sleep 5; waited=$((waited + 5))
    done
    log_warn "${#bad[@]} of ${#svcs[@]} services not running after ${timeout}s: ${bad[*]}"
    log_warn "Check: sudo $MS_INSTALL_BIN --compose logs --tail 100 <service>"
    return 1
}

# stack_apply pull|nopull  -- converge files, .env, folders, then bring the stack up
stack_apply() {
    local mode=${1:-pull}
    require_config; resolve_runtime; load_secrets
    (( DRY_RUN )) || docker_up || die "Docker is not running/installed. Run the full install first."
    ensure_service_account
    fetch_upstream
    deploy_files
    render_env
    write_override
    ensure_storage
    ensure_folders
    copy_app_configs
    log_step "Starting MediaStack ($mode)"
    if (( DRY_RUN )); then
        run compose_run config --quiet
        [[ "$mode" == pull ]] && run compose_run pull
        run compose_run up -d --remove-orphans
        return 0
    fi
    compose_run config --quiet || die "docker compose config failed (missing variables or invalid YAML)."
    log_ok "Compose configuration valid"
    stop_excluded_containers
    if [[ "$mode" == pull ]]; then run_logged compose_run pull; fi
    run_logged compose_run up -d --remove-orphans
    verify_services 180 || true
}

stack_stop() {
    require_config; resolve_runtime; load_secrets
    log_step "Stopping MediaStack (containers removed; data kept)"
    run_logged compose_run down --remove-orphans
    log_ok "Stack stopped"
}

# -----------------------------------------------------------------------------
# STATUS
# -----------------------------------------------------------------------------
show_status() {
    ensure_config; resolve_runtime
    log_step "MediaStack status"
    printf '  %-22s %s\n' "Installer" "v$SCRIPT_VERSION ($SCRIPT_PATH)"
    printf '  %-22s %s\n' "Config" "$( [[ -f "$CONF_FILE" ]] && echo "$CONF_FILE" || echo 'not configured')"
    printf '  %-22s %s\n' "Upstream (config)" "${CFG[UPSTREAM_REPO]}@${CFG[UPSTREAM_REF]:0:12} (${CFG[UPSTREAM_VARIANT]})"
    printf '  %-22s %s\n' "Upstream (deployed)" "$(state_get deployed_ref | cut -c1-12)"
    printf '  %-22s %s\n' "Secrets" "mode=${CFG[SECRETS_MODE]} backend=$( [[ -f "$SECRETS_FILE" ]] && secrets_file_backend || echo none)"
    printf '  %-22s %s\n' "Service account" "${CFG[SERVICE_USER]} ($PUID:$PGID)"
    printf '  %-22s %s\n' "Host IP / subnet" "$(eff_local_ip) / $(eff_local_subnet)  (iface ${DET_IFACE:-?})"
    printf '  %-22s %s\n' "Folders" "yaml=$FOLDER_FOR_YAML data=$FOLDER_FOR_DATA media=$FOLDER_FOR_MEDIA"
    printf '  %-22s %s\n' "Services" "disabled: ${CFG[DISABLED_SERVICES]:-none}  removed: ${CFG[REMOVED_SERVICES]:-none}"
    local t p
    for t in MEDIA DATA; do
        p=$(target_path "$t")
        printf '  %-22s %s' "Storage ($t)" "$(storage_desc "$t")"
        if [[ "$(storage_type "$t")" != local ]]; then
            if is_mounted "$p"; then printf '  %s[mounted]%s %s' "$G" "$NC" "$(df -h --output=used,size "$p" 2>/dev/null | awk 'NR==2 {print $1 " used of " $2}')"
            else printf '  %s[NOT MOUNTED]%s' "$R" "$NC"; fi
        fi
        echo
    done
    if ! docker_up; then log_warn "Docker is not installed or not running."; return 0; fi
    echo
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" \
        --format 'table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}' | sed 's/^/  /'
    local running total
    running=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" | wc -l)
    total=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" | wc -l)
    echo
    printf '  Containers running: %s/%s\n' "$running" "$total"
    if docker ps -q --filter "name=^${PG_CONTAINER}$" | grep -q .; then
        if docker exec "$PG_CONTAINER" pg_isready -q >/dev/null 2>&1; then log_ok "PostgreSQL accepting connections"
        else log_warn "PostgreSQL container up but not ready"; fi
    else
        log_info "PostgreSQL container not running"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# POST-INSTALL HELPERS (native equivalents of the upstream scripts; no secrets echoed)
# -----------------------------------------------------------------------------
helper_prereq() {
    require_config; resolve_runtime; load_secrets
    docker_up || die "Docker is not running."
    [[ -f "$FOLDER_FOR_YAML/.env" ]] || die "$FOLDER_FOR_YAML/.env not found; run install first."
    PG_USER=$(env_get "$FOLDER_FOR_YAML/.env" POSTGRESQL_USERNAME || true)
    AUTH_DB=$(env_get "$FOLDER_FOR_YAML/.env" AUTHENTIK_DATABASE || true)
    GUAC_DB=$(env_get "$FOLDER_FOR_YAML/.env" GUACAMOLE_DATABASE || true)
    [[ -n "$PG_USER" && -n "$AUTH_DB" && -n "$GUAC_DB" ]] || die "POSTGRESQL_USERNAME / AUTHENTIK_DATABASE / GUACAMOLE_DATABASE missing in .env"
}
PG_USER="" AUTH_DB="" GUAC_DB=""

wait_postgres() {
    local t=${1:-180} w=0
    log_info "Waiting for PostgreSQL (up to ${t}s)..."
    until docker exec "$PG_CONTAINER" pg_isready -q -U "$PG_USER" >/dev/null 2>&1; do
        (( w >= t )) && { log_error "PostgreSQL not ready after ${t}s"; return 1; }
        sleep 3; w=$((w + 3))
    done
    log_ok "PostgreSQL ready"
}

pg_sql() {    # pg_sql DB   (SQL on stdin)
    PGPASSWORD="${SECRETS[POSTGRESQL_PASSWORD]}" docker exec -i -e PGPASSWORD "$PG_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -q -U "$PG_USER" -d "$1"
}
pg_query() {  # pg_query DB SQL
    PGPASSWORD="${SECRETS[POSTGRESQL_PASSWORD]}" docker exec -e PGPASSWORD "$PG_CONTAINER" \
        psql -tAq -U "$PG_USER" -d "$1" -c "$2"
}

grant_sql() {  # grant_sql DB -> stdout
    cat <<EOF
GRANT CONNECT ON DATABASE "$1" TO "$PG_USER";
GRANT USAGE ON SCHEMA public TO "$PG_USER";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$PG_USER";
GRANT SELECT, USAGE ON ALL SEQUENCES IN SCHEMA public TO "$PG_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$PG_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "$PG_USER";
EOF
}

helper_authentik_db() {
    helper_prereq
    log_step "Secure Authentik database ($AUTH_DB)"
    wait_postgres || return 1
    [[ "$(pg_query postgres "SELECT 1 FROM pg_database WHERE datname='$AUTH_DB'")" == 1 ]] \
        || die "Database '$AUTH_DB' not found (PostgreSQL creates it on first start)."
    if (( DRY_RUN )); then log_info "[dry-run] would apply grants on $AUTH_DB"; return 0; fi
    grant_sql "$AUTH_DB" | pg_sql "$AUTH_DB"
    log_ok "Permissions applied on '$AUTH_DB'"
}

helper_guacamole_db() {
    helper_prereq
    log_step "Create Guacamole database ($GUAC_DB)"
    wait_postgres || return 1
    if [[ "$(pg_query postgres "SELECT 1 FROM pg_database WHERE datname='$GUAC_DB'")" == 1 ]]; then
        log_ok "Database '$GUAC_DB' already exists; nothing to do"; return 0
    fi
    if (( DRY_RUN )); then log_info "[dry-run] would create $GUAC_DB, grant, and load schema"; return 0; fi
    printf 'CREATE DATABASE "%s";\n' "$GUAC_DB" | pg_sql postgres
    grant_sql "$GUAC_DB" | pg_sql "$GUAC_DB"
    local img
    img=$(docker inspect -f '{{.Config.Image}}' guacamole 2>/dev/null || echo guacamole/guacamole)
    log_info "Loading schema from $img ..."
    docker run --rm "$img" /opt/guacamole/bin/initdb.sh --postgresql | pg_sql "$GUAC_DB"
    docker restart guacamole >/dev/null 2>&1 || true
    log_ok "Guacamole database created and initialised"
    log_warn "Default Guacamole login is guacadmin / guacadmin -- change it immediately."
}

helper_akadmin() {
    helper_prereq
    log_step "Reset Authentik 'akadmin' password"
    is_tty || die "This helper is interactive (needs a terminal)."
    local w=0
    until [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$AUTHENTIK_CONTAINER" 2>/dev/null)" =~ ^(healthy|running)$ ]]; do
        (( w >= 240 )) && die "Authentik container not healthy after 240s"
        sleep 5; w=$((w + 5))
    done
    if (( DRY_RUN )); then log_info "[dry-run] would run: docker exec -it $AUTHENTIK_CONTAINER ak changepassword akadmin"; return 0; fi
    docker exec -it "$AUTHENTIK_CONTAINER" ak changepassword akadmin
    log_ok "akadmin password changed. Log in at https://auth.${CFG[DOMAIN]} or http://$(eff_local_ip):$(env_get "$FOLDER_FOR_YAML/.env" WEBUI_PORT_AUTHENTIK || echo 6080)"
}

helper_apikeys() {
    helper_prereq
    log_step "*ARR API keys"
    local d=$FOLDER_FOR_DATA name file key tok
    local -a rows=( "Bazarr:bazarr/config/config.yaml:"
                    "Lidarr:lidarr/config.xml:LIDARR_API_TOKEN"
                    "Mylar:mylar/mylar/config.ini:MYLAR_API_TOKEN"
                    "Prowlarr:prowlarr/config.xml:"
                    "Radarr:radarr/config.xml:RADARR_API_TOKEN"
                    "Readarr:readarr/config.xml:READARR_API_TOKEN"
                    "Sonarr:sonarr/config.xml:SONARR_API_TOKEN"
                    "Whisparr:whisparr/config.xml:WHISPARR_API_TOKEN" )
    local -A found=()
    local r
    for r in "${rows[@]}"; do
        IFS=: read -r name file tok <<<"$r"
        is_removed "${name,,}" && continue
        key=""
        if [[ -f "$d/$file" ]]; then
            case "$file" in
                *.xml)  key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$d/$file" | head -n1) ;;
                *.yaml) key=$(awk '/^auth:/ {a=1; next} a && /^[^ ]/ {a=0} a && /apikey:/ {print $2; exit}' "$d/$file" | tr -d "'\"") ;;
                *.ini)  key=$(sed -n 's/^api_key[[:space:]]*=[[:space:]]*//p' "$d/$file" | head -n1) ;;
            esac
        fi
        printf '  %-9s %s\n' "$name" "${key:-<not found: $d/$file>}"
        [[ -n "$key" && -n "$tok" ]] && found[$tok]=$key
    done
    (( ${#found[@]} )) || return 0
    if confirm "Store the found keys in the vault (used by unpackerr/homepage via .env tokens)?" y; then
        for tok in "${!found[@]}"; do SECRETS[$tok]=${found[$tok]}; done
        save_secrets
        log_info "Run Apply (menu 4/5) to push the tokens into the containers."
    fi
}

offer_post_install() {
    is_tty || { log_info "Post-install helpers: run '$MS_INSTALL_BIN' and use menu 8."; return 0; }
    log_step "Post-install helpers"
    confirm "Secure the Authentik database now?" y && { helper_authentik_db || log_warn "Authentik DB helper failed"; }
    confirm "Create the Guacamole database now?" y && { helper_guacamole_db || log_warn "Guacamole DB helper failed"; }
    confirm "Set the Authentik 'akadmin' password now?" y && { helper_akadmin || log_warn "akadmin reset failed"; }
    return 0
}

# -----------------------------------------------------------------------------
# DETECTION
# -----------------------------------------------------------------------------
detect_existing_install() {
    local d wd
    if docker_up; then
        wd=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" \
             --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | head -n1 || true)
        if [[ -n "$wd" && -f "$wd/.env" ]]; then printf '%s' "$wd"; return 0; fi
    fi
    for d in "${CFG[FOLDER_FOR_YAML]}" /docker /mediastack/compose /mediastack/appdata /mediastack /opt/mediastack /srv/mediastack; do
        if [[ -f "$d/docker-compose.yaml" && -f "$d/.env" ]] && grep -q "^COMPOSE_PROJECT_NAME=$PROJECT_NAME" "$d/.env"; then
            printf '%s' "$d"; return 0
        fi
    done
    return 0
}

detect_domain() {
    local d; d=$(hostname -d 2>/dev/null || true)
    case "$d" in ""|localdomain|local|lan|home|internal|home.arpa) return 0 ;; esac
    valid_domain "$d" && printf '%s' "$d"
    return 0
}

# detect_storage TARGET -- an existing, foreign mount at the target path becomes 'external'
detect_storage() {
    local t=$1 p; p=${CFG[FOLDER_FOR_$t]}
    [[ -n "$(fstab_current "$t")" ]] && return 0
    if is_mounted "$p"; then
        CFG[${t}_STORAGE]=external
        log_ok "$p is already mounted ($(findmnt -n -o FSTYPE --mountpoint "$p" 2>/dev/null) from $(mounted_source "$p")) -> storage 'external'"
    fi
    return 0
}

detect_defaults() {
    log_step "Detecting defaults"
    detect_network
    log_ok "Network: ${DET_IP:-?} on ${DET_IFACE:-?}, subnet ${DET_SUBNET:-?}"
    log_ok "Timezone: ${CFG[TIMEZONE]}"
    local found k v u
    found=$(detect_existing_install)
    if [[ -n "$found" ]]; then
        log_ok "Existing MediaStack install in $found (its .env provides defaults)"
        CFG[FOLDER_FOR_YAML]=$found
        LEGACY_ENV="$found/.env"
        for k in FOLDER_FOR_MEDIA FOLDER_FOR_DATA TIMEZONE VPN_TYPE VPN_SERVICE_PROVIDER SERVER_REGIONS \
                 CLOUDFLARE_EMAIL CLOUDFLARE_DNS_ZONE EMAIL_SERVER_HOST EMAIL_SERVER_PORT EMAIL_ADDRESS EMAIL_SENDER; do
            v=$(env_get "$LEGACY_ENV" "$k" || true)
            [[ -z "$v" ]] && continue
            looks_placeholder "$k" "$v" && continue
            [[ "$v" == /your-* || "$v" == *example.com || "$v" == "VPN provider name" ]] && continue
            CFG[$k]=$v
        done
        [[ -n "${CFG[CLOUDFLARE_DNS_ZONE]}" ]] && CFG[DOMAIN]=${CFG[CLOUDFLARE_DNS_ZONE]}
        v=$(env_get "$LEGACY_ENV" PUID || true)
        u=""
        [[ "$v" =~ ^[0-9]+$ && "$v" != 0 ]] && u=$(getent passwd "$v" | cut -d: -f1 || true)
        if [[ "$u" == docker ]]; then
            log_info "Existing install runs as user 'docker' (uid $v). Keeping the dedicated '${CFG[SERVICE_USER]}' default; data is re-owned on apply."
        elif [[ -n "$u" ]]; then
            CFG[SERVICE_USER]=$u; log_ok "Service account from existing PUID $v: $u"
        fi
    else
        log_info "No existing MediaStack install found"
    fi
    if [[ -z "${CFG[DOMAIN]}" ]]; then
        v=$(detect_domain)
        if [[ -n "$v" ]]; then CFG[DOMAIN]=$v; log_ok "Domain from host name: $v"; fi
    fi
    [[ -z "${CFG[CLOUDFLARE_DNS_ZONE]}" ]] && CFG[CLOUDFLARE_DNS_ZONE]=${CFG[DOMAIN]}
    detect_storage MEDIA
    detect_storage DATA
    return 0
}

# -----------------------------------------------------------------------------
# SETTINGS SECTIONS (shared by the first-run wizard and the Settings menu)
# -----------------------------------------------------------------------------
SECRETS_DIRTY=0

# ask_valid VAR "Prompt" DEFAULT VALIDATOR "hint"
ask_valid() {
    local __var=$1 __p=$2 __d=$3 __fn=$4 __hint=$5 __v=""
    while :; do
        ask __v "$__p" "$__d"
        if "$__fn" "$__v"; then printf -v "$__var" '%s' "$__v"; return 0; fi
        if (( ASSUME_YES )) || ! is_tty; then die "$__p: '$__v' is not valid ($__hint). Set it in $CONF_FILE or run interactively."; fi
        log_warn "Expected: $__hint"
    done
}
v_any()      { return 0; }
v_path()     { valid_abs_path "$1"; }
v_domain()   { valid_domain "$1"; }
v_ip_auto()  { [[ "$1" == auto ]] || valid_ipv4 "$1"; }
v_cidr_auto(){ [[ "$1" == auto ]] || valid_cidr "$1"; }
v_yesno()    { [[ "$1" =~ ^(yes|no)$ ]]; }
v_num()      { [[ "$1" =~ ^[0-9]+$ ]]; }
v_num_opt()  { [[ -z "$1" || "$1" =~ ^[0-9]+$ ]]; }
v_user()     { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
v_vpn()      { [[ "$1" =~ ^(openvpn|wireguard)$ ]]; }
v_mode()     { [[ "$1" =~ ^(vault|env)$ ]]; }
v_backend()  { [[ "$1" =~ ^(auto|systemd-creds|openssl)$ ]]; }
v_variant()  { [[ "$1" =~ ^(full-download-vpn|mini-download-vpn|no-download-vpn)$ ]]; }
v_mtype()    { [[ "$1" =~ ^(local|smb|nfs|external)$ ]]; }
v_dtype()    { [[ "$1" =~ ^(local|nfs|external)$ ]]; }
v_smbver()   { [[ "$1" =~ ^(auto|1\.0|2\.0|2\.1|3|3\.0|3\.02|3\.1\.1)$ ]]; }
v_nfsver()   { [[ "$1" =~ ^(auto|3|4|4\.0|4\.1|4\.2)$ ]]; }
v_smb_remote() { valid_remote smb "$(normalize_remote smb "$1")"; }
v_nfs_remote() { valid_remote nfs "$(normalize_remote nfs "$1")"; }
section() { printf '\n  %s%s%s\n' "$B" "$1" "$NC"; }

cfg_paths() {
    section "Paths"
    while :; do
        ask_valid "CFG[FOLDER_FOR_MEDIA]" "Media folder (library + downloads; share mountpoint if remote)" "${CFG[FOLDER_FOR_MEDIA]}" v_path "absolute path without spaces"
        ask_valid "CFG[FOLDER_FOR_DATA]"  "App data folder (configs + databases)" "${CFG[FOLDER_FOR_DATA]}" v_path "absolute path without spaces"
        ask_valid "CFG[FOLDER_FOR_YAML]"  "Compose/.env folder" "${CFG[FOLDER_FOR_YAML]}" v_path "absolute path without spaces"
        local k; for k in FOLDER_FOR_MEDIA FOLDER_FOR_DATA FOLDER_FOR_YAML; do CFG[$k]=${CFG[$k]%/}; done
        if [[ "${CFG[FOLDER_FOR_DATA]}" == "${CFG[FOLDER_FOR_MEDIA]}" || "${CFG[FOLDER_FOR_DATA]}" == "${CFG[FOLDER_FOR_MEDIA]}"/* \
              || "${CFG[FOLDER_FOR_MEDIA]}" == "${CFG[FOLDER_FOR_DATA]}"/* ]]; then
            (( ASSUME_YES )) || ! is_tty && die "Media and app-data folders must be separate (neither inside the other)."
            log_warn "Media and app-data folders must be separate (neither inside the other)."; continue
        fi
        break
    done
}

cfg_network() {
    section "Domain and network"
    detect_network
    local old=${CFG[DOMAIN]}
    ask_valid "CFG[DOMAIN]" "Public domain for app hostnames (auth.<domain>, ...)" "${CFG[DOMAIN]}" v_domain "a domain such as example.org"
    [[ -z "${CFG[CLOUDFLARE_DNS_ZONE]}" || "${CFG[CLOUDFLARE_DNS_ZONE]}" == "$old" ]] && CFG[CLOUDFLARE_DNS_ZONE]=${CFG[DOMAIN]}
    ask_valid "CFG[CLOUDFLARE_DNS_ZONE]" "Cloudflare DNS zone" "${CFG[CLOUDFLARE_DNS_ZONE]}" v_domain "a domain"
    ask "CFG[CLOUDFLARE_EMAIL]" "Cloudflare account email" "${CFG[CLOUDFLARE_EMAIL]}"
    log_info "Detected: ${DET_IP:-?} on ${DET_IFACE:-?}, subnet ${DET_SUBNET:-?}  ('auto' re-detects on every apply)"
    ask_valid "CFG[LOCAL_DOCKER_IP]" "Host LAN IP (auto or IPv4)" "${CFG[LOCAL_DOCKER_IP]}" v_ip_auto "auto or a.b.c.d"
    ask_valid "CFG[LOCAL_SUBNET]" "LAN subnet (auto or CIDR)" "${CFG[LOCAL_SUBNET]}" v_cidr_auto "auto or a.b.c.d/nn"
    ask "CFG[TIMEZONE]" "Timezone" "${CFG[TIMEZONE]}"
    [[ -f "/usr/share/zoneinfo/${CFG[TIMEZONE]}" ]] || log_warn "'${CFG[TIMEZONE]}' not found in /usr/share/zoneinfo"
}

cfg_storage() {
    local t=$1 p v ty
    p=${CFG[FOLDER_FOR_$t]}
    if [[ "$t" == MEDIA ]]; then
        section "Media storage  ($p)"
        log_info "local    = folder on this host's disks"
        log_info "smb      = SMB/CIFS share: Windows (NTFS), Samba, macOS, Synology/TrueNAS/QNAP SMB"
        log_info "nfs      = NFS export: Linux, TrueNAS, Synology, QNAP, Unraid"
        log_info "external = you already mount $p yourself (fstab, autofs, systemd); verified on apply"
        ask_valid "CFG[MEDIA_STORAGE]" "Media storage type (local/smb/nfs/external)" "${CFG[MEDIA_STORAGE]}" v_mtype "local, smb, nfs or external"
    else
        section "App-data storage  ($p)"
        log_info "Local disk is strongly recommended: PostgreSQL and the *ARR SQLite databases need reliable"
        log_info "locking. SMB is not offered (no POSIX ownership/modes; PostgreSQL and Traefik refuse to run)."
        ask_valid "CFG[DATA_STORAGE]" "App-data storage type (local/nfs/external)" "${CFG[DATA_STORAGE]}" v_dtype "local, nfs or external"
    fi
    ty=${CFG[${t}_STORAGE]}
    if [[ "$ty" == local ]] && is_mounted "$p" && [[ -z "$(fstab_current "$t")" ]]; then
        log_warn "$p is currently a mountpoint ($(mounted_source "$p")); 'external' is probably what you want."
    fi
    case "$ty" in
        smb)
            ask_valid v "SMB share (//server/share or \\\\server\\share)" "${CFG[${t}_REMOTE]}" v_smb_remote "//server/share"
            CFG[${t}_REMOTE]=$(normalize_remote smb "$v")
            load_secrets
            ask v "SMB username (blank = guest access)" "${SECRETS[${t}_SMB_USERNAME]:-}"
            if [[ "$v" != "${SECRETS[${t}_SMB_USERNAME]:-}" ]]; then SECRETS[${t}_SMB_USERNAME]=$v; SECRETS_DIRTY=1; fi
            if [[ -n "$v" ]]; then
                secret_is_set "${t}_SMB_PASSWORD" && log_info "A password is stored; press Enter to keep it."
                ask_secret v "SMB password"
                if [[ -n "$v" ]]; then SECRETS[${t}_SMB_PASSWORD]=$v; SECRETS_DIRTY=1; fi
                ask "CFG[${t}_SMB_DOMAIN]" "SMB domain / workgroup (blank = none)" "${CFG[${t}_SMB_DOMAIN]}"
            fi
            ask_valid "CFG[${t}_SMB_VERSION]" "SMB protocol (auto, 3.1.1, 3.0, 2.1, 2.0, 1.0)" "${CFG[${t}_SMB_VERSION]}" v_smbver "auto or a version"
            log_info "Windows/NTFS: share permissions must allow the account to modify; hardlinks work on NTFS."
            ;;
        nfs)
            ask_valid v "NFS export (server:/path)" "${CFG[${t}_REMOTE]}" v_nfs_remote "server:/export/path"
            CFG[${t}_REMOTE]=$(normalize_remote nfs "$v")
            ask_valid "CFG[${t}_NFS_VERSION]" "NFS version (auto, 4.2, 4.1, 4, 3)" "${CFG[${t}_NFS_VERSION]}" v_nfsver "auto or a version"
            log_info "With root_squash, the export must let UID/GID $(id -u "${CFG[SERVICE_USER]}" 2>/dev/null || echo "<service>") write (or set a fixed UID in Service account)."
            ;;
        external)
            is_mounted "$p" && log_ok "$p is mounted from $(mounted_source "$p")" \
                            || log_warn "$p is not mounted right now; apply will refuse until it is."
            ;;
    esac
    if [[ "$ty" =~ ^(smb|nfs)$ ]]; then
        ask "CFG[${t}_MOUNT_OPTS]" "Extra mount options (comma list, blank = none)" "${CFG[${t}_MOUNT_OPTS]}"
    fi
    if [[ "$ty" != local ]]; then
        ask_valid "CFG[${t}_MOUNT_REQUIRED]" "Make Docker wait for this mount at boot (yes/no)" "${CFG[${t}_MOUNT_REQUIRED]}" v_yesno "yes or no"
        log_info "Tip: Settings -> T) Test mounts the share temporarily and checks write + hardlink support."
    fi
}

cfg_account() {
    section "Service account"
    log_info "Containers run as this account (PUID/PGID). Best practice: a dedicated nologin system"
    log_info "account that is NOT in the docker group (docker group = root-equivalent)."
    ask_valid "CFG[SERVICE_USER]" "Service account name" "${CFG[SERVICE_USER]}" v_user "lowercase account name"
    if id "${CFG[SERVICE_USER]}" >/dev/null 2>&1; then
        log_ok "'${CFG[SERVICE_USER]}' exists (uid $(id -u "${CFG[SERVICE_USER]}"), gid $(id -g "${CFG[SERVICE_USER]}"))"
    else
        log_info "Fixed IDs matter for NFS: match the export's owner. SMB maps ownership itself. Blank = auto."
        ask_valid "CFG[SERVICE_UID]" "UID (blank = auto)" "${CFG[SERVICE_UID]}" v_num_opt "number or blank"
        ask_valid "CFG[SERVICE_GID]" "GID (blank = auto)" "${CFG[SERVICE_GID]}" v_num_opt "number or blank"
    fi
    ask_valid "CFG[ADMIN_DOCKER_GROUP]" "Add admin '$REAL_USER' to the docker group (yes/no)" "${CFG[ADMIN_DOCKER_GROUP]}" v_yesno "yes or no"
}

compose_for_listing() {
    local f="${CFG[FOLDER_FOR_YAML]}/docker-compose.yaml"
    if [[ -f "$f" ]]; then printf '%s' "$f"; return 0; fi
    f="$MS_STATE_DIR/upstream/${CFG[UPSTREAM_REF]}/${CFG[UPSTREAM_VARIANT]}/docker-compose.yaml"
    if [[ ! -f "$f" ]] && ! (( DRY_RUN )); then ( fetch_upstream >/dev/null 2>&1 ) || true; fi
    [[ -f "$f" ]] && printf '%s' "$f"
    return 0
}

cfg_services() {
    section "Services"
    log_info "on = runs | disabled = never started, folders kept | removed = never started, no app-data folder"
    local f; f=$(compose_for_listing)
    if [[ -z "$f" ]] || (( ASSUME_YES )) || ! is_tty; then
        [[ -z "$f" ]] && log_warn "Service list unavailable (upstream not downloaded); enter names manually."
        ask "CFG[DISABLED_SERVICES]" "Disabled services (space separated)" "${CFG[DISABLED_SERVICES]}"
        ask "CFG[REMOVED_SERVICES]"  "Removed services (space separated)"  "${CFG[REMOVED_SERVICES]}"
        return 0
    fi
    local -a svcs; mapfile -t svcs < <(compose_services_list "$f")
    local in n i s st line
    while :; do
        echo
        for i in "${!svcs[@]}"; do
            st=$(svc_state "${svcs[$i]}")
            case "$st" in on) line="${G}on${NC}      " ;; disabled) line="${Y}disabled${NC}" ;; *) line="${R}removed${NC} " ;; esac
            printf '  %2d) %-20s %s' "$((i + 1))" "${svcs[$i]}" "$line"
            (( (i + 1) % 3 == 0 )) && echo
        done
        echo
        read -rp "  Numbers to cycle on -> disabled -> removed (e.g. '12 31'), Enter when done: " in || true
        [[ -z "$in" ]] && break
        for n in $in; do
            if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#svcs[@]} )); then log_warn "Ignoring '$n'"; continue; fi
            s=${svcs[$((n - 1))]}
            case "$(svc_state "$s")" in
                on)       set_svc_state "$s" disabled ;;
                disabled) set_svc_state "$s" removed ;;
                removed)  set_svc_state "$s" on ;;
            esac
            case "$s" in
                gluetun|postgresql|valkey|traefik|authentik)
                    [[ "$(svc_state "$s")" != on ]] && log_warn "'$s' is a dependency of other services; compose validation may fail without it." ;;
            esac
        done
    done
    for s in $(excluded_services); do
        in_list "$s" "${svcs[@]}" || log_info "'$s' is not in this compose variant (kept in the list, ignored)"
    done
}

cfg_vpn_email() {
    section "VPN and email"
    ask_valid "CFG[VPN_TYPE]" "VPN type (openvpn/wireguard)" "${CFG[VPN_TYPE]}" v_vpn "openvpn or wireguard"
    ask "CFG[VPN_SERVICE_PROVIDER]" "VPN provider (Gluetun name, e.g. mullvad, protonvpn, custom)" "${CFG[VPN_SERVICE_PROVIDER]}"
    ask "CFG[SERVER_REGIONS]" "VPN server regions (blank = provider default)" "${CFG[SERVER_REGIONS]}"
    ask "CFG[EMAIL_SERVER_HOST]" "SMTP host for Authentik (blank = none)" "${CFG[EMAIL_SERVER_HOST]}"
    ask_valid "CFG[EMAIL_SERVER_PORT]" "SMTP port" "${CFG[EMAIL_SERVER_PORT]}" v_num "a port number"
    ask "CFG[EMAIL_ADDRESS]" "SMTP username/address" "${CFG[EMAIL_ADDRESS]}"
    ask "CFG[EMAIL_SENDER]" "Email sender address" "${CFG[EMAIL_SENDER]}"
}

cfg_stack() {
    section "Upstream and secrets"
    ask "CFG[UPSTREAM_REF]" "Upstream ref (commit SHA recommended)" "${CFG[UPSTREAM_REF]}"
    ask_valid "CFG[UPSTREAM_VARIANT]" "Compose variant (full-download-vpn/mini-download-vpn/no-download-vpn)" "${CFG[UPSTREAM_VARIANT]}" v_variant "one of the three variants"
    ask_valid "CFG[SECRETS_MODE]" "Secrets mode (vault = encrypted, injected at runtime; env = plaintext .env)" "${CFG[SECRETS_MODE]}" v_mode "vault or env"
    ask_valid "CFG[SECRETS_BACKEND]" "Secrets backend (auto/systemd-creds/openssl)" "${CFG[SECRETS_BACKEND]}" v_backend "auto, systemd-creds or openssl"
    ask_valid "CFG[CHOWN_MEDIA_RECURSIVE]" "Re-own the whole media library on every apply (yes/no)" "${CFG[CHOWN_MEDIA_RECURSIVE]}" v_yesno "yes or no"
    ask "CFG[EXTRA_PACKAGES]" "Extra apt packages to install (blank = none)" "${CFG[EXTRA_PACKAGES]}"
}

config_summary() {
    section "Configuration"
    local k
    for k in "${CONF_KEYS[@]}"; do printf '    %-24s %s\n' "$k" "${CFG[$k]}"; done
    if [[ "${CFG[MEDIA_STORAGE]}" == smb ]]; then
        printf '    %-24s %s\n' "MEDIA SMB credentials" "$( [[ -n "${SECRETS[MEDIA_SMB_USERNAME]:-}" ]] && echo "user ${SECRETS[MEDIA_SMB_USERNAME]} (password in vault)" || echo guest)"
    fi
}

settings_save() {
    save_config
    if (( SECRETS_DIRTY )); then save_secrets; SECRETS_DIRTY=0; fi
}

# config_wizard -- first run: detect, then walk every section
config_wizard() {
    load_config
    [[ -f "$CONF_FILE" ]] || detect_defaults
    [[ -f "$SECRETS_FILE" ]] && load_secrets || SECRETS_LOADED=1
    cfg_paths; cfg_network; cfg_storage MEDIA; cfg_storage DATA; cfg_account
    cfg_services; cfg_vpn_email; cfg_stack
    config_summary
    confirm "Save this configuration?" y || die "Cancelled; nothing saved."
    settings_save
    resolve_runtime
}

menu_settings() {
    load_config
    local dirty=0 ch w
    if [[ ! -f "$CONF_FILE" ]]; then detect_defaults; dirty=1; fi
    [[ -f "$SECRETS_FILE" ]] && load_secrets || SECRETS_LOADED=1
    while :; do
        printf '\n  %sSettings%s %s\n' "$B" "$NC" "$( ((dirty)) && printf '%s(unsaved changes)%s' "$Y" "$NC")"
        printf '   1) Paths             media=%s data=%s\n' "${CFG[FOLDER_FOR_MEDIA]}" "${CFG[FOLDER_FOR_DATA]}"
        printf '   2) Domain / network  %s  ip=%s subnet=%s\n' "${CFG[DOMAIN]:-<unset>}" "${CFG[LOCAL_DOCKER_IP]}" "${CFG[LOCAL_SUBNET]}"
        printf '   3) Media storage     %s\n' "$(storage_desc MEDIA)"
        printf '   4) App-data storage  %s\n' "$(storage_desc DATA)"
        printf '   5) Service account   %s\n' "${CFG[SERVICE_USER]}"
        printf '   6) Services          disabled: %s | removed: %s\n' "${CFG[DISABLED_SERVICES]:-none}" "${CFG[REMOVED_SERVICES]:-none}"
        printf '   7) VPN / email       %s / %s\n' "${CFG[VPN_TYPE]}" "${CFG[VPN_SERVICE_PROVIDER]}"
        printf '   8) Upstream/secrets  %s %s mode=%s\n' "${CFG[UPSTREAM_REF]:0:12}" "${CFG[UPSTREAM_VARIANT]}" "${CFG[SECRETS_MODE]}"
        printf '   D) Re-run detection   T) Test share mount   V) View all\n'
        printf '   W) Save   A) Save + apply   0) Back\n'
        read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            1) cfg_paths; dirty=1 ;;
            2) cfg_network; dirty=1 ;;
            3) cfg_storage MEDIA; dirty=1 ;;
            4) cfg_storage DATA; dirty=1 ;;
            5) cfg_account; dirty=1 ;;
            6) cfg_services; dirty=1 ;;
            7) cfg_vpn_email; dirty=1 ;;
            8) cfg_stack; dirty=1 ;;
            d) detect_defaults; dirty=1 ;;
            t) ask w "Test which share (MEDIA/DATA)" MEDIA; w=${w^^}
               [[ "$w" =~ ^(MEDIA|DATA)$ ]] && menu_action storage_test "$w" ;;
            v) config_summary ;;
            w) settings_save; dirty=0 ;;
            a) settings_save; dirty=0; menu_action stack_apply nopull ;;
            0|q) if (( dirty )) && confirm "Save changes before leaving?" y; then settings_save; fi; return 0 ;;
            *) printf '  %sInvalid choice%s\n' "$R" "$NC" ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# FULL INSTALL
# -----------------------------------------------------------------------------
full_install() {
    preflight
    if [[ -f "$CONF_FILE" ]] && { (( ASSUME_YES )) || ! is_tty || ! confirm "Existing configuration found. Review/edit every section?" n; }; then
        load_config; resolve_runtime; log_ok "Using $CONF_FILE"
    else
        config_wizard
    fi
    [[ -n "${CFG[DOMAIN]}" ]] || die "DOMAIN is not set. Run interactively or set DOMAIN in $CONF_FILE."
    (( DRY_RUN )) || { mkdir -p "$MS_CONF_DIR"; chmod 700 "$MS_CONF_DIR"; }
    fetch_upstream
    log_step "Secrets"
    secrets_init
    install_docker
    ensure_service_account
    install_self
    stack_apply pull
    (( DRY_RUN )) || offer_post_install
    print_summary
}

print_summary() {
    local envf="$FOLDER_FOR_YAML/.env" ip; ip=$(eff_local_ip)
    log_step "Done"
    [[ -f "$envf" ]] || return 0
    local app port
    for app in HOMEPAGE PORTAINER AUTHENTIK GUACAMOLE PLEX JELLYFIN QBITTORRENT PROWLARR SONARR RADARR; do
        port=$(env_get "$envf" "WEBUI_PORT_$app" || true)
        [[ -n "$port" ]] && printf '  %-12s http://%s:%s\n' "${app,,}" "$ip" "$port"
    done
    printf '\n  Manage later with: sudo %s   (log: %s)\n' "$MS_INSTALL_BIN" "${LOG_FILE:-n/a}"
}

# -----------------------------------------------------------------------------
# SECRETS MENU
# -----------------------------------------------------------------------------
secrets_status() {
    local k st
    printf '\n  Store: %s  backend: %s  mode: %s\n\n' "$SECRETS_FILE" "$(secrets_file_backend)" "${CFG[SECRETS_MODE]}"
    for k in "${SECRET_KEYS[@]}"; do
        if secret_is_set "$k"; then st="${G}set${NC}"
        elif [[ "${SECRETS[$k]:-}" == "$SECRET_UNSET" ]]; then st="${Y}placeholder${NC}"
        else st="${D}empty${NC}"; fi
        in_list "$k" "${SECRET_GENERATED[@]}" && st+=" ${D}(generated)${NC}"
        printf '  %-26s %s\n' "$k" "$st"
    done
}

secret_change() {
    local k v
    ask k "Secret name" ""
    in_list "$k" "${SECRET_KEYS[@]}" || { log_warn "Unknown key '$k'"; return 0; }
    if [[ "$k" == POSTGRESQL_PASSWORD ]]; then
        helper_prereq
        [[ -f "$FOLDER_FOR_DATA/postgresql/PG_VERSION" ]] && ! docker ps -q --filter "name=^${PG_CONTAINER}$" | grep -q . \
            && die "PostgreSQL is initialised but not running; start the stack first so the role password can be changed in-database."
    fi
    if in_list "$k" "${SECRET_GENERATED[@]}" && confirm "Generate a new random value for $k?" y; then
        case "$k" in POSTGRESQL_PASSWORD) v=$(gen_hex 24) ;; AUTHENTIK_SECRET_KEY) v=$(gen_hex 48) ;; *) v=$(gen_hex 16) ;; esac
    else
        ask_secret v "New value for $k (Enter cancels)"
        [[ -n "$v" ]] || { log_info "Unchanged"; return 0; }
    fi
    if [[ "$k" == POSTGRESQL_PASSWORD && -f "$FOLDER_FOR_DATA/postgresql/PG_VERSION" ]]; then
        printf "ALTER ROLE \"%s\" WITH PASSWORD '%s';\n" "$PG_USER" "${v//\'/\'\'}" | pg_sql postgres \
            || die "ALTER ROLE failed; password unchanged."
        log_ok "Database role password changed"
    fi
    SECRETS[$k]=$v
    save_secrets
    [[ "$k" == AUTHENTIK_SECRET_KEY ]] && log_warn "Changing AUTHENTIK_SECRET_KEY logs out all Authentik sessions."
    log_info "Run Apply (menu 5) so containers pick up the new value."
}

secret_reveal() {
    local k; ask k "Secret name to reveal" ""
    in_list "$k" "${SECRET_KEYS[@]}" || { log_warn "Unknown key"; return 0; }
    confirm_typed REVEAL || { log_info "Cancelled"; return 0; }
    printf '  %s=%s\n' "$k" "${SECRETS[$k]:-}"
    _log_file AUDIT "secret revealed on screen: $k"
}

secret_export() {
    log_warn "This prints ALL secrets in plaintext (KEY=VALUE) for an offline backup."
    confirm_typed EXPORT || { log_info "Cancelled"; return 0; }
    local k; for k in "${SECRET_KEYS[@]}"; do printf '%s=%s\n' "$k" "${SECRETS[$k]:-}"; done
    _log_file AUDIT "all secrets exported to screen"
}

secret_import_file() {
    local f k v n=0 line
    ask f "Path to KEY=VALUE file" ""
    [[ -f "$f" ]] || { log_warn "Not found: $f"; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        in_list "$k" "${SECRET_KEYS[@]}" || continue
        SECRETS[$k]=$v; n=$((n + 1))
    done <"$f"
    save_secrets
    log_ok "Imported $n secret(s). Delete the plaintext file: shred -u $f"
}

secrets_init_menu() { resolve_runtime; secrets_init; }

menu_secrets() {
    require_config; load_secrets
    while :; do
        printf '\n  %sSecrets%s\n' "$B" "$NC"
        printf '  1) Status (names only)\n  2) Set / change a secret\n  3) Prompt for missing secrets\n'
        printf '  4) Reveal one secret\n  5) Export all (plaintext backup)\n  6) Import from KEY=VALUE file\n'
        printf '  7) Re-encrypt with current backend (%s)\n  0) Back\n' "$(secrets_backend_resolve)"
        local ch; read -rp "  Choice: " ch || return 0
        case "$ch" in
            1) secrets_status ;;
            2) menu_action secret_change; SECRETS_LOADED=0; load_secrets ;;
            3) menu_action secrets_init_menu; SECRETS_LOADED=0; load_secrets ;;
            4) secret_reveal ;;
            5) secret_export ;;
            6) secret_import_file ;;
            7) menu_action save_secrets ;;
            0) return 0 ;;
            *) printf '  %sInvalid choice%s\n' "$R" "$NC" ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# UNINSTALL / ENGINE PURGE
# -----------------------------------------------------------------------------
uninstall_stack() {
    require_config; resolve_runtime; load_secrets
    log_step "Uninstall MediaStack (stack only)"
    local p
    stack_down_if_running
    for p in "$FOLDER_FOR_YAML" "$FOLDER_FOR_DATA" "$FOLDER_FOR_MEDIA"; do
        safe_path "$p" || die "Refusing: unsafe path '$p' in config."
    done
    printf '  This will:\n'
    printf '   - docker compose down: remove %s containers, networks, named volumes, images\n' "$PROJECT_NAME"
    printf '   - delete compose folder  %s\n' "$FOLDER_FOR_YAML"
    printf '   - delete app data folder %s  (all app settings and databases; storage: %s)\n' "$FOLDER_FOR_DATA" "$(storage_desc DATA)"
    printf '   - unmount and remove the fstab entries of installer-managed shares\n'
    printf '  It will NOT touch the media library, Docker Engine, or other containers unless asked below.\n\n'
    confirm_typed UNINSTALL || { log_info "Cancelled"; return 0; }
    if docker_up && [[ -f "$FOLDER_FOR_YAML/docker-compose.yaml" ]]; then
        run_logged compose_run down --volumes --remove-orphans --rmi all || log_warn "compose down reported errors"
    elif docker_up; then
        local ids; ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME")
        [[ -n "$ids" ]] && run docker rm -f $ids
    fi
    wipe_path "$FOLDER_FOR_YAML"
    wipe_path "$FOLDER_FOR_DATA"
    log_ok "Stack, compose folder and app data removed"

    printf '\n  Media library: %s (%s)\n' "$FOLDER_FOR_MEDIA" "$(storage_desc MEDIA)"
    is_remote MEDIA && log_warn "Deleting the media library here deletes the files ON THE SHARE."
    if [[ -d "$FOLDER_FOR_MEDIA" ]] && is_tty && confirm "Delete the media library too?" n; then
        if confirm_typed DELETE-MEDIA; then wipe_path "$FOLDER_FOR_MEDIA"; log_ok "Media library deleted"
        else log_info "Media kept"; fi
    else
        log_info "Media kept"
    fi
    storage_release MEDIA
    storage_release DATA
    if [[ -f "$MS_DROPIN_DIR/mediastack-mounts.conf" ]]; then
        run rm -f "$MS_DROPIN_DIR/mediastack-mounts.conf"; run systemctl daemon-reload 2>/dev/null || true
    fi
    if id "${CFG[SERVICE_USER]}" >/dev/null 2>&1 && confirm "Remove service account '${CFG[SERVICE_USER]}'?" n; then
        run userdel "${CFG[SERVICE_USER]}" || true
        getent group "${CFG[SERVICE_USER]}" >/dev/null && run groupdel "${CFG[SERVICE_USER]}" || true
    fi
    if confirm "Remove installer config + encrypted secrets ($MS_CONF_DIR) and state? (keep them to reinstall with the same passwords)" n; then
        run rm -rf -- "$MS_CONF_DIR" "$MS_STATE_DIR"
        [[ "$SCRIPT_PATH" != "$MS_INSTALL_BIN" ]] && run rm -f "$MS_INSTALL_BIN"
        log_ok "Installer config, secrets and state removed"
    else
        run rm -f "$MS_STATE_DIR/deployed_ref" "$MS_STATE_DIR/deployed_domain"
        log_info "Config and secrets kept in $MS_CONF_DIR"
    fi
    log_ok "Uninstall complete"
}

purge_docker_engine() {
    log_step "Purge Docker Engine (host-wide)"
    if docker_up; then
        local others
        others=$(docker ps -a --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}' | awk -F'\t' -v p="$PROJECT_NAME" '$2 != p {print $1}')
        if [[ -n "$others" ]]; then
            log_warn "These NON-MediaStack containers will also be destroyed:"
            printf '%s\n' "$others" | sed 's/^/      /'
        fi
        printf '  Images: %s   Volumes: %s\n' "$(docker images -q | wc -l)" "$(docker volume ls -q | wc -l)"
    fi
    printf '  This removes Docker CE packages, /var/lib/docker, /var/lib/containerd and the Docker apt repo.\n'
    printf '  ALL containers, images and volumes on this host are destroyed. Bind-mounted folders are not.\n\n'
    confirm_typed PURGE-DOCKER || { log_info "Cancelled"; return 0; }
    if docker_up; then
        local ids; ids=$(docker ps -aq)
        [[ -n "$ids" ]] && run docker rm -f $ids
    fi
    run systemctl stop docker docker.socket containerd 2>/dev/null || true
    run_logged apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
    run_logged apt-get autoremove -y || true
    run rm -rf /var/lib/docker /var/lib/containerd
    run rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
    log_ok "Docker Engine purged"
}

menu_uninstall() {
    printf '\n  %sUninstall%s\n  1) MediaStack stack only (keeps Docker Engine)\n  2) Docker Engine purge (host-wide, separate confirmation)\n  0) Back\n' "$B" "$NC"
    local ch; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) menu_action uninstall_stack ;;
        2) menu_action purge_docker_engine ;;
    esac
}

# -----------------------------------------------------------------------------
# LOGS MENU
# -----------------------------------------------------------------------------
menu_logs() {
    printf '\n  %sLogs%s\n  1) List installer run logs\n  2) View previous run installer log\n  3) Container logs (one service)\n  0) Back\n' "$B" "$NC"
    local ch s; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) ls -1t "$MS_LOG_DIR"/installer-*.log 2>/dev/null | head -n "$LOG_KEEP" | sed 's/^/  /' ;;
        2) local f; f=$(ls -1t "$MS_LOG_DIR"/installer-*.log 2>/dev/null | sed -n 2p); [[ -n "$f" ]] && ${PAGER:-less} "$f" ;;
        3) ask s "Service name" "gluetun"; menu_action compose_logs "$s" ;;
    esac
}
compose_logs() { require_config; resolve_runtime; load_secrets; compose_run logs --tail 200 "$1"; }

# -----------------------------------------------------------------------------
# SELF-TEST (no root, no network, no Docker needed)
# -----------------------------------------------------------------------------
self_test() {
    log_step "Self-test ($SCRIPT_NAME v$SCRIPT_VERSION)"
    local pass=0 fail=0 t
    t=$(mktemp -d)
    st() { if eval "$2" >/dev/null 2>&1; then printf '  %s[PASS]%s %s\n' "$G" "$NC" "$1"; pass=$((pass + 1)); else printf '  %s[FAIL]%s %s\n' "$R" "$NC" "$1"; fail=$((fail + 1)); fi; }

    st "bash syntax"                       'bash -n "$SCRIPT_PATH"'
    st "version is semver"                 '[[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
    st "env parse: inline comment"         '[[ "$(env_parse_value "192.168.1.0/24             # subnet")" == "192.168.1.0/24" ]]'
    st "env parse: single-quoted"          "[[ \"\$(env_parse_value \"'a # b'\")\" == 'a # b' ]]"
    st "env parse: double-quoted"          '[[ "$(env_parse_value "\"q v\"")" == "q v" ]]'
    st "env parse: CRLF"                   '[[ "$(env_parse_value $'"'"'abc\r'"'"')" == abc ]]'
    printf 'A=1\nLOCAL_SUBNET=10.0.0.0/8     # your LAN\nB=2\nB=3\n' >"$t/.env"
    st "env_set moves inline comment"      'env_set "$t/.env" LOCAL_SUBNET 192.168.56.0/24 && grep -qx "# your LAN" "$t/.env" && grep -qx "LOCAL_SUBNET=192.168.56.0/24" "$t/.env"'
    st "env_set de-duplicates"             'env_set "$t/.env" B 9 && [[ $(grep -c "^B=" "$t/.env") == 1 && "$(env_get "$t/.env" B)" == 9 ]]'
    st "env_set appends new key"           'env_set "$t/.env" NEWKEY x && [[ "$(env_get "$t/.env" NEWKEY)" == x ]]'
    st "env_set quotes special value"      'env_set "$t/.env" P "a b\$c#d" && [[ "$(env_get "$t/.env" P)" == "a b\$c#d" ]]'
    st "env_set rejects single quote"      "! env_set \"\$t/.env\" Q \"it's\""
    st "conf quote round-trip"             "[[ \"\$(conf_unquote \"\$(conf_quote \"it's \\\$x\")\")\" == \"it's \\\$x\" ]]"
    st "cidr /24"                          '[[ "$(cidr_network 192.168.56.23/24)" == 192.168.56.0/24 ]]'
    st "cidr /20"                          '[[ "$(cidr_network 172.16.5.4/20)" == 172.16.0.0/20 ]]'
    st "cidr /8"                           '[[ "$(cidr_network 10.1.2.3/8)" == 10.0.0.0/8 ]]'
    st "safe_path rejects / /usr /home/x"  '! safe_path / && ! safe_path /usr && ! safe_path /home/alice && ! safe_path "" && ! safe_path rel/dir'
    st "safe_path accepts /mediastack/media" 'safe_path /mediastack/media && safe_path /home/alice/mediastack'
    st "data layout matches brace string"  '[[ "$(eval "printf \"%s \" $DATA_BRACE" | xargs)" == "$(printf "%s " "${DATA_SUBDIRS[@]}" | xargs)" ]]'
    st "domain/ip validators"              'valid_domain media.example.org && ! valid_domain "bad domain" && valid_ipv4 10.0.0.1 && valid_cidr 10.0.0.0/8 && ! valid_cidr 10.0.0.0/33'
    printf 'networks:\n  mediastack:\n    name: mediastack\n\nservices:\n\n####\n  whisparr:\n    image: x\n  radarr:\n    image: y\n' >"$t/compose.yaml"
    st "override renders profile"          'CFG[DISABLED_SERVICES]="whisparr,bogus"; CFG[REMOVED_SERVICES]="radarr whisparr"; out=$(render_override "$t/compose.yaml"); [[ "$out" == *"  whisparr:"* && "$out" == *"  radarr:"* && $(grep -c "  whisparr:" <<<"$out") == 1 && "$out" == *"bogus: not found"* ]]'
    st "compose service list (skips networks)" '[[ "$(compose_services_list "$t/compose.yaml" | xargs)" == "whisparr radarr" ]]'
    st "service state cycle"               'CFG[DISABLED_SERVICES]="whisparr"; CFG[REMOVED_SERVICES]="readarr"; set_svc_state whisparr removed; set_svc_state readarr on; set_svc_state sonarr disabled; [[ "${CFG[DISABLED_SERVICES]}" == sonarr && "${CFG[REMOVED_SERVICES]}" == whisparr && $(svc_state readarr) == on ]]'
    st "smb remote normalisation"          '[[ "$(normalize_remote smb "\\\\winsrv\\Media Share\\")" == "//winsrv/Media Share" ]] && valid_remote smb "//nas/media" && ! valid_remote smb "nas" && ! valid_remote smb "//nas/"'
    st "nfs remote validation"             'valid_remote nfs "truenas.lan:/mnt/tank/media" && valid_remote nfs "[fd00::5]:/media" && ! valid_remote nfs "/mnt/x"'
    st "fstab line: smb creds + escapes"   'PUID=990 PGID=990; CFG[MEDIA_STORAGE]=smb; CFG[MEDIA_REMOTE]="//winsrv/Media Share"; CFG[MEDIA_SMB_VERSION]=3.1.1; CFG[MEDIA_MOUNT_OPTS]=""; SECRETS[MEDIA_SMB_USERNAME]=svc; FOLDER_FOR_MEDIA=/srv/media; l=$(render_fstab_line MEDIA); [[ "$l" == "//winsrv/Media\\040Share /srv/media cifs credentials=$MS_CONF_DIR/media.smbcred,uid=990,gid=990,file_mode=0775,dir_mode=0775,iocharset=utf8,vers=3.1.1,_netdev,nofail,x-systemd.mount-timeout=30 0 0" ]]'
    st "fstab line: smb guest"             'PUID=1 PGID=1; CFG[MEDIA_STORAGE]=smb; CFG[MEDIA_REMOTE]=//nas/m; CFG[MEDIA_SMB_VERSION]=auto; SECRETS[MEDIA_SMB_USERNAME]=""; [[ "$(mount_opts MEDIA test)" == "guest,uid=1,gid=1,file_mode=0775,dir_mode=0775,iocharset=utf8" ]]'
    st "fstab line: nfs"                   'CFG[DATA_STORAGE]=nfs; CFG[DATA_REMOTE]=nas:/export/data; CFG[DATA_NFS_VERSION]=4.2; CFG[DATA_MOUNT_OPTS]=noatime; FOLDER_FOR_DATA=/srv/appdata; [[ "$(render_fstab_line DATA)" == "nas:/export/data /srv/appdata nfs vers=4.2,hard,_netdev,nofail,x-systemd.mount-timeout=30,noatime 0 0" ]]'
    printf '# static\nUUID=x / ext4 defaults 0 1\n' >"$t/fstab"
    st "fstab set/replace/remove"          '( MS_FSTAB="$t/fstab"; DRY_RUN=0; fstab_set MEDIA "a b cifs o 0 0" && fstab_set MEDIA "c d cifs o 0 0" && [[ "$(fstab_current MEDIA)" == "c d cifs o 0 0" && $(grep -c mediastack-installer:MEDIA "$MS_FSTAB") == 1 && "$(fstab_mountpoint MEDIA)" == d ]] && fstab_set MEDIA "" && [[ -z "$(fstab_current MEDIA)" && $(wc -l <"$MS_FSTAB") == 2 ]] && [[ -f "$MS_FSTAB.mediastack.bak" ]] )'
    st "config migration EXCLUDE->DISABLED" '( MS_CONF_DIR="$t/c"; CONF_FILE="$t/c/m.conf"; mkdir -p "$t/c"; printf "%s\n" "EXCLUDE_SERVICES='"'"'whisparr readarr'"'"'" >"$CONF_FILE"; REF_OVERRIDE=""; load_config; [[ "${CFG[DISABLED_SERVICES]}" == whisparr && "${CFG[REMOVED_SERVICES]}" == readarr ]] )'
    st "placeholder detection"             'looks_placeholder X "1234567890abcdef1234" && looks_placeholder X "<user>" && ! looks_placeholder X "Sup3rS3cret"'
    st "secrets round-trip (openssl)"      '(
        MS_CONF_DIR="$t/conf"; SECRETS_FILE="$t/conf/secrets.enc"; KEY_FILE="$t/conf/.k"; CFG[SECRETS_BACKEND]=openssl
        DRY_RUN=0; LOG_FILE=""
        SECRETS=([VPN_PASSWORD]="p@ss'"'"'w\"rd \$x\\y" [PLEX_CLAIM]="claim-abc")
        save_secrets && SECRETS=() && SECRETS_LOADED=0 && load_secrets &&
        [[ "${SECRETS[VPN_PASSWORD]}" == "p@ss'"'"'w\"rd \$x\\y" && "${SECRETS[PLEX_CLAIM]}" == claim-abc ]] &&
        ! grep -q claim-abc "$SECRETS_FILE" && [[ $(stat -c %a "$SECRETS_FILE") == 600 ]] )'
    if [[ "$(secrets_backend_resolve)" == systemd-creds && $EUID -eq 0 ]]; then
        st "systemd-creds encrypt/decrypt"  '[[ "$(printf hello | systemd-creds encrypt --name=mediastack-selftest - - | systemd-creds decrypt --name=mediastack-selftest - -)" == hello ]]'
    fi
    rm -rf "$t"
    printf '\n  Result: %s%d passed%s, %s%d failed%s\n' "$G" "$pass" "$NC" "$( ((fail)) && echo "$R" || echo "$G")" "$fail" "$NC"
    _log_file SELFTEST "pass=$pass fail=$fail"
    [[ $fail -eq 0 ]]
}

# -----------------------------------------------------------------------------
# MENUS
# -----------------------------------------------------------------------------
# menu_action FN ARGS...  -- run in a subshell so a failure returns to the menu
menu_action() {
    local rc
    set +e
    ( set -e; "$@" )
    rc=$?
    set -e
    (( rc == 0 )) || log_warn "Action '$1' ended with rc=$rc (see $LOG_FILE)"
    return 0
}

menu_helpers() {
    printf '\n  %sPost-install helpers%s\n' "$B" "$NC"
    printf '  1) Secure Authentik database (grants)\n  2) Create Guacamole database + schema\n'
    printf '  3) Reset Authentik akadmin password\n  4) Show *ARR API keys (optionally store in vault)\n  0) Back\n'
    local ch; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) menu_action helper_authentik_db ;;
        2) menu_action helper_guacamole_db ;;
        3) menu_action helper_akadmin ;;
        4) menu_action helper_apikeys ;;
    esac
}

show_banner() {
    load_config
    local cfg_state stack="docker not running" mode
    [[ -f "$CONF_FILE" ]] && cfg_state="${G}configured${NC}" || cfg_state="${Y}not configured${NC}"
    if docker_up; then
        stack="$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" | wc -l) running"
    fi
    (( DRY_RUN )) && mode="${Y}DRY-RUN${NC}" || mode="${G}LIVE${NC}"
    printf '\n  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  %s|%s  %sMediaStack Installer%s v%-8s  host: %-20s%s|%s\n' "$C" "$NC" "$B" "$NC" "$SCRIPT_VERSION" "$(hostname -s | cut -c1-20)" "$C" "$NC"
    printf '  %s+------------------------------------------------------------+%s\n' "$C" "$NC"
    printf '  Config: %b   Containers: %s   Mode: %b\n' "$cfg_state" "$stack" "$mode"
}

main_menu() {
    while :; do
        show_banner
        printf '\n  %sSetup%s\n' "$B" "$NC"
        printf '   1) Full install / reconfigure\n   2) Settings (paths, storage, services, ...)\n   3) Secrets\n'
        printf '  %sOperate%s\n' "$B" "$NC"
        printf '   4) Apply + pull updates   (converge, pull images, up)\n'
        printf '   5) Apply without pulling  (converge, up)\n'
        printf '   6) Stop stack             (containers down, data kept)\n'
        printf '   7) Status\n   8) Post-install helpers\n   9) Logs\n'
        printf '  %sMaintenance%s\n' "$B" "$NC"
        printf '   U) Uninstall...\n   T) Toggle dry-run\n   S) Self-test\n   0) Quit\n\n'
        local ch; read -rp "  Choice: " ch || exit 0
        case "${ch,,}" in
            1) menu_action full_install ;;
            2) menu_settings ;;
            3) menu_secrets ;;
            4) menu_action stack_apply pull ;;
            5) menu_action stack_apply nopull ;;
            6) menu_action stack_stop ;;
            7) menu_action show_status ;;
            8) menu_helpers ;;
            9) menu_logs ;;
            u) menu_uninstall ;;
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
$SCRIPT_NAME v$SCRIPT_VERSION -- MediaStack installer and lifecycle manager

Usage: sudo $(basename "$SCRIPT_PATH") [options] [action]

Actions (default: interactive menu)
  --install              Full install / reconfigure (wizard, secrets, Docker, account, apply)
  --apply                Converge files/.env/folders, pull images, start stack
  --start                Converge and start without pulling images
  --stop                 Stop stack (docker compose down; data kept)
  --status               Show configuration and container status
  --helper NAME          authentik-db | guacamole | akadmin | apikeys
  --settings             Settings menu (paths, network, storage, services, ...)
  --test-storage T       Trial-mount MEDIA or DATA share; check write + hardlinks
  --secrets              Secrets menu
  --uninstall            Remove MediaStack stack + compose/app-data folders (keyword UNINSTALL)
  --purge-docker         Remove Docker Engine host-wide (keyword PURGE-DOCKER)
  --compose ARGS...      Run 'docker compose' for the project with secrets injected
  --self-test            Run built-in tests (no root needed)
  --version | -h, --help

Options
  --dry-run              Show what would change; change nothing
  --yes                  Accept defaults for all prompts (non-interactive)
  --ref REF              Use this upstream commit/tag/branch for this run (saved on --install)
  --confirm KEYWORD      Pre-answer a typed confirmation (UNINSTALL, PURGE-DOCKER)

Files
  $CONF_FILE    settings (0600)
  $SECRETS_FILE       encrypted secrets
  $MS_LOG_DIR/installer-*.log   run logs (newest $LOG_KEEP kept)
EOF
}

check_root() {
    [[ $EUID -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "Run as root (sudo not found)."
    exec sudo -E bash "$SCRIPT_PATH" "$@"
}

acquire_lock() {
    exec 9>"$MS_LOCK_FILE"
    flock -n 9 || die "Another $SCRIPT_NAME run is in progress ($MS_LOCK_FILE)."
}

main() {
    local action="menu" helper="" ; local -a compose_args=() orig=("$@")
    while (( $# )); do
        case "$1" in
            --install)      action=install ;;
            --apply)        action=apply ;;
            --start)        action=start ;;
            --stop)         action=stop ;;
            --status)       action=status ;;
            --helper)       action=helper; helper=${2:-}; shift ;;
            --secrets)      action=secrets ;;
            --settings)     action=settings ;;
            --test-storage) action=teststorage; helper=${2:-MEDIA}; shift ;;
            --uninstall)    action=uninstall ;;
            --purge-docker) action=purge ;;
            --compose)      action=compose; shift; compose_args=("$@"); break ;;
            --self-test)    action=selftest ;;
            --dry-run)      DRY_RUN=1 ;;
            --yes|-y)       ASSUME_YES=1 ;;
            --ref)          REF_OVERRIDE=${2:-}; shift ;;
            --confirm)      CONFIRM_KEYWORD=${2:-}; shift ;;
            --version)      echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            -h|--help)      usage; exit 0 ;;
            *)              usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done

    if [[ "$action" == selftest ]]; then
        set_default_config
        if self_test; then exit 0; else exit 1; fi
    fi

    check_root "${orig[@]}"
    init_logging
    acquire_lock
    _log_file INFO "================================================"
    _log_file INFO "$SCRIPT_NAME v$SCRIPT_VERSION started action=$action dry_run=$DRY_RUN"
    _log_file INFO "User: $(id -un) (real: $REAL_USER)  PID: $$"
    _log_file INFO "================================================"

    case "$action" in
        menu)      is_tty || die "No terminal; use a CLI action (see --help)."; main_menu ;;
        install)   full_install ;;
        apply)     stack_apply pull ;;
        start)     stack_apply nopull ;;
        stop)      stack_stop ;;
        status)    show_status ;;
        secrets)   menu_secrets ;;
        settings)  is_tty || die "Settings menu needs a terminal."; menu_settings ;;
        teststorage) storage_test "${helper^^}" ;;
        uninstall) uninstall_stack ;;
        purge)     purge_docker_engine ;;
        compose)   require_config; resolve_runtime; load_secrets; compose_run "${compose_args[@]}" ;;
        helper)
            case "$helper" in
                authentik-db) helper_authentik_db ;;
                guacamole)    helper_guacamole_db ;;
                akadmin)      helper_akadmin ;;
                apikeys)      helper_apikeys ;;
                *)            die "Unknown helper '$helper' (authentik-db|guacamole|akadmin|apikeys)" ;;
            esac ;;
    esac
    _log_file INFO "Finished action=$action"
}

main "$@"
