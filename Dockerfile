ARG CUSTOM_REPORTS_VERSION=5.4.8

FROM debian:bookworm-slim AS plugin_fetch
ARG CUSTOM_REPORTS_VERSION

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl unzip && \
    rm -rf /var/lib/apt/lists/*

RUN --mount=type=secret,id=matomo_license_key,required=true \
    token="$(cat /run/secrets/matomo_license_key)"; \
    if [ -z "${token}" ]; then echo "matomo_license_key secret is empty"; exit 1; fi; \
    tmpdir="$(mktemp -d)"; \
    trap 'rm -rf "$tmpdir"' EXIT; \
    mkdir -p /opt/plugins; \
    \
    curl -sSL -X POST \
      "https://plugins.matomo.org/api/2.0/plugins/CustomReports/download/${CUSTOM_REPORTS_VERSION}" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data "access_token=${token}" \
      -o "$tmpdir/CustomReports.zip" ; \
    unzip -q "$tmpdir/CustomReports.zip" -d /opt/plugins; \
    test -d /opt/plugins/CustomReports

FROM matomo:5.1.0-apache
ARG CUSTOM_REPORTS_VERSION

# Create non-root matomo user with UID 1001 and GID 1001
RUN groupadd -g 1001 matomo && \
    useradd -u 1001 -g 1001 -m -s /bin/bash matomo

# Install only essential packages and clean up to reduce attack surface
RUN apt-get update && \
    apt-get install -y --no-install-recommends gettext-base && \
    apt-get purge -y --auto-remove && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    mkdir -p /var/www/html/tmp/cache && \
    chown -R matomo:matomo /var/www/html/tmp/cache

RUN rm -rf /var/www/html/plugins/CustomReports
COPY --from=plugin_fetch /opt/plugins/CustomReports /var/www/html/plugins/CustomReports
RUN chown -R matomo:matomo /var/www/html/plugins/CustomReports

# Configure Apache to run as non-root user
RUN sed -i 's/User www-data/User matomo/' /etc/apache2/apache2.conf && \
    sed -i 's/Group www-data/Group matomo/' /etc/apache2/apache2.conf

# Set proper ownership and secure permissions for all Matomo directories during build
RUN chown -R matomo:matomo /var/www/html && \
    chown -R matomo:matomo /var/log/apache2 && \
    chown -R matomo:matomo /var/run/apache2 && \
    chown -R matomo:matomo /var/lock/apache2 && \
    # Create all required directories with proper structure
    mkdir -p /var/www/html/config \
             /var/www/html/tmp/cache/tracker \
             /var/www/html/tmp/templates_c \
             /var/www/html/tmp/assets \
             /var/www/html/tmp/logs \
             /var/www/html/tmp/sessions \
             /var/www/html/plugins \
             /var/www/html/misc/user && \
    # Set secure ownership for configuration directories (Requirement 4.1)
    chown -R matomo:matomo /var/www/html/config && \
    chmod 750 /var/www/html/config && \
    # Ensure cache and temporary directories are writable by matomo user (Requirement 4.2)
    chown -R matomo:matomo /var/www/html/tmp && \
    chmod 755 /var/www/html/tmp && \
    chmod 755 /var/www/html/tmp/cache && \
    chmod 755 /var/www/html/tmp/cache/tracker && \
    chmod 755 /var/www/html/tmp/templates_c && \
    chmod 755 /var/www/html/tmp/assets && \
    chmod 755 /var/www/html/tmp/logs && \
    chmod 755 /var/www/html/tmp/sessions && \
    # Configure plugin directories with appropriate permissions (Requirement 4.3)
    chown -R matomo:matomo /var/www/html/plugins && \
    chmod 755 /var/www/html/plugins && \
    # Set up secure temporary file handling (Requirement 4.4, 4.5)
    chown -R matomo:matomo /var/www/html/misc && \
    chmod 750 /var/www/html/misc/user

COPY config.ini.php.tmpl /tmp/config.ini.php.tmpl
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.php /tmp/healthcheck.php
COPY healthcheck.sh /tmp/healthcheck.sh
COPY ping.php /tmp/ping.php
RUN chmod 0755 /entrypoint.sh && \
    chmod 0755 /tmp/healthcheck.sh && \
    chown matomo:matomo /entrypoint.sh && \
    chown matomo:matomo /tmp/healthcheck.php && \
    chown matomo:matomo /tmp/healthcheck.sh && \
    chown matomo:matomo /tmp/ping.php

# Configure Docker health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD /tmp/healthcheck.sh

# Switch to non-root user
USER matomo

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]