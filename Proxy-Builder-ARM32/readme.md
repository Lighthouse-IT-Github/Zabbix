# Zabbix Proxy for MikroTik RB4011 (ARM32)

Build a Zabbix proxy container for RouterOS 7.x on MikroTik ARM32 devices.

---

## Quick Start

### Windows
1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
2. Start Docker Desktop and wait for it to fully load
3. Right-click `build.ps1` → **Run with PowerShell**
4. Enter the Zabbix version when prompted (e.g., `7.2.3`)

### macOS / Linux
```bash
# Install Docker Desktop (macOS) or Docker Engine (Linux) first
chmod +x build.sh
./build.sh
```
Enter the Zabbix version when prompted (e.g., `7.2.3`).

### Output
Build produces: `zabbix-proxy-arm32-<version>.tar` (~25-35MB)

---

## Deploy to MikroTik RB4011

### Step 1: Enable Containers in RouterOS

```routeros
/system/device-mode/update container=yes
```
⚠️ **Router will reboot.** Wait for it to come back online.

### Step 2: Create Network for Container

```routeros
# Create virtual interface for container
/interface/veth/add name=veth-zabbix address=172.17.0.2/24 gateway=172.17.0.1

# Create bridge and add veth to it
/interface/bridge/add name=br-containers
/interface/bridge/port/add bridge=br-containers interface=veth-zabbix

# Give the bridge an IP (this is the container's gateway)
/ip/address/add address=172.17.0.1/24 interface=br-containers

# Allow container to reach the internet
/ip/firewall/nat/add chain=srcnat src-address=172.17.0.0/24 action=masquerade
```

### Step 3: Upload the Container Image

**Option A: WinBox**
- Open WinBox and connect to your router
- Go to **Files** on the left menu
- Drag and drop `zabbix-proxy-arm32-<version>.tar` into the file list

**Option B: SCP (command line)**
```bash
scp zabbix-proxy-arm32-7.2.3.tar admin@192.168.88.1:/
```
