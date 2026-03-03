# Zabbix Proxy - Automated Hyper-V Deployment

Fully automated deployment of Zabbix Proxy virtual machines running Ubuntu Server on Windows Hyper-V. One script takes you from zero to a running, configured Zabbix Proxy in under 15 minutes with no manual intervention on the VM.

## Overview

`Deploy-ZabbixProxy.ps1` is an interactive PowerShell script that handles the entire provisioning pipeline:

1. Creates a Hyper-V Gen 2 VM with your specified configuration
2. Generates a cloud-init seed ISO for unattended Ubuntu Server installation
3. Boots the VM and Ubuntu installs hands-free via autoinstall
4. On first boot, a systemd oneshot service automatically installs and configures the Zabbix Proxy

The script prompts for all required parameters at runtime -- no config files to edit beforehand.

## What's in This Repo

| File | Description |
|------|-------------|
| `Deploy-ZabbixProxy.ps1` | Main deployment script (PowerShell) |
| `Verify-ZabbixProxy.sh` | Post-deployment health check script (Bash, runs on the VM) |
| `README.md` | This file |

## Prerequisites

### Required

- **Windows 10/11** with **Hyper-V enabled**
  - Enable via: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`
  - Requires a system reboot after enabling
- **Hyper-V virtual switch** already created (External or Internal type)
  - Create via Hyper-V Manager > Virtual Switch Manager, or:
    ```powershell
    New-VMSwitch -Name "External Switch" -NetAdapterName "Ethernet" -AllowManagementOS $true
    ```
- **Ubuntu Server ISO** (22.04 LTS or 24.04 LTS)
  - Download from [ubuntu.com/download/server](https://ubuntu.com/download/server)
  - The ISO must be the **live server** installer (autoinstall-capable)
- **Internet access** on the VM's network during first boot (to download Zabbix packages from `repo.zabbix.com`)

### Optional (Recommended)

- **Git for Windows** -- the bundled `openssl.exe` is used to hash the VM admin password into SHA-512 crypt format. If Git is not installed, the script falls back to Python, then to a `chpasswd` late-command. Everything works either way, but having Git or Python available produces a cleaner autoinstall config.
  - Download from [git-scm.com](https://git-scm.com/download/win)
- **Windows ADK** -- if installed, the script uses `oscdimg.exe` for ISO creation. Otherwise it falls back to the built-in Windows IMAPI2 COM API, which works fine on all Windows 10/11 systems.

## Quick Start

### 1. Open PowerShell as Administrator

Right-click the Start menu and select **Terminal (Admin)** or **Windows PowerShell (Admin)**.

### 2. Run the Script

```powershell
# Option A: Bypass execution policy for this run only
powershell -ExecutionPolicy Bypass -File ".\Deploy-ZabbixProxy.ps1"

