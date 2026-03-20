# Zabbix Proxy + Agent2 for MikroTik RouterOS (ARM32 + ARM64)

> **Branch: dev** — Adds Zabbix Agent2 alongside the proxy. Experimental.

Self-updating Zabbix Proxy + Agent2 containers for MikroTik RouterOS 7.x.

| Architecture | Platform | Devices |
|---|---|---|
| ARM32 (armv7) | `linux/arm/v7` | RB4011 |
| ARM64 (aarch64) | `linux/arm64` | RB5009, CCR2004, CCR2116 |

---

## What's New in v4.0.0-dev

- **Zabbix Agent2** runs alongside the proxy in the same container
- Agent2 defaults to reporting to `127.0.0.1` (the colocated proxy)
- Both binaries auto-update from the IIS server simultaneously
- Agent2 can be disabled per-container via `DISABLE_AGENT2=true`
- Build scripts compile both proxy (C) and agent2 (Go) from source
- IIS now serves 4 binaries instead of 2

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
 │  IIS SERVER (C:\Firmware\Zabbix\)                                       │
 │                                                                         │
 │   zabbix_proxy.bin          ARM32 proxy                                 │
 │   zabbix_proxy_arm64.bin    ARM64 proxy                                 │
 │   zabbix_agent2.bin         ARM32 agent2                                │
 │   zabbix_agent2_arm64.bin   ARM64 agent2                                │
 │   version.txt               Current version marker                     │
 │                                                                         │
 └──────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### Build Container Images

```powershell
# Windows
.\build.ps1

# Linux / macOS
chmod +x build.sh && ./build.sh
```

Outputs both `zabbix-proxy-arm32-<ver>.tar` and `zabbix-proxy-arm64-<ver>.tar`.

### Compile Binaries for IIS

```powershell
.\Compile-ZabbixProxy.ps1
```

Outputs all 4 binaries to `C:\Firmware\Zabbix\`.

### Deploy to MikroTik

```routeros
# Upload tar, then:
/container/add file=zabbix-proxy-arm32-7.2.3.tar interface=veth-zabbix root-dir=disk1/zabbix-proxy hostname=rb4011-proxy envlist=zabbix-proxy logging=yes
/container/start 0
```

---

## Environment Variables

### Proxy Settings (same as main branch)

| Variable | Default |
|---|---|
| `ZBX_SERVER_HOST` | *(required)* |
| `ZBX_HOSTNAME` | container hostname |
| `ZBX_PROXYMODE` | `0` (active) |
| `ZBX_LISTENPORT` | `10051` |
| `ZBX_DEBUGLEVEL` | `3` |
| `ZBX_CACHESIZE` | `8M` |
| `ZBX_HISTORYCACHESIZE` | `16M` |
| All `ZBX_TLS*` vars | *(see main branch)* |

### Agent2 Settings (new)

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

### Container Settings

| Variable | Default |
|---|---|
| `SSH_ROOT_PASSWORD` | `zabbix` |
| `UPDATE_SCHEDULE` | `*/30 * * * *` |

### Example RouterOS Env Setup

```routeros
/container/envs
add name=zabbix key=ZBX_SERVER_HOST value=zabbix.example.com
add name=zabbix key=ZBX_HOSTNAME value=rb4011-proxy
add name=zabbix key=ZBX_AGENT2_HOSTNAME value=rb4011-agent
add name=zabbix key=SSH_ROOT_PASSWORD value=YourSecurePassword
```

---

## Manual Operations

```bash
# SSH into container
ssh root@172.17.0.2

# Check status (shows both proxy and agent2)
zabbix-update.sh status

# Force update
zabbix-update.sh update
```

---

## Files

| File | Description |
|---|---|
| `Dockerfile` | Multi-stage build — proxy (C) + agent2 (Go) |
| `entrypoint.sh` | Supervises proxy + agent2, sshd, crond |
| `zabbix-update.sh` | Auto-update for both binaries |
| `zabbix_proxy.conf` | Fallback proxy config |
| `zabbix_agent2.conf` | Fallback agent2 config |
| `build.sh` / `build.ps1` | Build both container tars with OCI fix |
| `Compile-ZabbixProxy.ps1` | Cross-compile all 4 binaries for IIS |

---

## Differences from Main Branch

| Feature | Main (v3.2.0) | Dev (v4.0.0-dev) |
|---|---|---|
| Proxy | Yes | Yes |
| Agent2 | No | Yes |
| IIS binaries | 2 (proxy per arch) | 4 (proxy + agent2 per arch) |
| Exposed ports | 10051, 22 | 10051, 10050, 22 |
| Build time | ~10-15 min per arch | ~15-25 min per arch (Go compile) |
| Container size | ~25-40 MB | ~40-60 MB (agent2 binary) |
| Update script | `zabbix-proxy-update.sh` | `zabbix-update.sh` |
