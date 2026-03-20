#!/usr/bin/env bash
# =============================================================================
# zabbix-proxy-update.sh v1.3.1
# =============================================================================
# Checks a remote version file and updates the local Zabbix proxy and agent
# to match. Auto-detects which agent is installed (zabbix-agent or
# zabbix-agent2). If no agent is found, installs zabbix-agent2.
#
# Usage:
#   sudo ./zabbix-proxy-update.sh install     Install script + cron job
#   sudo ./zabbix-proxy-update.sh uninstall   Remove script + cron job
#   sudo ./zabbix-proxy-update.sh update      Run update check immediately
#   sudo ./zabbix-proxy-update.sh status      Show current vs target version
#
# Dependencies: curl, apt, systemctl, dpkg
# Tested on: Ubuntu 22.04 / 24.04 with Zabbix repo packages
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# -- Configuration ------------------------------------------------------------
VERSION_URL="https://raw.githubusercontent.com/Lighthouse-IT-Github/TikLive/refs/heads/main/zblive"
ZABBIX_PROXY_PKG="zabbix-proxy-sqlite3"   # Change to zabbix-proxy-mysql if applicable
ZABBIX_AGENT_DEFAULT="zabbix-agent2"      # Installed if no agent is found
HEALTH_CHECK_RETRIES=5
HEALTH_CHECK_INTERVAL=5                   # seconds between retries
APT_LOCK_TIMEOUT=300                      # seconds to wait for apt lock (5 min)
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

# Wait for any running apt/dpkg processes to release their locks
wait_for_apt_lock() {
    local waited=0
    while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
        if [[ ${waited} -eq 0 ]]; then
            log "Waiting for apt lock (another package manager is running) ..."
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ ${waited} -ge ${APT_LOCK_TIMEOUT} ]]; then
            die "Timed out after ${APT_LOCK_TIMEOUT}s waiting for apt lock."
        fi
    done
    if [[ ${waited} -gt 0 ]]; then
        log "Apt lock released after ${waited}s."
    fi
}

get_target_version() {
    local ver
    ver="$(curl -fsSL --max-time 30 "${VERSION_URL}" | tr -d '[:space:]')"
    if [[ ! "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid version format retrieved: '${ver}'"
    fi
    echo "${ver}"
}

# Get bare version (e.g. "7.4.7") for any installed package
get_pkg_version() {
    local pkg="$1"
    if dpkg -l "${pkg}" &>/dev/null; then
        local raw
        raw="$(dpkg-query -W -f="${DPKG_VERSION_FMT}" "${pkg}" 2>/dev/null || true)"
        echo "${raw}" | sed -E 's/^[0-9]+://; s/-.*//'
    else
        echo "none"
    fi
}

# Detect which agent package is installed; returns package name or "none"
detect_agent_pkg() {
    if dpkg -l "zabbix-agent2" 2>/dev/null | grep -q "^ii"; then
        echo "zabbix-agent2"
    elif dpkg -l "zabbix-agent" 2>/dev/null | grep -q "^ii"; then
        echo "zabbix-agent"
    else
        echo "none"
    fi
}

# Get the systemd service name for an agent package
agent_service_name() {
    local pkg="$1"
    case "${pkg}" in
        zabbix-agent2) echo "zabbix-agent2" ;;
        zabbix-agent)  echo "zabbix-agent"  ;;
        *)             echo "" ;;
    esac
}

# Install or update a package to the target version
install_pkg() {
    local pkg="$1"
    local target_ver="$2"
    local APT_OPTS='-y -qq -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef'

    log "Installing ${pkg} version ${target_ver}* ..."
    wait_for_apt_lock
    if ! apt-get install ${APT_OPTS} "${pkg}=${target_ver}*" 2>/dev/null; then
        log "Retrying install with epoch prefix 1:${target_ver}* ..."
        apt-get install ${APT_OPTS} "${pkg}=1:${target_ver}*" ||
            die "Failed to install ${pkg} version ${target_ver}."
    fi

    local installed
    installed="$(get_pkg_version "${pkg}")"
    if [[ "${installed}" != "${target_ver}" ]]; then
        die "Post-install version mismatch for ${pkg}. Expected ${target_ver}, got ${installed}."
    fi
    log "Package ${pkg} verified: ${installed}"
}