# Option B: Set policy for the current session
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\Deploy-ZabbixProxy.ps1
```

If the script was downloaded from the internet, you may need to unblock it first: right-click the `.ps1` file in Explorer, go to Properties, and check **Unblock**.

### 3. Follow the Prompts

The script will ask for:

| Prompt | Description | Default |
|--------|-------------|---------|
| VM name | Name for the Hyper-V VM (e.g., `ZBPROXY-SITE01`) | *(required)* |
| Zabbix version | Version to install from the Zabbix repo | `7.4.7` |
| Zabbix Server address | IP or FQDN of your Zabbix Server or cluster | *(required)* |
| Proxy hostname | How this proxy appears in the Zabbix frontend | VM name |
| Network type | DHCP or Static IP configuration | `dhcp` |
| Virtual switch | Select from available Hyper-V switches | First available |
| Ubuntu ISO path | Full path to the Ubuntu Server ISO file | *(required)* |
| Admin username | Linux user account on the VM | `zadmin` |
| Admin password | Password for the admin account (entered securely) | *(required)* |
| TLS PSK | Whether to configure PSK encryption | `yes` |

### 4. Wait for Deployment

After the prompts, the script creates the VM at `C:\Lighthouse\ZBProxy\<VMName>\`, generates the cloud-init seed ISO, and starts the VM. Ubuntu installs automatically (5-15 minutes depending on hardware). After reboot, the Zabbix proxy installs and configures itself on first boot.

### 5. Verify the Deployment

Once the VM has an IP address:

```bash
ssh zadmin@<VM-IP> 'bash -s' < Verify-ZabbixProxy.sh
```

### 6. Add the Proxy in Zabbix

1. Log into your Zabbix Server frontend
2. Navigate to **Data Collection > Proxies** (Zabbix 7.x)
3. Click **Create proxy**
4. Set the **Proxy name** to match the hostname you entered during deployment
5. Set **Proxy mode** to **Active**
6. If you configured TLS PSK, enter the **PSK Identity** and **PSK Key** from the deployment summary

## VM Specifications

| Resource | Value |
|----------|-------|
| Generation | Gen 2 (UEFI) |
| vCPUs | 2 |
| RAM | 4 GB (Dynamic, 2-4 GB range) |
| Disk | 60 GB thin-provisioned VHDX |
| Secure Boot | Disabled (required for Ubuntu) |
| OS | Ubuntu Server 22.04 / 24.04 LTS |
| Checkpoints | Disabled |
| Auto Start | Enabled |

## Zabbix Proxy Configuration

The script configures the proxy with these tuning defaults:

| Parameter | Value | Description |
|-----------|-------|-------------|
| Database | SQLite | Lightweight, no external DB server needed |
| StartPollers | 10 | Number of data collection workers |
| StartPollersUnreachable | 5 | Workers for unreachable hosts |
| CacheSize | 64M | Configuration cache |
| HistoryCacheSize | 32M | History data cache |
| ConfigFrequency | 300s | How often to sync config from server |
| DataSenderFrequency | 5s | How often to send collected data to server |
| HeartbeatFrequency | 60s | Heartbeat interval to server |

These can be adjusted post-deployment by editing `/etc/zabbix/zabbix_proxy.conf` on the VM.

## TLS PSK Encryption

When enabled (default), the script:
- Generates a random 256-bit hex PSK key
- Creates `/etc/zabbix/zabbix_proxy.psk` with proper ownership and permissions (`640`)
- Configures `TLSConnect=psk` and `TLSAccept=psk` in the proxy config
- Displays the PSK key and identity during deployment and saves them to `deployment-info.txt`

**Important:** Save the PSK key displayed during deployment. You need it when adding the proxy in your Zabbix Server frontend.

## Deploying Multiple Proxies

Run the script once per proxy. Each deployment gets its own isolated folder:

```
C:\Lighthouse\ZBProxy\
    ZBPROXY-SITE01\
        ZBPROXY-SITE01.vhdx
        seed.iso
        deployment-info.txt
    ZBPROXY-SITE02\
        ZBPROXY-SITE02.vhdx
        seed.iso
        deployment-info.txt
