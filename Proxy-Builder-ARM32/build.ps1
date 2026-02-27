# Build script for Zabbix Proxy ARM32 container
# For MikroTik RB4011 RouterOS Container deployment
# Windows PowerShell version

$ErrorActionPreference = "Stop"

$IMAGE_NAME = "zabbix-proxy-arm32"

# Prompt for version
Write-Host "=============================================="
Write-Host "Zabbix Proxy ARM32 Builder for MikroTik RB4011"
Write-Host "=============================================="
Write-Host ""
Write-Host "Available versions: 6.0.x (LTS), 7.0.x (LTS), 7.2.x, 7.4.x"
Write-Host "Example: 7.0.23, 7.2.3, 7.4.7"
Write-Host ""
$ZABBIX_VERSION = Read-Host "Enter Zabbix version to build"

if ([string]::IsNullOrWhiteSpace($ZABBIX_VERSION)) {
    Write-Host "ERROR: Version cannot be empty" -ForegroundColor Red
    exit 1
}

# Determine major.minor for download URL
$VERSION_PARTS = $ZABBIX_VERSION.Split(".")
if ($VERSION_PARTS.Length -lt 2) {
    Write-Host "ERROR: Invalid version format. Use format like 7.2.3" -ForegroundColor Red
    exit 1
}
$MAJOR_MINOR = "$($VERSION_PARTS[0]).$($VERSION_PARTS[1])"

$IMAGE_TAG = $ZABBIX_VERSION
$TAR_OUTPUT = "zabbix-proxy-arm32-${ZABBIX_VERSION}.tar"

Write-Host ""
Write-Host "=============================================="
Write-Host "Building Zabbix Proxy $ZABBIX_VERSION for ARM32 (armv7)"
Write-Host "=============================================="

# Update Dockerfile with requested version
$dockerfileContent = Get-Content -Path "Dockerfile" -Raw
$dockerfileContent = $dockerfileContent -replace 'ENV ZABBIX_VERSION=.*', "ENV ZABBIX_VERSION=$ZABBIX_VERSION"
$dockerfileContent = $dockerfileContent -replace 'sources/stable/[0-9]+\.[0-9]+/', "sources/stable/$MAJOR_MINOR/"
$dockerfileContent = $dockerfileContent -replace 'LABEL version=".*"', "LABEL version=`"$ZABBIX_VERSION`""
$dockerfileContent = $dockerfileContent -replace 'Zabbix Proxy [0-9]+\.[0-9]+\.[0-9]+ for MikroTik', "Zabbix Proxy $ZABBIX_VERSION for MikroTik"
$dockerfileContent | Set-Content -Path "Dockerfile" -NoNewline

# Check Docker is running
try {
    docker info | Out-Null
} catch {
    Write-Host "ERROR: Docker is not running" -ForegroundColor Red
    Write-Host "Please start Docker Desktop"
    exit 1
}

# Check for Docker buildx
try {
    docker buildx version | Out-Null
} catch {
    Write-Host "ERROR: Docker buildx is required for cross-platform builds" -ForegroundColor Red
    Write-Host "Buildx should be included with Docker Desktop."
    Write-Host "Try updating Docker Desktop to the latest version."
    exit 1
}

# Create/use buildx builder with ARM support
$BUILDER_NAME = "arm32-builder"
$builderExists = $false

try {
    $null = docker buildx inspect $BUILDER_NAME 2>$null
    if ($LASTEXITCODE -eq 0) {
        $builderExists = $true
    }
} catch {
    $builderExists = $false
}

if (-not $builderExists) {
    Write-Host "Creating buildx builder with ARM support..."
    docker buildx create --name $BUILDER_NAME --driver docker-container --use
    docker buildx inspect --bootstrap $BUILDER_NAME
} else {
    Write-Host "Using existing builder: $BUILDER_NAME"
    docker buildx use $BUILDER_NAME
}

# Build the image for ARM32
Write-Host ""
Write-Host "Building container image (this may take 10-15 minutes)..."
Write-Host ""

docker buildx build --platform linux/arm/v7 --tag "${IMAGE_NAME}:${IMAGE_TAG}" --file Dockerfile --load .

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Build failed" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Build complete. Exporting image for RouterOS..."
Write-Host ""

# Export as tar for RouterOS import
docker save "${IMAGE_NAME}:${IMAGE_TAG}" -o $TAR_OUTPUT

$fileSize = (Get-Item $TAR_OUTPUT).Length / 1MB
$fileSizeFormatted = "{0:N2} MB" -f $fileSize

Write-Host "=============================================="
Write-Host "SUCCESS!" -ForegroundColor Green
Write-Host "=============================================="
Write-Host ""
Write-Host "Output file: $TAR_OUTPUT ($fileSizeFormatted)"
Write-Host ""
Write-Host "To deploy on RB4011:"
Write-Host ""
Write-Host "1. Upload to RouterOS:"
Write-Host "   scp $TAR_OUTPUT admin@<router-ip>:/"
Write-Host ""
Write-Host "2. In RouterOS terminal:"
Write-Host "   /container/add file=$TAR_OUTPUT interface=veth1 root-dir=disk1/zabbix-proxy hostname=rb4011-proxy logging=yes"
Write-Host ""
Write-Host "3. Configure environment:"
Write-Host "   /container/envs/add name=zabbix key=ZBX_SERVER_HOST value=<your-zabbix-server>"
Write-Host "   /container/envs/add name=zabbix key=ZBX_HOSTNAME value=rb4011-proxy"
Write-Host ""
Write-Host "4. Start container:"
Write-Host "   /container/start 0"
Write-Host ""
