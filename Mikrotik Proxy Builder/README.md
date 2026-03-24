# Zabbix Proxy + Agent2 for MikroTik RouterOS (ARM32 + ARM64)

Self-updating Zabbix Proxy + Agent2 containers for MikroTik RouterOS 7.x on ARM devices.

| Architecture | Platform | Devices |
|---|---|---|
| ARM32 (armv7) | `linux/arm/v7` | RB4011 |
| ARM64 (aarch64) | `linux/arm64` | RB5009, CCR2004, CCR2116 |

Pre-compiled binaries are served from an checkin.lighthouseit.us. Containers check a GitHub-hosted version file on a schedule (default is every 30 min) and automatically download and install new binaries when a version change is detected. Each container auto-detects its architecture and downloads the correct binaries.

---

## Architecture

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  CONTAINER INTERNALS                                                    │
 │                                                                         │
 │   ┌──────────────────────────────────────────┐                          │
 │   │  MikroTik Container (Alpine)             │                          │
 │   │                                          │                          │
 │   │  ┌─────────────┐  ┌─────────────┐       │                          │
 │   │  │ zabbix_proxy │  │ zabbix_agent2│      │                          │
 │   │  │ :10051       │  │ :10050       │      │                          │
 │   │  └──────┬───────┘  └──────┬───────┘      │                          │
 │   │         │                 │               │                          │
 │   │         │    agent2 -> proxy (127.0.0.1)  │                          │
 │   │         │                                 │                          │
 │   │  ┌──────┴─────────────────────────┐      │                          │
 │   │  │ entrypoint.sh (supervisor)     │      │                          │
 │   │  │ + sshd  + crond               │      │                          │
 │   │  └───────────────────────────────┘      │                          │
 │   └──────────────────────────────────────────┘                          │
 │                                                                         │
 └──────────────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────────────────────────────────────────────────────┐
 │  UPDATE FLOW                                                            │
 │                                                                         │
 │   ┌────────────────────┐       1. version check        ┌─────────────┐ │
 │   │ GitHub             │  <──────────────────────────── │  MikroTik   │ │
 │   │ (zblive file)      │                                │  Container  │ │
 │   │ contains: "7.2.15" │   2. if version != installed   │             │ │
 │   └────────────────────┘                                │  detects    │ │
 │                                                         │  arch and   │ │
 │   ┌────────────────────┐       download matching bins   │  downloads  │ │
 │   │ IIS Server         │  <──────────────────────────── │  both proxy │ │
 │   │ /Zabbix/           │                                │  + agent2   │ │
 │   │ zabbix_proxy.bin        (ARM32)                     │             │ │
 │   │ zabbix_proxy_arm64.bin  (ARM64)                     │  3. replace │ │
 │   │ zabbix_agent2.bin       (ARM32)                     │  4. restart │ │
 │   │ zabbix_agent2_arm64.bin (ARM64)                     │             │ │
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
 │   │                    │      (IIS serves this directory)               │
 │   └────────────────────┘                                                │
 │                                                                         │
 │   After compiling, update the GitHub zblive file to trigger rollout.    │
 │                                                                         │
 └──────────────────────────────────────────────────────────────────────────┘
