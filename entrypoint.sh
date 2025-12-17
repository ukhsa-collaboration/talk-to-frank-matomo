#!/bin/bash
set -e

# Signal handling for graceful shutdown
shutdown_requested=false

graceful_shutdown() {
    echo "Received shutdown signal, initiating graceful shutdown..."
    shutdown_requested=true
    
    if pgrep -f apache2 > /dev/null; then
        echo "Stopping Apache processes..."
        pkill -TERM apache2 || true
        
        for _ in $(seq 1 25); do
            if ! pgrep -f apache2 > /dev/null; then
                echo "Apache stopped gracefully"
                break
            fi
            sleep 1
        done
        
        # Force kill if still running
        if pgrep -f apache2 > /dev/null; then
            echo "Force stopping Apache processes..."
            pkill -KILL apache2 || true
        fi
    fi
    
    echo "Graceful shutdown complete"
    exit 0
}

trap graceful_shutdown SIGTERM SIGINT

export MATOMO_DATABASE_HOST=${MATOMO_DATABASE_HOST:-mariadb}
export MATOMO_DATABASE_USERNAME=${MATOMO_DATABASE_USERNAME:-user}
export MATOMO_DATABASE_PASSWORD=${MATOMO_DATABASE_PASSWORD:-password}
export MATOMO_DATABASE_DBNAME=${MATOMO_DATABASE_DBNAME:-matomo}
export MATOMO_SALT=${MATOMO_SALT:-$(openssl rand -hex 32)}
export MATOMO_TRUSTED_HOSTS=${MATOMO_TRUSTED_HOSTS:-localhost}
CONFIG_PATH=/var/www/html/config/config.ini.php
DB_EXISTS_MARKER=/tmp/db_exists

# Permission validation and fixing for non-root user
validate_and_fix_permissions() {
    local dir="$1"
    local expected_permissions="$2"
    
    if [ ! -d "$dir" ]; then
        echo "Creating directory: $dir"
        mkdir -p "$dir" || {
            echo "Error: Cannot create directory $dir"
            return 1
        }
    fi
    
    if [ -n "$expected_permissions" ]; then
        chmod "$expected_permissions" "$dir" 2>/dev/null || {
            echo "Warning: Cannot set permissions $expected_permissions for $dir"
        }
    fi
    
    if [ ! -w "$dir" ]; then
        echo "Warning: Directory $dir is not writable by current user"
        chmod u+w "$dir" 2>/dev/null || {
            echo "Error: Cannot fix permissions for $dir - directory not writable"
            return 1
        }
    fi
    
    # Verify we can create files in the directory
    local test_file="$dir/.permission_test_$$"
    if ! touch "$test_file" 2>/dev/null; then
        echo "Error: Cannot create files in directory $dir"
        return 1
    fi
    rm -f "$test_file"
    
    echo "Permissions validated for: $dir (permissions: ${expected_permissions:-default})"
    return 0
}

setup_secure_temp_handling() {
    echo "Setting up secure temporary file handling..."
    
    local temp_dirs=(
        "/var/www/html/tmp/sessions:755"
        "/var/www/html/tmp/logs:755"
        "/var/www/html/tmp/cache:755"
        "/var/www/html/tmp/cache/tracker:755"
        "/var/www/html/tmp/templates_c:755"
        "/var/www/html/tmp/assets:755"
    )
    
    for dir_perm in "${temp_dirs[@]}"; do
        local dir="${dir_perm%:*}"
        local perm="${dir_perm#*:}"
        
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir" || {
                echo "Error: Cannot create temporary directory $dir"
                return 1
            }
        fi
        
        chmod "$perm" "$dir" 2>/dev/null || {
            echo "Warning: Cannot set permissions $perm for $dir"
        }
        
        # Ensure directory is writable by matomo user
        if [ ! -w "$dir" ]; then
            echo "Error: Temporary directory $dir is not writable"
            return 1
        fi
    done
    
    echo "Secure temporary file handling configured successfully"
    return 0
}

configure_plugin_permissions() {
    echo "Configuring plugin directory permissions..."
    
    local plugin_base="/var/www/html/plugins"
    
    if [ ! -d "$plugin_base" ]; then
        mkdir -p "$plugin_base" || {
            echo "Error: Cannot create plugin directory $plugin_base"
            return 1
        }
    fi
    
    chmod 755 "$plugin_base" 2>/dev/null || {
        echo "Warning: Cannot set permissions for plugin directory"
    }
    
    if [ -d "$plugin_base" ]; then
        find "$plugin_base" -type d -exec chmod 755 {} \; 2>/dev/null || {
            echo "Warning: Cannot set permissions for plugin subdirectories"
        }
        find "$plugin_base" -type f -exec chmod 644 {} \; 2>/dev/null || {
            echo "Warning: Cannot set permissions for plugin files"
        }
    fi
    
    echo "Plugin directory permissions configured successfully"
    return 0
}

