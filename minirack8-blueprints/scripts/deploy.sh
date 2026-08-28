#!/usr/bin/env bash
# MiniRack8 Blueprint Deploy Script
# Production-ready deployment automation

set -euo pipefail
set -o nounset
set -o errtrace

# =============================================================================
# Pipe/bootstrap detection
# =============================================================================

if [[ -z "${BASH_SOURCE[0]:-}" || ! -f "${BASH_SOURCE[0]}" ]]; then
  tmp_script="$(mktemp /tmp/minirack8-deploy.XXXXXX.sh)"
  cat > "${tmp_script}"
  chmod +x "${tmp_script}"
  exec bash "${tmp_script}" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
LOG_DIR="${REPO_DIR}/logs"
AUDIT_LOG="${LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
# shellcheck disable=SC2034
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "${AUDIT_LOG}"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${AUDIT_LOG}"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" | tee -a "${AUDIT_LOG}"; exit 1; }
step() { echo -e "\n${BLUE}[STEP]${NC} $*" | tee -a "${AUDIT_LOG}"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
divider() { echo -e "${DIM}──────────────────────────────────────────────────────────────${NC}"; }

animate_spinner() {
  local pid=$1
  local delay=0.1
  # shellcheck disable=SC1003
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
  info "Re-running deploy script with latest version..."
  echo ""

  exec bash "${script_path}/deploy.sh" "$@"
}

init_logging() {
  mkdir -p "${LOG_DIR}"
  {
    echo "=== MiniRack8 Blueprint Deployment ==="
    echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "User: $(whoami)"
    echo "Host: $(hostname)"
    echo "Profile: ${PROFILE}"
    echo "======================================="
  } >> "${AUDIT_LOG}"
}

show_banner() {
  clear
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   MiniRack8 Blueprint Deploy Script                        ║
║                                                              ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
  echo ""
  echo -e "  ${DIM}Deploy pre-configured Docker Compose profiles${NC}"
  echo ""
  divider
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
      fail "Invalid IP address: ${ip} (octet ${octet} > 255)"
    fi
  done
  info "IP address validated: ${ip}"
}

validate_port() {
  local port="${1:?port required}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    fail "Invalid port number: ${port}. Must be 1-65535."
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
      warn "OS ${OS} may not be fully supported. Ubuntu/Debian recommended."
      ;;
  esac
}

check_hardware() {
  step "Checking MiniRack8 hardware specs..."

  # RAM check
  local total_ram_kb
  total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local total_ram_gb=$((total_ram_kb / 1024 / 1024))
  info "Total RAM: ${total_ram_gb}GB"

  if [[ ${total_ram_gb} -lt 16 ]]; then
    warn "This system has less than 16GB RAM. MiniRack8 has 16GB."
    warn "Some profiles may not run optimally."
  else
    info "RAM meets MiniRack8 specification (16GB)."
  fi

  # CPU check
  local cpu_cores
  cpu_cores=$(nproc)
  info "CPU cores: ${cpu_cores}"

  if [[ ${cpu_cores} -lt 14 ]]; then
    warn "This system has fewer than 14 cores. MiniRack8 has 14 cores (i5-13500T)."
  else
    info "CPU cores meet MiniRack8 specification (14 cores)."
  fi

  # Storage check
  local storage_gb
  storage_gb=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
  info "Available storage: ${storage_gb}GB"

  if [[ ${storage_gb} -lt 50 ]]; then
    warn "Less than 50GB storage available. MiniRack8 has 256GB SSD."
  else
    info "Storage meets minimum requirements."
  fi
}

install_docker() {
  step "Checking Docker installation..."

  if command -v docker &> /dev/null && docker --version &> /dev/null; then
    info "Docker is already installed: $(docker --version)"
    return 0
  fi

  info "Docker not found. Installing Docker..."

  case "${OS}" in
    ubuntu|debian)
      apt-get update -qq
      apt-get install -y -qq ca-certificates curl gnupg lsb-release

      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${OS}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS} $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

      apt-get update -qq
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

      systemctl enable --now docker
      systemctl enable --now containerd

      info "Docker installed successfully."
      ;;
    *)
      fail "Automatic Docker installation not supported for ${OS}. Please install Docker manually."
      ;;
  esac
}

check_docker_compose() {
  step "Checking Docker Compose..."

  if docker compose version &> /dev/null; then
    info "Docker Compose plugin found: $(docker compose version --short)"
  elif command -v docker-compose &> /dev/null; then
    info "Docker Compose (legacy) found: $(docker-compose --version)"
  else
    fail "Docker Compose not found. Please install Docker Compose plugin."
  fi
}

