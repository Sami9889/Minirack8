# MiniRack8 Blueprints — Collaborator Environment Setup

Use this document to reproduce the exact working environment, install the stack, and deploy a profile on a fresh machine.

<environment_details>
Current time: 2026-08-27T06:04:36+00:00
Working directory: /workspace/1254b264-94a7-4c61-a6f4-5348c476bcdc/sessions/agent_d8d21008-f9b2-4ada-ad45-d27c932a1c10
Workspace root folder: /workspace/1254b264-94a7-4c61-a6f4-5348c476bcdc/sessions/agent_d8d21008-f9b2-4ada-ad45-d27c932a1c10
</environment_details>

---

## 1. Target System Requirements

| Resource | Minimum | Recommended |
| --- | --- | --- |
| OS | Ubuntu 22.04 / Debian 12 | Ubuntu 22.04 LTS |
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 16 GB |
| Storage | 20 GB free | 100+ GB SSD |
| Network | 1 GbE | 1 GbE+ with static IP preferred |

---

## 2. One-Command Install

Run this from the target machine:

```bash
curl -fsSL https://raw.githubusercontent.com/Sami9889/Minirack8/main/minirack8-blueprints/install.sh | sudo bash -s -- --profile homelab
```

Optional flags:

```bash
# Bypass OS validation on non-standard distros
curl -fsSL https://raw.githubusercontent.com/Sami9889/Minirack8/main/minirack8-blueprints/install.sh | sudo bash -s -- --profile homelab --skip-os-check

# Skip OS and Docker checks entirely
curl -fsSL https://raw.githubusercontent.com/Sami9889/Minirack8/main/minirack8-blueprints/install.sh | sudo bash -s -- --profile homelab --force
```

---

## 3. Manual Clone Install

```bash
git clone https://github.com/Sami9889/Minirack8.git
cd minirack8-blueprints
sudo bash install.sh --profile homelab
```

---

## 4. Available Profiles

| Profile | Services | Min RAM |
| --- | --- | --- |
| `homelab` | Plex, Jellyfin, Transmission, SABnzbd | 4 GB |
| `dev` | Gitea, Drone CI, code-server | 6 GB |
| `networking` | Pi-hole, WireGuard | 2 GB |
| `storage` | Nextcloud, MariaDB, MinIO | 4 GB |
| `monitoring` | Grafana, Prometheus, InfluxDB | 2 GB |
| `full` | All services | 16 GB |
| `k3s-server` | K3s single-node control plane | 4 GB |
| `k3s-agent` | K3s agent joining a server | 2 GB |
| `k3s-cluster` | Multi-node K3s bootstrap | 8 GB+ |

---

## 5. Security Notes

- All passwords are auto-generated with `/dev/urandom`.
- The generated `.env` file is created with `chmod 600`.
- Audit logs are written under `/opt/minirack8/logs/`.
- Never commit `.env` to version control.

---

## 6. Post-Install Access

After install, services are reachable at the detected primary IP on their published ports. Use `docker compose ps` inside `/opt/minirack8/docker-compose` to verify running containers.

---

## 7. Useful Commands

```bash
# View logs
cd /opt/minirack8/docker-compose && docker compose logs -f

# Stop stack
cd /opt/minirack8/docker-compose && docker compose down

# Backup
sudo /opt/minirack8/scripts/backup.sh

# Security scan
sudo /opt/minirack8/scripts/security-scan.sh
```

---

## 8. Repo Structure

```
minirack8-blueprints/
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
├── PROVISIONER.md
└── install.sh
```

---

## 9. Troubleshooting

- If OS validation fails on non-Debian/Ubuntu, use `--skip-os-check`.
- If Docker installation should be skipped, use `--skip-docker`.
- If the script is already up to date but re-run fails, check `/opt/minirack8/logs/` and rerun with `--force`.

---

## 10. Support

For issues, review `docs/SECURITY.md` and `PROVISIONER.md` in this repository.
