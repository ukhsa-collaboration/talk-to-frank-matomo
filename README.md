# talk-to-frank-matomo

Dockerized Matomo (with MariaDB for local testing), with the Matomo `CustomReports` plugin baked into the image at build time.

## Prerequisites

- Docker + Docker Compose v2
- A Matomo Marketplace token with access to `CustomReports`

## Environment variables

Runtime (used by the container):

- `MATOMO_DATABASE_HOST`: database host (default `mariadb`)
- `MATOMO_DATABASE_USERNAME`: database username (default `user`)
- `MATOMO_DATABASE_PASSWORD`: database password (default `password`)
- `MATOMO_DATABASE_DBNAME`: database name (default `matomo`)
- `MATOMO_TRUSTED_HOSTS`: trusted host for Matomo (default `localhost`)
- `MATOMO_SALT`: Matomo salt (default: generated when `config.ini.php` is generated - this is on every restart for ECS)
- `MATOMO_LICENSE_KEY`: Marketplace license key (used to activate paid plugins like `CustomReports`)
- `MATOMO_PLUGINS`: comma-separated list of plugins to activate via CLI (the plugin must be added to the Docker image)

Build-time (used to download the plugin during `docker build`):

- `MATOMO_LICENSE_KEY`: Marketplace access token (wired into the Compose secret `matomo_license_key`)


## Configure the plugin download token

The build uses a Compose secret backed by an environment variable:

```sh
export MATOMO_LICENSE_KEY='…'
```

## Build and run

```sh
docker compose up --build
```

- Matomo will be available on `http://localhost/` (Compose maps `80:80` by default).
- On first boot with a fresh database, you should be taken through the Matomo web installer.

## Troubleshooting

### “Matomo is already installed” but tables are missing

This typically happens when a `config/config.ini.php` exists (or is generated) but the database is empty or points at the wrong DB.

This repo’s `entrypoint.sh` avoids generating `config/config.ini.php` until it detects Matomo tables in the DB. If you still see this:

- Confirm you rebuilt the image after changes: `docker compose up --build`
- Check which DB Matomo is pointing at (values in `config/config.ini.php` inside the container)

### Enabling CustomReports

`CustomReports` is copied into the image at build time, but Matomo may still require a Marketplace license key at runtime:

- Set `MATOMO_LICENSE_KEY` and restart the `matomo` container, or set it in the Matomo UI.

### Reset everything (drop DB and Matomo config)

If you want a completely fresh install:

```sh
docker compose down -v
docker compose up --build
```

### Apache warning about ServerName

Logs like `AH00558: Could not reliably determine the server's fully qualified domain name` are harmless in local/dev setups.