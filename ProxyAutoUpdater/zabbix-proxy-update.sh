#!/usr/bin/env bash
# =============================================================================
# zabbix-proxy-update.sh v1.2.0
# =============================================================================
# Checks a remote version file and updates the local Zabbix proxy to match.
#
# Usage:
#   sudo ./zabbix-proxy-update.sh install     Install script + daily cron job
#   sudo ./zabbix-proxy-update.sh uninstall   Remove script + cron job
#   sudo ./zabbix-proxy-update.sh update      Run update check immediately
#   sudo ./zabbix-proxy-update.sh status      Show current vs target version
#
# Dependencies: curl, apt, systemctl, dpkg
# Tested on: Ubuntu 22.04 / 24.04 with Zabbix repo packages
# =============================================================================

set -euo pipefail

# -- Configuration ------------------------------------------------------------
VERSION_URL="https://raw.githubusercontent.com/Lighthouse-IT-Github/TikLive/refs/heads/main/zblive"
ZABBIX_PROXY_PKG="zabbix-proxy-sqlite3"   # Change to zabbix-proxy-mysql if applicable
ZABBIX_SERVICE="zabbix-proxy"
HEALTH_CHECK_RETRIES=5
HEALTH_CHECK_INTERVAL=5                   # seconds between retries
ZABBIX_REPO_BASE="https://repo.zabbix.com/zabbix"

INSTALL_PATH="/usr/local/bin/zabbix-proxy-update.sh"
CRON_FILE="/etc/cron.d/zabbix-proxy-update"
LOG_FILE="/var/log/zabbix-proxy-update.log"
CRON_SCHEDULE="*/30 * * * *"               # Every 30 minutes

DPKG_VERSION_FMT='${Version}'
# ------------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

check_dependencies() {
    for cmd in curl apt dpkg systemctl lsb_release; do
        command -v "$cmd" &>/dev/null || die "Required command '$cmd' not found." 
    done
}

