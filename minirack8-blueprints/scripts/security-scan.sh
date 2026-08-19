#!/usr/bin/env bash
# =============================================================================
# MiniRack8 Security Scanner
# Scans blueprints for common security issues
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# =============================================================================
# Scan Functions
# =============================================================================

scan_hardcoded_secrets() {
  info "Scanning for hardcoded secrets..."

  local patterns=(
    'password.*=.*["'\'']?[a-zA-Z0-9]{1,8}["'\'']?'
    'PASSWORD.*=.*["'\'']?[a-zA-Z0-9]{1,8}["'\'']?'
    'SECRET.*=.*["'\'']?[a-zA-Z0-9]{1,8}["'\'']?'
    'API_KEY.*=.*["'\'']?[a-zA-Z0-9]{1,8}["'\'']?'
    'TOKEN.*=.*["'\'']?[a-zA-Z0-9]{1,8}["'\'']?'
  )

  local found=0
  for pattern in "${patterns[@]}"; do
    while IFS= read -r line; do
      warn "Potential hardcoded secret: ${line}"
      found=$((found + 1))
    done < <(grep -rn -E "${pattern}" "${REPO_DIR}" --include="*.sh" --include="*.yml" --include="*.yaml" --include="*.json" 2>/dev/null || true)
  done

  if [[ ${found} -eq 0 ]]; then
    info "No hardcoded secrets found."
  else
    warn "Found ${found} potential hardcoded secrets."
  fi
}

scan_command_injection() {
  info "Scanning for command injection risks..."

  local patterns=(
    '`[^`]*\$[^`]*`'
    '\$\([^)]*\$[^(]*\)'
    'eval.*\$'
    'exec.*\$'
    'ssh.*\$\(.*\)'
  )

  local found=0
  for pattern in "${patterns[@]}"; do
    while IFS= read -r line; do
      warn "Potential command injection: ${line}"
      found=$((found + 1))
    done < <(grep -rn -E "${pattern}" "${REPO_DIR}" --include="*.sh" 2>/dev/null || true)
  done

  if [[ ${found} -eq 0 ]]; then
    info "No obvious command injection patterns found."
  else
    warn "Found ${found} potential command injection patterns."
  fi
}

scan_unquoted_variables() {
  info "Scanning for unquoted variables..."

  local found=0
  while IFS= read -r line; do
    warn "Unquoted variable: ${line}"
    found=$((found + 1))
  done < <(grep -rn '\$[A-Za-z_][A-Za-z0-9_]*[^"'\'']' "${REPO_DIR}" --include="*.sh" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '"\$' | grep -v "'\$" || true)

  if [[ ${found} -eq 0 ]]; then
    info "No unquoted variables found."
  else
    warn "Found ${found} unquoted variables."
  fi
}

scan_missing_validation() {
  info "Scanning for missing input validation..."

  local found=0
  while IFS= read -r line; do
    warn "Missing validation: ${line}"
    found=$((found + 1))
  done < <(grep -rn 'read -r' "${REPO_DIR}" --include="*.sh" 2>/dev/null | grep -v 'validate_' || true)

  if [[ ${found} -eq 0 ]]; then
    info "All read statements appear to have validation."
  else
    warn "Found ${found} read statements without validation."
  fi
}

scan_missing_healthchecks() {
  info "Scanning Docker Compose for missing health checks..."

  local compose_file="${REPO_DIR}/docker-compose/docker-compose.yml"
  if [[ ! -f "${compose_file}" ]]; then
    warn "Docker Compose file not found."
    return 0
  fi

  local services
  services=$(grep -c 'healthcheck:' "${compose_file}" || true)

  local total_services
  total_services=$(grep -c 'container_name:' "${compose_file}" || true)

  if [[ ${services} -eq ${total_services} ]]; then
    info "All services have health checks."
  else
    warn "Missing health checks: ${services}/${total_services} services have health checks."
  fi
}

scan_missing_resource_limits() {
  info "Scanning Docker Compose for missing resource limits..."

  local compose_file="${REPO_DIR}/docker-compose/docker-compose.yml"
  if [[ ! -f "${compose_file}" ]]; then
    warn "Docker Compose file not found."
    return 0
  fi

  local services
  services=$(grep -c 'cpus:' "${compose_file}" || true)

  local total_services
  total_services=$(grep -c 'container_name:' "${compose_file}" || true)

  if [[ ${services} -eq ${total_services} ]]; then
    info "All services have CPU limits."
  else
    warn "Missing CPU limits: ${services}/${total_services} services have CPU limits."
  fi
}

scan_missing_network_segmentation() {
  info "Scanning for network segmentation..."

  local compose_file="${REPO_DIR}/docker-compose/docker-compose.yml"
  if [[ ! -f "${compose_file}" ]]; then
    warn "Docker Compose file not found."
    return 0
  fi

  local networks
  networks=$(grep -c 'minirack-' "${compose_file}" || true)

  if [[ ${networks} -ge 2 ]]; then
    info "Network segmentation detected (${networks} networks)."
  else
    warn "Insufficient network segmentation. Only ${networks} network(s) found."
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "MiniRack8 Security Scanner"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  echo ""

  scan_hardcoded_secrets
  echo ""
  scan_command_injection
  echo ""
  scan_unquoted_variables
  echo ""
  scan_missing_validation
  echo ""
  scan_missing_healthchecks
  echo ""
  scan_missing_resource_limits
  echo ""
  scan_missing_network_segmentation
  echo ""

  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  info "Security scan complete."
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
}

main "$@"
