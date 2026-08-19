#!/usr/bin/env bash
# =============================================================================
# MiniRack8 All-in-One Installer
# One command to install Docker and deploy a profile
# =============================================================================

set -euo pipefail
set -o nounset
set -o errtrace

MINIRACK_INSTALL_DIR="/opt/minirack8"
MINIRACK_DOCKER_VERSION="5:24.0.0-1~ubuntu.22.04~jammy"
MINIRACK_COMPOSE_VERSION="v2.23.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo -e "\n${BLUE}[STEP]${NC} $*"; }

# =============================================================================
# Banner
# =============================================================================

show_banner() {
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   MiniRack8 All-in-One Installer                            ║
║   Install Docker + Deploy Blueprints in One Command         ║
║                                                              ║
║   Hardware: Intel i5-13500T | 16GB RAM | 256GB SSD         ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

# =============================================================================
# Validation
# =============================================================================

check_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root. Use: sudo bash install.sh"
  fi
}

check_os() {
  step "Checking operating system..."

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS="${ID}"
    VER="${VERSION_ID}"
    info "Detected: ${PRETTY_NAME}"
  else
    fail "Cannot detect OS. /etc/os-release not found."
  fi

  case "${OS}" in
    ubuntu|debian)
      info "OS supported: ${OS} ${VER}"
      ;;
    *)
      fail "Unsupported OS: ${OS}. This script supports Ubuntu and Debian only."
      ;;
  esac
}

check_hardware() {
  step "Checking hardware compatibility..."

  local total_ram_gb
  total_ram_gb=$(grep MemTotal /proc/meminfo | awk '{print $2 / 1024 / 1024}')
  info "Total RAM: ${total_ram_gb}GB"

  if [[ ${total_ram_gb} -lt 8 ]]; then
    warn "This system has less than 8GB RAM. MiniRack8 has 16GB."
  else
    info "RAM meets minimum requirements (8GB)."
  fi

  local cpu_cores
  cpu_cores=$(nproc)
  info "CPU cores: ${cpu_cores}"

  if [[ ${cpu_cores} -lt 4 ]]; then
    warn "This system has fewer than 4 cores. MiniRack8 has 14 cores."
  else
    info "CPU cores meet minimum requirements (4 cores)."
  fi

  local storage_gb
  storage_gb=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
  info "Available storage: ${storage_gb}GB"

  if [[ ${storage_gb} -lt 20 ]]; then
    fail "Insufficient storage. At least 20GB required."
  else
    info "Storage meets minimum requirements."
  fi
}

validate_profile() {
  local profile="${1:?profile required}"
  local valid_profiles=(
    "homelab" "dev" "networking" "storage"
    "monitoring" "full"
    "k3s-server" "k3s-agent" "k3s-cluster"
  )
  for valid in "${valid_profiles[@]}"; do
    if [[ "${profile}" == "${valid}" ]]; then
      return 0
    fi
  done
  fail "Invalid profile: ${profile}. Use --help for available profiles."
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

# =============================================================================
# Docker Installation
# =============================================================================

install_docker() {
  step "Checking Docker installation..."

  if command -v docker &> /dev/null && docker --version &> /dev/null; then
    info "Docker is already installed: $(docker --version)"
    return 0
  fi

  info "Docker not found. Installing Docker..."

  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS} $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Configure Docker daemon
  cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "features": {
    "buildkit": true
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  },
  "live-restore": true,
  "no-new-privileges": true
}
EOF

  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
Restart=always
RestartSec=10
LimitNOFILE=65536
EOF

  systemctl daemon-reload
  systemctl enable --now docker
  systemctl enable --now containerd

  # Wait for Docker to be ready
  local max_attempts=30
  local attempt=0
  while [[ ${attempt} -lt ${max_attempts} ]]; do
    if docker info &> /dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done

  if [[ ${attempt} -eq ${max_attempts} ]]; then
    fail "Docker daemon failed to start."
  fi

  info "Docker installed and configured."
}

# =============================================================================
# Blueprint Deployment
# =============================================================================

