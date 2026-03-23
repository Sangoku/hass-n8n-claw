FROM n8nio/n8n:latest

ARG NGINX_ALLOWED_IP=172.30.32.2
ENV NGINX_ALLOWED_IP=${NGINX_ALLOWED_IP}

ARG BUILD_VERSION
ARG BUILD_ARCH
ARG POSTGREST_VERSION=v14.7

LABEL \
  io.hass.version="${BUILD_VERSION}" \
  io.hass.type="addon" \
  io.hass.arch="${BUILD_ARCH}"

USER root

# Reinstall apk-tools since n8n removes it
RUN ARCH=$(uname -m) && \
    wget -qO- "http://dl-cdn.alpinelinux.org/alpine/latest-stable/main/${ARCH}/" | \
    grep -o 'href="apk-tools-static-[^"]*\.apk"' | head -1 | cut -d'"' -f2 | \
    xargs -I {} wget -q "http://dl-cdn.alpinelinux.org/alpine/latest-stable/main/${ARCH}/{}" && \
    tar -xzf apk-tools-static-*.apk && \
    ./sbin/apk.static -X http://dl-cdn.alpinelinux.org/alpine/latest-stable/main \
        -U --allow-untrusted add apk-tools && \
    rm -rf sbin apk-tools-static-*.apk

RUN apk add --no-cache --update \
    jq \
    bash \
    npm \
    curl \
    nginx \
    supervisor \
    envsubst \
    postgresql-client \
    gmp \
    python3 \
    make \
    g++

# Install community n8n nodes at build time into /app/custom-nodes
# These are loaded via N8N_CUSTOM_EXTENSIONS=/app/custom-nodes at runtime
RUN mkdir -p /app/custom-nodes && \
    cd /app/custom-nodes && \
    npm install --save \
      n8n-nodes-homeassistantws \
      @berriai/n8n-nodes-litellm

# Download PostgREST binary
# x86-64: linux-static build; aarch64: ubuntu build (no static available)
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
        PGRST_FILE="postgrest-${POSTGREST_VERSION}-ubuntu-aarch64.tar.xz"; \
    else \
        PGRST_FILE="postgrest-${POSTGREST_VERSION}-linux-static-x86-64.tar.xz"; \
    fi && \
    wget -qO /tmp/postgrest.tar.xz \
      "https://github.com/PostgREST/postgrest/releases/download/${POSTGREST_VERSION}/${PGRST_FILE}" && \
    tar -xJf /tmp/postgrest.tar.xz -C /usr/local/bin && \
    chmod +x /usr/local/bin/postgrest && \
    rm /tmp/postgrest.tar.xz

WORKDIR /data

RUN mkdir -p /run/nginx /app/migrations /app/seed /app/workflows

COPY nginx.conf /etc/nginx/nginx.conf.template
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisord.conf

COPY n8n-exports.sh /app/n8n-exports.sh
COPY n8n-entrypoint.sh /app/n8n-entrypoint.sh
COPY nginx-entrypoint.sh /app/nginx-entrypoint.sh
COPY postgrest-entrypoint.sh /app/postgrest-entrypoint.sh
COPY db-init.sh /app/db-init.sh
COPY workflow-import.sh /app/workflow-import.sh
COPY ha-integration.sh /app/ha-integration.sh

COPY migrations/ /app/migrations/
COPY seed/ /app/seed/
COPY workflows/ /app/workflows/

RUN chmod +x /app/n8n-entrypoint.sh \
    && chmod +x /app/nginx-entrypoint.sh \
    && chmod +x /app/n8n-exports.sh \
    && chmod +x /app/postgrest-entrypoint.sh \
    && chmod +x /app/db-init.sh \
    && chmod +x /app/workflow-import.sh \
    && chmod +x /app/ha-integration.sh

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
