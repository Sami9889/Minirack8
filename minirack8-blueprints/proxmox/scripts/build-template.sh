#!/usr/bin/env bash
# =============================================================================
# MiniRack8 Proxmox Template Builder
# Builds Ubuntu 22.04 cloud-init template for MiniRack8
# =============================================================================

set -euo pipefail

# Configuration (override via environment variables)
PROXMOX_NODE="${PROXMOX_NODE:-pve}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
TEMPLATE_NAME="${TEMPLATE_NAME:-minirack8-ubuntu2204}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-4096}"
CORES="${CORES:-4}"
DISK_SIZE="${DISK_SIZE:-32G}"
UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"

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

# =============================================================================
# Main
# =============================================================================

main() {
  info "MiniRack8 Proxmox Template Builder"
  info "Template: ${TEMPLATE_NAME} (VMID: ${TEMPLATE_VMID})"

  # Validate required environment variables
  [[ -z "${PM_API_URL:-}" ]] && fail "PM_API_URL is required."
  [[ -z "${PM_API_TOKEN_ID:-}" ]] && fail "PM_API_TOKEN_ID is required."
  [[ -z "${PM_API_TOKEN_SECRET:-}" ]] && fail "PM_API_TOKEN_SECRET is required."

  # Validate numeric parameters
  validate_port "${MEMORY}"
  validate_port "${CORES}"

  # Validate disk size format
  if ! [[ "${DISK_SIZE}" =~ ^[0-9]+[GM]$ ]]; then
    fail "Invalid disk size format: ${DISK_SIZE}. Must end with G or M."
  fi

  info "Downloading Ubuntu ${UBUNTU_VERSION} cloud image..."
  local image_url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  curl -fsSL -o /tmp/ubuntu2204.img "${image_url}"

  # Verify image was downloaded
  if [[ ! -f /tmp/ubuntu2204.img ]]; then
    fail "Failed to download Ubuntu cloud image."
  fi

  local image_size
  image_size=$(stat -f%z /tmp/ubuntu2204.img 2>/dev/null || stat -c%s /tmp/ubuntu2204.img)
  info "Image downloaded: ${image_size} bytes"

  info "Creating VM ${TEMPLATE_VMID}..."
  qm create "${TEMPLATE_VMID}" \
    --name "${TEMPLATE_NAME}" \
    --memory "${MEMORY}" \
    --cores "${CORES}" \
    --net0 virtio,bridge=${BRIDGE} \
    --scsihw virtio-scsi-pci \
    --ostype l26 \
    --agent 1

  info "Importing disk to ${PROXMOX_STORAGE}..."
  qm importdisk "${TEMPLATE_VMID}" /tmp/ubuntu2204.img "${PROXMOX_STORAGE}"

  info "Attaching disk to VM..."
  qm set "${TEMPLATE_VMID}" --scsi0 "${PROXMOX_STORAGE}:vm-${TEMPLATE_VMID}-disk-0"
  qm set "${TEMPLATE_VMID}" --boot order=scsi0

  info "Adding cloud-init drive..."
  qm set "${TEMPLATE_VMID}" --ide2 "${PROXMOX_STORAGE}:cloudinit"

  info "Configuring cloud-init..."
  qm set "${TEMPLATE_VMID}" --ipconfig0 ip=dhcp
  qm set "${TEMPLATE_VMID}" --ciuser minirack
  qm set "${TEMPLATE_VMID}" --cipassword "$(openssl rand -base64 12)"

  info "Resizing disk to ${DISK_SIZE}..."
  qm resize "${TEMPLATE_VMID}" scsi0 "${DISK_SIZE}"

  info "Converting to template..."
  qm template "${TEMPLATE_VMID}"

  # Clean up
  rm -f /tmp/ubuntu2204.img

  info "Template ${TEMPLATE_NAME} (VMID: ${TEMPLATE_VMID}) created successfully."
  info "Next steps:"
  info "  1. Clone template: qm clone ${TEMPLATE_VMID} <new-vmid> --name <vm-name>"
  info "  2. Configure cloud-init: qm set <new-vmid> --cipassword <password>"
  info "  3. Start VM: qm start <new-vmid>"
}

main "$@"
