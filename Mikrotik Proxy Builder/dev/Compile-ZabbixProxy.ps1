# =============================================================================
# Compile-ZabbixProxy.ps1 v2.0.0-dev
# =============================================================================
# Cross-compiles Zabbix Proxy + Agent2 for BOTH ARM32 and ARM64.
#
# Output files (C:\Firmware\Zabbix\):
#   zabbix_proxy.bin        (ARM32 - RB4011)
#   zabbix_proxy_arm64.bin  (ARM64 - RB5009, CCR2004, CCR2116)
#   zabbix_agent2.bin       (ARM32 - RB4011)
#   zabbix_agent2_arm64.bin (ARM64 - RB5009, CCR2004, CCR2116)
#
# Prerequisites: Docker Desktop with buildx support
# =============================================================================

$ErrorActionPreference = "Stop"

$OUTPUT_DIR = "C:\Firmware\Zabbix"
$TEMP_DIR = "$env:TEMP\zabbix-arm-compile"
$BUILDER_NAME = "arm-builder"

Write-Host ""
Write-Host "=============================================="
Write-Host "Zabbix Proxy + Agent2 ARM Compiler"
Write-Host "v2.0.0-dev - ARM32 + ARM64"
Write-Host "=============================================="
Write-Host ""
Write-Host "Compiles for both architectures:"
Write-Host "  ARM32 (armv7)   -> zabbix_proxy.bin, zabbix_agent2.bin"
Write-Host "  ARM64 (aarch64) -> zabbix_proxy_arm64.bin, zabbix_agent2_arm64.bin"
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
Write-Host "Compiling Zabbix $ZABBIX_VERSION (Proxy + Agent2, ARM32 + ARM64)"
Write-Host "=============================================="

# -- Check Docker -------------------------------------------------------------
Write-Host ""
Write-Host "Checking Docker..."
try { docker info | Out-Null } catch {
    Write-Host "ERROR: Docker is not running." -ForegroundColor Red
    exit 1
}
try { docker buildx version | Out-Null } catch {
    Write-Host "ERROR: Docker buildx is required." -ForegroundColor Red
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

# Dockerfile template (single-quoted here-string = no PS expansion)
$CompileDockerfile = @'
FROM alpine:3.19 AS builder

ARG TARGETARCH

# Install C build dependencies
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
    linux-headers \
    net-snmp-dev \
    libssh2-dev \
    openipmi-dev \
    unixodbc-dev

# Install Go 1.24 from official binary (Alpine's Go is too old for agent2)
RUN case "${TARGETARCH}" in \
        arm64)  GOARCH="arm64" ;; \
        arm*)   GOARCH="armv6l" ;; \
        *)      GOARCH="${TARGETARCH}" ;; \
    esac \
    && curl -fsSL "https://go.dev/dl/go1.24.1.linux-${GOARCH}.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/root/go"

WORKDIR /build

RUN curl -LO https://cdn.zabbix.com/zabbix/sources/stable/__MAJOR_MINOR__/zabbix-__VERSION__.tar.gz \
    && tar xzf zabbix-__VERSION__.tar.gz

WORKDIR /build/zabbix-__VERSION__

RUN ./configure \
    --prefix=/usr \
    --sysconfdir=/etc/zabbix \
    --enable-proxy \
    --enable-agent2 \
    --with-sqlite3 \
    --with-libpcre2 \
    --with-openssl \
    --with-libcurl \
    --with-libxml2 \
    --with-ldap \
    --with-net-snmp \
    --with-ssh2 \
    --with-openipmi \
    --with-unixodbc

# Build proxy + agent2
RUN make -j$(nproc)
RUN strip src/zabbix_proxy/zabbix_proxy

# Strip agent2 if possible (Go binaries may not always strip cleanly)
RUN strip src/go/bin/zabbix_agent2 || true

# Final stage: extract both binaries
FROM scratch
COPY --from=builder /build/zabbix-__VERSION__/src/zabbix_proxy/zabbix_proxy /zabbix_proxy
COPY --from=builder /build/zabbix-__VERSION__/src/go/bin/zabbix_agent2 /zabbix_agent2
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
Write-Host "This may take 15-25 minutes (proxy + agent2)..."
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

if (-not (Test-Path "$ARM32_Dir\zabbix_proxy")) {
    Write-Host "ERROR: ARM32 proxy binary not found" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path "$ARM32_Dir\zabbix_agent2")) {
    Write-Host "ERROR: ARM32 agent2 binary not found" -ForegroundColor Red
    exit 1
}

