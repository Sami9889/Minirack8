#!/usr/bin/env bash
set -euo pipefail

PROXMOX_NODE="${PROXMOX_NODE:-pve}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
TEMPLATE_NAME="${TEMPLATE_NAME:-minirack8-ubuntu2204}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-4096}"
CORES="${CORES:-4}"
DISK_SIZE="${DISK_SIZE:-32G}"

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $*"; exit 1; }

[[ -z "${PM_API_URL:-}" ]] && fail "PM_API_URL is required."
[[ -z "${PM_API_TOKEN_ID:-}" ]] && fail "PM_API_TOKEN_ID is required."
[[ -z "${PM_API_TOKEN_SECRET:-}" ]] && fail "PM_API_TOKEN_SECRET is required."

info "Downloading Ubuntu 22.04 cloud image..."
curl -fsSL -o /tmp/ubuntu2204.img \
  "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

info "Creating VM ${TEMPLATE_VMID}..."
qm create "${TEMPLATE_VMID}" \
  --name "${TEMPLATE_NAME}" \
  --memory "${MEMORY}" \
  --cores "${CORES}" \
  --net0 virtio,bridge=${BRIDGE} \
  --scsihw virtio-scsi-pci \
  --ostype l26

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

info "Template ${TEMPLATE_NAME} (VMID: ${TEMPLATE_VMID}) created successfully."
rm -f /tmp/ubuntu2204.img
