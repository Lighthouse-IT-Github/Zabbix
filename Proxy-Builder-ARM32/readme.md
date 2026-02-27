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

### Step 4: Configure and Start Container

```routeros
# Create environment variables (CHANGE THESE VALUES!)
/container/envs
add name=zabbix key=ZBX_SERVER_HOST value="zabbix.yourcompany.com"
add name=zabbix key=ZBX_HOSTNAME value="rb4011-proxy"

# Create persistent storage for database
/container/mounts
add name=zabbix-data src=disk1/zabbix-data dst=/var/lib/zabbix

# Add the container (change filename to match your version)
/container/add file=zabbix-proxy-arm32-7.2.3.tar interface=veth-zabbix root-dir=disk1/zabbix-proxy envlist=zabbix mounts=zabbix-data hostname=rb4011-proxy logging=yes

# Start it
/container/start 0
```

### Step 5: Verify It's Running

```routeros
# Check container status
/container/print

# Should show "running" status
```

---

## Environment Variables

Set these in RouterOS under `/container/envs`:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ZBX_SERVER_HOST` | **YES** | - | Your Zabbix server address |
| `ZBX_HOSTNAME` | **YES** | - | Proxy name (must match Zabbix server config) |
| `ZBX_PROXYMODE` | No | `0` | `0` = Active, `1` = Passive |
| `ZBX_DEBUGLEVEL` | No | `3` | Log verbosity (0-5) |

---

## Troubleshooting

### Container won't start
```routeros
/log/print where topics~"container"
```

### Container starts but proxy won't connect
```routeros
# Get shell access to container
/container/shell 0

# Test DNS
nslookup zabbix.yourcompany.com

# Test connectivity to Zabbix server
nc -zv zabbix.yourcompany.com 10051

# Check proxy logs
cat /var/log/zabbix/zabbix_proxy.log
```

### "exited with status 127" error
This means a file is missing or corrupt. Rebuild the container image.

### Proxy shows in Zabbix but "never seen"
1. Check the hostname in RouterOS matches exactly what's configured in Zabbix server
2. Make sure your firewall allows outbound TCP 10051 from the container

---

## Supported Zabbix Versions

| Version | Type | Notes |
|---------|------|-------|
| 7.4.x | Current | Latest features |
| 7.2.x | Standard | |
| 7.0.x | **LTS** | Supported until 2029 |
| 6.0.x | **LTS** | Supported until 2027 |

⚠️ **Proxy version must match your Zabbix server version!**

---

## Firewall Rules (Optional)

If the proxy needs to poll agents on other networks:

```routeros
# Allow proxy to reach agents
/ip/firewall/filter/add chain=forward src-address=172.17.0.2 dst-port=10050 protocol=tcp action=accept
```

If using passive proxy mode (server connects to proxy):

```routeros
# Port forward to proxy
/ip/firewall/nat/add chain=dstnat dst-port=10051 protocol=tcp action=dst-nat to-addresses=172.17.0.2
```

---

## Need Help?

1. Check the [MikroTik Container Docs](https://help.mikrotik.com/docs/display/ROS/Container)
2. Check the [Zabbix Proxy Docs](https://www.zabbix.com/documentation/current/en/manual/distributed_monitoring/proxies)
