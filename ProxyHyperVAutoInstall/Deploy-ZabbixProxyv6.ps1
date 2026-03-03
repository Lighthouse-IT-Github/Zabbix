#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Automated deployment of a Zabbix Proxy VM on Hyper-V with Ubuntu Server.

.DESCRIPTION
    This script:
    1. Creates a Hyper-V Gen2 VM (2 vCPU, 4GB RAM)
    2. Generates a cloud-init autoinstall ISO for unattended Ubuntu install
    3. Embeds Zabbix Proxy (SQLite) setup into the first-boot provisioning
    4. Boots the VM and lets it self-provision end-to-end

.NOTES
    Run from an elevated PowerShell prompt on a Windows 11 machine with Hyper-V enabled.
    Requires an Ubuntu Server 22.04+ ISO (autoinstall-capable).
#>

# ----------------------------------------------------------------------
#  Configuration / User Prompts
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Zabbix Proxy - Hyper-V Deployment Script"   -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# --- VM Name ---
$VMName = Read-Host "Enter VM name (e.g. ZBPROXY-SITE01)"
if ([string]::IsNullOrWhiteSpace($VMName)) {
    Write-Host "VM name cannot be empty. Exiting." -ForegroundColor Red
    exit 1
}

# --- Zabbix Version ---
$ZabbixVersionInput = Read-Host "Enter Zabbix version [default: 7.4.7]"
if ([string]::IsNullOrWhiteSpace($ZabbixVersionInput)) {
    $ZabbixVersion = "7.4.7"
} else {
    $ZabbixVersion = $ZabbixVersionInput.Trim()
}

# Derive the major.minor for the repo URL (e.g., 7.4.7 -> 7.4)
$ZabbixMajorMinor = ($ZabbixVersion -split '\.')[0..1] -join '.'

# --- Zabbix Server Address ---
$ZabbixServer = Read-Host "Enter Zabbix Server/Cluster address (IP or FQDN)"
if ([string]::IsNullOrWhiteSpace($ZabbixServer)) {
    Write-Host "Zabbix Server address is required. Exiting." -ForegroundColor Red
    exit 1
}

# --- Proxy Hostname ---
$ProxyHostname = Read-Host "Enter Zabbix Proxy hostname as it appears in Zabbix [default: $VMName]"
if ([string]::IsNullOrWhiteSpace($ProxyHostname)) {
    $ProxyHostname = $VMName
}

# --- Network Config ---
Write-Host ""
Write-Host "Network Configuration:" -ForegroundColor Yellow
$NetworkType = Read-Host "Use DHCP or Static IP? (dhcp/static) [default: dhcp]"
if ($NetworkType -eq "static") {
    $StaticIP = Read-Host "  IP Address (CIDR, e.g. 192.168.1.50/24)"
    $Gateway  = Read-Host "  Gateway"
    $DNS      = Read-Host "  DNS Server(s) (comma-separated)"
} else {
    $NetworkType = "dhcp"
}

# --- Hyper-V Virtual Switch ---
$VMSwitches = Get-VMSwitch | Select-Object -ExpandProperty Name
if ($VMSwitches.Count -eq 0) {
    Write-Host "No Hyper-V virtual switches found. Create one first." -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "Available Virtual Switches:" -ForegroundColor Yellow
for ($i = 0; $i -lt $VMSwitches.Count; $i++) {
    Write-Host "  [$i] $($VMSwitches[$i])"
}
$SwitchIndex = Read-Host "Select switch number [default: 0]"
if ([string]::IsNullOrWhiteSpace($SwitchIndex)) { $SwitchIndex = 0 }
$VMSwitch = $VMSwitches[[int]$SwitchIndex]

# --- Ubuntu ISO ---
$UbuntuISO = Read-Host "Full path to Ubuntu Server ISO (22.04 or 24.04)"
if (-not (Test-Path $UbuntuISO)) {
    Write-Host "ISO not found at '$UbuntuISO'. Exiting." -ForegroundColor Red
    exit 1
}

# --- Admin Credentials ---
$AdminUser = Read-Host "VM admin username [default: zadmin]"
if ([string]::IsNullOrWhiteSpace($AdminUser)) { $AdminUser = "zadmin" }

$AdminPasswordSecure = Read-Host "VM admin password" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPasswordSecure)
$AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

# Generate SHA-512 crypt hash for autoinstall identity section
$AdminPasswordHash = $null

