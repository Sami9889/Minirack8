# MiniRack8 Blueprints

Permanent, production-ready blueprints for the MiniRack8.

## Hardware Reference

| Spec | Detail |
|------|--------|
| Form Factor | 10-inch rack, 8U |
| CPU | Intel i5-13500T (14 cores, 4.6GHz) |
| RAM | 16GB DDR4 |
| Storage | 256GB SSD (renewed Dell OptiPlex 7010) |
| Network | 12-port patch panel + managed switch |
| Power | 8-outlet PDU (125V/15A) |

## Quick Start

### One-Command Install

```bash
# Install Docker and deploy a profile in one step
# PCI-DSS inspired security: cryptographically secure passwords generated automatically
curl -fsSL https://raw.githubusercontent.com/Sami9889/Minirack8/main/minirack8-blueprints/install.sh | sudo bash -s -- --profile homelab
```

### Manual Installation

```bash
# 1. Clone the repository
git clone https://github.com/Sami9889/Minirack8.git
cd blueprints

# 2. Run installer
sudo bash install.sh --profile homelab
```

### Security Features

- Cryptographically secure passwords using `/dev/urandom`
- Password strength validation (16+ chars, mixed case, numbers, symbols)
- `.env` file permissions set to `600` (owner read/write only)
- PCI-DSS inspired password generation
- Audit logging for all password generation
- Auto-generated WireGuard key pairs
- No hardcoded passwords in repository

## Docker Compose Profiles

| Profile | Description | Min RAM |
|---------|-------------|---------|
| `homelab` | Plex, Jellyfin, Transmission, SABnzbd | 4GB |
| `dev` | Gitea, Drone CI, code-server | 6GB |
| `networking` | Pi-hole, WireGuard | 2GB |
| `storage` | Nextcloud, MariaDB, MinIO | 4GB |
| `monitoring` | Grafana, Prometheus, InfluxDB | 2GB |
| `full` | All services | 16GB |

## K3s Clusters

```bash
# Single node
sudo bash install.sh --profile k3s-server

# Multi node
sudo bash install.sh --profile k3s-cluster

# Agent node
sudo bash install.sh --profile k3s-agent --server-ip 192.168.1.10
```

## Proxmox Templates

Pre-built VM templates available in `proxmox/` for rapid provisioning.

## Security

All secrets are managed via environment variables. Never commit `.env` to version control.

See `docs/SECURITY.md` for hardening guidelines.

## Repository Structure

```
blueprints/
├── docker-compose/
│   └── docker-compose.yml
├── k3s/
│   ├── minirack8-single/
│   │   └── install.sh
│   └── minirack8-cluster/
│       ├── bootstrap.sh
│       └── server.sh
├── proxmox/
│   ├── scripts/
│   │   ├── build-template.sh
│   │   └── clone-template.sh
│   └── README.md
├── scripts/
│   ├── deploy.sh
│   ├── install-docker.sh
│   ├── backup.sh
│   └── security-scan.sh
├── docs/
│   └── SECURITY.md
├── .env.example
├── .gitignore
├── README.md
└── install.sh
```

## License

MIT
