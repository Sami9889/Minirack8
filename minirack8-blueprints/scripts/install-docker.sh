#!/usr/bin/env bash
# MiniRack8 Docker Installer
# Production-ready Docker CE installation

set -euo pipefail
set -o nounset
set -o errtrace

# =============================================================================
# Pipe/bootstrap detection
# =============================================================================

if [[ -z "${BASH_SOURCE[0]:-}" || ! -f "${BASH_SOURCE[0]}" ]]; then
  tmp_script="$(mktemp /tmp/minirack8-docker.XXXXXX.sh)"
  cat > "${tmp_script}"
  chmod +x "${tmp_script}"
  exec bash "${tmp_script}" "$@"
fi

MINIRACK_DOCKER_VERSION="5:24.0.0-1~ubuntu.22.04~jammy"
MINIRACK_COMPOSE_VERSION="v2.23.0"
MINIRACK_INSTALL_DIR="/opt/minirack8"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
# shellcheck disable=SC2034
MAGENTA='\033[0;35m'
# shellcheck disable=SC2034
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step() { echo -e "\n${BLUE}[STEP]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
divider() { echo -e "${DIM}──────────────────────────────────────────────────────────────${NC}"; }

animate_spinner() {
  local pid=$1
  local delay=0.1
  # shellcheck disable=SC1003
  local spinstr='|/-\'
  while kill -0 "${pid}" 2>/dev/null; do
    for char in ${spinstr}; do
      # shellcheck disable=SC2059
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

  # shellcheck disable=SC2059
  printf "\r${CYAN}["
  printf "%${completed}s" | tr ' ' '█'
  printf "%${remaining}s" | tr ' ' '░'
  printf "] ${percentage}%%${NC}"
}

self_update() {
  step "Checking for updates..."

  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_dir
  repo_dir="$(dirname "${script_path}")"

  if [[ ! -d "${repo_dir}/.git" ]]; then
    info "Not a git clone. Skipping self-update."
    info "To get the latest version, re-run the install command."
    return 0
  fi

  pushd "${repo_dir}" > /dev/null 2>&1 || return 0

  local current_commit
  current_commit=$(git rev-parse HEAD 2>/dev/null || echo "")

  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")

  if [[ -z "${current_commit}" || -z "${remote_url}" ]]; then
    popd > /dev/null 2>&1 || true
    info "No git remote configured. Skipping self-update."
    return 0
  fi

  info "Current version: ${current_commit:0:8}"

  git fetch origin > /dev/null 2>&1 || {
    warn "Failed to fetch updates. Check network connection."
    popd > /dev/null 2>&1 || true
    return 0
  }

  local latest_commit
  latest_commit=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null || echo "")

  if [[ -z "${latest_commit}" ]]; then
    popd > /dev/null 2>&1 || true
    info "Could not determine latest version. Skipping self-update."
    return 0
  fi

  info "Latest version:  ${latest_commit:0:8}"

  if [[ "${current_commit}" == "${latest_commit}" ]]; then
    info "Already on the latest version."
    popd > /dev/null 2>&1 || true
    return 0
  fi

  echo ""
  warn "A new version is available!"
  info "Updating from ${current_commit:0:8} to ${latest_commit:0:8}..."

  git stash > /dev/null 2>&1 || true

  if ! git pull --rebase origin > /dev/null 2>&1; then
    warn "Auto-update failed. Please manually run: git pull"
    git stash pop > /dev/null 2>&1 || true
    popd > /dev/null 2>&1 || true
    return 0
  fi

  git stash pop > /dev/null 2>&1 || true

  info "Updated to latest version: $(git rev-parse HEAD 2>/dev/null | cut -c1-8)"

  popd > /dev/null 2>&1 || true

  echo ""
  info "Re-running Docker installer with latest version..."
  echo ""

  exec bash "${script_path}/install-docker.sh" "$@"
}

