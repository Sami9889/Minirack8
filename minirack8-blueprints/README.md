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

```bash
git clone https://github.com/minirackhq/blueprints.git
cd blueprints
cp .env.example .env
# Edit .env and set required passwords
./scripts/deploy.sh --profile homelab
```

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
./scripts/deploy.sh --profile k3s-server

# Multi node
./scripts/deploy.sh --profile k3s-cluster

# Agent node
./scripts/deploy.sh --profile k3s-agent --server-ip 192.168.1.10
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
│   ├── docker-compose.yml
│   └── profiles/
│       ├── homelab.yml
│       ├── dev.yml
│       ├── networking.yml
│       ├── storage.yml
│       ├── monitoring.yml
│       └── full.yml
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
│   └── deploy.sh
├── docs/
│   └── SECURITY.md
├── .env.example
└── README.md
```

## License

MIT