# Restart a service and health-check it
restart_and_verify() {
    local svc="$1"

    log "Restarting ${svc} ..."
    systemctl restart "${svc}" || die "systemctl restart ${svc} failed."

    log "Waiting for ${svc} to become healthy ..."
    local PID
    for ((i=1; i<=HEALTH_CHECK_RETRIES; i++)); do
        sleep "${HEALTH_CHECK_INTERVAL}"
        if systemctl is-active --quiet "${svc}"; then
            PID="$(systemctl show -p MainPID --value "${svc}" 2>/dev/null || true)"
            if [[ -n "${PID}" && "${PID}" -gt 0 ]] && kill -0 "${PID}" 2>/dev/null; then
                log "Service ${svc} is healthy (PID ${PID})."
                return 0
            fi
        fi
        log "Health check attempt ${i}/${HEALTH_CHECK_RETRIES} -- ${svc} not yet stable."
    done

    die "Service ${svc} failed to stabilize after ${HEALTH_CHECK_RETRIES} attempts."
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
        "# Zabbix proxy/agent auto-update -- installed by zabbix-proxy-update.sh v1.3.1" \
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

    local proxy_ver target agent_pkg agent_ver agent_svc
    proxy_ver="$(get_pkg_version "${ZABBIX_PROXY_PKG}")"
    target="$(get_target_version)"
    agent_pkg="$(detect_agent_pkg)"

    if [[ "${agent_pkg}" != "none" ]]; then
        agent_ver="$(get_pkg_version "${agent_pkg}")"
    else
        agent_ver="not installed"
    fi

    echo ""
    echo "  Zabbix Update Status"
    echo "  -----------------------------"
    echo "  Target version    : ${target}"
    echo ""
    echo "  Proxy package     : ${ZABBIX_PROXY_PKG}"
    echo "  Proxy version     : ${proxy_ver}"
    if [[ "${proxy_ver}" == "${target}" ]]; then
        echo "  Proxy status      : UP TO DATE"
    else
        echo "  Proxy status      : UPDATE AVAILABLE"
    fi
    echo ""
    if [[ "${agent_pkg}" != "none" ]]; then
        echo "  Agent package     : ${agent_pkg}"
        echo "  Agent version     : ${agent_ver}"
        if [[ "${agent_ver}" == "${target}" ]]; then
            echo "  Agent status      : UP TO DATE"
        else
            echo "  Agent status      : UPDATE AVAILABLE"
        fi
    else
        echo "  Agent package     : none detected"
        echo "  Agent status      : WILL INSTALL ${ZABBIX_AGENT_DEFAULT}"
    fi
    echo ""
    if [[ -f "${CRON_FILE}" ]]; then
        echo "  Cron job          : Active (${CRON_SCHEDULE})"
    else
        echo "  Cron job          : Not installed"
    fi
    echo "  Ubuntu version    : $(lsb_release -rs)"
    echo ""
}

