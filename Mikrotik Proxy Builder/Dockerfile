# Zabbix Proxy 7.2.3 for ARM (MikroTik RouterOS)
# v3.2.0 - Supports ARM32 (RB4011) and ARM64 (RB5009, CCR2004, CCR2116)
# Build with: docker buildx build --platform linux/arm/v7 -t zabbix-proxy-arm32:7.2.3 --load .
#         or: docker buildx build --platform linux/arm64   -t zabbix-proxy-arm64:7.2.3 --load .

FROM alpine:3.19 AS builder

ENV ZABBIX_VERSION=7.2.3

# Install build dependencies
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

# Download and extract Zabbix source
RUN curl -LO https://cdn.zabbix.com/zabbix/sources/stable/7.2/zabbix-${ZABBIX_VERSION}.tar.gz \
    && tar xzf zabbix-${ZABBIX_VERSION}.tar.gz

WORKDIR /build/zabbix-${ZABBIX_VERSION}

# Configure with SQLite support
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

# Build
RUN make -j$(nproc)

# Install to staging directory and copy schema
RUN make DESTDIR=/staging install \
    && strip /staging/usr/sbin/zabbix_proxy \
    && mkdir -p /staging/usr/share/zabbix/database/sqlite3 \
    && cp database/sqlite3/schema.sql /staging/usr/share/zabbix/database/sqlite3/

# =============================================================================
# Stage 2: Lean Alpine runtime
# =============================================================================
FROM alpine:3.19

LABEL maintainer="Lighthouse IT"
LABEL description="Zabbix Proxy 7.2.3 for MikroTik RouterOS (ARM)"
LABEL version="7.2.3"

# Runtime dependencies + openssh + tools
RUN apk add --no-cache \
    sqlite \
    sqlite-libs \
    pcre2 \
    libevent \
    openssl \
    libcurl \
    libxml2 \
    libldap \
    zlib \
    ca-certificates \
    tzdata \
    openssh-server \
    openssh-client \
    su-exec \
    curl \
    procps \
    nano \
    bash \
    file

# Configure openssh - always running, root login enabled
RUN mkdir -p /var/run/sshd \
    && ssh-keygen -A \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Create zabbix user and directories
RUN addgroup -S zabbix \
    && adduser -S -G zabbix -h /var/lib/zabbix zabbix \
    && mkdir -p /etc/zabbix /var/lib/zabbix /var/log/zabbix /var/run/zabbix /usr/share/zabbix/database/sqlite3 \
    && chown -R zabbix:zabbix /var/lib/zabbix /var/log/zabbix /var/run/zabbix

# Copy binary and schema from builder
COPY --from=builder /staging/usr/sbin/zabbix_proxy /usr/sbin/
COPY --from=builder /staging/usr/share/zabbix/database/sqlite3/schema.sql /usr/share/zabbix/database/sqlite3/

# Copy config, entrypoint, and update script
COPY zabbix_proxy.conf /etc/zabbix/
COPY entrypoint.sh /entrypoint.sh
COPY zabbix-proxy-update.sh /usr/local/bin/zabbix-proxy-update.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/zabbix-proxy-update.sh

# Write initial version tracker
ARG ZABBIX_VERSION=7.2.3
RUN echo "${ZABBIX_VERSION}" > /etc/zabbix/.installed_version

# Persistent data volume
VOLUME ["/var/lib/zabbix"]

# Zabbix proxy port + SSH
EXPOSE 10051 22

ENTRYPOINT ["/entrypoint.sh"]
