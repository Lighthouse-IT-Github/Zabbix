#!/bin/ash
# Zabbix Proxy + Agent2 Entrypoint v4.0.0-dev
# Supervises both processes, sshd always on, auto-update via crond
set -e

ZABBIX_DB_PATH="${ZBX_DBPATH:-/var/lib/zabbix/zabbix_proxy.db}"
ZABBIX_SCHEMA="/usr/share/zabbix/database/sqlite3/schema.sql"
PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
AGENT2_CONF="/etc/zabbix/zabbix_agent2.conf"
PROXY_BIN="/usr/sbin/zabbix_proxy"
AGENT2_BIN="/usr/sbin/zabbix_agent2"
PROXY_PID=0
AGENT2_PID=0

log() {
    echo "[entrypoint] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Graceful shutdown on container stop
cleanup() {
    log "Received shutdown signal, stopping..."
    [ $PROXY_PID -ne 0 ]  && kill "$PROXY_PID"  2>/dev/null || true
    [ $AGENT2_PID -ne 0 ] && kill "$AGENT2_PID" 2>/dev/null || true
    wait 2>/dev/null || true
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
echo "${UPDATE_SCHEDULE} /usr/local/bin/zabbix-update.sh update >> /var/log/zabbix-update.log 2>&1" \
    | crontab -
crond -b -l 8
log "Auto-update cron started (schedule: ${UPDATE_SCHEDULE})"

# -- Generate proxy config from environment variables --------------------------
if [ -n "$ZBX_SERVER_HOST" ]; then
    cat > "$PROXY_CONF" << EOF
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

    [ -n "$ZBX_TLSCONNECT" ]     && echo "TLSConnect=${ZBX_TLSCONNECT}"         >> "$PROXY_CONF"
    [ -n "$ZBX_TLSACCEPT" ]      && echo "TLSAccept=${ZBX_TLSACCEPT}"           >> "$PROXY_CONF"
    [ -n "$ZBX_TLSPSKIDENTITY" ] && echo "TLSPSKIdentity=${ZBX_TLSPSKIDENTITY}" >> "$PROXY_CONF"
    [ -n "$ZBX_TLSPSKFILE" ]     && echo "TLSPSKFile=${ZBX_TLSPSKFILE}"         >> "$PROXY_CONF"
    [ -n "$ZBX_TLSCAFILE" ]      && echo "TLSCAFile=${ZBX_TLSCAFILE}"           >> "$PROXY_CONF"
    [ -n "$ZBX_TLSCERTFILE" ]    && echo "TLSCertFile=${ZBX_TLSCERTFILE}"       >> "$PROXY_CONF"
    [ -n "$ZBX_TLSKEYFILE" ]     && echo "TLSKeyFile=${ZBX_TLSKEYFILE}"         >> "$PROXY_CONF"

    log "Proxy configuration generated from environment variables"
fi

# -- Generate agent2 config from environment variables -------------------------
# Agent2 reports to the LOCAL proxy (127.0.0.1) by default so it monitors
# the MikroTik host through the proxy it's colocated with.
AGENT2_SERVER="${ZBX_AGENT2_SERVER:-127.0.0.1}"
AGENT2_SERVERACTIVE="${ZBX_AGENT2_SERVERACTIVE:-127.0.0.1}"
AGENT2_HOSTNAME="${ZBX_AGENT2_HOSTNAME:-${ZBX_HOSTNAME:-$(hostname)}-agent}"
AGENT2_LISTENPORT="${ZBX_AGENT2_LISTENPORT:-10050}"

cat > "$AGENT2_CONF" << EOF
# Zabbix Agent2 Configuration - Auto-generated from environment
Server=${AGENT2_SERVER}
ServerActive=${AGENT2_SERVERACTIVE}
Hostname=${AGENT2_HOSTNAME}
ListenPort=${AGENT2_LISTENPORT}
LogType=console
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=0
DebugLevel=${ZBX_AGENT2_DEBUGLEVEL:-3}
ControlSocket=/var/run/zabbix/agent2.sock
EOF

[ -n "$ZBX_AGENT2_TLSCONNECT" ]     && echo "TLSConnect=${ZBX_AGENT2_TLSCONNECT}"         >> "$AGENT2_CONF"
[ -n "$ZBX_AGENT2_TLSACCEPT" ]      && echo "TLSAccept=${ZBX_AGENT2_TLSACCEPT}"           >> "$AGENT2_CONF"
[ -n "$ZBX_AGENT2_TLSPSKIDENTITY" ] && echo "TLSPSKIdentity=${ZBX_AGENT2_TLSPSKIDENTITY}" >> "$AGENT2_CONF"
[ -n "$ZBX_AGENT2_TLSPSKFILE" ]     && echo "TLSPSKFile=${ZBX_AGENT2_TLSPSKFILE}"         >> "$AGENT2_CONF"

log "Agent2 configuration generated (hostname: ${AGENT2_HOSTNAME})"

# -- Determine which services to run -------------------------------------------
# By default both run. Set DISABLE_AGENT2=true to run proxy only.
DISABLE_AGENT2_LOWER=$(echo "$DISABLE_AGENT2" | tr '[:upper:]' '[:lower:]')
RUN_AGENT2=true
if [ "$DISABLE_AGENT2_LOWER" = "true" ] || [ "$DISABLE_AGENT2" = "1" ]; then
    RUN_AGENT2=false
    log "Agent2 disabled via DISABLE_AGENT2 env var"
fi

# -- Supervised process loop ---------------------------------------------------
log "Starting supervised process loop (arch: $(uname -m))..."

start_proxy() {
    su-exec zabbix "$PROXY_BIN" -c "$PROXY_CONF" -f &
    PROXY_PID=$!
    log "zabbix_proxy started (PID ${PROXY_PID})"
}

start_agent2() {
    if [ "$RUN_AGENT2" = "true" ] && [ -x "$AGENT2_BIN" ]; then
        su-exec zabbix "$AGENT2_BIN" -c "$AGENT2_CONF" -f &
        AGENT2_PID=$!
        log "zabbix_agent2 started (PID ${AGENT2_PID})"
    fi
}

start_proxy
start_agent2

# Monitor both processes — restart whichever exits
while true; do
    # Wait for any child to exit
    wait -n 2>/dev/null || true

    # Check proxy
    if [ $PROXY_PID -ne 0 ] && ! kill -0 "$PROXY_PID" 2>/dev/null; then
        log "zabbix_proxy exited, restarting in 3s..."
        PROXY_PID=0
        sleep 3
        start_proxy
    fi

    # Check agent2
    if [ "$RUN_AGENT2" = "true" ] && [ $AGENT2_PID -ne 0 ] && ! kill -0 "$AGENT2_PID" 2>/dev/null; then
        log "zabbix_agent2 exited, restarting in 3s..."
        AGENT2_PID=0
        sleep 3
        start_agent2
    fi

    sleep 1
done
