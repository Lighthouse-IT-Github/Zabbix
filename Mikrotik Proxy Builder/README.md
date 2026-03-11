# Zabbix Proxy for MikroTik RouterOS (ARM32 + ARM64)

Self-updating Zabbix Proxy containers for MikroTik RouterOS 7.x on ARM devices.

| Architecture | Platform | Devices |
|---|---|---|
| ARM32 (armv7) | `linux/arm/v7` | RB4011 |
| ARM64 (aarch64) | `linux/arm64` | RB5009, CCR2004, CCR2116 |

Pre-compiled binaries are served from an internal IIS server. Containers check a GitHub-hosted version file on a schedule and automatically download and install new binaries when a version change is detected. Each container auto-detects its architecture and downloads the correct binary.

---

## Architecture

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  UPDATE FLOW                                                            │
 │                                                                         │
 │   ┌────────────────────┐       1. version check        ┌─────────────┐ │
 │   │ GitHub             │  <──────────────────────────── │  MikroTik   │ │
 │   │ (zblive file)      │                                │  Container  │ │
 │   │ contains: "7.2.4"  │   2. if version != installed   │  (Alpine)   │ │
 │   └────────────────────┘                                │             │ │
 │                                                         │  detects    │ │
 │   ┌────────────────────┐       download matching binary │  arch:      │ │
 │   │ IIS Server         │  <──────────────────────────── │  ARM32 or   │ │
 │   │ /Zabbix/           │                                │  ARM64      │ │
 │   │ zabbix_proxy.bin       (ARM32)                      │             │ │
 │   │ zabbix_proxy_arm64.bin (ARM64)                      │  3. replace │ │
 │   │                    │  ────────────────────────────>  │  4. restart │ │
 │   └────────────────────┘                                └─────────────┘ │
 │                                                                         │
 └──────────────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────────────────────────────────────────────────────┐
 │  COMPILE FLOW                                                           │
 │                                                                         │
 │   ┌────────────────────┐                                                │
 │   │ Windows Machine    │   Compile-ZabbixProxy.ps1                      │
 │   │ (Docker Desktop)   │                                                │
 │   │                    │   1. Prompt for version                        │
 │   │                    │   2. Cross-compile ARM32 + ARM64 via buildx    │
 │   │                    │   3. Output to C:\Firmware\Zabbix\             │
 │   │                    │      zabbix_proxy.bin       (ARM32)            │
 │   │                    │      zabbix_proxy_arm64.bin (ARM64)            │
 │   │                    │      (IIS serves this directory)               │
 │   └────────────────────┘                                                │
 │                                                                         │
 │   After compiling, update the GitHub zblive file to trigger rollout.    │
 │                                                                         │
 └──────────────────────────────────────────────────────────────────────────┘
```

### How an update rolls out

1. Run `Compile-ZabbixProxy.ps1` on the Windows build machine — compiles both ARM32 and ARM64
2. Binaries are placed at `C:\Firmware\Zabbix\` (served by IIS)
3. Update the `zblive` file on GitHub to the new version number
4. Within 30 minutes, all containers detect the version mismatch
5. Each container downloads the binary matching its architecture
6. Binary is replaced in-place and the proxy process restarts automatically

---

## Part 1: Containers (MikroTik)

Both ARM32 and ARM64 containers are built from the same Dockerfile. The architecture is determined by the `--platform` flag at build time. At runtime, the update script auto-detects the architecture and downloads the correct binary.

### Prerequisites

- Docker Desktop (Windows/macOS) or Docker Engine (Linux) with buildx support

### Build Both Container Images

**Windows (PowerShell):**
```powershell
.\build.ps1
```

**Linux / macOS:**
```bash
chmod +x build.sh
./build.sh
```

Enter the Zabbix version when prompted. Both images are built in sequence:

| Output File | Architecture | Devices |
|---|---|---|
| `zabbix-proxy-arm32-<version>.tar` | ARM32 (armv7) | RB4011 |
| `zabbix-proxy-arm64-<version>.tar` | ARM64 (aarch64) | RB5009, CCR2004, CCR2116 |



### Container Features

| Feature | Status | Details |
|---|---|---|
| SSH | Always on | Port 22, root login |
| Auto-update | Always on | Every 30 min (configurable) |
| Arch detection | Automatic | Downloads correct binary for ARM32/ARM64 |
| Package manager | `apk` | Alpine Linux |
| Supervised proxy | Entrypoint loop | Auto-restart on crash or update |

### Environment Variables

#### Zabbix Proxy Settings

| Variable | Description | Default |
|---|---|---|
| `ZBX_SERVER_HOST` | Zabbix server address | *(required)* |
| `ZBX_HOSTNAME` | Unique proxy hostname | container hostname |
| `ZBX_PROXYMODE` | `0` = Active, `1` = Passive | `0` |
| `ZBX_LISTENPORT` | Listen port | `10051` |
| `ZBX_DEBUGLEVEL` | Log verbosity (0-5) | `3` |
| `ZBX_CACHESIZE` | Cache size | `8M` |
| `ZBX_HISTORYCACHESIZE` | History cache size | `16M` |
| `ZBX_HISTORYINDEXCACHESIZE` | History index cache | `4M` |
| `ZBX_STARTPOLLERS` | Number of pollers | `5` |
| `ZBX_STARTPOLLERSUNREACHABLE` | Unreachable pollers | `1` |
| `ZBX_STARTTRAPPERS` | Number of trappers | `5` |
| `ZBX_STARTPINGERS` | Number of pingers | `1` |
| `ZBX_STARTDISCOVERERS` | Number of discoverers | `1` |
| `ZBX_TIMEOUT` | Item timeout (seconds) | `4` |
| `ZBX_TRAPPERTIMEOUT` | Trapper timeout (seconds) | `300` |
| `ZBX_CONFIGFREQUENCY` | Config sync interval (seconds) | `60` |
| `ZBX_DATASENDERFREQUENCY` | Data send interval (seconds) | `1` |
| `ZBX_HEARTBEATFREQUENCY` | Heartbeat interval (seconds) | `60` |
| `ZBX_PROXYLOCALBUFFER` | Local buffer (hours) | `0` |
| `ZBX_PROXYOFFLINEBUFFER` | Offline buffer (hours) | `1` |
| `ZBX_UNREACHABLEPERIOD` | Unreachable period (seconds) | `45` |
| `ZBX_UNAVAILABLEDELAY` | Unavailable delay (seconds) | `60` |
| `ZBX_UNREACHABLEDELAY` | Unreachable delay (seconds) | `15` |
| `ZBX_DBPATH` | SQLite database path | `/var/lib/zabbix/zabbix_proxy.db` |


#### Container Settings

| Variable | Description | Default |
|---|---|---|
| `SSH_ROOT_PASSWORD` | Root password for SSH | `zabbix` |
| `UPDATE_SCHEDULE` | Cron expression for update checks | `*/30 * * * *` |

### Manual Update / Status Check

SSH into the container:

```bash
ssh root@IP Address
```

```bash
# Check current vs target version and detected architecture
zabbix-proxy-update.sh status

