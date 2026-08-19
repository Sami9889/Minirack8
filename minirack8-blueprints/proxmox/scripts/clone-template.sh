#!/usr/bin/env bash
set -euo pipefail

PROXMOX_NODE="${PROXMOX_NODE:-pve}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
NEW_VMID="${1:?new vmid required}"
NEW_NAME="${2:-minirack8-vm}"

info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $*"; exit 1; }

[[ -z "${PM_API_URL:-}" ]] && fail "PM_API_URL is required."
[[ -z "${PM_API_TOKEN_ID:-}" ]] && fail "PM_API_TOKEN_ID is required."
[[ -z "${PM_API_TOKEN_SECRET:-}" ]] && fail "PM_API_TOKEN_SECRET is required."

info "Cloning template ${TEMPLATE_VMID} to ${NEW_VMID}..."
qm clone "${TEMPLATE_VMID}" "${NEW_VMID}" --name "${NEW_NAME}"

info "Starting VM ${NEW_VMID}..."
qm start "${NEW_VMID}"

info "Waiting for cloud-init..."
sleep 30

info "VM ${NEW_NAME} (VMID: ${NEW_VMID}) provisioned."
