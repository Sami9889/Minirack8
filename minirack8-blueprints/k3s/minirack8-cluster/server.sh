#!/usr/bin/env bash
set -euo pipefail

MINIRACK_INSTALL_DIR="/var/lib/rancher/minirack8"
MINIRACK_K3S_VERSION="v1.28.0+k3s1"

mkdir -p "${MINIRACK_INSTALL_DIR}/etc"
mkdir -p "${MINIRACK_INSTALL_DIR}/manifests"

cat > "${MINIRACK_INSTALL_DIR}/etc/registries.yaml" << 'EOF'
configs:
  docker.io:
    auths: {}
  ghcr.io:
    auths: {}
EOF

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${MINIRACK_K3S_VERSION}" sh -s - server \
  --write-kubeconfig "${MINIRACK_INSTALL_DIR}/kubeconfig" \
  --write-kubeconfig-mode 600 \
  --disable traefik \
  --node-name minirack8-master

echo "K3s server installed. Kubeconfig: ${MINIRACK_INSTALL_DIR}/kubeconfig"
