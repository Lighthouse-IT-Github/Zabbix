#!/bin/bash
# Zabbix Proxy Post-Deployment Verification
# Usage: ssh zadmin@VM-IP 'bash -s' < Verify-ZabbixProxy.sh
PASS=0; FAIL=0
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  [PASS] $d"; ((PASS++)); else echo "  [FAIL] $d"; ((FAIL++)); fi; }

echo ""; echo "===== Zabbix Proxy Verification ====="
echo ""; echo "--- System ---"
check "Ubuntu OS"          test -f /etc/lsb-release
check "SSH running"        systemctl is-active ssh
check "Network"            ping -c1 -W3 8.8.8.8

echo ""; echo "--- Zabbix Proxy ---"
check "Package installed"  dpkg -l zabbix-proxy-sqlite3
check "Service enabled"    systemctl is-enabled zabbix-proxy
check "Service running"    systemctl is-active zabbix-proxy
check "Config exists"      test -f /etc/zabbix/zabbix_proxy.conf
check "SQLite DB exists"   test -f /var/lib/zabbix/zabbix_proxy.db
check "Listening on 10051" ss -tlnp | grep -q :10051

echo ""; echo "--- Configuration ---"
CONF="/etc/zabbix/zabbix_proxy.conf"
if [ -f "$CONF" ]; then
    grep -E "^(Server|Hostname|DBName)=" "$CONF" | sed 's/^/  /'
    PSK=$(grep -E "^TLSPSKFile=" "$CONF" 2>/dev/null | cut -d= -f2)
    [ -n "$PSK" ] && echo "  TLS PSK: Configured" || echo "  TLS PSK: Not configured"
    SERVER=$(grep -E "^Server=" "$CONF" | cut -d= -f2)
    [ -n "$SERVER" ] && check "Reach Zabbix Server" bash -c "echo '' | nc -w3 $SERVER 10051"
fi

echo ""; echo "--- Setup Log (last 5 lines) ---"
[ -f /var/log/zabbix-proxy-setup.log ] && tail -5 /var/log/zabbix-proxy-setup.log | sed 's/^/  /' || echo "  (not found)"
echo ""; echo "===== $PASS passed, $FAIL failed ====="
[ $FAIL -eq 0 ] && echo "All checks passed!" || echo "Some failed - wait for setup or check logs."
echo ""
