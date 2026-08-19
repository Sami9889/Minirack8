#!/usr/bin/env bash
# =============================================================================
# MiniRack8 Proxmox Template Cloner
# Clones a Proxmox template and provisions a new VM
# =============================================================================

set -euo pipefail

# Configuration (override via environment variables)
PROXMOX_NODE="${PROXMOX_NODE:-pve}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
NEW_VMID="${1:?new vmid required}"
NEW_NAME="${2:-minirack8-vm}"
MEMORY="${MEMORY:-4096}"
CORES="${CORES:-4}"

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $*"; exit 1; }

# =============================================================================
# Validation
# =============================================================================

validate_port() {
  local port="$1"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    fail "Invalid port number: ${port}. Must be 1-65535."
  fi
}

validate_vmid() {
  local vmid="$1"
  if ! [[ "${vmid}" =~ ^[0-9]+$ ]]; then
    fail "Invalid VMID: ${vmid}. Must be numeric."
  fi
  if (( vmid < 100 || vmid > 999999999 )); then
    fail "VMID out of range: ${vmid}. Must be 100-999999999."
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  info "MiniRack8 Proxmox Template Cloner"
  info "Template VMID: ${TEMPLATE_VMID}"
  info "New VMID: ${NEW_VMID}"
  info "New Name: ${NEW_NAME}"

  # Validate required environment variables
  [[ -z "${PM_API_URL:-}" ]] && fail "PM_API_URL is required."
  [[ -z "${PM_API_TOKEN_ID:-}" ]] && fail "PM_API_TOKEN_ID is required."
  [[ -z "${PM_API_TOKEN_SECRET:-}" ]] && fail "PM_API_TOKEN_SECRET is required."

  # Validate inputs
  validate_vmid "${NEW_VMID}"

  # Sanitize VM name
  NEW_NAME=$(echo "${NEW_NAME}" | tr -cd '[:alnum:]-_')
  if [[ -z "${NEW_NAME}" ]]; then
    fail "Invalid VM name: ${NEW_NAME}. Must contain only alphanumeric, dash, underscore."
  fi

  validate_port "${MEMORY}"
  validate_port "${CORES}"

  info "Cloning template ${TEMPLATE_VMID} to ${NEW_VMID}..."
  qm clone "${TEMPLATE_VMID}" "${NEW_VMID}" --name "${NEW_NAME}"

  info "Configuring VM resources..."
  qm set "${NEW_VMID}" --memory "${MEMORY}" --cores "${CORES}"

  info "Starting VM ${NEW_VMID}..."
  qm start "${NEW_VMID}"

  info "Waiting for cloud-init to complete..."
  local max_attempts=30
  local attempt=0
  while [[ ${attempt} -lt ${max_attempts} ]]; do
    if qm guest cmd "${NEW_VMID}" info get-status &> /dev/null; then
      info "VM is running."
      break
    fi
    attempt=$((attempt + 1))
    sleep 5
  done

  if [[ ${attempt} -eq ${max_attempts} ]]; then
    warn "Cloud-init may still be running. Check VM console for status."
  fi

  info "VM ${NEW_NAME} (VMID: ${NEW_VMID}) provisioned successfully."
  info "Access via: ssh minirack@$(qm guest get ipconfig ${NEW_VMID} 2>/dev/null || echo '<check-proxmox-console>')"
}

main "$@"
