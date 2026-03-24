#!/bin/ash
# =============================================================================
# zabbix-update.sh v4.0.0 (Alpine Container Edition)
# =============================================================================
# Checks GitHub version file, downloads pre-compiled proxy + agent2 binaries
# from IIS server. Auto-detects ARM32 vs ARM64.
#
# IIS filenames:
#   ARM32 (armv7l):
#     zabbix_proxy.bin
#     zabbix_agent2.bin
#   ARM64 (aarch64):
#     zabbix_proxy_arm64.bin
#     zabbix_agent2_arm64.bin
#
# Usage:
#   zabbix-update.sh update      Run update check now
#   zabbix-update.sh status      Show current vs target version
# =============================================================================

set -euo pipefail

# -- Configuration ------------------------------------------------------------
VERSION_URL="https://raw.githubusercontent.com/Lighthouse-IT-Github/TikLive/refs/heads/main/zblive"
BINARY_BASE_URL="http://checkin.lighthouseit.us/Zabbix"

VERSION_FILE="/etc/zabbix/.installed_version"
PROXY_BIN="/usr/sbin/zabbix_proxy"
AGENT2_BIN="/usr/sbin/zabbix_agent2"
ZABBIX_DB_PATH="${ZBX_DBPATH:-/var/lib/zabbix/zabbix_proxy.db}"
ZABBIX_SCHEMA="/usr/share/zabbix/database/sqlite3/schema.sql"
LOG_FILE="/var/log/zabbix-update.log"

HEALTH_CHECK_RETRIES=8
HEALTH_CHECK_INTERVAL=5
# -----------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Detect architecture and return filename suffixes
get_arch_suffix() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64)   echo "_arm64" ;;
        armv7l|armv7*)   echo "" ;;
        *)               die "Unsupported architecture: $arch" ;;
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

# Download and validate a binary
download_binary() {
    local URL="$1"
    local DEST="$2"
    local LABEL="$3"
    local TMP="/tmp/${LABEL}_new"

    log "Downloading ${LABEL} from ${URL}..."
    if ! curl -fSL --max-time 120 -o "${TMP}" "${URL}"; then
        log "WARNING: Failed to download ${LABEL} from ${URL}"
        return 1
    fi

    local FILE_TYPE
    FILE_TYPE="$(file -b "${TMP}" 2>/dev/null || echo "unknown")"
    if echo "${FILE_TYPE}" | grep -qi "html\|text\|ascii"; then
        rm -f "${TMP}"
        log "WARNING: Downloaded ${LABEL} is not a binary (got: ${FILE_TYPE})"
        return 1
    fi

    local FILE_SIZE
    FILE_SIZE="$(wc -c < "${TMP}")"
    if [ "${FILE_SIZE}" -lt 100000 ]; then
        rm -f "${TMP}"
        log "WARNING: Downloaded ${LABEL} too small (${FILE_SIZE} bytes)"
        return 1
    fi

    chmod 755 "${TMP}"
    cp -f "${TMP}" "${DEST}"
    rm -f "${TMP}"
    log "Installed ${LABEL}: ${FILE_SIZE} bytes"
    return 0
}