setup_blueprints() {
  step "Setting up MiniRack8 blueprints..."

  # Create directories
  mkdir -p "${MINIRACK_INSTALL_DIR}/docker-compose"
  mkdir -p "${MINIRACK_INSTALL_DIR}/scripts"
  mkdir -p "${MINIRACK_INSTALL_DIR}/logs"
  mkdir -p "${MINIRACK_INSTALL_DIR}/backups"

  # Copy blueprints from repo
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_dir
  repo_dir="$(dirname "${script_dir}")"

  cp -r "${repo_dir}/docker-compose" "${MINIRACK_INSTALL_DIR}/"
  cp -r "${repo_dir}/scripts" "${MINIRACK_INSTALL_DIR}/"
  cp -r "${repo_dir}/k3s" "${MINIRACK_INSTALL_DIR}/"
  cp -r "${repo_dir}/proxmox" "${MINIRACK_INSTALL_DIR}/"
  cp "${repo_dir}/.env.example" "${MINIRACK_INSTALL_DIR}/.env.example"
  cp "${repo_dir}/README.md" "${MINIRACK_INSTALL_DIR}/README.md" 2>/dev/null || true

  # Create .env if it doesn't exist
  if [[ ! -f "${MINIRACK_INSTALL_DIR}/.env" ]]; then
    cat > "${MINIRACK_INSTALL_DIR}/.env" << 'EOF'
# MiniRack8 Environment Configuration
# Generated by installer - CHANGE THESE PASSWORDS

# Pi-hole
PIHOLE_WEBPASSWORD=changeme
PIHOLE_IP=192.168.1.2

# Nextcloud / MariaDB
MYSQL_PASSWORD=changeme
MYSQL_ROOT_PASSWORD=changeme

# MinIO
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=changeme

# InfluxDB
INFLUXDB_PASSWORD=changeme

# Drone CI
DRONE_GITEA_SERVER=http://gitea:3000
DRONE_GITEA_CLIENT_ID=
DRONE_GITEA_CLIENT_SECRET=
DRONE_RPC_SECRET=
DRONE_SERVER_HOST=drone.local
DRONE_SERVER_PROTO=http

# WireGuard
WG_PEERS=3
EOF
    warn "Environment file created at ${MINIRACK_INSTALL_DIR}/.env"
    warn "IMPORTANT: Edit ${MINIRACK_INSTALL_DIR}/.env and set secure passwords!"
  fi

  info "Blueprints installed to ${MINIRACK_INSTALL_DIR}"
}

deploy_profile() {
  local profile="${1:?profile required}"
  step "Deploying profile: ${profile}"

  case "${profile}" in
    k3s-server)
      info "Installing K3s single-node server..."
      bash "${MINIRACK_INSTALL_DIR}/k3s/minirack8-single/install.sh"
      ;;
    k3s-agent)
      local server_ip="${2:?server IP required for k3s-agent}"
      validate_ip "${server_ip}"
      info "Installing K3s agent connecting to ${server_ip}..."
      bash "${MINIRACK_INSTALL_DIR}/k3s/minirack8-single/install.sh" agent "${server_ip}"
      ;;
    k3s-cluster)
      info "Deploying multi-node K3s cluster..."
      warn "This requires SSH key-based access to all nodes."
      read -rp "Enter server IP: " server_ip
      validate_ip "${server_ip}"
      read -rp "Enter agent IPs (space-separated): " -a agent_ips
      for agent_ip in "${agent_ips[@]}"; do
        validate_ip "${agent_ip}"
      done
      bash "${MINIRACK_INSTALL_DIR}/k3s/minirack8-cluster/bootstrap.sh" "${server_ip}" "${agent_ips[@]}"
      ;;
    *)
      info "Deploying Docker Compose profile: ${profile}"
      cd "${MINIRACK_INSTALL_DIR}/docker-compose"
      docker compose --profile "${profile}" pull
      docker compose --profile "${profile}" up -d
      ;;
  esac

  info "Profile '${profile}' deployed successfully."
}

# =============================================================================
# Summary
# =============================================================================

