#!/usr/bin/env bash
# =============================================================================
#  docker-inventory.sh
#  Read-only inventory of a Docker host, for planning a rebuild / migration
#
#  Version   : SCRIPT_VERSION below is the authoritative version string
#  Author    : netgeek1 (Claude.ai)
#
#  Usage     : sudo ./docker-inventory.sh            writes ~/docker-inventory-<host>-<date>.tar.gz
#              sudo ./docker-inventory.sh --no-redact  keep secret values (do NOT share that bundle)
#
#  Changes nothing on the host. Secret-looking values (PASSWORD, SECRET, TOKEN, KEY, ...)
#  in container env, compose files and .env files are replaced with <redacted>.
#  Redaction is best-effort: look through the bundle before you share it.
# =============================================================================
set -uo pipefail   # best-effort: one failing probe must not abort the inventory
umask 077

readonly SCRIPT_VERSION="1.0.1"
REDACT=1
[[ "${1:-}" == --no-redact ]] && REDACT=0
[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,15p' "$0"; exit 0; }

if [[ $EUID -ne 0 ]]; then exec sudo bash "$0" "$@"; fi
command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }

REAL_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
STAMP=$(date +%F_%H%M)
NAME="docker-inventory-$(hostname -s)-$STAMP"
WORK=$(mktemp -d)
OUT="$WORK/$NAME"
mkdir -p "$OUT/containers" "$OUT/compose"
SECRET_RE='(PASS|PASSWD|PASSWORD|SECRET|TOKEN|APIKEY|API_KEY|PRIVATE|CREDENTIAL|AUTH|_KEY$|^KEY$)'

log() { printf '  %s\n' "$*"; }

# redact_env_lines: KEY=value lines on stdin
redact_env_lines() {
    if (( ! REDACT )); then cat; return; fi
    awk -v re="$SECRET_RE" 'BEGIN{IGNORECASE=1}
        /^[[:space:]]*#/ {print; next}
        { k=$0; sub(/=.*/, "", k); gsub(/^[[:space:]]*(export[[:space:]]+)?/, "", k)
          if (index($0, "=") && toupper(k) ~ re) { print substr($0, 1, index($0, "=")) "<redacted>" } else print }'
}

# redact_yaml: compose files -- "KEY: value", "- KEY=value", "KEY=value"
redact_yaml() {
    if (( ! REDACT )); then cat; return; fi
    sed -E 's/^([[:space:]]*-?[[:space:]]*"?[A-Za-z0-9_]*([Pp][Aa][Ss][Ss]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll])[A-Za-z0-9_]*"?[[:space:]]*[:=][[:space:]]*).+$/\1<redacted>/'
}

echo "docker-inventory v$SCRIPT_VERSION  (redaction: $( ((REDACT)) && echo on || echo OFF))"

log "Host + Docker versions"
{
    echo "## Host"; hostnamectl 2>/dev/null || hostname
    echo; cat /etc/os-release
    echo; echo "## Kernel / arch"; uname -a; dpkg --print-architecture 2>/dev/null || true
    echo; echo "## Addresses"; ip -4 -br addr 2>/dev/null || true; ip -4 route 2>/dev/null || true
    echo; echo "## DNS (host)"; cat /etc/resolv.conf 2>/dev/null || true
    echo; echo "## Listening ports"; ss -Hltnup 2>/dev/null || true
    echo; echo "## Docker"; docker version 2>&1 || true
    echo; docker compose version 2>&1 || true; docker-compose version 2>&1 || true
    echo; echo "## Disk"; df -h -x tmpfs -x devtmpfs 2>/dev/null || true
    echo; echo "## Docker disk usage"; docker system df 2>&1 || true
} >"$OUT/host.txt"

log "Containers"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' >"$OUT/containers.txt"
mapfile -t CONTAINERS < <(docker ps -a --format '{{.Names}}')

declare -A PROJECT_FILES=() PROJECT_DIRS=()
for c in "${CONTAINERS[@]}"; do
    if command -v python3 >/dev/null 2>&1; then
        docker inspect "$c" | REDACT=$REDACT RE="$SECRET_RE" python3 -c '
import json, os, re, sys
d = json.load(sys.stdin)
rx = re.compile(os.environ["RE"], re.I)
if os.environ["REDACT"] == "1":
    for c in d:
        env = c.get("Config", {}).get("Env") or []
        c["Config"]["Env"] = [e.split("=", 1)[0] + "=<redacted>" if "=" in e and rx.search(e.split("=", 1)[0]) else e for e in env]
