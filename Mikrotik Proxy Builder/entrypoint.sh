#!/bin/ash
# Zabbix Proxy Entrypoint v3.1.0
# sshd always on, auto-update via crond, supervised proxy loop
set -e

ZABBIX_DB_PATH="${ZBX_DBPATH:-/var/lib/zabbix/zabbix_proxy.db}"
ZABBIX_SCHEMA="/usr/share/zabbix/database/sqlite3/schema.sql"
ZABBIX_CONF="/etc/zabbix/zabbix_proxy.conf"
PROXY_BIN="/usr/sbin/zabbix_proxy"
PROXY_PID=0

log() {
    echo "[entrypoint] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Graceful shutdown on container stop
cleanup() {
    log "Received shutdown signal, stopping..."
    if [ $PROXY_PID -ne 0 ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup TERM INT

# -- Initialize SQLite database -----------------------------------------------
if [ ! -f "$ZABBIX_DB_PATH" ]; then
    log "Initializing Zabbix proxy SQLite database..."
    /usr/bin/sqlite3 "$ZABBIX_DB_PATH" < "$ZABBIX_SCHEMA"
    chown zabbix:zabbix "$ZABBIX_DB_PATH"
    log "Database initialized at $ZABBIX_DB_PATH"
fi

# -- Start SSH daemon (always on) ---------------------------------------------
ROOT_PASS="${SSH_ROOT_PASSWORD:-zabbix}"
echo "root:${ROOT_PASS}" | chpasswd
/usr/sbin/sshd
if [ -n "$SSH_ROOT_PASSWORD" ]; then
    log "SSH daemon started (custom root password set)"
else
    log "SSH daemon started (default root password: zabbix)"
fi

# -- Start crond for auto-updates ---------------------------------------------
UPDATE_SCHEDULE="${UPDATE_SCHEDULE:-*/30 * * * *}"
mkdir -p /var/log
echo "${UPDATE_SCHEDULE} /usr/local/bin/zabbix-proxy-update.sh update >> /var/log/zabbix-proxy-update.log 2>&1" \
    | crontab -
crond -b -l 8
log "Auto-update cron started (schedule: ${UPDATE_SCHEDULE})"

# -- Generate config from environment variables --------------------------------
if [ -n "$ZBX_SERVER_HOST" ]; then
    cat > "$ZABBIX_CONF" << EOF
# Zabbix Proxy Configuration - Auto-generated from environment
ProxyMode=${ZBX_PROXYMODE:-0}
Server=${ZBX_SERVER_HOST}
Hostname=${ZBX_HOSTNAME:-$(hostname)}
ListenPort=${ZBX_LISTENPORT:-10051}
LogType=console
LogFile=/var/log/zabbix/zabbix_proxy.log
LogFileSize=0
DebugLevel=${ZBX_DEBUGLEVEL:-3}
DBName=${ZABBIX_DB_PATH}
ProxyLocalBuffer=${ZBX_PROXYLOCALBUFFER:-0}
ProxyOfflineBuffer=${ZBX_PROXYOFFLINEBUFFER:-1}
HeartbeatFrequency=${ZBX_HEARTBEATFREQUENCY:-60}
ConfigFrequency=${ZBX_CONFIGFREQUENCY:-60}
DataSenderFrequency=${ZBX_DATASENDERFREQUENCY:-1}
StartPollers=${ZBX_STARTPOLLERS:-5}
StartPollersUnreachable=${ZBX_STARTPOLLERSUNREACHABLE:-1}
StartTrappers=${ZBX_STARTTRAPPERS:-5}
StartPingers=${ZBX_STARTPINGERS:-1}
StartDiscoverers=${ZBX_STARTDISCOVERERS:-1}
CacheSize=${ZBX_CACHESIZE:-8M}
HistoryCacheSize=${ZBX_HISTORYCACHESIZE:-16M}
HistoryIndexCacheSize=${ZBX_HISTORYINDEXCACHESIZE:-4M}
Timeout=${ZBX_TIMEOUT:-4}
TrapperTimeout=${ZBX_TRAPPERTIMEOUT:-300}
UnreachablePeriod=${ZBX_UNREACHABLEPERIOD:-45}
UnavailableDelay=${ZBX_UNAVAILABLEDELAY:-60}
UnreachableDelay=${ZBX_UNREACHABLEDELAY:-15}
EOF

    [ -n "$ZBX_TLSCONNECT" ]     && echo "TLSConnect=${ZBX_TLSCONNECT}"         >> "$ZABBIX_CONF"
    [ -n "$ZBX_TLSACCEPT" ]      && echo "TLSAccept=${ZBX_TLSACCEPT}"           >> "$ZABBIX_CONF"
    [ -n "$ZBX_TLSPSKIDENTITY" ] && echo "TLSPSKIdentity=${ZBX_TLSPSKIDENTITY}" >> "$ZABBIX_CONF"
    [ -n "$ZBX_TLSPSKFILE" ]     && echo "TLSPSKFile=${ZBX_TLSPSKFILE}"         >> "$ZABBIX_CONF"
    [ -n "$ZBX_TLSCAFILE" ]      && echo "TLSCAFile=${ZBX_TLSCAFILE}"           >> "$ZABBIX_CONF"
    [ -n "$ZBX_TLSCERTFILE" ]    && echo "TLSCertFile=${ZBX_TLSCERTFILE}"       >> "$ZABBIX_CONF"
    [ -n "$ZBX_TLSKEYFILE" ]     && echo "TLSKeyFile=${ZBX_TLSKEYFILE}"         >> "$ZABBIX_CONF"

    log "Configuration generated from environment variables"
fi

# -- Supervised proxy loop -----------------------------------------------------
log "Starting zabbix_proxy supervised loop (arch: $(uname -m))..."

while true; do
    su-exec zabbix "$PROXY_BIN" -c "$ZABBIX_CONF" -f &
    PROXY_PID=$!
    log "zabbix_proxy started (PID ${PROXY_PID})"

    wait "$PROXY_PID" || true
    EXIT_CODE=$?
    PROXY_PID=0

    log "zabbix_proxy exited (code ${EXIT_CODE}), restarting in 3s..."
    sleep 3
done
