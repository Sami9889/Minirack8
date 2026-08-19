#!/usr/bin/env bash
set -euo pipefail

MINIRACK_K3S_VERSION="v1.28.0+k3s1"
MINIRACK_K3S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIRACK_INSTALL_DIR="${MINIRACK_INSTALL_DIR:-/var/lib/rancher/minirack8}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

fail() {
  echo -e "${RED}[FAIL]${NC} $*"
  exit 1
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

configure_k3s() {
  info "Configuring K3s for MiniRack8..."
  mkdir -p "${MINIRACK_INSTALL_DIR}/etc"
  mkdir -p "${MINIRACK_INSTALL_DIR}/manifests"

  cat > "${MINIRACK_INSTALL_DIR}/etc/registries.yaml" << 'EOF'
configs:
  docker.io:
    auths: {}
  ghcr.io:
    auths: {}
EOF

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

install_k3s_server() {
  info "Installing K3s server..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${MINIRACK_K3S_VERSION}" sh -s - server \
    --write-kubeconfig "${MINIRACK_INSTALL_DIR}/kubeconfig" \
    --write-kubeconfig-mode 600 \
    --disable traefik \
    --node-name minirack8-master
  info "K3s server installed."
}

install_k3s_agent() {
  local server_ip="${1:-}"
  local token_file="${2:-/var/lib/rancher/k3s/server/node-token}"
  [[ -z "${server_ip}" ]] && fail "Usage: $0 agent <server-ip> [token-file]"

  info "Installing K3s agent..."
  local token
  token="$(cat "${token_file}")"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${MINIRACK_K3S_VERSION}" sh -s - agent \
    --server "https://${server_ip}:6443" \
    --token "${token}" \
    --node-name minirack8-worker
  info "K3s agent installed."
}

show_kubeconfig() {
  info "Kubeconfig location: ${MINIRACK_INSTALL_DIR}/kubeconfig"
  info "To use kubectl:"
  echo "  export KUBECONFIG=${MINIRACK_INSTALL_DIR}/kubeconfig"
}

main() {
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
