#!/usr/bin/env bash
# MiniRack8 Enterprise Provisioner
# Production-ready deployment for Docker, K3s, and Proxmox

set -euo pipefail
set -o nounset
set -o errtrace

MINIRACK_INSTALL_DIR="/opt/minirack8"
MINIRACK_DOCKER_VERSION="5:24.0.0-1~ubuntu.22.04~jammy"
MINIRACK_COMPOSE_VERSION="v2.23.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# =============================================================================
# UI Helpers
# =============================================================================

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo -e "\n${BLUE}[STEP]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
divider() { echo -e "${DIM}──────────────────────────────────────────────────────────────${NC}"; }

animate_spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  while kill -0 "${pid}" 2>/dev/null; do
    for char in ${spinstr}; do
      printf "${CYAN}%c${NC}" "${char}"
      sleep "${delay}"
      printf "\b"
    done
  done
}

progress_bar() {
  local current=$1
  local total=$2
  local width=40
  local percentage=$((current * 100 / total))
  local completed=$((width * current / total))
  local remaining=$((width - completed))

  printf "\r${CYAN}["
  printf "%${completed}s" | tr ' ' '█'
  printf "%${remaining}s" | tr ' ' '░'
  printf "] ${percentage}%%${NC}"
}

show_banner() {
  clear
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   MiniRack8 Enterprise Provisioner                          ║
║   Production-Ready Deployment Automation                    ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
  echo ""
  echo -e "  ${DIM}Deploy Docker, K3s, and Proxmox resources${NC}"
  echo ""
  divider
  echo ""
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root. Use: sudo bash install.sh"
  fi
}

check_os() {
  step "Checking operating system..."

  if [[ "${SKIP_OS_CHECK}" == true ]]; then
    warn "Skipping OS compatibility check per --skip-os-check flag."
    return 0
  fi

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
      fail "Unsupported OS: ${OS}. This script supports Ubuntu and Debian only.

To bypass this check and continue anyway, re-run with:
  sudo bash install.sh --profile ${PROFILE} --skip-os-check"
      ;;
  esac
}