get_target_version() {
    local ver
    ver="$(curl -fsSL --max-time 30 "${VERSION_URL}" | tr -d '[:space:]')" 
    if [[ ! "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid version format retrieved: '${ver}'" 
    fi
    echo "${ver}"
}

get_installed_version() {
    if dpkg -l "${ZABBIX_PROXY_PKG}" &>/dev/null; then
        local raw
        raw="$(dpkg-query -W -f="${DPKG_VERSION_FMT}" "${ZABBIX_PROXY_PKG}" 2>/dev/null || true)"
        echo "${raw}" | sed -E 's/^[0-9]+://; s/-.*//'
    else
        echo "none"
    fi
}

# =============================================================================
# Command: install
# =============================================================================
cmd_install() {
    check_root
    log "-- Installing zabbix-proxy-update --"

    cp -f "$(readlink -f "$0")" "${INSTALL_PATH}"
    chmod 755 "${INSTALL_PATH}"
    log "Script installed to ${INSTALL_PATH}"

    printf '%s\n' \
        "# Zabbix proxy auto-update -- installed by zabbix-proxy-update.sh v1.2.0" \
        "SHELL=/bin/bash" \
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "${CRON_SCHEDULE} root ${INSTALL_PATH} update >> ${LOG_FILE} 2>&1" \
        > "${CRON_FILE}"
    chmod 644 "${CRON_FILE}"
    log "Cron job created at ${CRON_FILE} (schedule: ${CRON_SCHEDULE})"

    touch "${LOG_FILE}"
    chmod 640 "${LOG_FILE}"
    log "Log file: ${LOG_FILE}"

    echo ""
    log "-- Installation complete --"
    log "  The update check will run every 30 minutes."
    log "  To run immediately:  sudo zabbix-proxy-update.sh update"
    log "  To check versions:   sudo zabbix-proxy-update.sh status"
    log "  To remove:           sudo zabbix-proxy-update.sh uninstall"
}

# =============================================================================
# Command: uninstall
# =============================================================================
cmd_uninstall() {
    check_root
    log "-- Uninstalling zabbix-proxy-update --"

    if [[ -f "${CRON_FILE}" ]]; then
        rm -f "${CRON_FILE}"
        log "Removed cron job ${CRON_FILE}"
    else
        log "No cron job found (already removed)."
    fi

    if [[ -f "${INSTALL_PATH}" ]]; then
        rm -f "${INSTALL_PATH}"
        log "Removed ${INSTALL_PATH}"
    else
        log "Script not found at ${INSTALL_PATH} (already removed)."
    fi

    log "Log file left in place at ${LOG_FILE} (remove manually if desired)."
    log "-- Uninstall complete --"
}

# =============================================================================
# Command: status
# =============================================================================
cmd_status() {
    check_root
    check_dependencies

    local installed target
    installed="$(get_installed_version)"
    target="$(get_target_version)"

    echo ""
    echo "  Zabbix Proxy Update Status"
    echo "  -----------------------------"
    echo "  Installed version : ${installed}"
    echo "  Target version    : ${target}"
    if [[ "${installed}" == "${target}" ]]; then
        echo "  Status            : UP TO DATE"
    else
        echo "  Status            : UPDATE AVAILABLE"
    fi
    echo ""
    if [[ -f "${CRON_FILE}" ]]; then
        echo "  Cron job          : Active (${CRON_SCHEDULE})"
    else
        echo "  Cron job          : Not installed"
    fi
    echo "  Ubuntu codename   : $(lsb_release -cs)"
    echo ""
}

# =============================================================================
# Command: update
# =============================================================================
cmd_update() {
    check_root
    check_dependencies

    local UBUNTU_CODENAME
    UBUNTU_CODENAME="$(lsb_release -cs)"
    log "Detected Ubuntu codename: ${UBUNTU_CODENAME}"

    log "Fetching target version from ${VERSION_URL} ..."
    local TARGET_VERSION
    TARGET_VERSION="$(get_target_version)"
    log "Target version: ${TARGET_VERSION}"

    local INSTALLED_VERSION
    INSTALLED_VERSION="$(get_installed_version)"
    log "Installed version: ${INSTALLED_VERSION}"

    if [[ "${INSTALLED_VERSION}" == "${TARGET_VERSION}" ]]; then
        log "Already running target version ${TARGET_VERSION}. Nothing to do."
        exit 0
    fi

    log "Version mismatch: ${INSTALLED_VERSION} -> ${TARGET_VERSION}. Proceeding with update."

    local TARGET_MAJOR_MINOR
    TARGET_MAJOR_MINOR="$(echo "${TARGET_VERSION}" | cut -d. -f1,2)"
    log "Target repo branch: ${TARGET_MAJOR_MINOR}"

    local REPO_DEB_URL="${ZABBIX_REPO_BASE}/${TARGET_MAJOR_MINOR}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${TARGET_MAJOR_MINOR}+ubuntu${UBUNTU_CODENAME}_all.deb"
    local REPO_DEB_TMP="/tmp/zabbix-release_${TARGET_MAJOR_MINOR}.deb"

    log "Downloading Zabbix repo package: ${REPO_DEB_URL}"
    if ! curl -fsSL --max-time 60 -o "${REPO_DEB_TMP}" "${REPO_DEB_URL}"; then
        die "Failed to download Zabbix release package. Check that ${TARGET_MAJOR_MINOR} supports Ubuntu ${UBUNTU_CODENAME}."
    fi

    log "Installing Zabbix repo package ..."
    dpkg -i "${REPO_DEB_TMP}" || die "Failed to install Zabbix release .deb"
    rm -f "${REPO_DEB_TMP}"

    log "Running apt-get update ..."
    apt-get update -qq || die "apt-get update failed."

    log "Installing ${ZABBIX_PROXY_PKG} version ${TARGET_VERSION}* ..."
    if ! apt-get install -y -qq "${ZABBIX_PROXY_PKG}=${TARGET_VERSION}*" 2>/dev/null; then
        log "Retrying install with epoch prefix 1:${TARGET_VERSION}* ..."
        apt-get install -y -qq "${ZABBIX_PROXY_PKG}=1:${TARGET_VERSION}*" ||
            die "Failed to install ${ZABBIX_PROXY_PKG} version ${TARGET_VERSION}."
    fi

    local NEW_VERSION
    NEW_VERSION="$(get_installed_version)"

    if [[ "${NEW_VERSION}" != "${TARGET_VERSION}" ]]; then
        die "Post-install version mismatch. Expected ${TARGET_VERSION}, got ${NEW_VERSION}."
    fi

    log "Package version verified: ${NEW_VERSION}"

    log "Restarting ${ZABBIX_SERVICE} ..."
    systemctl restart "${ZABBIX_SERVICE}" || die "systemctl restart failed."

    log "Waiting for service to become healthy ..."
    local PID
    for ((i=1; i<=HEALTH_CHECK_RETRIES; i++)); do
        sleep "${HEALTH_CHECK_INTERVAL}"
        if systemctl is-active --quiet "${ZABBIX_SERVICE}"; then
            PID="$(systemctl show -p MainPID --value "${ZABBIX_SERVICE}" 2>/dev/null || true)"
            if [[ -n "${PID}" && "${PID}" -gt 0 ]] && kill -0 "${PID}" 2>/dev/null; then
                log "Service ${ZABBIX_SERVICE} is healthy (PID ${PID})."
                log "Update complete: ${INSTALLED_VERSION} -> ${TARGET_VERSION}"
                exit 0
            fi
        fi
        log "Health check attempt ${i}/${HEALTH_CHECK_RETRIES} -- service not yet stable."
    done

    die "Service ${ZABBIX_SERVICE} failed to stabilize after ${HEALTH_CHECK_RETRIES} attempts."
}

# =============================================================================
# Main -- route subcommand
# =============================================================================
usage() {
    echo ""
    echo "  Zabbix Proxy Auto-Update v1.2.0"
    echo "  --------------------------------"
    echo "  Usage: sudo $0 <command>"
    echo ""
    echo "  Commands:"
    echo "    install     Copy script to ${INSTALL_PATH} and create daily cron job"
    echo "    uninstall   Remove script and cron job"
    echo "    update      Check remote version and update proxy if needed"
    echo "    status      Show installed vs target version"
    echo ""
}

case "${1:-}" in
    install)    cmd_install   ;;
    uninstall)  cmd_uninstall ;;
    update)     cmd_update    ;;
    status)     cmd_status    ;;
    *)          usage         ;;
esac
