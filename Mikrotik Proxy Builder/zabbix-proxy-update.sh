#!/bin/ash
# =============================================================================
# zabbix-proxy-update.sh v3.1.0 (Alpine Container Edition)
# =============================================================================
# Checks GitHub version file, downloads pre-compiled binary from IIS server.
# Auto-detects ARM32 vs ARM64 and downloads the correct binary.
#
# IIS filenames:
#   ARM32 (armv7l)  -> zabbix_proxy.bin
#   ARM64 (aarch64) -> zabbix_proxy_arm64.bin
#
# Usage:
#   zabbix-proxy-update.sh update      Run update check now
#   zabbix-proxy-update.sh status      Show current vs target version
# =============================================================================

set -euo pipefail

# -- Configuration ------------------------------------------------------------
VERSION_URL="https://raw.githubusercontent.com/Lighthouse-IT-Github/TikLive/refs/heads/main/zblive"
BINARY_BASE_URL="http://checkin.lighthouseit.us/Zabbix"

VERSION_FILE="/etc/zabbix/.installed_version"
PROXY_BIN="/usr/sbin/zabbix_proxy"
LOG_FILE="/var/log/zabbix-proxy-update.log"

HEALTH_CHECK_RETRIES=5
HEALTH_CHECK_INTERVAL=5
# -----------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Detect architecture and return the correct binary filename
get_binary_filename() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64)
            echo "zabbix_proxy_arm64.bin"
            ;;
        armv7l|armv7*|armhf)
            echo "zabbix_proxy.bin"
            ;;
        *)
            die "Unsupported architecture: $arch"
            ;;
    esac
}

get_arch_label() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64)   echo "ARM64" ;;
        armv7l|armv7*)   echo "ARM32" ;;
        *)               echo "$arch" ;;
    esac
}

get_target_version() {
    local ver
    ver="$(curl -fsSL --max-time 30 "${VERSION_URL}" | tr -d '[:space:]')"
    echo "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || die "Invalid version format retrieved: '${ver}'"
    echo "$ver"
}

get_installed_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE" | tr -d '[:space:]'
    elif [ -x "$PROXY_BIN" ]; then
        "$PROXY_BIN" -V 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"
    else
        echo "none"
    fi
}

# =============================================================================
# Command: status
# =============================================================================
cmd_status() {
    local installed target bin_file arch_label
    installed="$(get_installed_version)"
    target="$(get_target_version)"
    bin_file="$(get_binary_filename)"
    arch_label="$(get_arch_label)"

    echo ""
    echo "  Zabbix Proxy Update Status (Container)"
    echo "  ----------------------------------------"
    echo "  Installed version : ${installed}"
    echo "  Target version    : ${target}"
    if [ "${installed}" = "${target}" ]; then
        echo "  Status            : UP TO DATE"
    else
        echo "  Status            : UPDATE AVAILABLE"
    fi
    echo ""
    echo "  Architecture      : ${arch_label} ($(uname -m))"
    echo "  Binary URL        : ${BINARY_BASE_URL}/${bin_file}"
    echo "  Version URL       : ${VERSION_URL}"
    echo ""

    if crontab -l 2>/dev/null | grep -q "zabbix-proxy-update"; then
        local sched
        sched="$(crontab -l 2>/dev/null | grep 'zabbix-proxy-update' | awk '{print $1,$2,$3,$4,$5}')"
        echo "  Auto-update       : Active (${sched})"
    else
        echo "  Auto-update       : Not enabled"
    fi
    echo "  Alpine version    : $(cat /etc/alpine-release 2>/dev/null || echo 'unknown')"
    echo ""
}