```

Each `deployment-info.txt` contains the full deployment summary including PSK keys.

## File Locations on the VM

| Path | Contents |
|------|----------|
| `/etc/zabbix/zabbix_proxy.conf` | Proxy configuration |
| `/etc/zabbix/zabbix_proxy.conf.bak` | Backup of original config |
| `/var/lib/zabbix/zabbix_proxy.db` | SQLite database |
| `/etc/zabbix/zabbix_proxy.psk` | TLS PSK key file (if configured) |
| `/var/log/zabbix-proxy-setup.log` | First-boot setup log |
| `/var/log/zabbix/zabbix_proxy.log` | Runtime proxy log |
| `/opt/setup-zabbix-proxy.sh` | Setup script (runs once, then self-disables) |

## How It Works

### Seed ISO Generation

The script creates a small ISO image (`seed.iso`) containing cloud-init `user-data` and `meta-data` files. This ISO is attached as a secondary DVD drive to the VM. When Ubuntu boots from the primary install ISO, it detects the `CIDATA` volume and uses the autoinstall configuration for a fully unattended installation.

ISO creation uses `oscdimg.exe` (Windows ADK) if available, otherwise falls back to the Windows built-in IMAPI2 COM API with a C# helper class for proper IStream handling.

### Password Handling

The admin password is handled through a multi-layered approach:
1. **Primary:** The script attempts to generate a SHA-512 crypt hash using `openssl` (from Git for Windows) or Python's `crypt` module
2. **Guaranteed fallback:** A `chpasswd` command runs as a late-command during Ubuntu installation, setting the password from plain text regardless of whether the hash generation succeeded

### First-Boot Provisioning

A systemd oneshot service (`zabbix-proxy-setup.service`) runs after the first boot:
1. Detects the Ubuntu codename and version
2. Downloads and installs the Zabbix repository `.deb` package
3. Installs `zabbix-proxy-sqlite3`
4. Configures the proxy (server address, hostname, database path, performance tuning)
5. Sets up TLS PSK encryption if configured
6. Enables and starts the `zabbix-proxy` service
7. Disables itself so it does not run again on subsequent boots

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Script won't run (not digitally signed) | PowerShell execution policy | Run with `-ExecutionPolicy Bypass` or unblock the file |
| VM won't boot from ISO | Secure Boot enabled | Script disables this automatically; verify in VM settings |
| Ubuntu install hangs or shows manual prompts | Malformed autoinstall YAML | Check that the seed ISO was created successfully; re-run the script |
| Password doesn't work at login | Hash generation failed silently | The chpasswd fallback should handle this; check setup logs. Reset via recovery mode if needed |
| Zabbix proxy not installed after boot | No internet on first boot | VM needs internet access to reach repo.zabbix.com. Check DNS and routing |
| Zabbix repo download fails | Version/codename mismatch | Verify the version exists for your Ubuntu release at repo.zabbix.com |
| Proxy not connecting to server | Firewall blocking traffic | Proxy needs outbound TCP 10051 to the Zabbix Server |
| Seed ISO creation fails | IMAPI2 COM error | Install Windows ADK for oscdimg.exe as an alternative |

### Checking Logs

On the VM:

```bash
# First-boot setup log
cat /var/log/zabbix-proxy-setup.log

# Systemd service status
journalctl -u zabbix-proxy-setup.service

# Zabbix proxy runtime log
tail -50 /var/log/zabbix/zabbix_proxy.log

# Zabbix proxy service status
systemctl status zabbix-proxy
```

### Password Recovery

If you cannot log into the VM, reset the password via GRUB recovery:
1. In Hyper-V Manager, connect to the VM console
2. Reboot the VM and hold **Shift** during boot (or press **Esc** to reach GRUB)
3. Select **Advanced options for Ubuntu** then **Recovery mode**
4. Select **root - Drop to root shell prompt**
5. Run: `passwd <username>`
6. Reboot: `reboot`

## Network Requirements

| Direction | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| VM to Zabbix Server | 10051/TCP | Outbound | Proxy sends data and receives config |
| VM to Internet | 443/TCP | Outbound | Package downloads during setup (one-time) |
| Admin to VM | 22/TCP | Inbound | SSH management access |

## Customization

### Changing VM Specs

Edit these variables in the `Paths and Constants` section of the script:

```powershell
$RAMBytes      = 4GB       # Startup RAM
$VCPUCount     = 2         # Virtual CPUs
$DiskSizeBytes = 60GB      # Virtual disk size
```

Dynamic memory range is set in the `Set-VM` call:

```powershell
-MemoryMinimumBytes 2GB
-MemoryMaximumBytes 4GB
```

### Changing the Base Path

All VM files are stored under `C:\Lighthouse\ZBProxy` by default. Change this variable:

```powershell
$BasePath = "C:\Lighthouse\ZBProxy"
```

### Post-Deployment Zabbix Tuning

SSH into the VM and edit the proxy config:

```bash
sudo nano /etc/zabbix/zabbix_proxy.conf
sudo systemctl restart zabbix-proxy
```

## Tested On

- Windows 11 23H2 / 24H2 with Hyper-V
- Ubuntu Server 24.04.4 LTS
- Zabbix 7.4.x (SQLite backend)

## License

This project is provided as-is for internal use. Modify and distribute as needed for your environment.
