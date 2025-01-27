#!/bin/bash

# Zabbix Proxy Upgrade Script (6.4 to 7.0 on Ubuntu 22.04)

# Stop the Zabbix proxy service
systemctl stop zabbix-proxy

# Clean up old downloaded files
rm zabbix-release_*.deb

#Set MySQL settings
mysql -u root -e "SET GLOBAL log_bin_trust_function_creators = 1;"

# Backup the current Zabbix proxy configuration
cp /etc/zabbix/zabbix_proxy.conf /etc/zabbix/zabbix_proxy.conf.bak

# Remove the old Zabbix repository if it exists (Optional but recommended)
# This will prevent future accidental installations of 6.4 packages
rm -Rf /etc/apt/sources.list.d/zabbix.list

# Add the Zabbix repository for version 7.0
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-1+ubuntu22.04_all.deb
dpkg -i zabbix-release_7.0-1+ubuntu22.04_all.deb
apt update

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

# start the Zabbix proxy service
systemctl start zabbix-proxy


# Clean up downloaded files
rm zabbix-release_*.deb

echo "Zabbix Proxy upgrade complete."

exit 0
