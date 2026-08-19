#!/usr/bin/env bash
# =============================================================================
# MiniRack8 Docker Installer
# Professional, self-contained Docker CE installer for MiniRack8
# No agent required - run directly on the target host
# =============================================================================

set -euo pipefail

MINIRACK_DOCKER_VERSION="5:24.0.0-1~ubuntu.22.04~jammy"
MINIRACK_COMPOSE_VERSION="v2.23.0"
MINIRACK_INSTALL_DIR="/opt/minirack8"

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
║   MiniRack8 Docker Installer                                ║
║   Professional Docker CE Installation                       ║
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
    fail "This script must be run as root. Use: sudo bash install-docker.sh"
  fi
}

check_os() {
  step "Checking operating system..."

  if [[ -f /etc/os-release ]]; then
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
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
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

# =============================================================================
# Pre-installation
# =============================================================================

uninstall_old_docker() {
  step "Removing old Docker versions..."

  # Remove old Docker packages
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
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
  curl -fsSL https://download.docker.com/linux/${OS}/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Add repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${OS} $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq

  info "Docker repository configured."
}

# =============================================================================
# Docker Installation
# =============================================================================

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

# =============================================================================
# Post-installation
# =============================================================================

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

setup_environment() {
  step "Setting up environment..."

  # Create environment file if it doesn't exist
  if [[ ! -f "${MINIRACK_INSTALL_DIR}/.env" ]]; then
    cat > "${MINIRACK_INSTALL_DIR}/.env" << 'EOF'
# MiniRack8 Environment Configuration
# Generated by Docker installer

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

    info "Environment file created at ${MINIRACK_INSTALL_DIR}/.env"
    warn "Please edit ${MINIRACK_INSTALL_DIR}/.env and set secure passwords."
  fi
}

# =============================================================================
# Verification
# =============================================================================

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

# =============================================================================
# Summary
# =============================================================================

show_summary() {
  echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "Docker installation completed successfully!"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

  echo -e "\n${YELLOW}Next Steps:${NC}"
  echo "1. Edit environment file: ${MINIRACK_INSTALL_DIR}/.env"
  echo "   ${YELLOW}IMPORTANT:${NC} Set secure passwords before deploying services."
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

# =============================================================================
# Main
# =============================================================================

main() {
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
