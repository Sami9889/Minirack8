# Provisioner Improvements

## Changes in this branch

- Renamed installer to **MiniRack8 Enterprise Provisioner**
- Added `--skip-os-check` flag for Alpine, CentOS, RHEL, and other non-Debian/Ubuntu distros
- Added `--force` flag to skip both OS and Docker installation checks
- Improved hardware detection output:
  - CPU model name
  - Core count
  - RAM in GB
  - Available storage
  - Primary IP address
  - Hardware summary block
- Better error messages that show the exact bypass command
- README updated with correct one-liner URL and bypass examples

## How to use on non-standard Linux

```bash
# Bypass OS check only
sudo bash install.sh --profile homelab --skip-os-check

# Skip OS + Docker checks entirely
sudo bash install.sh --profile homelab --force
```
