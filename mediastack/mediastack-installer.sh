#!/usr/bin/env bash
# =============================================================================
#  mediastack-installer.sh
#  Installer and lifecycle manager for MediaStack (github.com/geekau/mediastack)
#
#  Version   : SCRIPT_VERSION below is the authoritative version string
#  Changelog : CHANGELOG.md (per-version history)
#  Docs      : README.md
#  Author    : netgeek1 & Claude (Anthropic)
#
#  Usage     : sudo ./mediastack-installer.sh              interactive menu
#              sudo ./mediastack-installer.sh --install    full install / reconfigure
#              sudo ./mediastack-installer.sh --help       all CLI flags
#
#  Requires  : bash 4.4+, Ubuntu or Debian (amd64/arm64), root (re-execs via sudo),
#              Docker Compose v2.24.4+ (installed/updated from Docker's repository when missing)
#              MediaStack itself is upstream's compose project; nothing else is embedded here.
#  License   : MIT
# =============================================================================
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION="2.5.10"
readonly SCRIPT_NAME="mediastack-installer"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

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

# Folders for installer-patched upstream services (not in upstream restart.sh)
EXTRA_DATA_SUBDIRS=( homarr/appdata )

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

# Add-on services: not part of upstream MediaStack; defined by this installer in the managed
# docker-compose.override.yaml and toggled like any other service (on/disabled/removed).
ADDON_SERVICES=( audiobookshelf )
declare -A ADDON_DATA_DIRS=( [audiobookshelf]="audiobookshelf/config audiobookshelf/metadata" )
declare -A ADDON_MEDIA_DIRS=( [audiobookshelf]="media/audio media/podcasts media/books" )
declare -A ADDON_ENV_DEFAULTS=( [audiobookshelf]="WEBUI_PORT_AUDIOBOOKSHELF=13378" )

# -----------------------------------------------------------------------------
# CONFIG MODEL (non-secret settings -> $CONF_FILE)
# -----------------------------------------------------------------------------
CONF_KEYS=( FOLDER_FOR_MEDIA FOLDER_FOR_DATA FOLDER_FOR_YAML DOMAIN CLOUDFLARE_DNS_ZONE CLOUDFLARE_EMAIL
            TIMEZONE LOCAL_SUBNET LOCAL_DOCKER_IP SERVICE_USER SERVICE_UID SERVICE_GID ADMIN_DOCKER_GROUP
            VPN_TYPE VPN_SERVICE_PROVIDER SERVER_REGIONS EMAIL_SERVER_HOST EMAIL_SERVER_PORT EMAIL_ADDRESS
            EMAIL_SENDER DISABLED_SERVICES REMOVED_SERVICES UPSTREAM_REPO UPSTREAM_REF UPSTREAM_VARIANT
            EXTRA_PACKAGES CHOWN_MEDIA_RECURSIVE SECRETS_MODE SECRETS_BACKEND
            MEDIA_STORAGE MEDIA_REMOTE MEDIA_SMB_DOMAIN MEDIA_SMB_VERSION MEDIA_NFS_VERSION MEDIA_MOUNT_OPTS
            MEDIA_MOUNT_REQUIRED DATA_STORAGE DATA_REMOTE DATA_NFS_VERSION DATA_MOUNT_OPTS DATA_MOUNT_REQUIRED
            ACCESS_MODE CERT_MODE TLS_CERT_FILE TLS_KEY_FILE SERVICE_PRESET PLAYER TAILSCALE_CONTROL
            BACKUP_DIR BACKUP_KEEP BACKUP_FORMAT BACKUP_PASSPHRASE_FILE BACKUP_STOP_STACK
            VPN_CUSTOM_OVPN_FILE VPN_ENDPOINT_IP VPN_ENDPOINT_PORT WIREGUARD_PUBLIC_KEY WIREGUARD_ADDRESSES
            CERT_FETCH_SOURCE CERT_FETCH_CERT CERT_FETCH_KEY CERT_PUSH_USER CERT_PUSH_FROM
            SERVER_COUNTRIES SERVER_CITIES SERVER_HOSTNAMES VPN_SERVERS_UPDATE_PERIOD VPN_UPDATER_PROTON_EMAIL )
# Settings that did not exist before v2.0.0: an existing config without them keeps its old behaviour
declare -A CONF_LEGACY=( [ACCESS_MODE]=internet [CERT_MODE]=letsencrypt [SERVICE_PRESET]=custom
                         [TAILSCALE_CONTROL]=headscale [PLAYER]=both )
declare -A CFG=()

# .env keys driven from CFG on every apply
ENV_MANAGED=( FOLDER_FOR_MEDIA FOLDER_FOR_DATA TIMEZONE LOCAL_SUBNET LOCAL_DOCKER_IP VPN_TYPE
              VPN_SERVICE_PROVIDER SERVER_REGIONS SERVER_COUNTRIES SERVER_CITIES SERVER_HOSTNAMES CLOUDFLARE_EMAIL CLOUDFLARE_DNS_ZONE EMAIL_SERVER_HOST
              EMAIL_SERVER_PORT EMAIL_ADDRESS EMAIL_SENDER )

# -----------------------------------------------------------------------------
# SECRETS MODEL (encrypted -> $SECRETS_FILE)
# -----------------------------------------------------------------------------
SECRET_KEYS=( VPN_USERNAME VPN_PASSWORD PLEX_CLAIM CLOUDFLARE_DNS_API_TOKEN EMAIL_PASSWORD TAILSCALE_AUTHKEY
              WIREGUARD_PRIVATE_KEY WIREGUARD_PRESHARED_KEY POSTGRESQL_PASSWORD AUTHENTIK_SECRET_KEY
              HEADPLANE_COOKIE_SECRET SONARR_API_TOKEN RADARR_API_TOKEN LIDARR_API_TOKEN READARR_API_TOKEN
              WHISPARR_API_TOKEN MYLAR_API_TOKEN MEDIA_SMB_USERNAME MEDIA_SMB_PASSWORD SECRET_ENCRYPTION_KEY
              TLS_KEY_PASSPHRASE UPDATER_PROTONVPN_PASSWORD )
# Vault entries that are not .env variables
SECRET_NON_ENV=( HEADPLANE_COOKIE_SECRET MEDIA_SMB_USERNAME MEDIA_SMB_PASSWORD TLS_KEY_PASSPHRASE )
SECRET_PROMPTED=( VPN_USERNAME VPN_PASSWORD CLOUDFLARE_DNS_API_TOKEN TAILSCALE_AUTHKEY EMAIL_PASSWORD PLEX_CLAIM )
SECRET_WIREGUARD=( WIREGUARD_PRIVATE_KEY )   # WIREGUARD_PRESHARED_KEY is optional: taken from wg0.conf only
SECRET_REQUIRED=( VPN_USERNAME VPN_PASSWORD CLOUDFLARE_DNS_API_TOKEN TAILSCALE_AUTHKEY )   # compose :?err
SECRET_GENERATED=( POSTGRESQL_PASSWORD AUTHENTIK_SECRET_KEY HEADPLANE_COOKIE_SECRET SECRET_ENCRYPTION_KEY )
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

init_logging() {   # init_logging [PREFIX]  -- cert timer/push runs use their own prefix so they never rotate out install logs
    local pre=${1:-installer} old
    mkdir -p "$MS_LOG_DIR"
    chmod 750 "$MS_LOG_DIR"
    LOG_FILE="$MS_LOG_DIR/$pre-$(date +%F_%H-%M-%S).log"
    : >"$LOG_FILE"
    chmod 640 "$LOG_FILE"
    # Rotation: keep the newest $LOG_KEEP run logs of this kind
    while IFS= read -r old; do rm -f -- "$old"; done < <(ls -1t "$MS_LOG_DIR/$pre"-*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)))
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
        [VPN_SERVICE_PROVIDER]=""
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
        [ACCESS_MODE]="internet"
        [CERT_MODE]="letsencrypt"
        [TLS_CERT_FILE]=""
        [TLS_KEY_FILE]=""
        [SERVICE_PRESET]="core"
        [PLAYER]="jellyfin"
        [TAILSCALE_CONTROL]="tailscale"
        [BACKUP_DIR]="/var/backups/mediastack"
        [BACKUP_KEEP]="5"
        [BACKUP_FORMAT]="host"
        [BACKUP_PASSPHRASE_FILE]=""
        [BACKUP_STOP_STACK]="yes"
        [VPN_CUSTOM_OVPN_FILE]=""
        [VPN_ENDPOINT_IP]=""
        [VPN_ENDPOINT_PORT]=""
        [WIREGUARD_PUBLIC_KEY]=""
        [WIREGUARD_ADDRESSES]=""
        [CERT_FETCH_SOURCE]=""
        [CERT_FETCH_CERT]="fullchain.pem"
        [CERT_FETCH_KEY]="privkey.pem"
        [CERT_PUSH_USER]="mscertpush"
        [CERT_PUSH_FROM]=""
        [SERVER_COUNTRIES]=""
        [SERVER_CITIES]=""
        [SERVER_HOSTNAMES]=""
        [VPN_SERVERS_UPDATE_PERIOD]="480h"
        [VPN_UPDATER_PROTON_EMAIL]=""
    )
}

load_config() {
    set_default_config
    if [[ -f "$CONF_FILE" ]]; then
        local line k v legacy_excl="" have_disabled=0
        local -A seen=()
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
            k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
            seen[$k]=1
            [[ "$k" == EXCLUDE_SERVICES ]] && legacy_excl=$(conf_unquote "$v")   # v1.0.0 name
            [[ "$k" == DISABLED_SERVICES ]] && have_disabled=1
            in_list "$k" "${CONF_KEYS[@]}" || continue
            CFG[$k]=$(conf_unquote "$v")
        done <"$CONF_FILE"
        if (( ! have_disabled )) && [[ -n "$legacy_excl" ]]; then
            CFG[DISABLED_SERVICES]=$( { list_words "$legacy_excl" | grep -vxF -f <(list_words "${CFG[REMOVED_SERVICES]}") || true; } | xargs)
        fi
        for k in "${!CONF_LEGACY[@]}"; do [[ -n "${seen[$k]:-}" ]] || CFG[$k]=${CONF_LEGACY[$k]}; done
        # server filters were hand-edited in .env before v2.5.0: keep them when the config predates the keys
        for k in SERVER_COUNTRIES SERVER_CITIES SERVER_HOSTNAMES; do
            [[ -n "${seen[$k]:-}" ]] && continue
            v=$(env_get "${CFG[FOLDER_FOR_YAML]%/}/.env" "$k" 2>/dev/null || true)
            [[ "$v" =~ ^[^=#/]*$ ]] && CFG[$k]=$v
        done
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

# secret_needed KEY -- does the current selection of services actually use this secret?
secret_needed() {
    case "$1" in
        VPN_USERNAME|VPN_PASSWORD) svc_enabled gluetun && [[ "${CFG[VPN_TYPE]}" == openvpn ]] \
                                   && { [[ "${CFG[VPN_SERVICE_PROVIDER]}" != custom ]] || grep -qE '^[[:space:]]*auth-user-pass' "${CFG[VPN_CUSTOM_OVPN_FILE]:-/dev/null}" 2>/dev/null; } ;;
        WIREGUARD_PRIVATE_KEY) svc_enabled gluetun && [[ "${CFG[VPN_TYPE]}" == wireguard ]] ;;
        WIREGUARD_PRESHARED_KEY) return 1 ;;   # optional; most providers do not use one
        UPDATER_PROTONVPN_PASSWORD) svc_enabled gluetun && [[ "${CFG[VPN_SERVICE_PROVIDER]}" == protonvpn && -n "${CFG[VPN_UPDATER_PROTON_EMAIL]}" ]] ;;
        CLOUDFLARE_DNS_API_TOKEN) svc_enabled traefik && [[ "${CFG[CERT_MODE]}" == letsencrypt ]] ;;
        TAILSCALE_AUTHKEY) svc_enabled tailscale ;;
        PLEX_CLAIM) svc_enabled plex ;;
        EMAIL_PASSWORD) svc_enabled authentik && [[ -n "${CFG[EMAIL_SERVER_HOST]}" ]] ;;
        *) return 0 ;;
    esac
}

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
                SECRET_ENCRYPTION_KEY)   SECRETS[$k]=$(gen_hex 32) ;;   # Homarr 1.x: 64 hex chars
            esac
            log_ok "Generated $k (stored once; reused on every run)"; changed=1
        fi
    done
    local -a prompt_keys=("${SECRET_PROMPTED[@]}")
    [[ "${CFG[VPN_TYPE]}" == wireguard ]] && prompt_keys+=("${SECRET_WIREGUARD[@]}")
    for k in "${prompt_keys[@]}"; do
        secret_is_set "$k" && continue
        secret_needed "$k" || continue
        [[ "$k" == PLEX_CLAIM ]] && log_info "PLEX_CLAIM: get one at https://plex.tv/claim (valid ~4 minutes, first Plex start only)."
        if [[ "$k" == TAILSCALE_AUTHKEY ]]; then
            if [[ "${CFG[TAILSCALE_CONTROL]}" == headscale ]]; then
                log_info "TAILSCALE_AUTHKEY: after Headscale runs, create one with: docker exec headscale headscale preauthkeys create --user <user> --reusable"
            else
                log_info "TAILSCALE_AUTHKEY: create a reusable key at https://login.tailscale.com/admin/settings/keys"
            fi
        fi
        ask_secret v "$k (Enter to skip)"
        if [[ -n "$v" ]]; then SECRETS[$k]=$v; changed=1; fi
    done
    for k in "${SECRET_REQUIRED[@]}"; do
        if ! secret_is_set "$k"; then
            [[ "${SECRETS[$k]:-}" == "$SECRET_UNSET" ]] || changed=1
            SECRETS[$k]=$SECRET_UNSET
            if secret_needed "$k"; then
                log_warn "$k is not set (placeholder '$SECRET_UNSET' used so compose validates). Set it via the Secrets menu."
            fi
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
    if ! have_docker; then
        log_info "Docker is not installed yet; it is installed (with Compose v2.24.4+) after the settings."
    elif compose_version_ok; then
        log_ok "Docker Compose $(compose_version)"
    else
        log_warn "Docker Compose $(compose_version) is older than v2.24.4 (needed for '!override'); it is updated with Docker below."
    fi
}

compose_version() {   # empty when Docker/Compose is not installed yet (never fails)
    have_docker || return 0
    local v; v=$(docker compose version --short 2>/dev/null) || v=""
    printf '%s' "${v#v}"
}
compose_version_ok() {   # true when Compose understands the !override YAML tag (v2.24.4+)
    local v; v=$(compose_version)
    [[ -n "$v" ]] || return 1
    [[ "$(printf '%s\n%s\n' 2.24.4 "$v" | sort -V | head -n1)" == 2.24.4 ]]
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
    if ! (( DRY_RUN )) && ! compose_version_ok; then
        log_warn "Docker Compose $(compose_version) is too old for this installer; updating docker-compose-plugin"
        run_logged apt-get install -y --only-upgrade docker-compose-plugin || true
        compose_version_ok || die "Docker Compose v2.24.4+ is required (have $(compose_version)). Install it from Docker's repository."
    fi
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
    if has_line docker "$(id -nG "$u" 2>/dev/null | tr " " "\n")"; then
        log_warn "'$u' is in the docker group (root-equivalent). It does not need to be; consider: gpasswd -d $u docker"
    fi
    if [[ "${CFG[ADMIN_DOCKER_GROUP]}" == yes && "$REAL_USER" != root ]]; then
        if has_line docker "$(id -nG "$REAL_USER" 2>/dev/null | tr " " "\n")"; then
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
    [[ -f "$MS_INSTALL_BIN" ]] && cmp -s "$SCRIPT_PATH" "$MS_INSTALL_BIN" && return 0
    run install -D -m 750 -o root -g root "$SCRIPT_PATH" "$MS_INSTALL_BIN"
    log_ok "Installer copied to $MS_INSTALL_BIN"
}

# installed_version -> SCRIPT_VERSION of the installed copy (blank when none)
installed_version() { sed -n 's/^readonly SCRIPT_VERSION="\([0-9.]*\)".*/\1/p' "$MS_INSTALL_BIN" 2>/dev/null | head -n1; }

# self_update_installed -- running a newer copy from elsewhere: refresh the installed one, so
# 'sudo mediastack-installer', the certificate timer/watcher and the push receiver use the same version
self_update_installed() {
    local iv
    [[ "$SCRIPT_PATH" == "$MS_INSTALL_BIN" || ! -f "$MS_INSTALL_BIN" ]] && return 0
    iv=$(installed_version)
    [[ -n "$iv" && "$iv" != "$SCRIPT_VERSION" ]] || return 0
    if [[ "$(printf '%s\n%s\n' "$iv" "$SCRIPT_VERSION" | sort -V | tail -n1)" == "$SCRIPT_VERSION" ]]; then
        run install -m 750 -o root -g root "$SCRIPT_PATH" "$MS_INSTALL_BIN"
        log_ok "Updated $MS_INSTALL_BIN: v$iv -> v$SCRIPT_VERSION"
    else
        log_warn "$MS_INSTALL_BIN is newer (v$iv) than this copy (v$SCRIPT_VERSION); left alone."
    fi
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
            SERVER_*)        v=${CFG[$k]}
                             # 'custom' has no server list: any filter makes Gluetun refuse to start
                             [[ "${CFG[VPN_SERVICE_PROVIDER]}" == custom ]] && v="" ;;
            *)               v=${CFG[$k]} ;;
        esac
        env_set "$envf" "$k" "$v"
    done
    env_set "$envf" PUID "$PUID"
    env_set "$envf" PGID "$PGID"
    vpn_normalize
    # Endpoint: only provider 'custom' takes it (for listed providers it pins a server that is often not in
    # Gluetun's list: "target IP address not found"). Upstream passes the deprecated VPN_ENDPOINT_IP/PORT names,
    # so they stay blank here and the override sets WIREGUARD_ENDPOINT_IP/PORT instead.
    env_set "$envf" VPN_ENDPOINT_IP ""
    env_set "$envf" VPN_ENDPOINT_PORT ""
    env_set "$envf" WIREGUARD_PUBLIC_KEY "${CFG[WIREGUARD_PUBLIC_KEY]:-}"
    v=$(wg_addresses_usable "${CFG[WIREGUARD_ADDRESSES]:-}")
    [[ -n "$v" ]] && env_set "$envf" WIREGUARD_ADDRESSES "$v"
    if [[ "${CFG[VPN_SERVICE_PROVIDER]}" == custom && "${CFG[VPN_TYPE]}" == openvpn ]]; then
        env_set "$envf" OPENVPN_CUSTOM_CONFIG "$GLUETUN_OVPN_PATH"
    else
        env_set "$envf" OPENVPN_CUSTOM_CONFIG ""
    fi
    local a kv
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        for kv in ${ADDON_ENV_DEFAULTS[$a]:-}; do
            if ! grep -q "^${kv%%=*}=" "$envf" 2>/dev/null; then
                if (( DRY_RUN )); then log_info "[dry-run] would add ${kv} for add-on $a"; continue; fi
                printf '\n# added for add-on %s by %s\n' "$a" "$SCRIPT_NAME" >>"$envf"
                env_set "$envf" "${kv%%=*}" "${kv#*=}"
                log_ok "Added ${kv} to .env for $a"
            fi
        done
    done < <(active_addons)

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
# NB: "producer | grep -q" can die of SIGPIPE under pipefail; match against captured output instead
has_line() { grep -qx -- "$1" <<<"$2"; }
is_removed()  { has_line "$1" "$(removed_services)"; }

svc_state() {   # stored state: on | disabled | removed
    if has_line "$1" "$(removed_services)"; then echo removed
    elif has_line "$1" "$(disabled_services)"; then echo disabled
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

# forced_off -- services parked automatically because of other settings (never stored)
forced_off() {
    [[ "${CFG[CERT_MODE]:-letsencrypt}" != letsencrypt ]] && printf '%s\n' traefik-certs-dumper   # only reads acme.json
    return 0
}
excluded_services() { { disabled_services; removed_services; forced_off; } | awk 'NF && !seen[$0]++'; }
eff_state() {   # effective state after forced exclusions
    local st; st=$(svc_state "$1")
    if [[ "$st" == on ]] && has_line "$1" "$(forced_off)"; then echo disabled; else echo "$st"; fi
}
all_services() {   # upstream services of the selected variant + add-ons
    local f; f=$(compose_for_listing)
    [[ -n "$f" ]] && compose_services_list "$f"
    printf '%s\n' "${ADDON_SERVICES[@]}"
}
svc_exists()  { has_line "$1" "$(all_services)"; }
svc_enabled() { svc_exists "$1" && [[ "$(eff_state "$1")" == on ]]; }

# -----------------------------------------------------------------------------
# SERVICE PRESETS (chosen in the wizard; 'custom' keeps the lists as they are)
# -----------------------------------------------------------------------------
readonly PRESET_CORE_COMMON="gluetun qbittorrent sabnzbd prowlarr flaresolverr unpackerr sonarr radarr lidarr bazarr seerr homepage tailscale audiobookshelf"
readonly PRESET_CORE_INTERNET="traefik traefik-certs-dumper crowdsec authentik authentic-worker postgresql valkey"
readonly PRESET_ALWAYS_REMOVED="readarr"       # retired upstream
readonly PRESET_FULL_DISABLED="whisparr"

preset_core_on() {   # services ON in the Core preset for the current settings
    local -a on extra
    read -ra on <<<"$PRESET_CORE_COMMON"
    if [[ "${CFG[ACCESS_MODE]}" == internet ]]; then read -ra extra <<<"$PRESET_CORE_INTERNET"; on+=("${extra[@]}"); fi
    case "${CFG[PLAYER]}" in jellyfin) on+=(jellyfin) ;; plex) on+=(plex) ;; *) on+=(jellyfin plex) ;; esac
    [[ "${CFG[TAILSCALE_CONTROL]}" == headscale ]] && on+=(headscale headplane)
    printf '%s\n' "${on[@]}"
}

# apply_preset -- rewrite DISABLED_SERVICES / REMOVED_SERVICES from SERVICE_PRESET
apply_preset() {
    local p=${CFG[SERVICE_PRESET]:-custom} s d="" r=""
    [[ "$p" == custom ]] && return 0
    local -a all on=()
    mapfile -t all < <(all_services)
    (( ${#all[@]} > ${#ADDON_SERVICES[@]} )) || die "Service list unavailable (upstream not downloaded); cannot apply preset '$p'."
    r=$PRESET_ALWAYS_REMOVED
    case "$p" in
        full) d=$PRESET_FULL_DISABLED ;;
        core)
            mapfile -t on < <(preset_core_on)
            for s in "${all[@]}"; do
                in_list "$s" "${on[@]}" && continue
                in_list "$s" $PRESET_ALWAYS_REMOVED && continue
                d+=" $s"
            done ;;
    esac
    CFG[DISABLED_SERVICES]=$(xargs <<<"$d")
    CFG[REMOVED_SERVICES]=$(xargs <<<"$r")
    return 0
}

# -----------------------------------------------------------------------------
# DEPENDENCIES (compose depends_on + network_mode, plus links compose cannot see)
# -----------------------------------------------------------------------------
compose_deps() {   # FILE -> "service dependency" pairs
    awk '
        /^services:/ {s = 1; next}
        /^[^[:space:]#]/ {s = 0; next}
        !s {next}
        /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {svc = $1; sub(/:$/, "", svc); dep = 0; next}
        /^    [A-Za-z_]+:/ {dep = ($1 == "depends_on:")}
        /^    network_mode:/ {if (match($0, /service:[A-Za-z0-9_.-]+/)) print svc, substr($0, RSTART + 8, RLENGTH - 8); next}
        dep && /^      [A-Za-z0-9_.-]+:[[:space:]]*$/ {d = $1; sub(/:$/, "", d); print svc, d; next}
        dep && /^      - [A-Za-z0-9_.-]+/ {print svc, $2; next}
    ' "$1"
}

soft_deps() {
    printf '%s\n' "traefik crowdsec" "traefik authentik"   # traefik-bouncer + authentik-forwardauth middlewares
    [[ "${CFG[TAILSCALE_CONTROL]}" == headscale ]] && printf '%s\n' "tailscale headscale"
    return 0
}

# check_dependencies -> "A needs B" for each enabled service whose dependency is not enabled
check_dependencies() {
    local f s a b
    local -A en=() ex=()
    f=$(compose_for_listing)
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        ex[$s]=1
        [[ "$(eff_state "$s")" == on ]] && en[$s]=1
    done < <(all_services)
    { [[ -n "$f" ]] && compose_deps "$f"; soft_deps; } | while read -r a b; do
        if [[ -n "${en[$a]:-}" && -n "${ex[$b]:-}" && -z "${en[$b]:-}" ]]; then printf '%s needs %s\n' "$a" "$b"; fi
    done | sort -u
    return 0
}

report_dependencies() {   # report_dependencies warn|die
    local deps l; deps=$(check_dependencies)
    [[ -z "$deps" ]] && return 0
    while IFS= read -r l; do log_warn "Dependency: $l"; done <<<"$deps"
    [[ "$1" == die ]] && die "Enable the missing services (Settings -> Services) or disable the ones that need them."
    return 0
}

# -----------------------------------------------------------------------------
# OVERRIDE FILE: add-ons, patches to upstream services, exclusions
# -----------------------------------------------------------------------------
render_addon() {   # render_addon NAME -> service body (4-space indented, no key line)
    case "$1" in
        audiobookshelf)
            cat <<'EOF'
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: audiobookshelf
    restart: unless-stopped
    networks:
      - mediastack
    user: ${PUID:?err}:${PGID:?err}           # ABS has no PUID/PGID env; run as the service account
    ports:
      - ${WEBUI_PORT_AUDIOBOOKSHELF:?err}:80
    volumes:
      - ${FOLDER_FOR_DATA:?err}/audiobookshelf/config:/config       # SQLite: keep on local disk
      - ${FOLDER_FOR_DATA:?err}/audiobookshelf/metadata:/metadata
      - ${FOLDER_FOR_MEDIA:?err}/media/audio:/audiobooks
      - ${FOLDER_FOR_MEDIA:?err}/media/podcasts:/podcasts
      - ${FOLDER_FOR_MEDIA:?err}/media/books:/books
    environment:
      - TZ=${TIMEZONE:?err}
    labels:
      - traefik.enable=true
    # ROUTERS (no Authentik forward-auth: ABS has its own login and its mobile apps use the API)
      - traefik.http.routers.audiobookshelf.service=audiobookshelf
      - traefik.http.routers.audiobookshelf.rule=Host(`audiobookshelf.${CLOUDFLARE_DNS_ZONE:?err}`)
      - traefik.http.routers.audiobookshelf.entrypoints=secureweb
      - traefik.http.routers.audiobookshelf.middlewares=security-headers@file,traefik-bouncer@file
    # SERVICES
      - traefik.http.services.audiobookshelf.loadbalancer.server.scheme=http
      - traefik.http.services.audiobookshelf.loadbalancer.server.port=80
EOF
            ;;
    esac
}

render_patch() {   # render_patch NAME -> body that changes an upstream service
    case "$1" in
        homarr)
            cat <<'EOF'
    # Homarr 1.x (homarr-labs) replaces the legacy ghcr.io/ajnart/homarr image used upstream
    image: ghcr.io/homarr-labs/homarr:latest
    volumes: !override
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${FOLDER_FOR_DATA:?err}/homarr/appdata:/appdata
    environment: !override
      - PUID=${PUID:?err}
      - PGID=${PGID:?err}
      - TZ=${TIMEZONE:?err}
      - SECRET_ENCRYPTION_KEY=${SECRET_ENCRYPTION_KEY:?err}
EOF
            ;;
        gluetun)
            printf '    # Gluetun: server-list updates (VPN_SERVERS_UPDATE_PERIOD) / custom WireGuard endpoint\n    environment:\n'
            [[ -n "$(vpn_update_period)" ]] && printf '      - UPDATER_PERIOD=%s\n' "$(vpn_update_period)"
            if vpn_custom_wg_endpoint; then
                printf '      - WIREGUARD_ENDPOINT_IP=%s\n      - WIREGUARD_ENDPOINT_PORT=%s\n' "${CFG[VPN_ENDPOINT_IP]}" "${CFG[VPN_ENDPOINT_PORT]}"
            fi
            if [[ "${CFG[VPN_SERVICE_PROVIDER]}" == protonvpn && -n "${CFG[VPN_UPDATER_PROTON_EMAIL]}" ]]; then
                printf '      - UPDATER_PROTONVPN_EMAIL=%s\n' "${CFG[VPN_UPDATER_PROTON_EMAIL]}"
                printf '      - UPDATER_PROTONVPN_PASSWORD=${UPDATER_PROTONVPN_PASSWORD:-}\n'
            fi
            ;;
        tailscale)
            cat <<'EOF'
    # TAILSCALE_CONTROL=tailscale: official control server (upstream logs in to self-hosted Headscale)
    environment:
      - TS_EXTRA_ARGS=--hostname=exit-node --advertise-exit-node --advertise-routes=${LOCAL_SUBNET:?err},${DOCKER_SUBNET:?err}
