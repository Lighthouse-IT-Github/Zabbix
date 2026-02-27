#!/bin/ash
set -e

ZABBIX_DB_PATH="${ZBX_DBPATH:-/var/lib/zabbix/zabbix_proxy.db}"
ZABBIX_SCHEMA="/usr/share/zabbix/database/sqlite3/schema.sql"

# Initialize SQLite database if it doesn't exist
if [ ! -f "$ZABBIX_DB_PATH" ]; then
    echo "Initializing Zabbix proxy SQLite database..."
    /usr/bin/sqlite3 "$ZABBIX_DB_PATH" < "$ZABBIX_SCHEMA"
    echo "Database initialized at $ZABBIX_DB_PATH"
fi

# Generate config from environment variables if ZBX_SERVER_HOST is set
if [ -n "$ZBX_SERVER_HOST" ]; then
    CONFIG_FILE="/etc/zabbix/zabbix_proxy.conf"
    
    cat > "$CONFIG_FILE" << EOF
# Zabbix Proxy Configuration - Auto-generated
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

    # Add TLS settings if configured
    if [ -n "$ZBX_TLSCONNECT" ]; then
        echo "TLSConnect=${ZBX_TLSCONNECT}" >> "$CONFIG_FILE"
    fi
    if [ -n "$ZBX_TLSACCEPT" ]; then
        echo "TLSAccept=${ZBX_TLSACCEPT}" >> "$CONFIG_FILE"
    fi
    if [ -n "$ZBX_TLSPSKIDENTITY" ]; then
        echo "TLSPSKIdentity=${ZBX_TLSPSKIDENTITY}" >> "$CONFIG_FILE"
    fi
    if [ -n "$ZBX_TLSPSKFILE" ]; then
        echo "TLSPSKFile=${ZBX_TLSPSKFILE}" >> "$CONFIG_FILE"
    fi
    if [ -n "$ZBX_TLSCAFILE" ]; then
        echo "TLSCAFile=${ZBX_TLSCAFILE}" >> "$CONFIG_FILE"
    fi
    if [ -n "$ZBX_TLSCERTFILE" ]; then
        echo "TLSCertFile=${ZBX_TLSCERTFILE}" >> "$CONFIG_FILE"
    fi
    if [ -n "$ZBX_TLSKEYFILE" ]; then
        echo "TLSKeyFile=${ZBX_TLSKEYFILE}" >> "$CONFIG_FILE"
    fi

    echo "Configuration generated from environment variables"
fi

exec "$@"