# Try openssl (ships with Git for Windows, available in WSL)
$opensslPaths = @(
    "openssl",
    "C:\Program Files\Git\usr\bin\openssl.exe",
    "C:\Program Files (x86)\Git\usr\bin\openssl.exe",
    "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
)
foreach ($oPath in $opensslPaths) {
    try {
        $result = echo $AdminPassword | & $oPath passwd -6 -stdin 2>$null
        if ($result -and $result -match '^\$6\$') {
            $AdminPasswordHash = $result.Trim()
            Write-Host "  Password hashed via openssl." -ForegroundColor Gray
            break
        }
    } catch { }
}

# Try Python as fallback
if (-not $AdminPasswordHash) {
    foreach ($pyCmd in @("python3", "python", "py")) {
        try {
            $escapedPw = $AdminPassword -replace "'", "\\'"
            $pyScript = "import crypt; print(crypt.crypt('$escapedPw', crypt.mksalt(crypt.METHOD_SHA512)))"
            $result = & $pyCmd -c $pyScript 2>$null
            if ($result -and $result -match '^\$6\$') {
                $AdminPasswordHash = $result.Trim()
                Write-Host "  Password hashed via Python." -ForegroundColor Gray
                break
            }
        } catch { }
    }
}

# Fallback: use a dummy hash - the chpasswd late-command will set the real password
if (-not $AdminPasswordHash) {
    Write-Host "  No openssl or python found for hashing." -ForegroundColor Yellow
    Write-Host "  Password will be set via chpasswd during first boot." -ForegroundColor Yellow
    $AdminPasswordHash = "`$6`$fallback`$x"
}

# --- PSK (optional) ---
Write-Host ""
$UsePSK = Read-Host "Configure TLS PSK encryption? (y/n) [default: y]"
if ($UsePSK -ne "n") {
    $PSKIdentity = Read-Host "  PSK Identity [default: $ProxyHostname]"
    if ([string]::IsNullOrWhiteSpace($PSKIdentity)) { $PSKIdentity = $ProxyHostname }

    # Generate a random 256-bit hex PSK
    $PSKValue = -join ((1..32) | ForEach-Object { "{0:x2}" -f (Get-Random -Maximum 256) })
    Write-Host "  Generated PSK: $PSKValue" -ForegroundColor Green
    Write-Host "  ** Save this PSK -- you need it when adding the proxy in Zabbix **" -ForegroundColor Yellow
} else {
    $PSKIdentity = ""
    $PSKValue    = ""
}

# ----------------------------------------------------------------------
#  Paths & Constants
# ----------------------------------------------------------------------

$BasePath      = "C:\Lighthouse\ZBProxy"
$VMPath        = Join-Path $BasePath $VMName
$VHDPath       = Join-Path $VMPath "$VMName.vhdx"
$SeedISOPath   = Join-Path $VMPath "seed.iso"
$TempSeedDir   = Join-Path $env:TEMP "zbproxy-seed-$VMName"
$RAMBytes      = 4GB
$VCPUCount     = 2
$DiskSizeBytes = 60GB

# ----------------------------------------------------------------------
#  Build Autoinstall user-data YAML
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Generating autoinstall configuration..." -ForegroundColor Cyan

# Network section
if ($NetworkType -eq "static") {
    $NetworkYAML = @"
  network:
    version: 2
    ethernets:
      eth0:
        match:
          name: "e*"
        addresses:
          - $StaticIP
        routes:
          - to: default
            via: $Gateway
        nameservers:
          addresses: [$($DNS -replace '\s','')]
"@
} else {
    $NetworkYAML = @"
  network:
    version: 2
    ethernets:
      eth0:
        match:
          name: "e*"
        dhcp4: true
"@
}

# PSK config lines for the setup script
if ($PSKValue -ne "") {
    $PSKConfigLines = @"
echo '$PSKValue' > /etc/zabbix/zabbix_proxy.psk
chmod 640 /etc/zabbix/zabbix_proxy.psk
chown zabbix:zabbix /etc/zabbix/zabbix_proxy.psk
sed -i 's|^# TLSConnect=.*|TLSConnect=psk|' /etc/zabbix/zabbix_proxy.conf
sed -i 's|^# TLSAccept=.*|TLSAccept=psk|' /etc/zabbix/zabbix_proxy.conf
sed -i 's|^# TLSPSKIdentity=.*|TLSPSKIdentity=$PSKIdentity|' /etc/zabbix/zabbix_proxy.conf
sed -i 's|^# TLSPSKFile=.*|TLSPSKFile=/etc/zabbix/zabbix_proxy.psk|' /etc/zabbix/zabbix_proxy.conf
"@
} else {
    $PSKConfigLines = "# PSK not configured"
}

$UserData = @"
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
    variant: ""
    toggle: null