EOF
            ;;
    esac
}

is_addon() { in_list "$1" "${ADDON_SERVICES[@]}"; }
active_addons() {   # add-ons not 'removed'
    local a; for a in "${ADDON_SERVICES[@]}"; do is_removed "$a" || printf '%s\n' "$a"; done
    return 0
}
active_patches() {   # upstream services this installer modifies
    local compose=$1
    [[ -f "$compose" ]] || return 0
    if grep -qE '^  homarr:[[:space:]]*$' "$compose" && ! is_removed homarr; then echo homarr; fi
    if grep -qE '^  gluetun:[[:space:]]*$' "$compose" && ! is_removed gluetun \
        && { [[ -n "$(vpn_update_period)" ]] || vpn_custom_wg_endpoint; }; then echo gluetun; fi
    if grep -qE '^  tailscale:[[:space:]]*$' "$compose" && ! is_removed tailscale \
        && [[ "${CFG[TAILSCALE_CONTROL]}" == tailscale ]]; then echo tailscale; fi
    return 0
}

render_override() {   # render_override COMPOSEFILE -> stdout
    local compose=$1 s
    local -a order=()
    local -A blk=()
    printf '%s\n' "$OVERRIDE_MARKER"
    printf '# Regenerated on every install/apply -- do not edit (a file without the marker line is left alone).\n'
    printf '# - add-on services defined by the installer (not part of upstream MediaStack)\n'
    printf '# - patches to upstream services (Homarr 1.x image, Tailscale control server, Gluetun server updates)\n'
    printf "# - disabled / removed services parked in the 'disabled' profile\n"
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        order+=("$s"); blk[$s]="$(render_addon "$s")"$'\n'
    done < <(active_addons)
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        order+=("$s"); blk[$s]="$(render_patch "$s")"$'\n'
    done < <(active_patches "$compose")
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        if is_addon "$s"; then is_removed "$s" && continue
        elif [[ -f "$compose" ]] && ! grep -qE "^  ${s}:[[:space:]]*$" "$compose"; then
            printf '# %s: not found in docker-compose.yaml, ignored\n' "$s"; continue
        fi
        [[ -n "${blk[$s]+x}" ]] || order+=("$s")
        blk[$s]+="    profiles: [\"disabled\"]"$'\n'
    done < <(excluded_services)
    if (( ${#order[@]} == 0 )); then printf 'services: {}\n'; return 0; fi
    printf 'services:\n'
    for s in "${order[@]}"; do printf '  %s:\n%s' "$s" "${blk[$s]}"; done
    return 0
}

write_override() {
    local f="$FOLDER_FOR_YAML/docker-compose.override.yaml" compose="$FOLDER_FOR_YAML/docker-compose.yaml" body
    if [[ -f "$f" ]] && ! grep -qF "$OVERRIDE_MARKER" "$f"; then
        log_warn "$f exists and is not managed by this installer; leaving it alone (add-ons, patches and exclusions NOT applied)."
        return 0
    fi
    body=$(render_override "$compose")
    if [[ "$body" == *$'\nservices: {}' ]]; then
        [[ -f "$f" ]] && run rm -f "$f"
        log_ok "All upstream services enabled; no add-ons or patches"
        return 0
    fi
    printf '%s\n' "$body" | write_file "$f" 640 root:root
    log_ok "Add-ons: $(active_addons | xargs) | patches: $(active_patches "$compose" | xargs) | disabled: $( { disabled_services; forced_off; } | awk 'NF && !seen[$0]++' | xargs) | removed: ${CFG[REMOVED_SERVICES]:-none}"
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
    if [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME")" ]]; then
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
    for d in "${EXTRA_DATA_SUBDIRS[@]}"; do
        top=${d%%/*}
        (( ${#rem[@]} )) && in_list "$top" "${rem[@]}" && continue
        ddirs+=("$FOLDER_FOR_DATA/$d")
    done
    for d in "${MEDIA_SUBDIRS[@]}"; do mdirs+=("$FOLDER_FOR_MEDIA/$d"); done
    local a
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        for d in ${ADDON_DATA_DIRS[$a]:-};  do ddirs+=("$FOLDER_FOR_DATA/$d"); done
        for d in ${ADDON_MEDIA_DIRS[$a]:-}; do in_list "$FOLDER_FOR_MEDIA/$d" "${mdirs[@]}" || mdirs+=("$FOLDER_FOR_MEDIA/$d"); done
    done < <(active_addons)
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
    if [[ "$dty" != local ]] && has_line audiobookshelf "$(active_addons)"; then
        log_warn "Audiobookshelf keeps a SQLite DB in $FOLDER_FOR_DATA/audiobookshelf/config; its docs warn against network storage."
    fi
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
    if [[ "${CFG[VPN_SERVICE_PROVIDER]}" == custom && "${CFG[VPN_TYPE]}" == openvpn && -f "${CFG[VPN_CUSTOM_OVPN_FILE]}" \
          && -d "$FOLDER_FOR_DATA/gluetun" ]]; then
        put_file "${CFG[VPN_CUSTOM_OVPN_FILE]}" "$FOLDER_FOR_DATA/gluetun/${GLUETUN_OVPN_PATH#/gluetun/}" 600
        log_ok "Custom OpenVPN config placed for Gluetun ($GLUETUN_OVPN_PATH)"
    fi
    log_ok "App config files placed (traefik, headscale, headplane, crowdsec); acme.json 600"
}

# -----------------------------------------------------------------------------
# TLS CERTIFICATES FOR TRAEFIK
#   letsencrypt : upstream behaviour (ACME DNS-01 via Cloudflare)
#   selfsigned  : local CA in $MS_CONF_DIR/tls signs a wildcard leaf (renewed automatically)
#   manual      : your cert + key files, validated and re-copied on every apply
# -----------------------------------------------------------------------------
tls_dir()          { printf '%s/tls' "$MS_CONF_DIR"; }
traefik_cert_dir() { printf '%s/traefik/certs' "$FOLDER_FOR_DATA"; }
tls_zone()         { printf '%s' "${CFG[CLOUDFLARE_DNS_ZONE]:-${CFG[DOMAIN]}}"; }

tls_sans() {   # SAN list for the self-signed leaf
    local z ip; z=$(tls_zone); ip=$(eff_local_ip)
    printf 'DNS:%s,DNS:*.%s' "$z" "$z"
    valid_ipv4 "$ip" && printf ',IP:%s' "$ip"
    return 0
}

ensure_local_ca() {
    local d; d=$(tls_dir)
    [[ -s "$d/ca.key" && -s "$d/ca.crt" ]] && return 0
    if (( DRY_RUN )); then log_info "[dry-run] would create a local CA in $d"; return 0; fi
    mkdir -p "$d"; chmod 700 "$d"
    ( umask 077
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -sha384 -days 3650 \
          -keyout "$d/ca.key" -out "$d/ca.crt" \
          -subj "/CN=MediaStack Local CA ($(hostname -s 2>/dev/null || echo host))/O=mediastack-installer" \
          -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" ) >/dev/null 2>&1 \
        || die "Creating the local CA failed (openssl)."
    chmod 600 "$d/ca.key"; chmod 644 "$d/ca.crt"
    log_ok "Local CA created: $d/ca.crt -- import it on your devices to trust the self-signed certificates"
}

issue_leaf() {   # issue_leaf OUTDIR -> OUTDIR/cert.pem (leaf + CA) and key.pem
    local out=$1 d tmp; d=$(tls_dir)
    tmp=$(mktemp -d)
    if ! ( umask 077
           openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$tmp/key.pem" \
               -out "$tmp/req.csr" -subj "/CN=$(tls_zone)" &&
           printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' \
               "$(tls_sans)" >"$tmp/ext" &&
           openssl x509 -req -in "$tmp/req.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -set_serial "0x$(openssl rand -hex 15)" \
               -days 397 -sha256 -extfile "$tmp/ext" -out "$tmp/leaf.pem" ) >/dev/null 2>&1; then
        rm -rf "$tmp"; die "Issuing the self-signed certificate failed (openssl)."
    fi
    cat "$tmp/leaf.pem" "$d/ca.crt" >"$out/cert.pem"; chmod 644 "$out/cert.pem"
    install -m 600 "$tmp/key.pem" "$out/key.pem"
    rm -rf "$tmp"
}

leaf_needs_reissue() {   # leaf_needs_reissue CERT -> 0 when missing, expiring, re-scoped or not from our CA
    local c=$1
    [[ -s "$c" && -s "$(dirname "$c")/key.pem" ]] || return 0
    openssl x509 -in "$c" -noout -checkend 2592000 >/dev/null 2>&1 || return 0
    [[ "$(state_get tls_sans)" == "$(tls_sans)" ]] || return 0
    openssl verify -CAfile "$(tls_dir)/ca.crt" "$c" >/dev/null 2>&1 || return 0
    return 1
}

key_is_encrypted() {   # PKCS#8 "ENCRYPTED PRIVATE KEY" or traditional "Proc-Type: 4,ENCRYPTED"
    grep -qE -- '-----BEGIN ENCRYPTED PRIVATE KEY-----|^Proc-Type: *4,ENCRYPTED' "$1" 2>/dev/null
}

# tls_key_plain KEYFILE [PASSPHRASE] -> unencrypted PEM key on stdout (passphrase via fd, never argv)
tls_key_plain() {
    local k=$1 pass=${2-${SECRETS[TLS_KEY_PASSPHRASE]:-}}
    if key_is_encrypted "$k"; then
        [[ -n "$pass" ]] || return 2
        openssl pkey -in "$k" -passin fd:3 3<<<"$pass" 2>/dev/null
    else
        openssl pkey -in "$k" 2>/dev/null
    fi
}

tls_validate_pair() {   # tls_validate_pair CERT KEY -> 0 if usable (warnings for minor issues)
    local c=$1 k=$2 kp d ord rc=0 leaf z san i=0 f n first
    [[ -r "$c" && -r "$k" ]] || { log_error "Cannot read $c / $k"; return 1; }
    kp=$(tls_key_plain "$k" | openssl pkey -pubout 2>/dev/null) || kp=""
    if [[ -z "$kp" ]]; then
        if key_is_encrypted "$k"; then
            log_error "$k is encrypted and the stored passphrase is missing or wrong (Settings -> Access/certs, or Secrets -> TLS_KEY_PASSPHRASE)"
        else
            log_error "$k is not a readable PEM private key"
        fi
        return 1
    fi
    d=$(mktemp -d)
    ord=$(tls_chain_order "$c" "$kp" "$d") || rc=$?
    n=$(grep -c -- '-----END CERTIFICATE-----' "$c" 2>/dev/null || true)
    if (( rc == 2 )); then rm -rf "$d"; log_error "$c contains no PEM certificate"; return 1; fi
    if (( rc == 1 )); then rm -rf "$d"; log_error "The private key matches none of the $n certificate(s) in $c"; return 1; fi
    leaf=$(head -n1 <<<"$ord"); first="$d/cert-001.pem"
    log_info "Certificate chain ($n):"
    while IFS= read -r f; do
        i=$((i + 1))
        log_info "  $i) $(cert_field subject "$f")   <- issued by $(cert_field issuer "$f")"
    done <<<"$ord"
    [[ "$leaf" == "$first" ]] || log_warn "The server certificate was not first; it is put first when installed."
    if (( n == 1 )) && [[ "$(cert_field subject "$leaf")" != "$(cert_field issuer "$leaf")" ]]; then
        log_warn "Only the server certificate is present; add the intermediate certificate(s) or some clients will reject it."
    fi
    if ! openssl x509 -in "$leaf" -noout -checkend 0 >/dev/null 2>&1; then rm -rf "$d"; log_error "The certificate has expired"; return 1; fi
    openssl x509 -in "$leaf" -noout -checkend 1209600 >/dev/null 2>&1 || log_warn "The certificate expires within 14 days"
    z=$(tls_zone)
    san=$(openssl x509 -in "$leaf" -noout -ext subjectAltName 2>/dev/null || true)
    if [[ -n "$z" && "$san" != *"DNS:*.$z"* ]]; then
        log_warn "The certificate has no DNS:*.$z entry; app hostnames such as sonarr.$z will not match it."
    fi
    rm -rf "$d"
    return 0
}

# -----------------------------------------------------------------------------
# VPN (Gluetun): settings checks, custom configs, start diagnostics
# -----------------------------------------------------------------------------
GLUETUN_PROVIDERS=( airvpn cyberghost expressvpn fastestvpn giganews hidemyass ipvanish ivpn mullvad nordvpn
                    "perfect privacy" privado "private internet access" privatevpn protonvpn purevpn slickvpn
                    surfshark torguard vpnsecure "vpn unlimited" vyprvpn wevpn windscribe custom )
vpn_dir() { printf '%s/vpn' "$MS_CONF_DIR"; }
readonly GLUETUN_OVPN_PATH="/gluetun/custom.ovpn"

# vpn_problems -> one line per reason Gluetun cannot connect with the current settings
vpn_problems() {
    svc_enabled gluetun || return 0
    local p=${CFG[VPN_SERVICE_PROVIDER]:-} f=${CFG[VPN_CUSTOM_OVPN_FILE]:-}
    [[ -n "$p" ]] || echo "VPN_SERVICE_PROVIDER is not set"
    local fk
    for fk in SERVER_REGIONS SERVER_COUNTRIES SERVER_CITIES SERVER_HOSTNAMES; do
        validate_key "$fk" "${CFG[$fk]:-}" || echo "$fk '${CFG[$fk]}' is not a list of names (clear it in Settings -> VPN)"
    done
    if [[ "$p" == protonvpn && -n "${CFG[VPN_UPDATER_PROTON_EMAIL]:-}" ]] && ! secret_is_set UPDATER_PROTONVPN_PASSWORD; then
        echo "VPN_UPDATER_PROTON_EMAIL is set but UPDATER_PROTONVPN_PASSWORD is not (Settings -> VPN or the Secrets menu)"
    fi
    if [[ "${CFG[VPN_TYPE]}" == wireguard ]]; then
        secret_is_set WIREGUARD_PRIVATE_KEY || echo "WIREGUARD_PRIVATE_KEY is not set (import your provider's wg0.conf)"
        [[ -n "${CFG[WIREGUARD_ADDRESSES]:-}" ]] || echo "WIREGUARD_ADDRESSES is not set (the Address line of your wg0.conf)"
        if [[ "$p" == custom ]] && [[ -z "${CFG[VPN_ENDPOINT_IP]:-}" || -z "${CFG[VPN_ENDPOINT_PORT]:-}" || -z "${CFG[WIREGUARD_PUBLIC_KEY]:-}" ]]; then
            echo "provider 'custom' + WireGuard needs the server endpoint and public key (import your wg0.conf)"
        fi
    elif [[ "$p" == custom ]]; then
        if [[ -z "$f" || ! -f "$f" ]]; then
            echo "provider 'custom' + OpenVPN needs your .ovpn file"
        elif grep -qE '^[[:space:]]*auth-user-pass' "$f" && ! { secret_is_set VPN_USERNAME && secret_is_set VPN_PASSWORD; }; then
            echo "the .ovpn uses auth-user-pass but VPN_USERNAME / VPN_PASSWORD are not set"
        fi
    elif [[ -n "$p" ]] && ! { secret_is_set VPN_USERNAME && secret_is_set VPN_PASSWORD; }; then
        echo "VPN_USERNAME / VPN_PASSWORD are not set (most providers use separate OpenVPN/service credentials, not your account login)"
    fi
    [[ -e /dev/net/tun ]] || echo "/dev/net/tun is missing on this host (load the tun module: modprobe tun)"
    return 0
}

vpn_dependents() {   # enabled services that run behind / depend on gluetun
    local f a b; f=$(compose_for_listing)
    [[ -n "$f" ]] || return 0
    compose_deps "$f" | while read -r a b; do
        if [[ "$b" == gluetun && "$(eff_state "$a")" == on ]]; then echo "$a"; fi
    done | sort -u
}

vpn_preflight() {
    local probs l n
    probs=$(vpn_problems)
    [[ -z "$probs" ]] && return 0
    n=$(vpn_dependents | wc -l)
    log_warn "Gluetun (the VPN that $n app(s) run behind) cannot connect with the current settings:"
    while IFS= read -r l; do log_warn "  - $l"; done <<<"$probs"
    log_info "Fix: Settings -> 8) VPN / email (and the Secrets menu). Without a VPN at all, choose the"
    log_info "no-download-vpn variant (Settings -> 9) or set the apps that need Gluetun to disabled."
    if is_tty && ! (( ASSUME_YES )) && confirm "Start anyway (Gluetun stays unhealthy and those apps are skipped)?" n; then return 0; fi
    die "Not started: VPN settings incomplete."
}

# vpn_log_hints TEXT -> likely causes for a Gluetun log excerpt
vpn_log_hints() {   # vpn_log_hints "LOG LINES" -> one hint per recognised cause (each line judged on its own)
    local line
    while IFS= read -r line; do [[ -n "$line" ]] && vpn_line_hints "$line"; done <<<"$1" | awk '!seen[$0]++'
    return 0
}
vpn_line_hints() {
    local l=${1,,}
    [[ "$l" =~ auth_failed|auth.*fail|authentication\ fail|wrong\ (username|password) ]] && \
        echo "The VPN rejected the username/password. Many providers use separate OpenVPN/service credentials (e.g. NordVPN 'service credentials', Surfshark 'manual setup'); set them in the Secrets menu."
    if [[ "$l" =~ target\ ip\ address\ not\ found|endpoint\ ip\ is\ not\ set ]]; then
        echo "A fixed server endpoint (VPN_ENDPOINT_IP/PORT) only works with provider 'custom'. For a listed provider it must be blank (Apply blanks it now); choose servers with SERVER_COUNTRIES/CITIES/HOSTNAMES."
    elif [[ "$l" =~ provider\ custom.*(country|region|city|hostname).*not\ valid ]]; then
        echo "Provider 'custom' has no server list, so server filters (countries/cities/hostnames/regions) must be blank. Apply now leaves them out for 'custom'."
    elif [[ "$l" =~ server\ selection|no\ server|server.*not\ found|no\ .*server.*match|(region|country|city|hostname).*not\ valid ]]; then
        echo "No server matches the server filter. Clear or correct the filters (Settings -> VPN), or update Gluetun's server list (Post-install helpers -> 5)."
        [[ "$l" =~ region.*no\ possible\ value ]] && echo "This provider has no regions in Gluetun: leave SERVER_REGIONS blank and use SERVER_COUNTRIES."
    elif [[ "$l" =~ provider.*(not\ valid|invalid|unknown)|vpn_service_provider ]]; then
        echo "VPN_SERVICE_PROVIDER is not a Gluetun provider name (see the list in Settings -> VPN)."
    fi
    [[ "$l" =~ custom.*config|openvpn_custom_config|\.ovpn ]] && \
        echo "The custom OpenVPN config could not be used; check the .ovpn (Settings -> VPN)."
    [[ "$l" =~ wireguard.*(private\ key|public\ key|address|preshared)|(private|public)\ key.*(not\ valid|invalid|malformed)|interface\ address ]] && \
        echo "Gluetun rejected a WireGuard value (key or address): re-import the provider's wg0.conf (Settings -> VPN)."
    [[ "$l" =~ /dev/net/tun|tun\ device ]] && \
        echo "The TUN device is unavailable: run 'modprobe tun' on the host (and add 'tun' to /etc/modules)."
    [[ "$l" =~ tls\ key\ negotiation|tls\ handshake|connection\ timed\ out|no\ route\ to\ host|network\ is\ unreachable ]] && \
        echo "The VPN server could not be reached: the firewall may block outbound UDP/TCP to it; try another server/protocol."
    if [[ "$l" =~ healthcheck|unhealthy|handshake ]] && [[ ! "$l" =~ auth_failed|server\ selection|not\ valid|invalid ]]; then
        if [[ "${CFG[VPN_SERVICE_PROVIDER]:-}" == custom ]]; then
            echo "The tunnel is set up but passes no traffic (with WireGuard: the handshake never completes). Usual causes: a firewall or Docker NAT problem for UDP from containers, a wrong server key/endpoint, or a revoked key."
        else
            echo "The tunnel is set up but passes no traffic (with WireGuard: the handshake never completes). Usual causes: the servers Gluetun picks do not accept the key (ProtonVPN free plan: only free servers do, so set FREE_ONLY=on in .env), a firewall blocking outbound UDP to port 51820, a revoked key, or an outdated server list (Post-install helpers -> 5)."
        fi
    fi
    return 0
}

# vpn_normalize -- endpoint/public key only apply to provider 'custom'
vpn_normalize() {
    [[ "${CFG[VPN_SERVICE_PROVIDER]:-}" == custom ]] && return 0
    CFG[VPN_ENDPOINT_IP]=""; CFG[VPN_ENDPOINT_PORT]=""; CFG[WIREGUARD_PUBLIC_KEY]=""
}
# wg_addresses_usable LIST -> the IPv4 entries (all entries when there is no IPv4 one)
wg_addresses_usable() {
    local a out="" x
    for x in ${1//,/ }; do [[ "$x" == *:* ]] || out+="${out:+,}$x"; done
    [[ -n "$out" ]] && a=$out || a=$1
    printf '%s' "$a"
}
vpn_custom_wg_endpoint() {
    [[ "${CFG[VPN_SERVICE_PROVIDER]:-}" == custom && "${CFG[VPN_TYPE]:-}" == wireguard && -n "${CFG[VPN_ENDPOINT_IP]:-}" ]]
}
# vpn_update_period -> UPDATER_PERIOD value, blank when periodic updates are off/impossible
vpn_update_period() {
    local p=${CFG[VPN_SERVERS_UPDATE_PERIOD]:-off}
    [[ "$p" == off || "${CFG[VPN_SERVICE_PROVIDER]:-}" == custom || -z "${CFG[VPN_SERVICE_PROVIDER]:-}" ]] && return 0
    # ProtonVPN only serves its server list to logged-in accounts
    [[ "${CFG[VPN_SERVICE_PROVIDER]}" == protonvpn && -z "${CFG[VPN_UPDATER_PROTON_EMAIL]}" ]] && return 0
    printf '%s' "$p"
}
gluetun_image() {
    local img=""
    [[ -f "$FOLDER_FOR_YAML/docker-compose.yaml" ]] && \
        img=$(awk '/^  gluetun:[[:space:]]*$/ {f = 1; next} f && /^  [a-z]/ {exit} f && $1 == "image:" {print $2; exit}' "$FOLDER_FOR_YAML/docker-compose.yaml")
    printf '%s' "${img:-qmcgaw/gluetun:latest}"
}

# vpn_check -- on-demand VPN diagnosis (settings, Gluetun health, log errors with hints, WireGuard state)
vpn_check() {
    require_config; resolve_runtime; load_secrets
    log_step "VPN check (${CFG[VPN_SERVICE_PROVIDER]:-?} / ${CFG[VPN_TYPE]})"
    local probs l st lg ex
    probs=$(vpn_problems)
    if [[ -n "$probs" ]]; then while IFS= read -r l; do log_warn "Settings: $l"; done <<<"$probs"; else log_ok "Settings complete"; fi
    docker_up || die "Docker is not running."
    st=$(docker inspect -f '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' gluetun 2>/dev/null || echo "not created")
    log_info "Gluetun: $st"
    lg=$(docker logs --tail 300 gluetun 2>&1 || true)
    ex=$(grep -E '(^|[[:space:]])(ERROR|WARN|FATAL)[[:space:]]' <<<"$lg" | tail -n 12 || true)
    [[ -n "$ex" ]] && { log_info "Recent errors/warnings:"; printf '%s\n' "$ex" | sed 's/^/    /'; }
    while IFS= read -r l; do [[ -n "$l" ]] && log_warn "$l"; done <<<"$(vpn_log_hints "${ex:-$(tail -n 20 <<<"$lg")}")"
    vpn_wg_probe
    [[ "$st" == *healthy* && "$st" != *unhealthy* ]] && log_ok "Gluetun is healthy"
    return 0
}

# vpn_update_servers -- refresh Gluetun's server list now (CLI updater, outside the tunnel), restart Gluetun
vpn_update_servers() {
    require_config; resolve_runtime; load_secrets
    local p=${CFG[VPN_SERVICE_PROVIDER]} img e="" pw=""
    [[ -n "$p" && "$p" != custom ]] || die "Server-list updates apply to listed providers, not '${p:-<unset>}'."
    docker_up || die "Docker is not running."
    img=$(gluetun_image)
    if [[ "$p" == protonvpn ]]; then
        e=${CFG[VPN_UPDATER_PROTON_EMAIL]}; pw=${SECRETS[UPDATER_PROTONVPN_PASSWORD]:-}
        if [[ -z "$e" || -z "$pw" ]]; then
            is_tty || die "ProtonVPN needs account credentials to download its server list (Settings -> VPN)."
            log_info "ProtonVPN serves its server list only to a logged-in account (a free account is enough for free servers)."
            ask e "Proton account email" "$e"; ask_secret pw "Proton account password"
            [[ -n "$e" && -n "$pw" ]] || die "Both are required."
        fi
    fi
    log_step "Updating Gluetun's $p server list"
    log_warn "This runs outside the VPN: your public IP is visible to the provider's API and the DNS-over-HTTPS resolver."
    if (( DRY_RUN )); then run docker run --rm -v "$FOLDER_FOR_DATA/gluetun:/gluetun" "$img" update -providers "$p"; return 0; fi
    install -d "$FOLDER_FOR_DATA/gluetun"
    # credentials travel as environment variables, never on this host's docker command line
    if ! PE=$e PP=$pw run_logged docker run --rm -e PE -e PP -e PROV="$p" -v "$FOLDER_FOR_DATA/gluetun:/gluetun" \
            --entrypoint /bin/sh "$img" -c 'set -- update -providers "$PROV"
                [ -n "$PE" ] && set -- "$@" -proton-email "$PE" -proton-password "$PP"
                exec /gluetun-entrypoint "$@"'; then
        die "The server-list update failed (see above)."
    fi
    log_ok "Server list updated in $FOLDER_FOR_DATA/gluetun/servers.json"
    if docker ps -q --filter 'name=^gluetun$' | grep -q .; then
        run docker restart gluetun >/dev/null && log_ok "Gluetun restarted with the new list"
    fi
}

# wg_dump_eval DUMP -> "PUBKEY ENDPOINT HANDSHAKE RX TX PEERKEY LISTENPORT" from 'wg show all dump' (first interface + first peer)
wg_dump_eval() {
    awk -F'\t' 'NF == 5 && !ifc {ifc = $1; pub = $3; lp = $4; next}
                 NF >= 9 && $1 == ifc && !done {print pub, $4, $6, $7, $8, $2, lp; done = 1}' <<<"$1"
}

# docker_egress_test [NETWORK] -> ok | fail | unknown : can a throwaway container on NETWORK reach the internet?
docker_egress_test() {
    local out net=${1:-bridge}
    out=$(timeout 30 docker run --rm --network "$net" --entrypoint /bin/sh "$(gluetun_image)" -c \
          'command -v nslookup >/dev/null || { echo unknown; exit 0; }; nslookup github.com 1.1.1.1 >/dev/null 2>&1 && echo ok || echo fail' 2>/dev/null | tail -n1)
    printf '%s' "${out:-unknown}"
}

# vpn_wg_probe -- read WireGuard's own state inside Gluetun's network namespace (handshake, bytes)
vpn_wg_probe() {
    [[ "${CFG[VPN_TYPE]}" == wireguard ]] || return 0
    local pid dump r pub ep hs rx tx peer lport i eg
    if ! command -v wg >/dev/null 2>&1; then
        log_info "Install wireguard-tools on the host (apt-get install wireguard-tools) to see Gluetun's WireGuard handshake state here."
        return 0
    fi
    pid=$(docker inspect -f '{{.State.Pid}}' gluetun 2>/dev/null || echo 0)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { log_info "Gluetun is not running, so its WireGuard state cannot be read."; return 0; }
    log_info "Watching Gluetun's WireGuard interface for up to 15 s..."
    for (( i = 0; i < 8; i++ )); do
        dump=$(nsenter -t "$pid" -n wg show all dump 2>/dev/null || true)
        r=$(wg_dump_eval "$dump")
        read -r pub ep hs rx tx peer lport <<<"$r"
        [[ -n "$hs" && "$hs" != 0 ]] && break
        sleep 2
    done
    if [[ -z "$r" ]]; then log_info "No WireGuard interface found in Gluetun (it may be between restarts)."; return 0; fi
    log_info "Gluetun WireGuard: interface public key $pub, server $ep (server key $peer), source port ${lport:-?}, sent ${tx:-0} B, received ${rx:-0} B, handshake $([[ "$hs" != 0 ]] && date -d "@$hs" '+%T' || echo never)"
    if [[ "$hs" == 0 ]]; then
        log_warn "No WireGuard handshake from inside Gluetun (sent handshake requests, no answer)."
        log_warn "  1) Interface public key: compare with the 'public key' 'wg show' printed for a working config;"
        log_warn "     different -> re-import the working wg0.conf (Settings -> VPN, answer y to replace)."
        log_warn "  2) Server key: must equal [Peer] PublicKey in that wg0.conf."
        local snet sbr eg2 nroutes sub
        sub=$(stack_subnet)
        nroutes=$(ip -4 route show 2>/dev/null | grep -c "^${sub%/*}/" || true)
        if [[ -n "$sub" ]] && (( nroutes > 1 )); then
            log_warn "  3) The host has $nroutes routes for the stack's subnet $sub (two Docker networks share it):"
            ip -4 route show 2>/dev/null | grep "^${sub%/*}/" | sed 's/^/       /'
            log_warn "     The server's answers are routed to the wrong bridge (a 'linkdown' route still counts). Run Apply: it removes"
            log_warn "     the duplicate network or orphaned bridge."
            return 0
        fi
        snet=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' gluetun 2>/dev/null | awk '{print $1}')
        log_info "Testing whether containers can reach the internet (DNS to 1.1.1.1 from throwaway containers)..."
        eg=$(docker_egress_test bridge)
        eg2=unknown
        [[ -n "$snet" && "$snet" != bridge ]] && eg2=$(docker_egress_test "$snet")
        if [[ "$eg" == ok && "$eg2" == fail ]]; then
            sbr="br-$(docker network inspect -f '{{.Id}}' "$snet" 2>/dev/null | cut -c1-12)"
            log_warn "  3) Containers on Docker's default bridge (docker0) reach the internet, but containers on the stack's network"
            log_warn "     '$snet' (host interface $sbr) do not: replies come back to the host and are not forwarded to $sbr."
            log_warn "     This is a HOST FIREWALL rule that allows docker0 only. Allow forwarding for Docker's bridges, e.g. in nftables:"
            log_warn "       iifname \"br-*\" accept; oifname \"br-*\" ct state established,related accept"
            log_warn "     Find it with: sudo nft list ruleset | grep -nE 'hook forward|policy|docker0|br-'"
            return 0
        fi
        [[ "$eg2" == fail ]] && eg=fail
        case "$eg" in
            fail) log_warn "  3) Containers on Docker's bridge cannot reach the internet: Docker forwarding/NAT on this host is broken, not the VPN."
                  log_warn "     Check: sysctl net.ipv4.ip_forward (must be 1); sudo iptables -t nat -S | grep MASQUERADE (Docker's NAT rule);"
                  log_warn "     a host nftables/firewall forward chain dropping docker0 traffic; then: sudo systemctl restart docker" ;;
            ok)   log_warn "  3) Other containers (also on the stack's network) reach the internet, so Docker NAT works. Watch where the handshake goes:"
                  if [[ -n "$lport" && "$lport" == "${ep##*:}" ]]; then
                      log_warn "     Gluetun sends FROM UDP port $lport (the same as the server port). If your router/firewall forwards inbound"
                      log_warn "     UDP $lport (e.g. its own WireGuard server or a port forward), or rewrites the source port, the server's answer"
                      log_warn "     never reaches Gluetun. A host test with wg-quick uses a random source port, which is why it works."
                  fi
                  log_warn "     sudo tcpdump -ni any udp and host ${ep%:*}   (requests should leave on the veth/br- AND your LAN interface, and the"
                  log_warn "     answers (92 bytes) should come back the same way; answers that arrive on the LAN interface but never appear on the"
                  log_warn "     br-/veth interface are dropped by this host's firewall/conntrack)"
                  log_warn "     Leaves the LAN interface without answers -> a firewall between this host and the internet treats NATed container"
                  log_warn "     UDP differently from the host's own (e.g. per-port rules, or a policy only allowing the host's WireGuard port)." ;;
            *)    log_info "  3) Could not test container egress here; run: docker run --rm alpine nslookup github.com 1.1.1.1" ;;
        esac
    elif [[ "${rx:-0}" -gt 0 ]]; then
        log_warn "WireGuard is connected (handshake and data), so the failure is above it: Gluetun's DNS (DNS over TLS, port 853) or its health-check targets. Read: sudo $MS_INSTALL_BIN --logs 200 gluetun"
    fi
}

diagnose_start_failure() {
    log_step "Why containers did not start"
    local bad lg ex hints
    bad=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Names}}\t{{.Status}}' 2>/dev/null \
          | awk -F'\t' '$2 !~ /^Up/ || $2 ~ /unhealthy/' || true)
    [[ -n "$bad" ]] && printf '%s\n' "$bad" | sed 's/^/    /' | head -n 20
    if [[ -n "$(docker ps -aq --filter name='^gluetun$' 2>/dev/null)" ]] && \
       [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' gluetun 2>/dev/null)" != healthy ]]; then
        lg=$(docker logs --tail 200 gluetun 2>&1 || true)
        # Gluetun's own level field only: words like "failure"/"Authentication" also occur in its settings dump
        ex=$(grep -E '(^|[[:space:]])(ERROR|WARN|FATAL)[[:space:]]' <<<"$lg" | tail -n 12 || true)
        if [[ -n "$ex" ]]; then
            log_info "Gluetun log (last errors/warnings):"
            printf '%s\n' "$ex" | sed 's/^/    /'
        fi
        hints=$(vpn_log_hints "${ex:-$(tail -n 20 <<<"$lg")}")
        vpn_wg_probe
        if [[ -n "$hints" ]]; then
            while IFS= read -r ex; do log_warn "$ex"; done <<<"$hints"
        else
            log_info "No known cause matched; read the full log: sudo $MS_INSTALL_BIN --logs 200 gluetun"
        fi
    fi
    return 0
}

# wg_import FILE -- take PrivateKey/Address (+ PublicKey/Endpoint/PresharedKey) from a wg0.conf
wg_import() {
    local f=$1 pk addr pub psk ep host port ip
    pk=$(wg_value Interface PrivateKey "$f"); addr=$(wg_value Interface Address "$f")
    pub=$(wg_value Peer PublicKey "$f"); psk=$(wg_value Peer PresharedKey "$f"); ep=$(wg_value Peer Endpoint "$f")
    [[ -n "$pk" && -n "$addr" ]] || { log_error "No [Interface] PrivateKey/Address found; is this a WireGuard config?"; return 1; }
    SECRETS[WIREGUARD_PRIVATE_KEY]=$pk; SECRETS_DIRTY=1
    SECRETS[WIREGUARD_PRESHARED_KEY]=$psk   # blank when the new config has none (clears an old one)
    addr=${addr// /}
    if [[ "$(wg_addresses_usable "$addr")" != "$addr" ]]; then
        log_info "Address $addr: Docker gives Gluetun no IPv6 by default, so only $(wg_addresses_usable "$addr") is used."
    fi
    CFG[WIREGUARD_ADDRESSES]=$addr
    if [[ "${CFG[VPN_SERVICE_PROVIDER]}" == custom ]]; then
        [[ -n "$pub" && -n "$ep" ]] || { log_error "A custom WireGuard server needs [Peer] PublicKey and Endpoint"; return 1; }
        host=${ep%:*}; port=${ep##*:}; host=${host#[}; host=${host%]}
        if valid_ipv4 "$host"; then ip=$host
        else ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}' || true)
             [[ -n "$ip" ]] || { log_error "Cannot resolve the endpoint host '$host'"; return 1; }
             log_warn "Endpoint $host resolved to $ip; Gluetun needs an IP, so update it if the server's address changes."
        fi
        CFG[VPN_ENDPOINT_IP]=$ip; CFG[VPN_ENDPOINT_PORT]=$port; CFG[WIREGUARD_PUBLIC_KEY]=$pub
    else
        vpn_normalize
        [[ -n "$ep" ]] && log_info "Endpoint ${ep} is not used: Gluetun picks a ${CFG[VPN_SERVICE_PROVIDER]} server from its list (filters: countries/cities/hostnames)."
    fi
    log_ok "WireGuard settings imported (private key$( [[ -n "$psk" ]] && printf ' + preshared key') stored in the vault)"
}
wg_value() {   # wg_value SECTION KEY FILE
    awk -v s="[$1]" -v k="$2" '
        { line = $0; sub(/[#;].*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line) }
        line ~ /^\[.*\]$/ { cur = line; next }
        cur == s && index(line, "=") { key = substr(line, 1, index(line, "=") - 1); gsub(/[ \t]/, "", key)
            if (tolower(key) == tolower(k)) { v = substr(line, index(line, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }' "$3"
}

# pick_conf KIND CFGKEY STOREFILE -- path, or 'paste' (KIND: ovpn | wg)
pick_conf() {
    local kind=$1 key=$2 store=$3 v tmp label
    label=$([[ $kind == ovpn ]] && echo "OpenVPN config (.ovpn)" || echo "WireGuard config (wg0.conf)")
    while :; do
        ask v "$label: file path, or 'paste' to paste it" "${CFG[$key]:-paste}"
        tmp=$(mktemp); chmod 600 "$tmp"
        if [[ "${v,,}" == paste ]]; then
            if (( ASSUME_YES )) || ! is_tty; then rm -f "$tmp"; die "Pasting needs a terminal; give a file path instead."; fi
            log_info "Paste the $label. Input ends 3 seconds after the paste, or type END / press Ctrl-D:"
            read_paste "$tmp" 1
        elif v_file "$v"; then
            cat "$v" >"$tmp"
        else
            log_warn "Not an existing file (absolute path): '$v'"; rm -f "$tmp"; continue
        fi
        if [[ "$kind" == ovpn ]] && ! grep -qE '^[[:space:]]*remote[[:space:]]' "$tmp"; then
            log_error "No 'remote' line found; that is not an OpenVPN client config."; rm -f "$tmp"; continue
        fi
        if [[ "$kind" == wg ]]; then
            if wg_import "$tmp"; then rm -f "$tmp"; return 0; fi
            rm -f "$tmp"; continue
        fi
        if (( DRY_RUN )); then CFG[$key]=$tmp; log_info "[dry-run] would store it as $store"; return 0; fi
        mkdir -p "$(dirname "$store")"; chmod 700 "$(dirname "$store")"
        install -m 600 "$tmp" "$store"; rm -f "$tmp"
        CFG[$key]=$store
        log_ok "Stored in $store (copied to Gluetun as $GLUETUN_OVPN_PATH on apply)"
        return 0
    done
}

cfg_vpn() {
    section "VPN (Gluetun)"
    local v u
    log_info "Gluetun provider names: ${GLUETUN_PROVIDERS[*]}"
    ask_valid "CFG[VPN_TYPE]" "VPN type (openvpn/wireguard)" "${CFG[VPN_TYPE]}" v_vpn "openvpn or wireguard"
    while :; do
        ask v "VPN provider" "${CFG[VPN_SERVICE_PROVIDER]}"
        v=${v,,}
        if [[ -z "$v" ]]; then
            { (( ASSUME_YES )) || ! is_tty; } && die "VPN_SERVICE_PROVIDER is not set. Set it in $CONF_FILE or run interactively."
            log_warn "A provider is required (or 'custom' with your own config)"; continue
        fi
        in_list "$v" "${GLUETUN_PROVIDERS[@]}" || log_warn "'$v' is not in the provider list above; Gluetun will refuse it unless it is newer than this list."
        CFG[VPN_SERVICE_PROVIDER]=$v; break
    done
    [[ -f "$SECRETS_FILE" ]] && load_secrets || SECRETS_LOADED=1
    if [[ "${CFG[VPN_TYPE]}" == wireguard ]]; then
        log_info "WireGuard: download a wg0.conf for this host from your provider; the installer takes the"
        log_info "private key (vault), address$( [[ $v == custom ]] && printf ', server endpoint and public key') from it."
        if secret_is_set WIREGUARD_PRIVATE_KEY && [[ -n "${CFG[WIREGUARD_ADDRESSES]}" ]] && ! confirm "Replace the stored WireGuard settings?" n; then :
        elif is_tty && ! (( ASSUME_YES )); then
            pick_conf wg VPN_WG_IMPORT_UNUSED "" || true
        fi
    elif [[ "$v" == custom ]]; then
        log_info "Custom OpenVPN: give your provider's .ovpn client config (inline certificates are fine)."
        if is_tty && ! (( ASSUME_YES )); then pick_conf ovpn VPN_CUSTOM_OVPN_FILE "$(vpn_dir)/custom.ovpn"
        else ask_valid "CFG[VPN_CUSTOM_OVPN_FILE]" "OpenVPN config file" "${CFG[VPN_CUSTOM_OVPN_FILE]}" v_file "an existing file"; fi
    fi
    if [[ "${CFG[VPN_TYPE]}" == openvpn ]] && is_tty && ! (( ASSUME_YES )); then
        if [[ "$v" != custom ]] || grep -qE '^[[:space:]]*auth-user-pass' "${CFG[VPN_CUSTOM_OVPN_FILE]:-/dev/null}" 2>/dev/null; then
            log_info "OpenVPN credentials: most providers issue separate OpenVPN/service credentials (not your account login)."
            ask u "OpenVPN username" "$( secret_is_set VPN_USERNAME && printf '%s' "${SECRETS[VPN_USERNAME]}")"
            if [[ -n "$u" && "$u" != "${SECRETS[VPN_USERNAME]:-}" ]]; then SECRETS[VPN_USERNAME]=$u; SECRETS_DIRTY=1; fi
            secret_is_set VPN_PASSWORD && log_info "A password is stored; press Enter to keep it."
            ask_secret u "OpenVPN password"
            if [[ -n "$u" ]]; then SECRETS[VPN_PASSWORD]=$u; SECRETS_DIRTY=1; fi
        fi
    fi
    vpn_normalize
    local k lbl
    [[ "$v" == custom ]] && log_info "Provider 'custom' connects to the server in your config, so server filters are not used."
    [[ "$v" == custom ]] || log_info "Server filters (all optional, comma-separated; blank = any server of the provider):"
    for k in SERVER_COUNTRIES SERVER_CITIES SERVER_HOSTNAMES SERVER_REGIONS; do
        [[ "$v" == custom ]] && break
        case "$k" in
            SERVER_COUNTRIES) lbl="Countries (e.g. Switzerland,Netherlands)" ;;
            SERVER_CITIES)    lbl="Cities (e.g. Zurich)" ;;
            SERVER_HOSTNAMES) lbl="Server hostnames (e.g. ch-01.protonvpn.net)" ;;
            SERVER_REGIONS)   lbl="Regions (not every provider has regions; ProtonVPN has none)" ;;
        esac
        if ! validate_key "$k" "${CFG[$k]}"; then
            log_warn "Stored $k '${CFG[$k]}' is not a list of names (pasted text?); cleared."; CFG[$k]=""
        fi
        while :; do
            ask "CFG[$k]" "$lbl" "${CFG[$k]}"
            validate_key "$k" "${CFG[$k]}" && break
            log_warn "That is not a list of names."; CFG[$k]=""
        done
    done
    if [[ "$v" != custom ]]; then
        log_info "Gluetun ships a server list that ages; it can refresh it itself (through the VPN) every N hours."
        ask_valid "CFG[VPN_SERVERS_UPDATE_PERIOD]" "Update the server list every (e.g. 480h, min 360h; off)" "${CFG[VPN_SERVERS_UPDATE_PERIOD]}" v_period "off or hours such as 480h"
        if [[ "$v" == protonvpn && "${CFG[VPN_SERVERS_UPDATE_PERIOD]}" != off ]]; then
            log_info "ProtonVPN serves its server list only to a logged-in account (stored: email in the config, password in the vault)."
            ask_valid "CFG[VPN_UPDATER_PROTON_EMAIL]" "Proton account email (blank = no automatic updates)" "${CFG[VPN_UPDATER_PROTON_EMAIL]}" v_email_opt "an email address or blank"
            if [[ -n "${CFG[VPN_UPDATER_PROTON_EMAIL]}" ]]; then
                secret_is_set UPDATER_PROTONVPN_PASSWORD && log_info "A password is stored; press Enter to keep it."
                ask_secret u "Proton account password"
                if [[ -n "$u" ]]; then SECRETS[UPDATER_PROTONVPN_PASSWORD]=$u; SECRETS_DIRTY=1; fi
            fi
        fi
    fi
    local probs l; probs=$(vpn_problems)
    if [[ -n "$probs" ]]; then while IFS= read -r l; do log_warn "VPN: $l"; done <<<"$probs"; else log_ok "VPN settings complete"; fi
}


# traefik_static_no_acme FILE -- drop the ACME resolver and the entrypoint's certResolver/domains
traefik_static_no_acme() {
    yaml_edit "$1" '
        function ind(s) { match(s, /[^ ]/); return RSTART - 1 }
        skip >= 0 { if ($0 ~ /^[[:space:]]*(#.*)?$/) next; if (ind($0) > skip) next; skip = -1 }
        /^[[:space:]]*certResolver:[[:space:]]*letsencrypt/ {next}
        /^[[:space:]]*domains:[[:space:]]*$/ {skip = ind($0); next}
        /^certificatesResolvers:/ {skip = 0; next}
        {print}'
}

# traefik_dynamic_file_cert FILE -- serve /etc/traefik/certs/{cert,key}.pem (works with sniStrict)
traefik_dynamic_file_cert() {
    yaml_edit "$1" '
        function ind(s) { match(s, /[^ ]/); return RSTART - 1 }
        skip >= 0 { if ($0 ~ /^[[:space:]]*(#.*)?$/) next; if (ind($0) > skip) next; skip = -1 }
        /^tls:[[:space:]]*$/ {
            print
            print "  certificates:"
            print "    - certFile: /etc/traefik/certs/cert.pem"
            print "      keyFile: /etc/traefik/certs/key.pem"
            next
        }
        /^[[:space:]]*defaultGeneratedCert:[[:space:]]*$/ {
            i = ind($0); p = sprintf("%" i "s", "")
            print p "defaultCertificate:"
            print p "  certFile: /etc/traefik/certs/cert.pem"
            print p "  keyFile: /etc/traefik/certs/key.pem"
            skip = i; next
        }
        {print}'
}

yaml_edit() {   # yaml_edit FILE AWKPROGRAM  (in place, keeps mode/owner)
    local f=$1 tmp
    tmp=$(mktemp "$f.XXXXXX")
    awk -v skip=-1 "$2" "$f" >"$tmp" || { rm -f "$tmp"; die "Editing $f failed"; }
    chmod --reference="$f" "$tmp"; chown --reference="$f" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f"
}

tls_install_selfsigned() {   # tls_install_selfsigned OUTDIR -- local CA + leaf, reissued when needed
    local out=$1
    ensure_local_ca
    if (( DRY_RUN )); then log_info "[dry-run] would issue/refresh the self-signed certificate in $out"; return 0; fi
    install -d -m 2775 "$out"
    if leaf_needs_reissue "$out/cert.pem"; then
        issue_leaf "$out"; state_set tls_sans "$(tls_sans)"
        log_ok "Self-signed certificate issued for $(tls_sans) (397 days; renewed automatically 30 days before expiry)"
    else
        log_ok "Self-signed certificate current ($(openssl x509 -in "$out/cert.pem" -noout -enddate | cut -d= -f2))"
    fi
}

tls_install_pair() {   # tls_install_pair CERT KEY OUTDIR -- validate, then install chain (leaf first) + plain key
    local c=$1 k=$2 out=$3
    tls_validate_pair "$c" "$k" || die "The certificate ($c) failed validation."
    if (( DRY_RUN )); then log_info "[dry-run] would install $c into $out"; return 0; fi
    install -d -m 2775 "$out"
    tls_write_chain "$c" "$k" "$out/cert.pem.new" || { rm -f "$out/cert.pem.new"; die "Writing the certificate chain failed."; }
    chmod 644 "$out/cert.pem.new"
    ( umask 077; tls_key_plain "$k" >"$out/key.pem.new" ) || { rm -f "$out/key.pem.new" "$out/cert.pem.new"; die "Decrypting $k failed."; }
    chmod 600 "$out/key.pem.new"
    mv -f "$out/key.pem.new" "$out/key.pem"; mv -f "$out/cert.pem.new" "$out/cert.pem"
    key_is_encrypted "$k" && log_ok "Encrypted key decrypted with the vault passphrase (Traefik's copy is root-only, 0600)"
    log_ok "Certificate installed: $(cert_field subject "$out/cert.pem"), expires $(openssl x509 -in "$out/cert.pem" -noout -enddate | cut -d= -f2)"
}

# ensure_tls -- run after copy_app_configs (which re-copies the upstream Traefik templates)
ensure_tls() {
    svc_enabled traefik || return 0
    local mode=${CFG[CERT_MODE]:-letsencrypt} out
    out=$(traefik_cert_dir)
    log_step "TLS certificate ($mode)"
    case "$mode" in
        letsencrypt)
            log_ok "Let's Encrypt wildcard for $(tls_zone) via Cloudflare DNS-01 (issued by Traefik)"
            return 0 ;;
        selfsigned) tls_install_selfsigned "$out" ;;
        manual)
            [[ -n "${CFG[TLS_CERT_FILE]}" && -n "${CFG[TLS_KEY_FILE]}" ]] \
                || die "CERT_MODE=manual needs TLS_CERT_FILE and TLS_KEY_FILE (Settings -> Access and certificates)."
            tls_install_pair "${CFG[TLS_CERT_FILE]}" "${CFG[TLS_KEY_FILE]}" "$out" ;;
        fetch|push)
            if [[ "$mode" == fetch ]] && ! cert_fetch; then
                CERT_FETCH_FAILED=1
                [[ -n "$(cert_source_pair)" ]] && log_warn "Using the last fetched certificate."
            fi
            local pair c k; pair=$(cert_source_pair)
            if [[ -z "$pair" ]]; then
                log_warn "No $([[ "$mode" == push ]] && echo pushed || echo fetched) certificate yet: Traefik serves a temporary self-signed one until it arrives."
                tls_install_selfsigned "$out"
            else
                read -r c k <<<"$pair"
                tls_install_pair "$c" "$k" "$out"
            fi ;;
    esac
    local st="$FOLDER_FOR_DATA/traefik/traefik.yaml" dy="$FOLDER_FOR_DATA/traefik/dynamic.yaml"
    if [[ -f "$st" && -f "$dy" ]]; then
        traefik_static_no_acme "$st"
        traefik_dynamic_file_cert "$dy"
        log_ok "Traefik serves /etc/traefik/certs/cert.pem (ACME resolver removed from its config)"
    else
        log_warn "Traefik config files missing in $FOLDER_FOR_DATA/traefik; certificate not wired"
    fi
}

# -----------------------------------------------------------------------------
# CERTIFICATE PULL (CERT_MODE=fetch) and PUSH (CERT_MODE=push) -- same model as docker-dashboard
#   fetch: scp the pair from CERT_FETCH_SOURCE (e.g. OPNsense acme.sh) daily, via a systemd timer
#   push : another host streams "chain + key" on stdin to a forced SSH command:
#            cat fullchain.pem privkey.pem | ssh mscertpush@host
#          The push user's key may only run "sudo -n mediastack-installer --cert-receive", and sudoers
#          allows only that exact command. The last stdout line is machine-readable and uses the same
#          protocol as docker-dashboard, so the same deployer can push to both:
#            DD-CERT-RECEIVE OK changed|unchanged sha256=<FP> notafter=<DATE> live=yes|no|n/a
#            DD-CERT-RECEIVE FAIL <reason>
# -----------------------------------------------------------------------------
cert_fetch_dir()   { printf '%s/certs-fetched' "$MS_CONF_DIR"; }
cert_push_dir()    { printf '%s/certs-pushed' "$MS_CONF_DIR"; }
cert_fetch_keyf()  { printf '%s/certfetch_ed25519' "$MS_CONF_DIR"; }
cert_fetch_hosts() { printf '%s/certfetch_known_hosts' "$MS_CONF_DIR"; }
readonly PUSH_MAX_BYTES=65536
readonly UNIT_CERT="mediastack-cert"
readonly CERT_RECEIVE_TAG="DD-CERT-RECEIVE"
CERT_FETCH_FAILED=0

# cert_source_pair -> "CERT KEY" for the file-based modes (blank when none is available yet)
cert_source_pair() {
    local d
    case "${CFG[CERT_MODE]}" in
        manual) printf '%s %s' "${CFG[TLS_CERT_FILE]}" "${CFG[TLS_KEY_FILE]}" ;;
        fetch)  d=$(cert_fetch_dir); [[ -s "$d/fullchain.pem" && -s "$d/privkey.pem" ]] && printf '%s %s' "$d/fullchain.pem" "$d/privkey.pem" ;;
        push)   d=$(cert_push_dir);  [[ -s "$d/fullchain.pem" && -s "$d/privkey.pem" ]] && printf '%s %s' "$d/fullchain.pem" "$d/privkey.pem" ;;
    esac
    return 0
}

cert_fetch() {   # scp the pair from CERT_FETCH_SOURCE into $(cert_fetch_dir)
    local src=${CFG[CERT_FETCH_SOURCE]%/} dst t k
    dst=$(cert_fetch_dir); k=$(cert_fetch_keyf)
    [[ -n "$src" ]] || { log_error "CERT_FETCH_SOURCE is not set (Settings -> Access / certs)."; return 1; }
    [[ -f "$k" ]] || { log_error "No fetch key yet: Certificate menu -> create fetch key (or --cert-fetch-key)."; return 1; }
    if (( DRY_RUN )); then run scp "$src/${CFG[CERT_FETCH_CERT]}" "$src/${CFG[CERT_FETCH_KEY]}" "$dst/"; return 0; fi
    t=$(mktemp -d)
    if ! scp -q -i "$k" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$(cert_fetch_hosts)" "$src/${CFG[CERT_FETCH_CERT]}" "$src/${CFG[CERT_FETCH_KEY]}" "$t/" 2>"$t/err"; then
        log_error "Fetching the certificate from $src failed: $(tr '\n' ' ' <"$t/err")"
        rm -rf "$t"; return 1
    fi
    if key_is_encrypted "$t/${CFG[CERT_FETCH_KEY]}"; then
        rm -rf "$t"; log_error "The fetched private key is encrypted; fetch/push need an unencrypted key (use manual mode for encrypted keys)."; return 1
    fi
    install -d -m 700 "$dst"
    if cmp -s "$t/${CFG[CERT_FETCH_CERT]}" "$dst/fullchain.pem" && cmp -s "$t/${CFG[CERT_FETCH_KEY]}" "$dst/privkey.pem"; then
        rm -rf "$t"; log_ok "Fetched from $src (unchanged)"; return 0
    fi
    install -m 600 "$t/${CFG[CERT_FETCH_KEY]}" "$dst/privkey.pem.new"
    install -m 644 "$t/${CFG[CERT_FETCH_CERT]}" "$dst/fullchain.pem.new"
    mv -f "$dst/privkey.pem.new" "$dst/privkey.pem"; mv -f "$dst/fullchain.pem.new" "$dst/fullchain.pem"
    rm -rf "$t"
    log_ok "Certificate fetched from $src"
}

cert_fetch_key() {
    local k; k=$(cert_fetch_keyf)
    if [[ ! -f "$k" ]]; then
        install -d -m 700 "$MS_CONF_DIR"
        run ssh-keygen -q -t ed25519 -N "" -C "mediastack@$(hostname -s)" -f "$k"
        log_ok "Created $k"
    fi
    log_info "Public key -- add it to the account named in CERT_FETCH_SOURCE (OPNsense: System -> Access -> Users -> Authorized keys):"
    printf '\n    %s\n\n' "$(cat "$k.pub" 2>/dev/null)"
}

pem_split() {   # pem_split IN CRT_OUT KEY_OUT -> certificates (in order) and the one private key
    awk -v c="$2" -v k="$3" '
        /^-----BEGIN CERTIFICATE-----/                       { o = c; nc++ }
        /^-----BEGIN ([A-Z]+ )?(ENCRYPTED )?PRIVATE KEY-----/ { o = k; nk++ }
        o != ""                                              { print > o }
        /^-----END /                                         { o = "" }
        END { exit (nc >= 1 && nk == 1) ? 0 : 1 }' "$1"
}

tls_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'; }
tls_https_port() {
    local p=""
    [[ -n "$FOLDER_FOR_YAML" && -f "$FOLDER_FOR_YAML/.env" ]] && p=$(env_get "$FOLDER_FOR_YAML/.env" REVERSE_PROXY_PORT_HTTPS || true)
    [[ "$p" =~ ^[0-9]+$ ]] || p=443
    printf '%s' "$p"
}
# tls_probe_name -> SNI for local checks. Traefik uses strict SNI, so the name must be covered by the certificate:
# a host under the zone matches a wildcard (*.zone); the bare zone is often NOT in a wildcard certificate.
tls_probe_name() { printf 'mediastack-probe.%s' "$(tls_zone)"; }
tls_live_fp() {   # what Traefik serves right now
    echo | timeout 5 openssl s_client -connect "127.0.0.1:$(tls_https_port)" -servername "$(tls_probe_name)" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}
traefik_running() { have_docker && docker ps -q --filter 'name=^traefik$' 2>/dev/null | grep -q .; }

# tls_ensure_live -- make Traefik serve cert.pem: it reloads on a dynamic-config change; if it still
# serves something else, restart it. Prints yes | no | n/a (Traefik not running).
tls_ensure_live() {
    local want i
    { [[ "${CFG[CERT_MODE]}" != letsencrypt ]] && svc_enabled traefik && traefik_running; } || { echo n/a; return 0; }
    (( DRY_RUN )) && { echo n/a; return 0; }
    local live
    want=$(tls_fp "$(traefik_cert_dir)/cert.pem")
    [[ -n "$want" ]] || { echo no; return 0; }
    live=$(tls_live_fp)
    [[ "$live" == "$want" ]] && { echo yes; return 0; }
    log_info "Checking that Traefik serves the current certificate (up to ~45 s)..." >&2
    touch "$FOLDER_FOR_DATA/traefik/dynamic.yaml" 2>/dev/null || true     # file provider watch -> reload
    for (( i = 0; i < 10; i++ )); do
        sleep 1; live=$(tls_live_fp); [[ "$live" == "$want" ]] && { echo yes; return 0; }
    done
    if [[ -z "$live" ]]; then
        # no TLS answer at all: restarting would not help and only interrupts the apps
        log_warn "No TLS answer from Traefik on 127.0.0.1:$(tls_https_port) for $(tls_probe_name); not restarting it." >&2
        log_warn "Check: sudo $MS_INSTALL_BIN --logs 50 traefik" >&2
        echo unknown; return 0
    fi
    log_info "Traefik still serves another certificate; restarting it" >&2
    docker restart traefik </dev/null >/dev/null 2>&1 3>&- 9>&- || true   # no inherited fds (ssh channel, lock)
    for (( i = 0; i < 30; i++ )); do sleep 1; [[ "$(tls_live_fp)" == "$want" ]] && { echo yes; return 0; }; done
    echo no
}

cert_receive_fail() { printf '%s FAIL %s\n' "$CERT_RECEIVE_TAG" "$*" >&3; _log_file ERROR "cert-receive: $*"; exit 1; }

cert_receive() {
    exec 3>&1 1>&2          # only the status line goes to stdout; diagnostics go to stderr
    [[ -f "$CONF_FILE" ]] || cert_receive_fail "not installed (no $CONF_FILE)"
    ensure_config; resolve_runtime
    [[ "${CFG[CERT_MODE]}" == push ]] || cert_receive_fail "CERT_MODE is ${CFG[CERT_MODE]}, not push"
    svc_enabled traefik || cert_receive_fail "Traefik is not enabled on this host (nothing serves the certificate)"
    (( DRY_RUN )) && { log_info "Dry run: would validate stdin and install it into $(cert_push_dir)"; return 0; }
    local t n before after state=unchanged d live notafter
    d=$(cert_push_dir)
    t=$(mktemp -d); chmod 700 "$t"
    # shellcheck disable=SC2064
    trap "rm -rf '$t'" EXIT
    # bounded read: a stalled or wrong client (scp/sftp) must not hold the lock
    timeout 30 head -c $((PUSH_MAX_BYTES + 1)) >"$t/in" || [[ $? != 124 ]] || cert_receive_fail "timed out waiting for input"
    n=$(wc -c <"$t/in")
    (( n > 0 )) || cert_receive_fail "nothing received on stdin"
    (( n <= PUSH_MAX_BYTES )) || cert_receive_fail "input larger than $PUSH_MAX_BYTES bytes"
    sed -i 's/\r$//' "$t/in"
    pem_split "$t/in" "$t/crt" "$t/key" || cert_receive_fail "expected certificate(s) followed by exactly one private key (PEM)"
    key_is_encrypted "$t/key" && cert_receive_fail "the private key is encrypted (push an unencrypted key)"
    openssl x509 -in "$t/crt" -noout 2>/dev/null || cert_receive_fail "certificate does not parse"
    tls_validate_pair "$t/crt" "$t/key" || cert_receive_fail "certificate rejected (key mismatch, no matching certificate or expired)"
    install -d -m 700 "$d"
    if ! cmp -s "$t/crt" "$d/fullchain.pem" || ! cmp -s "$t/key" "$d/privkey.pem"; then
        install -m 600 -o root -g root "$t/key" "$d/privkey.pem.new"
        install -m 644 -o root -g root "$t/crt" "$d/fullchain.pem.new"
        mv -f "$d/privkey.pem.new" "$d/privkey.pem"; mv -f "$d/fullchain.pem.new" "$d/fullchain.pem"
        log_ok "Stored the pushed certificate in $d"
    fi
    before=$(tls_fp "$(traefik_cert_dir)/cert.pem")
    ( ensure_tls ) || cert_receive_fail "installing the certificate for Traefik failed"
    after=$(tls_fp "$(traefik_cert_dir)/cert.pem")
    [[ "$before" != "$after" ]] && state=changed
    live=$(tls_ensure_live)
    [[ "$live" =~ ^(yes|n/a)$ ]] || log_warn "Could not confirm that Traefik serves the new certificate (live: $live)"
    notafter=$(openssl x509 -in "$(traefik_cert_dir)/cert.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//; s/ /_/g')
    printf '%s OK %s sha256=%s notafter=%s live=%s\n' "$CERT_RECEIVE_TAG" "$state" "$after" "$notafter" "$live" >&3
    _log_file INFO "cert-receive: $state $after live=$live"
}

push_authorized_line() {   # push_authorized_line PUBKEY_LINE [FROM]
    local opts="restrict"
    [[ -n "${2:-}" ]] && opts+=",from=\"$2\""
    printf '%s,command="sudo -n %s --cert-receive" %s\n' "$opts" "$MS_INSTALL_BIN" "$1"
}
push_sudoers_line() { printf '%s ALL=(root) NOPASSWD: %s --cert-receive\n' "$1" "$MS_INSTALL_BIN"; }
push_sudoers_file() { printf '%s/mediastack-certpush' "${MS_SUDOERS_DIR:-/etc/sudoers.d}"; }

cert_push_setup() {   # cert_push_setup [PUBKEY_FILE|-]  -- create the push user, forced command and sudoers rule
    require_config; resolve_runtime
    local u=${CFG[CERT_PUSH_USER]} from=${CFG[CERT_PUSH_FROM]} src=${1:-} key="" home sud tmp au
    log_step "Certificate push receiver (user $u)"
    if [[ -n "$src" && "$src" != - ]]; then key=$(grep -m1 -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+) ' "$src" 2>/dev/null || true)
    elif [[ "$src" == - ]] || ! is_tty; then key=$(grep -m1 -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+) ' || true)
    else
        log_info "Paste the pushing machine's PUBLIC key (one line: ssh-ed25519 AAAA... comment)."
        log_info "On OPNsense, create it with: ssh-keygen -t ed25519 -N '' -f /root/ssl_certs/mediastack_push_ed25519"
        read -rp "  Public key: " key || true
    fi
    key=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$key")
    [[ -n "$key" ]] && ssh-keygen -l -f /dev/stdin <<<"$key" >/dev/null 2>&1 || die "That is not an SSH public key."
    command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || log_warn "openssh-server is not installed: install it (apt-get install openssh-server) or pushes cannot arrive."
    command -v sudo >/dev/null 2>&1 || { log_info "Installing sudo"; run apt-get install -y -qq sudo; }
    [[ -x "$MS_INSTALL_BIN" ]] || install_self
    if ! id "$u" >/dev/null 2>&1; then
        run useradd --system --create-home --shell /bin/sh --comment "mediastack certificate push" "$u"
        log_ok "Created system user $u (no password; key login only)"
    fi
    # "!" (locked) makes sshd refuse even key logins when UsePAM is off; "*" = no password, keys still work
    [[ "$(getent shadow "$u" 2>/dev/null | cut -d: -f2)" == "*" ]] || run usermod -p '*' "$u"
    home=$(getent passwd "$u" | cut -d: -f6); [[ -n "$home" ]] || home="/home/$u"
    run install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
    push_authorized_line "$key" "$from" | write_file "$home/.ssh/authorized_keys" 600 "$u:$u"
    sud=$(push_sudoers_file)
    if (( DRY_RUN )); then run write "$sud"
    else
        tmp=$(mktemp)
        push_sudoers_line "$u" >"$tmp"
        visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "visudo rejected the sudoers rule."; }
        install -d -m 750 "$(dirname "$sud")"; install -m 440 -o root -g root "$tmp" "$sud"; rm -f "$tmp"
        log_ok "Wrote $sud"
    fi
    au=$(sshd -T 2>/dev/null | awk 'tolower($1) == "allowusers" {$1 = ""; print}' || true)
    if [[ -n "${au// }" && " $au " != *" $u "* ]]; then
        log_warn "sshd has AllowUsers ($au): add $u there or the push is refused."
    fi
    [[ "${CFG[CERT_MODE]}" == push ]] || log_warn "CERT_MODE is ${CFG[CERT_MODE]}: pushes are refused until it is 'push' (Settings -> Access / certs)."
    log_info "Pushing side: user $u, host $(eff_local_ip), key = the private half of the key above."
    log_info "Test it from there:  cat fullchain.pem privkey.pem | ssh -i KEY $u@$(eff_local_ip)"
    log_info "Its TLS check must use a hostname under $(tls_zone) (Traefik uses strict SNI, so a probe by IP fails)."
    [[ -n "$from" ]] || log_info "Tip: set CERT_PUSH_FROM to the pushing machine's IP so the key only works from there."
}

cert_push_remove() {   # undo cert_push_setup (uninstall)
    local u=${CFG[CERT_PUSH_USER]:-mscertpush} sud
    sud=$(push_sudoers_file)
    [[ -f "$sud" ]] && run rm -f "$sud"
    if id "$u" >/dev/null 2>&1 && [[ "$(getent passwd "$u" | cut -d: -f5)" == "mediastack certificate push" ]]; then
        run userdel -r "$u" 2>/dev/null || true
        log_ok "Removed certificate push user $u"
    fi
    return 0
}

# cert_refresh -- timer/path-unit/menu entry point: fetch or re-read, install, reload Traefik if it changed
cert_refresh() {
    require_config; resolve_runtime
    [[ "${CFG[CERT_MODE]}" == manual ]] && load_secrets
    svc_enabled traefik || { log_info "Traefik is not enabled: nothing serves a certificate."; return 0; }
    [[ "${CFG[CERT_MODE]}" == letsencrypt ]] && { log_info "Let's Encrypt certificates are renewed by Traefik itself."; return 0; }
    local before after live
    before=$(tls_fp "$(traefik_cert_dir)/cert.pem")
    ensure_tls
    after=$(tls_fp "$(traefik_cert_dir)/cert.pem")
    live=$(tls_ensure_live)
    if [[ "$before" != "$after" ]]; then log_ok "New certificate installed (live: $live)"
    else log_info "Certificate unchanged (live: $live)"; fi
    [[ "$live" =~ ^(yes|n/a)$ ]] || log_warn "Could not confirm that Traefik serves $(traefik_cert_dir)/cert.pem (live: $live)"
    if (( CERT_FETCH_FAILED )); then   # non-zero for the timer's journal when the fetch itself failed
        log_error "The fetch failed; Traefik keeps serving the previous certificate."
        return 1
    fi
    return 0
}

cert_show() {
    require_config; resolve_runtime
    local f; f="$(traefik_cert_dir)/cert.pem"
    printf '  Mode: %s\n' "${CFG[CERT_MODE]}"
    case "${CFG[CERT_MODE]}" in
        fetch) printf '  Source: %s (%s, %s); last fetched copy: %s\n' "${CFG[CERT_FETCH_SOURCE]:-<unset>}" "${CFG[CERT_FETCH_CERT]}" "${CFG[CERT_FETCH_KEY]}" \
                      "$(date -r "$(cert_fetch_dir)/fullchain.pem" '+%F %T' 2>/dev/null || echo never)" ;;
        push)  printf '  Push user: %s (from: %s); last push stored: %s\n' "${CFG[CERT_PUSH_USER]}" "${CFG[CERT_PUSH_FROM]:-any}" \
                      "$(date -r "$(cert_push_dir)/fullchain.pem" '+%F %T' 2>/dev/null || echo 'never (temporary self-signed in use)')" ;;
    esac
    if [[ -f "$f" ]]; then
        openssl x509 -in "$f" -noout -subject -issuer -enddate -ext subjectAltName 2>&1 | sed 's/^/  /'
        printf '  sha256 %s\n  Served now: %s  (127.0.0.1:%s, SNI %s)\n' "$(tls_fp "$f")" "$(tls_live_fp || true)" "$(tls_https_port)" "$(tls_probe_name)"
    else
        log_info "No file-based certificate deployed (${CFG[CERT_MODE]})."
    fi
}

# cert_units -- systemd units: fetch = daily timer; manual = path watcher on the two files
cert_units() {
    local ud=${MS_UNIT_DIR:-/etc/systemd/system} want="" svc timer pathu
    svc="[Unit]
Description=mediastack-installer: refresh the Traefik TLS certificate
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MS_INSTALL_BIN --cert-refresh --yes"
    timer="[Unit]
Description=mediastack-installer: fetch the TLS certificate daily

[Timer]
OnCalendar=*-*-* 05:23:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target"
    pathu="[Unit]
Description=mediastack-installer: deploy the TLS certificate when its files change

[Path]
PathChanged=${CFG[TLS_CERT_FILE]}
PathChanged=${CFG[TLS_KEY_FILE]}

[Install]
WantedBy=multi-user.target"
    if svc_enabled traefik; then
        case "${CFG[CERT_MODE]}" in
            fetch)  want=timer ;;
            manual) [[ -n "${CFG[TLS_CERT_FILE]}" && -n "${CFG[TLS_KEY_FILE]}" ]] && want=path ;;
        esac
    fi
    command -v systemctl >/dev/null 2>&1 || return 0
    local kind other changed
    for kind in timer path; do
        [[ "$kind" == "$want" ]] && continue
        if [[ -f "$ud/$UNIT_CERT.$kind" ]]; then
            run systemctl disable --now "$UNIT_CERT.$kind" 2>/dev/null || true
            run rm -f "$ud/$UNIT_CERT.$kind"
            [[ -z "$want" ]] && run rm -f "$ud/$UNIT_CERT.service"
            run systemctl daemon-reload 2>/dev/null || true
            log_ok "Removed $UNIT_CERT.$kind"
        fi
    done
    [[ -n "$want" ]] || return 0
    [[ "$want" == timer ]] && other=$timer || other=$pathu
    changed=0
    if [[ "$(cat "$ud/$UNIT_CERT.service" 2>/dev/null)" != "$svc" ]]; then printf '%s\n' "$svc" | write_file "$ud/$UNIT_CERT.service" 644 root:root; changed=1; fi
    if [[ "$(cat "$ud/$UNIT_CERT.$want" 2>/dev/null)" != "$other" ]]; then printf '%s\n' "$other" | write_file "$ud/$UNIT_CERT.$want" 644 root:root; changed=1; fi
    if (( changed )); then
        run systemctl daemon-reload
        run systemctl enable "$UNIT_CERT.$want"
        run systemctl restart "$UNIT_CERT.$want"
    elif ! systemctl is-active --quiet "$UNIT_CERT.$want" 2>/dev/null; then
        run systemctl enable --now "$UNIT_CERT.$want"
    fi
    [[ "$want" == timer ]] && log_ok "Daily certificate fetch: $UNIT_CERT.timer" || log_ok "Certificate file watcher: $UNIT_CERT.path"
    return 0
}

cfg_cert_transfer() {   # fetch / push details (Settings -> Access / certs)
    local c k
    case "${CFG[CERT_MODE]}" in
        fetch)
            section "Certificate fetch (pull)"
            log_info "The pair is copied daily over scp (and on every apply) from another machine, e.g. OPNsense acme.sh."
            ask_valid "CFG[CERT_FETCH_SOURCE]" "Source user@host:/folder (e.g. certsync@192.168.1.1:/var/etc/acme-client/certs/ID)" "${CFG[CERT_FETCH_SOURCE]}" v_fetchsrc "user@host:/absolute/folder"
            ask_valid "CFG[CERT_FETCH_CERT]" "Certificate (full chain) file name in that folder" "${CFG[CERT_FETCH_CERT]}" v_fname "a file name"
            ask_valid "CFG[CERT_FETCH_KEY]" "Private key file name in that folder" "${CFG[CERT_FETCH_KEY]}" v_fname "a file name"
            if [[ ! -f "$(cert_fetch_keyf)" ]] && confirm "Create the SSH key used for fetching now?" y; then cert_fetch_key; fi
            if [[ -f "$(cert_fetch_keyf)" ]] && is_tty && confirm "Try fetching now?" y; then
                cert_fetch && { read -r c k <<<"$(cert_source_pair)"; tls_validate_pair "$c" "$k" && log_ok "Fetched certificate is valid"; } || true
            fi ;;
        push)
            section "Certificate push"
            log_info "Another machine (e.g. the OPNsense certificate deployer) pushes chain + key over SSH when it renews."
            log_info "Until the first push, Traefik serves a temporary self-signed certificate."
            ask_valid "CFG[CERT_PUSH_USER]" "Local user the pushing machine logs in as" "${CFG[CERT_PUSH_USER]}" v_user "a user name"
            ask_valid "CFG[CERT_PUSH_FROM]" "Only accept pushes from (IP/CIDR list, blank = any)" "${CFG[CERT_PUSH_FROM]}" v_from_opt "IPs/CIDRs separated by commas"
            if [[ -f "$CONF_FILE" ]] && confirm "Set up the push user and its key now?" y; then save_config; cert_push_setup; fi
            [[ -f "$CONF_FILE" ]] || log_info "After the install, run Certificate menu -> set up push receiver (or --cert-push-setup)." ;;
    esac
    return 0
}

menu_cert() {
    while :; do
        load_config
        printf '\n  %sCertificate%s (%s)\n' "$B" "$NC" "${CFG[CERT_MODE]}"
        printf '   1) Refresh now          (fetch / re-read, reload Traefik if it changed)\n'
        printf '   2) Show certificate     (what is deployed and what is served)\n'
        printf '   3) Create / show fetch SSH key (pull mode)\n'
        printf '   4) Set up push receiver (user, key, sudoers)\n'
        printf '   5) Change mode / source (Settings -> Access / certs)\n'
        printf '   0) Back\n'
        local ch; read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            1) menu_action cert_refresh ;;
            2) menu_action cert_show ;;
            3) menu_action cert_fetch_key ;;
            4) menu_action cert_push_setup ;;
            5) cfg_access; cfg_manual_cert; cfg_cert_transfer
               [[ "${CFG[CERT_MODE]}" == letsencrypt ]] || CFG[CLOUDFLARE_DNS_ZONE]=${CFG[DOMAIN]}
               [[ "${CFG[SERVICE_PRESET]}" == custom ]] || apply_preset
               save_config
               confirm "Apply now so it takes effect?" y && menu_action stack_apply nopull ;;
            0|q) return 0 ;;
            *) continue ;;
        esac
        pause
    done
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

# image_id IMAGE -> local image ID (blank when not present)
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

# compose_stream ARGS... -- docker compose with line-based progress. The log gets every line except
# the per-layer byte counters (Downloading 12.3MB / Extracting 4B); the console gets one updating
# status line (one line per image when not a terminal) plus anything that is not progress.
STREAM_AWK='
function clr() { if (st) { printf "\r\033[K"; st = 0 } }
function status(msg) { if (tty) { printf "\r\033[K  %s", substr(msg, 1, 100); st = 1; fflush() } }
function nm(s) { sub(/^[^A-Za-z0-9]*/, "", s); sub(/^Container +/, "", s); sub(/ +[A-Z][a-z]+( [a-z]+)?[ \t]*$/, "", s); return s }
{
    sub(/\r$/, ""); line = $0; show = line; sub(/^[ \t]+/, "", show)
    layer = (line ~ /^[ \t]*[0-9a-f]{12} /)
    if (layer && line ~ /(Downloading|Extracting|Waiting|Verifying Checksum|Pulling fs layer)/) next
    if (lf != "") { print line >> lf; fflush(lf) }
    if (layer || line ~ /^[ \t]*$/) next
    if (line ~ /[Ee]rror|failed|unhealthy|denied|not found|manifest unknown/) { clr(); print "  " show; fflush(); next }
    if (line ~ / Pulling[ \t]*$/) { status(sprintf("Pulling images: %d done, now %s", pulled, nm(line))); next }
    if (line ~ / Pulled[ \t]*$/) {
        pulled++
        if (tty) status(sprintf("Pulling images: %d done (%s)", pulled, nm(line)))
        else { print "  pulled: " nm(line); fflush() }
        next
    }
    if (line ~ /^[ \t]*Container /) {
        if (line ~ / (Started|Running|Healthy)[ \t]*$/) started[nm(line)] = 1
        status("Starting containers: " nm(line) " " $NF); next
    }
    if (line ~ /^[ \t]*(Network|Volume) /) next
    clr(); print "  " show; fflush()
}
END {
    clr()
    if (pulled) printf "  Pulled %d image(s)\n", pulled
    n = 0; for (k in started) n++
    if (n) printf "  %d container(s) started or running\n", n
}'
compose_stream() {
    if (( DRY_RUN )); then run compose_run "$@"; return 0; fi
    _log_file RUN "docker compose $*"
    local tty=0
    [[ -t 1 ]] && tty=1
    if compose_run --progress plain "$@" 2>&1 | awk -v lf="${LOG_FILE:-}" -v tty="$tty" "$STREAM_AWK"; then
        return 0
    else
        return "${PIPESTATUS[0]}"
    fi
}

# compose_pull -- pull with compact progress (see compose_stream) and report which images changed
compose_pull() {
    local img a rc=0
    local -a imgs changed=()
    local -A before=()
    mapfile -t imgs < <(compose_run config --images 2>/dev/null | sort -u)
    for img in "${imgs[@]}"; do [[ -n "$img" ]] && before[$img]=$(image_id "$img"); done
    log_info "Pulling ${#imgs[@]} image(s); the first install can take several minutes..."
    compose_stream pull || rc=$?
    (( rc == 0 )) || return "$rc"
    for img in "${imgs[@]}"; do
        [[ -n "$img" ]] || continue
        a=$(image_id "$img")
        [[ -n "$a" && "$a" != "${before[$img]:-}" ]] && changed+=("$img")
    done
    if (( ${#changed[@]} )); then
        log_ok "${#changed[@]} image(s) new or updated:"
        for img in "${changed[@]}"; do log_info "  $img"; done
    else
        log_ok "All ${#imgs[@]} image(s) already up to date"
    fi
}

# cidr_overlap A/n B/m -> 0 when the two IPv4 networks overlap
ip4_int() { local a b c d; IFS=. read -r a b c d <<<"$1"; printf '%s' $(( (a << 24) | (b << 16) | (c << 8) | d )); }
cidr_overlap() {
    [[ "$1" == */* && "$2" == */* ]] || return 1
    valid_ipv4 "${1%/*}" && valid_ipv4 "${2%/*}" || return 1
    local n=${1#*/} m=${2#*/} p mask
    p=$(( n < m ? n : m ))
    mask=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
    (( ($(ip4_int "${1%/*}") & mask) == ($(ip4_int "${2%/*}") & mask) ))
}

# stack_subnet -> DOCKER_SUBNET from the stack's .env
stack_subnet() { env_get "$FOLDER_FOR_YAML/.env" DOCKER_SUBNET 2>/dev/null || true; }

# network_conflicts -> "id|name|project|containers" for every Docker network overlapping the stack's subnet
network_conflicts() {
    local sub id line name proj subs cn x
    sub=$(stack_subnet); [[ -n "$sub" ]] || return 0
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        line=$(docker network inspect -f '{{.Name}}|{{index .Labels "com.docker.compose.project"}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}|{{len .Containers}}' "$id" 2>/dev/null) || continue
        IFS='|' read -r name proj subs cn <<<"$line"
        for x in $subs; do
            if cidr_overlap "$x" "$sub"; then printf '%s|%s|%s|%s\n' "${id:0:12}" "$name" "$proj" "$cn"; break; fi
        done
    done < <(docker network ls -q --filter driver=bridge 2>/dev/null)
    return 0
}

# docker_bridge_ifaces -> host interface names of all Docker bridge networks (br-<id12> or a custom bridge.name)
docker_bridge_ifaces() {
    local id nm
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        nm=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$id" 2>/dev/null || true)
        if [[ -n "$nm" ]]; then echo "$nm"; else echo "br-${id:0:12}"; fi
    done < <(docker network ls -q --no-trunc --filter driver=bridge 2>/dev/null)
    return 0
}

# subnet_foreign_ifaces -> "IFACE CIDR" for host interfaces holding an address in the stack's subnet that are not
# Docker bridges (e.g. a bridge left behind by a removed Docker network: its route still captures the replies)
subnet_foreign_ifaces() {
    local sub dev cidr; local -a known
    sub=$(stack_subnet); [[ -n "$sub" ]] || return 0
    mapfile -t known < <(docker_bridge_ifaces)
    while read -r dev cidr; do
        [[ -n "$dev" ]] || continue
        cidr_overlap "$cidr" "$sub" || continue
        in_list "$dev" "${known[@]}" || printf '%s %s\n' "$dev" "$cidr"
    done < <(ip -4 -o addr show 2>/dev/null | awk '{print $2, $4}')
    return 0
}

# ensure_no_foreign_subnet_iface -- remove orphaned Docker bridges (br-<12 hex>, no ports) on the stack's subnet;
# anything else using that subnet is a real conflict
ensure_no_foreign_subnet_iface() {
    local dev cidr bad=""
    while read -r dev cidr; do
        [[ -n "$dev" ]] || continue
        if [[ "$dev" =~ ^br-[0-9a-f]{12}$ && -d "/sys/class/net/$dev/bridge" ]] && [[ -z "$(ls -A "/sys/class/net/$dev/brif" 2>/dev/null)" ]]; then
            log_warn "Host interface $dev ($cidr) is a bridge left by a Docker network that no longer exists; its route for the"
            log_warn "stack's subnet sends replies (e.g. Gluetun's WireGuard handshake answers) into it. Removing it."
            if run ip link delete "$dev"; then log_ok "Removed orphaned bridge $dev"; else bad+=" $dev"; fi
        else
            bad+=" $dev($cidr)"
        fi
    done < <(subnet_foreign_ifaces)
    [[ -z "$bad" ]] || die "Host interface(s)${bad} use the stack's subnet $(stack_subnet). Move them, or give MediaStack another DOCKER_SUBNET/DOCKER_GATEWAY in $FOLDER_FOR_YAML/.env."
    return 0
}

# ensure_stack_network -- exactly one Docker network may use the stack's subnet. A second one (left by an
# earlier run, a different project name or a duplicate "mediastack" network) gets its own host route for the
# same subnet, and replies to the containers (e.g. Gluetun's WireGuard handshake) are routed into it and lost.
ensure_stack_network() {
    local -a nets=() keep=(); local n id name proj cn foreign=""
    ensure_no_foreign_subnet_iface
    mapfile -t nets < <(network_conflicts)
    (( ${#nets[@]} > 1 )) || return 0
    log_warn "${#nets[@]} Docker networks use the stack's subnet $(stack_subnet); traffic back to the containers goes to the wrong one:"
    for n in "${nets[@]}"; do
        IFS='|' read -r id name proj cn <<<"$n"
        log_warn "  $name ($id, project ${proj:-none}, $cn container(s)) -> host interface br-$id"
        if [[ "$name" != "$PROJECT_NAME" && "$proj" != "$PROJECT_NAME" && "$cn" != 0 ]]; then foreign+=" $name"; fi
    done
    [[ -z "$foreign" ]] || die "Network(s)${foreign} belong to something else and are in use. Remove them, or give MediaStack another DOCKER_SUBNET/DOCKER_GATEWAY in $FOLDER_FOR_YAML/.env, then Apply again."
    log_info "Recreating the stack's network: stopping MediaStack's containers and removing the duplicate network(s)..."
    run_logged compose_run down --remove-orphans || true
    for n in "${nets[@]}"; do
        IFS='|' read -r id name proj cn <<<"$n"
        if run docker network rm "$id" >/dev/null 2>&1; then log_ok "Removed network $name ($id)"
        else keep+=("$name ($id)"); fi
    done
    (( ${#keep[@]} == 0 )) || die "Could not remove: ${keep[*]} (still in use?). Check: docker network inspect <id>"
    return 0
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

verify_services() {   # verify_services TIMEOUT_SECONDS -- wait (visibly) until every enabled service runs
    local timeout=${1:-180} waited=0 s st msg tty=0 settled
    local -a svcs bad
    local -A state
    [[ -t 1 ]] && tty=1
    mapfile -t svcs < <(compose_run config --services 2>/dev/null)
    log_info "Waiting up to ${timeout}s for ${#svcs[@]} services to be running..."
    while :; do
        bad=(); state=(); settled=1
        while IFS=$'\t' read -r s st; do [[ -n "$s" ]] && state[$s]=$st; done \
            < <(compose_run ps -a --format '{{.Service}}\t{{.State}}' 2>/dev/null)
        for s in "${svcs[@]}"; do
            st=${state[$s]:-missing}
            [[ "$st" == running ]] && continue
            bad+=("$s:$st")
            [[ "$st" =~ ^(exited|dead|created)$ ]] || settled=0   # restarting/starting may still come up
        done
        (( tty )) && printf '\r\033[K'
        (( ${#bad[@]} == 0 )) && { log_ok "All ${#svcs[@]} services running"; return 0; }
        # containers that exited or were never started will not change by waiting
        (( settled && waited >= 30 )) && break
        (( waited >= timeout )) && break
        msg="$(( ${#svcs[@]} - ${#bad[@]} ))/${#svcs[@]} running after ${waited}s; waiting for: ${bad[*]}"
        if (( tty )); then printf '  %s' "${msg:0:$(( ${COLUMNS:-120} - 4 ))}"
        elif (( waited % 30 == 0 )); then log_info "$msg"; fi
        sleep 5; waited=$((waited + 5))
    done
    log_warn "${#bad[@]} of ${#svcs[@]} services not running after ${waited}s: ${bad[*]}"
    log_warn "Check: sudo $MS_INSTALL_BIN --logs 100 <service>"
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
    ensure_tls
    cert_units
    report_dependencies die
    log_step "Starting MediaStack ($mode)"
    if (( DRY_RUN )); then
        run compose_run config --quiet
        [[ "$mode" == pull ]] && run compose_run pull --quiet
        run compose_run up -d --remove-orphans --quiet-pull
        return 0
    fi
    vpn_preflight
    compose_run config --quiet || die "docker compose config failed (missing variables or invalid YAML)."
    log_ok "Compose configuration valid"
    ensure_stack_network
    stop_excluded_containers
    if [[ "$mode" == pull ]]; then
        compose_pull || die "Pulling images failed (network or registry problem); nothing was changed."
    fi
    if ! compose_stream up -d --remove-orphans; then
        diagnose_start_failure
        die "Some containers could not start (causes above). Fix them, then run Apply again."
    fi
    verify_services 180 || true
    if [[ "${CFG[CERT_MODE]}" != letsencrypt ]] && svc_enabled traefik && [[ ! "$(tls_ensure_live)" =~ ^(yes|n/a)$ ]]; then
        log_warn "Traefik is not serving $(traefik_cert_dir)/cert.pem yet; check: sudo $MS_INSTALL_BIN --cert-show"
    fi
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
    printf '  %-22s %s\n' "Access / certificate" "${CFG[ACCESS_MODE]} / ${CFG[CERT_MODE]}$( [[ "${CFG[CERT_MODE]}" == selfsigned ]] && printf ' (CA: %s/ca.crt)' "$(tls_dir)")"
    printf '  %-22s %s\n' "Services" "preset=${CFG[SERVICE_PRESET]} player=${CFG[PLAYER]} tailscale=${CFG[TAILSCALE_CONTROL]}"
    printf '  %-22s %s\n' "" "disabled: ${CFG[DISABLED_SERVICES]:-none}  removed: ${CFG[REMOVED_SERVICES]:-none}  auto-off: $(forced_off | xargs)"
    if [[ "${CFG[CERT_MODE]}" != letsencrypt && -f "$(traefik_cert_dir)/cert.pem" ]]; then
        printf '  %-22s %s\n' "Certificate expires" "$(openssl x509 -in "$(traefik_cert_dir)/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
    fi
    case "${CFG[CERT_MODE]}" in
        fetch) printf '  %-22s %s\n' "Certificate fetch" "${CFG[CERT_FETCH_SOURCE]:-<unset>}; last copy $(date -r "$(cert_fetch_dir)/fullchain.pem" '+%F %T' 2>/dev/null || echo never)" ;;
        push)  printf '  %-22s %s\n' "Certificate push" "user ${CFG[CERT_PUSH_USER]} from ${CFG[CERT_PUSH_FROM]:-any}; last push $(date -r "$(cert_push_dir)/fullchain.pem" '+%F %T' 2>/dev/null || echo 'never (temporary self-signed)')" ;;
    esac
    report_dependencies warn
    if svc_enabled gluetun; then
        printf '  %-22s %s\n' "VPN" "${CFG[VPN_SERVICE_PROVIDER]:-<not set>} / ${CFG[VPN_TYPE]}"
        local vl; while IFS= read -r vl; do [[ -n "$vl" ]] && log_warn "VPN: $vl"; done <<<"$(vpn_problems)"
    fi
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
    if [[ -n "$(docker ps -q --filter "name=^${PG_CONTAINER}$")" ]]; then
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
    if svc_enabled authentik; then
        confirm "Secure the Authentik database now?" y && { helper_authentik_db || log_warn "Authentik DB helper failed"; }
    fi
    if svc_enabled guacamole; then
        confirm "Create the Guacamole database now?" y && { helper_guacamole_db || log_warn "Guacamole DB helper failed"; }
    fi
    if svc_enabled authentik; then
        confirm "Set the Authentik 'akadmin' password now?" y && { helper_akadmin || log_warn "akadmin reset failed"; }
    fi
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
                 CLOUDFLARE_EMAIL CLOUDFLARE_DNS_ZONE EMAIL_SERVER_HOST EMAIL_SERVER_PORT EMAIL_ADDRESS EMAIL_SENDER \
                 VPN_ENDPOINT_IP VPN_ENDPOINT_PORT WIREGUARD_PUBLIC_KEY WIREGUARD_ADDRESSES \
                 SERVER_COUNTRIES SERVER_CITIES SERVER_HOSTNAMES; do
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
v_access()   { [[ "$1" =~ ^(internet|lan)$ ]]; }
v_cert()     { [[ "$1" =~ ^(letsencrypt|selfsigned|manual|fetch|push)$ ]]; }
v_fetchsrc() { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+:/[^[:space:]\']*$ ]]; }
v_fname()    { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
v_period()   { [[ "$1" == off || "$1" =~ ^[0-9]+h$ ]]; }
v_email_opt(){ [[ -z "$1" || "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; }
v_from_opt() { [[ -z "$1" || "$1" =~ ^[0-9A-Fa-f.:/,*?]+$ ]]; }
v_preset()   { [[ "$1" =~ ^(core|full|custom)$ ]]; }
v_player()   { [[ "$1" =~ ^(jellyfin|plex|both)$ ]]; }
v_tscontrol(){ [[ "$1" =~ ^(tailscale|headscale)$ ]]; }
v_bformat()  { [[ "$1" =~ ^(host|portable)$ ]]; }
v_file()     { valid_abs_path "$1" && [[ -f "$1" ]]; }
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

cfg_access() {
    section "Access and certificates"
    log_info "internet = public domain via Traefik + Authentik SSO + CrowdSec (forward port 443 to this host)"
    log_info "lan      = LAN only: apps on their own ports; Traefik/Authentik/CrowdSec off in the Core preset"
    local old=${CFG[ACCESS_MODE]}
    ask_valid "CFG[ACCESS_MODE]" "Access mode (internet/lan)" "${CFG[ACCESS_MODE]}" v_access "internet or lan"
    if [[ "${CFG[ACCESS_MODE]}" != "$old" && "${CFG[ACCESS_MODE]}" == lan && "${CFG[CERT_MODE]}" == letsencrypt ]]; then
        CFG[CERT_MODE]=selfsigned
    fi
    log_info "Traefik certificate (used whenever Traefik runs):"
    log_info "  letsencrypt = trusted wildcard via Cloudflare DNS-01 (Cloudflare-hosted domain + API token)"
    log_info "  selfsigned  = local CA created on this host; import its ca.crt on your devices once"
    log_info "  manual      = your own certificate + key files (paths or pasted); re-copied on every apply"
    log_info "  fetch       = pulled over scp daily from another machine (e.g. OPNsense acme.sh)"
    log_info "  push        = another machine pushes it over SSH when it renews (e.g. the OPNsense deployer)"
    ask_valid "CFG[CERT_MODE]" "Certificate source (letsencrypt/selfsigned/manual/fetch/push)" "${CFG[CERT_MODE]}" v_cert "letsencrypt, selfsigned, manual, fetch or push"
}

# read_paste OUT [hidden] -- pasted text until a line "END", Ctrl-D, or 3 s without input once
# something has arrived (a terminal paste arrives in one burst, so multi-block chains and config
# files with blank lines are read whole). CR line endings are stripped.
read_paste() {
    local out=$1 hid=${2:-0} line n=0 rc stty_save=""
    local -a ro
    : >"$out"
    # Non-canonical mode: a paste whose last line has no newline is still delivered (in canonical
    # mode it would sit in the tty buffer and be fed to the NEXT prompt as its answer).
    if [[ -t 0 ]]; then stty_save=$(stty -g 2>/dev/null || true); stty -icanon -echoctl min 1 time 0 2>/dev/null || true; fi
    while :; do
        ro=(-r); (( hid )) && ro+=(-s); (( n )) && ro+=(-t 3)
        line=""; rc=0
        IFS= read "${ro[@]}" line || rc=$?
        line=${line%$'\r'}
        if (( rc )); then
            if [[ -n "$line" && "$line" != END && "$line" != end ]]; then   # unterminated last line
                printf '%s\n' "$line" >>"$out"; [[ -t 0 ]] && echo
            fi
            break
        fi
        [[ "$line" == END || "$line" == end ]] && break
        printf '%s\n' "$line" >>"$out"; n=$((n + 1))
    done
    if [[ -n "$stty_save" ]]; then stty "$stty_save" 2>/dev/null || true; fi
    (( hid )) && echo
    local body; body=$(cat "$out")            # drop trailing blank lines
    if [[ -n "$body" ]]; then printf '%s\n' "$body" >"$out"; else : >"$out"; fi
    return 0
}

# read_pem KIND OUT -- KIND=cert: the whole chain (any number of certificates, blank lines allowed);
#                      KIND=key : one private key, hidden, ends at its -----END ... KEY----- line
read_pem() {
    local kind=$1 out=$2 line n=0 ends
    if [[ "$kind" == cert ]]; then
        log_info "Paste the certificate chain (server certificate + intermediates, any order). Input ends"
        log_info "3 seconds after the paste, or type END / press Ctrl-D:"
        read_paste "$out"
        ends=$(grep -c -- '-----END CERTIFICATE-----' "$out" || true)
        (( ends > 0 )) || { log_error "No -----BEGIN/END CERTIFICATE----- block found in the pasted text"; return 1; }
        log_ok "Read $ends certificate(s)"
        return 0
    fi
    : >"$out"
    log_info "Paste the private key (input is hidden; it ends automatically at its -----END ...----- line):"
    while :; do
        IFS= read -rs line || break
        line=${line%$'\r'}
        [[ "$line" == END || "$line" == end ]] && break
        if [[ -z "$line" ]]; then
            # traditional encrypted keys need the blank line after their DEK-Info header
            if [[ -s "$out" ]]; then printf '\n' >>"$out"; fi
            continue
        fi
        printf '%s\n' "$line" >>"$out"; n=$((n + 1))
        [[ "$line" =~ ^-----END\ .*PRIVATE\ KEY-----$ ]] && break
    done
    echo
    grep -qE -- '-----BEGIN .*PRIVATE KEY-----' "$out" || { log_error "No private key block found in the pasted text"; return 1; }
    log_ok "Read the private key ($n lines)$(key_is_encrypted "$out" && printf ' -- encrypted')"
}

cert_field() { openssl x509 -in "$2" -noout -"$1" -nameopt RFC2253 2>/dev/null | sed 's/^[a-z]* *= *//'; }

# tls_chain_order CERTFILE KEYPUB DIR -> ordered cert files (leaf first, then each issuer)
#   rc 2: no certificate in the file; rc 1: none of the certificates matches the key
tls_chain_order() {
    local c=$1 kp=$2 d=$3 f leaf="" cur iss nxt n
    n=$(awk -v d="$d" '/-----BEGIN CERTIFICATE-----/ {n++; f = sprintf("%s/cert-%03d.pem", d, n)}
                       f {print > f}
                       /-----END CERTIFICATE-----/ {close(f); f = ""}
                       END {print n + 0}' "$c")
    (( n > 0 )) || return 2
    local -a all order rest
    all=("$d"/cert-*.pem)
    for f in "${all[@]}"; do
        if [[ "$(openssl x509 -in "$f" -noout -pubkey 2>/dev/null)" == "$kp" ]]; then leaf=$f; break; fi
    done
    [[ -n "$leaf" ]] || return 1
    order=("$leaf"); rest=()
    for f in "${all[@]}"; do [[ "$f" == "$leaf" ]] || rest+=("$f"); done
    cur=$leaf
    while (( ${#rest[@]} )); do
        iss=$(cert_field issuer "$cur")
        [[ "$iss" == "$(cert_field subject "$cur")" ]] && break        # self-signed: end of chain
        nxt=""
        for f in "${rest[@]}"; do [[ "$(cert_field subject "$f")" == "$iss" ]] && { nxt=$f; break; }; done
        [[ -n "$nxt" ]] || break
        order+=("$nxt")
        local -a keep=(); for f in "${rest[@]}"; do [[ "$f" == "$nxt" ]] || keep+=("$f"); done; rest=("${keep[@]}")
        cur=$nxt
    done
    printf '%s\n' "${order[@]}" "${rest[@]}"
}

# tls_write_chain CERT KEY OUT -- write the chain leaf-first (as Traefik expects)
tls_write_chain() {
    local d kp rc=0 ord
    d=$(mktemp -d)
    kp=$(tls_key_plain "$2" | openssl pkey -pubout 2>/dev/null) || kp=""
    ord=$(tls_chain_order "$1" "$kp" "$d") || rc=$?
    if (( rc == 0 )); then
        # shellcheck disable=SC2046
        cat $(printf '%s\n' "$ord") >"$3"
    fi
    rm -rf "$d"
    return $rc
}


# pick_pem KIND CFGKEY STOREFILE -- ask for a path, or 'paste' to paste the PEM (stored in STOREFILE)
pick_pem() {
    local kind=$1 key=$2 store=$3 v label tmp
    label=$([[ $kind == cert ]] && echo "Certificate (full chain)" || echo "Private key")
    while :; do
        ask v "$label: file path, or 'paste' to paste it" "${CFG[$key]:-paste}"
        if [[ "${v,,}" == paste ]]; then
            if (( ASSUME_YES )) || ! is_tty; then die "Pasting needs a terminal; set $key to a file path instead."; fi
            tmp=$(mktemp); chmod 600 "$tmp"
            if read_pem "$kind" "$tmp"; then
                if (( DRY_RUN )); then CFG[$key]=$tmp; log_info "[dry-run] would store it as $store"; return 0; fi
                mkdir -p "$(dirname "$store")"; chmod 700 "$(dirname "$store")"
                install -m "$([[ $kind == key ]] && echo 600 || echo 644)" "$tmp" "$store"; rm -f "$tmp"
                CFG[$key]=$store
                log_ok "Stored in $store"
                return 0
            fi
            rm -f "$tmp"; continue
        fi
        if v_file "$v"; then CFG[$key]=$v; return 0; fi
        log_warn "Not an existing file (absolute path): '$v'"
    done
}

# ask_key_passphrase KEYFILE -- encrypted keys: verify/ask the passphrase and keep it in the vault
ask_key_passphrase() {
    local k=$1 p tries=0
    if ! key_is_encrypted "$k"; then
        if secret_is_set TLS_KEY_PASSPHRASE; then SECRETS[TLS_KEY_PASSPHRASE]=""; SECRETS_DIRTY=1; fi
        return 0
    fi
    if secret_is_set TLS_KEY_PASSPHRASE && tls_key_plain "$k" >/dev/null; then
        log_ok "The key is encrypted; the stored passphrase opens it"; return 0
    fi
    log_info "The key is encrypted. Its passphrase is stored in the vault so every apply can decrypt it for Traefik."
    while (( tries < 3 )); do
        ask_secret p "Key passphrase"
        [[ -n "$p" ]] || break
        if tls_key_plain "$k" "$p" >/dev/null; then
            SECRETS[TLS_KEY_PASSPHRASE]=$p; SECRETS_DIRTY=1; log_ok "Passphrase OK"; return 0
        fi
        log_warn "That passphrase does not open the key."; tries=$((tries + 1))
    done
    log_warn "No working passphrase stored; apply will refuse until one is set."
    return 1
}

cfg_manual_cert() {
    [[ "${CFG[CERT_MODE]}" == manual ]] || return 0
    section "Manual certificate"
    log_info "Certificate chain (server certificate + intermediates, any order) covering $(tls_zone) and *.$(tls_zone),"
    log_info "plus its PEM private key"
    log_info "(encrypted keys are fine: you are asked for the passphrase). Give file paths -- e.g. where your"
    log_info "renewal job writes them, re-copied on every apply -- or paste the PEM text (stored in $(tls_dir))."
    [[ -f "$SECRETS_FILE" ]] && load_secrets || SECRETS_LOADED=1
    while :; do
        if (( ASSUME_YES )) || ! is_tty; then
            ask_valid "CFG[TLS_CERT_FILE]" "Certificate file" "${CFG[TLS_CERT_FILE]}" v_file "an existing file"
            ask_valid "CFG[TLS_KEY_FILE]"  "Private key file" "${CFG[TLS_KEY_FILE]}" v_file "an existing file"
        else
            pick_pem cert TLS_CERT_FILE "$(tls_dir)/manual-cert.pem"
            pick_pem key  TLS_KEY_FILE  "$(tls_dir)/manual-key.pem"
            ask_key_passphrase "${CFG[TLS_KEY_FILE]}" || true
        fi
        tls_validate_pair "${CFG[TLS_CERT_FILE]}" "${CFG[TLS_KEY_FILE]}" && { log_ok "Certificate and key match"; break; }
        { (( ASSUME_YES )) || ! is_tty; } && die "The manual certificate failed validation."
        confirm "Keep these anyway (apply will refuse until they validate)?" n && break
    done
}

cfg_network() {
    section "Domain and network"
    detect_network
    local old=${CFG[DOMAIN]}
    if [[ "${CFG[ACCESS_MODE]}" == lan ]]; then
        [[ -n "${CFG[DOMAIN]}" ]] || CFG[DOMAIN]=mediastack.lan
        ask_valid "CFG[DOMAIN]" "Domain for app hostnames (local DNS, e.g. home.lan; used when Traefik runs)" "${CFG[DOMAIN]}" v_domain "a domain such as home.lan"
    else
        ask_valid "CFG[DOMAIN]" "Public domain for app hostnames (auth.<domain>, ...)" "${CFG[DOMAIN]}" v_domain "a domain such as example.org"
    fi
    if [[ "${CFG[CERT_MODE]}" == letsencrypt ]]; then
        [[ -z "${CFG[CLOUDFLARE_DNS_ZONE]}" || "${CFG[CLOUDFLARE_DNS_ZONE]}" == "$old" ]] && CFG[CLOUDFLARE_DNS_ZONE]=${CFG[DOMAIN]}
        ask_valid "CFG[CLOUDFLARE_DNS_ZONE]" "Cloudflare DNS zone" "${CFG[CLOUDFLARE_DNS_ZONE]}" v_domain "a domain"
        ask "CFG[CLOUDFLARE_EMAIL]" "Cloudflare account email" "${CFG[CLOUDFLARE_EMAIL]}"
    else
        CFG[CLOUDFLARE_DNS_ZONE]=${CFG[DOMAIN]}   # hostname base for the Traefik labels
    fi
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
    log_info "core   = Gluetun VPN, qBittorrent, SABnzbd, Prowlarr, FlareSolverr, Unpackerr, Sonarr, Radarr,"
    log_info "         Lidarr, Bazarr, Seerr, Homepage, Tailscale, Audiobookshelf + your player"
    log_info "         (+ Traefik, Authentik, CrowdSec, PostgreSQL, Valkey when access mode is internet)"
    log_info "full   = every upstream service (Whisparr disabled) + add-ons"
    log_info "custom = choose service by service (starts from Core on a new install)"
    log_info "Readarr is always removed (retired upstream)."
    local oldp=${CFG[SERVICE_PRESET]}
    ask_valid "CFG[SERVICE_PRESET]" "Service preset (core/full/custom)" "${CFG[SERVICE_PRESET]}" v_preset "core, full or custom"
    ask_valid "CFG[PLAYER]" "Media player (jellyfin/plex/both)" "${CFG[PLAYER]}" v_player "jellyfin, plex or both"
    log_info "Tailscale control server:"
    log_info "  tailscale = official service; works LAN-only (auth key from https://login.tailscale.com/admin/settings/keys)"
    log_info "  headscale = self-hosted Headscale at https://headscale.<domain> (also enables Headscale + Headplane)"
    ask_valid "CFG[TAILSCALE_CONTROL]" "Tailscale control server (tailscale/headscale)" "${CFG[TAILSCALE_CONTROL]}" v_tscontrol "tailscale or headscale"
    if [[ "${CFG[TAILSCALE_CONTROL]}" == headscale && "${CFG[ACCESS_MODE]}" == lan ]]; then
        log_warn "Headscale must be reachable over HTTPS by your devices; in 'lan' mode that only works inside your LAN."
    fi
    if [[ "${CFG[SERVICE_PRESET]}" == custom && "$oldp" != custom && ! -f "$CONF_FILE" ]]; then
        CFG[SERVICE_PRESET]=core; apply_preset; CFG[SERVICE_PRESET]=custom
        log_info "Starting from the Core selection."
    fi
    apply_preset
    if [[ "${CFG[SERVICE_PRESET]}" == custom ]]; then
        if (( ASSUME_YES )) || ! is_tty; then
            ask "CFG[DISABLED_SERVICES]" "Disabled services (space separated)" "${CFG[DISABLED_SERVICES]}"
            ask "CFG[REMOVED_SERVICES]"  "Removed services (space separated)"  "${CFG[REMOVED_SERVICES]}"
        else
            services_toggle_ui
        fi
    fi
    local on s; on=$(all_services | while read -r s; do if [[ "$(eff_state "$s")" == on ]]; then echo "$s"; fi; done | xargs)
    log_ok "Services on ($(wc -w <<<"$on")): $on"
    report_dependencies warn
}

services_toggle_ui() {
    log_info "on = runs | disabled = never started, folders kept | removed = never started, no app-data folder"
    local -a svcs; mapfile -t svcs < <(all_services)
    local in n i s line
    while :; do
        echo
        for i in "${!svcs[@]}"; do
            s=${svcs[$i]}
            case "$(eff_state "$s")" in
                on)       line="${G}on${NC}      " ;;
                disabled) line="${Y}disabled${NC}"; [[ "$(svc_state "$s")" == on ]] && line="${Y}auto-off${NC}" ;;
                *)        line="${R}removed${NC} " ;;
            esac
            if is_addon "$s"; then s+="+"; fi
            printf '  %2d) %-20s %s' "$((i + 1))" "$s" "$line"
            (( (i + 1) % 3 == 0 )) && echo
        done
        echo
        printf '  (+ = add-on provided by this installer; auto-off = parked by another setting)\n'
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
        done
        CFG[SERVICE_PRESET]=custom
        report_dependencies warn
    done
}

cfg_vpn_email() {
    section "VPN and email"
    if svc_enabled gluetun; then cfg_vpn; elif svc_exists gluetun; then log_info "Gluetun is off: VPN settings skipped."; fi
    if svc_enabled authentik; then
        ask "CFG[EMAIL_SERVER_HOST]" "SMTP host for Authentik (blank = none)" "${CFG[EMAIL_SERVER_HOST]}"
        if [[ -n "${CFG[EMAIL_SERVER_HOST]}" ]]; then
            ask_valid "CFG[EMAIL_SERVER_PORT]" "SMTP port" "${CFG[EMAIL_SERVER_PORT]}" v_num "a port number"
            ask "CFG[EMAIL_ADDRESS]" "SMTP username/address" "${CFG[EMAIL_ADDRESS]}"
            ask "CFG[EMAIL_SENDER]" "Email sender address" "${CFG[EMAIL_SENDER]}"
        fi
    else
        log_info "Authentik is off: SMTP settings skipped."
    fi
}

cfg_stack() {
    section "Upstream, secrets and backups"
    ask "CFG[UPSTREAM_REF]" "Upstream ref (commit SHA recommended)" "${CFG[UPSTREAM_REF]}"
    ask_valid "CFG[UPSTREAM_VARIANT]" "Compose variant (full-download-vpn/mini-download-vpn/no-download-vpn)" "${CFG[UPSTREAM_VARIANT]}" v_variant "one of the three variants"
    ask_valid "CFG[SECRETS_MODE]" "Secrets mode (vault = encrypted, injected at runtime; env = plaintext .env)" "${CFG[SECRETS_MODE]}" v_mode "vault or env"
    ask_valid "CFG[SECRETS_BACKEND]" "Secrets backend (auto/systemd-creds/openssl)" "${CFG[SECRETS_BACKEND]}" v_backend "auto, systemd-creds or openssl"
    ask_valid "CFG[CHOWN_MEDIA_RECURSIVE]" "Re-own the whole media library on every apply (yes/no)" "${CFG[CHOWN_MEDIA_RECURSIVE]}" v_yesno "yes or no"
    ask "CFG[EXTRA_PACKAGES]" "Extra apt packages to install (blank = none)" "${CFG[EXTRA_PACKAGES]}"
    ask_valid "CFG[BACKUP_DIR]" "Backup folder" "${CFG[BACKUP_DIR]}" v_path "absolute path without spaces"
    ask_valid "CFG[BACKUP_KEEP]" "Backups to keep" "${CFG[BACKUP_KEEP]}" v_num "a number"
    ask_valid "CFG[BACKUP_FORMAT]" "Default backup format (host = this host only; portable = passphrase-encrypted)" "${CFG[BACKUP_FORMAT]}" v_bformat "host or portable"
    ask_valid "CFG[BACKUP_STOP_STACK]" "Stop containers during backups for consistent databases (yes/no)" "${CFG[BACKUP_STOP_STACK]}" v_yesno "yes or no"
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
    cfg_paths; cfg_access; cfg_network; cfg_manual_cert; cfg_cert_transfer; cfg_storage MEDIA; cfg_storage DATA
    cfg_account; cfg_services; cfg_vpn_email; cfg_stack
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
        printf '   1) Paths              media=%s data=%s\n' "${CFG[FOLDER_FOR_MEDIA]}" "${CFG[FOLDER_FOR_DATA]}"
        printf '   2) Access / certs     %s, certificate=%s\n' "${CFG[ACCESS_MODE]}" "${CFG[CERT_MODE]}"
        printf '   3) Domain / network   %s  ip=%s subnet=%s\n' "${CFG[DOMAIN]:-<unset>}" "${CFG[LOCAL_DOCKER_IP]}" "${CFG[LOCAL_SUBNET]}"
        printf '   4) Media storage      %s\n' "$(storage_desc MEDIA)"
        printf '   5) App-data storage   %s\n' "$(storage_desc DATA)"
        printf '   6) Service account    %s\n' "${CFG[SERVICE_USER]}"
        printf '   7) Services           preset=%s player=%s tailscale=%s\n' "${CFG[SERVICE_PRESET]}" "${CFG[PLAYER]}" "${CFG[TAILSCALE_CONTROL]}"
        printf '   8) VPN / email        %s / %s\n' "${CFG[VPN_TYPE]}" "${CFG[VPN_SERVICE_PROVIDER]}"
        printf '   9) Upstream / secrets / backups  %s %s mode=%s\n' "${CFG[UPSTREAM_REF]:0:12}" "${CFG[UPSTREAM_VARIANT]}" "${CFG[SECRETS_MODE]}"
        printf '   D) Re-run detection   T) Test share mount   V) View all\n'
        printf '   W) Save   A) Save + apply   0) Back\n'
        read -rp "  Choice: " ch || return 0
        case "${ch,,}" in
            1) cfg_paths; dirty=1 ;;
            2) cfg_access; cfg_manual_cert; cfg_cert_transfer; [[ "${CFG[CERT_MODE]}" == letsencrypt ]] || CFG[CLOUDFLARE_DNS_ZONE]=${CFG[DOMAIN]}
               [[ "${CFG[SERVICE_PRESET]}" == custom ]] || apply_preset; dirty=1 ;;
            3) cfg_network; dirty=1 ;;
            4) cfg_storage MEDIA; dirty=1 ;;
            5) cfg_storage DATA; dirty=1 ;;
            6) cfg_account; dirty=1 ;;
            7) cfg_services; dirty=1 ;;
            8) cfg_vpn_email; dirty=1 ;;
            9) cfg_stack; dirty=1 ;;
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
    local app port z; z=$(tls_zone)
    for app in HOMEPAGE HOMARR PORTAINER AUTHENTIK GUACAMOLE PLEX JELLYFIN AUDIOBOOKSHELF SEERR QBITTORRENT SABNZBD PROWLARR SONARR RADARR LIDARR; do
        svc_enabled "${app,,}" || continue
        port=$(env_get "$envf" "WEBUI_PORT_$app" || true)
        [[ -n "$port" ]] || continue
        if svc_enabled traefik; then printf '  %-15s http://%s:%-6s https://%s.%s\n' "${app,,}" "$ip" "$port" "${app,,}" "$z"
        else printf '  %-15s http://%s:%s\n' "${app,,}" "$ip" "$port"; fi
    done
    if svc_enabled traefik && [[ "${CFG[CERT_MODE]}" == selfsigned ]]; then
        printf '\n  Self-signed: import %s/ca.crt on your devices (and point *.%s at %s in your DNS).\n' "$(tls_dir)" "$z" "$ip"
    fi
    if svc_enabled tailscale && [[ "${CFG[TAILSCALE_CONTROL]}" == tailscale ]]; then
        printf '  Tailscale: approve the advertised routes / exit node for "exit-node" in the Tailscale admin console.\n'
    fi
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
        [[ -f "$FOLDER_FOR_DATA/postgresql/PG_VERSION" ]] && [[ -z "$(docker ps -q --filter "name=^${PG_CONTAINER}$")" ]] \
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
    CFG[CERT_MODE]=letsencrypt; cert_units     # removes the certificate timer/watcher
    cert_push_remove
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
    printf '\n  %sLogs%s\n  1) List installer run logs\n  2) View previous run installer log\n  3) Container logs\n  0) Back\n' "$B" "$NC"
    local ch s n; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) ls -1t "$MS_LOG_DIR"/installer-*.log 2>/dev/null | head -n "$LOG_KEEP" | sed 's/^/  /' ;;
        2) local f; f=$(ls -1t "$MS_LOG_DIR"/installer-*.log 2>/dev/null | sed -n 2p); [[ -n "$f" ]] && ${PAGER:-less} "$f" ;;
        3) ask s "Service (blank = all)" ""; ask n "Lines" "100"; [[ "$n" =~ ^[0-9]+$ ]] || n=100
           menu_action show_logs "$n" "$s" ;;
    esac
}

# -----------------------------------------------------------------------------
# SETTINGS FROM THE CLI (--show-config, --set KEY VALUE)
# -----------------------------------------------------------------------------
declare -A CONF_HELP=(
    [FOLDER_FOR_MEDIA]="media library + downloads (share mountpoint when remote)"
    [FOLDER_FOR_DATA]="app configs + databases"
    [FOLDER_FOR_YAML]="compose file, .env, templates, wrappers (local)"
    [DOMAIN]="domain for app hostnames"
    [CLOUDFLARE_DNS_ZONE]="hostname base in Traefik labels; Cloudflare zone for letsencrypt"
    [CLOUDFLARE_EMAIL]="Cloudflare account email (letsencrypt)"
    [TIMEZONE]="IANA timezone"
    [LOCAL_SUBNET]="auto | LAN CIDR"
    [LOCAL_DOCKER_IP]="auto | host LAN IPv4"
    [SERVICE_USER]="service account (PUID/PGID)"
    [SERVICE_UID]="blank = auto (set for NFS)"
    [SERVICE_GID]="blank = auto (set for NFS)"
    [ADMIN_DOCKER_GROUP]="yes | no: add sudo user to docker group"
    [VPN_TYPE]="openvpn | wireguard"
    [VPN_SERVICE_PROVIDER]="Gluetun provider name"
    [SERVER_REGIONS]="Gluetun server regions (blank = default)"
    [EMAIL_SERVER_HOST]="SMTP host for Authentik (blank = none)"
    [EMAIL_SERVER_PORT]="SMTP port"
    [EMAIL_ADDRESS]="SMTP username/address"
    [EMAIL_SENDER]="email sender"
    [DISABLED_SERVICES]="never started, folders kept (setting it makes the preset custom)"
    [REMOVED_SERVICES]="never started, no app-data folder (setting it makes the preset custom)"
    [UPSTREAM_REPO]="owner/repo of MediaStack"
    [UPSTREAM_REF]="pinned commit SHA (or tag/branch)"
    [UPSTREAM_VARIANT]="full-download-vpn | mini-download-vpn | no-download-vpn"
    [EXTRA_PACKAGES]="extra apt packages"
    [CHOWN_MEDIA_RECURSIVE]="yes | no: re-own whole library on every apply"
    [SECRETS_MODE]="vault | env"
    [SECRETS_BACKEND]="auto | systemd-creds | openssl (then --rekey)"
    [MEDIA_STORAGE]="local | smb | nfs | external"
    [MEDIA_REMOTE]="//server/share or server:/export"
    [MEDIA_SMB_DOMAIN]="SMB domain/workgroup"
    [MEDIA_SMB_VERSION]="auto | 3.1.1 | 3.0 | 2.1 | 2.0 | 1.0"
    [MEDIA_NFS_VERSION]="auto | 4.2 | 4.1 | 4 | 3"
    [MEDIA_MOUNT_OPTS]="extra mount options"
    [MEDIA_MOUNT_REQUIRED]="yes | no: Docker waits for the mount at boot"
    [DATA_STORAGE]="local | nfs | external"
    [DATA_REMOTE]="server:/export"
    [DATA_NFS_VERSION]="auto | 4.2 | 4.1 | 4 | 3"
    [DATA_MOUNT_OPTS]="extra mount options"
    [DATA_MOUNT_REQUIRED]="yes | no: Docker waits for the mount at boot"
    [ACCESS_MODE]="internet | lan"
    [CERT_MODE]="letsencrypt | selfsigned | manual | fetch (pull over scp daily) | push (received over SSH)"
    [SERVER_COUNTRIES]="Gluetun server filter: countries, comma-separated (blank = any)"
    [SERVER_CITIES]="Gluetun server filter: cities, comma-separated (blank = any)"
    [SERVER_HOSTNAMES]="Gluetun server filter: server hostnames, comma-separated (blank = any)"
    [VPN_SERVERS_UPDATE_PERIOD]="Gluetun updates its VPN server list this often, e.g. 480h (min 360h); off = never"
    [VPN_UPDATER_PROTON_EMAIL]="protonvpn: Proton account email for server-list updates (password in the vault)"
    [CERT_FETCH_SOURCE]="fetch mode: user@host:/folder holding the certificate files"
    [CERT_FETCH_CERT]="fetch mode: full-chain certificate file name in that folder"
    [CERT_FETCH_KEY]="fetch mode: private key file name in that folder"
    [CERT_PUSH_USER]="push mode: local user the pushing machine logs in as"
    [CERT_PUSH_FROM]="push mode: IPs/CIDRs the push key is accepted from (blank = any)"
    [TLS_CERT_FILE]="manual mode: PEM full-chain certificate path"
    [TLS_KEY_FILE]="manual mode: PEM private key path"
    [SERVICE_PRESET]="core | full | custom"
    [PLAYER]="jellyfin | plex | both (Core preset)"
    [TAILSCALE_CONTROL]="tailscale (official) | headscale (self-hosted)"
    [BACKUP_DIR]="where backups are written"
    [BACKUP_KEEP]="number of backups kept"
    [BACKUP_FORMAT]="host | portable (passphrase-encrypted)"
    [BACKUP_PASSPHRASE_FILE]="file whose first line is the portable-backup passphrase"
    [BACKUP_STOP_STACK]="yes | no: stop containers while backing up"
    [VPN_CUSTOM_OVPN_FILE]="provider custom + OpenVPN: your .ovpn (copied to Gluetun)"
    [VPN_ENDPOINT_IP]="provider custom + WireGuard: server IP"
    [VPN_ENDPOINT_PORT]="provider custom + WireGuard: server port"
    [WIREGUARD_PUBLIC_KEY]="provider custom + WireGuard: server public key"
    [WIREGUARD_ADDRESSES]="WireGuard: interface address(es) from wg0.conf"
)

validate_key() {   # validate_key KEY VALUE
    local k=$1 v=$2
    [[ "$v" != *$'\n'* && "$v" != *"'"* ]] || return 1
    case "$k" in
        FOLDER_FOR_MEDIA|FOLDER_FOR_DATA|FOLDER_FOR_YAML|BACKUP_DIR) v_path "$v" ;;
        DOMAIN|CLOUDFLARE_DNS_ZONE) v_domain "$v" ;;
        TIMEZONE) [[ "$v" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$ ]] ;;
        LOCAL_SUBNET) v_cidr_auto "$v" ;;
        LOCAL_DOCKER_IP) v_ip_auto "$v" ;;
        SERVICE_USER) v_user "$v" ;;
        SERVICE_UID|SERVICE_GID) v_num_opt "$v" ;;
        ADMIN_DOCKER_GROUP|CHOWN_MEDIA_RECURSIVE|MEDIA_MOUNT_REQUIRED|DATA_MOUNT_REQUIRED|BACKUP_STOP_STACK) v_yesno "$v" ;;
        VPN_TYPE) v_vpn "$v" ;;
        EMAIL_SERVER_PORT|BACKUP_KEEP) v_num "$v" ;;
        UPSTREAM_REPO) [[ "$v" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ;;
        UPSTREAM_REF) [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] ;;
        UPSTREAM_VARIANT) v_variant "$v" ;;
        SECRETS_MODE) v_mode "$v" ;;
        SECRETS_BACKEND) v_backend "$v" ;;
        MEDIA_STORAGE) v_mtype "$v" ;;
        DATA_STORAGE) v_dtype "$v" ;;
        MEDIA_REMOTE) [[ -z "$v" ]] || v_smb_remote "$v" || v_nfs_remote "$v" ;;
        DATA_REMOTE) [[ -z "$v" ]] || v_nfs_remote "$v" ;;
        MEDIA_SMB_VERSION) v_smbver "$v" ;;
        MEDIA_NFS_VERSION|DATA_NFS_VERSION) v_nfsver "$v" ;;
        ACCESS_MODE) v_access "$v" ;;
        CERT_MODE) v_cert "$v" ;;
        CERT_FETCH_SOURCE) v_fetchsrc "$v" ;;
        CERT_FETCH_CERT|CERT_FETCH_KEY) v_fname "$v" ;;
        CERT_PUSH_USER) v_user "$v" ;;
        CERT_PUSH_FROM) v_from_opt "$v" ;;
        TLS_CERT_FILE|TLS_KEY_FILE|BACKUP_PASSPHRASE_FILE) [[ -z "$v" ]] || v_path "$v" ;;
        SERVICE_PRESET) v_preset "$v" ;;
        PLAYER) v_player "$v" ;;
        TAILSCALE_CONTROL) v_tscontrol "$v" ;;
        BACKUP_FORMAT) v_bformat "$v" ;;
        VPN_CUSTOM_OVPN_FILE) [[ -z "$v" ]] || v_path "$v" ;;
        VPN_ENDPOINT_IP) [[ -z "$v" ]] || valid_ipv4 "$v" ;;
        VPN_ENDPOINT_PORT) [[ -z "$v" ]] || v_num "$v" ;;
        WIREGUARD_PUBLIC_KEY) [[ -z "$v" || "$v" =~ ^[A-Za-z0-9+/]{42,43}=?$ ]] ;;
        WIREGUARD_ADDRESSES) return 0 ;;
        VPN_SERVICE_PROVIDER) [[ -n "$v" ]] ;;
        SERVER_REGIONS|SERVER_COUNTRIES|SERVER_CITIES|SERVER_HOSTNAMES) [[ "$v" != *[=\[\]#/]* ]] ;;
        VPN_SERVERS_UPDATE_PERIOD) [[ "$v" == off || "$v" =~ ^[0-9]+h$ ]] ;;
        VPN_UPDATER_PROTON_EMAIL) [[ -z "$v" || "$v" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ;;
        CLOUDFLARE_EMAIL|EMAIL_SERVER_HOST|EMAIL_ADDRESS|EMAIL_SENDER| \
        DISABLED_SERVICES|REMOVED_SERVICES|EXTRA_PACKAGES|MEDIA_SMB_DOMAIN|MEDIA_MOUNT_OPTS|DATA_MOUNT_OPTS) return 0 ;;
        *) return 1 ;;
    esac
}

