#!/bin/bash
# Build script for Zabbix Proxy ARM containers v3.2.0
# Builds BOTH ARM32 (RB4011) and ARM64 (RB5009, CCR2004, CCR2116)
# Includes OCI normalization via skopeo for RouterOS compatibility
# For MikroTik RouterOS Container deployment
# Works on: Linux, macOS (Intel & Apple Silicon)

set -e

IMAGE_BASE="zabbix-proxy"
SKOPEO_IMAGE="quay.io/skopeo/stable:latest"

echo "=============================================="
echo "Zabbix Proxy ARM Builder for MikroTik RouterOS"
echo "v3.2.0 - ARM32 + ARM64 (OCI-compliant)"
echo "=============================================="
echo ""
echo "Builds containers for:"
echo "  ARM32 (armv7) - RB4011"
echo "  ARM64 (aarch64) - RB5009, CCR2004, CCR2116"
echo ""
echo "Available versions: 6.0.x (LTS), 7.0.x (LTS), 7.2.x, 7.4.x"
echo "Example: 7.0.23, 7.2.3, 7.4.7"
echo ""
read -p "Enter Zabbix version to build: " ZABBIX_VERSION

if [ -z "$ZABBIX_VERSION" ]; then
    echo "ERROR: Version cannot be empty"
    exit 1
fi

MAJOR_MINOR=$(echo "$ZABBIX_VERSION" | cut -d. -f1,2)

echo ""
echo "=============================================="
echo "Building Zabbix Proxy $ZABBIX_VERSION"
echo "=============================================="

# Update Dockerfile with requested version
sed -i.bak "s/ENV ZABBIX_VERSION=.*/ENV ZABBIX_VERSION=$ZABBIX_VERSION/" Dockerfile
sed -i.bak "s|sources/stable/[0-9]*\.[0-9]*/|sources/stable/$MAJOR_MINOR/|" Dockerfile
sed -i.bak "s/LABEL version=\".*\"/LABEL version=\"$ZABBIX_VERSION\"/" Dockerfile
sed -i.bak "s/Zabbix Proxy [0-9]*\.[0-9]*\.[0-9]* for MikroTik/Zabbix Proxy $ZABBIX_VERSION for MikroTik/" Dockerfile
sed -i.bak "s/^ARG ZABBIX_VERSION=.*/ARG ZABBIX_VERSION=$ZABBIX_VERSION/" Dockerfile
rm -f Dockerfile.bak

OS="$(uname -s)"
echo "Detected OS: $OS"

if ! docker info &> /dev/null; then
    echo "ERROR: Docker is not running"
    exit 1
fi

if ! docker buildx version &> /dev/null; then
    echo "ERROR: Docker buildx is required"
    exit 1
fi

# -- OCI normalization via skopeo ---------------------------------------------
# RouterOS (especially < 7.21) cannot handle multi-platform or non-standard
# OCI image tarballs. Running skopeo copy normalizes the archive format.
# See: https://tangentsoft.com/mikrotik/wiki?name=Container+Limitations
normalize_tar() {
    local TAR_FILE="$1"
    local TAR_DIR
    TAR_DIR="$(cd "$(dirname "$TAR_FILE")" && pwd)"
    local TAR_NAME
    TAR_NAME="$(basename "$TAR_FILE")"
    local RAW_NAME="raw_${TAR_NAME}"

    echo "  Normalizing OCI archive with skopeo..."
    mv "$TAR_FILE" "${TAR_DIR}/${RAW_NAME}"

    docker run --rm \
        -v "${TAR_DIR}:/work" \
        "$SKOPEO_IMAGE" \
        copy \
        "docker-archive:/work/${RAW_NAME}" \
        "docker-archive:/work/${TAR_NAME}"

    if [ $? -ne 0 ]; then
        echo "  WARNING: skopeo normalization failed, using original tar"
        mv "${TAR_DIR}/${RAW_NAME}" "$TAR_FILE"
    else
        rm -f "${TAR_DIR}/${RAW_NAME}"
        echo "  OCI normalization complete."
    fi
}

# Pull skopeo image ahead of time
echo ""
echo "Pulling skopeo image for OCI normalization..."
docker pull "$SKOPEO_IMAGE" || echo "WARNING: Could not pull skopeo image. Will try at normalization step."

BUILDER_NAME="arm-builder"
if ! docker buildx inspect "$BUILDER_NAME" &> /dev/null 2>&1; then
    echo "Creating buildx builder with ARM support..."
    docker buildx create --name "$BUILDER_NAME" --driver docker-container --use
    docker buildx inspect --bootstrap "$BUILDER_NAME"
else
    echo "Using existing builder: $BUILDER_NAME"
    docker buildx use "$BUILDER_NAME"
fi

# ---- Build ARM32 ------------------------------------------------------------
ARM32_IMAGE="${IMAGE_BASE}-arm32:${ZABBIX_VERSION}"
ARM32_TAR="zabbix-proxy-arm32-${ZABBIX_VERSION}.tar"

echo ""
echo "----------------------------------------------"
echo "[1/2] Building ARM32 (armv7) - RB4011"
echo "----------------------------------------------"
echo ""

docker buildx build \
    --platform linux/arm/v7 \
    --tag "${ARM32_IMAGE}" \
    --build-arg "ZABBIX_VERSION=${ZABBIX_VERSION}" \
    --file Dockerfile \
    --load \
    .

if [ $? -ne 0 ]; then
    echo "ERROR: ARM32 build failed"
    exit 1
fi

echo ""
echo "ARM32 build complete. Exporting..."
docker save "${ARM32_IMAGE}" -o "$ARM32_TAR"
normalize_tar "$ARM32_TAR"

# ---- Build ARM64 ------------------------------------------------------------
ARM64_IMAGE="${IMAGE_BASE}-arm64:${ZABBIX_VERSION}"
ARM64_TAR="zabbix-proxy-arm64-${ZABBIX_VERSION}.tar"

echo ""
echo "----------------------------------------------"
echo "[2/2] Building ARM64 (aarch64) - RB5009, CCR"
echo "----------------------------------------------"
echo ""

docker buildx build \
    --platform linux/arm64 \
    --tag "${ARM64_IMAGE}" \
    --build-arg "ZABBIX_VERSION=${ZABBIX_VERSION}" \
    --file Dockerfile \
    --load \
    .

if [ $? -ne 0 ]; then
    echo "ERROR: ARM64 build failed"
    exit 1
fi

echo ""
echo "ARM64 build complete. Exporting..."
docker save "${ARM64_IMAGE}" -o "$ARM64_TAR"
normalize_tar "$ARM64_TAR"

# ---- Summary ----------------------------------------------------------------
get_size() {
    if [[ "$OS" == "Darwin" ]]; then
        stat -f%z "$1" | awk '{printf "%.2f MB", $1/1024/1024}'
    else
        stat --printf="%s" "$1" | awk '{printf "%.2f MB", $1/1024/1024}'
    fi
}

echo ""
echo "=============================================="
echo "SUCCESS! Both builds complete."
echo "=============================================="
echo ""
echo "  ARM32 : $ARM32_TAR ($(get_size "$ARM32_TAR"))"
echo "          For: RB4011"
echo ""
echo "  ARM64 : $ARM64_TAR ($(get_size "$ARM64_TAR"))"
echo "          For: RB5009, CCR2004, CCR2116"
echo ""
echo "Deploy the matching tar to each router."
echo "SSH is enabled by default (root/zabbix)."
echo "Auto-updates check every 30 min."
echo ""
