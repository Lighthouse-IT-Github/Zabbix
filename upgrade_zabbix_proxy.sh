#!/bin/bash

# Zabbix Proxy Upgrade Script (6.4 to 7.0 on Ubuntu 24.04)

# Stop the Zabbix proxy service
systemctl stop zabbix-proxy

# Clean up old downloaded files
rm zabbix-release_*.deb

# Backup the current Zabbix proxy configuration
cp /etc/zabbix/zabbix_proxy.conf /etc/zabbix/zabbix_proxy.conf.bak

# Remove the old Zabbix repository if it exists (Optional but recommended)
# This will prevent future accidental installations of 6.4 packages
rm -Rf /etc/apt/sources.list.d/zabbix.list

# Add the Zabbix repository for version 7.0 (Ubuntu 24.04)
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-1+ubuntu24.04_all.deb
dpkg -i zabbix-release_7.0-1+ubuntu24.04_all.deb
apt update

# Install the Zabbix proxy 7.0 package
apt install --only-upgrade zabbix-proxy-sqlite3

# Restore the backed-up configuration file. This is crucial as the new package might overwrite it.
cp /etc/zabbix/zabbix_proxy.conf.bak /etc/zabbix/zabbix_proxy.conf

# start the Zabbix proxy service
systemctl start zabbix-proxy

# Clean up downloaded files
rm zabbix-release_*.deb

echo "Zabbix Proxy upgrade complete."

exit 0
