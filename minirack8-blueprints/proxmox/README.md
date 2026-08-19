# MiniRack8 Proxmox Templates

Pre-built Proxmox VM templates for rapid provisioning on MiniRack8.

## Available Templates

| Template | VMID | OS | Purpose |
|----------|------|----|---------|
| `minirack8-ubuntu2204` | 9000 | Ubuntu 22.04 LTS | General purpose workloads |
| `minirack8-ubuntu2404` | 9001 | Ubuntu 24.04 LTS | Latest Ubuntu LTS |
| `minirack8-debian12` | 9002 | Debian 12 | Minimal base image |

## Usage

### Build a template from scratch

```bash
cd scripts
./build-template.sh
```

### Clone a template

```bash
cd scripts
export PM_API_URL="https://your-proxmox:8006/api2/json"
export PM_API_TOKEN_ID="user@pam!token"
export PM_API_TOKEN_SECRET="secret"
./clone-template.sh 100 minirack8-k3s-master
```

## Cloud-Init

All templates include cloud-init. Set the following for new VMs:

```bash
qm set <vmid> --ciuser minirack
qm set <vmid> --cipassword <password>
qm set <vmid> --ipconfig0 ip=dhcp
```
