# Zabbix Proxy 7.2.3 for ARM32 (MikroTik RB4011)
# Build with: docker buildx build --platform linux/arm/v7 -t zabbix-proxy-arm32:7.2.3 --load .

FROM --platform=linux/arm/v7 alpine:3.19 AS builder

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

# Stage 2: Minimal runtime
FROM --platform=linux/arm/v7 alpine:3.19

LABEL maintainer="Gabriel - Lighthouse IT"
LABEL description="Zabbix Proxy 7.2.3 for MikroTik RB4011 (ARM32)"
LABEL version="7.2.3"

# Install runtime dependencies only
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
    tzdata

# Create zabbix user and directories
RUN addgroup -S zabbix \
    && adduser -S -G zabbix -h /var/lib/zabbix zabbix \
    && mkdir -p /etc/zabbix /var/lib/zabbix /var/log/zabbix /var/run/zabbix /usr/share/zabbix/database/sqlite3 \
    && chown -R zabbix:zabbix /var/lib/zabbix /var/log/zabbix /var/run/zabbix

# Copy binary and schema from builder
COPY --from=builder /staging/usr/sbin/zabbix_proxy /usr/sbin/
COPY --from=builder /staging/usr/share/zabbix/database/sqlite3/schema.sql /usr/share/zabbix/database/sqlite3/

# Copy config and entrypoint
COPY zabbix_proxy.conf /etc/zabbix/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Persistent data volume
VOLUME ["/var/lib/zabbix"]

# Zabbix proxy port
EXPOSE 10051

USER zabbix

ENTRYPOINT ["/entrypoint.sh"]
CMD ["zabbix_proxy", "-c", "/etc/zabbix/zabbix_proxy.conf", "-f"]