show_banner() {
  clear
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   MiniRack8 Docker Installer                                ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
  echo ""
  echo -e "  ${DIM}Install Docker CE with hardened configuration${NC}"
  echo ""
  divider
  echo ""
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root. Use: sudo bash install-docker.sh"
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
    ubuntu)
      if [[ "${VER}" != "22.04" && "${VER}" != "24.04" ]]; then
        warn "This script is tested on Ubuntu 22.04/24.04. You are running ${VER}."
        read -rp "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
          fail "Installation aborted."
        fi
      fi
      ;;
    debian)
      if [[ "${VER}" != "11" && "${VER}" != "12" ]]; then
        warn "This script is tested on Debian 11/12. You are running ${VER}."
      fi
      ;;
    *)
      fail "Unsupported OS: ${OS}. This script supports Ubuntu and Debian only."
      ;;
  esac
}

check_hardware() {
  step "Checking hardware compatibility..."

  # RAM check
  local total_ram_kb
  total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local total_ram_gb=$((total_ram_kb / 1024 / 1024))
  info "Total RAM: ${total_ram_gb}GB"

  if [[ ${total_ram_gb} -lt 8 ]]; then
    warn "This system has less than 8GB RAM. MiniRack8 has 16GB."
    warn "Docker may not perform optimally."
  else
    info "RAM meets minimum requirements (8GB)."
  fi

  # CPU check
  local cpu_cores
  cpu_cores=$(nproc)
  info "CPU cores: ${cpu_cores}"

  if [[ ${cpu_cores} -lt 4 ]]; then
    warn "This system has fewer than 4 cores. MiniRack8 has 14 cores."
  else
    info "CPU cores meet minimum requirements (4 cores)."
  fi

  # Storage check
  local storage_gb
  storage_gb=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
  info "Available storage: ${storage_gb}GB"

  if [[ ${storage_gb} -lt 20 ]]; then
    fail "Insufficient storage. At least 20GB required."
  else
    info "Storage meets minimum requirements."
  fi
}

uninstall_old_docker() {
  step "Removing old Docker versions..."

  # Remove old Docker packages
  local old_pkgs=(docker.io docker-doc docker-compose podman-docker containerd runc)
  for pkg in "${old_pkgs[@]}"; do
    if dpkg -l | grep -q "^ii  ${pkg}"; then
      info "Removing ${pkg}..."
      apt-get remove -y -qq "${pkg}" 2>/dev/null || true
    fi
  done

  # Remove old Docker directories
  rm -rf /var/lib/docker
  rm -rf /var/lib/containerd

  info "Old Docker versions removed."
}

install_prerequisites() {
  step "Installing prerequisites..."

  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    jq \
    git \
    htop \
    iotop \
    net-tools

  info "Prerequisites installed."
}

setup_docker_repo() {
  step "Setting up Docker repository..."

  install -m 0755 -d /etc/apt/keyrings

  # Download Docker GPG key
  curl -fsSL "https://download.docker.com/linux/${OS}/gpg" | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Add repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${OS} $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq

  info "Docker repository configured."
}

install_docker_ce() {
  step "Installing Docker CE..."

  apt-get install -y -qq \
    docker-ce="${MINIRACK_DOCKER_VERSION}" \
    docker-ce-cli="${MINIRACK_DOCKER_VERSION}" \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  # Verify installation
  if ! command -v docker &> /dev/null; then
    fail "Docker installation failed."
  fi

  info "Docker CE installed: $(docker --version)"
  info "Docker Compose: $(docker compose version --short 2>/dev/null || echo 'not found')"
}

configure_docker() {
  step "Configuring Docker daemon..."

  # Create Docker daemon configuration
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

  # Create Docker systemd override
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
Restart=always
RestartSec=10
LimitNOFILE=65536
EOF

  # Reload systemd and restart Docker
  systemctl daemon-reload
  systemctl enable --now docker
  systemctl enable --now containerd

  # Wait for Docker to be ready
  local max_attempts=30
  local attempt=0
  while [[ ${attempt} -lt ${max_attempts} ]]; do
    if docker info &> /dev/null; then
      info "Docker daemon is running."
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done

  if [[ ${attempt} -eq ${max_attempts} ]]; then
    fail "Docker daemon failed to start."
  fi

  info "Docker daemon configured."
}

