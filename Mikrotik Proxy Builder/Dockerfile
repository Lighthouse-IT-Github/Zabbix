# Zabbix Proxy + Agent2 for ARM (MikroTik RouterOS)
# v4.0.0 - Proxy + Agent2, ARM32 + ARM64
# Build with: docker buildx build --platform linux/arm/v7 -t zabbix-proxy-arm32:7.2.3 --load .
#         or: docker buildx build --platform linux/arm64   -t zabbix-proxy-arm64:7.2.3 --load .

FROM alpine:3.19 AS builder

ARG TARGETARCH
ENV ZABBIX_VERSION=7.4.8

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

# Download and extract Zabbix source
RUN curl -LO https://cdn.zabbix.com/zabbix/sources/stable/7.4/zabbix-${ZABBIX_VERSION}.tar.gz \
    && tar xzf zabbix-${ZABBIX_VERSION}.tar.gz

WORKDIR /build/zabbix-${ZABBIX_VERSION}

# Configure with SQLite proxy + agent2
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

# Install to staging directory and copy schema
RUN make DESTDIR=/staging install \
    && strip /staging/usr/sbin/zabbix_proxy \
    && mkdir -p /staging/usr/share/zabbix/database/sqlite3 \
    && cp database/sqlite3/schema.sql /staging/usr/share/zabbix/database/sqlite3/

# Copy agent2 binary to staging (built by top-level make via --enable-agent2)
RUN cp src/go/bin/zabbix_agent2 /staging/usr/sbin/zabbix_agent2 \
    && strip /staging/usr/sbin/zabbix_agent2 || true

# =============================================================================
# Stage 2: Lean Alpine runtime
# =============================================================================
FROM alpine:3.19

LABEL maintainer="Lighthouse IT"
LABEL description="Zabbix Proxy + Agent2 for MikroTik RouterOS (ARM)"
LABEL version="7.4.8"

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
    file \
    net-snmp \
    net-snmp-libs \
    libssh2 \
    openipmi-libs \
    unixodbc \
    fping \
    traceroute \
    nmap \
    sudo

# Ensure fping is available at both /usr/sbin/fping and /usr/bin/fping
# Also set setuid so the zabbix user can send ICMP pings
RUN if [ -f /usr/sbin/fping ] && [ ! -f /usr/bin/fping ]; then \
        ln -s /usr/sbin/fping /usr/bin/fping; \
    elif [ -f /usr/bin/fping ] && [ ! -f /usr/sbin/fping ]; then \
        ln -s /usr/bin/fping /usr/sbin/fping; \
    fi \
    && chmod 4755 /usr/sbin/fping

# Allow zabbix user to run commands via sudo (for UserParameter scripts)
RUN echo "zabbix ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/zabbix \
    && chmod 0440 /etc/sudoers.d/zabbix

# Configure openssh - always running, root login enabled
RUN mkdir -p /var/run/sshd \
    && ssh-keygen -A \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Create zabbix user and directories
RUN addgroup -S zabbix \
    && adduser -S -G zabbix -h /var/lib/zabbix zabbix \
    && mkdir -p /etc/zabbix /etc/zabbix/zabbix_agent2.d \
        /var/lib/zabbix /var/log/zabbix /var/run/zabbix \
        /usr/share/zabbix/database/sqlite3 \
    && chown -R zabbix:zabbix /var/lib/zabbix /var/log/zabbix /var/run/zabbix

# Copy binaries and schema from builder
COPY --from=builder /staging/usr/sbin/zabbix_proxy /usr/sbin/
COPY --from=builder /staging/usr/sbin/zabbix_agent2 /usr/sbin/
COPY --from=builder /staging/usr/share/zabbix/database/sqlite3/schema.sql /usr/share/zabbix/database/sqlite3/

# Copy configs, entrypoint, and update script
COPY zabbix_proxy.conf /etc/zabbix/
COPY zabbix_agent2.conf /etc/zabbix/
COPY entrypoint.sh /entrypoint.sh
COPY zabbix-update.sh /usr/local/bin/zabbix-update.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/zabbix-update.sh

# Write initial version tracker
ARG ZABBIX_VERSION=7.4.8
RUN echo "${ZABBIX_VERSION}" > /etc/zabbix/.installed_version

# Persistent data volume
VOLUME ["/var/lib/zabbix"]

# Zabbix proxy + agent2 + SSH
EXPOSE 10051 10050 22

ENTRYPOINT ["/entrypoint.sh"]