# =============================================================================
# Command: update
# =============================================================================
cmd_update() {
    local ARCH_LABEL BIN_FILE
    ARCH_LABEL="$(get_arch_label)"
    BIN_FILE="$(get_binary_filename)"

    log "=== Zabbix Proxy Update Check (${ARCH_LABEL}) ==="

    log "Fetching target version from GitHub..."
    local TARGET_VERSION
    TARGET_VERSION="$(get_target_version)"
    log "Target version: ${TARGET_VERSION}"

    local INSTALLED_VERSION
    INSTALLED_VERSION="$(get_installed_version)"
    log "Installed version: ${INSTALLED_VERSION}"

    if [ "${INSTALLED_VERSION}" = "${TARGET_VERSION}" ]; then
        log "Already running target version ${TARGET_VERSION}. Nothing to do."
        return 0
    fi

    log "Version mismatch: ${INSTALLED_VERSION} -> ${TARGET_VERSION}. Downloading update..."

    # -- Download binary from IIS server ---------------------------------------
    local BINARY_URL="${BINARY_BASE_URL}/${BIN_FILE}"
    local TMP_BIN="/tmp/zabbix_proxy_new"

    log "Downloading ${ARCH_LABEL} binary from ${BINARY_URL}..."
    if ! curl -fSL --max-time 120 -o "${TMP_BIN}" "${BINARY_URL}"; then
        die "Failed to download binary from ${BINARY_URL}"
    fi

    # Verify we got an actual binary (not an HTML error page)
    local FILE_TYPE
    FILE_TYPE="$(file -b "${TMP_BIN}" 2>/dev/null || echo "unknown")"
    if echo "${FILE_TYPE}" | grep -qi "html\|text\|ascii"; then
        rm -f "${TMP_BIN}"
        die "Downloaded file is not a binary (got: ${FILE_TYPE}). Check IIS server."
    fi

    local FILE_SIZE
    FILE_SIZE="$(wc -c < "${TMP_BIN}")"
    if [ "${FILE_SIZE}" -lt 100000 ]; then
        rm -f "${TMP_BIN}"
        die "Downloaded file too small (${FILE_SIZE} bytes). Expected zabbix_proxy binary."
    fi

    log "Downloaded binary: ${FILE_SIZE} bytes (${FILE_TYPE})"

    # -- Replace binary and restart --------------------------------------------
    chmod 755 "${TMP_BIN}"
    cp -f "${TMP_BIN}" "${PROXY_BIN}"
    rm -f "${TMP_BIN}"

    echo "${TARGET_VERSION}" > "${VERSION_FILE}"
    log "Binary replaced. Version file updated to ${TARGET_VERSION}."

    log "Killing running zabbix_proxy (entrypoint will restart it)..."
    if pkill -f "zabbix_proxy.*-f" 2>/dev/null; then
        log "Sent kill signal to zabbix_proxy"
    else
        log "Warning: Could not find running zabbix_proxy process"
    fi

    # -- Health check ----------------------------------------------------------
    log "Waiting for proxy to restart..."
    local i
    for i in $(seq 1 $HEALTH_CHECK_RETRIES); do
        sleep "$HEALTH_CHECK_INTERVAL"
        if pgrep -f "zabbix_proxy.*-f" > /dev/null 2>&1; then
            log "zabbix_proxy is running again."
            log "Update complete: ${INSTALLED_VERSION} -> ${TARGET_VERSION}"
            return 0
        fi
        log "Health check attempt ${i}/${HEALTH_CHECK_RETRIES} -- proxy not yet running."
    done

    die "zabbix_proxy failed to restart after ${HEALTH_CHECK_RETRIES} attempts."
}

# =============================================================================
# Main
# =============================================================================
usage() {
    local bin_file arch_label
    bin_file="$(get_binary_filename)"
    arch_label="$(get_arch_label)"

    echo ""
    echo "  Zabbix Proxy Auto-Update v3.1.0 (Alpine Container)"
    echo "  ---------------------------------------------------"
    echo "  Usage: $0 <command>"
    echo ""
    echo "  Commands:"
    echo "    update      Check GitHub version and update proxy if needed"
    echo "    status      Show installed vs target version"
    echo ""
    echo "  Architecture  : ${arch_label} ($(uname -m))"
    echo "  Version source: ${VERSION_URL}"
    echo "  Binary source : ${BINARY_BASE_URL}/${bin_file}"
    echo ""
}

case "${1:-}" in
    update)  cmd_update ;;
    status)  cmd_status ;;
    *)       usage      ;;
esac