$NetworkYAML
  apt:
    geoip: true
    preserve_sources_list: false
  identity:
    hostname: $($VMName.ToLower())
    username: $AdminUser
    password: "$AdminPasswordHash"
  storage:
    layout:
      name: lvm
      sizing-policy: all
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - openssh-server
    - curl
    - wget
    - gnupg2
    - sqlite3
    - linux-tools-virtual
    - linux-cloud-tools-virtual
  late-commands:
    - curtin in-target -- bash -c "echo '${AdminUser}:${AdminPassword}' | chpasswd"
    - |
      cat << 'ZBXEOF' > /target/opt/setup-zabbix-proxy.sh
      #!/bin/bash
      set -euo pipefail
      exec > /var/log/zabbix-proxy-setup.log 2>&1

      echo "=== Zabbix Proxy Setup Starting ==="
      date

      ZABBIX_VERSION="$ZabbixVersion"
      ZABBIX_MAJOR_MINOR="$ZabbixMajorMinor"
      ZABBIX_SERVER="$ZabbixServer"
      PROXY_HOSTNAME="$ProxyHostname"

      # Detect Ubuntu codename
      CODENAME=`$(lsb_release -cs)
      UBUNTU_VER=`$(lsb_release -rs)

      echo "Installing Zabbix `${ZABBIX_VERSION} (repo `${ZABBIX_MAJOR_MINOR}) on Ubuntu `${CODENAME} (`${UBUNTU_VER})..."

      # Add Zabbix repo
      wget -q "https://repo.zabbix.com/zabbix/`${ZABBIX_MAJOR_MINOR}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_`${ZABBIX_MAJOR_MINOR}+ubuntu`${UBUNTU_VER}_all.deb" \
           -O /tmp/zabbix-release.deb || {
        echo "WARN: Exact version .deb not found, trying latest..."
        wget -q "https://repo.zabbix.com/zabbix/`${ZABBIX_MAJOR_MINOR}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu`${UBUNTU_VER}_all.deb" \
             -O /tmp/zabbix-release.deb
      }

      dpkg -i /tmp/zabbix-release.deb
      apt-get update -y

      # Install Zabbix Proxy (SQLite)
      apt-get install -y zabbix-proxy-sqlite3

      # Backup and configure
      cp /etc/zabbix/zabbix_proxy.conf /etc/zabbix/zabbix_proxy.conf.bak

      sed -i "s|^Server=.*|Server=$ZabbixServer|"       /etc/zabbix/zabbix_proxy.conf
      sed -i "s|^Hostname=.*|Hostname=$ProxyHostname|"   /etc/zabbix/zabbix_proxy.conf

      # Set SQLite DB path
      sed -i "s|^# DBName=.*|DBName=/var/lib/zabbix/zabbix_proxy.db|" /etc/zabbix/zabbix_proxy.conf
      sed -i "s|^DBName=.*|DBName=/var/lib/zabbix/zabbix_proxy.db|"   /etc/zabbix/zabbix_proxy.conf

      # Tuning — sensible defaults for a proxy
      sed -i 's|^# StartPollers=.*|StartPollers=10|'                     /etc/zabbix/zabbix_proxy.conf
      sed -i 's|^# StartPollersUnreachable=.*|StartPollersUnreachable=5|' /etc/zabbix/zabbix_proxy.conf
      sed -i 's|^# CacheSize=.*|CacheSize=64M|'                         /etc/zabbix/zabbix_proxy.conf
      sed -i 's|^# HistoryCacheSize=.*|HistoryCacheSize=32M|'           /etc/zabbix/zabbix_proxy.conf
      sed -i 's|^# ConfigFrequency=.*|ConfigFrequency=300|'             /etc/zabbix/zabbix_proxy.conf
      sed -i 's|^# DataSenderFrequency=.*|DataSenderFrequency=5|'       /etc/zabbix/zabbix_proxy.conf
      sed -i 's|^# HeartbeatFrequency=.*|HeartbeatFrequency=60|'        /etc/zabbix/zabbix_proxy.conf

      # DB directory
      mkdir -p /var/lib/zabbix
      chown zabbix:zabbix /var/lib/zabbix

      # PSK Configuration
      $PSKConfigLines

      # Enable and start
      systemctl enable zabbix-proxy
      systemctl start zabbix-proxy

      echo "=== Zabbix Proxy Setup Complete ==="
      date
      systemctl status zabbix-proxy --no-pager || true

      # Self-disable after success
      systemctl disable zabbix-proxy-setup.service
      ZBXEOF
    - chmod +x /target/opt/setup-zabbix-proxy.sh
    - |
      cat << 'SVCEOF' > /target/etc/systemd/system/zabbix-proxy-setup.service
      [Unit]
      Description=Zabbix Proxy First-Boot Setup
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=/opt/setup-zabbix-proxy.sh

      [Service]
      Type=oneshot
      ExecStart=/opt/setup-zabbix-proxy.sh
      RemainAfterExit=yes
      TimeoutStartSec=600
      StandardOutput=journal
      StandardError=journal

      [Install]
      WantedBy=multi-user.target
      SVCEOF
    - curtin in-target -- systemctl enable zabbix-proxy-setup.service
