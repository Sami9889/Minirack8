#!/usr/bin/env bash
# =============================================================================
# MiniRack8 K3s Multi-Node Cluster Bootstrap
# Enterprise-grade cluster deployment with security hardening
# =============================================================================

set -euo pipefail
set -o nounset
set -o errtrace

MINIRACK_K3S_VERSION="v1.28.0+k3s1"
MINIRACK_CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIRACK_INSTALL_DIR="/var/lib/rancher/minirack8"

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

check_requirements() {
  info "Checking requirements..."
  command -v ssh &> /dev/null || fail "ssh is required but not installed."
  command -v scp &> /dev/null || fail "scp is required but not installed."
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
      fail "Invalid IP address: ${ip} (octet ${octet} > 255)"
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
# Server Bootstrap
# =============================================================================

bootstrap_server() {
  local server_ip="${1:?server ip required}"
  validate_ip "${server_ip}"

  info "Bootstrapping K3s server at ${server_ip}..."

  # Copy server script to remote with restricted permissions
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${MINIRACK_CLUSTER_DIR}/server.sh" "root@${server_ip}:/tmp/minirack8-server.sh"

  # Execute server script
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${server_ip}" "bash /tmp/minirack8-server.sh"

  # Clean up
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${server_ip}" "rm -f /tmp/minirack8-server.sh"

  info "Server bootstrapped at ${server_ip}"
}

# =============================================================================
# Agent Bootstrap
# =============================================================================

bootstrap_agents() {
  local server_ip="${1:?server ip required}"
  shift
  local agents=("$@")

  if [[ ${#agents[@]} -eq 0 ]]; then
    fail "No agent IPs provided."
  fi

  # Validate all agent IPs
  for agent_ip in "${agents[@]}"; do
    validate_ip "${agent_ip}"
  done

  # Retrieve join token from server
  info "Retrieving join token from server..."
  local token
  token="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${server_ip}" "cat ${MINIRACK_INSTALL_DIR}/server/node-token")"

  if [[ -z "${token}" ]]; then
    fail "Failed to retrieve node token from server."
  fi

  # Sanitize token for safe use in scripts
  token="${token//[^a-zA-Z0-9+/=]/}"

  # Bootstrap each agent
  for agent_ip in "${agents[@]}"; do
    info "Bootstrapping agent at ${agent_ip}..."

    # Create agent script with proper escaping
    cat > /tmp/minirack8-agent.sh << AGENTEOF
#!/usr/bin/env bash
set -euo pipefail
set -o nounset
set -o errtrace

# Install K3s agent
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${MINIRACK_K3S_VERSION}' sh -s - agent \
  --server 'https://${server_ip}:6443' \
  --token '${token}' \
  --node-name minirack8-worker \
  --log '${MINIRACK_INSTALL_DIR}/agent.log'
AGENTEOF

    chmod 700 /tmp/minirack8-agent.sh

    # Copy and execute with restricted permissions
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      /tmp/minirack8-agent.sh "root@${agent_ip}:/tmp/minirack8-agent.sh"

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${agent_ip}" "bash /tmp/minirack8-agent.sh"

    # Clean up
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${agent_ip}" "rm -f /tmp/minirack8-agent.sh"
    rm -f /tmp/minirack8-agent.sh

    info "Agent ${agent_ip} bootstrapped successfully."
  done
}

# =============================================================================
# Post-Bootstrap Verification
# =============================================================================

verify_cluster() {
  local server_ip="${1:?server ip required}"

  info "Verifying cluster status..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${server_ip}" << 'VERIFYEOF'
set -euo pipefail
set -o nounset
set -o errtrace

export KUBECONFIG=${MINIRACK_INSTALL_DIR}/kubeconfig

echo "=== Cluster Nodes ==="
kubectl get nodes -o wide

echo -e "\n=== System Pods ==="
kubectl get pods -A

echo -e "\n=== MiniRack8 Namespace ==="
kubectl get all -n minirack8
VERIFYEOF
}

# =============================================================================
# Main
# =============================================================================

main() {
  [[ $# -lt 2 ]] && fail "Usage: $0 <server-ip> <agent1-ip> [agent2-ip ...]"

  check_requirements

  local server_ip="$1"
  validate_ip "${server_ip}"
  shift

  local agents=("$@")

  info "MiniRack8 K3s Cluster Bootstrap"
  info "Server: ${server_ip}"
  info "Agents: ${agents[*]}"

  bootstrap_server "${server_ip}"

  if [[ ${#agents[@]} -gt 0 ]]; then
    bootstrap_agents "${server_ip}" "${agents[@]}"
  fi

  verify_cluster "${server_ip}"

  echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "MiniRack8 K3s cluster deployed successfully!"
  info "Kubeconfig: ${MINIRACK_INSTALL_DIR}/kubeconfig (on server)"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
}

main "$@"