```

### How an update rolls out

1. Run `Compile-ZabbixProxy.ps1` on the Windows build machine (LH-TIK) — compiles proxy + agent2 for both ARM32 and ARM64
2. Four binaries are placed at `C:\Firmware\Zabbix\` (served by IIS)
3. Update the `zblive` file on GitHub to the new version number
4. Within 30 minutes, all containers detect the version mismatch
5. Each container downloads the binaries matching its architecture
6. Binaries are replaced in-place and both processes restart automatically

---

## Part 1: Containers (MikroTik)

Both ARM32 and ARM64 containers are built from the same Dockerfile. The architecture is determined by the `--platform` flag at build time. At runtime, the update script auto-detects the architecture and downloads the correct binaries.

### Compiled Features

The proxy binary is compiled with full Zabbix feature support:

| Feature | Configure Flag | What It Enables |
|---|---|---|
| SQLite | `--with-sqlite3` | Local proxy database |
| SNMP | `--with-net-snmp` | SNMP monitoring |
| SSH | `--with-ssh2` | `ssh.run[]` remote command items |
| IPMI | `--with-openipmi` | iDRAC / BMC hardware monitoring |
| ODBC | `--with-unixodbc` | Database monitoring via ODBC |
| LDAP | `--with-ldap` | LDAP checks |
| SSL | `--with-openssl` | TLS/PSK encryption |
| cURL | `--with-libcurl` | HTTP agent, web scenarios |
| XML | `--with-libxml2` | XML processing |
| PCRE2 | `--with-libpcre2` | Regular expressions |

### Included Tools

| Tool | Path | Purpose |
|---|---|---|
| `fping` | `/usr/sbin/fping` + `/usr/bin/fping` | ICMP ping checks (setuid enabled) |
| `traceroute` | `/usr/bin/traceroute` | Network diagnostics |
| `nmap` | `/usr/bin/nmap` | Network discovery |
| `sudo` | `/usr/bin/sudo` | UserParameter script elevation |
| `openssh` | `/usr/sbin/sshd` | SSH access into the container |
| `nano` | `/usr/bin/nano` | File editing |
| `curl` | `/usr/bin/curl` | HTTP testing |

### Prerequisites

- Docker Desktop (Windows/macOS) or Docker Engine (Linux) with buildx support

> **OCI Compliance:** RouterOS versions prior to 7.21 may fail to extract container images produced by Docker buildx due to non-standard OCI archive formatting. The build scripts automatically normalize tarballs using [skopeo](https://github.com/containers/skopeo) (run via Docker container — no extra install needed). See [Container Limitations](https://tangentsoft.com/mikrotik/wiki?name=Container+Limitations#compliance) for details.

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

### Deploy to MikroTik

#### Enable Container Support

```routeros
/system/device-mode/update container=yes
```
> **Warning:** The router will reboot.

#### Create Container Network

```routeros
/interface/veth/add name=veth-zabbix address=172.17.0.2/24 gateway=172.17.0.1
/interface/bridge/add name=br-containers
/interface/bridge/port/add bridge=br-containers interface=veth-zabbix
/ip/address/add address=172.17.0.1/24 interface=br-containers
/ip/firewall/nat/add chain=srcnat src-address=172.17.0.0/24 action=masquerade
```

#### Upload Container Image

Upload the correct `.tar` for the device via WinBox (Files → drag and drop) or SCP:

```bash
# RB4011 (ARM32)
scp zabbix-proxy-arm32-7.2.15.tar admin@<router-ip>:/

# RB5009, CCR2004, CCR2116 (ARM64)
scp zabbix-proxy-arm64-7.2.15.tar admin@<router-ip>:/
```

#### Configure Environment Variables

```routeros
/container/envs
add name=zabbix key=ZBX_SERVER_HOST value=zabbix.example.com
add name=zabbix key=ZBX_HOSTNAME value=<unique-proxy-name>
add name=zabbix key=SSH_ROOT_PASSWORD value=YourSecurePassword
```

#### Create and Start the Container

```routeros
# ARM32 (RB4011)
/container/add file=zabbix-proxy-arm32-7.2.15.tar interface=veth-zabbix root-dir=disk1/zabbix-proxy hostname=rb4011-proxy envlist=zabbix logging=yes

# ARM64 (RB5009, CCR2004, CCR2116)
/container/add file=zabbix-proxy-arm64-7.2.15.tar interface=veth-zabbix root-dir=disk1/zabbix-proxy hostname=rb5009-proxy envlist=zabbix logging=yes

