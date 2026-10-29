#!/bin/sh
# ==========================================================
# SSH Hardening Compliance Verifier — OPNsense / FreeBSD
#
# Read-only. Compares the LIVE sshd configuration (`sshd -T`)
# against a FreeBSD-valid hardening baseline and reports the
# deviations plus a compliance percentage.
#
# This script NEVER writes to /etc/ssh, never touches users or
# groups, and never restarts sshd. Enforcement on OPNsense must
# go through the GUI (System > Settings > Administration) or a
# template override under /usr/local/opnsense/service/templates/.
#
# Usage:
#   ./verify_sshd_hardening.sh [--verify|--debug|--version|--help]
#
# Author: netgeek1 (Claude.ai)
#
# 20260713-0900 - Initial FreeBSD/OPNsense POSIX sh port
#                 (from deploy_sshd_hardening.sh, Linux/bash)
# ==========================================================

SCRIPT_NAME="verify_sshd_hardening.sh"
SCRIPT_VERSION="20260713-0900"

# =============================================================================
# PORTING NOTES (vs. the Linux/bash original)
#
# - POSIX sh only: no `declare -A`, no `${var,,}`, no printf '%(...)T'.
# - mktemp templates use TRAILING X's (FreeBSD rejects a suffix after them).
# - `sshd` lives at /usr/sbin/sshd; PATH is fixed up for non-login shells.
# - `DebianBanner` REMOVED — it is a Debian-only patch. `sshd -t` on FreeBSD
#   rejects it as an unknown keyword.
# - Comma-list directives (Ciphers/MACs/KexAlgorithms) are compared as SETS
#   (order-insensitive) so a reordered-but-equivalent list is not a false diff.
# - Directives that OPNsense manages in config.xml are annotated [GUI] so you
#   know to fix them in the web UI, not in a dropped-in .conf file.
# =============================================================================

set -eu

DEBUG=0
LOGFILE="/var/log/ssh_hardening_verify.log"
SSHD_CONFIG="/etc/ssh/sshd_config"

REC_KV=""
RUN_KV=""

cleanup() { [ -n "$REC_KV" ] && rm -f "$REC_KV"; [ -n "$RUN_KV" ] && rm -f "$RUN_KV"; }
trap cleanup EXIT INT HUP TERM

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOGFILE" 2>/dev/null || true; }
dbg() { [ "$DEBUG" -eq 1 ] && printf '[DEBUG] %s\n' "$*" || true; }

# Directives OPNsense owns via config.xml / the web GUI.
GUI_MANAGED="port permitrootlogin passwordauthentication pubkeyauthentication allowtcpforwarding listenaddress"

show_version() {
  printf '\nSSH Hardening Compliance Verifier (OPNsense/FreeBSD)\n'
  printf 'Script name: %s\n' "$SCRIPT_NAME"
  printf 'Version    : %s\n' "$SCRIPT_VERSION"
  printf 'Maintainer : Matt McHugh\n'
  show_options
}

show_options() {
  cat <<'EOF'

Usage:
  ./verify_sshd_hardening.sh [--verify|--debug|--version|--help]

Options:
  --verify     Check live SSH configuration compliance (default)
  --debug      Verify with detailed parsing output
  --version    Show version and exit
  --help       Show this help and exit

This tool is READ-ONLY. It will not modify sshd, users, or groups.
EOF
}

# ----------------------- Recommended baseline (FreeBSD-valid) -----------------------
generate_recommended_config() {
cat <<'EOF'
# --- Basic Security ---
Port 22
PermitRootLogin no
PermitEmptyPasswords no
PasswordAuthentication no
PubkeyAuthentication yes
StrictModes yes

# --- Session Management ---
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 2
MaxStartups 10:30:60
TCPKeepAlive no

# --- Forwarding Restrictions ---
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no

# --- Cryptography ---
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256@libssh.org,sntrup761x25519-sha512@openssh.com

# --- Logging & Visibility ---
LogLevel VERBOSE

# --- Miscellaneous ---
UsePAM yes
PrintMotd no
PrintLastLog yes
Compression no
EOF
}

# ----------------------- Helpers -----------------------
# Normalize a value: lowercase, strip whitespace, sort comma-lists so that
# order does not matter for Ciphers/MACs/KexAlgorithms.
normalize() {
  printf '%s' "$1" \
    | tr 'A-Z' 'a-z' \
    | tr -d ' \t' \
    | tr ',' '\n' \
    | sort \
    | tr '\n' ',' \
    | sed -e 's/,*$//' -e 's/^,*//'
}

is_gui_managed() {
  for g in $GUI_MANAGED; do
    [ "$1" = "$g" ] && return 0
  done
  return 1
}

# ----------------------- KV builders -----------------------
build_recommended_kv() {
  REC_KV=$(mktemp /var/tmp/sshd-rec-XXXXXXXX) || { echo "mktemp failed"; exit 1; }
  generate_recommended_config \
    | grep -vE '^[[:space:]]*#|^[[:space:]]*$' \
    | sed -E 's/[[:space:]]*#.*$//' \
    | awk 'NF>=2 { k=tolower($1); $1=""; sub(/^[ \t]+/,""); print k "\t" $0 }' \
    >"$REC_KV"
  dbg "Recommended directives: $(wc -l <"$REC_KV" | tr -d ' ')"
}

