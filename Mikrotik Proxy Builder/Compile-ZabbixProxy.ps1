# =============================================================================
# Compile-ZabbixProxy.ps1 v1.1.0
# =============================================================================
# Cross-compiles Zabbix Proxy for BOTH ARM32 and ARM64 and places the
# binaries at C:\Firmware\Zabbix\ for IIS to serve.
#
# Output files:
#   C:\Firmware\Zabbix\zabbix_proxy.bin       (ARM32 - RB4011)
#   C:\Firmware\Zabbix\zabbix_proxy_arm64.bin (ARM64 - RB5009, CCR2004, CCR2116)
#
# Prerequisites: Docker Desktop with buildx support
#
# Usage:
#   Right-click -> Run with PowerShell
#   or: powershell -ExecutionPolicy Bypass -File .\Compile-ZabbixProxy.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$OUTPUT_DIR = "C:\Firmware\Zabbix"
$TEMP_DIR = "$env:TEMP\zabbix-arm-compile"
$BUILDER_NAME = "arm-builder"

# -- Banner -------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================="
Write-Host "Zabbix Proxy ARM Compiler"
Write-Host "v1.1.0 - ARM32 + ARM64"
Write-Host "=============================================="
Write-Host ""
Write-Host "This script compiles the Zabbix Proxy binary for:"
Write-Host "  ARM32 (armv7)   -> zabbix_proxy.bin"
Write-Host "  ARM64 (aarch64) -> zabbix_proxy_arm64.bin"
Write-Host ""
Write-Host "Output directory: $OUTPUT_DIR"
Write-Host ""
Write-Host "Available versions: 6.0.x (LTS), 7.0.x (LTS), 7.2.x, 7.4.x"
Write-Host "Example: 7.0.23, 7.2.3, 7.4.7"
Write-Host ""

$ZABBIX_VERSION = Read-Host "Enter Zabbix version to compile"

if ([string]::IsNullOrWhiteSpace($ZABBIX_VERSION)) {
    Write-Host "ERROR: Version cannot be empty" -ForegroundColor Red
    exit 1
}

if ($ZABBIX_VERSION -notmatch '^\d+\.\d+\.\d+$') {
    Write-Host "ERROR: Invalid version format. Use format like 7.2.3" -ForegroundColor Red
    exit 1
}

$VERSION_PARTS = $ZABBIX_VERSION.Split(".")
$MAJOR_MINOR = "$($VERSION_PARTS[0]).$($VERSION_PARTS[1])"

Write-Host ""
Write-Host "=============================================="
Write-Host "Compiling Zabbix Proxy $ZABBIX_VERSION (ARM32 + ARM64)"
Write-Host "=============================================="

# -- Check Docker -------------------------------------------------------------
Write-Host ""
Write-Host "Checking Docker..."

try { docker info | Out-Null } catch {
    Write-Host "ERROR: Docker is not running. Please start Docker Desktop." -ForegroundColor Red
    exit 1
}

try { docker buildx version | Out-Null } catch {
    Write-Host "ERROR: Docker buildx is required. Update Docker Desktop." -ForegroundColor Red
    exit 1
}

# -- Set up buildx builder ----------------------------------------------------
$builderExists = $false
try {
    $null = docker buildx inspect $BUILDER_NAME 2>$null
    if ($LASTEXITCODE -eq 0) { $builderExists = $true }
} catch { $builderExists = $false }

if (-not $builderExists) {
    Write-Host "Creating buildx builder with ARM support..."
    docker buildx create --name $BUILDER_NAME --driver docker-container --use
    docker buildx inspect --bootstrap $BUILDER_NAME
} else {
    Write-Host "Using existing builder: $BUILDER_NAME"
    docker buildx use $BUILDER_NAME
}

# -- Create temp build context -------------------------------------------------
Write-Host ""
Write-Host "Preparing build context..."

if (Test-Path $TEMP_DIR) {
    Remove-Item -Recurse -Force $TEMP_DIR
}
New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null

# Create a Dockerfile template using single-quoted here-string (no PS expansion)
# then replace placeholders with actual values
$CompileDockerfile = @'
FROM alpine:3.19 AS builder

RUN apk add --no-cache \
    alpine-sdk \
    autoconf \
    automake \
    curl \
    sqlite-dev \
    pcre2-dev \
    libevent-dev \
    openssl-dev \
    curl-dev \
    libxml2-dev \
    openldap-dev \
    zlib-dev \
    linux-headers

WORKDIR /build

RUN curl -LO https://cdn.zabbix.com/zabbix/sources/stable/__MAJOR_MINOR__/zabbix-__VERSION__.tar.gz \
    && tar xzf zabbix-__VERSION__.tar.gz

WORKDIR /build/zabbix-__VERSION__

RUN ./configure \
    --prefix=/usr \
    --sysconfdir=/etc/zabbix \
    --enable-proxy \
    --with-sqlite3 \
    --with-libpcre2 \
    --with-openssl \
    --with-libcurl \
    --with-libxml2 \
    --with-ldap

RUN make -j$(nproc)

RUN strip src/zabbix_proxy/zabbix_proxy

# Final stage: just the binary in a scratch image for extraction
FROM scratch
COPY --from=builder /build/zabbix-__VERSION__/src/zabbix_proxy/zabbix_proxy /zabbix_proxy
'@