/container/start 0
```

### Container Features

| Feature | Status | Details |
|---|---|---|
| Zabbix Proxy | Always on | Supervised, auto-restarts |
| Zabbix Agent2 | On by default | Disable with `DISABLE_AGENT2=true` |
| SSH | Always on | Port 22, root login |
| Auto-update | Always on | Every 30 min (configurable) |
| Arch detection | Automatic | Downloads correct binaries for ARM32/ARM64 |
| Package manager | `apk` | Alpine Linux |

### Environment Variables

#### Proxy Settings

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

#### Proxy TLS Settings

| Variable | Description |
|---|---|
| `ZBX_TLSCONNECT` | Outgoing TLS mode (`psk`, `cert`) |
| `ZBX_TLSACCEPT` | Incoming TLS mode |
| `ZBX_TLSPSKIDENTITY` | PSK identity string |
| `ZBX_TLSPSKFILE` | Path to PSK file |
| `ZBX_TLSCAFILE` | Path to CA certificate |
| `ZBX_TLSCERTFILE` | Path to TLS certificate |
| `ZBX_TLSKEYFILE` | Path to TLS private key |

#### Agent2 Settings

| Variable | Description | Default |
|---|---|---|
| `ZBX_AGENT2_SERVER` | Server/proxy for passive checks | `127.0.0.1` |
| `ZBX_AGENT2_SERVERACTIVE` | Server/proxy for active checks | `127.0.0.1` |
| `ZBX_AGENT2_HOSTNAME` | Agent hostname in Zabbix | `<ZBX_HOSTNAME>-agent` |
| `ZBX_AGENT2_LISTENPORT` | Agent listen port | `10050` |
| `ZBX_AGENT2_DEBUGLEVEL` | Agent log level (0-5) | `3` |
| `ZBX_AGENT2_TLSCONNECT` | Agent TLS connect mode | — |
| `ZBX_AGENT2_TLSACCEPT` | Agent TLS accept mode | — |
| `ZBX_AGENT2_TLSPSKIDENTITY` | Agent PSK identity | — |
| `ZBX_AGENT2_TLSPSKFILE` | Agent PSK file path | — |
| `DISABLE_AGENT2` | Set to `true` to run proxy only | `false` |

#### Container Settings

| Variable | Description | Default |
|---|---|---|
| `SSH_ROOT_PASSWORD` | Root password for SSH | `zabbix` |
| `UPDATE_SCHEDULE` | Cron expression for update checks | `*/30 * * * *` |

### Manual Update / Status Check

SSH into the container:

```bash
ssh root@172.17.0.2
```

```bash
# Check current vs target version (shows arch, both binaries, URLs)
zabbix-update.sh status

# Force an update check right now
zabbix-update.sh update
```

### Logs

| Log | Location |
|---|---|
| Proxy + Agent2 output | Container console (visible in RouterOS logging) |
| Update script | `/var/log/zabbix-update.log` |

---

## Part 2: Windows Compile Script

`Compile-ZabbixProxy.ps1` cross-compiles the Zabbix Proxy + Agent2 binaries for both ARM32 and ARM64 in a single run and places them in the IIS serving directory.

### Prerequisites

- Docker Desktop with buildx support
- IIS configured to serve `C:\Firmware\Zabbix\`

### Usage

```powershell
.\Compile-ZabbixProxy.ps1
```

The script will:

1. Prompt for the Zabbix version to compile (e.g., `7.2.15`)
2. Cross-compile proxy + agent2 for ARM32, then ARM64, using Docker buildx
3. Strip binaries and extract them to `C:\Firmware\Zabbix\`
4. Back up any existing binaries with timestamps

### IIS Output

| File | Architecture | Served At |
|---|---|---|
| `zabbix_proxy.bin` | ARM32 | `http://checkin.lighthouseit.us/Zabbix/zabbix_proxy.bin` |
| `zabbix_proxy_arm64.bin` | ARM64 | `http://checkin.lighthouseit.us/Zabbix/zabbix_proxy_arm64.bin` |
| `zabbix_agent2.bin` | ARM32 | `http://checkin.lighthouseit.us/Zabbix/zabbix_agent2.bin` |
| `zabbix_agent2_arm64.bin` | ARM64 | `http://checkin.lighthouseit.us/Zabbix/zabbix_agent2_arm64.bin` |
| `version.txt` | — | Version marker |