# =============================================================================
# Command: status
# =============================================================================
cmd_status() {
    local installed target arch_label arch_suffix
    installed="$(get_installed_version)"
    target="$(get_target_version)"
    arch_label="$(get_arch_label)"
    arch_suffix="$(get_arch_suffix)"

    echo ""
    echo "  Zabbix Update Status (Container)"
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
    echo "  Proxy binary      : $([ -x "$PROXY_BIN" ] && echo "installed" || echo "MISSING")"
    echo "  Agent2 binary     : $([ -x "$AGENT2_BIN" ] && echo "installed" || echo "MISSING")"
    echo ""
    echo "  Proxy URL         : ${BINARY_BASE_URL}/zabbix_proxy${arch_suffix}.bin"
    echo "  Agent2 URL        : ${BINARY_BASE_URL}/zabbix_agent2${arch_suffix}.bin"
    echo "  Version URL       : ${VERSION_URL}"
    echo ""

    if crontab -l 2>/dev/null | grep -q "zabbix-update"; then
        local sched
        sched="$(crontab -l 2>/dev/null | grep 'zabbix-update' | awk '{print $1,$2,$3,$4,$5}')"
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
    local ARCH_LABEL ARCH_SUFFIX
    ARCH_LABEL="$(get_arch_label)"
    ARCH_SUFFIX="$(get_arch_suffix)"

    log "=== Zabbix Update Check (${ARCH_LABEL}) ==="

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

    log "Version mismatch: ${INSTALLED_VERSION} -> ${TARGET_VERSION}. Downloading updates..."

    # -- Download both binaries ------------------------------------------------
    local PROXY_URL="${BINARY_BASE_URL}/zabbix_proxy${ARCH_SUFFIX}.bin"
    local AGENT2_URL="${BINARY_BASE_URL}/zabbix_agent2${ARCH_SUFFIX}.bin"
    local PROXY_OK=false
    local AGENT2_OK=false

    if download_binary "${PROXY_URL}" "${PROXY_BIN}" "zabbix_proxy"; then
        PROXY_OK=true
    fi

    if download_binary "${AGENT2_URL}" "${AGENT2_BIN}" "zabbix_agent2"; then
        AGENT2_OK=true
    fi

    if [ "$PROXY_OK" = "false" ] && [ "$AGENT2_OK" = "false" ]; then
        die "Failed to download both binaries. Update aborted."
    fi

    # -- Handle database schema changes on major.minor version change ----------
    local INSTALLED_MAJOR_MINOR TARGET_MAJOR_MINOR
    INSTALLED_MAJOR_MINOR="$(echo "${INSTALLED_VERSION}" | cut -d. -f1,2)"
    TARGET_MAJOR_MINOR="$(echo "${TARGET_VERSION}" | cut -d. -f1,2)"

    if [ "${INSTALLED_MAJOR_MINOR}" != "${TARGET_MAJOR_MINOR}" ]; then
        log "Major.minor version change detected (${INSTALLED_MAJOR_MINOR} -> ${TARGET_MAJOR_MINOR})."
        if [ -f "${ZABBIX_DB_PATH}" ]; then
            local DB_BACKUP="${ZABBIX_DB_PATH}.${INSTALLED_VERSION}.bak"
            cp -f "${ZABBIX_DB_PATH}" "${DB_BACKUP}"
            log "Backed up database to ${DB_BACKUP}"
            rm -f "${ZABBIX_DB_PATH}"
            log "Removed old database (schema incompatible across major.minor versions)."
        fi
        # Reinitialize database with current schema
        if [ -f "${ZABBIX_SCHEMA}" ]; then
            /usr/bin/sqlite3 "${ZABBIX_DB_PATH}" < "${ZABBIX_SCHEMA}"
            chown zabbix:zabbix "${ZABBIX_DB_PATH}"
            log "Reinitialized database from schema.sql"
        else
            log "Warning: schema.sql not found. New binary will need to create the DB."
        fi
    else
        log "Patch-level change only (${INSTALLED_MAJOR_MINOR}). Database schema unchanged."
    fi

    # -- Update version tracker ------------------------------------------------
    echo "${TARGET_VERSION}" > "${VERSION_FILE}"
    log "Version file updated to ${TARGET_VERSION}."

    # -- Kill running processes (entrypoint loop restarts them) ----------------
    log "Killing running Zabbix processes (entrypoint will restart them)..."
    if [ "$PROXY_OK" = "true" ]; then
        pkill -f "zabbix_proxy.*-f" 2>/dev/null && log "Killed zabbix_proxy" || log "zabbix_proxy not running"
    fi
    if [ "$AGENT2_OK" = "true" ]; then
        pkill -f "zabbix_agent2.*-f" 2>/dev/null && log "Killed zabbix_agent2" || log "zabbix_agent2 not running"
    fi

    # -- Health check ----------------------------------------------------------
    log "Waiting for processes to restart..."
    local i proxy_up=false agent2_up=false
    for i in $(seq 1 $HEALTH_CHECK_RETRIES); do
        sleep "$HEALTH_CHECK_INTERVAL"

        if [ "$proxy_up" = "false" ] && pgrep -f "zabbix_proxy.*-f" > /dev/null 2>&1; then
            proxy_up=true
            log "zabbix_proxy is running."
        fi

        if [ "$agent2_up" = "false" ] && pgrep -f "zabbix_agent2.*-f" > /dev/null 2>&1; then
            agent2_up=true
            log "zabbix_agent2 is running."
        fi

        if [ "$proxy_up" = "true" ]; then
            log "Update complete: ${INSTALLED_VERSION} -> ${TARGET_VERSION}"
            [ "$agent2_up" = "false" ] && log "Note: agent2 may still be starting or is disabled."
            return 0
        fi

        log "Health check ${i}/${HEALTH_CHECK_RETRIES} -- waiting..."
    done

    die "Processes failed to restart after ${HEALTH_CHECK_RETRIES} attempts."
}

# =============================================================================
# Main
# =============================================================================
usage() {
    local arch_label arch_suffix
    arch_label="$(get_arch_label)"
    arch_suffix="$(get_arch_suffix)"

    echo ""
    echo "  Zabbix Auto-Update v4.0.0 (Alpine Container)"
    echo "  -------------------------------------------------"
    echo "  Usage: $0 <command>"
    echo ""
    echo "  Commands:"
    echo "    update      Check GitHub version and update proxy + agent2"
    echo "    status      Show installed vs target version"
    echo ""
    echo "  Architecture  : ${arch_label} ($(uname -m))"
    echo "  Proxy binary  : ${BINARY_BASE_URL}/zabbix_proxy${arch_suffix}.bin"
    echo "  Agent2 binary : ${BINARY_BASE_URL}/zabbix_agent2${arch_suffix}.bin"
    echo ""
}

case "${1:-}" in
    update)  cmd_update ;;
    status)  cmd_status ;;
    *)       usage      ;;
esac