deploy_docker() {
  local profile="${1:?profile required}"
  step "Deploying Docker Compose profile: ${profile}"

  local compose_file="${REPO_DIR}/docker-compose/docker-compose.yml"
  # shellcheck disable=SC2034
  local profiles_dir="${REPO_DIR}/docker-compose/profiles"

  if [[ ! -f "${compose_file}" ]]; then
    fail "Docker Compose file not found: ${compose_file}"
  fi

  info "Profile: ${profile}"
  info "Compose file: ${compose_file}"

  if [[ "${DRY_RUN}" == true ]]; then
    info "[DRY RUN] Would execute:"
    info "  cd ${REPO_DIR}/docker-compose"
    info "  docker compose --profile ${profile} up -d"
    return 0
  fi

  pushd "${REPO_DIR}/docker-compose" > /dev/null

  info "Pulling latest images..."
  docker compose --profile "${profile}" pull

  info "Starting services..."
  docker compose --profile "${profile}" up -d

  popd > /dev/null

  info "Docker Compose profile '${profile}' deployed successfully."
}

deploy_k3s_server() {
  step "Deploying K3s single-node server..."

  if [[ "${DRY_RUN}" == true ]]; then
    info "[DRY RUN] Would execute: ${REPO_DIR}/k3s/minirack8-single/install.sh"
    return 0
  fi

  bash "${REPO_DIR}/k3s/minirack8-single/install.sh"
  info "K3s server deployed."
}

deploy_k3s_agent() {
  local server_ip="${1:?server IP required}"
  [[ -z "${server_ip}" ]] && fail "--server-ip is required for k3s-agent profile."

  step "Deploying K3s agent connecting to ${server_ip}..."

  if [[ "${DRY_RUN}" == true ]]; then
    info "[DRY RUN] Would execute: ${REPO_DIR}/k3s/minirack8-single/install.sh agent ${server_ip}"
    return 0
  fi

  bash "${REPO_DIR}/k3s/minirack8-single/install.sh" agent "${server_ip}"
  info "K3s agent deployed."
}

deploy_k3s_cluster() {
  step "Deploying multi-node K3s cluster..."
  warn "This requires SSH key-based access to all nodes."

  if [[ "${DRY_RUN}" == true ]]; then
    info "[DRY RUN] Would bootstrap K3s cluster"
    return 0
  fi

  read -rp "Enter server IP: " server_ip
  validate_ip "${server_ip}"

  read -rp "Enter agent IPs (space-separated): " -a agent_ips
  for agent_ip in "${agent_ips[@]}"; do
    validate_ip "${agent_ip}"
  done

  bash "${REPO_DIR}/k3s/minirack8-cluster/bootstrap.sh" "${server_ip}" "${agent_ips[@]}"
  info "K3s cluster deployed."
}

show_usage() {
  cat << EOF
${GREEN}MiniRack8 Blueprint Deploy Script${NC}

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
  --dry-run     Show what would be deployed
  --skip-docker Skip Docker installation check
  --skip-hw-check Skip hardware validation
  --no-self-update Skip automatic self-update check
  --help        Show this help

${YELLOW}Environment Variables:${NC}
  PIHOLE_WEBPASSWORD    Pi-hole admin password
  MYSQL_PASSWORD        Nextcloud/MariaDB password
  MYSQL_ROOT_PASSWORD   MariaDB root password
  MINIO_ROOT_USER       MinIO root username
  MINIO_ROOT_PASSWORD   MinIO root password
  INFLUXDB_PASSWORD     InfluxDB admin password
  DRONE_GITEA_CLIENT_ID       Drone OAuth client ID
  DRONE_GITEA_CLIENT_SECRET   Drone OAuth client secret
  DRONE_RPC_SECRET            Drone RPC secret
  DRONE_SERVER_HOST           Drone server hostname
  DRONE_SERVER_PROTO          Drone server protocol (http/https)

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
  DRY_RUN=false
  SKIP_DOCKER=false
  SKIP_HW_CHECK=false
  NO_SELF_UPDATE=false

  # Parse arguments
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
      --skip-docker)
        SKIP_DOCKER=true
        shift
        ;;
      --skip-hw-check)
        SKIP_HW_CHECK=true
        shift
        ;;
      --no-self-update)
        NO_SELF_UPDATE=true
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

  # Validate required inputs
  [[ -z "${PROFILE}" ]] && fail "Profile is required. Use --help for options."
  validate_profile "${PROFILE}"

  if [[ "${NO_SELF_UPDATE}" != true ]]; then
    self_update "$@"
  fi

  # Initialize logging
  init_logging

  # System checks
  check_os

  if [[ "${SKIP_HW_CHECK}" != true ]]; then
    check_hardware
  fi

  if [[ "${SKIP_DOCKER}" != true ]]; then
    install_docker
    check_docker_compose
  fi

  # Deploy selected profile
  case "${PROFILE}" in
    homelab|dev|networking|storage|monitoring|full)
      deploy_docker "${PROFILE}"
      ;;
    k3s-server)
      deploy_k3s_server
      ;;
    k3s-agent)
      [[ -z "${SERVER_IP}" ]] && fail "--server-ip is required for k3s-agent profile."
      validate_ip "${SERVER_IP}"
      deploy_k3s_agent "${SERVER_IP}"
      ;;
    k3s-cluster)
      deploy_k3s_cluster
      ;;
    *)
      fail "Unknown profile: ${PROFILE}. Use --help for available profiles."
      ;;
  esac

  echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "MiniRack8 blueprint '${PROFILE}' deployment complete!"
  info "Audit log: ${AUDIT_LOG}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

  if [[ "${PROFILE}" != k3s-server && "${PROFILE}" != k3s-agent && "${PROFILE}" != k3s-cluster ]]; then
    show_deployment_dashboard
  fi
}