show_summary() {
  local profile="${1:?profile required}"
  echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "MiniRack8 installation complete!"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

  echo -e "\n${YELLOW}Installation Directory:${NC} ${MINIRACK_INSTALL_DIR}"
  echo -e "${YELLOW}Profile Deployed:${NC} ${profile}"

  echo -e "\n${YELLOW}Next Steps:${NC}"
  echo "1. Edit environment file: ${MINIRACK_INSTALL_DIR}/.env"
  echo "   ${YELLOW}IMPORTANT:${NC} Set secure passwords before accessing services."
  echo ""

  case "${profile}" in
    homelab)
      echo "2. Access services:"
      echo "   Plex:        http://$(hostname -I | awk '{print $1}'):32400"
      echo "   Jellyfin:    http://$(hostname -I | awk '{print $1}'):8096"
      echo "   Transmission: http://$(hostname -I | awk '{print $1}'):9091"
      echo "   SABnzbd:     http://$(hostname -I | awk '{print $1}'):8080"
      ;;
    dev)
      echo "2. Access services:"
      echo "   Gitea:       http://$(hostname -I | awk '{print $1}'):3000"
      echo "   Drone:       http://$(hostname -I | awk '{print $1}'):8081"
      echo "   code-server: https://$(hostname -I | awk '{print $1}'):8443"
      ;;
    networking)
      echo "2. Access services:"
      echo "   Pi-hole:     http://$(hostname -I | awk '{print $1}'):8082"
      echo "   WireGuard:   udp://$(hostname -I | awk '{print $1}'):51820"
      ;;
    storage)
      echo "2. Access services:"
      echo "   Nextcloud:   http://$(hostname -I | awk '{print $1}'):8083"
      echo "   MinIO:       http://$(hostname -I | awk '{print $1}'):9001"
      ;;
    monitoring)
      echo "2. Access services:"
      echo "   Grafana:     http://$(hostname -I | awk '{print $1}'):3002"
      echo "   Prometheus:  http://$(hostname -I | awk '{print $1}'):9090"
      echo "   InfluxDB:    http://$(hostname -I | awk '{print $1}'):8086"
      ;;
    full)
      echo "2. All services deployed. Check docker-compose.yml for port mappings."
      ;;
    k3s-server|k3s-agent|k3s-cluster)
      echo "2. Kubeconfig: ${MINIRACK_INSTALL_DIR}/k3s/minirack8-single/kubeconfig"
      echo "   Run: export KUBECONFIG=${MINIRACK_INSTALL_DIR}/k3s/minirack8-single/kubeconfig"
      ;;
  esac

  echo ""
  echo -e "${YELLOW}Useful Commands:${NC}"
  echo "  View logs:   cd ${MINIRACK_INSTALL_DIR}/docker-compose && docker compose logs -f"
  echo "  Stop:        cd ${MINIRACK_INSTALL_DIR}/docker-compose && docker compose down"
  echo "  Backup:      ${MINIRACK_INSTALL_DIR}/scripts/backup.sh"
  echo "  Security:    ${MINIRACK_INSTALL_DIR}/scripts/security-scan.sh"
  echo ""
}

# =============================================================================
# Main
# =============================================================================

show_usage() {
  cat << EOF
${GREEN}MiniRack8 All-in-One Installer${NC}

${YELLOW}Usage:${NC} $0 --profile <profile> [options]

${YELLOW}Profiles:${NC}
  homelab       Media, downloads, monitoring (4GB RAM)
  dev           Git, CI/CD, code-server (6GB RAM)
  networking    Pi-hole, WireGuard (2GB RAM)
  storage       Nextcloud, MinIO (4GB RAM)
  monitoring    Grafana, Prometheus, InfluxDB (2GB RAM)
  full          All services (16GB RAM)
  k3s-server    Install K3s single-node server
  k3s-agent     Install K3s agent (requires --server-ip)
  k3s-cluster   Bootstrap multi-node K3s cluster

${YELLOW}Options:${NC}
  --profile     Profile to deploy (required)
  --server-ip   K3s server IP (for k3s-agent)
  --skip-docker Skip Docker installation
  --help        Show this help

${YELLOW}Examples:${NC}
  $0 --profile homelab
  $0 --profile full
  $0 --profile k3s-server
  $0 --profile k3s-agent --server-ip 192.168.1.10
EOF
  exit 0
}

main() {
  show_banner

  PROFILE=""
  SERVER_IP=""
  SKIP_DOCKER=false

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
      --skip-docker)
        SKIP_DOCKER=true
        shift
        ;;
      --help|-h)
        show_usage
        ;;
      *)
        fail "Unknown option: $1. Use --help for usage."
        ;;
    esac
  done

  [[ -z "${PROFILE}" ]] && fail "Profile is required. Use --help for options."
  validate_profile "${PROFILE}"

  check_root
  check_os
  check_hardware

  if [[ "${SKIP_DOCKER}" != true ]]; then
    install_docker
  fi

  setup_blueprints

  case "${PROFILE}" in
    k3s-agent)
      [[ -z "${SERVER_IP}" ]] && fail "--server-ip is required for k3s-agent profile."
      validate_ip "${SERVER_IP}"
      deploy_profile "${PROFILE}" "${SERVER_IP}"
      ;;
    *)
      deploy_profile "${PROFILE}"
      ;;
  esac

  show_summary "${PROFILE}"
}

main "$@"