$CompileDockerfile = $CompileDockerfile -replace '__VERSION__', $ZABBIX_VERSION
$CompileDockerfile = $CompileDockerfile -replace '__MAJOR_MINOR__', $MAJOR_MINOR

$CompileDockerfile | Set-Content -Path "$TEMP_DIR\Dockerfile" -Encoding UTF8 -NoNewline

# -- Ensure output directory exists --------------------------------------------
if (-not (Test-Path $OUTPUT_DIR)) {
    New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
    Write-Host "Created directory: $OUTPUT_DIR"
}

# =============================================================================
# Build ARM32
# =============================================================================
Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "[1/2] Compiling ARM32 (armv7) - RB4011" -ForegroundColor Cyan
Write-Host "----------------------------------------------"
Write-Host "This may take 10-15 minutes..."
Write-Host ""

$ARM32_Dir = "$TEMP_DIR\arm32"
New-Item -ItemType Directory -Path $ARM32_Dir -Force | Out-Null

docker buildx build `
    --platform linux/arm/v7 `
    --file "$TEMP_DIR\Dockerfile" `
    --output "type=local,dest=$ARM32_Dir" `
    $TEMP_DIR

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: ARM32 compilation failed" -ForegroundColor Red
    exit 1
}

$ARM32_Binary = "$ARM32_Dir\zabbix_proxy"
if (-not (Test-Path $ARM32_Binary)) {
    Write-Host "ERROR: ARM32 binary not found at $ARM32_Binary" -ForegroundColor Red
    exit 1
}

$ARM32_Size = "{0:N2} MB" -f ((Get-Item $ARM32_Binary).Length / 1MB)
Write-Host "ARM32 compilation successful ($ARM32_Size)" -ForegroundColor Green

# =============================================================================
# Build ARM64
# =============================================================================
Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "[2/2] Compiling ARM64 (aarch64) - RB5009, CCR" -ForegroundColor Cyan
Write-Host "----------------------------------------------"
Write-Host "This may take 10-15 minutes..."
Write-Host ""

$ARM64_Dir = "$TEMP_DIR\arm64"
New-Item -ItemType Directory -Path $ARM64_Dir -Force | Out-Null

docker buildx build `
    --platform linux/arm64 `
    --file "$TEMP_DIR\Dockerfile" `
    --output "type=local,dest=$ARM64_Dir" `
    $TEMP_DIR

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: ARM64 compilation failed" -ForegroundColor Red
    exit 1
}

$ARM64_Binary = "$ARM64_Dir\zabbix_proxy"
if (-not (Test-Path $ARM64_Binary)) {
    Write-Host "ERROR: ARM64 binary not found at $ARM64_Binary" -ForegroundColor Red
    exit 1
}

$ARM64_Size = "{0:N2} MB" -f ((Get-Item $ARM64_Binary).Length / 1MB)
Write-Host "ARM64 compilation successful ($ARM64_Size)" -ForegroundColor Green

# =============================================================================
# Deploy to IIS directory
# =============================================================================
Write-Host ""
Write-Host "Deploying to $OUTPUT_DIR..."

# -- ARM32: zabbix_proxy.bin --
$ARM32_Dest = "$OUTPUT_DIR\zabbix_proxy.bin"
if (Test-Path $ARM32_Dest) {
    $BackupName = "zabbix_proxy_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
    Copy-Item $ARM32_Dest "$OUTPUT_DIR\$BackupName"
    Write-Host "  Backed up ARM32 binary to $BackupName"
}
Copy-Item -Force $ARM32_Binary $ARM32_Dest

# -- ARM64: zabbix_proxy_arm64.bin --
$ARM64_Dest = "$OUTPUT_DIR\zabbix_proxy_arm64.bin"
if (Test-Path $ARM64_Dest) {
    $BackupName = "zabbix_proxy_arm64_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
    Copy-Item $ARM64_Dest "$OUTPUT_DIR\$BackupName"
    Write-Host "  Backed up ARM64 binary to $BackupName"
}
Copy-Item -Force $ARM64_Binary $ARM64_Dest

# -- Version marker --
"$ZABBIX_VERSION" | Set-Content -Path "$OUTPUT_DIR\version.txt" -NoNewline

# -- Cleanup -------------------------------------------------------------------
Write-Host "Cleaning up temp files..."
Remove-Item -Recurse -Force $TEMP_DIR -ErrorAction SilentlyContinue

# -- Done ----------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================="
Write-Host "SUCCESS! Both binaries compiled." -ForegroundColor Green
Write-Host "=============================================="
Write-Host ""
Write-Host "  ARM32 : $ARM32_Dest ($ARM32_Size)"
Write-Host "           -> http://checkin.lighthouseit.us/Zabbix/zabbix_proxy.bin"
Write-Host "           For: RB4011"
Write-Host ""
Write-Host "  ARM64 : $ARM64_Dest ($ARM64_Size)"
Write-Host "           -> http://checkin.lighthouseit.us/Zabbix/zabbix_proxy_arm64.bin"
Write-Host "           For: RB5009, CCR2004, CCR2116"
Write-Host ""
Write-Host "  Version: $ZABBIX_VERSION"
Write-Host ""
Write-Host "  Update the GitHub zblive file to '$ZABBIX_VERSION'"
Write-Host "  to trigger the rollout to all containers."
Write-Host ""
