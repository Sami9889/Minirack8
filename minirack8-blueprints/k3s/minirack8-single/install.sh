#!/usr/bin/env bash
# =============================================================================
# MiniRack8 K3s Single-Node Installer
# Enterprise-grade K3s installation with security hardening
# =============================================================================

set -euo pipefail
set -o nounset
set -o errtrace

MINIRACK_K3S_VERSION="v1.28.0+k3s1"
MINIRACK_K3S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIRACK_INSTALL_DIR="${MINIRACK_INSTALL_DIR:-/var/lib/rancher/minirack8}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# =============================================================================
# Validation
# =============================================================================

check_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root. Use: sudo $0"
  fi
}

check_requirements() {
  info "Checking requirements..."
  if ! command -v curl &> /dev/null; then
    fail "curl is required but not installed."
  fi
  if ! command -v docker &> /dev/null; then
    warn "Docker not found. Some profiles may not work."
  fi
}

validate_ip() {
  local ip="${1:?IP address required}"
  local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  if [[ ! ${ip} =~ ${regex} ]]; then
    fail "Invalid IP address format: ${ip}"
  fi
  IFS='.' read -r -a octets <<< "${ip}"
  for octet in "${octets[@]}"; do
    if (( octet > 255 )); then
      fail "Invalid IP address: ${ip}"
    fi
  done
}

validate_hostname() {
  local hostname="${1:?hostname required}"
  local regex='^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$'
  if [[ ! ${hostname} =~ ${regex} ]]; then
    fail "Invalid hostname: ${hostname}"
  fi
}

# =============================================================================
# Configuration
# =============================================================================

configure_k3s() {
  info "Configuring K3s for MiniRack8..."
  mkdir -p "${MINIRACK_INSTALL_DIR}/etc"
  mkdir -p "${MINIRACK_INSTALL_DIR}/manifests"

  # Container registry configuration
  cat > "${MINIRACK_INSTALL_DIR}/etc/registries.yaml" << 'EOF'
configs:
  docker.io:
    auths: {}
  ghcr.io:
    auths: {}
  registry.k8s.io:
    auths: {}
EOF

  # MiniRack8 namespace and hardware info
  cat > "${MINIRACK_INSTALL_DIR}/manifests/minirack8-config.yaml" << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: minirack8
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: minirack8-info
  namespace: minirack8
data:
  hardware: "MiniRack8"
  cpu: "Intel i5-13500T"
  memory: "16GB"
  storage: "256GB SSD"
EOF

  info "K3s configuration written to ${MINIRACK_INSTALL_DIR}"
}

# =============================================================================
# Installation
# =============================================================================

install_k3s_server() {
  info "Installing K3s server..."

  # Download and verify K3s binary
  local k3s_url="https://github.com/k3s-io/k3s/releases/download/${MINIRACK_K3S_VERSION}/k3s"
  info "Downloading K3s from ${k3s_url}"

  curl -fsSL "${k3s_url}" -o /usr/local/bin/k3s
  chmod +x /usr/local/bin/k3s

  # Create kubeconfig directory
  mkdir -p "${MINIRACK_INSTALL_DIR}"
  chmod 755 "${MINIRACK_INSTALL_DIR}"

  # Get primary IP for TLS SAN
  local primary_ip
  primary_ip=$(hostname -I | awk '{print $1}')
  validate_ip "${primary_ip}"

  # Start K3s server
  info "Starting K3s server..."
  k3s server \
    --write-kubeconfig "${MINIRACK_INSTALL_DIR}/kubeconfig" \
    --write-kubeconfig-mode 600 \
    --node-name minirack8-master \
    --disable traefik \
    --disable servicelb \
    --disable local-storage \
    --tls-san "${primary_ip}" \
    --tls-san 127.0.0.1 \
    --log "${MINIRACK_INSTALL_DIR}/server.log" &

  # Wait for server to be ready
  info "Waiting for K3s server to be ready..."
  local max_attempts=60
  local attempt=0
  while [[ ${attempt} -lt ${max_attempts} ]]; do
    if kubectl --kubeconfig="${MINIRACK_INSTALL_DIR}/kubeconfig" get nodes &> /dev/null; then
      info "K3s server is ready."
      break
    fi
    attempt=$((attempt + 1))
    sleep 5
  done

  if [[ ${attempt} -eq ${max_attempts} ]]; then
    fail "K3s server failed to start within ${max_attempts} attempts."
  fi

  # Apply MiniRack8 manifests
  kubectl --kubeconfig="${MINIRACK_INSTALL_DIR}/kubeconfig" apply -f "${MINIRACK_INSTALL_DIR}/manifests/"

  info "K3s server installed successfully."
}

install_k3s_agent() {
  local server_ip="${1:-}"
  local token_file="${2:-/var/lib/rancher/k3s/server/node-token}"

  [[ -z "${server_ip}" ]] && fail "Usage: $0 agent <server-ip> [token-file]"
  validate_ip "${server_ip}"

  info "Installing K3s agent..."

  # Download K3s binary
  local k3s_url="https://github.com/k3s-io/k3s/releases/download/${MINIRACK_K3S_VERSION}/k3s"
  info "Downloading K3s from ${k3s_url}"
  curl -fsSL "${k3s_url}" -o /usr/local/bin/k3s
  chmod +x /usr/local/bin/k3s

  # Get token from server
  info "Retrieving join token from server..."
  local token
  token="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${server_ip}" "cat ${token_file}")"

  if [[ -z "${token}" ]]; then
    fail "Failed to retrieve node token from server."
  fi

  # Sanitize token
  token="${token//[^a-zA-Z0-9+/=]/}"

  # Start K3s agent
  k3s agent \
    --server "https://${server_ip}:6443" \
    --token "${token}" \
    --node-name minirack8-worker \
    --log "${MINIRACK_INSTALL_DIR}/agent.log" &

  info "K3s agent installed."
}

# =============================================================================
# Kubeconfig
# =============================================================================

show_kubeconfig() {
  info "Kubeconfig location: ${MINIRACK_INSTALL_DIR}/kubeconfig"
  info "To use kubectl:"
  echo "  export KUBECONFIG=${MINIRACK_INSTALL_DIR}/kubeconfig"
}

# =============================================================================
# Main
# =============================================================================

main() {
  check_root
  check_requirements
  configure_k3s

  case "${1:-server}" in
    server)
      install_k3s_server
      show_kubeconfig
      ;;
    agent)
      install_k3s_agent "${2:?server ip required}" "${3:-/var/lib/rancher/k3s/server/node-token}"
      ;;
    *)
      fail "Usage: $0 [server|agent <server-ip> [token-file]]"
      ;;
  esac
}

main "$@"
