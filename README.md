# Proxmox USB host config backup
 Backs up Proxmox host configuration to a selected USB drive (temporary mount + structured folder layout).

 ## What it backs up
- `/etc/pve` (cluster config, VM/LXC configs, storage cfg, etc.)
- `/etc/network/interfaces`
- `/etc/fstab`
- basic host info (pveversion, uptime, disks)

## Run (recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/thatisfree/pve-usb-config-backup/main/pve-usb-backup.sh | sudo bash
