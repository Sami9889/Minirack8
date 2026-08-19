#!/usr/bin/env bash
# =============================================================================
# MiniRack8 Backup Script
# Backs up Docker volumes and K3s cluster state
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
BACKUP_DIR="${BACKUP_DIR:-${REPO_DIR}/backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RETENTION_DAYS="${RETENTION_DAYS:-7}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# =============================================================================
# Backup Functions
# =============================================================================

backup_docker_volumes() {
  info "Backing up Docker volumes..."

  local backup_path="${BACKUP_DIR}/docker/${TIMESTAMP}"
  mkdir -p "${backup_path}"

  # List all volumes
  local volumes
  volumes=$(docker volume ls --format "{{.Name}}" | grep -E "^minirack-" || true)

  if [[ -z "${volumes}" ]]; then
    warn "No MiniRack8 Docker volumes found."
    return 0
  fi

  for volume in ${volumes}; do
    info "Backing up volume: ${volume}"
    docker run --rm \
      -v "${volume}:/source:ro" \
      -v "${backup_path}:/backup" \
      alpine tar czf "/backup/${volume}.tar.gz" -C /source .
  done

  info "Docker volumes backed up to: ${backup_path}"
}

backup_k3s() {
  info "Backing up K3s cluster..."

  local kubeconfig="${KUBECONFIG:-/var/lib/rancher/minirack8/kubeconfig}"

  if [[ ! -f "${kubeconfig}" ]]; then
    warn "Kubeconfig not found at ${kubeconfig}. Skipping K3s backup."
    return 0
  fi

  local backup_path="${BACKUP_DIR}/k3s/${TIMESTAMP}"
  mkdir -p "${backup_path}"

  # Export all resources
  kubectl --kubeconfig="${kubeconfig}" get all --all-namespaces -o yaml > "${backup_path}/all-resources.yaml"
  kubectl --kubeconfig="${kubeconfig}" get configmaps --all-namespaces -o yaml > "${backup_path}/configmaps.yaml"
  kubectl --kubeconfig="${kubeconfig}" get secrets --all-namespaces -o yaml > "${backup_path}/secrets.yaml"
  kubectl --kubeconfig="${kubeconfig}" get pvc --all-namespaces -o yaml > "${backup_path}/pvcs.yaml"

  # Backup kubeconfig
  cp "${kubeconfig}" "${backup_path}/kubeconfig"

  info "K3s cluster backed up to: ${backup_path}"
}

cleanup_old_backups() {
  info "Cleaning up backups older than ${RETENTION_DAYS} days..."

  find "${BACKUP_DIR}" -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
  find "${BACKUP_DIR}" -type d -empty -delete 2>/dev/null || true

  info "Old backups cleaned up."
}

# =============================================================================
# Main
# =============================================================================

main() {
  info "MiniRack8 Backup Script"
  info "Backup directory: ${BACKUP_DIR}"

  mkdir -p "${BACKUP_DIR}"

  backup_docker_volumes
  backup_k3s
  cleanup_old_backups

  echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "Backup completed successfully!"
  info "Backup location: ${BACKUP_DIR}/"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
}

main "$@"