### After Compiling

Update the `zblive` file in the GitHub repository to the new version number. This triggers all containers (both ARM32 and ARM64) to download their respective updated binaries.

---

## Upgrades, Downgrades, and Rollbacks

The update script supports both upgrades and downgrades. When you change the version in `zblive`, containers will download the matching binaries regardless of whether the new version is higher or lower.

### Patch-level changes (e.g. 7.2.3 → 7.2.15)

Binaries are replaced and both processes restart. The SQLite database is preserved since the schema is unchanged within a major.minor branch.

### Major.minor changes (e.g. 7.2.x → 7.4.x or 7.4.x → 7.2.x)

The update script detects the major.minor change and automatically:

1. Backs up the existing database (e.g. `zabbix_proxy.db.7.4.7.bak`)
2. Deletes the database
3. Reinitializes a fresh database from `schema.sql`
4. Restarts both processes

Any buffered monitoring data that hasn't been sent to the Zabbix server will be lost during a major.minor change. For major.minor version changes, consider rebuilding the container image with `build.ps1` / `build.sh` to ensure `schema.sql` matches the new version.

---

## Device Reference

| Device | Architecture | Container Image | Proxy Binary | Agent2 Binary |
|---|---|---|---|---|
| RB4011 | ARM32 | `zabbix-proxy-arm32-<ver>.tar` | `zabbix_proxy.bin` | `zabbix_agent2.bin` |
| RB5009 | ARM64 | `zabbix-proxy-arm64-<ver>.tar` | `zabbix_proxy_arm64.bin` | `zabbix_agent2_arm64.bin` |
| CCR2004 | ARM64 | `zabbix-proxy-arm64-<ver>.tar` | `zabbix_proxy_arm64.bin` | `zabbix_agent2_arm64.bin` |
| CCR2116 | ARM64 | `zabbix-proxy-arm64-<ver>.tar` | `zabbix_proxy_arm64.bin` | `zabbix_agent2_arm64.bin` |

---

## Files

| File | Description |
|---|---|
| `Dockerfile` | Multi-stage container build — proxy (C) + agent2 (Go), Alpine 3.19 |
| `entrypoint.sh` | Container startup — supervises proxy + agent2, sshd, crond |
| `zabbix-update.sh` | In-container auto-update script (detects arch, updates both binaries) |
| `zabbix_proxy.conf` | Fallback proxy config (overridden by env vars) |
| `zabbix_agent2.conf` | Fallback agent2 config (overridden by env vars) |
| `build.sh` | Build both container tars with OCI normalization (Linux/macOS) |
| `build.ps1` | Build both container tars with OCI normalization (Windows) |
| `Compile-ZabbixProxy.ps1` | Cross-compile all 4 binaries for IIS server (Windows) |

---

## Version History

| Version | Changes |
|---|---|
| **v4.0.0** | Added Zabbix Agent2 alongside proxy. Added SSH checks, IPMI, ODBC compile support. Added fping (dual-path symlink + setuid), traceroute, nmap, sudo. Go 1.24 direct install for agent2 compilation. Fixed BusyBox ash `wait -n` supervisor bug. |
| v3.2.0 | OCI normalization via skopeo. Database wipe on major.minor version changes. |
| v3.1.0 | ARM64 support (RB5009, CCR2004, CCR2116). Dual-arch build scripts. |
| v3.0.0 | Two-part architecture: lean container + Windows compile script. Auto-update from IIS. |
| v2.x | Various iterations (Alpine vs Debian, self-compile approach). |
| v1.0.0 | Original Alpine container by Gabriel. Build-time compile only. |
