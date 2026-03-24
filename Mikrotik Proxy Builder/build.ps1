# Build script for Zabbix Proxy + Agent2 ARM containers v4.0.0
# Builds BOTH ARM32 (RB4011) and ARM64 (RB5009, CCR2004, CCR2116)
# Includes OCI normalization via skopeo for RouterOS compatibility
# Windows PowerShell version

$ErrorActionPreference = "Stop"

$IMAGE_BASE = "zabbix-proxy"
$SKOPEO_IMAGE = "quay.io/skopeo/stable:latest"

Write-Host "=============================================="
Write-Host "Zabbix Proxy + Agent2 ARM Builder"
Write-Host "v4.0.0 (OCI-compliant)"
Write-Host "=============================================="
Write-Host ""
Write-Host "Builds containers for:"
Write-Host "  ARM32 (armv7)   - RB4011"
Write-Host "  ARM64 (aarch64) - RB5009, CCR2004, CCR2116"
Write-Host ""
Write-Host "Available versions: 6.0.x (LTS), 7.0.x (LTS), 7.2.x, 7.4.x"
Write-Host "Example: 7.0.23, 7.2.3, 7.4.7"
Write-Host ""
$ZABBIX_VERSION = Read-Host "Enter Zabbix version to build"

if ([string]::IsNullOrWhiteSpace($ZABBIX_VERSION)) {
    Write-Host "ERROR: Version cannot be empty" -ForegroundColor Red
    exit 1
}

$VERSION_PARTS = $ZABBIX_VERSION.Split(".")
if ($VERSION_PARTS.Length -lt 2) {
    Write-Host "ERROR: Invalid version format. Use format like 7.2.3" -ForegroundColor Red
    exit 1
}
$MAJOR_MINOR = "$($VERSION_PARTS[0]).$($VERSION_PARTS[1])"

Write-Host ""
Write-Host "=============================================="
Write-Host "Building Zabbix Proxy + Agent2 $ZABBIX_VERSION"
Write-Host "=============================================="

# Update Dockerfile with requested version
$dockerfileContent = Get-Content -Path "Dockerfile" -Raw
$dockerfileContent = $dockerfileContent -replace 'ENV ZABBIX_VERSION=.*', "ENV ZABBIX_VERSION=$ZABBIX_VERSION"
$dockerfileContent = $dockerfileContent -replace 'sources/stable/[0-9]+\.[0-9]+/', "sources/stable/$MAJOR_MINOR/"
$dockerfileContent = $dockerfileContent -replace 'LABEL version=".*"', "LABEL version=`"$ZABBIX_VERSION`""
$dockerfileContent = $dockerfileContent -replace 'Zabbix Proxy [0-9]+\.[0-9]+\.[0-9]+ for MikroTik', "Zabbix Proxy $ZABBIX_VERSION for MikroTik"
$dockerfileContent = $dockerfileContent -replace 'ARG ZABBIX_VERSION=.*', "ARG ZABBIX_VERSION=$ZABBIX_VERSION"
$dockerfileContent | Set-Content -Path "Dockerfile" -NoNewline

try { docker info | Out-Null } catch {
    Write-Host "ERROR: Docker is not running" -ForegroundColor Red; exit 1
}
try { docker buildx version | Out-Null } catch {
    Write-Host "ERROR: Docker buildx is required" -ForegroundColor Red; exit 1
}

# OCI normalization function
function Normalize-Tar {
    param([string]$TarFile)
    $TarDir = Split-Path -Parent (Resolve-Path $TarFile)
    $TarName = Split-Path -Leaf $TarFile
    $RawName = "raw_$TarName"
    Write-Host "  Normalizing OCI archive with skopeo..."
    Rename-Item -Path $TarFile -NewName $RawName
    docker run --rm -v "${TarDir}:/work" $SKOPEO_IMAGE copy "docker-archive:/work/$RawName" "docker-archive:/work/$TarName"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: skopeo normalization failed, using original tar" -ForegroundColor Yellow
        Rename-Item -Path "$TarDir\$RawName" -NewName $TarName
    } else {
        Remove-Item -Force "$TarDir\$RawName" -ErrorAction SilentlyContinue
        Write-Host "  OCI normalization complete."
    }
}

Write-Host ""
Write-Host "Pulling skopeo image for OCI normalization..."
docker pull $SKOPEO_IMAGE

$BUILDER_NAME = "arm-builder"
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

# ---- Build ARM32 ------------------------------------------------------------
$ARM32_IMAGE = "${IMAGE_BASE}-arm32:${ZABBIX_VERSION}"
$ARM32_TAR = "zabbix-proxy-arm32-${ZABBIX_VERSION}.tar"

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "[1/2] Building ARM32 (armv7) - RB4011" -ForegroundColor Cyan
Write-Host "----------------------------------------------"
Write-Host ""

docker buildx build --platform linux/arm/v7 --tag $ARM32_IMAGE --build-arg "ZABBIX_VERSION=${ZABBIX_VERSION}" --file Dockerfile --load .

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: ARM32 build failed" -ForegroundColor Red; exit 1
}

Write-Host ""; Write-Host "ARM32 build complete. Exporting..."
docker save $ARM32_IMAGE -o $ARM32_TAR
Normalize-Tar -TarFile $ARM32_TAR

# ---- Build ARM64 ------------------------------------------------------------
$ARM64_IMAGE = "${IMAGE_BASE}-arm64:${ZABBIX_VERSION}"
$ARM64_TAR = "zabbix-proxy-arm64-${ZABBIX_VERSION}.tar"

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "[2/2] Building ARM64 (aarch64) - RB5009, CCR" -ForegroundColor Cyan
Write-Host "----------------------------------------------"
Write-Host ""

docker buildx build --platform linux/arm64 --tag $ARM64_IMAGE --build-arg "ZABBIX_VERSION=${ZABBIX_VERSION}" --file Dockerfile --load .

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: ARM64 build failed" -ForegroundColor Red; exit 1
}

Write-Host ""; Write-Host "ARM64 build complete. Exporting..."
docker save $ARM64_IMAGE -o $ARM64_TAR
Normalize-Tar -TarFile $ARM64_TAR

# ---- Summary ----------------------------------------------------------------
$ARM32_SIZE = "{0:N2} MB" -f ((Get-Item $ARM32_TAR).Length / 1MB)
$ARM64_SIZE = "{0:N2} MB" -f ((Get-Item $ARM64_TAR).Length / 1MB)

Write-Host ""
Write-Host "=============================================="
Write-Host "SUCCESS! Both builds complete." -ForegroundColor Green
Write-Host "=============================================="
Write-Host ""
Write-Host "  ARM32 : $ARM32_TAR ($ARM32_SIZE) - RB4011"
Write-Host "  ARM64 : $ARM64_TAR ($ARM64_SIZE) - RB5009, CCR2004, CCR2116"
Write-Host ""
Write-Host "Both images include Zabbix Proxy + Agent2."
Write-Host "OCI-normalized for RouterOS compatibility."
Write-Host ""
