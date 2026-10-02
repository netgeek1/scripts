#!/bin/bash
# ====================================================
# 
# Docker install script | Auto-Elevating | Modular
#
# ====================================================

# -------------------------------
# Function: Auto-Elevate
# -------------------------------
auto_elevate() {
  if [[ $EUID -ne 0 ]]; then
    echo "[*] Elevation required. Re-running as root..."
    exec sudo bash "$0" "$@"
    exit 0
  fi
}

auto_elevate "$@"

REAL_USER="${SUDO_USER:-root}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }
pause(){ read -rp "Press ENTER to continue..."; }

# ------------------------------------------------------------
# Docker install & prerequisites (Ubuntu/Debian)
# ------------------------------------------------------------
install_docker() {
  command -v docker >/dev/null 2>&1 && return
  log "Docker not found; installing prerequisites + Docker Engine..."

  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release openssl

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  log "Docker installed."
}

ensure_docker_group() {
  getent group docker >/dev/null || groupadd docker
  if ! id "$REAL_USER" | grep -q docker; then
    log "Adding user '$REAL_USER' to docker group"
    usermod -aG docker "$REAL_USER"
    warn "You may need to log out/in for group changes to apply in existing sessions."
    exit
  fi
}

# -------------------------------
# Summary
# -------------------------------
install_docker
ensure_docker_group