show_config() {
    ensure_config
    local k
    printf '\n  %sSettings%s (%s)\n' "$B" "$NC" "$CONF_FILE"
    for k in "${CONF_KEYS[@]}"; do
        printf '    %-24s %-34s %s%s%s\n' "$k" "${CFG[$k]:-(empty)}" "$D" "${CONF_HELP[$k]:-}" "$NC"
    done
    printf '\n  Secrets are not shown; see the Secrets menu (--secrets).\n'
}

cli_set() {   # cli_set KEY VALUE
    local k=$1 v=$2
    require_config
    in_list "$k" "${CONF_KEYS[@]}" || die "Unknown setting '$k'. See --show-config for valid keys."
    case "$k" in
        MEDIA_REMOTE) [[ "$v" == *:/* ]] && v=$(normalize_remote nfs "$v") || { [[ -n "$v" ]] && v=$(normalize_remote smb "$v"); } ;;
        DATA_REMOTE)  [[ -n "$v" ]] && v=$(normalize_remote nfs "$v") ;;
        FOLDER_FOR_*) v=${v%/} ;;
    esac
    validate_key "$k" "$v" || die "Invalid value for $k: '$v' (${CONF_HELP[$k]:-})"
    CFG[$k]=$v
    case "$k" in
        DISABLED_SERVICES|REMOVED_SERVICES)
            [[ "${CFG[SERVICE_PRESET]}" == custom ]] || { CFG[SERVICE_PRESET]=custom; log_info "SERVICE_PRESET is now custom"; } ;;
        SERVICE_PRESET|PLAYER|ACCESS_MODE|TAILSCALE_CONTROL)
            if [[ "${CFG[SERVICE_PRESET]}" != custom ]]; then apply_preset; log_info "Preset '${CFG[SERVICE_PRESET]}' re-applied"; fi ;;
        DOMAIN|CERT_MODE)
            [[ "${CFG[CERT_MODE]}" == letsencrypt ]] || CFG[CLOUDFLARE_DNS_ZONE]=${CFG[DOMAIN]} ;;
    esac
    [[ "$k" == CERT_MODE && "$v" == manual && ( -z "${CFG[TLS_CERT_FILE]}" || -z "${CFG[TLS_KEY_FILE]}" ) ]] \
        && log_warn "Also set TLS_CERT_FILE and TLS_KEY_FILE before applying."
    [[ "$k" == CERT_MODE && "$v" == fetch && -z "${CFG[CERT_FETCH_SOURCE]}" ]] \
        && log_warn "Also set CERT_FETCH_SOURCE, and create the fetch key (--cert-fetch-key), before applying."
    [[ "$k" == CERT_MODE && "$v" == push ]] && log_info "Set up the receiver with --cert-push-setup PUBKEY_FILE."
    save_config
    log_ok "$k=$v saved. Run --apply (or --start) to put it into effect."
    report_dependencies warn
}

# -----------------------------------------------------------------------------
# RESTART / LOGS
# -----------------------------------------------------------------------------
stack_restart() {
    require_config; resolve_runtime; load_secrets
    log_step "Restarting MediaStack containers"
    run_logged compose_run restart
    log_ok "Containers restarted (no converge; use --apply after changing settings)"
}

show_logs() {   # show_logs [N] [SERVICE]
    local n=${1:-100} svc=${2:-}
    require_config; resolve_runtime; load_secrets
    if [[ -n "$svc" ]]; then compose_run logs --no-color --tail "$n" "$svc"
    else compose_run logs --no-color --tail "$n"; fi
}

# -----------------------------------------------------------------------------
# BACKUP / RESTORE
#   host     : tar.gz of settings + vault + key, compose folder and app data (this host)
#   portable : the same, with the vault decrypted inside an archive encrypted with a
#              passphrase (AES-256-CBC, PBKDF2-SHA256) so it restores on any host
#   Media is never included. Containers are stopped while archiving (BACKUP_STOP_STACK).
# -----------------------------------------------------------------------------
readonly PORTABLE_MAGIC="MEDIASTACK-BACKUP v1 portable"
readonly PORTABLE_ITER=600000
readonly PASSPHRASE_MIN=12
readonly BACKUP_META="_mediastack_meta"
BACKUP_FORMAT_OPT=""
PASSPHRASE_FILE_OPT=""
STACK_PAUSED=0
BACKUP_EXCLUDES=( --exclude='*/Plex Media Server/Cache' --exclude='*/Plex Media Server/Crash Reports'
                  --exclude='*/jellyfin/cache' --exclude='*/jellyfin/transcodes' --exclude='*/tdarr_transcode_cache' )

backup_items() {   # paths relative to / (compose folder skipped when inside app data)
    [[ -d "$MS_CONF_DIR" ]] && printf '%s\n' "${MS_CONF_DIR#/}"
    if [[ -d "$FOLDER_FOR_YAML" && "$FOLDER_FOR_YAML" != "$FOLDER_FOR_DATA" && "$FOLDER_FOR_YAML" != "$FOLDER_FOR_DATA"/* ]]; then
        printf '%s\n' "${FOLDER_FOR_YAML#/}"
    fi
    [[ -d "$FOLDER_FOR_DATA" ]] && printf '%s\n' "${FOLDER_FOR_DATA#/}"
    return 0
}

list_backups() {
    [[ -d "${CFG[BACKUP_DIR]}" ]] || return 0
    find "${CFG[BACKUP_DIR]}" -maxdepth 1 -type f \( -name 'mediastack-*.tar.gz' -o -name 'mediastack-*.msbak' \) \
        -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-
}

prune_backups() {
    local old
    while IFS= read -r old; do rm -f -- "$old"; log_info "Pruned $old"; done \
        < <(list_backups | tail -n +$(( CFG[BACKUP_KEEP] + 1 )))
}

backup_pause() {
    STACK_PAUSED=0
    [[ "${CFG[BACKUP_STOP_STACK]}" == yes ]] && docker_up || return 0
    [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME")" ]] || return 0
    log_info "Stopping containers for a consistent backup"
    compose_run stop >/dev/null 2>&1 && STACK_PAUSED=1
    return 0
}
backup_resume() {
    if (( STACK_PAUSED )); then
        compose_run start >/dev/null 2>&1 && log_ok "Containers started again" || log_warn "Restarting containers failed; run --start"
        STACK_PAUSED=0
    fi
    return 0
}

do_backup() {
    require_config; resolve_runtime; load_secrets
    local fmt=${BACKUP_FORMAT_OPT:-${CFG[BACKUP_FORMAT]}}
    if [[ "$fmt" == portable ]]; then do_backup_portable; return; fi
    log_step "Backup (this host)"
    local out rc=0; out="${CFG[BACKUP_DIR]}/mediastack-$(date +%Y%m%d-%H%M%S).tar.gz"
    local -a items; mapfile -t items < <(backup_items)
    (( ${#items[@]} )) || die "Nothing to back up."
    if (( DRY_RUN )); then run tar -czf "$out" --numeric-owner -C / "${items[@]}"; return 0; fi
    install -d -m 0700 -o root -g root "${CFG[BACKUP_DIR]}"
    backup_pause
    ( umask 077; tar -czf "$out.part" --numeric-owner "${BACKUP_EXCLUDES[@]}" -C / "${items[@]}" ) || rc=$?
    backup_resume
    (( rc <= 1 )) || { rm -f -- "$out.part"; die "tar failed (rc=$rc)"; }
    (( rc == 1 )) && log_warn "Some files changed while being archived (tar rc=1)."
    mv -f -- "$out.part" "$out"; chmod 600 "$out"
    log_ok "Backup written: $out ($(du -h "$out" | cut -f1))"
    log_warn "It holds your settings, the vault AND its key, and all app data: keep it private."
    [[ "$(secrets_file_backend)" == systemd-creds ]] && \
        log_warn "Vault backend is systemd-creds (host/TPM-bound): this backup restores on THIS host only. Use --backup --portable for another host."
    prune_backups
}

# get_passphrase VAR new|existing  -- --passphrase-file, $MS_BACKUP_PASSPHRASE, BACKUP_PASSPHRASE_FILE, prompt
get_passphrase() {
    local __var=$1 mode=$2 __p="" __src="" __b=""
    if [[ -n "$PASSPHRASE_FILE_OPT" ]]; then __src=$PASSPHRASE_FILE_OPT
    elif [[ -n "${MS_BACKUP_PASSPHRASE:-}" ]]; then __p=$MS_BACKUP_PASSPHRASE
    elif [[ -n "${CFG[BACKUP_PASSPHRASE_FILE]:-}" && -f "${CFG[BACKUP_PASSPHRASE_FILE]}" ]]; then __src=${CFG[BACKUP_PASSPHRASE_FILE]}
    fi
    if [[ -n "$__src" ]]; then
        [[ -r "$__src" ]] || die "Cannot read passphrase file $__src"
        [[ "$(stat -c %a "$__src")" =~ ^[4-7]00$ ]] || log_warn "$__src is readable by others; chmod 600 it."
        IFS= read -r __p <"$__src" || true
    elif [[ -z "$__p" ]]; then
        is_tty || die "A portable backup needs a passphrase: --passphrase-file FILE, MS_BACKUP_PASSPHRASE, or BACKUP_PASSPHRASE_FILE."
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

portable_encrypt() {   # portable_encrypt PASS < plaintext > file
    printf '%s kdf=pbkdf2-sha256 iter=%s cipher=aes-256-cbc\n' "$PORTABLE_MAGIC" "$PORTABLE_ITER"
    openssl enc -aes-256-cbc -pbkdf2 -iter "$PORTABLE_ITER" -md sha256 -salt -pass fd:3 3<<<"$1"
}
is_portable_backup() { [[ "$(head -c ${#PORTABLE_MAGIC} "$1" 2>/dev/null)" == "$PORTABLE_MAGIC" ]]; }
portable_decrypt() {   # portable_decrypt FILE PASS > plaintext
    local hdr iter
    hdr=$(head -n1 "$1")
    [[ "$hdr" == "$PORTABLE_MAGIC "* ]] || return 1
    iter=$(sed -n 's/.* iter=\([0-9]*\).*/\1/p' <<<"$hdr")
    [[ "$iter" =~ ^[0-9]+$ ]] || return 1
    tail -c +$(( ${#hdr} + 2 )) "$1" | openssl enc -d -aes-256-cbc -pbkdf2 -iter "$iter" -md sha256 -pass fd:3 3<<<"$2"
}

do_backup_portable() {
    log_step "Backup (portable)"
    local out pp st k; out="${CFG[BACKUP_DIR]}/mediastack-$(date +%Y%m%d-%H%M%S).msbak"
    local -a items=()
    [[ -d "$FOLDER_FOR_YAML" && "$FOLDER_FOR_YAML" != "$FOLDER_FOR_DATA" && "$FOLDER_FOR_YAML" != "$FOLDER_FOR_DATA"/* ]] && items+=("${FOLDER_FOR_YAML#/}")
    [[ -d "$FOLDER_FOR_DATA" ]] && items+=("${FOLDER_FOR_DATA#/}")
    if (( DRY_RUN )); then log_info "[dry-run] would write the passphrase-encrypted archive $out (${items[*]})"; return 0; fi
    get_passphrase pp new
    install -d -m 0700 -o root -g root "${CFG[BACKUP_DIR]}"
    st=$(mktemp -d "${CFG[BACKUP_DIR]}/.stage.XXXXXX"); chmod 700 "$st"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$st'; trap - RETURN" RETURN
    mkdir -p "$st/$BACKUP_META"
    cp "$CONF_FILE" "$st/$BACKUP_META/host.conf"
    ( umask 077
      for k in "${!SECRETS[@]}"; do printf '%s=%s\n' "$k" "$(printf '%s' "${SECRETS[$k]}" | base64 -w0)"; done >"$st/$BACKUP_META/secrets.env" )
    [[ -d "$(tls_dir)" ]] && cp -a "$(tls_dir)" "$st/$BACKUP_META/tls"
    printf 'format=1\ncreated=%s\nhost=%s\ninstaller=%s\nupstream_ref=%s\ndata_dir=%s\nyaml_dir=%s\nmedia_dir=%s\n' \
        "$(date '+%F %T %z')" "$(hostname -s 2>/dev/null || hostname)" "$SCRIPT_VERSION" "${CFG[UPSTREAM_REF]}" \
        "$FOLDER_FOR_DATA" "$FOLDER_FOR_YAML" "$FOLDER_FOR_MEDIA" >"$st/$BACKUP_META/manifest"
    ( cd "$st/$BACKUP_META" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS )
    backup_pause
    local rc=0
    ( umask 077; tar -czf - --numeric-owner "${BACKUP_EXCLUDES[@]}" -C "$st" "$BACKUP_META" -C / "${items[@]}" \
          | portable_encrypt "$pp" >"$out.part" ) || rc=$?
    backup_resume
    (( rc == 0 )) || { rm -f -- "$out.part"; die "Creating the portable backup failed (rc=$rc)."; }
    mv -f -- "$out.part" "$out"; chmod 600 "$out"
    log_ok "Portable backup written: $out ($(du -h "$out" | cut -f1))"
    log_info "Encrypted with your passphrase (AES-256, PBKDF2-SHA256 x$PORTABLE_ITER). Restore on any host with:"
    log_info "  sudo ./mediastack-installer.sh --restore $(basename "$out")"
    log_warn "Without the passphrase this backup cannot be restored. Store the passphrase separately."
    prune_backups
}

archive_conf_value() {   # archive_conf_value CONFTEXT KEY
    local line
    line=$(grep -m1 -E "^$2=" <<<"$1") || return 0
    conf_unquote "${line#*=}"
}

move_aside() {   # move_aside PATH STAMP -- keep the current copy (contents kept in place for mountpoints)
    local p=$1 ts=$2
    [[ -e "$p" ]] || return 0
    if is_mounted "$p"; then log_warn "$p is a mountpoint; restoring over its current contents"; return 0; fi
    mv -- "$p" "$p.pre-restore-$ts"
    log_info "Previous $p kept as $p.pre-restore-$ts"
}

do_restore() {
    local file=$1
    ensure_config
    local cand
    for cand in "$file" "${CFG[BACKUP_DIR]:-/var/backups/mediastack}/$file" "$SCRIPT_DIR/$file"; do
        if [[ -f "$cand" ]]; then file=$cand; break; fi
    done
    [[ -f "$file" ]] || die "No such file: $file (looked here, in BACKUP_DIR and next to the installer)"
    if is_portable_backup "$file"; then do_restore_portable "$file"; return; fi
    log_step "Restore from $file"
    ensure_config
    local list aconf adata ayaml rel bad ts host_new=0
    [[ -f "$CONF_FILE" ]] || host_new=1
    list=$(tar -tzf "$file") || die "Not a readable tar.gz: $file"
    aconf=$(tar -xzOf "$file" "${CONF_FILE#/}" 2>/dev/null) || die "$file has no ${CONF_FILE#/}: not a mediastack-installer host backup."
    adata=$(archive_conf_value "$aconf" FOLDER_FOR_DATA); ayaml=$(archive_conf_value "$aconf" FOLDER_FOR_YAML)
    [[ -n "$adata" && -n "$ayaml" ]] || die "The archive's settings lack FOLDER_FOR_DATA/FOLDER_FOR_YAML."
    safe_path "$adata" && safe_path "$ayaml" || die "The archive points at unsafe folders ($adata, $ayaml)."
    if grep -qE '(^|/)\.\.(/|$)' <<<"$list"; then die "The archive contains '..' paths; refusing."; fi
    bad=$(grep -vE "^(${MS_CONF_DIR#/}|${adata#/}|${ayaml#/})(/|$)" <<<"$list" | head -n3 || true)
    [[ -z "$bad" ]] || die "The archive contains paths outside the MediaStack folders (e.g. $bad); refusing."
    local vb; vb=$(tar -xzOf "$file" "${SECRETS_FILE#/}" 2>/dev/null | head -n1 | sed -n 's/.*backend=//p')
    [[ "$vb" == systemd-creds ]] && log_warn "This archive's vault is host/TPM-bound (systemd-creds): it restores only on the host that made it."
    log_warn "This replaces $MS_CONF_DIR, $ayaml and $adata with the archive's copies (current ones are kept as *.pre-restore-*)."
    confirm_typed RESTORE || { log_info "Cancelled."; return 0; }
    if (( DRY_RUN )); then log_info "[dry-run] would stop the stack, move the folders aside, extract and apply"; return 0; fi
    if [[ -f "$CONF_FILE" ]]; then ( resolve_runtime; load_secrets; stack_down_if_running ) || true; fi
    ts=$(date +%Y%m%d-%H%M%S)
    for rel in "$MS_CONF_DIR" "$ayaml" "$adata"; do move_aside "$rel" "$ts"; done
    tar -xzf "$file" -C / --numeric-owner
    log_ok "Archive extracted"
    restore_finish "$host_new"
}

# restore_host_settings STAGE -- fresh host: adopt the backup's settings minus host-specific ones
restore_host_settings() {
    local st=$1 saved=$CONF_FILE
    [[ -f "$st/host.conf" ]] || return 0
    CONF_FILE="$st/host.conf"; CONFIG_LOADED=0; load_config; CONF_FILE=$saved
    CFG[SERVICE_UID]=""; CFG[SERVICE_GID]=""; CFG[SECRETS_BACKEND]=auto
    if [[ "${CFG[LOCAL_DOCKER_IP]}" != auto ]] && ! grep -qw -- "${CFG[LOCAL_DOCKER_IP]}" <<<"$(ip -o addr show 2>/dev/null)"; then
        log_warn "LOCAL_DOCKER_IP ${CFG[LOCAL_DOCKER_IP]} is not on this host; using auto."; CFG[LOCAL_DOCKER_IP]=auto; CFG[LOCAL_SUBNET]=auto
    fi
    if [[ "${CFG[CERT_MODE]}" == manual && ! -f "${CFG[TLS_CERT_FILE]}" ]]; then
        log_warn "Manual certificate ${CFG[TLS_CERT_FILE]} is not on this host; copy it there before applying."
    fi
    CONFIG_LOADED=1
}

do_restore_portable() {
    local file=$1 pp st0 st line k is_new=0 ts b_data b_yaml
    log_step "Restore portable backup $file"
    ensure_config
    get_passphrase pp existing
    st0=$(mktemp -d); chmod 700 "$st0"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$st0'; trap - RETURN" RETURN
    portable_decrypt "$file" "$pp" 2>/dev/null | tar -xzf - -C "$st0" --no-same-owner "$BACKUP_META" 2>/dev/null \
        || die "Cannot decrypt $file: wrong passphrase, or the file is damaged."
    local m="$st0/$BACKUP_META"
    [[ -f "$m/manifest" && -f "$m/secrets.env" && -f "$m/SHA256SUMS" ]] || die "$file is not a complete mediastack-installer backup."
    ( cd "$m" && sha256sum --quiet -c SHA256SUMS ) >/dev/null 2>&1 || die "Checksum mismatch: the backup is damaged."
    b_data=$(sed -n 's/^data_dir=//p' "$m/manifest"); b_yaml=$(sed -n 's/^yaml_dir=//p' "$m/manifest")
    log_ok "Passphrase OK: made on $(sed -n 's/^host=//p' "$m/manifest") at $(sed -n 's/^created=//p' "$m/manifest") (installer v$(sed -n 's/^installer=//p' "$m/manifest"))"
    [[ -f "$CONF_FILE" ]] || is_new=1
    if (( is_new )); then log_info "No install on this host: adopting the backup's settings (host-specific values reset)."
    else log_info "Keeping this host's settings and folders ($CONF_FILE); restoring app data, compose folder, secrets and TLS CA."; fi
    log_warn "This replaces the app data and compose folders (current ones kept as *.pre-restore-*) and the vault contents."
    confirm_typed RESTORE || { log_info "Cancelled."; return 0; }
    if (( DRY_RUN )); then log_info "[dry-run] would stop, restore data + secrets, and apply"; return 0; fi
    if (( is_new )); then restore_host_settings "$m"; else ( resolve_runtime; load_secrets; stack_down_if_running ) || true; fi
    resolve_runtime
    mkdir -p "$(dirname "$FOLDER_FOR_DATA")"
    st=$(mktemp -d "$(dirname "$FOLDER_FOR_DATA")/.ms-restore.XXXXXX"); chmod 700 "$st"
    portable_decrypt "$file" "$pp" 2>/dev/null | tar -xzf - -C "$st" --numeric-owner \
        || { rm -rf -- "$st"; die "Extracting $file failed."; }
    ts=$(date +%Y%m%d-%H%M%S)
    restore_tree "$st/${b_data#/}" "$FOLDER_FOR_DATA" "$ts"
    if [[ "$b_yaml" != "$b_data" && "$b_yaml" != "$b_data"/* ]]; then restore_tree "$st/${b_yaml#/}" "$FOLDER_FOR_YAML" "$ts"; fi
    rm -rf -- "$st"
    mkdir -p "$MS_CONF_DIR"; chmod 700 "$MS_CONF_DIR"
    if [[ -d "$m/tls" ]]; then rm -rf -- "$(tls_dir)"; cp -a "$m/tls" "$(tls_dir)"; chmod 700 "$(tls_dir)"; fi
    SECRETS=()
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
        k=${BASH_REMATCH[1]}
        in_list "$k" "${SECRET_KEYS[@]}" && SECRETS[$k]=$(printf '%s' "${BASH_REMATCH[2]}" | base64 -d)
    done <"$m/secrets.env"
    SECRETS_LOADED=1
    save_secrets
    (( is_new )) && save_config
    restore_finish "$is_new"
}

restore_tree() {   # restore_tree SRC DST STAMP
    local src=$1 dst=$2 ts=$3
    [[ -d "$src" ]] || { log_warn "Backup has no $(basename "$dst") folder; skipped"; return 0; }
    if is_mounted "$dst"; then
        log_warn "$dst is a mountpoint; copying the backup over its contents"
        cp -a "$src/." "$dst/"
    else
        move_aside "$dst" "$ts"
        mkdir -p "$(dirname "$dst")"; mv -- "$src" "$dst"
    fi
    log_ok "Restored $dst"
}

restore_finish() {   # restore_finish FRESH
    CONFIG_LOADED=0; SECRETS_LOADED=0
    load_config; resolve_runtime; load_secrets
    if (( $1 )); then preflight; install_docker; fi
    ensure_service_account
    install_self
    stack_apply nopull
    log_ok "Restore complete"
}

secrets_rekey() {
    require_config; load_secrets
    [[ -f "$SECRETS_FILE" ]] || die "No vault to re-encrypt yet."
    log_step "Re-encrypting the vault (backend: $(secrets_backend_resolve))"
    save_secrets
}

menu_backup() {
    ensure_config
    printf '\n  %sBackup / restore%s  (folder: %s, keep %s)\n' "$B" "$NC" "${CFG[BACKUP_DIR]}" "${CFG[BACKUP_KEEP]}"
    printf '  1) Back up now (this host)\n  2) Portable backup (passphrase-encrypted)\n  3) List backups\n  4) Restore...\n  0) Back\n'
    local ch f n; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) BACKUP_FORMAT_OPT=host;     menu_action do_backup; BACKUP_FORMAT_OPT="" ;;
        2) BACKUP_FORMAT_OPT=portable; menu_action do_backup; BACKUP_FORMAT_OPT="" ;;
        3) list_backups | nl -w3 -s') ' | sed 's/^/  /' ;;
        4) local -a bl; mapfile -t bl < <(list_backups)
           (( ${#bl[@]} )) && printf '%s\n' "${bl[@]}" | nl -w3 -s') ' | sed 's/^/  /'
           ask f "Number or path of the backup to restore" ""
           if [[ "$f" =~ ^[0-9]+$ ]] && (( f >= 1 && f <= ${#bl[@]} )); then n=$((f - 1)); f=${bl[$n]}; fi
           [[ -n "$f" ]] && menu_action do_restore "$f" ;;
    esac
}

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
    st "add-on rendered when on"            'CFG[DISABLED_SERVICES]=""; CFG[REMOVED_SERVICES]=""; out=$(render_override "$t/compose.yaml"); [[ "$out" == *"  audiobookshelf:"* && "$out" == *"user: \${PUID:?err}"* && "$out" != *disabled\"* ]]'
    st "add-on disabled -> profile"         'CFG[DISABLED_SERVICES]="audiobookshelf"; CFG[REMOVED_SERVICES]=""; out=$(render_override "$t/compose.yaml"); [[ "$out" == *"  audiobookshelf:"* && "$out" == *"profiles: [\"disabled\"]"* ]]'
    st "add-on removed -> absent"           'CFG[DISABLED_SERVICES]=""; CFG[REMOVED_SERVICES]="audiobookshelf"; out=$(render_override "$t/compose.yaml"); [[ "$out" != *audiobookshelf* && "$out" == *"services: {}"* ]]'
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
    # ---- v2: presets, dependencies, patches, TLS, backups (fixture compose mirrors upstream structure)
    mkdir -p "$t/y" "$t/st" "$t/conf2" "$t/data/traefik"
    cat >"$t/y/docker-compose.yaml" <<'FIX'
networks:
  mediastack:
    name: mediastack
services:
  gluetun:
    image: g
  qbittorrent:
    network_mode: "service:gluetun"
  sonarr:
    network_mode: service:gluetun
  jellyfin:
    depends_on:
      gluetun:
        condition: service_healthy
        restart: true
  plex:
    network_mode: "service:gluetun"
  traefik:
    image: t
  traefik-certs-dumper:
    image: d
  crowdsec:
    image: c
  authentik:
    depends_on:
      postgresql:
        condition: service_healthy
      valkey:
        condition: service_healthy
  postgresql:
    image: p
  valkey:
    image: v
  homarr:
    image: ghcr.io/ajnart/homarr:latest
  tailscale:
    image: ts
  headscale:
    image: hs
  headplane:
    depends_on:
      - headscale
  readarr:
    image: r
  whisparr:
    image: w
FIX
    cat >"$t/data/traefik/traefik.yaml" <<'FIX'
entryPoints:
  secureweb:
    address: :443
    http:
      tls:
        options: default
        certResolver: letsencrypt
        domains:
          - main: example.org
            sans:
              - "*.example.org"
  metrics:
    address: :8082
providers:
  file:
    directory: /etc/traefik
certificatesResolvers:
  letsencrypt:
    acme:
      storage: /letsencrypt/acme.json
      dnsChallenge:
        provider: cloudflare
experimental:
  plugins: {}
FIX
    cat >"$t/data/traefik/dynamic.yaml" <<'FIX'
tls:
  stores:
    default:
      defaultGeneratedCert:
        resolver: letsencrypt
        domain:
          main: example.org
          sans:
            - "*.example.org"
  options:
    default:
      sniStrict: true
http:
  middlewares: {}
FIX
    st_prep() { CFG[FOLDER_FOR_YAML]="$t/y"; CFG[ACCESS_MODE]=$1; CFG[PLAYER]=$2; CFG[TAILSCALE_CONTROL]=$3
                CFG[SERVICE_PRESET]=$4; CFG[CERT_MODE]=${5:-letsencrypt}; apply_preset; }
    st_on()  { local s; for s in "$@"; do [[ "$(eff_state "$s")" == on ]] || return 1; done; }
    st_off() { local s; for s in "$@"; do [[ "$(eff_state "$s")" != on ]] || return 1; done; }
    st "preset core/internet"              '( st_prep internet jellyfin tailscale core; st_on gluetun qbittorrent sonarr jellyfin traefik traefik-certs-dumper crowdsec authentik postgresql valkey tailscale audiobookshelf && st_off plex homarr headscale headplane whisparr && [[ $(svc_state readarr) == removed && -z "$(check_dependencies)" ]] )'
    st "preset core/lan"                   '( st_prep lan plex tailscale core selfsigned; st_on plex gluetun tailscale && st_off jellyfin traefik crowdsec authentik postgresql valkey && [[ -z "$(check_dependencies)" ]] )'
    st "preset core + headscale"           '( st_prep internet both headscale core; st_on headscale headplane jellyfin plex && [[ -z "$(check_dependencies)" ]] )'
    st "preset full"                       '( st_prep internet jellyfin tailscale full; st_on homarr headscale plex traefik && [[ $(svc_state whisparr) == disabled && $(svc_state readarr) == removed ]] )'
    st "compose_deps (map, list, network_mode)" '( d=$(compose_deps "$t/y/docker-compose.yaml"); grep -qx "jellyfin gluetun" <<<"$d" && grep -qx "headplane headscale" <<<"$d" && grep -qx "sonarr gluetun" <<<"$d" && grep -qx "authentik valkey" <<<"$d" )'
    st "dependency problems detected"      '( st_prep internet jellyfin tailscale core; CFG[SERVICE_PRESET]=custom; set_svc_state gluetun disabled; set_svc_state crowdsec disabled; set_svc_state postgresql removed; d=$(check_dependencies); grep -qx "jellyfin needs gluetun" <<<"$d" && grep -qx "traefik needs crowdsec" <<<"$d" && grep -qx "authentik needs postgresql" <<<"$d" )'
    st "homarr patch: homarr-labs + !override" '( st_prep internet jellyfin tailscale full; o=$(render_override "$t/y/docker-compose.yaml"); [[ "$o" == *"image: ghcr.io/homarr-labs/homarr:latest"* && "$o" == *"volumes: !override"* && "$o" == *"SECRET_ENCRYPTION_KEY=\${SECRET_ENCRYPTION_KEY:?err}"* ]] )'
    st "disabled + patched -> one block"   '( st_prep internet jellyfin tailscale core; o=$(render_override "$t/y/docker-compose.yaml"); [[ $(grep -c "^  homarr:" <<<"$o") == 1 ]] && [[ "$(awk "/^  homarr:/{f=1;next} /^  [a-z]/{f=0} f" <<<"$o")" == *profiles* ]] )'
    st "tailscale patch follows control"   '( st_prep internet jellyfin tailscale core; o=$(render_override "$t/y/docker-compose.yaml"); [[ "$o" == *"TS_EXTRA_ARGS=--hostname=exit-node --advertise-exit-node"* && "$o" != *login-server* ]] && st_prep internet jellyfin headscale core && o=$(render_override "$t/y/docker-compose.yaml") && [[ "$o" != *TS_EXTRA_ARGS* ]] )'
    st "certs-dumper auto-off unless LE"   '( st_prep internet jellyfin tailscale core selfsigned; [[ $(svc_state traefik-certs-dumper) == on && $(eff_state traefik-certs-dumper) == disabled ]] && o=$(render_override "$t/y/docker-compose.yaml") && [[ "$(awk "/^  traefik-certs-dumper:/{f=1;next} /^  [a-z]/{f=0} f" <<<"$o")" == *profiles* ]] )'
    st "secrets needed follow services"    '( st_prep lan jellyfin tailscale core selfsigned; ! secret_needed CLOUDFLARE_DNS_API_TOKEN && secret_needed TAILSCALE_AUTHKEY && secret_needed VPN_PASSWORD && ! secret_needed PLEX_CLAIM && st_prep internet plex tailscale core letsencrypt && secret_needed CLOUDFLARE_DNS_API_TOKEN && secret_needed PLEX_CLAIM )'
    st "traefik static: ACME removed"      '( DRY_RUN=0; traefik_static_no_acme "$t/data/traefik/traefik.yaml"; f="$t/data/traefik/traefik.yaml"; ! grep -q "certResolver\|certificatesResolvers\|domains:\|acme" "$f" && grep -q "^experimental:" "$f" && grep -q "options: default" "$f" && grep -q "^  metrics:" "$f" )'
    st "traefik dynamic: file certificate" '( DRY_RUN=0; traefik_dynamic_file_cert "$t/data/traefik/dynamic.yaml"; f="$t/data/traefik/dynamic.yaml"; ! grep -q "defaultGeneratedCert\|resolver:" "$f" && grep -q "^      defaultCertificate:" "$f" && grep -q "^  certificates:" "$f" && grep -q "sniStrict: true" "$f" && [[ $(grep -c "certFile: /etc/traefik/certs/cert.pem" "$f") == 2 ]] )'
    st "self-signed CA + leaf (SANs, chain)" '( MS_CONF_DIR="$t/conf2"; MS_STATE_DIR="$t/st"; DRY_RUN=0; LOG_FILE=""; CFG[DOMAIN]=media.example.org; CFG[CLOUDFLARE_DNS_ZONE]=media.example.org; CFG[LOCAL_DOCKER_IP]=10.0.0.5; mkdir -p "$t/leaf"
        ensure_local_ca && issue_leaf "$t/leaf" && state_set tls_sans "$(tls_sans)" &&
        openssl verify -CAfile "$t/conf2/tls/ca.crt" "$t/leaf/cert.pem" &&
        s=$(openssl x509 -in "$t/leaf/cert.pem" -noout -ext subjectAltName) && [[ "$s" == *"*.media.example.org"* && "$s" == *"10.0.0.5"* ]] &&
        ! leaf_needs_reissue "$t/leaf/cert.pem" && CFG[LOCAL_DOCKER_IP]=10.0.0.6 && leaf_needs_reissue "$t/leaf/cert.pem" &&
        [[ $(stat -c %a "$t/leaf/key.pem") == 600 && $(stat -c %a "$t/conf2/tls/ca.key") == 600 ]] )'
    st "manual cert: pair check"            '( MS_CONF_DIR="$t/conf2"; CFG[CLOUDFLARE_DNS_ZONE]=media.example.org; tls_validate_pair "$t/leaf/cert.pem" "$t/leaf/key.pem" && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$t/other.key" 2>/dev/null && ! tls_validate_pair "$t/leaf/cert.pem" "$t/other.key" && ! tls_validate_pair "$t/leaf/key.pem" "$t/leaf/key.pem" )'
    st "encrypted key: detect, decrypt, validate" '( MS_CONF_DIR="$t/conf2"; CFG[CLOUDFLARE_DNS_ZONE]=media.example.org
        openssl pkey -in "$t/leaf/key.pem" -aes256 -passout pass:s3cret-pass -out "$t/enc8.pem" 2>/dev/null &&
        openssl ec -in "$t/leaf/key.pem" -aes256 -passout pass:s3cret-pass -out "$t/encl.pem" 2>/dev/null && grep -q "^Proc-Type: 4,ENCRYPTED" "$t/encl.pem" &&
        key_is_encrypted "$t/enc8.pem" && key_is_encrypted "$t/encl.pem" && ! key_is_encrypted "$t/leaf/key.pem" &&
        SECRETS[TLS_KEY_PASSPHRASE]="" && ! tls_validate_pair "$t/leaf/cert.pem" "$t/enc8.pem" &&
        SECRETS[TLS_KEY_PASSPHRASE]="wrong" && ! tls_validate_pair "$t/leaf/cert.pem" "$t/enc8.pem" &&
        SECRETS[TLS_KEY_PASSPHRASE]="s3cret-pass" && tls_validate_pair "$t/leaf/cert.pem" "$t/enc8.pem" && tls_validate_pair "$t/leaf/cert.pem" "$t/encl.pem" &&
        k=$(tls_key_plain "$t/encl.pem") && [[ "$k" == *"BEGIN PRIVATE KEY"* && "$k" != *ENCRYPTED* ]] )'
    st "paste: chain + key readers (CRLF, traditional)" '( { cat "$t/leaf/cert.pem"; echo; echo END; echo "ignored"; } | read_pem cert "$t/p.crt" && cmp -s "$t/p.crt" "$t/leaf/cert.pem" &&
        { cat "$t/enc8.pem"; echo "after"; } | read_pem key "$t/p.key" && cmp -s "$t/p.key" "$t/enc8.pem" &&
        { sed "s/\$/\r/" "$t/encl.pem"; echo "after"; } | read_pem key "$t/p2.key" && cmp -s "$t/p2.key" "$t/encl.pem" &&
        SECRETS[TLS_KEY_PASSPHRASE]=s3cret-pass && tls_validate_pair "$t/leaf/cert.pem" "$t/p2.key" &&
        ! echo "garbage" | read_pem cert "$t/g.crt" )'
    st "chain paste: 3 certs, blank lines, END" '( printf "%s\n\n\n" "$(sed -n "/BEGIN/,/END/p" "$t/leaf/cert.pem" | head -n 999)" >"$t/two.txt"; { cat "$t/two.txt"; cat "$t/conf2/tls/ca.crt"; echo; echo END; echo after; } | read_pem cert "$t/p3.crt" && [[ $(grep -c "END CERTIFICATE" "$t/p3.crt") == 3 ]] && ! grep -q after "$t/p3.crt" )'
    st "chain order: leaf first, issuer next" '( MS_CONF_DIR="$t/conf2"; d=$(mktemp -d)
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$d/root.key" -out "$d/root.pem" -subj /CN=TestRoot -days 5 2>/dev/null &&
        openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$d/int.key" -out "$d/int.csr" -subj /CN=TestInt 2>/dev/null &&
        printf "basicConstraints=critical,CA:TRUE\n" >"$d/ca.ext" && openssl x509 -req -in "$d/int.csr" -CA "$d/root.pem" -CAkey "$d/root.key" -set_serial 2 -days 5 -extfile "$d/ca.ext" -out "$d/int.pem" 2>/dev/null &&
        openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$d/leaf.key" -out "$d/leaf.csr" -subj /CN=media.example.org 2>/dev/null &&
        printf "subjectAltName=DNS:media.example.org,DNS:*.media.example.org\n" >"$d/l.ext" && openssl x509 -req -in "$d/leaf.csr" -CA "$d/int.pem" -CAkey "$d/int.key" -set_serial 3 -days 5 -extfile "$d/l.ext" -out "$d/leaf.pem" 2>/dev/null &&
        { cat "$d/root.pem"; echo; cat "$d/leaf.pem"; echo; cat "$d/int.pem"; } >"$d/mixed.pem" &&
        CFG[CLOUDFLARE_DNS_ZONE]=media.example.org && SECRETS[TLS_KEY_PASSPHRASE]="" && tls_validate_pair "$d/mixed.pem" "$d/leaf.key" &&
        tls_write_chain "$d/mixed.pem" "$d/leaf.key" "$d/out.pem" && sed -n "/BEGIN/,/END/p" "$d/out.pem" | awk "/BEGIN/{n++} n==1" >"$d/first.pem" &&
        [[ "$(openssl x509 -in "$d/first.pem" -noout -subject)" == *media.example.org* ]] &&
        [[ "$(openssl crl2pkcs7 -nocrl -certfile "$d/out.pem" | openssl pkcs7 -print_certs -noout | grep -c "^subject")" == 3 ]] &&
        [[ "$(openssl crl2pkcs7 -nocrl -certfile "$d/out.pem" | openssl pkcs7 -print_certs -noout | sed -n "s/^subject=//p" | tr -d " " | xargs)" == "CN=media.example.org CN=TestInt CN=TestRoot" ]] &&
        ! tls_validate_pair "$d/mixed.pem" "$d/root.key.missing" ; rc=$?; rm -rf "$d"; exit $rc )'
    st "wg0.conf import (custom)"         '( printf "[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\nAddress = 10.64.1.2/32\nDNS = 10.64.0.1\n\n[Peer]\nPublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=\nPresharedKey = ccc=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 198.51.100.7:51820 # srv\n" >"$t/wg0.conf"; CFG[VPN_SERVICE_PROVIDER]=custom; wg_import "$t/wg0.conf" && [[ "${SECRETS[WIREGUARD_PRIVATE_KEY]}" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa= && "${CFG[WIREGUARD_ADDRESSES]}" == 10.64.1.2/32 && "${CFG[VPN_ENDPOINT_IP]}" == 198.51.100.7 && "${CFG[VPN_ENDPOINT_PORT]}" == 51820 && "${CFG[WIREGUARD_PUBLIC_KEY]}" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb= && "${SECRETS[WIREGUARD_PRESHARED_KEY]}" == ccc= ]] && validate_key WIREGUARD_PUBLIC_KEY "${CFG[WIREGUARD_PUBLIC_KEY]}" )'
    st "wg0.conf without PresharedKey"    '( st_prep lan jellyfin tailscale core selfsigned; CFG[VPN_TYPE]=wireguard; CFG[VPN_SERVICE_PROVIDER]=mullvad; SECRETS[WIREGUARD_PRESHARED_KEY]=old=; printf "[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\nAddress = 10.64.1.2/32\n\n[Peer]\nPublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=\nEndpoint = 198.51.100.7:51820\n" >"$t/wg1.conf"; wg_import "$t/wg1.conf" >/dev/null && [[ -z "${SECRETS[WIREGUARD_PRESHARED_KEY]}" ]] && secret_needed WIREGUARD_PRIVATE_KEY && ! secret_needed WIREGUARD_PRESHARED_KEY && ! in_list WIREGUARD_PRESHARED_KEY "${SECRET_WIREGUARD[@]}" && [[ -z "$(vpn_problems)" || "$(vpn_problems)" != *PRESHARED* ]] )'
    st "Gluetun hint: invalid region"     '( h=$(vpn_log_hints "ERROR VPN settings: provider settings: server selection: for VPN service provider protonvpn: the region specified is not valid: one or more values is set but there is no possible value available"); [[ "$h" == *SERVER_REGIONS* && "$h" == *"no regions"* && "$h" != *"not a Gluetun provider"* ]] && h=$(vpn_log_hints "ERROR VPN_SERVICE_PROVIDER: provider foo is not valid") && [[ "$h" == *"not a Gluetun provider"* ]] )'
    st "SERVER_REGIONS rejects pasted text" '( validate_key SERVER_REGIONS "" && validate_key SERVER_REGIONS "US East,Netherlands" && ! validate_key SERVER_REGIONS "PersistentKeepalive = 25" && ! validate_key SERVER_REGIONS "[Peer]" && st_prep lan jellyfin tailscale core selfsigned && CFG[SERVER_REGIONS]="PersistentKeepalive = 25" && [[ "$(vpn_problems)" == *SERVER_REGIONS* ]] )'
    st "compose output: log vs console"   '( f="$t/stream.log"; : >"$f"; c=$(printf " sonarr Pulling\n a1289cb1b2e1 Downloading 138.4MB\n 7970ef2aa55e Extracting 7B\n a1289cb1b2e1 Pull complete\n sonarr Pulled\n Container sonarr Started\nError response from daemon: boom\n" | awk -v lf="$f" -v tty=0 "$STREAM_AWK"); [[ "$c" == *"pulled: sonarr"* && "$c" == *"Error response from daemon: boom"* && "$c" == *"Pulled 1 image(s)"* && "$c" != *Downloading* && "$c" != *Extracting* ]] && ! grep -q "Downloading\|Extracting" "$f" && grep -q "Pull complete" "$f" && grep -q "sonarr Pulled" "$f" && grep -q "Container sonarr Started" "$f" )'
    st "cert fetch/push settings validate" '( validate_key CERT_MODE fetch && validate_key CERT_MODE push && ! validate_key CERT_MODE pull && validate_key CERT_FETCH_SOURCE "certsync@192.168.1.1:/var/etc/acme" && ! validate_key CERT_FETCH_SOURCE "192.168.1.1:/x" && ! validate_key CERT_FETCH_SOURCE "u@h:rel" && validate_key CERT_FETCH_CERT fullchain.pem && ! validate_key CERT_FETCH_KEY "a/b" && validate_key CERT_PUSH_FROM "192.168.1.1,10.0.0.0/8" && validate_key CERT_PUSH_FROM "" && ! validate_key CERT_PUSH_FROM "1.2.3.4 && id" && validate_key CERT_PUSH_USER mscertpush )'
    st "push input split (chain + one key)" '( d="$t/ps"; mkdir -p "$d"; cat "$t/leaf/cert.pem" "$t/leaf/key.pem" >"$d/in" && pem_split "$d/in" "$d/c" "$d/k" && cmp -s "$d/c" "$t/leaf/cert.pem" && cmp -s "$d/k" "$t/leaf/key.pem" && ! pem_split "$t/leaf/cert.pem" "$d/c2" "$d/k2" && cat "$d/in" "$t/leaf/key.pem" >"$d/in2" && ! pem_split "$d/in2" "$d/c3" "$d/k3" && ! { echo hello >"$d/g"; pem_split "$d/g" "$d/c4" "$d/k4"; } )'
    st "push key forced to --cert-receive" '( l=$(push_authorized_line "ssh-ed25519 AAAAkey c" "192.168.1.1"); [[ "$l" == "restrict,from=\"192.168.1.1\",command=\"sudo -n $MS_INSTALL_BIN --cert-receive\" ssh-ed25519 AAAAkey c" ]] && l=$(push_authorized_line "ssh-ed25519 AAAAkey c") && [[ "$l" == restrict,command=* ]] && [[ "$(push_sudoers_line mscertpush)" == "mscertpush ALL=(root) NOPASSWD: $MS_INSTALL_BIN --cert-receive" ]] && { ! command -v visudo >/dev/null || { push_sudoers_line mscertpush >"$t/sud" && visudo -cf "$t/sud" >/dev/null; }; } )'
    st "fetched/pushed pair lookup"        '( MS_CONF_DIR="$t/cp"; mkdir -p "$t/cp/certs-pushed" "$t/cp/certs-fetched"; CFG[CERT_MODE]=push; [[ -z "$(cert_source_pair)" ]] && cp "$t/leaf/cert.pem" "$t/cp/certs-pushed/fullchain.pem" && cp "$t/leaf/key.pem" "$t/cp/certs-pushed/privkey.pem" && [[ "$(cert_source_pair)" == "$t/cp/certs-pushed/fullchain.pem $t/cp/certs-pushed/privkey.pem" ]] && CFG[CERT_MODE]=fetch && [[ -z "$(cert_source_pair)" ]] )'
    st "VPN problems detected"             '( st_prep lan jellyfin tailscale core selfsigned; CFG[VPN_TYPE]=openvpn; CFG[VPN_SERVICE_PROVIDER]=custom; CFG[VPN_CUSTOM_OVPN_FILE]=""; p=$(vpn_problems); [[ "$p" == *".ovpn"* ]] &&
        CFG[VPN_SERVICE_PROVIDER]=nordvpn && SECRETS[VPN_USERNAME]=""; p=$(vpn_problems); [[ "$p" == *"VPN_USERNAME"* ]] &&
        SECRETS[VPN_USERNAME]=u && SECRETS[VPN_PASSWORD]=p && p=$(vpn_problems) && [[ "$p" != *VPN_USERNAME* ]] &&
        CFG[VPN_TYPE]=wireguard && CFG[VPN_SERVICE_PROVIDER]=mullvad && SECRETS[WIREGUARD_PRIVATE_KEY]="" && p=$(vpn_problems) && [[ "$p" == *WIREGUARD_PRIVATE_KEY* && "$p" == *WIREGUARD_ADDRESSES* ]] &&
        CFG[VPN_SERVICE_PROVIDER]="" && p=$(vpn_problems) && [[ "$p" == *"VPN_SERVICE_PROVIDER is not set"* ]] )'
    st "Gluetun log hints"                 '( h=$(vpn_log_hints "2026 ERROR [openvpn] AUTH: Received control message: AUTH_FAILED"); [[ "$h" == *username/password* ]] && h=$(vpn_log_hints "ERROR no server found: for VPN openvpn; protocol udp; region Narnia"); [[ "$h" == *"server filter"* ]] && [[ -z "$(vpn_log_hints "INFO all good")" ]] )'
    st "Gluetun hints: WireGuard + endpoint" '( [[ -z "$(vpn_log_hints "2026-11-24T03:01:02Z INFO [wireguard] Using available kernelspace implementation")" ]] && h=$(vpn_log_hints "ERROR [vpn] finding a VPN server: target IP address not found") && [[ "$h" == *"only works with provider '"'"'custom'"'"'"* && "$h" != *"server filter"* ]] && h=$(vpn_log_hints "INFO [healthcheck] program has been unhealthy for 21s: restarting VPN") && [[ "$h" == *"passes no traffic"* ]] && h=$(vpn_log_hints "ERROR VPN settings: wireguard settings: private key is not valid") && [[ "$h" == *"re-import"* ]] )'
    st "Gluetun hints: settings dump is not an error" '( lg="    |   └── Restart VPN on healthcheck failure: yes
    |   └── Authentication file path: /gluetun/auth/config.toml
2026-11-24T03:45:25Z WARN [dns] downloading block lists failed, skipping: lookup raw.githubusercontent.com on 127.0.0.1:53: i/o timeout
2026-11-24T03:48:54Z WARN [vpn] restarting VPN because it failed to pass the healthcheck: startup check: all check tries failed: dialing: dial tcp4: lookup github.com: i/o timeout"; ex=$(grep -E "(^|[[:space:]])(ERROR|WARN|FATAL)[[:space:]]" <<<"$lg"); [[ "$ex" != *Authentication* ]] && h=$(vpn_log_hints "$lg") && [[ "$h" != *username/password* && "$h" == *"passes no traffic"* && "$h" == *FREE_ONLY* && $(grep -c . <<<"$h") == 1 ]] )'
    st "custom WireGuard: new names, no filters" '( st_prep internet jellyfin tailscale core; CFG[VPN_SERVICE_PROVIDER]=custom; CFG[VPN_TYPE]=wireguard; CFG[VPN_ENDPOINT_IP]=37.120.137.194; CFG[VPN_ENDPOINT_PORT]=51820; CFG[VPN_SERVERS_UPDATE_PERIOD]=480h; o=$(render_override "$t/y/docker-compose.yaml"); [[ "$o" == *"WIREGUARD_ENDPOINT_IP=37.120.137.194"* && "$o" == *"WIREGUARD_ENDPOINT_PORT=51820"* && "$o" != *UPDATER_PERIOD* ]] && h=$(vpn_log_hints "ERROR VPN settings: provider settings: server selection: for VPN service provider custom: the country specified is not valid: one or more values is set but there is no possible value available") && [[ "$h" == *"must be blank"* && $(grep -c . <<<"$h") == 1 ]] && CFG[VPN_SERVICE_PROVIDER]=mullvad && vpn_normalize && o=$(render_override "$t/y/docker-compose.yaml") && [[ "$o" != *WIREGUARD_ENDPOINT* && "$o" == *UPDATER_PERIOD=480h* ]] )'
    st "WireGuard dump parsing"           '( d=$(printf "tun0\tPRIV\tPUBX=\t51820\toff\ntun0\tPEERPUB=\t(none)\t37.120.137.194:51820\t0.0.0.0/0\t0\t0\t1480\toff\n"); [[ "$(wg_dump_eval "$d")" == "PUBX= 37.120.137.194:51820 0 0 1480 PEERPUB= 51820" ]] && d=$(printf "tun0\tPRIV\tPUBX=\t51820\toff\ntun0\tPEERPUB=\t(none)\t1.2.3.4:51820\t0.0.0.0/0\t1764000000\t9000\t3000\toff\n") && [[ "$(wg_dump_eval "$d")" == "PUBX= 1.2.3.4:51820 1764000000 9000 3000 PEERPUB= 51820" ]] )'
    st "installed copy updated only upward" '( MS_INSTALL_BIN="$t/inst"; printf "readonly SCRIPT_VERSION=\"2.5.2\"\n" >"$t/inst"; [[ "$(installed_version)" == 2.5.2 ]] && [[ "$(printf "%s\n%s\n" 2.5.2 2.5.10 | sort -V | tail -n1)" == 2.5.10 ]] && printf "readonly SCRIPT_VERSION=\"9.0.0\"\n" >"$t/inst" && [[ "$(installed_version)" == 9.0.0 ]] )'
    st "subnet overlap check"             '( cidr_overlap 172.28.10.0/24 172.28.10.0/24 && cidr_overlap 172.28.0.0/16 172.28.10.0/24 && ! cidr_overlap 172.28.11.0/24 172.28.10.0/24 && ! cidr_overlap 172.17.0.0/16 172.28.10.0/24 && cidr_overlap 0.0.0.0/0 10.1.2.0/24 && ! cidr_overlap fd00::/64 172.28.10.0/24 )'
    st "orphaned bridge on stack subnet"  '( FOLDER_FOR_YAML="$t/fy"; mkdir -p "$t/fy"; echo DOCKER_SUBNET=172.28.10.0/24 >"$t/fy/.env"; docker() { case "$1 $2" in "network ls") echo 91b65f27405bfffffff;; "network inspect") echo "";; esac; }; ip() { echo "1: lo    inet 127.0.0.1/8 scope host lo"; echo "5: br-cef1f9fa439b    inet 172.28.10.1/24 brd 172.28.10.255 scope global br-cef1f9fa439b"; echo "6: br-91b65f27405b    inet 172.28.10.1/24 scope global br-91b65f27405b"; echo "2: eno1    inet 192.168.11.75/24 scope global eno1"; }; [[ "$(subnet_foreign_ifaces)" == "br-cef1f9fa439b 172.28.10.1/24" ]] )'
    st "TLS probe name is under the zone"  '( CFG[CLOUDFLARE_DNS_ZONE]=certifiedgeeks.net; [[ "$(tls_probe_name)" == mediastack-probe.certifiedgeeks.net ]] )'
    st "WireGuard addresses + endpoint reset" '( [[ "$(wg_addresses_usable "10.2.0.2/32,2a07:b944::2:2/128")" == 10.2.0.2/32 && "$(wg_addresses_usable "10.64.1.2/32")" == 10.64.1.2/32 && "$(wg_addresses_usable "fd00::2/128")" == fd00::2/128 ]] && CFG[VPN_SERVICE_PROVIDER]=protonvpn CFG[VPN_ENDPOINT_IP]=1.2.3.4 CFG[VPN_ENDPOINT_PORT]=51820 CFG[WIREGUARD_PUBLIC_KEY]=x && vpn_normalize && [[ -z "${CFG[VPN_ENDPOINT_IP]}${CFG[VPN_ENDPOINT_PORT]}${CFG[WIREGUARD_PUBLIC_KEY]}" ]] && CFG[VPN_SERVICE_PROVIDER]=custom CFG[VPN_ENDPOINT_IP]=1.2.3.4 && vpn_normalize && [[ ${CFG[VPN_ENDPOINT_IP]} == 1.2.3.4 ]] )'
    st "Gluetun server-list updater patch"  '( st_prep internet jellyfin tailscale core; CFG[VPN_SERVICE_PROVIDER]=mullvad; CFG[VPN_SERVERS_UPDATE_PERIOD]=480h; o=$(render_override "$t/y/docker-compose.yaml"); [[ "$o" == *"UPDATER_PERIOD=480h"* && "$o" != *PROTONVPN* ]] && CFG[VPN_SERVICE_PROVIDER]=protonvpn && o=$(render_override "$t/y/docker-compose.yaml") && [[ "$o" != *UPDATER_PERIOD* ]] && CFG[VPN_UPDATER_PROTON_EMAIL]=me@example.org && o=$(render_override "$t/y/docker-compose.yaml") && [[ "$o" == *"UPDATER_PROTONVPN_EMAIL=me@example.org"* && "$o" == *"UPDATER_PROTONVPN_PASSWORD=\${UPDATER_PROTONVPN_PASSWORD:-}"* ]] && CFG[VPN_SERVERS_UPDATE_PERIOD]=off && o=$(render_override "$t/y/docker-compose.yaml") && [[ "$o" != *UPDATER* ]] && validate_key VPN_SERVERS_UPDATE_PERIOD 480h && ! validate_key VPN_SERVERS_UPDATE_PERIOD 15d && validate_key SERVER_COUNTRIES "Switzerland,Netherlands" && ! validate_key SERVER_CITIES "a=b" )'
    st "portable backup crypto round-trip"  '( printf "secret data\n" | portable_encrypt "correct horse battery" >"$t/b.msbak" && is_portable_backup "$t/b.msbak" && [[ "$(portable_decrypt "$t/b.msbak" "correct horse battery")" == "secret data" ]] && ! portable_decrypt "$t/b.msbak" "wrong passphrase!!" >/dev/null 2>&1 && ! grep -q "secret data" "$t/b.msbak" )'
    st "--set validation"                   'validate_key CERT_MODE selfsigned && ! validate_key CERT_MODE self && validate_key ACCESS_MODE lan && ! validate_key DATA_STORAGE smb && validate_key MEDIA_REMOTE "//nas/media" && validate_key BACKUP_KEEP 7 && ! validate_key BACKUP_KEEP x && ! validate_key NOPE 1 && ! validate_key DOMAIN "a b"'
    st "v1.x config keeps old behaviour"    '( MS_CONF_DIR="$t/c3"; CONF_FILE="$t/c3/m.conf"; mkdir -p "$t/c3"; printf "%s\n" "DOMAIN='"'"'x.org'"'"'" >"$CONF_FILE"; REF_OVERRIDE=""; load_config; [[ ${CFG[ACCESS_MODE]} == internet && ${CFG[CERT_MODE]} == letsencrypt && ${CFG[SERVICE_PRESET]} == custom && ${CFG[TAILSCALE_CONTROL]} == headscale ]] )'
    st "compose version check without Docker" '( PATH=/nonexistent; e=$(compose_version 2>&1); [[ -z "$e" ]] && ! compose_version_ok 2>/dev/null )'
    st "new install defaults"               '( CONF_FILE="$t/none.conf"; REF_OVERRIDE=""; load_config; [[ ${CFG[SERVICE_PRESET]} == core && ${CFG[TAILSCALE_CONTROL]} == tailscale && ${CFG[BACKUP_FORMAT]} == host ]] )'
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
    printf '  3) Reset Authentik akadmin password\n  4) Show *ARR API keys (optionally store in vault)\n'
    printf '  5) Update Gluetun VPN server list now\n  6) VPN check (Gluetun health, errors, WireGuard handshake)\n  0) Back\n'
    local ch; read -rp "  Choice: " ch || return 0
    case "$ch" in
        1) menu_action helper_authentik_db ;;
        2) menu_action helper_guacamole_db ;;
        3) menu_action helper_akadmin ;;
        4) menu_action helper_apikeys ;;
        5) menu_action vpn_update_servers ;;
        6) menu_action vpn_check ;;
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
        printf '   R) Restart containers     (no converge)\n'
        printf '   7) Status\n   8) Post-install helpers\n   9) Logs\n   K) Certificate          (refresh, show, fetch key, push receiver)\n'
        printf '  %sMaintenance%s\n' "$B" "$NC"
        printf '   B) Backup / restore\n   C) Show settings (all keys)\n   U) Uninstall...\n   T) Toggle dry-run\n   S) Self-test\n   0) Quit\n\n'
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
            k) menu_cert ;;
            r) menu_action stack_restart ;;
            b) menu_backup ;;
            c) menu_action show_config ;;
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
  --restart              Restart the containers (no converge)
  --status               Show configuration, storage, certificate and container status
  --logs [N] [SERVICE]   Last N container log lines (default 100), all services or one
  --show-config          Print every setting with its meaning
  --set KEY VALUE        Change one setting (validated; presets re-applied), then --apply
  --backup [--portable]  Back up settings, vault, compose folder and app data to BACKUP_DIR
                         (--portable: passphrase-encrypted, restores on any host)
  --restore FILE         Restore a backup (keyword RESTORE)
  --passphrase-file FILE Portable backup passphrase (first line), or set MS_BACKUP_PASSPHRASE
  --rekey                Re-encrypt the vault with the configured SECRETS_BACKEND
  --cert-refresh         Fetch / re-read the certificate, install it, reload Traefik if it changed
  --cert-show            Show the deployed certificate and what Traefik serves
  --cert-fetch-key       Create / show the SSH key used to fetch the certificate (CERT_MODE=fetch)
  --cert-push-setup [F|-] Set up the push receiver (user, forced-command key, sudoers); public key
                         from file F, stdin (-) or a prompt (CERT_MODE=push)
  --cert-receive         Push receiver: read chain + key on stdin (run by the forced SSH command)
  --helper NAME          authentik-db | guacamole | akadmin | apikeys | vpn-servers | vpn-check
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
  --confirm KEYWORD      Pre-answer a typed confirmation (UNINSTALL, PURGE-DOCKER, RESTORE, DELETE-MEDIA)

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
    local action="menu" helper="" arg1="" arg2="" ; local -a compose_args=() orig=("$@") set_kv=()
    while (( $# )); do
        case "$1" in
            --install)      action=install ;;
            --apply)        action=apply ;;
            --start)        action=start ;;
            --stop)         action=stop ;;
            --restart)      action=restart ;;
            --logs)         action=logs
                            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then arg1=$2; shift; fi
                            if [[ -n "${2:-}" && "${2:-}" != -* ]]; then arg2=$2; shift; fi ;;
            --show-config)  action=showconfig ;;
            --set)          action="set"; (( $# >= 3 )) || die "--set needs KEY VALUE"; set_kv=("$2" "$3"); shift 2 ;;
            --backup)       action=backup ;;
            --portable)     BACKUP_FORMAT_OPT=portable ;;
            --restore)      action=restore; arg1=${2:-}; [[ -n "$arg1" ]] || die "--restore needs FILE"; shift ;;
            --passphrase-file) PASSPHRASE_FILE_OPT=${2:-}; [[ -n "$PASSPHRASE_FILE_OPT" ]] || die "--passphrase-file needs FILE"; shift ;;
            --rekey)        action=rekey ;;
            --cert-refresh) action=certrefresh ;;
            --cert-show)    action=certshow ;;
            --cert-fetch-key) action=certkey ;;
            --cert-push-setup) action=certpush
                            if [[ -n "${2:-}" && ( "${2:-}" == - || "${2:-}" != -* ) ]]; then arg1=$2; shift; fi ;;
            --cert-receive) action=certreceive ;;
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
    case "$action" in certrefresh|certreceive) init_logging cert ;; *) init_logging ;; esac
    if [[ "$action" == certreceive ]]; then   # a push waits for a menu/apply run instead of failing
        exec 9>"$MS_LOCK_FILE"
        flock -w 300 9 || { printf '%s FAIL busy: another run held the lock for 5 minutes\n' "$CERT_RECEIVE_TAG"; exit 1; }
    else
        acquire_lock
    fi
    _log_file INFO "================================================"
    _log_file INFO "$SCRIPT_NAME v$SCRIPT_VERSION started action=$action dry_run=$DRY_RUN"
    [[ "$action" == certreceive ]] || self_update_installed
    _log_file INFO "User: $(id -un) (real: $REAL_USER)  PID: $$"
    _log_file INFO "================================================"

    case "$action" in
        menu)      is_tty || die "No terminal; use a CLI action (see --help)."; main_menu ;;
        install)   full_install ;;
        apply)     stack_apply pull ;;
        start)     stack_apply nopull ;;
        stop)      stack_stop ;;
        restart)   stack_restart ;;
        logs)      show_logs "${arg1:-100}" "$arg2" ;;
        showconfig) show_config ;;
        set)       cli_set "${set_kv[0]}" "${set_kv[1]}" ;;
        backup)    do_backup ;;
        restore)   do_restore "$arg1" ;;
        rekey)     secrets_rekey ;;
        certrefresh) cert_refresh || exit 1 ;;
        certshow)  cert_show ;;
        certkey)   ensure_config; cert_fetch_key ;;
        certpush)  cert_push_setup "$arg1" ;;
        certreceive) cert_receive ;;
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
                vpn-servers)  vpn_update_servers ;;
                vpn-check)    vpn_check ;;
                *)            die "Unknown helper '$helper' (authentik-db|guacamole|akadmin|apikeys|vpn-servers|vpn-check)" ;;
            esac ;;
    esac
    _log_file INFO "Finished action=$action"
}

main "$@"