configure_config_permissions() {
    echo "Configuring configuration directory permissions..."
    
    local config_dir="/var/www/html/config"
    
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir" || {
            echo "Error: Cannot create config directory $config_dir"
            return 1
        }
    fi
    
    chmod 750 "$config_dir" 2>/dev/null || {
        echo "Warning: Cannot set secure permissions for config directory"
    }
    
    if [ -f "$config_dir/config.ini.php" ]; then
        chmod 640 "$config_dir/config.ini.php" 2>/dev/null || {
            echo "Warning: Cannot set permissions for config.ini.php"
        }
    fi
    
    echo "Configuration directory permissions configured successfully"
    return 0
}

echo "Validating permissions for critical directories..."
validate_and_fix_permissions "/var/www/html" "" || {
    echo "Error: Cannot validate permissions for /var/www/html"
    exit 1
}

validate_and_fix_permissions "/tmp" "" || {
    echo "Error: Cannot validate permissions for /tmp"
    exit 1
}

setup_secure_temp_handling || {
    echo "Error: Failed to set up secure temporary file handling"
    exit 1
}

configure_plugin_permissions || {
    echo "Error: Failed to configure plugin permissions"
    exit 1
}

configure_config_permissions || {
    echo "Error: Failed to configure config permissions"
    exit 1
}

# Populate Matomo files if this is a fresh volume (mirrors upstream entrypoint)
if [ ! -e /var/www/html/matomo.php ]; then
    echo "Populating Matomo files from source..."
    tar cf - --one-file-system -C /usr/src/matomo . | tar xf - -C /var/www/html
fi

echo "Copying health check files..."
if [ -f "/tmp/healthcheck.php" ]; then
    cp /tmp/healthcheck.php /var/www/html/healthcheck.php
    chmod 644 /var/www/html/healthcheck.php
    echo "Health check file copied successfully"
fi

if [ -f "/tmp/ping.php" ]; then
    cp /tmp/ping.php /var/www/html/ping.php
    chmod 644 /var/www/html/ping.php
    echo "Ping file copied successfully"
fi

echo "Creating and validating Matomo directories with secure permissions..."

validate_and_fix_permissions "/var/www/html/config" "750" || {
    echo "Error: Cannot validate permissions for config directory"
    exit 1
}

for dir in "/var/www/html/tmp" "/var/www/html/tmp/cache" "/var/www/html/tmp/cache/tracker" "/var/www/html/tmp/templates_c" "/var/www/html/tmp/assets" "/var/www/html/tmp/logs" "/var/www/html/tmp/sessions"; do
    validate_and_fix_permissions "$dir" "755" || {
        echo "Error: Cannot validate permissions for $dir"
        exit 1
    }
done

run_as_matomo() {
  "$@"
}

check_database_connectivity() {
    local max_attempts=${1:-30}
    local retry_delay=${2:-2}
    local attempt=1
    
    echo "Checking database connectivity (max attempts: $max_attempts)..."
    
    while [ $attempt -le "$max_attempts" ]; do
        if [ "$shutdown_requested" = true ]; then
            echo "Shutdown requested, stopping database connectivity check"
            return 1
        fi
        
        echo "Database connectivity attempt $attempt/$max_attempts..."
        
        if ! php -r "
            \$host = getenv('MATOMO_DATABASE_HOST') ?: 'mariadb';
            \$user = getenv('MATOMO_DATABASE_USERNAME') ?: 'user';
            \$pass = getenv('MATOMO_DATABASE_PASSWORD') ?: 'password';
            \$name = getenv('MATOMO_DATABASE_DBNAME') ?: 'matomo';
            \$mysqli = @new mysqli(\$host, \$user, \$pass, \$name);
            if (\$mysqli->connect_errno) { 
                echo 'Database connection failed: ' . \$mysqli->connect_error . PHP_EOL;
                exit(1); 
            }
            echo 'Database connection successful' . PHP_EOL;
            \$mysqli->close();
            exit(0);
        "; then
            echo "Database connection failed on attempt $attempt"
            if [ $attempt -eq "$max_attempts" ]; then
                echo "Error: Database connectivity check failed after $max_attempts attempts"
                return 1
            fi
            sleep "$retry_delay"
            attempt=$((attempt + 1))
            continue
        fi
        
        echo "Database connectivity verified successfully"
        return 0
    done
    
    return 1
}

