#!/bin/bash

# Zabbix Proxy Upgrade Script (6.4 to 7.0 on Ubuntu 22.04)

# Stop the Zabbix proxy service
systemctl stop zabbix-proxy

# Backup the current Zabbix proxy configuration
cp /etc/zabbix/zabbix_proxy.conf /etc/zabbix/zabbix_proxy.conf.bak

# Add the Zabbix repository for version 7.0
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-1+ubuntu22.04_all.deb
dpkg -i zabbix-release_7.0-1+ubuntu22.04_all.deb
apt update

# Remove the old Zabbix repository if it exists (Optional but recommended)
# This will prevent future accidental installations of 6.4 packages
if grep -q "deb http://repo.zabbix.com/zabbix/6.4/ubuntu" /etc/apt/sources.list.d/zabbix.list; then
    sed -i '/deb http:\/\/repo.zabbix.com\/zabbix\/6.4\/ubuntu/d' /etc/apt/sources.list.d/zabbix.list
    apt update
fi

# Install the Zabbix proxy 7.0 package
apt install --only-upgrade zabbix-proxy-mysql

# Check the database schema version and upgrade if necessary
if mysql -u root -e "SELECT schema_version FROM zabbix.dbconfig;" | grep -q "7.0"; then
  echo "Database schema is already at 7.0. Skipping database upgrade."
else
  echo "Upgrading database schema..."
  zabbix_db_upgrade -u root zabbix
fi

# Restore the backed-up configuration file. This is crucial as the new package might overwrite it.
cp /etc/zabbix/zabbix_proxy.conf.bak /etc/zabbix/zabbix_proxy.conf

# Check if the Server parameter in the configuration file is correct.
# If you use hostname, make sure it resolves correctly.
SERVER=$(grep "Server=" /etc/zabbix/zabbix_proxy.conf | cut -d '=' -f 2 | tr -d ' ')
echo "Zabbix Server configured as: $SERVER"
if [ -z "$SERVER" ]; then
    echo "ERROR: Server parameter is missing in zabbix_proxy.conf. Please configure it."
    exit 1
fi

# Restart the Zabbix proxy service
systemctl restart zabbix-proxy

# Check the status of the Zabbix proxy service
systemctl status zabbix-proxy

# Clean up downloaded files
rm zabbix-release_*.deb

echo "Zabbix Proxy upgrade complete."

exit 0