# =============================================================================
# Command: update
# =============================================================================
cmd_update() {
    check_root
    check_dependencies

    local UBUNTU_VERSION
    UBUNTU_VERSION="$(lsb_release -rs)"
    log "Detected Ubuntu version: ${UBUNTU_VERSION}"

    # -- Fetch target version --------------------------------------------------
    log "Fetching target version from ${VERSION_URL} ..."
    local TARGET_VERSION
    TARGET_VERSION="$(get_target_version)"
    log "Target version: ${TARGET_VERSION}"

    local TARGET_MAJOR_MINOR
    TARGET_MAJOR_MINOR="$(echo "${TARGET_VERSION}" | cut -d. -f1,2)"

    # -- Detect current state --------------------------------------------------
    local PROXY_VERSION
    PROXY_VERSION="$(get_pkg_version "${ZABBIX_PROXY_PKG}")"
    log "Proxy (${ZABBIX_PROXY_PKG}) installed version: ${PROXY_VERSION}"

    local AGENT_PKG
    AGENT_PKG="$(detect_agent_pkg)"
    local AGENT_VERSION="none"
    local AGENT_SERVICE=""

    if [[ "${AGENT_PKG}" != "none" ]]; then
        AGENT_VERSION="$(get_pkg_version "${AGENT_PKG}")"
        AGENT_SERVICE="$(agent_service_name "${AGENT_PKG}")"
        log "Agent (${AGENT_PKG}) installed version: ${AGENT_VERSION}"
    else
        AGENT_PKG="${ZABBIX_AGENT_DEFAULT}"
        AGENT_SERVICE="$(agent_service_name "${AGENT_PKG}")"
        log "No agent detected. Will install ${AGENT_PKG}."
    fi

    # -- Check if anything needs updating --------------------------------------
    local PROXY_NEEDS_UPDATE=false
    local AGENT_NEEDS_UPDATE=false

    if [[ "${PROXY_VERSION}" != "${TARGET_VERSION}" ]]; then
        PROXY_NEEDS_UPDATE=true
    fi
    if [[ "${AGENT_VERSION}" != "${TARGET_VERSION}" ]]; then
        AGENT_NEEDS_UPDATE=true
    fi

    if [[ "${PROXY_NEEDS_UPDATE}" == false && "${AGENT_NEEDS_UPDATE}" == false ]]; then
        log "Proxy and agent are both at target version ${TARGET_VERSION}. Nothing to do."
        exit 0
    fi

    # -- Update APT repository if anything needs updating ----------------------
    log "Target repo branch: ${TARGET_MAJOR_MINOR}"

    local REPO_DEB_URL="${ZABBIX_REPO_BASE}/${TARGET_MAJOR_MINOR}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${TARGET_MAJOR_MINOR}+ubuntu${UBUNTU_VERSION}_all.deb"
    local REPO_DEB_TMP="/tmp/zabbix-release_${TARGET_MAJOR_MINOR}.deb"

    log "Downloading Zabbix repo package: ${REPO_DEB_URL}"
    if ! curl -fsSL --max-time 60 -o "${REPO_DEB_TMP}" "${REPO_DEB_URL}"; then
        die "Failed to download Zabbix release package. Check that ${TARGET_MAJOR_MINOR} supports Ubuntu ${UBUNTU_VERSION}."
    fi

    log "Installing Zabbix repo package ..."
    wait_for_apt_lock
    dpkg -i "${REPO_DEB_TMP}" || die "Failed to install Zabbix release .deb"
    rm -f "${REPO_DEB_TMP}"

    log "Running apt-get update ..."
    wait_for_apt_lock
    apt-get update -qq || die "apt-get update failed."

    # -- Update proxy ----------------------------------------------------------
    if [[ "${PROXY_NEEDS_UPDATE}" == true ]]; then
        log "Proxy: ${PROXY_VERSION} -> ${TARGET_VERSION}"
        install_pkg "${ZABBIX_PROXY_PKG}" "${TARGET_VERSION}"
        restart_and_verify "zabbix-proxy"
        log "Proxy update complete."
    else
        log "Proxy already at ${TARGET_VERSION}. Skipping."
    fi

    # -- Update / install agent ------------------------------------------------
    if [[ "${AGENT_NEEDS_UPDATE}" == true ]]; then
        if [[ "${AGENT_VERSION}" == "none" ]]; then
            log "Agent: installing ${AGENT_PKG} ${TARGET_VERSION} (new install)"
        else
            log "Agent: ${AGENT_VERSION} -> ${TARGET_VERSION}"
        fi
        install_pkg "${AGENT_PKG}" "${TARGET_VERSION}"
        systemctl enable "${AGENT_SERVICE}" 2>/dev/null || true
        restart_and_verify "${AGENT_SERVICE}"
        log "Agent update complete."
    else
        log "Agent already at ${TARGET_VERSION}. Skipping."
    fi

    log "All updates complete."
}

# =============================================================================
# Main -- route subcommand
# =============================================================================
usage() {
    echo ""
    echo "  Zabbix Proxy/Agent Auto-Update v1.3.1"
    echo "  ----------------------------------------"
    echo "  Usage: sudo $0 <command>"
    echo ""
    echo "  Commands:"
    echo "    install     Copy script to ${INSTALL_PATH} and create cron job"
    echo "    uninstall   Remove script and cron job"
    echo "    update      Check remote version and update proxy + agent if needed"
    echo "    status      Show installed vs target version for proxy and agent"
    echo ""
}

case "${1:-}" in
    install)    cmd_install   ;;
    uninstall)  cmd_uninstall ;;
    update)     cmd_update    ;;
    status)     cmd_status    ;;
    *)          usage         ;;
esac
