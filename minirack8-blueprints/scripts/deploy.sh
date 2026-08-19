#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

show_usage() {
  cat << EOF
MiniRack8 Blueprint Deploy Script

Usage: $0 --profile <profile> [options]

Profiles:
  homelab       Media, downloads, monitoring (4GB RAM)
  dev           Git, CI/CD, code-server (6GB RAM)
  networking    Pi-hole, WireGuard (2GB RAM)
  storage       Nextcloud, MinIO (4GB RAM)
  ai            Ollama, Open WebUI (8GB RAM)
  monitoring    Grafana, Prometheus, InfluxDB (2GB RAM)
  full          All services (16GB RAM)
  k3s-server    Install K3s single-node server
  k3s-agent     Install K3s agent (requires --server-ip)
  k3s-cluster   Bootstrap multi-node K3s cluster

Options:
  --profile     Profile to deploy (required)
  --server-ip   K3s server IP (for k3s-agent)
  --dry-run     Show what would be deployed
  --help        Show this help

Examples:
  $0 --profile homelab
  $0 --profile full
  $0 --profile k3s-server
  $0 --profile k3s-agent --server-ip 192.168.1.10
EOF
  exit 0
}

parse_args() {
  PROFILE=""
  SERVER_IP=""
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        PROFILE="$2"
        shift 2
        ;;
      --server-ip)
        SERVER_IP="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help)
        show_usage
        ;;
      *)
        fail "Unknown option: $1. Use --help for usage."
        ;;
    esac
  done

  [[ -z "${PROFILE}" ]] && fail "Profile is required. Use --help for options."
}

deploy_docker() {
  local profile="$1"
  info "Deploying Docker Compose profile: ${profile}"

  if [[ "${DRY_RUN}" == true ]]; then
    info "[DRY RUN] Would execute: cd ${REPO_DIR}/docker-compose && docker compose --profile ${profile} up -d"
    return 0
  fi

  pushd "${REPO_DIR}/docker-compose" > /dev/null
  docker compose --profile "${profile}" up -d
  popd > /dev/null

  info "Docker Compose profile '${profile}' deployed."
}

deploy_k3s_server() {
  info "Deploying K3s single-node server..."
  if [[ "${DRY_RUN}" == true ]]; then
    info "[DRY RUN] Would execute: ${REPO_DIR}/k3s/minirack8-single/install.sh"
    return 0
  fi
  bash "${REPO_DIR}/k3s/minirack8-single/install.sh"
  info "K3s server deployed."
}

deploy_k3s_agent() {
  local server_ip="$1"
  [[ -z "${server_ip}" ]] && fail "--server-ip is required for k3s-agent profile."

  info "Deploying K3s agent connecting to ${server_ip}..."
  if [[ "${DRY_RUN}" == true ]]; then
    info "[DRY RUN] Would execute: ${REPO_DIR}/k3s/minirack8-single/install.sh agent ${server_ip}"
    return 0
  fi
  bash "${REPO_DIR}/k3s/minirack8-single/install.sh" agent "${server_ip}"
  info "K3s agent deployed."
}

deploy_k3s_cluster() {
  info "Deploying multi-node K3s cluster..."
  warn "This requires SSH key-based access to all nodes."
  read -rp "Enter server IP: " server_ip
  read -rp "Enter agent IPs (space-separated): " -a agent_ips

  if [[ "${DRY_RUN}" == true ]]; then
    info "[DRY RUN] Would bootstrap K3s cluster with server=${server_ip} and agents=${agent_ips[*]}"
    return 0
  fi

  bash "${REPO_DIR}/k3s/minirack8-cluster/bootstrap.sh" "${server_ip}" "${agent_ips[@]}"
  info "K3s cluster deployed."
}

main() {
  parse_args "$@"

  case "${PROFILE}" in
    homelab|dev|networking|storage|ai|monitoring|full)
      deploy_docker "${PROFILE}"
      ;;
    k3s-server)
      deploy_k3s_server
      ;;
    k3s-agent)
      deploy_k3s_agent "${SERVER_IP}"
      ;;
    k3s-cluster)
      deploy_k3s_cluster
      ;;
    *)
      fail "Unknown profile: ${PROFILE}. Use --help for available profiles."
      ;;
  esac

  info "MiniRack8 blueprint '${PROFILE}' deployment complete."
}

main "$@"
