# Zabbix Proxy Auto-Update

Automatically keeps Zabbix proxy servers in sync with a centrally managed version number hosted on GitHub.

The script checks a remote version file every 30 minutes. If the installed Zabbix proxy version doesn't match, it updates the APT repository, installs the correct version, restarts the service, and verifies it's healthy.

## Requirements

- **OS:** Ubuntu Server (tested on 22.04 and 24.04)
- **Zabbix proxy** installed via APT from [repo.zabbix.com](https://repo.zabbix.com)
- **Packages:** `curl`, `apt`, `dpkg`, `systemctl`, `lsb_release` (all present on a standard Ubuntu server install)
- **Root access** (the script must run as root or via `sudo`)

## Quick Start

1. Download `zabbix-proxy-update.sh` from the [Lighthouse-IT-Github/TikLive](https://github.com/Lighthouse-IT-Github/TikLive) repository to your local machine
2. Copy the script to the target server and install:

```bash
# Copy to the server
scp zabbix-proxy-update.sh user@proxy-server:/tmp/

# SSH in and install
ssh user@proxy-server
sudo bash /tmp/zabbix-proxy-update.sh install
```

That's it. The script will now check for updates every 30 minutes.

## Commands

| Command | Description |
|---------|-------------|
| `sudo zabbix-proxy-update.sh install` | One-time setup — copies script to `/usr/local/bin/` and creates the cron job |
| `sudo zabbix-proxy-update.sh update` | Runs an update check immediately |
| `sudo zabbix-proxy-update.sh status` | Shows installed version vs. target version |
| `sudo zabbix-proxy-update.sh uninstall` | Removes the script and cron job |

Running the script with no arguments prints the usage help.

### Example: Checking Status

```
$ sudo zabbix-proxy-update.sh status

  Zabbix Proxy Update Status
  -----------------------------
  Installed version : 7.2.4
  Target version    : 7.4.7
  Status            : UPDATE AVAILABLE

  Cron job          : Active (*/30 * * * *)
  Ubuntu codename   : jammy
```

## How It Works

1. **Fetches** the target version from the remote `zblive` file (a single line like `7.4.7`)
2. **Compares** it to the locally installed `zabbix-proxy-sqlite3` package version
3. If they differ:
   - Downloads and installs the correct Zabbix release `.deb` for the target major.minor version and detected Ubuntu codename
   - Runs `apt-get update` to refresh the repo
   - Installs the exact target package version
   - Restarts the `zabbix-proxy` service
   - Runs a health check (5 retries, 5 seconds apart) to confirm the service is stable
4. If they match, the script exits with no changes

The script handles **major/minor version jumps** (e.g., 7.2 → 7.4) by automatically switching the APT repository.

## Configuration

All configuration is at the top of the script. Edit these variables before running `install` if needed:

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION_URL` | `https://raw.githubusercontent.com/.../zblive` | URL of the remote file containing the target version |
| `ZABBIX_PROXY_PKG` | `zabbix-proxy-sqlite3` | Package name — change to `zabbix-proxy-mysql` if applicable |
| `ZABBIX_SERVICE` | `zabbix-proxy` | systemd service name |
| `CRON_SCHEDULE` | `*/30 * * * *` | Cron schedule (default: every 30 minutes) |
| `HEALTH_CHECK_RETRIES` | `5` | Number of health check attempts after restart |
| `HEALTH_CHECK_INTERVAL` | `5` | Seconds between health check attempts |

## File Locations

| Path | Purpose |
|------|---------|
| `/usr/local/bin/zabbix-proxy-update.sh` | Installed script location |
| `/etc/cron.d/zabbix-proxy-update` | Cron drop-in file |
| `/var/log/zabbix-proxy-update.log` | Log output from cron runs |

## Deploying to Multiple Servers

Use `scp` and `ssh` to deploy across your fleet:

```bash
# Deploy to a single server
scp zabbix-proxy-update.sh user@proxy-server:/tmp/
ssh user@proxy-server "sudo bash /tmp/zabbix-proxy-update.sh install"
```

Or loop through a list of hosts:

```bash
SERVERS="proxy-01 proxy-02 proxy-03"

for host in $SERVERS; do
    echo "--- Deploying to ${host} ---"
    scp zabbix-proxy-update.sh user@${host}:/tmp/
    ssh user@${host} "sudo bash /tmp/zabbix-proxy-update.sh install"
done
```

## Updating the Script

To update an already-installed server to a newer version of the script, just run `install` again:

```bash
sudo ./zabbix-proxy-update.sh install
```

This overwrites the script and cron file in place.

## Uninstalling

```bash
sudo zabbix-proxy-update.sh uninstall
```

This removes the script from `/usr/local/bin/` and the cron job from `/etc/cron.d/`. The log file at `/var/log/zabbix-proxy-update.log` is left in place for review — delete it manually if desired.

## Troubleshooting

**Check the log:**
```bash
sudo cat /var/log/zabbix-proxy-update.log
```

**Common issues:**

- **"This script must be run as root"** — Run with `sudo`
- **"Failed to download Zabbix release package"** — The target version's major.minor may not have a repo for your Ubuntu codename. Verify the version in the `zblive` file supports your OS.
- **"Service failed to stabilize"** — The proxy started but crashed shortly after. Check Zabbix proxy logs at `/var/log/zabbix/zabbix_proxy.log` for details.
- **"Invalid version format"** — The remote `zblive` file returned something unexpected. It should contain only a version number like `7.4.7`.

## Version

Current: **v1.2.0**