# Force an update check right now
zabbix-proxy-update.sh update
```

### Logs

| Log | Location |
|---|---|
| Proxy output | Container console (visible in RouterOS logging) |
| Update script | `/var/log/zabbix-proxy-update.log` |

---

## Part 2: Windows Compile Script

`Compile-ZabbixProxy.ps1` cross-compiles the Zabbix Proxy binary for both ARM32 and ARM64 in a single run and places them in the IIS serving directory.

### Prerequisites

- Docker Desktop with buildx support
- IIS configured to serve `C:\Firmware\Zabbix\`

### Usage

```powershell
.\Compile-ZabbixProxy.ps1
```

The script will:

1. Prompt for the Zabbix version to compile (e.g., `7.2.3`)
2. Cross-compile for ARM32, then ARM64, using Docker buildx
3. Strip both binaries and extract them to `C:\Firmware\Zabbix\`
4. Back up any existing binaries with timestamps

### IIS Output

| File | Architecture | Served At |
|---|---|---|
| `C:\Firmware\Zabbix\zabbix_proxy.bin` | ARM32 | `http://checkin.lighthouseit.us/Zabbix/zabbix_proxy.bin` |
| `C:\Firmware\Zabbix\zabbix_proxy_arm64.bin` | ARM64 | `http://checkin.lighthouseit.us/Zabbix/zabbix_proxy_arm64.bin` |
| `C:\Firmware\Zabbix\version.txt` | — | Version marker |

### After Compiling

Update the `zblive` file in the GitHub repository to the new version number. This triggers all containers (both ARM32 and ARM64) to download their respective updated binary.

---

## Device Reference

| Device | Architecture | Container Image |
|---|---|---|
| RB4011 | ARM32 (armv7) | `zabbix-proxy-arm32-<ver>.tar` |
| RB5009 | ARM64 (aarch64) | `zabbix-proxy-arm64-<ver>.tar` |
| CCR2004 | ARM64 (aarch64) | `zabbix-proxy-arm64-<ver>.tar` |
| CCR2116 | ARM64 (aarch64) | `zabbix-proxy-arm64-<ver>.tar` |

---

## Files

| File | Description |
|---|---|
| `Dockerfile` | Multi-stage container build (Alpine 3.19, arch-agnostic) |
| `entrypoint.sh` | Container startup — sshd, crond, supervised proxy loop |
| `zabbix-proxy-update.sh` | In-container update script (auto-detects arch) |
| `zabbix_proxy.conf` | Fallback proxy config (overridden by env vars) |
| `build.sh` | Build both container images (Linux/macOS) |
| `build.ps1` | Build both container images (Windows) |
| `Compile-ZabbixProxy.ps1` | Cross-compile both binaries for IIS server (Windows) |

---

## Version History

| Version | Changes |
|---|---|
| **v3.1.0** | Added ARM64 support (RB5009, CCR2004, CCR2116). Build scripts produce both ARM32 and ARM64 images. Compile script produces both binaries. Update script auto-detects architecture. |
| v3.0.0 | Two-part architecture: lean container + Windows compile script. Auto-update from IIS. SSH always on. |
| v2.x | Various iterations on base image (Alpine vs Debian) and self-compile approach. |
| v1.0.0 | Original Alpine container by Gabriel. Build-time compile only. |