configure_firewall() {
  step "Configuring firewall..."

  if command -v ufw &> /dev/null; then
    # Allow SSH
    ufw allow ssh 2>/dev/null || true

    # Allow Docker profiles
    ufw allow 32400/tcp 2>/dev/null || true   # Plex
    ufw allow 8096/tcp 2>/dev/null || true    # Jellyfin
    ufw allow 9091/tcp 2>/dev/null || true    # Transmission
    ufw allow 8080/tcp 2>/dev/null || true    # SABnzbd
    ufw allow 3000/tcp 2>/dev/null || true    # Gitea
    ufw allow 8081/tcp 2>/dev/null || true    # Drone
    ufw allow 8443/tcp 2>/dev/null || true    # Code-server
    ufw allow 8082/tcp 2>/dev/null || true    # Pi-hole
    ufw allow 51820/udp 2>/dev/null || true   # WireGuard
    ufw allow 8083/tcp 2>/dev/null || true    # Nextcloud
    ufw allow 9000/tcp 2>/dev/null || true    # MinIO
    ufw allow 9001/tcp 2>/dev/null || true    # MinIO console
    ufw allow 3002/tcp 2>/dev/null || true    # Grafana
    ufw allow 9090/tcp 2>/dev/null || true    # Prometheus
    ufw allow 8086/tcp 2>/dev/null || true    # InfluxDB
    ufw allow 9443/tcp 2>/dev/null || true    # Portainer

    info "Firewall rules configured."
  else
    warn "UFW not found. Please configure firewall manually."
  fi
}

install_docker_compose() {
  step "Installing Docker Compose..."

  # Check if already installed via plugin
  if docker compose version &> /dev/null; then
    info "Docker Compose plugin already installed."
    return 0
  fi

  # Install standalone binary as fallback
  local compose_dir="/usr/local/lib/docker/cli-plugins"
  mkdir -p "${compose_dir}"

  local arch
  arch=$(uname -m)
  case "${arch}" in
    x86_64) arch="x86_64" ;;
    aarch64) arch="aarch64" ;;
    armv7l) arch="armv7" ;;
    *)
      fail "Unsupported architecture: ${arch}"
      ;;
  esac

  local compose_url="https://github.com/docker/compose/releases/download/${MINIRACK_COMPOSE_VERSION}/docker-compose-linux-${arch}"

  info "Downloading Docker Compose from ${compose_url}..."
  curl -fsSL "${compose_url}" -o "${compose_dir}/docker-compose"

  chmod +x "${compose_dir}/docker-compose"

  if docker compose version &> /dev/null; then
    info "Docker Compose installed: $(docker compose version --short)"
  else
    warn "Docker Compose installation may have failed."
  fi
}

create_minirack_directories() {
  step "Creating MiniRack8 directories..."

  mkdir -p "${MINIRACK_INSTALL_DIR}/docker-compose"
  mkdir -p "${MINIRACK_INSTALL_DIR}/scripts"
  mkdir -p "${MINIRACK_INSTALL_DIR}/logs"
  mkdir -p "${MINIRACK_INSTALL_DIR}/backups"
  mkdir -p "${MINIRACK_INSTALL_DIR}/configs"

  info "MiniRack8 directories created at ${MINIRACK_INSTALL_DIR}"
}

generate_password() {
  local length="${1:-32}"
  openssl rand -base64 "${length}" | tr -d '\n' | tr -d '/' | tr -d '+' | head -c "${length}"
}