"@

# ----------------------------------------------------------------------
#  Build cloud-init seed ISO using IMAPI2 (built into Windows)
# ----------------------------------------------------------------------

# Add C# helper to write COM IStream to file (IMAPI2 returns a COM IStream
# that PowerShell cannot call .Read() on directly)
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public class ISOStreamHelper {
    public static void WriteIStreamToFile(object comStream, string filePath) {
        IStream stream = (IStream)comStream;
        using (FileStream fs = new FileStream(filePath, FileMode.Create, FileAccess.Write)) {
            byte[] buffer = new byte[65536];
            while (true) {
                IntPtr bytesReadPtr = Marshal.AllocHGlobal(sizeof(long));
                Marshal.WriteInt64(bytesReadPtr, 0);
                stream.Read(buffer, buffer.Length, bytesReadPtr);
                int bytesRead = (int)Marshal.ReadInt64(bytesReadPtr);
                Marshal.FreeHGlobal(bytesReadPtr);
                if (bytesRead == 0) { break; }
                fs.Write(buffer, 0, bytesRead);
            }
        }
    }
}
"@

function New-SeedISO {
    param(
        [string]$OutputPath,
        [string]$SourceDir
    )

    Write-Host "Creating seed ISO at $OutputPath..." -ForegroundColor Cyan

    # Try oscdimg first (Windows ADK)
    $oscdimg = $null
    $adkPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($p in $adkPaths) {
        if (Test-Path $p) { $oscdimg = $p; break }
    }
    if (-not $oscdimg) {
        $found = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
        if ($found) { $oscdimg = $found.Source }
    }

    if ($oscdimg) {
        Write-Host "  Using oscdimg.exe..." -ForegroundColor Gray
        & $oscdimg -lCIDATA -j1 $SourceDir $OutputPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "oscdimg failed (exit $LASTEXITCODE)" }
        return
    }

    # Fallback: IMAPI2 COM objects (available on all Windows 10/11)
    Write-Host "  Using IMAPI2 (built-in Windows)..." -ForegroundColor Gray

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    # FsiFileSystemISO9660=1, FsiFileSystemJoliet=2, both=3
    $fsi.FileSystemsToCreate = 3
    $fsi.VolumeName = "CIDATA"

    # Add entire directory tree
    $fsi.Root.AddTree($SourceDir, $false)

    $result    = $fsi.CreateResultImage()
    $imgStream = $result.ImageStream

    # Use C# helper to write the COM IStream to disk
    [ISOStreamHelper]::WriteIStreamToFile($imgStream, $OutputPath)

    # Cleanup COM objects
    [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($imgStream) | Out-Null
    [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($result) | Out-Null
    [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($fsi) | Out-Null

    Write-Host "  Seed ISO created." -ForegroundColor Green
}

# ----------------------------------------------------------------------
#  Create Directories & Seed ISO
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Creating directory structure..." -ForegroundColor Cyan

New-Item -ItemType Directory -Path $VMPath     -Force | Out-Null
New-Item -ItemType Directory -Path $TempSeedDir -Force | Out-Null

# Write cloud-init files (UTF-8 no BOM)
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $TempSeedDir "user-data"), $UserData, $Utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $TempSeedDir "meta-data"),
    "instance-id: $($VMName.ToLower())`nlocal-hostname: $($VMName.ToLower())", $Utf8NoBom)

# Build the seed ISO
New-SeedISO -OutputPath $SeedISOPath -SourceDir $TempSeedDir

# Cleanup temp
Remove-Item -Path $TempSeedDir -Recurse -Force

# ----------------------------------------------------------------------
#  Create the Hyper-V VM
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Creating Hyper-V VM '$VMName'..." -ForegroundColor Cyan

# Check for existing VM
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "VM '$VMName' already exists!" -ForegroundColor Red
    $Overwrite = Read-Host "Remove existing VM and recreate? (y/n)"
    if ($Overwrite -eq "y") {
        Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $VMName -Force
        if (Test-Path $VHDPath) { Remove-Item $VHDPath -Force }
    } else {
        Write-Host "Exiting." -ForegroundColor Yellow
        exit 0
    }
}