check_hardware() {
  step "Checking hardware compatibility..."

  # RAM check
  local total_ram_kb total_ram_gb
  total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  total_ram_gb=$(awk "BEGIN {printf \"%.1f\", ${total_ram_kb}/1024/1024}")
  info "RAM: ${total_ram_gb}GB"

  if (( $(awk "BEGIN {print (${total_ram_gb} < 8)}") )); then
    warn "This system has less than 8GB RAM. MiniRack8 has 16GB."
  else
    info "RAM meets minimum requirements (8GB)."
  fi

  # CPU check
  local cpu_cores cpu_model
  cpu_cores=$(nproc)
  cpu_model=$(grep 'model name' /proc/cpuinfo | head -1 | sed 's/.*: //')
  info "CPU: ${cpu_model}"
  info "Cores: ${cpu_cores}"

  if (( cpu_cores < 4 )); then
    warn "This system has fewer than 4 cores. MiniRack8 has 14 cores (i5-13500T)."
  else
    info "CPU cores meet minimum requirements (4 cores)."
  fi

  # Storage check
  local storage_gb
  storage_gb=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
  info "Storage: ${storage_gb}GB available"

  if [[ ${storage_gb} -lt 20 ]]; then
    fail "Insufficient storage. At least 20GB required."
  else
    info "Storage meets minimum requirements."
  fi

  # Network check
  local primary_ip
  primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
  info "Primary IP: ${primary_ip}"

  # Summary
  echo ""
  info "Hardware Summary:"
  echo "  CPU:    ${cpu_model}"
  echo "  Cores:  ${cpu_cores}"
  echo "  RAM:    ${total_ram_gb}GB"
  echo "  Disk:   ${storage_gb}GB"
  echo "  IP:     ${primary_ip}"
  echo ""
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

generate_password() {
  local length="${1:-32}"
  # Use /dev/urandom for cryptographically secure randomness
  # This is suitable for generating passwords that need to be high-entropy
  if [[ -r /dev/urandom ]]; then
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.<>?' < /dev/urandom | head -c "${length}"
  else
    # Fallback to openssl if /dev/urandom is not available
    openssl rand -base64 "${length}" | tr -d '\n' | tr -d '/' | tr -d '+' | head -c "${length}"
  fi
}

validate_password_strength() {
  local password="${1:?password required}"
  local min_length="${2:-16}"

  if [[ ${#password} -lt ${min_length} ]]; then
    fail "Password must be at least ${min_length} characters. Current: ${#password}"
  fi

  # Check for at least 3 of 4 character classes
  local score=0
  [[ "${password}" =~ [A-Z] ]] && ((score++))
  [[ "${password}" =~ [a-z] ]] && ((score++))
  [[ "${password}" =~ [0-9] ]] && ((score++))
  [[ "${password}" =~ [^A-Za-z0-9] ]] && ((score++))

  if [[ ${score} -lt 3 ]]; then
    warn "Password is weak. Recommend including uppercase, lowercase, numbers, and symbols."
  fi

  return 0
}

prompt_secure_password() {
  local var_name="${1:?variable name required}"
  local description="${2:-${var_name}}"
  local password=""
  local password_confirm=""

  echo ""
  info "Set password for: ${description}"
  echo "  Requirements: minimum 16 characters, mixed case, numbers, symbols"
  echo "  Press Enter to auto-generate a cryptographically secure password"
  echo ""

  # Use stty to disable echo for password input
  read -rsp "Password [auto-generate]: " password
  echo ""

  # Auto-generate if empty
  if [[ -z "${password}" ]]; then
    password=$(generate_password 32)
    info "Auto-generated ${#password}-character password."
    echo ""

    # Validate auto-generated password
    validate_password_strength "${password}" 16
  else
    # Validate custom password
    validate_password_strength "${password}" 16

    # Confirm password
    read -rsp "Confirm password: " password_confirm
    echo ""

    if [[ "${password}" != "${password_confirm}" ]]; then
      fail "Passwords do not match."
    fi
  fi

  # Set variable in parent scope
  printf -v "${var_name}" "%s" "${password}"
}

setup_secure_passwords() {
  step "Configuring secure passwords..."

  local pihole_password mysql_password mysql_root_password minio_password influxdb_password

  info "Generating cryptographically secure passwords using /dev/urandom"
  echo ""

  prompt_secure_password "pihole_password" "Pi-hole Admin Password"
  prompt_secure_password "mysql_password" "Nextcloud Database Password"
  prompt_secure_password "mysql_root_password" "MariaDB Root Password"
  prompt_secure_password "minio_password" "MinIO Root Password"
  prompt_secure_password "influxdb_password" "InfluxDB Admin Password"

  echo ""
  info "Generating additional secrets..."

  # Generate WireGuard key pair
  local wg_private_key wg_public_key
  if command -v wg &> /dev/null; then
    wg_private_key=$(wg genkey)
    wg_public_key=$(echo "${wg_private_key}" | wg pubkey)
  else
    warn "WireGuard tools not installed. Generating random keys."
    wg_private_key=$(generate_password 32)
    wg_public_key=$(generate_password 32)
  fi

  # Generate random Drone secrets
  local drone_client_id drone_client_secret drone_rpc_secret
  drone_client_id=$(generate_password 24)
  drone_client_secret=$(generate_password 32)
  drone_rpc_secret=$(generate_password 32)

  # Detect primary IP
  local primary_ip
  primary_ip=$(hostname -I | awk '{print $1}')
  if [[ -z "${primary_ip}" ]]; then
    primary_ip="192.168.1.10"
    warn "Could not detect IP. Using default: ${primary_ip}"
  fi

  # Create .env with secure permissions
  cat > "${MINIRACK_INSTALL_DIR}/.env" << EOF
# MiniRack8 Environment Configuration
# SECURITY: This file contains sensitive credentials
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Generated by: $(whoami)@$(hostname)
# PCI-DSS Inspired: All passwords are cryptographically secure

# =============================================================================
# Pi-hole
# =============================================================================
PIHOLE_WEBPASSWORD=${pihole_password}
PIHOLE_IP=${primary_ip}

# =============================================================================
# Nextcloud / MariaDB
# =============================================================================
MYSQL_PASSWORD=${mysql_password}
MYSQL_ROOT_PASSWORD=${mysql_root_password}

# =============================================================================
# MinIO
# =============================================================================
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=${minio_password}

# =============================================================================
# InfluxDB
# =============================================================================
INFLUXDB_PASSWORD=${influxdb_password}

# =============================================================================
# Drone CI
# =============================================================================
DRONE_GITEA_SERVER=http://gitea:3000
DRONE_GITEA_CLIENT_ID=${drone_client_id}
DRONE_GITEA_CLIENT_SECRET=${drone_client_secret}
DRONE_RPC_SECRET=${drone_rpc_secret}
DRONE_SERVER_HOST=drone.local
DRONE_SERVER_PROTO=http

# =============================================================================
# WireGuard
# =============================================================================
WG_PRIVATE_KEY=${wg_private_key}
WG_PUBLIC_KEY=${wg_public_key}
WG_PEERS=3
EOF

  # Set strict permissions - owner read/write only
  chmod 600 "${MINIRACK_INSTALL_DIR}/.env"

  # Create audit log entry
  local audit_dir="${MINIRACK_INSTALL_DIR}/logs"
  mkdir -p "${audit_dir}"
  cat > "${audit_dir}/password-generation-$(date +%Y%m%d-%H%M%S).log" << EOF
=== MiniRack8 Password Generation Audit ===
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
User: $(whoami)
Host: $(hostname)
Profile: ${PROFILE}
Generated by: install.sh

Services configured:
  - Pi-hole:        ${pihole_password}
  - MySQL:          ${mysql_password}
  - MySQL Root:     ${mysql_root_password}
  - MinIO:          ${minio_password}
  - InfluxDB:       ${influxdb_password}
  - WireGuard PK:   ${wg_private_key}

Security:
  - Password length: 32 characters
  - Entropy source: /dev/urandom
  - File permissions: 600
  - PCI-DSS inspired: YES
EOF

  info "Environment file created: ${MINIRACK_INSTALL_DIR}/.env"
  info "Permissions set to 600 (owner read/write only)."
  info "Audit log: ${audit_dir}/password-generation-*.log"

  echo ""
  info "Password Summary (save these in a secure password manager):"
  echo "  Pi-hole:        ${pihole_password}"
  echo "  MySQL:          ${mysql_password}"
  echo "  MySQL Root:     ${mysql_root_password}"
  echo "  MinIO:          ${minio_password}"
  echo "  InfluxDB:       ${influxdb_password}"
  echo "  Drone Client:   ${drone_client_id}"
  echo "  Drone Secret:   ${drone_client_secret}"
  echo "  Drone RPC:      ${drone_rpc_secret}"
  echo "  WireGuard PK:   ${wg_private_key}"
  echo ""
  warn "SECURITY: Store these passwords in a secure password manager!"
  warn "SECURITY: Never share .env file or commit to version control!"
}

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
    setup_secure_passwords
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

show_summary() {
  local profile="${1:?profile required}"
  echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "MiniRack8 installation complete!"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

  echo -e "\n${YELLOW}Installation Directory:${NC} ${MINIRACK_INSTALL_DIR}"
  echo -e "${YELLOW}Profile Deployed:${NC} ${profile}"

  echo -e "\n${YELLOW}Next Steps:${NC}"
  echo "1. Passwords saved to: ${MINIRACK_INSTALL_DIR}/.env (mode 600)"
  echo "   Save these in a secure password manager!"
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

show_usage() {
  cat << EOF
${GREEN}MiniRack8 Enterprise Provisioner${NC}

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
  --skip-os-check Bypass OS compatibility check
  --force        Skip OS and Docker checks, deploy immediately
  --help        Show this help

${YELLOW}Examples:${NC}
  $0 --profile homelab
  $0 --profile full
  $0 --profile k3s-server
  $0 --profile k3s-agent --server-ip 192.168.1.10
  $0 --profile homelab --skip-os-check
  $0 --profile homelab --force
EOF
  exit 0
}

main() {
  PROFILE=""
  SERVER_IP=""
  SKIP_DOCKER=false
  SKIP_OS_CHECK=false
  FORCE_MODE=false

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
      --skip-os-check)
        SKIP_OS_CHECK=true
        shift
        ;;
      --force)
        FORCE_MODE=true
        SKIP_OS_CHECK=true
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
  show_banner
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