$ARM32_ProxySize = "{0:N2} MB" -f ((Get-Item "$ARM32_Dir\zabbix_proxy").Length / 1MB)
$ARM32_Agent2Size = "{0:N2} MB" -f ((Get-Item "$ARM32_Dir\zabbix_agent2").Length / 1MB)
Write-Host "ARM32 compilation successful" -ForegroundColor Green
Write-Host "  Proxy:  $ARM32_ProxySize"
Write-Host "  Agent2: $ARM32_Agent2Size"

# =============================================================================
# Build ARM64
# =============================================================================
Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "[2/2] Compiling ARM64 (aarch64) - RB5009, CCR" -ForegroundColor Cyan
Write-Host "----------------------------------------------"
Write-Host "This may take 15-25 minutes (proxy + agent2)..."
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

if (-not (Test-Path "$ARM64_Dir\zabbix_proxy")) {
    Write-Host "ERROR: ARM64 proxy binary not found" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path "$ARM64_Dir\zabbix_agent2")) {
    Write-Host "ERROR: ARM64 agent2 binary not found" -ForegroundColor Red
    exit 1
}

$ARM64_ProxySize = "{0:N2} MB" -f ((Get-Item "$ARM64_Dir\zabbix_proxy").Length / 1MB)
$ARM64_Agent2Size = "{0:N2} MB" -f ((Get-Item "$ARM64_Dir\zabbix_agent2").Length / 1MB)
Write-Host "ARM64 compilation successful" -ForegroundColor Green
Write-Host "  Proxy:  $ARM64_ProxySize"
Write-Host "  Agent2: $ARM64_Agent2Size"

# =============================================================================
# Deploy to IIS directory
# =============================================================================
Write-Host ""
Write-Host "Deploying to $OUTPUT_DIR..."

function Deploy-Binary {
    param([string]$Source, [string]$DestName)
    $DestPath = "$OUTPUT_DIR\$DestName"
    if (Test-Path $DestPath) {
        $BakName = "$($DestName -replace '\.bin$','')_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
        Copy-Item $DestPath "$OUTPUT_DIR\$BakName"
        Write-Host "  Backed up $DestName to $BakName"
    }
    Copy-Item -Force $Source $DestPath
    Write-Host "  Deployed $DestName"
}

# ARM32
Deploy-Binary -Source "$ARM32_Dir\zabbix_proxy" -DestName "zabbix_proxy.bin"
Deploy-Binary -Source "$ARM32_Dir\zabbix_agent2" -DestName "zabbix_agent2.bin"

# ARM64
Deploy-Binary -Source "$ARM64_Dir\zabbix_proxy" -DestName "zabbix_proxy_arm64.bin"
Deploy-Binary -Source "$ARM64_Dir\zabbix_agent2" -DestName "zabbix_agent2_arm64.bin"

# Version marker
"$ZABBIX_VERSION" | Set-Content -Path "$OUTPUT_DIR\version.txt" -NoNewline

# -- Cleanup -------------------------------------------------------------------
Write-Host ""
Write-Host "Cleaning up temp files..."
Remove-Item -Recurse -Force $TEMP_DIR -ErrorAction SilentlyContinue

# -- Done ----------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================="
Write-Host "SUCCESS! All binaries compiled." -ForegroundColor Green
Write-Host "=============================================="
Write-Host ""
Write-Host "  ARM32 (RB4011):"
Write-Host "    Proxy  : $OUTPUT_DIR\zabbix_proxy.bin ($ARM32_ProxySize)"
Write-Host "    Agent2 : $OUTPUT_DIR\zabbix_agent2.bin ($ARM32_Agent2Size)"
Write-Host ""
Write-Host "  ARM64 (RB5009, CCR2004, CCR2116):"
Write-Host "    Proxy  : $OUTPUT_DIR\zabbix_proxy_arm64.bin ($ARM64_ProxySize)"
Write-Host "    Agent2 : $OUTPUT_DIR\zabbix_agent2_arm64.bin ($ARM64_Agent2Size)"
Write-Host ""
Write-Host "  Version: $ZABBIX_VERSION"
Write-Host ""
Write-Host "  IIS serves from: http://checkin.lighthouseit.us/Zabbix/"
Write-Host ""
Write-Host "  Update the GitHub zblive file to '$ZABBIX_VERSION'"
Write-Host "  to trigger the rollout to all containers."
Write-Host ""
