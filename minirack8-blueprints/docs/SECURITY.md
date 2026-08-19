# MiniRack8 Blueprints - Security Guide

## Overview

This guide covers security hardening for MiniRack8 blueprints in enterprise environments.

## Secrets Management

### Never Commit Secrets

All sensitive values are loaded from environment variables or a `.env` file.

```bash
# Copy the example and fill in your values
cp .env.example .env
# Edit .env with your secure passwords
```

### Generate Strong Passwords

```bash
# Generate a random 32-character password
openssl rand -base64 32

# Generate a random 16-character password
openssl rand -base64 16
```

### Required Secrets

| Variable | Description | Default |
|----------|-------------|---------|
| `PIHOLE_WEBPASSWORD` | Pi-hole admin password | **REQUIRED** |
| `MYSQL_PASSWORD` | Nextcloud database password | **REQUIRED** |
| `MYSQL_ROOT_PASSWORD` | MariaDB root password | **REQUIRED** |
| `MINIO_ROOT_USER` | MinIO root username | minioadmin |
| `MINIO_ROOT_PASSWORD` | MinIO root password | **REQUIRED** |
| `INFLUXDB_PASSWORD` | InfluxDB admin password | **REQUIRED** |
| `DRONE_GITEA_CLIENT_ID` | Drone OAuth client ID | - |
| `DRONE_GITEA_CLIENT_SECRET` | Drone OAuth client secret | - |
| `DRONE_RPC_SECRET` | Drone RPC secret | - |

## Network Segmentation

The blueprints use three isolated bridge networks:

| Network | Purpose | Internal |
|----------|---------|----------|
| `minirack-frontend` | User-facing services | No |
| `minirack-backend` | Databases and internal services | Yes |
| `minirack-monitor` | Metrics collection | No |

### Network Isolation Rules

- Backend databases (MariaDB) are on `minirack-backend` (internal network)
- Only services that need database access connect to `minirack-backend`
- Monitoring services are isolated on `minirack-monitor`
- Frontend services are on `minirack-frontend` with selective backend access

## Resource Limits

All services have CPU and memory limits defined:

```yaml
deploy:
  resources:
    limits:
      cpus: "1.0"
      memory: 512m
```

### Why This Matters

- Prevents a single service from consuming all host resources
- Ensures predictable performance across profiles
- Protects against denial-of-service from runaway containers

## Container Hardening

### Non-Root Users

LinuxServer.io images run as non-root users by default (PUID/PGID). For other images, add:

```yaml
user: "1000:1000"
```

### Read-Only Filesystems

Where possible, containers use read-only root filesystems:

```yaml
read_only: true
tmpfs:
  - /tmp
  - /var/run
```

### Security Options

```yaml
security_opt:
  - no-new-privileges:true
  - seccomp:default
```

## Health Checks

All services include health checks:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8080"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```

## Audit Logging

All deployment actions are logged to `logs/deploy-YYYYMMDD-HHMMSS.log`.

### Log Contents

- Timestamp
- User
- Hostname
- Deployed profile
- Success/failure status

### Centralized Logging

For enterprise deployments, ship logs to a central system:

```bash
# Example: Forward to ELK/Loki
./scripts/deploy.sh --profile monitoring
# Then configure Loki/Fluentd to collect from Promtail
```

## Backups

### Automated Backups

```bash
# Run backup script
./scripts/backup.sh

# Set retention period (default: 7 days)
RETENTION_DAYS=30 ./scripts/backup.sh

# Custom backup directory
BACKUP_DIR=/mnt/nfs/backups ./scripts/backup.sh
```

### Backup Contents

- Docker volumes (all `minirack-*` volumes)
- K3s cluster state (resources, configmaps, secrets, PVCs)
- Kubeconfig files

### Backup Schedule

```bash
# Add to crontab for daily backups at 2 AM
0 2 * * * /opt/minirack8/scripts/backup.sh
```

## K3s Security

### TLS Configuration

K3s is configured with:
- TLS certificate authentication
- Node name restrictions
- Kubeconfig permissions (600)

### Network Policies

Apply network policies to restrict pod-to-pod communication:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: minirack8
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### RBAC

Enable RBAC for K3s:

```bash
k3s server --disable=servicelb --write-kubeconfig-mode 600
```

## Compliance

### CIS Benchmarks

- [ ] Docker CIS Benchmark
- [ ] Kubernetes CIS Benchmark
- [ ] Ubuntu Server CIS Benchmark

### Audit Checklist

- [ ] All secrets stored in `.env` (not in git)
- [ ] `.env` is in `.gitignore`
- [ ] All services have resource limits
- [ ] All services have health checks
- [ ] Backups are scheduled and tested
- [ ] Network segmentation is configured
- [ ] Audit logs are centralized
- [ ] TLS is enabled for all external services
- [ ] Container images are scanned for vulnerabilities
- [ ] Security policies are enforced

## Incident Response

### If a Container is Compromised

1. Stop the container: `docker stop <container>`
2. Preserve logs: `docker logs <container> > incident-<container>.log`
3. Remove container: `docker rm <container>`
4. Scan image: `docker scan <image>`
5. Rotate secrets exposed in the container

### If a Host is Compromised

1. Isolate the host from the network
2. Preserve all logs in `logs/` directory
3. Restore from last known good backup
4. Rotate all credentials
5. Review K3s cluster for unauthorized access

## Reporting Security Issues

Report security vulnerabilities to: security@minirackhq.com