build_running_kv() {
  RUN_KV=$(mktemp /var/tmp/sshd-run-XXXXXXXX) || { echo "mktemp failed"; exit 1; }
  if ! sshd -T >"$RUN_KV.raw" 2>"$RUN_KV.err"; then
    printf '\xe2\x9d\x8c  `sshd -T` failed. Output:\n'
    cat "$RUN_KV.err"
    printf '\nThis usually means the script is not running as root, or the\n'
    printf 'active sshd_config has a syntax error.\n'
    rm -f "$RUN_KV.raw" "$RUN_KV.err"
    exit 1
  fi
  # Collapse repeated keys (e.g. multiple `port` lines) into one comma list.
  awk '{
        k=tolower($1); $1=""; sub(/^[ \t]+/,"");
        if (k in m) m[k] = m[k] "," $0; else m[k] = $0
      }
      END { for (k in m) print k "\t" m[k] }' "$RUN_KV.raw" | sort >"$RUN_KV"
  rm -f "$RUN_KV.raw" "$RUN_KV.err"
  dbg "Running directives: $(wc -l <"$RUN_KV" | tr -d ' ')"
}

lookup_running() {
  awk -F'\t' -v key="$1" '$1 == key { print $2; found=1; exit } END { if (!found) exit 1 }' "$RUN_KV"
}

# ----------------------- Reporting -----------------------
print_differences() {
  matches=0
  total=0
  deviations=0

  while IFS='   ' read -r key rec; do
    [ -z "$key" ] && continue
    total=$((total + 1))

    if run=$(lookup_running "$key"); then
      nr=$(normalize "$rec")
      nv=$(normalize "$run")
      if [ "$nv" = "$nr" ]; then
        matches=$((matches + 1))
        dbg "MATCH  $key = $run"
        continue
      fi
      tag=""
      is_gui_managed "$key" && tag=" [GUI]"
      printf '%-24s = %-34s (recommended: %s)%s\n' "$key" "$run" "$rec" "$tag"
    else
      tag=""
      is_gui_managed "$key" && tag=" [GUI]"
      printf '%-24s   %-34s (recommended: %s)%s\n' "$key" "not reported" "$rec" "$tag"
    fi
    deviations=$((deviations + 1))
  done <"$REC_KV"

  compliance=0
  [ "$total" -gt 0 ] && compliance=$((matches * 100 / total))

  echo "----------------------------------------------------------------------"
  printf 'Compliance: %s of %s directives aligned (%s%%)\n' "$matches" "$total" "$compliance"
  [ "$deviations" -gt 0 ] && echo "[GUI] = managed by OPNsense (System > Settings > Administration)"

  log "Compliance $matches/$total (${compliance}%)"
  [ "$deviations" -eq 0 ]
}

report_include_status() {
  echo
  echo "OPNsense config-ownership check:"
  if [ ! -r "$SSHD_CONFIG" ]; then
    echo "  - Cannot read $SSHD_CONFIG (run as root)."
    return
  fi
  if grep -qiE '^[[:space:]]*Include' "$SSHD_CONFIG"; then
    echo "  - $SSHD_CONFIG DOES have an Include directive:"
    grep -iE '^[[:space:]]*Include' "$SSHD_CONFIG" | sed 's/^/      /'
    echo "  - Drop-in files may take effect, but OPNsense regenerates"
    echo "    $SSHD_CONFIG from its templates on apply/reboot."
  else
    echo "  - $SSHD_CONFIG has NO Include directive."
    echo "  - Any file in /etc/ssh/sshd_config.d/ is INERT on this box."
    echo "  - Persist changes via a template override under"
    echo "    /usr/local/opnsense/service/templates/ instead."
  fi
}

# ----------------------- Main -----------------------
main() {
  log "Starting SSH hardening verification (debug=$DEBUG)"

  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sshd -T requires it)."
    echo "Re-run as: sudo $0 $*"
    exit 1
  fi

  if ! command -v sshd >/dev/null 2>&1; then
    if [ -x /usr/sbin/sshd ]; then
      PATH="/usr/sbin:$PATH"
      export PATH
    else
      echo "sshd not found in PATH or /usr/sbin/sshd"
      exit 1
    fi
  fi

  echo
  echo "Differences from the recommended SSH hardening baseline:"
  echo "----------------------------------------------------------------------"

  build_recommended_kv
  build_running_kv

  if print_differences; then
    echo
    echo "Fully compliant with the recommended baseline."
    log "Fully compliant."
    report_include_status
    exit 0
  else
    echo
    echo "Some directives deviate from the baseline (see above)."
    log "Deviations present."
    report_include_status
    exit 2
  fi
}

# =============================================================================
# Argument parsing
# =============================================================================
case "${1:-}" in
  --debug)          DEBUG=1 ;;
  --verify|"")      DEBUG=0 ;;
  --version|-v)     show_version; exit 0 ;;
  --help|-h)        show_options; exit 0 ;;
  *)
    printf 'Unknown option: %s\n' "${1:-}"
    printf "Use '--verify', '--debug', '--version', or '--help'\n"
    exit 1
    ;;
esac

main "$@"
