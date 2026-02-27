#!/bin/bash
# Build script for Zabbix Proxy ARM32 container
# For MikroTik RB4011 RouterOS Container deployment
# Works on: Linux, macOS (Intel & Apple Silicon)

set -e

IMAGE_NAME="zabbix-proxy-arm32"

# Prompt for version
echo "=============================================="
echo "Zabbix Proxy ARM32 Builder for MikroTik RB4011"
echo "=============================================="
echo ""
echo "Available versions: 6.0.x (LTS), 7.0.x (LTS), 7.2.x, 7.4.x"
echo "Example: 7.0.23, 7.2.3, 7.4.7"
echo ""
read -p "Enter Zabbix version to build: " ZABBIX_VERSION

if [ -z "$ZABBIX_VERSION" ]; then
    echo "ERROR: Version cannot be empty"
    exit 1
fi

# Determine major.minor for download URL
MAJOR_MINOR=$(echo "$ZABBIX_VERSION" | cut -d. -f1,2)

IMAGE_TAG="$ZABBIX_VERSION"
TAR_OUTPUT="zabbix-proxy-arm32-${ZABBIX_VERSION}.tar"

echo ""
echo "=============================================="
echo "Building Zabbix Proxy $ZABBIX_VERSION for ARM32 (armv7)"
echo "=============================================="

# Update Dockerfile with requested version
sed -i.bak "s/ENV ZABBIX_VERSION=.*/ENV ZABBIX_VERSION=$ZABBIX_VERSION/" Dockerfile
sed -i.bak "s|sources/stable/[0-9]*\.[0-9]*/|sources/stable/$MAJOR_MINOR/|" Dockerfile
sed -i.bak "s/LABEL version=\".*\"/LABEL version=\"$ZABBIX_VERSION\"/" Dockerfile
sed -i.bak "s/Zabbix Proxy [0-9]*\.[0-9]*\.[0-9]* for MikroTik/Zabbix Proxy $ZABBIX_VERSION for MikroTik/" Dockerfile
rm -f Dockerfile.bak

# Detect OS
OS="$(uname -s)"
echo "Detected OS: $OS"

# Check Docker is running
if ! docker info &> /dev/null; then
    echo "ERROR: Docker is not running"
    if [[ "$OS" == "Darwin" ]]; then
        echo "Please start Docker Desktop"
    fi
    exit 1
fi

# Check for Docker buildx
if ! docker buildx version &> /dev/null; then
    echo "ERROR: Docker buildx is required for cross-platform builds"
    if [[ "$OS" == "Darwin" ]]; then
        echo "Buildx should be included with Docker Desktop."
        echo "Try updating Docker Desktop to the latest version."
    else
        echo "Install with: docker buildx install"
    fi
    exit 1
fi

# Create/use buildx builder with ARM support
BUILDER_NAME="arm32-builder"
if ! docker buildx inspect "$BUILDER_NAME" &> /dev/null 2>&1; then
    echo "Creating buildx builder with ARM support..."
    docker buildx create --name "$BUILDER_NAME" --driver docker-container --use
    docker buildx inspect --bootstrap "$BUILDER_NAME"
else
    echo "Using existing builder: $BUILDER_NAME"
    docker buildx use "$BUILDER_NAME"
fi

# Build the image for ARM32
echo ""
echo "Building container image (this may take 10-15 minutes)..."
echo ""

docker buildx build \
    --platform linux/arm/v7 \
    --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
    --file Dockerfile \
    --load \
    .

if [ $? -ne 0 ]; then
    echo "ERROR: Build failed"
    exit 1
fi

echo ""
echo "Build complete. Exporting image for RouterOS..."
echo ""

# Export as tar for RouterOS import
docker save "${IMAGE_NAME}:${IMAGE_TAG}" -o "$TAR_OUTPUT"

# Get file size
if [[ "$OS" == "Darwin" ]]; then
    SIZE=$(stat -f%z "$TAR_OUTPUT" | awk '{printf "%.2f MB", $1/1024/1024}')
else
    SIZE=$(stat --printf="%s" "$TAR_OUTPUT" | awk '{printf "%.2f MB", $1/1024/1024}')
fi

echo "=============================================="
echo "SUCCESS!"
echo "=============================================="
echo ""
echo "Output file: $TAR_OUTPUT ($SIZE)"
echo ""
echo "To deploy on RB4011:"
echo ""
echo "1. Upload to RouterOS:"
echo "   scp $TAR_OUTPUT admin@<router-ip>:/"
echo ""
echo "2. In RouterOS terminal:"
echo "   /container/add file=$TAR_OUTPUT interface=veth1 root-dir=disk1/zabbix-proxy hostname=rb4011-proxy logging=yes"
echo ""
echo "3. Configure environment:"
echo "   /container/envs/add name=zabbix key=ZBX_SERVER_HOST value=<your-zabbix-server>"
echo "   /container/envs/add name=zabbix key=ZBX_HOSTNAME value=rb4011-proxy"
echo ""
echo "4. Start container:"
echo "   /container/start 0"
echo ""