setup_health_check_readiness() {
    echo "Setting up health check readiness indicators..."
    
    if [ -f "/var/www/html/healthcheck.php" ]; then
        chmod 644 /var/www/html/healthcheck.php
        echo "Health check endpoint configured at /healthcheck.php"
    fi
    
    if [ -f "/var/www/html/ping.php" ]; then
        chmod 644 /var/www/html/ping.php
        echo "Ping endpoint configured at /ping.php"
    fi
    
    touch /tmp/container_ready
    echo "Container readiness marker created"
}

db_has_schema() {
    rm -f "$DB_EXISTS_MARKER"
    
    if ! check_database_connectivity 5 1; then
        echo "Cannot check schema - database not accessible"
        return 1
    fi
    
    php -r "
    \$host = getenv('MATOMO_DATABASE_HOST') ?: 'mariadb';
    \$user = getenv('MATOMO_DATABASE_USERNAME') ?: 'user';
    \$pass = getenv('MATOMO_DATABASE_PASSWORD') ?: 'password';
    \$name = getenv('MATOMO_DATABASE_DBNAME') ?: 'matomo';
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
    
    if ! check_database_connectivity 30 2; then
        echo "Database connectivity check failed; skipping templated config so the installer can run."
    else
        # Check if database has schema so we know whether to show the install screen
        if db_has_schema; then
            echo "Database is already configured, generating config file from environment variables."
            envsubst < /tmp/config.ini.php.tmpl > "$CONFIG_PATH"
            
            if [ ! -f "$CONFIG_PATH" ] || [ ! -s "$CONFIG_PATH" ]; then
                echo "Error: Failed to generate config file"
                exit 1
            fi
            echo "Config file generated successfully"
        else
            echo "Database not yet configured; skipping templated config so the installer can run."
        fi
    fi
fi

if [ -e "$CONFIG_PATH" ] && [ -n "${MATOMO_LICENSE_KEY:-}" ]; then
  echo "Setting Matomo license key..."
  run_as_matomo php /var/www/html/console marketplace:set-license-key --license-key="$MATOMO_LICENSE_KEY" --no-interaction --quiet || echo "Warning: Failed to set license key, continuing..."
fi

if [ -e "$CONFIG_PATH" ] && [ -n "${MATOMO_PLUGINS:-}" ]; then
  echo "Activating Matomo plugins..."
  IFS=',' read -r -a plugins <<<"$MATOMO_PLUGINS"
  for plugin in "${plugins[@]}"; do
    plugin="$(echo "$plugin" | xargs)"
    [ -n "$plugin" ] || continue
    echo "Activating plugin: $plugin"
    run_as_matomo php /var/www/html/console plugin:activate "$plugin" --no-interaction --quiet || echo "Warning: Failed to activate plugin $plugin, continuing..."
  done
fi

echo "Creating security files..."
run_as_matomo php /var/www/html/console core:create-security-files || echo "Warning: Failed to create security files, continuing..."

echo "Performing final permission validation..."
validate_and_fix_permissions "/var/www/html/config" "750" || echo "Warning: Config directory permissions may be incorrect"
validate_and_fix_permissions "/var/www/html/tmp" "755" || echo "Warning: Temp directory permissions may be incorrect"

setup_health_check_readiness

create_health_check_script() {
    cat > /tmp/healthcheck.sh << 'EOF'
#!/bin/bash
# Health check wrapper script for Docker HEALTHCHECK

# Try to access the health check endpoint via HTTP
curl -f -s -H "User-Agent: healthcheck-docker" http://localhost/healthcheck.php > /dev/null 2>&1
exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo "Health check passed"
    exit 0
else
    echo "Health check failed"
    exit 1
fi
EOF
    chmod +x /tmp/healthcheck.sh
    echo "Health check script created at /tmp/healthcheck.sh"
}

create_health_check_script

echo "Entrypoint setup complete, starting Apache..."

exec "$@" &
apache_pid=$!

while [ "$shutdown_requested" = false ]; do
    if ! kill -0 $apache_pid 2>/dev/null; then
        echo "Apache process has stopped unexpectedly"
        exit 1
    fi
    sleep 1
done

wait $apache_pid
