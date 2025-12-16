#!/bin/bash
set -e

export DB_HOST=${DB_HOST:-mariadb}
export DB_USERNAME=${DB_USERNAME:-user}
export DB_PASSWORD=${DB_PASSWORD:-password}
export DB_NAME=${DB_NAME:-matomo}
export MATOMO_SALT=${MATOMO_SALT:-$(openssl rand -hex 32)}
export MATOMO_TRUSTED_HOSTS=${MATOMO_TRUSTED_HOSTS:-localhost}
CONFIG_PATH=/var/www/html/config/config.ini.php
DB_EXISTS_MARKER=/tmp/db_exists

# Populate Matomo files if this is a fresh volume (mirrors upstream entrypoint)
if [ ! -e /var/www/html/matomo.php ]; then
  tar cf - --one-file-system -C /usr/src/matomo . | tar xf - -C /var/www/html
  chown -R www-data:www-data /var/www/html
fi

mkdir -p /var/www/html/config/
mkdir -p /var/www/html/tmp/cache
chown -R www-data:www-data /var/www/html/tmp/cache

run_as_www_data() {
  local cmd
  cmd="$(printf '%q ' "$@")"
  su -s /bin/bash www-data -c "$cmd"
}

db_has_schema() {
  rm -f "$DB_EXISTS_MARKER"
  php -r "
  \$host = getenv('DB_HOST') ?: 'mariadb';
  \$user = getenv('DB_USERNAME') ?: 'user';
  \$pass = getenv('DB_PASSWORD') ?: 'password';
  \$name = getenv('DB_NAME') ?: 'matomo';
  \$mysqli = @new mysqli(\$host, \$user, \$pass, \$name);
  if (\$mysqli->connect_errno) { exit(2); }
  \$tableCheck = \$mysqli->query(\"SELECT COUNT(*) AS cnt FROM information_schema.tables WHERE table_schema = '\$name' AND table_name = 'matomo_option'\");
  if (!\$tableCheck) { exit(1); }
  \$row = \$tableCheck->fetch_assoc();
  \$cnt = isset(\$row['cnt']) ? (int)\$row['cnt'] : 0;
  if (\$cnt > 0) { @touch('/tmp/db_exists'); exit(0); }
  exit(1);
  "
  [ -f "$DB_EXISTS_MARKER" ]
}

if [ -e "$CONFIG_PATH" ]; then
  echo "Using existing Matomo config."
else
  echo "No config file found; checking database state before generating one..."
  for attempt in $(seq 1 30); do
    if db_has_schema; then
      echo "Database is already configured..."
      break
    fi
    echo "Database not yet configured; waiting... (attempt $attempt/30)"
    sleep 2
  done

  if [ -f "$DB_EXISTS_MARKER" ]; then
    echo "Generating config file from environment variables."
    envsubst < /tmp/config.ini.php.tmpl > "$CONFIG_PATH"
    chown www-data:www-data "$CONFIG_PATH"
  else
    echo "Database not reachable or missing Matomo tables; skipping templated config so the installer can run."
  fi
fi

if [ -e "$CONFIG_PATH" ] && [ -n "${MATOMO_LICENSE_KEY:-}" ]; then
  run_as_www_data php /var/www/html/console marketplace:set-license-key --license-key="$MATOMO_LICENSE_KEY" --no-interaction --quiet
fi

if [ -e "$CONFIG_PATH" ] && [ -n "${MATOMO_PLUGINS:-}" ]; then
  IFS=',' read -r -a plugins <<<"$MATOMO_PLUGINS"
  for plugin in "${plugins[@]}"; do
    plugin="$(echo "$plugin" | xargs)"
    [ -n "$plugin" ] || continue
    run_as_www_data php /var/www/html/console plugin:activate "$plugin" --no-interaction --quiet
  done
fi

php /var/www/html/console core:create-security-files

chown -R www-data:www-data /var/www/html/tmp/cache

exec "$@"