json.dump(d, sys.stdout, indent=2)' >"$OUT/containers/$c.inspect.json"
    else
        docker inspect "$c" | sed -E 's/"([A-Za-z0-9_]*(PASS|SECRET|TOKEN|KEY)[A-Za-z0-9_]*)=[^"]*"/"\1=<redacted>"/g' >"$OUT/containers/$c.inspect.json"
    fi
    proj=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null | sed 's/<no value>//')
    if [[ -n "$proj" ]]; then
        PROJECT_FILES[$proj]=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$c")
        PROJECT_DIRS[$proj]=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c")
    else
        # docker run container: reconstruct the essentials as a readable summary
        docker inspect -f '{{.Name}}
  image:    {{.Config.Image}}
  restart:  {{.HostConfig.RestartPolicy.Name}}
  network:  {{.HostConfig.NetworkMode}}
  ports:    {{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}}->{{$p}} {{end}}{{end}}
  mounts:   {{range .Mounts}}{{.Type}}:{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}->{{.Destination}}{{if not .RW}}:ro{{end}} {{end}}
  caps:     {{.HostConfig.CapAdd}}
  devices:  {{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}
  dns:      {{.HostConfig.Dns}}
  hostname: {{.Config.Hostname}}
  cmd:      {{.Config.Cmd}}' "$c" 2>&1 | sed 's#^/##' >>"$OUT/docker-run-containers.txt" || true
        echo >>"$OUT/docker-run-containers.txt"
    fi
done

log "Compose projects"
: >"$OUT/compose-projects.txt"
for proj in "${!PROJECT_FILES[@]}"; do
    dir=${PROJECT_DIRS[$proj]}
    printf '%s\t%s\t%s\n' "$proj" "$dir" "${PROJECT_FILES[$proj]}" >>"$OUT/compose-projects.txt"
    mkdir -p "$OUT/compose/$proj"
    IFS=',' read -ra files <<<"${PROJECT_FILES[$proj]}"
    for f in "${files[@]}"; do
        [[ "$f" == /* ]] || f="$dir/$f"     # compose v1 records config files relative to the project dir
        [[ -f "$f" ]] && redact_yaml <"$f" >"$OUT/compose/$proj/$(basename "$f")"
    done
    if [[ -d "$dir" ]]; then
        for f in "$dir"/.env "$dir"/*.env; do
            [[ -f "$f" ]] && redact_env_lines <"$f" >"$OUT/compose/$proj/$(basename "$f").txt"
        done
        # small text config files next to the compose file (e.g. prometheus.yml), not data
        find "$dir" -maxdepth 2 -type f -size -64k \( -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.ini' -o -name '*.json' -o -name '*.toml' \) \
            ! -name 'docker-compose*' ! -name 'compose.y*' 2>/dev/null | while IFS= read -r f; do
            rel=${f#"$dir"/}; mkdir -p "$OUT/compose/$proj/extra/$(dirname "$rel")"
            redact_yaml <"$f" >"$OUT/compose/$proj/extra/$rel"
        done
        ls -la "$dir" >"$OUT/compose/$proj/_listing.txt" 2>&1
        ( cd "$dir" && git remote -v 2>/dev/null && git log -1 --oneline 2>/dev/null ) >"$OUT/compose/$proj/_git.txt" 2>/dev/null || true
    else
        echo "working dir $dir not found" >"$OUT/compose/$proj/_missing.txt"
    fi
done

log "Data locations (bind mounts + named volumes, with sizes)"
{
    printf '%-20s %-7s %-55s %-35s %s\n' CONTAINER TYPE SOURCE DESTINATION SIZE
    for c in "${CONTAINERS[@]}"; do
        docker inspect -f '{{range .Mounts}}{{.Type}}|{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}|{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' "$c" \
        | while IFS='|' read -r type src dst path; do
            [[ -n "$type" ]] || continue
            size=$(du -sh "$path" 2>/dev/null | cut -f1)
            printf '%-20s %-7s %-55s %-35s %s\n' "$c" "$type" "$src" "$dst" "${size:-?}"
        done
    done
} >"$OUT/data-locations.txt"
docker volume ls >"$OUT/volumes.txt" 2>&1
docker network ls >"$OUT/networks.txt" 2>&1
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}' >"$OUT/images.txt"

log "Scheduled jobs that touch docker"
{
    echo "## root crontab"; crontab -l 2>/dev/null || echo none
    [[ -n "${SUDO_USER:-}" ]] && { echo; echo "## $SUDO_USER crontab"; crontab -u "$SUDO_USER" -l 2>/dev/null || echo none; }
    echo; echo "## /etc/cron.d"; grep -l -i docker /etc/cron.d/* 2>/dev/null || echo none
    echo; echo "## systemd timers"; { systemctl list-timers --all --no-legend 2>/dev/null || echo "systemctl unavailable"; } | head -40
} >"$OUT/schedules.txt"

ls -la "$REAL_HOME/web-site-content" >"$OUT/web-site-content.txt" 2>&1 || true

TARBALL="$REAL_HOME/$NAME.tar.gz"
tar -C "$WORK" -czf "$TARBALL" "$NAME"
chown "${SUDO_USER:-root}:" "$TARBALL" 2>/dev/null || true
rm -rf "$WORK"
echo
echo "Wrote $TARBALL ($(du -h "$TARBALL" | cut -f1))"
echo "Contains: host.txt containers.txt compose/ containers/*.inspect.json docker-run-containers.txt data-locations.txt ..."
(( REDACT )) && echo "Secrets redacted (best-effort) -- skim compose/ before sharing." || echo "NOT redacted -- do not share this file."
