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

RUN apt-get update && \
    apt-get install -y --no-install-recommends gettext-base && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/www/html/tmp/cache && \
    chown -R www-data:www-data /var/www/html/tmp/cache

RUN rm -rf /var/www/html/plugins/CustomReports
COPY --from=plugin_fetch /opt/plugins/CustomReports /var/www/html/plugins/CustomReports
RUN chown -R www-data:www-data /var/www/html/plugins/CustomReports

COPY config.ini.php.tmpl /tmp/config.ini.php.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh


ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]