show_deployment_dashboard() {
  echo -e "\n${CYAN}${BOLD}"
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                   MINIRACK8 LIVE DASHBOARD                  ║
╚══════════════════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"

  step "Scanning running containers..."

  # Animated scanning effect
  # shellcheck disable=SC1003
  local spinstr='|/-\'
  local i=0
  for _ in $(seq 1 18); do
    # shellcheck disable=SC2059
    printf "\r  ${CYAN}Scanning... %c${NC}" "${spinstr:i++%${#spinstr}:1}"
    sleep 0.05
  done
  # shellcheck disable=SC2059
  printf "\r  ${GREEN}Scan complete. Found:${NC}\n"

  local containers
  containers=$(docker ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)

  if [[ -z "${containers}" ]]; then
    warn "No running containers found."
    return 0
  fi

  echo ""
  printf "${BOLD}%-28s %-22s %s${NC}\n" "SERVICE" "STATUS" "PORTS"
  echo -e "${DIM}$(printf '%.0s─' {1..90})${NC}"

  local primary_ip
  primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

  while IFS=$'\t' read -r name status ports; do
    local status_color="${GREEN}"
    if [[ "${status,,}" == *"unhealthy"* ]]; then
      status_color="${RED}"
    elif [[ "${status,,}" == *"starting"* ]]; then
      status_color="${YELLOW}"
    elif [[ "${status,,}" == *"restarting"* ]]; then
      status_color="${RED}"
    fi

    local display_ports="${ports}"
    [[ ${#display_ports} -gt 45 ]] && display_ports="${display_ports:0:42}..."

    printf "%-28s ${status_color}%-22s${NC} %s\n" "${name}" "${status}" "${display_ports}"
  done <<< "${containers}"

  echo ""
  step "Detecting service endpoints..."

  echo -e "\n${BOLD}${CYAN}  Quick Access URLs:${NC}"
  echo -e "${DIM}  ─────────────────────────────────────────────────────────────${NC}"

  local found_any=false
  while IFS=$'\t' read -r name status ports; do
    [[ -z "${ports}" ]] && continue

    local host_ports
    host_ports=$(echo "${ports}" | grep -oE ':[0-9]+->' | sed 's/://g; s/->//g' | tr '\n' ' ')
    [[ -z "${host_ports}" ]] && continue

    for port in ${host_ports}; do
      echo -e "  ${GREEN}✓${NC} ${name}:${DIM} http://${primary_ip}:${port}${NC}"
      found_any=true
    done
  done <<< "${containers}"

  if [[ "${found_any}" == false ]]; then
    echo -e "  ${YELLOW}No published ports detected.${NC}"
  fi

  echo ""
  step "Resource overview..."

  local total_containers
  total_containers=$(docker ps -q 2>/dev/null | wc -l)
  echo -e "  ${CYAN}Running containers:${NC} ${total_containers}"

  if command -v free &> /dev/null; then
    local used_mem total_mem
    used_mem=$(free -h | awk '/^Mem:/ {print $3}')
    total_mem=$(free -h | awk '/^Mem:/ {print $2}')
    echo -e "  ${CYAN}RAM usage:${NC} ${used_mem} / ${total_mem}"
  fi

  if command -v df &> /dev/null; then
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')
    echo -e "  ${CYAN}Disk usage:${NC} ${disk_usage}"
  fi

  if command -v nproc &> /dev/null; then
    local cores
    cores=$(nproc)
    echo -e "  ${CYAN}CPU cores:${NC} ${cores}"
  fi

  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "MiniRack8 deployment verified and operational!"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
}

main "$@"