setup_environment() {
  step "Setting up environment..."

  # Create environment file if it doesn't exist
  if [[ ! -f "${MINIRACK_INSTALL_DIR}/.env" ]]; then
    info "Generating cryptographically secure passwords..."
    echo ""

    local pihole_password mysql_password mysql_root_password minio_password influxdb_password
    local drone_client_id drone_client_secret drone_rpc_secret
    local wg_private_key wg_public_key

    # Generate passwords using /dev/urandom via openssl
    pihole_password=$(generate_password 32)
    mysql_password=$(generate_password 32)
    mysql_root_password=$(generate_password 32)
    minio_password=$(generate_password 32)
    influxdb_password=$(generate_password 32)

    # Generate WireGuard key pair (fallback to random if wg not installed)
    if command -v wg &> /dev/null; then
      wg_private_key=$(wg genkey)
      wg_public_key=$(echo "${wg_private_key}" | wg pubkey)
    else
      warn "WireGuard tools not installed. Generating random keys."
      wg_private_key=$(generate_password 32)
      wg_public_key=$(generate_password 32)
    fi

    # Generate random Drone secrets
    drone_client_id=$(generate_password 24)
    drone_client_secret=$(generate_password 32)
    drone_rpc_secret=$(generate_password 32)

    # Detect primary IP
    local primary_ip
    primary_ip=$(hostname -I | awk '{print $1}')
    if [[ -z "${primary_ip}" ]]; then
      primary_ip="192.168.1.2"
      warn "Could not detect IP. Using default: ${primary_ip}"
    fi

    cat > "${MINIRACK_INSTALL_DIR}/.env" << EOF
# MiniRack8 Environment Configuration
# SECURITY: This file contains sensitive credentials
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

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

    chmod 600 "${MINIRACK_INSTALL_DIR}/.env"

    info "Environment file created: ${MINIRACK_INSTALL_DIR}/.env"
    warn "Permissions set to 600 (owner read/write only)."
    echo ""
    info "Generated passwords:"
    echo "  Pi-hole:        ${pihole_password}"
    echo "  MySQL:          ${mysql_password}"
    echo "  MySQL Root:     ${mysql_root_password}"
    echo "  MinIO:          ${minio_password}"
    echo "  InfluxDB:       ${influxdb_password}"
    echo "  Drone Client:   ${drone_client_id}"
    echo "  Drone Secret:   ${drone_client_secret}"
    echo "  Drone RPC:      ${drone_rpc_secret}"
    echo ""
    warn "Save these passwords in a secure password manager!"
  else
    info "Environment file already exists at ${MINIRACK_INSTALL_DIR}/.env"
    warn "Using existing passwords."
  fi
}

verify_installation() {
  step "Verifying Docker installation..."

  # Check Docker version
  if docker --version &> /dev/null; then
    info "Docker: $(docker --version)"
  else
    fail "Docker verification failed."
  fi

  # Check Docker Compose
  if docker compose version &> /dev/null; then
    info "Docker Compose: $(docker compose version --short)"
  else
    warn "Docker Compose plugin not found."
  fi

  # Test Docker with hello-world
  info "Testing Docker with hello-world..."
  if docker run --rm hello-world &> /dev/null; then
    info "Docker test successful."
  else
    warn "Docker test failed. Check network connectivity."
  fi

  # Check Docker info
  info "Docker storage driver: $(docker info --format '{{.Driver}}')"
  info "Docker root directory: $(docker info --format '{{.DockerRootDir}}')"
}

show_summary() {
  echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "Docker installation completed successfully!"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

  echo -e "\n${YELLOW}Next Steps:${NC}"
  echo "1. Passwords saved to: ${MINIRACK_INSTALL_DIR}/.env (mode 600)"
  echo "   Save these in a secure password manager!"
  echo ""
  echo "2. Deploy MiniRack8 blueprints:"
  echo "   ${MINIRACK_INSTALL_DIR}/scripts/deploy.sh --profile homelab"
  echo ""
  echo "3. Or manually deploy:"
  echo "   cd ${MINIRACK_INSTALL_DIR}/docker-compose"
  echo "   docker compose --profile homelab up -d"
  echo ""
  echo -e "${YELLOW}Documentation:${NC}"
  echo "  Security guide: ${MINIRACK_INSTALL_DIR}/docs/SECURITY.md"
  echo "  Backup script: ${MINIRACK_INSTALL_DIR}/scripts/backup.sh"
  echo ""
}

main() {
  NO_SELF_UPDATE=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-self-update)
        NO_SELF_UPDATE=true
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ "${NO_SELF_UPDATE}" != true ]]; then
    self_update "$@"
  fi

  show_banner
  check_root
  check_os
  check_hardware
  uninstall_old_docker
  install_prerequisites
  setup_docker_repo
  install_docker_ce
  configure_docker
  configure_firewall
  install_docker_compose
  create_minirack_directories
  setup_environment
  verify_installation
  show_summary
}

main "$@"