# Create Gen 2 VM
New-VM -Name $VMName `
       -Path $BasePath `
       -Generation 2 `
       -MemoryStartupBytes $RAMBytes `
       -SwitchName $VMSwitch `
       -NewVHDPath $VHDPath `
       -NewVHDSizeBytes $DiskSizeBytes

# Configure resources
Set-VM -Name $VMName `
       -ProcessorCount $VCPUCount `
       -DynamicMemory `
       -MemoryMinimumBytes 2GB `
       -MemoryMaximumBytes 4GB `
       -AutomaticStartAction Start `
       -AutomaticStopAction ShutDown `
       -CheckpointType Disabled

# Disable Secure Boot (required for Ubuntu ISO boot)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Attach Ubuntu ISO (primary DVD)
Add-VMDvdDrive -VMName $VMName -Path $UbuntuISO

# Attach seed ISO (secondary DVD — cloud-init picks this up)
Add-VMDvdDrive -VMName $VMName -Path $SeedISOPath

# Set boot order: DVD first, then HDD
$DVD = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $UbuntuISO } | Select-Object -First 1
$HDD = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
Set-VMFirmware -VMName $VMName -BootOrder $DVD, $HDD

# Enable Hyper-V guest services
Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"

Write-Host "VM created successfully." -ForegroundColor Green

# ----------------------------------------------------------------------
#  Save Deployment Summary
# ----------------------------------------------------------------------

$SummaryFile = Join-Path $VMPath "deployment-info.txt"

# Build conditional summary sections as variables first
$DateStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if ($NetworkType -eq "static") {
    $NetworkSummary = "  Static IP:        $StaticIP`n  Gateway:          $Gateway`n  DNS:              $DNS"
} else {
    $NetworkSummary = "  IP:               DHCP"
}

if ($PSKValue -ne "") {
    $PSKSummary = "  TLS PSK Identity: $PSKIdentity`n  TLS PSK Key:      $PSKValue`n`n  ** SAVE THE PSK KEY -- YOU NEED IT IN ZABBIX SERVER **"
} else {
    $PSKSummary = "  TLS:              Not configured"
}

$Summary = @"
=============================================
  Zabbix Proxy Deployment Summary
=============================================
  Date:             $DateStamp

  VM Name:          $VMName
  vCPUs:            $VCPUCount
  RAM:              4 GB (Dynamic 2-4 GB)
  Disk:             60 GB (thin-provisioned VHDX)
  VM Files:         $VMPath
  Virtual Switch:   $VMSwitch

  Network:          $NetworkType
$NetworkSummary

  Ubuntu Admin:     $AdminUser
  Zabbix Version:   $ZabbixVersion
  Zabbix Server:    $ZabbixServer
  Proxy Hostname:   $ProxyHostname
  Database:         SQLite (/var/lib/zabbix/zabbix_proxy.db)

$PSKSummary

  Setup Log (VM):   /var/log/zabbix-proxy-setup.log
=============================================
"@

$Summary | Out-File -FilePath $SummaryFile -Encoding UTF8
Write-Host ""
Write-Host $Summary -ForegroundColor White

# ----------------------------------------------------------------------
#  Start the VM
# ----------------------------------------------------------------------

Write-Host ""
$StartNow = Read-Host "Start the VM now? (y/n) [default: y]"
if ($StartNow -ne "n") {
    Start-VM -Name $VMName
    Write-Host ""
    Write-Host "VM '$VMName' is booting!" -ForegroundColor Green
    Write-Host ""
    Write-Host "What happens next:" -ForegroundColor Yellow
    Write-Host "  1. Ubuntu installs automatically (~5-15 min)"
    Write-Host "  2. VM reboots into the installed OS"
    Write-Host "  3. First-boot service installs Zabbix Proxy (needs internet)"
    Write-Host "  4. Watch progress via Hyper-V Manager console"
    Write-Host "  5. SSH in after:  ssh $AdminUser@<VM-IP>"
    Write-Host "  6. Check logs:    cat /var/log/zabbix-proxy-setup.log"
    Write-Host ""
    Write-Host "Remember to add this proxy in your Zabbix Server frontend!" -ForegroundColor Cyan
    if ($PSKValue -ne "") {
        Write-Host "  PSK Identity: $PSKIdentity" -ForegroundColor Cyan
    }
} else {
    Write-Host "VM created but not started. Run manually:" -ForegroundColor Yellow
    Write-Host "  Start-VM -Name '$VMName'" -ForegroundColor White
}

Write-Host ""
Write-Host "Deployment info saved to: $SummaryFile" -ForegroundColor Gray
Write-Host "Done!" -ForegroundColor Green
