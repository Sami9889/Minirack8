#!/usr/bin/env bash
set -euo pipefail

MINIRACK_K3S_VERSION="v1.28.0+k3s1"
MINIRACK_CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

check_requirements() {
  info "Checking requirements..."
  command -v ssh &> /dev/null || fail "ssh is required but not installed."
}

bootstrap_server() {
  local server_ip="${1:?server ip required}"
  info "Bootstrapping K3s server at ${server_ip}..."
  ssh "root@${server_ip}" "bash -s" < "${MINIRACK_CLUSTER_DIR}/server.sh"
  info "Server bootstrapped."
}

bootstrap_agents() {
  local server_ip="${1:?server ip required}"
  shift
  local agents=("$@")
  [[ ${#agents[@]} -eq 0 ]] && fail "No agent IPs provided."

  local token
  token="$(ssh "root@${server_ip}" "cat /var/lib/rancher/k3s/server/node-token")"

  for agent_ip in "${agents[@]}"; do
    info "Bootstrapping agent at ${agent_ip}..."
    ssh "root@${agent_ip}" "bash -s" << EOF
set -euo pipefail
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${MINIRACK_K3S_VERSION}' sh -s - agent \
  --server 'https://${server_ip}:6443' \
  --token '${token}' \
  --node-name minirack8-worker
EOF
  done
  info "Agents bootstrapped."
}

main() {
  [[ $# -lt 2 ]] && fail "Usage: $0 <server-ip> <agent1-ip> [agent2-ip ...]"

  check_requirements
  bootstrap_server "$1"
  shift
  bootstrap_agents "$@"
}

main "$@"
