#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  Prometheon Wizard  |  Install · Update · Uninstall
#  Usage:  sudo bash prometheon_wizard.sh [install|update [version]|repair|uninstall] [-v] [--delete-volumes]
#          sudo bash prometheon_wizard.sh          ← interactive menu
# ─────────────────────────────────────────────────────────────────────────────

WIZARD_VERSION="1.3.0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Flags and Release Channels
VERBOSE=false
DELETE_VOLUMES=false
OVERWRITE_CONFIGS=true

# ── Release Channels ─────────────────────────────────────────────────────────
# Client channel: stable release only (SMS blasting + AI TTS Extension).
# Developer channel: Docker tag "latest" (WIP) or pinned "1.6" (next release preview).
WIZARD_RELEASE_CHANNEL="${WIZARD_RELEASE_CHANNEL:-client}"
CLIENT_VERSION="1.6"
DEVELOPER_VERSION="1.6"
DEVELOPER_DEFAULT_TAG="latest"

# Pinned Asterisk image. Never use :latest — a new major (e.g. 23) can ship
# config/doc changes that stop Asterisk from booting. Keep in sync with the
# hardcoded tag in the compose heredoc below and in the repo docker-compose.yml.
ASTERISK_IMAGE="andrius/asterisk:22.11.0_debian-trixie"

log()   { echo -e "${GREEN}[✔]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1"; exit 1; }
hr()    { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }

# Verbose logging function
debug() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Run command with optional verbose output
run_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        "$@"
    else
        "$@" 2>/dev/null
    fi
}

# Pull stack images without relying on docker-compose.yml (safe before compose is fixed).
_pull_infra_images() {
    info "Pulling postgres, redis, nginx, asterisk..."
    docker pull postgres:17
    docker pull redis:latest
    docker pull nginx:alpine
    docker pull "${ASTERISK_IMAGE}"
    log "Infrastructure images ready"
}

_compose_validate() {
    cd "${INSTALL_DIR}"
    if docker compose config -q 2>/dev/null; then
        return 0
    fi
    warn "docker-compose.yml is invalid:"
    docker compose config 2>&1 | head -30 || true
    return 1
}

_compose_up() {
    cd "${INSTALL_DIR}"
    info "Starting containers (docker compose up -d)..."
    if docker compose up -d --remove-orphans; then
        log "Containers started"
        return 0
    fi
    warn "docker compose up failed. Checking compose file..."
    docker compose config 2>&1 | head -30 || true
    error "Could not start stack. Fix errors above, then: cd ${INSTALL_DIR} && sudo docker compose up -d"
}

# Write pjsip.conf snippets (always refresh trunk + includes).
_write_pjsip_prometheon() {
    local AST_DIR="${INSTALL_DIR}/asterisk"

    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${AST_DIR}/pjsip.conf" ]]; then
        cat > "${AST_DIR}/pjsip.conf" <<'__AST_PJSIP__'
; Prometheon — trunk definitions in pjsip_trunks.conf
#include pjsip_transports.conf
#include pjsip_trunks.conf
#include pjsip_extensions.conf
#include pjsip_custom.conf
__AST_PJSIP__
    fi

    if [[ ! -f "${AST_DIR}/pjsip_custom.conf" ]]; then
        cat > "${AST_DIR}/pjsip_custom.conf" <<'__AST_PJSIP_CUSTOM__'
; Prometheon — pjsip_custom.conf
; Use this file to define custom PJSIP endpoints, transports, or overrides.
; The wizard will NEVER overwrite this file during updates or repairs.
__AST_PJSIP_CUSTOM__
    fi

    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${AST_DIR}/pjsip_transports.conf" ]]; then
        cat > "${AST_DIR}/pjsip_transports.conf" <<'__AST_PJSIP_TR__'
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
allow_reload=yes

[transport-tcp]
type=transport
protocol=tcp
bind=0.0.0.0:5060
allow_reload=yes
__AST_PJSIP_TR__
    fi

    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${AST_DIR}/pjsip_trunks.conf" ]]; then
        cat > "${AST_DIR}/pjsip_trunks.conf" <<'__AST_PJSIP_TRUNK__'
; Prometheon — pjsip_trunks.conf
; Trunks are managed via the Web GUI.
__AST_PJSIP_TRUNK__
    fi
}

# Ensure PJSIP is up and endpoint tg1600 exists (required for TTS outbound).
_asterisk_bootstrap_pjsip() {
    local ctr="prometheon_asterisk"
    if ! docker ps --format '{{.Names}}' | grep -qx "$ctr"; then
        warn "Asterisk container is not running — skipping PJSIP bootstrap"
        return 1
    fi

    local i
    for i in $(seq 1 20); do
        if docker exec "$ctr" asterisk -rx "core show version" &>/dev/null; then
            break
        fi
        sleep 2
    done

    if ! docker exec "$ctr" asterisk -rx "core show channeltypes" 2>&1 | grep -q "PJSIP"; then
        warn "PJSIP channel type not registered — restart Asterisk: docker compose restart asterisk"
        return 1
    fi
    log "PJSIP channel type is registered"

    info "Reloading PJSIP and TTS dialplan..."
    docker exec "$ctr" asterisk -rx "pjsip reload" 2>&1 | tail -5 || true
    docker exec "$ctr" asterisk -rx "dialplan reload" 2>&1 | tail -3 || true
    sleep 2

    if docker exec "$ctr" asterisk -rx "pjsip show endpoints" &>/dev/null; then
        log "PJSIP module is active and responsive"
    else
        warn "PJSIP show endpoints check failed."
        return 1
    fi

    local sample
    sample=$(ls "${INSTALL_DIR}/asterisk_lib/sounds/"tts_*.wav 2>/dev/null | head -1 || true)
    if [[ -z "$sample" ]]; then
        sample=$(ls "${INSTALL_DIR}/asterisk_lib/sounds/custom/"*.wav 2>/dev/null | head -1 || true)
    fi
    if [[ -n "$sample" ]]; then
        local base
        base=$(basename "$sample" .wav)
        if docker exec "$ctr" test -r "/var/lib/asterisk/sounds/${base}.wav" \
            -o -r "/var/lib/asterisk/sounds/${base}.ulaw" 2>/dev/null; then
            log "TTS sounds visible in Asterisk container (${base}.wav or .ulaw)"
        else
            warn "TTS audio not readable in container at /var/lib/asterisk/sounds/${base}.*"
        fi
    fi
    return 0
}

# Copy custom/*.wav -> tts_*.wav and build ulaw/gsm via backend ffmpeg (host may lack ffmpeg).
_publish_tts_sounds() {
    local sounds="${INSTALL_DIR}/asterisk_lib/sounds"
    local bctr="prometheon_backend"
    mkdir -p "${sounds}" "${sounds}/custom"
    chmod -R a+rX "${sounds}" 2>/dev/null || true
    chown -R 1000:1000 "${sounds}" 2>/dev/null || true

    shopt -s nullglob
    for f in "${sounds}/custom/"*.wav; do
        local base="${f##*/}"
        base="${base%.wav}"
        cp -f "$f" "${sounds}/tts_${base}.wav"
        log "Synced tts_${base}.wav from custom/"
    done

    local wav_count=0
    for _f in "${sounds}/"tts_*.wav; do
        ((wav_count++)) || true
    done
    if [[ "$wav_count" -eq 0 ]]; then
        warn "No tts_*.wav under ${sounds} — generate TTS in Prometheon or add custom/*.wav"
        shopt -u nullglob
        return 0
    fi

    if ! docker ps --format '{{.Names}}' | grep -qx "$bctr"; then
        warn "Backend not running — tts_*.wav copied only (no ulaw/gsm). Run: docker compose up -d && sudo bash prometheon_wizard.sh repair"
        shopt -u nullglob
        return 0
    fi

    for f in "${sounds}/"tts_*.wav; do
        local name="${f##*/}"
        local stem="${name%.wav}"
        info "Encoding ${stem} (ulaw + gsm) via ${bctr}..."
        docker exec "$bctr" ffmpeg -y -i "/var/lib/asterisk/sounds/${name}" \
            -ar 8000 -ac 1 -acodec pcm_mulaw -f mulaw \
            "/var/lib/asterisk/sounds/${stem}.ulaw" 2>/dev/null \
            || warn "ulaw encode failed for ${stem}"
        docker exec "$bctr" ffmpeg -y -i "/var/lib/asterisk/sounds/${name}" \
            -ar 8000 -ac 1 -acodec gsm -f gsm \
            "/var/lib/asterisk/sounds/${stem}.gsm" 2>/dev/null \
            || warn "gsm encode failed for ${stem}"
        [[ -s "${sounds}/${stem}.ulaw" ]] || rm -f "${sounds}/${stem}.ulaw" 2>/dev/null || true
        [[ -s "${sounds}/${stem}.gsm" ]] || rm -f "${sounds}/${stem}.gsm" 2>/dev/null || true
    done
    shopt -u nullglob
    log "TTS sounds ready: ${sounds}/tts_*.{wav,ulaw,gsm}"
}

INSTALL_DIR="/opt/prometheon"

# ─── Embedded assets ─────────────────────────────────────────────────────────
# Written to INSTALL_DIR during install and refresh on update.
# Copy only this script to the server: sudo bash prometheon_wizard.sh update

# Append KEY=value to .env when missing (never overwrites existing values).
_migrate_env() {
    [[ -f "${INSTALL_DIR}/.env" ]] || return 0
    local key="$1" value="$2"
    if ! grep -q "^${key}=" "${INSTALL_DIR}/.env" 2>/dev/null; then
        echo "${key}=${value}" >> "${INSTALL_DIR}/.env"
        log "Added ${key} to .env"
    fi
}

_migrate_env_asterisk() {
    [[ -f "${INSTALL_DIR}/.env" ]] || return 0
    if ! grep -q "^AMI_PASSWORD=.\+" "${INSTALL_DIR}/.env" 2>/dev/null; then
        local AMI_PASSWORD
        AMI_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
        echo "" >> "${INSTALL_DIR}/.env"
        echo "AMI_PASSWORD=${AMI_PASSWORD}" >> "${INSTALL_DIR}/.env"
        log "AMI_PASSWORD generated and added to .env"
    fi
    _migrate_env TTS_AMI_HOST asterisk
    _migrate_env TTS_AMI_PORT 5038
    _migrate_env TTS_AMI_USER prometheon
    _migrate_env TTS_AMI_CONTEXT ami-tts-out
    _migrate_env TTS_AMI_TRUNK tg1600
    # Do not overwrite TTS_GSM_PORT if already set (0 = Simple Mode, 15 = prefix route).
    _migrate_env "TTS_CALLER_ID" "Prometheon <0000>"
    _migrate_env TTS_RECORDINGS_DIR /app/tts_recordings
    _migrate_env ASTERISK_SOUNDS_DIR /var/lib/asterisk/sounds

    # Ensure ASTERISK_DB and other keys are migrated for the 1.5 update:
    local AMI_PASSWORD_VAL
    AMI_PASSWORD_VAL=$(grep "^AMI_PASSWORD=" "${INSTALL_DIR}/.env" | cut -d= -f2- || true)
    local TTS_AMI_USER_VAL
    TTS_AMI_USER_VAL=$(grep "^TTS_AMI_USER=" "${INSTALL_DIR}/.env" | cut -d= -f2- || true)
    [[ -z "$TTS_AMI_USER_VAL" ]] && TTS_AMI_USER_VAL="prometheon"

    _migrate_env DB_HOST postgres
    _migrate_env ASTERISK_DB asterisk_rt
    _migrate_env ASTERISK_AMI_HOST asterisk
    _migrate_env ASTERISK_AMI_PORT 5038
    _migrate_env ASTERISK_AMI_USER "${TTS_AMI_USER_VAL}"
    _migrate_env ASTERISK_AMI_SECRET "${AMI_PASSWORD_VAL}"
}

_write_compose() {
    debug "Writing docker-compose.yml"
    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        cat > "${INSTALL_DIR}/docker-compose.yml" <<'__COMPOSE__'
services:

  nginx:
    image: nginx:alpine
    container_name: prometheon_nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./certs:/etc/nginx/certs:ro
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx_custom.d:/etc/nginx/custom.d:ro
    depends_on:
      backend:
        condition: service_healthy
      frontend:
        condition: service_started
    networks:
      - prometheon_net
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

  postgres:
    image: postgres:17
    container_name: prometheon_postgres
    restart: always
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-prometheon}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB:-prometheon_db}
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-db.sh:/docker-entrypoint-initdb.d/00-init-db.sh:ro
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
      - ./init-asterisk-rt.sql:/docker-entrypoint-initdb.d/init-asterisk-rt.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-prometheon} -d ${POSTGRES_DB:-prometheon_db}"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s
    networks:
      - prometheon_net
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    image: redis:latest
    container_name: prometheon_redis
    restart: always
    command: redis-server --appendonly yes --requirepass "${REDIS_PASSWORD}"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 15s
    networks:
      - prometheon_net
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  frontend:
    image: kaizotechnologies/prometheon-1_frontend:${PROMETHEON_VERSION:-1.6}
    container_name: prometheon_frontend
    restart: always
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    networks:
      - prometheon_net
    depends_on:
      backend:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 768M
        reservations:
          memory: 256M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  backend:
    image: kaizotechnologies/prometheon-1_backend:${PROMETHEON_VERSION:-1.6}
    container_name: prometheon_backend
    restart: always
    command: ["python3", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
    env_file:
      - .env
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-prometheon}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-prometheon_db}
      SQLITE_URL: sqlite+aiosqlite:////app/data/backup.db
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      CELERY_BROKER_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      CELERY_RESULT_BACKEND: redis://:${REDIS_PASSWORD}@redis:6379/2
      TTS_RECORDINGS_DIR: /app/tts_recordings
      ASTERISK_SOUNDS_DIR: /var/lib/asterisk/sounds
      ASTERISK_CONF_DIR: /etc/asterisk
    volumes:
      - ./data:/app/data
      - ./backups:/app/backups
      - ./license:/app/license
      - ./tts_recordings:/app/tts_recordings
      - ./asterisk_lib/sounds:/var/lib/asterisk/sounds
      - ./asterisk:/etc/asterisk
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      asterisk:
        condition: service_started
    healthcheck:
      test: ["CMD", "python3", "-c",
             "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 60s
    networks:
      - prometheon_net
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

  celery_worker:
    image: kaizotechnologies/prometheon-1_backend:${PROMETHEON_VERSION:-1.6}
    container_name: prometheon_celery_worker
    restart: always
    command: ["python3", "-m", "celery", "-A", "app.workers.celery_app",
              "worker", "--loglevel=warning", "--concurrency=4"]
    env_file:
      - .env
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-prometheon}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-prometheon_db}
      SQLITE_URL: sqlite+aiosqlite:////app/data/backup.db
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      CELERY_BROKER_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      CELERY_RESULT_BACKEND: redis://:${REDIS_PASSWORD}@redis:6379/2
    volumes:
      - ./data:/app/data
      - ./backups:/app/backups
      - ./license:/app/license
      - ./tts_recordings:/app/tts_recordings
      - ./asterisk_lib/sounds:/var/lib/asterisk/sounds
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - prometheon_net
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

  celery_beat:
    image: kaizotechnologies/prometheon-1_backend:${PROMETHEON_VERSION:-1.6}
    container_name: prometheon_celery_beat
    restart: always
    command: ["python3", "-m", "celery", "-A", "app.workers.celery_app",
              "beat", "--loglevel=warning", "--schedule", "/app/data/celerybeat-schedule"]
    env_file:
      - .env
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-prometheon}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-prometheon_db}
      SQLITE_URL: sqlite+aiosqlite:////app/data/backup.db
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      CELERY_BROKER_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      CELERY_RESULT_BACKEND: redis://:${REDIS_PASSWORD}@redis:6379/2
    volumes:
      - ./data:/app/data
      - ./backups:/app/backups
      - ./license:/app/license
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - prometheon_net
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  asterisk:
    image: andrius/asterisk:22.11.0_debian-trixie
    container_name: prometheon_asterisk
    restart: always
    ports:
      - "5060:5060/udp"
      - "5060:5060/tcp"
      - "5038:5038"
      - "10000-10099:10000-10099/udp"
    volumes:
      - ./asterisk:/etc/asterisk
      - ./asterisk_spool:/var/spool/asterisk
      - ./asterisk_lib:/var/lib/asterisk
      - ./asterisk_lib/sounds:/var/lib/asterisk/sounds
      - ./asterisk_log:/var/log/asterisk
    networks:
      - prometheon_net
    healthcheck:
      test: ["CMD-SHELL", "asterisk -rx 'core show version' >/dev/null && asterisk -rx 'core show channeltypes' | grep -q PJSIP"]
      interval: 30s
      timeout: 10s
      retries: 8
      start_period: 45s
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"


volumes:
  postgres_data:
  redis_data:

networks:
  prometheon_net:
    driver: bridge
__COMPOSE__
    else
        info "docker-compose.yml exists → skipping overwrite"
    fi

    if [[ ! -f "${INSTALL_DIR}/docker-compose.override.yml" ]]; then
        cat > "${INSTALL_DIR}/docker-compose.override.yml" <<'__COMPOSE_OVERRIDE__'
# Prometheon — docker-compose.override.yml
# Use this file to customize services, edit ports, or adjust volumes.
# The wizard will NEVER overwrite this file during updates or repairs.
#
# Examples:
#
# services:
#   nginx:
#     ports:
#       - "8080:80"  # Map custom external port
#
#   backend:
#     environment:
#       - CUSTOM_ENV_VAR=value
__COMPOSE_OVERRIDE__
    fi
}

_write_nginx() {
    debug "Writing nginx.conf"
    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${INSTALL_DIR}/nginx.conf" ]]; then
        cat > "${INSTALL_DIR}/nginx.conf" <<'__NGINX__'
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;

    server_tokens off;

    gzip            on;
    gzip_vary       on;
    gzip_min_length 1024;
    gzip_proxied    any;
    gzip_comp_level 5;
    gzip_types
        text/plain text/css text/xml text/javascript
        application/json application/javascript application/xml
        application/rss+xml image/svg+xml;

    # User custom http configuration overrides
    include /etc/nginx/custom.d/http_*.conf;

    upstream backend {
        server backend:8000;
        keepalive 32;
    }

    upstream frontend {
        server frontend:3000;
        keepalive 32;
    }

    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate     /etc/nginx/certs/cert.pem;
        ssl_certificate_key /etc/nginx/certs/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256;
        ssl_prefer_server_ciphers off;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;

        client_max_body_size 20M;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options    "nosniff" always;
        add_header X-Frame-Options           "DENY" always;
        add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy        "camera=(), microphone=(), geolocation=(), payment=()" always;

        location /api/sms-inbox/ws {
            proxy_pass         http://backend;
            proxy_http_version 1.1;
            proxy_set_header   Upgrade $http_upgrade;
            proxy_set_header   Connection "upgrade";
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_read_timeout 3600s;
        }

        location /api/backups {
            proxy_pass             http://backend;
            proxy_set_header       Host $host;
            proxy_set_header       X-Real-IP $remote_addr;
            proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header       X-Forwarded-Proto $scheme;
            proxy_http_version     1.1;
            proxy_set_header       Connection "";
            proxy_read_timeout     900s;
            proxy_connect_timeout  10s;
            proxy_send_timeout     900s;
            client_max_body_size   500M;
        }

        location /api/ {
            proxy_pass             http://backend;
            proxy_set_header       Host $host;
            proxy_set_header       X-Real-IP $remote_addr;
            proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header       X-Forwarded-Proto $scheme;
            proxy_http_version     1.1;
            proxy_set_header       Connection "";
            proxy_read_timeout     120s;
            proxy_connect_timeout  10s;
            proxy_send_timeout     120s;
        }

        location /health {
            proxy_pass       http://backend;
            proxy_set_header Host $host;
            access_log       off;
        }

        location /_next/static/ {
            proxy_pass   http://frontend;
            proxy_set_header Host $host;
            add_header   Cache-Control "public, max-age=31536000, immutable";
            access_log   off;
        }

        location / {
            proxy_pass             http://frontend;
            proxy_http_version     1.1;
            proxy_set_header       Upgrade $http_upgrade;
            proxy_set_header       Connection "upgrade";
            proxy_set_header       Host $host;
            proxy_set_header       X-Real-IP $remote_addr;
            proxy_set_header       X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header       X-Forwarded-Proto $scheme;
            proxy_connect_timeout  10s;
            proxy_read_timeout     60s;
        }

        # User custom server location/settings overrides
        include /etc/nginx/custom.d/server_*.conf;
    }
}
__NGINX__
    else
        info "nginx.conf exists → skipping overwrite"
    fi

    mkdir -p "${INSTALL_DIR}/nginx_custom.d"
    if [[ ! -f "${INSTALL_DIR}/nginx_custom.d/http_custom.conf.example" ]]; then
        cat > "${INSTALL_DIR}/nginx_custom.d/http_custom.conf.example" <<'__NGINX_HTTP_EXAMPLE__'
# Example HTTP-level customizations (e.g. custom upstream, variables)
# Rename this file to http_custom.conf to activate.
# upstream custom_service {
#     server 127.0.0.1:8080;
# }
__NGINX_HTTP_EXAMPLE__
    fi
    if [[ ! -f "${INSTALL_DIR}/nginx_custom.d/server_custom.conf.example" ]]; then
        cat > "${INSTALL_DIR}/nginx_custom.d/server_custom.conf.example" <<'__NGINX_SERVER_EXAMPLE__'
# Example server-level customizations (e.g. custom location blocks)
# Rename this file to server_custom.conf to activate.
# location /my-custom-app {
#     proxy_pass http://custom_service;
# }
__NGINX_SERVER_EXAMPLE__
    fi
}

_write_sql() {
    debug "Writing database initialization scripts"
    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${INSTALL_DIR}/init-db.sh" ]]; then
        cat > "${INSTALL_DIR}/init-db.sh" <<'__SQL_INIT_DB__'
#!/bin/bash
set -e

# 1. Run the main init.sql (pgcrypto + asterisk_rt database creation)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/init.sql

# 2. Run the asterisk_rt schema (tables for Trunks, Extensions, Outbound Routes)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "asterisk_rt" -f /docker-entrypoint-initdb.d/init-asterisk-rt.sql

echo "=== Prometheon-1 database initialization complete ==="
__SQL_INIT_DB__
        chmod +x "${INSTALL_DIR}/init-db.sh"
    fi

    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${INSTALL_DIR}/init.sql" ]]; then
        cat > "${INSTALL_DIR}/init.sql" <<'__SQL__'
-- Prometheon-1 | PostgreSQL initialisation
-- Executed once on first startup when the data volume is empty.

-- pgcrypto: enables gen_random_bytes(), pgp_sym_encrypt/decrypt(), etc.
-- Available for column-level encryption of sensitive fields if needed in future
-- schema migrations (e.g. AES-encrypted audit rows or config secrets).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Create the asterisk_rt database for PBX Realtime tables (Trunks, Routes, etc.)
-- This runs as the POSTGRES_USER during container init.
-- ---------------------------------------------------------------------------
-- NOTE: CREATE DATABASE cannot run inside a transaction block, so we use
-- the \gexec trick to conditionally execute it.
SELECT 'CREATE DATABASE asterisk_rt'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'asterisk_rt')\gexec
__SQL__
    fi

    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${INSTALL_DIR}/init-asterisk-rt.sql" ]]; then
        cat > "${INSTALL_DIR}/init-asterisk-rt.sql" <<'__SQL_ASTERISK_RT__'
-- ---------------------------------------------------------------------------
-- Asterisk Realtime schema for prometheon-1
-- Executed against the asterisk_rt database after it is created.
-- ---------------------------------------------------------------------------

-- =========================================================================
-- PBX Configuration Tables (managed by the UI via pbx_config.py)
-- =========================================================================

CREATE TABLE IF NOT EXISTS trunks (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(128) UNIQUE NOT NULL,
    tech        VARCHAR(32) DEFAULT 'pjsip',
    callerid    VARCHAR(128),
    status      VARCHAR(32) DEFAULT 'active',
    settings    JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS outbound_routes (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(128) NOT NULL,
    outbound_cid    VARCHAR(128),
    password        VARCHAR(128),
    status          VARCHAR(32) DEFAULT 'active',
    settings        JSONB DEFAULT '{}'::jsonb
);

-- =========================================================================
-- Asterisk PJSIP Realtime Tables
-- These are read directly by Asterisk via res_config_pgsql / res_sorcery_realtime
-- =========================================================================

CREATE TABLE IF NOT EXISTS ps_endpoints (
    id                      VARCHAR(128) PRIMARY KEY,
    type                    VARCHAR(32) DEFAULT 'endpoint',
    transport               VARCHAR(128),
    context                 VARCHAR(128),
    disallow                VARCHAR(256),
    allow                   VARCHAR(256),
    auth                    VARCHAR(128),
    aors                    VARCHAR(128),
    direct_media            VARCHAR(8),
    rewrite_contact         VARCHAR(8),
    rtp_symmetric           VARCHAR(8),
    force_rport             VARCHAR(8),
    webrtc                  VARCHAR(8),
    media_encryption        VARCHAR(32),
    dtls_auto_generate_cert VARCHAR(8),
    ice_support             VARCHAR(8),
    use_avpf                VARCHAR(8),
    identify_by             VARCHAR(128),
    outbound_auth           VARCHAR(128),
    dtmf_mode               VARCHAR(32),
    callerid                VARCHAR(256)
);

CREATE TABLE IF NOT EXISTS ps_auths (
    id          VARCHAR(128) PRIMARY KEY,
    type        VARCHAR(32) DEFAULT 'auth',
    auth_type   VARCHAR(32) DEFAULT 'userpass',
    username    VARCHAR(128),
    password    VARCHAR(256)
);

CREATE TABLE IF NOT EXISTS ps_aors (
    id                VARCHAR(128) PRIMARY KEY,
    type              VARCHAR(32) DEFAULT 'aor',
    max_contacts      INTEGER DEFAULT 1,
    remove_existing   VARCHAR(8) DEFAULT 'yes',
    contact           VARCHAR(512),
    qualify_frequency INTEGER DEFAULT 0,
    support_path      VARCHAR(8)
);

CREATE TABLE IF NOT EXISTS ps_endpoint_id_ips (
    id       VARCHAR(128) PRIMARY KEY,
    type     VARCHAR(32) DEFAULT 'identify',
    endpoint VARCHAR(128),
    match    VARCHAR(256)
);

-- =========================================================================
-- Asterisk Dialplan Realtime Table
-- Used by _sync_outbound_routes / _sync_extensions for dynamic dialplan
-- =========================================================================

CREATE TABLE IF NOT EXISTS extensions (
    id       SERIAL PRIMARY KEY,
    context  VARCHAR(128) NOT NULL,
    exten    VARCHAR(128) NOT NULL,
    priority INTEGER NOT NULL DEFAULT 1,
    app      VARCHAR(128),
    appdata  TEXT
);

CREATE INDEX IF NOT EXISTS idx_extensions_context ON extensions (context);

-- =========================================================================
-- Asterisk PJSIP Globals (optional, used by _sync_sip_settings)
-- =========================================================================

CREATE TABLE IF NOT EXISTS ps_globals (
    id   VARCHAR(128) PRIMARY KEY DEFAULT '0',
    type VARCHAR(32) DEFAULT 'global'
);

-- =========================================================================
-- Additional PBX Configuration Tables
-- Queried by the sync engine (_write_extensions_local_conf)
-- =========================================================================

CREATE TABLE IF NOT EXISTS inbound_routes (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(128),
    description     TEXT DEFAULT '',
    did             VARCHAR(128),
    cid             VARCHAR(128),
    destination     VARCHAR(128),
    status          VARCHAR(32) DEFAULT 'active',
    settings        JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS ivrs (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(128) NOT NULL,
    description TEXT DEFAULT '',
    status      VARCHAR(32) DEFAULT 'active',
    settings    JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS ring_groups (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(128),
    group_number    VARCHAR(32),
    description     TEXT DEFAULT '',
    extension_list  TEXT DEFAULT '',
    status          VARCHAR(32) DEFAULT 'active',
    settings        JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS recordings (
    id              SERIAL PRIMARY KEY,
    displayname     VARCHAR(255) NOT NULL,
    filename        VARCHAR(255) NOT NULL,
    description     TEXT DEFAULT '',
    created_at      TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS cdr (
    id          SERIAL PRIMARY KEY,
    accountcode VARCHAR(20),
    src         VARCHAR(80),
    dst         VARCHAR(80),
    dcontext    VARCHAR(80),
    clid        VARCHAR(80),
    channel     VARCHAR(80),
    dstchannel  VARCHAR(80),
    lastapp     VARCHAR(80),
    lastdata    VARCHAR(80),
    start       TIMESTAMP,
    answer      TIMESTAMP,
    "end"       TIMESTAMP,
    duration    INTEGER,
    billsec     INTEGER,
    disposition VARCHAR(45),
    amaflags    VARCHAR(45),
    uniqueid    VARCHAR(32) UNIQUE,
    userfield   VARCHAR(255)
);
__SQL_ASTERISK_RT__
    fi
}

_write_asterisk() {
    local AST_DIR="${INSTALL_DIR}/asterisk"
    local SPOOL_DIR="${INSTALL_DIR}/asterisk_spool"
    local LIB_DIR="${INSTALL_DIR}/asterisk_lib"
    local LOG_DIR="${INSTALL_DIR}/asterisk_log"

    info "Ensuring Asterisk configuration and data directories exist..."
    mkdir -p "${AST_DIR}" "${SPOOL_DIR}" "${LIB_DIR}" "${LOG_DIR}"

    local TMP_AST="/tmp/asterisk_defaults_$$"

    # Try to extract the full default configuration and data sets from the Asterisk image
    if docker image inspect "${ASTERISK_IMAGE}" &>/dev/null; then
        debug "Extracting default configs and data from ${ASTERISK_IMAGE}..."
        docker create --name tmp_asterisk_$$ "${ASTERISK_IMAGE}" >/dev/null 2>&1

        mkdir -p "${TMP_AST}/etc" "${TMP_AST}/spool" "${TMP_AST}/lib"
        docker cp tmp_asterisk_$$:/etc/asterisk/. "${TMP_AST}/etc/" >/dev/null 2>&1 || true
        docker cp tmp_asterisk_$$:/var/spool/asterisk/. "${TMP_AST}/spool/" >/dev/null 2>&1 || true
        docker cp tmp_asterisk_$$:/var/lib/asterisk/. "${TMP_AST}/lib/" >/dev/null 2>&1 || true

        docker rm tmp_asterisk_$$ >/dev/null 2>&1
    fi

    local AMI_PASS
    AMI_PASS=$(grep "^AMI_PASSWORD=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2- || echo "")
    [[ -z "$AMI_PASS" ]] && AMI_PASS="changeme"

    # Write Prometheon-specific configurations (only if they don't exist yet)
    # ── asterisk.conf ──
    if [[ ! -f "${AST_DIR}/asterisk.conf" ]]; then
        cat > "${AST_DIR}/asterisk.conf" <<'__AST_MAIN__'
[directories]
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk

[options]
runuser = asterisk
rungroup = asterisk
documentation_language = en_US
verbose = 3
logger_queue_limit = 0
__AST_MAIN__
    fi

    # Copy stock configs first (stasis.conf, etc.), then apply Prometheon overrides.
    if [[ -d "${TMP_AST}/etc" ]]; then
        cp -Rn "${TMP_AST}/etc/." "${AST_DIR}/" 2>/dev/null || true
    fi
    if [[ -d "${TMP_AST}/spool" ]]; then
        cp -Rn "${TMP_AST}/spool/." "${SPOOL_DIR}/" 2>/dev/null || true
    fi
    if [[ -d "${TMP_AST}/lib" ]]; then
        cp -Rn "${TMP_AST}/lib/." "${LIB_DIR}/" 2>/dev/null || true
        # ./asterisk_lib is bind-mounted over /var/lib/asterisk, which hides the
        # image's own XML docs. Asterisk 21+ refuses to start Stasis when those
        # docs are missing or from another version, so always overwrite them
        # with the docs that match the pinned image (cp -n above would keep stale ones).
        if [[ -d "${TMP_AST}/lib/documentation" ]]; then
            rm -rf "${LIB_DIR}/documentation"
            cp -R "${TMP_AST}/lib/documentation" "${LIB_DIR}/documentation" 2>/dev/null || true
        fi
    fi
    rm -rf "${TMP_AST}" 2>/dev/null || true

    # ── modules.conf (preload PJSIP before other modules) ──
    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${AST_DIR}/modules.conf" ]]; then
        cat > "${AST_DIR}/modules.conf" <<'__AST_MOD__'
; Prometheon — minimal PJSIP stack (preload before autoload).
[modules]
autoload = yes

noload => chan_sip.so

preload => res_pjsip.so
preload => res_pjsip_session.so
preload => chan_pjsip.so
preload => format_wav.so
preload => format_pcm.so
preload => format_gsm.so
__AST_MOD__
    fi

    # ── manager.conf (AMI — always sync secret from .env AMI_PASSWORD) ──
    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${AST_DIR}/manager.conf" ]]; then
        cat > "${AST_DIR}/manager.conf" <<__AST_MGR__
[general]
enabled = yes
port = 5038
bindaddr = 0.0.0.0

[prometheon]
secret = ${AMI_PASS}
read = system,call,log,verbose,command,agent,user,config,originate,message
write = system,call,log,verbose,command,agent,user,config,originate,message
deny = 0.0.0.0/0.0.0.0
permit = 0.0.0.0/0.0.0.0

#include manager_custom.conf
__AST_MGR__
    fi

    if [[ ! -f "${AST_DIR}/manager_custom.conf" ]]; then
        cat > "${AST_DIR}/manager_custom.conf" <<'__AST_MGR_CUSTOM__'
; Prometheon — manager_custom.conf
; Use this file to define custom AMI users or overrides.
; The wizard will NEVER overwrite this file during updates or repairs.
__AST_MGR_CUSTOM__
    fi

    _write_pjsip_prometheon

    if [[ "$OVERWRITE_CONFIGS" == true || ! -f "${AST_DIR}/extensions_tts_call.conf" ]]; then
        cat > "${AST_DIR}/extensions_tts_call.conf" <<'__AST_TTS__'
[ami-tts-out]
exten => s,1,NoOp(TTS outbound ${DIALNUM}@${TRUNK} play=${PLAYBACK_FILE})
 same => n,GotoIf($["${PLAYBACK_FILE}" = ""]?fail)
 same => n,Answer()
 same => n,Dial(PJSIP/${DIALNUM}@${TRUNK},120,U(tts-playback^s^1^${PLAYBACK_FILE}))
 same => n,NoOp(Dial done DIALSTATUS=${DIALSTATUS})
 same => n,Hangup()
 same => n(fail),NoOp(TTS missing PLAYBACK_FILE)
 same => n,Hangup()

[tts-playback]
exten => s,1,NoOp(Playing ${ARG3} on ${CHANNEL})
 same => n,GotoIf($["${ARG3}" = ""]?end)
 same => n,Wait(1)
 same => n,Playback(${ARG3})
 same => n(end),Hangup()
__AST_TTS__
    fi

    # ── extensions.conf ──
    if [[ ! -f "${AST_DIR}/extensions.conf" ]]; then
        cat > "${AST_DIR}/extensions.conf" <<'__AST_EXT__'
[general]
static = yes
writeprotect = no

[globals]

#include extensions_tts_call.conf

[from-trunk]
exten => _X.,1,NoOp(Inbound from trunk ${CALLERID(num)})
 same => n,Hangup()
__AST_EXT__
    elif ! grep -q 'extensions_tts_call.conf' "${AST_DIR}/extensions.conf" 2>/dev/null; then
        echo '#include extensions_tts_call.conf' >> "${AST_DIR}/extensions.conf"
        info "Added #include extensions_tts_call.conf to extensions.conf"
    fi

    mkdir -p "${LIB_DIR}/sounds/custom" "${LIB_DIR}/sounds/en" "${INSTALL_DIR}/asterisk_log/cdr-csv"
    # World-writable so the backend (UID 1000) can still write after Asterisk
    # container runs chown -R asterisk /var/lib/asterisk on startup.
    # chown changes owner but not permission bits, so a+rwx survives the chown.
    chmod a+rwx "${LIB_DIR}/sounds" "${LIB_DIR}/sounds/en" "${LIB_DIR}/sounds/custom" 2>/dev/null || true
    chmod -R a+rX "${LIB_DIR}/sounds" 2>/dev/null || true
    chown -R 1000:1000 "${LIB_DIR}/sounds" 2>/dev/null || true

    # ── rtp.conf (matches Docker port mapping 10000-10099) ──
    if [[ ! -f "${AST_DIR}/rtp.conf" ]]; then
        cat > "${AST_DIR}/rtp.conf" <<'__AST_RTP__'
[general]
rtpstart = 10000
rtpend = 10099
strictrtp = yes
icesupport = no
__AST_RTP__
    fi

    # ── logger.conf ──
    if [[ ! -f "${AST_DIR}/logger.conf" ]]; then
        cat > "${AST_DIR}/logger.conf" <<'__AST_LOG__'
[general]

[logfiles]
console => notice,warning,error
messages => notice,warning,error
__AST_LOG__
    fi

    log "Asterisk default configs and data directories ensured"
    info "Edit files in ${AST_DIR}/ to configure SIP trunks and dialplan."
}

# ─── Shared helpers ───────────────────────────────────────────────────────────

_is_installed() { [[ -f "${INSTALL_DIR}/.env" ]]; }

_require_docker() {
    if ! command -v docker &>/dev/null; then
        info "Docker not found — installing Docker Engine..."
        if [[ "$VERBOSE" == true ]]; then
            curl -fsSL https://get.docker.com | bash
        else
            curl -fsSL https://get.docker.com | bash 2>/dev/null
        fi
        systemctl enable --now docker
        log "Docker installed"
    else
        log "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
    fi
    if ! docker compose version &>/dev/null; then
        info "Installing Docker Compose plugin..."
        if [[ "$VERBOSE" == true ]]; then
            apt-get install -y docker-compose-plugin
        else
            apt-get install -y docker-compose-plugin 2>/dev/null
        fi
    fi
}

_wait_healthy() {
    local url="${1}"
    info "Waiting for services to be ready..."
    local attempts=0
    local max_attempts=24

    while [[ $attempts -lt $max_attempts ]]; do
        if curl -fsk "${url}/health" &>/dev/null || \
           curl -fsk "http://localhost/health"  &>/dev/null; then
            break
        fi

        if [[ "$VERBOSE" == true ]]; then
            echo -e "${CYAN}[DEBUG]${NC} Health check attempt $((attempts + 1))/$max_attempts - services not ready yet"
        fi

        attempts=$((attempts + 1))
        sleep 5
    done

    if [[ $attempts -lt $max_attempts ]]; then
        echo ""
        echo -e "${GREEN}${BOLD}  ✔  Prometheon is running!${NC}"
        echo -e "${CYAN}${BOLD}  ➜  Get Started: ${url}/getting-started${NC}"
        echo ""

        if [[ "$VERBOSE" == true ]]; then
            info "Health check passed after $((attempts + 1)) attempts"
            info "Container status:"
            docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep prometheon
        fi

        # Attempt to "redirect" (open browser)
        info "Redirecting to getting-started page..."
        if command -v xdg-open &>/dev/null; then
            xdg-open "${url}/getting-started" &>/dev/null &
        elif command -v open &>/dev/null; then
            open "${url}/getting-started" &>/dev/null &
        elif command -v explorer.exe &>/dev/null; then
            # Handle Windows/WSL
            explorer.exe "${url}/getting-started" &>/dev/null &
        fi
    else
        warn "Health check timed out. Services may still be starting."
        info "Check logs: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
        if [[ "$VERBOSE" == true ]]; then
            info "Recent container logs:"
            docker compose -f "${INSTALL_DIR}/docker-compose.yml" logs --tail=20
        fi
    fi
}

_show_volumes() {
    if [[ "$VERBOSE" == true ]]; then
        info "Current Docker volumes:"
        docker volume ls | grep -E "prometheon|postgres|redis|sqlite" || echo "  No Prometheon volumes found"
        echo ""
    fi
}

# ─── Install ──────────────────────────────────────────────────────────────────

do_install() {
    if _is_installed; then
        warn "Prometheon is already installed at ${INSTALL_DIR}."
        read -rp "  Re-install (overwrites config)? [y/N]: " CONFIRM
        [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { info "Aborted."; return; }

        echo ""
        echo "  [Fresh Start Option]"
        echo "  Do you want to WIPE all existing database and volume data?"
        read -rp "  Wipe data? [y/N]: " WIPE_CONFIRM
        if [[ "$WIPE_CONFIRM" =~ ^[Yy]$ ]]; then
            info "Wiping existing data..."
            cd "${INSTALL_DIR}" && docker compose down -v 2>/dev/null || true
            rm -rf "${INSTALL_DIR}"/backups/* "${INSTALL_DIR}"/license/*
            log "Data wiped"
        fi
    fi

    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        warn "This installer is optimised for Ubuntu 24.04. Continuing on unsupported OS."
    fi

    local ram_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    [[ $ram_mb -lt 3800 ]] && warn "Less than 4 GB RAM detected (${ram_mb} MB). Prometheon may be slow."

    local disk_gb
    disk_gb=$(df -BG / | awk 'NR==2{gsub("G",""); print $4}')
    [[ $disk_gb -lt 15 ]] && warn "Less than 20 GB disk free (${disk_gb} GB). Consider freeing space."

    for PORT in 80 443; do
        ss -tlnp | grep -q ":${PORT} " && warn "Port ${PORT} is in use. Another web server may be running."
    done

    _require_docker

    hr
    echo ""
    echo -e "${BOLD}  Configuration${NC}"
    echo ""

    read -rp "  Server IP or domain (e.g. 192.168.1.100 or prometheon.company.com): " SERVER_ADDR
    [[ -z "$SERVER_ADDR" ]] && error "Server address cannot be empty."

    local FRONTEND_URL="https://${SERVER_ADDR}"

    local DEFAULT_VERSION="$(_wizard_default_version)"
    local VERSION="${PROMETHEON_VERSION:-$DEFAULT_VERSION}"
    VERSION="$(_resolve_image_version "$VERSION")"
    local PULL_TOKEN=""

    read -rsp "  Docker Hub pull token (hidden): " PULL_TOKEN
    echo ""
    [[ -z "$PULL_TOKEN" ]] && error "Docker Hub pull token cannot be empty."

    echo ""
    log "Server address : ${SERVER_ADDR}"
    log "Access URL     : ${FRONTEND_URL}"
    log "Version        : ${VERSION}"
    echo ""

    hr
    info "Creating installation directories..."
    mkdir -p "${INSTALL_DIR}"/{data,backups,license,certs,asterisk,asterisk_spool,asterisk_lib,asterisk_log,tts_recordings,nginx_custom.d}
    mkdir -p "${INSTALL_DIR}/asterisk_lib/sounds/custom"
    chown -R 1000:1000 "${INSTALL_DIR}"/{data,backups,license,asterisk,asterisk_spool,asterisk_lib,asterisk_log,tts_recordings,nginx_custom.d}
    log "Directories created at ${INSTALL_DIR} (permissions set for container)"

    info "Generating secure credentials..."
    local PG_PASSWORD REDIS_PASSWORD AMI_PASSWORD
    PG_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    AMI_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)

    cat > "${INSTALL_DIR}/.env" <<EOF
POSTGRES_USER=prometheon
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_DB=prometheon_db

REDIS_PASSWORD=${REDIS_PASSWORD}

FRONTEND_URL=${FRONTEND_URL}
ALLOWED_ORIGINS=${FRONTEND_URL}

LICENSE_SERVER_URL=https://phlicsrv01.kaizotechnologies.com

ALGORITHM=HS256
PROMETHEON_VERSION=${VERSION}

AMI_PASSWORD=${AMI_PASSWORD}

DB_HOST=postgres
ASTERISK_DB=asterisk_rt

TTS_AMI_HOST=asterisk
TTS_AMI_PORT=5038
TTS_AMI_USER=prometheon
TTS_AMI_CONTEXT=ami-tts-out
TTS_AMI_TRUNK=tg1600
TTS_GSM_PORT=0
TTS_CALLER_ID=Prometheon <0000>
TTS_RECORDINGS_DIR=/app/tts_recordings
ASTERISK_SOUNDS_DIR=/var/lib/asterisk/sounds

ASTERISK_AMI_HOST=asterisk
ASTERISK_AMI_PORT=5038
ASTERISK_AMI_USER=prometheon
ASTERISK_AMI_SECRET=${AMI_PASSWORD}

DOCKER_PULL_TOKEN=${PULL_TOKEN}
EOF
    chmod 600 "${INSTALL_DIR}/.env"
    log "Credentials generated (root-only access)"

    hr
    echo ""
    echo -e "${BOLD}  SSL Certificate Setup${NC}"
    echo ""
    echo "  1) I have my own certificate (cert.pem + key.pem)"
    echo "  2) Generate a self-signed certificate (testing only)"
    echo ""
    read -rp "  Choice [1/2]: " SSL_CHOICE

    if [[ "$SSL_CHOICE" == "1" ]]; then
        echo ""
        info "Place your cert.pem and key.pem in ${INSTALL_DIR}/certs/"
        read -rp "  Press Enter when ready..."
        [[ ! -f "${INSTALL_DIR}/certs/cert.pem" ]] && error "cert.pem not found in ${INSTALL_DIR}/certs/"
        [[ ! -f "${INSTALL_DIR}/certs/key.pem" ]]  && error "key.pem not found in ${INSTALL_DIR}/certs/"
        log "SSL certificates verified"
    else
        info "Generating self-signed certificate (valid 10 years)..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${INSTALL_DIR}/certs/key.pem" \
            -out    "${INSTALL_DIR}/certs/cert.pem" \
            -subj   "/CN=${SERVER_ADDR}/O=Prometheon/C=PH" \
            2>/dev/null
        chmod 600 "${INSTALL_DIR}/certs/key.pem"
        log "Self-signed certificate generated"
        warn "Self-signed certificates show a browser warning. Use a real certificate in production."
    fi

    hr
    info "Pulling public images (postgres, redis, nginx, asterisk)..."
    run_verbose docker pull postgres:17
    run_verbose docker pull redis:latest
    run_verbose docker pull nginx:alpine
    run_verbose docker pull "${ASTERISK_IMAGE}"
    log "Public images ready"

    info "Logging in to Docker Hub..."
    echo "${PULL_TOKEN}" | docker login -u "kaizotechnologies" --password-stdin 2>/dev/null \
        || error "Docker Hub login failed. Check your pull token."

    info "Pulling Prometheon images (this may take several minutes)..."
    run_verbose docker pull kaizotechnologies/prometheon-1_backend:"${VERSION}"
    run_verbose docker pull kaizotechnologies/prometheon-1_frontend:"${VERSION}"

    docker logout 2>/dev/null || true
    log "Images pulled and credentials cleared"

    hr
    info "Registering system service..."
    cat > /etc/systemd/system/prometheon.service <<EOF
[Unit]
Description=Prometheon SMS Platform
Documentation=https://kaizotechnologies.com
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
TimeoutStopSec=60
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable prometheon
    log "System service registered (auto-starts on reboot)"

    hr
    info "Writing configuration files..."
    _migrate_env_asterisk
    _write_compose
    _write_nginx
    _write_sql
    _write_asterisk
    log "Configuration files ready"
    info "Use the Web GUI to configure your SIP trunks and outbound routes."

    _compose_validate || error "docker-compose.yml is invalid after install."

    hr
    _compose_up

    docker compose restart asterisk
    sleep 5
    _asterisk_bootstrap_pjsip || warn "PJSIP may not be active — run: sudo bash prometheon_wizard.sh repair"

    _wait_healthy "${FRONTEND_URL}"

    echo ""
    hr
    echo -e "${BOLD}"
    echo "  ═══════════════════════════════════════════════════"
    echo "    Prometheon Installation Complete"
    echo "  ═══════════════════════════════════════════════════"
    echo -e "${NC}"
    echo "  Access URL    :  ${FRONTEND_URL}/getting-started"
    echo "  Install dir   :  ${INSTALL_DIR}"
    echo "  Credentials   :  ${INSTALL_DIR}/.env  (root-only)"
    echo ""
    echo "  Useful commands:"
    echo "    Logs    →  docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
    echo "    Stop    →  systemctl stop prometheon"
    echo "    Start   →  systemctl start prometheon"
    echo "    Update  →  sudo bash prometheon_wizard.sh update"
    echo ""
    echo -e "${YELLOW}  IMPORTANT: Back up ${INSTALL_DIR}/.env securely."
    echo -e "  It contains your database passwords.${NC}"
    hr
}

# ─── Repair (fix PJSIP / compose without pulling images) ─────────────────────

do_repair() {
    _is_installed || error "Prometheon is not installed. Run: sudo bash prometheon_wizard.sh install"

    hr
    info "Prometheon repair (wizard v${WIZARD_VERSION})"
    info "Rewrites docker-compose.yml, Asterisk modules.conf, and restarts Asterisk."
    hr

    cd "${INSTALL_DIR}"
    OVERWRITE_CONFIGS=true
    _migrate_env_asterisk
    _write_compose
    _write_nginx
    _write_sql
    _write_asterisk
    _compose_validate || error "docker-compose.yml is still invalid."

    docker compose down 2>/dev/null || true
    _compose_up

    _publish_tts_sounds || true

    info "Restarting Asterisk to apply modules.conf..."
    docker compose restart asterisk
    sleep 5
    _asterisk_bootstrap_pjsip || warn "PJSIP still not active — see module output above"

    hr
    log "Repair complete"
    hr
}

# ─── Update ───────────────────────────────────────────────────────────────────

do_update() {
    _is_installed || error "Prometheon is not installed. Run: sudo bash prometheon_wizard.sh install"

    info "Wizard version: ${WIZARD_VERSION}"

    local CURRENT_VERSION
    CURRENT_VERSION=$(grep "^PROMETHEON_VERSION=" "${INSTALL_DIR}/.env" | cut -d= -f2 || echo "unknown")

    local DEFAULT_VERSION="$(_wizard_default_version)"
    local TARGET_VERSION="${1:-$DEFAULT_VERSION}"
    TARGET_VERSION="$(_resolve_image_version "$TARGET_VERSION")"
    TARGET_VERSION="$(_migrate_client_latest_env "$CURRENT_VERSION" "$TARGET_VERSION")"

    debug "Starting update process with VERBOSE=$VERBOSE"
    debug "Target version: $TARGET_VERSION"

    local PULL_TOKEN
    PULL_TOKEN=$(grep "^DOCKER_PULL_TOKEN=" "${INSTALL_DIR}/.env" | cut -d= -f2- || true)

    hr
    echo -e "${BOLD}  Prometheon Updater${NC}"
    hr

    info "Current version : ${CURRENT_VERSION}"
    info "Target version  : ${TARGET_VERSION}"
    echo ""

    # Show volume information before update if verbose
    _show_volumes

    read -rp "  Continue with update? [y/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { info "Update cancelled."; return; }

    if [[ -z "$PULL_TOKEN" ]]; then
        read -rsp "  Docker Hub pull token (hidden): " PULL_TOKEN
        echo ""
        [[ -n "$PULL_TOKEN" ]] && echo "DOCKER_PULL_TOKEN=${PULL_TOKEN}" >> "${INSTALL_DIR}/.env"
    fi
    [[ -z "$PULL_TOKEN" ]] && error "Pull token cannot be empty."

    hr
    info "Logging in to Docker Hub..."
    if [[ "$VERBOSE" == true ]]; then
        echo "${PULL_TOKEN}" | docker login -u "kaizotechnologies" --password-stdin
        [[ $? -eq 0 ]] || error "Docker Hub login failed."
    else
        echo "${PULL_TOKEN}" | docker login -u "kaizotechnologies" --password-stdin 2>/dev/null \
            || error "Docker Hub login failed."
    fi

    debug "Updating PROMETHEON_VERSION in .env from ${CURRENT_VERSION} to ${TARGET_VERSION}"
    sed -i "s/^PROMETHEON_VERSION=.*/PROMETHEON_VERSION=${TARGET_VERSION}/" "${INSTALL_DIR}/.env"

    cd "${INSTALL_DIR}"

    hr
    info "Refreshing configuration files (docker-compose.yml, Asterisk, .env)..."
    mkdir -p "${INSTALL_DIR}"/{data,backups,license,certs,asterisk,asterisk_spool,asterisk_lib,asterisk_log,tts_recordings,nginx_custom.d}
    mkdir -p "${INSTALL_DIR}/asterisk_lib/sounds/custom"
    chown -R 1000:1000 "${INSTALL_DIR}"/{data,backups,license,asterisk,asterisk_spool,asterisk_lib,asterisk_log,tts_recordings,nginx_custom.d} 2>/dev/null || true

    OVERWRITE_CONFIGS=false
    _migrate_env_asterisk
    _write_compose
    _write_nginx
    _write_sql
    _write_asterisk
    OVERWRITE_CONFIGS=true
    # _write_compose keeps an existing docker-compose.yml on update, so re-pin the
    # Asterisk image in place (older installs used andrius/asterisk:latest).
    sed -i -E "s#image: andrius/asterisk:[^[:space:]]+#image: ${ASTERISK_IMAGE}#" "${INSTALL_DIR}/docker-compose.yml"
    log "Configuration files updated"

    _compose_validate || error "Regenerated docker-compose.yml is invalid — report this to support."

    hr
    info "Pulling updated images..."
    info "Pulling backend (${TARGET_VERSION})..."
    docker pull kaizotechnologies/prometheon-1_backend:"${TARGET_VERSION}"
    info "Pulling frontend (${TARGET_VERSION})..."
    docker pull kaizotechnologies/prometheon-1_frontend:"${TARGET_VERSION}"
    _pull_infra_images

    docker logout 2>/dev/null || true
    log "All images pulled"

    # Handle volume deletion if --delete-volumes flag is set
    if [[ "$DELETE_VOLUMES" == true ]]; then
        warn "⚠️  VOLUME DELETION MODE ENABLED ⚠️"
        warn "This will PERMANENTLY delete all Docker volumes!"
        warn "All database data, Redis cache, and SQLite data will be LOST!"
        echo ""
        read -rp "  Type 'DELETE VOLUMES' to confirm: " CONFIRM_DELETE

        if [[ "$CONFIRM_DELETE" == "DELETE VOLUMES" ]]; then
            info "Stopping containers and DELETING volumes..."
            cd "${INSTALL_DIR}"
            if [[ "$VERBOSE" == true ]]; then
                docker compose down -v --remove-orphans
            else
                docker compose down -v --remove-orphans 2>/dev/null
            fi
            log "Containers and volumes removed"

            # Recreate volume directories
            info "Recreating volume structure..."
            docker volume create prometheon_postgres_data 2>/dev/null || true
            docker volume create prometheon_redis_data 2>/dev/null || true
            docker volume create prometheon_sqlite_data 2>/dev/null || true
            log "Fresh volumes created"
        else
            error "Volume deletion cancelled. Update aborted."
        fi
    else
        # Normal update without volume deletion
        debug "Normal update (preserving volumes)..."
        if [[ "$VERBOSE" == true ]]; then
            docker compose down
        else
            docker compose down 2>/dev/null
        fi
    fi

    _compose_up

    info "Restarting Asterisk to apply modules.conf..."
    docker compose restart asterisk
    sleep 5
    _asterisk_bootstrap_pjsip || warn "PJSIP may not be active — TTS test calls will fail until fixed"

    _wait_healthy "https://$(grep "^FRONTEND_URL=" "${INSTALL_DIR}/.env" | cut -d= -f2-)"

    echo ""
    hr
    log "Prometheon updated to ${TARGET_VERSION} and running"
    info "Getting Started : https://$(grep "^FRONTEND_URL=" "${INSTALL_DIR}/.env" | cut -d= -f2- | sed 's|^https://||' | sed 's|/$||')/getting-started"

    if [[ "$VERBOSE" == true ]]; then
        hr
        info "Current running containers:"
        docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep prometheon
        hr
    fi
    hr
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    hr
    echo -e "${BOLD}  Prometheon Uninstaller${NC}"
    hr
    echo ""
    warn "This will stop and remove Prometheon from this server."
    echo ""
    read -rp "  Type YES to confirm: " CONFIRM
    [[ "$CONFIRM" != "YES" ]] && { info "Uninstall cancelled."; return; }

    hr
    if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        info "Stopping containers..."
        cd "${INSTALL_DIR}"
        echo ""
        echo "  Remove database volumes? This PERMANENTLY deletes all data."
        read -rp "  Type YES to also remove data volumes [anything else = keep data]: " REMOVE_VOLUMES

        if [[ "$REMOVE_VOLUMES" == "YES" ]]; then
            if [[ "$VERBOSE" == true ]]; then
                docker compose down -v --remove-orphans
            else
                docker compose down -v --remove-orphans 2>/dev/null || true
            fi
            log "Containers and volumes removed"
        else
            if [[ "$VERBOSE" == true ]]; then
                docker compose down --remove-orphans
            else
                docker compose down --remove-orphans 2>/dev/null || true
            fi
            log "Containers stopped (data volumes preserved)"
        fi
    else
        warn "docker-compose.yml not found — skipping container removal"
    fi

    hr
    info "Removing system service..."
    systemctl stop prometheon    2>/dev/null || true
    systemctl disable prometheon 2>/dev/null || true
    rm -f /etc/systemd/system/prometheon.service
    systemctl daemon-reload
    log "System service removed"

    info "Removing Prometheon Docker images..."
    docker images --format "{{.Repository}}:{{.Tag}}" | grep "prometheon" \
        | xargs -r docker rmi --force 2>/dev/null || true
    log "Docker images removed"

    echo ""
    echo "  Remove installation directory ${INSTALL_DIR}?"
    echo "  This includes credentials (.env), SSL certificates, and backups."
    read -rp "  Type YES to remove [anything else = keep]: " REMOVE_DIR

    if [[ "$REMOVE_DIR" == "YES" ]]; then
        rm -rf "${INSTALL_DIR}"
        log "Installation directory removed"
    else
        info "Installation directory kept at ${INSTALL_DIR}"
    fi

    docker logout 2>/dev/null || true

    echo ""
    hr
    log "Prometheon has been uninstalled"
    if [[ "${REMOVE_DIR:-}" != "YES" ]]; then
        info "Credentials and data are still at ${INSTALL_DIR}"
        info "Remove manually with: rm -rf ${INSTALL_DIR}"
    fi
    hr
}

# ─── Interactive menu ─────────────────────────────────────────────────────────

_menu() {
    hr
    echo -e "${BOLD}  Prometheon Wizard${NC}"
    local channel_label="Client Release Channel (stable ${CLIENT_VERSION} only)"
    if [[ "$WIZARD_RELEASE_CHANNEL" == "developer" ]]; then
        channel_label="Developer Release Channel (default: ${DEVELOPER_DEFAULT_TAG}, or ${DEVELOPER_VERSION})"
    fi
    echo -e "  Channel: ${CYAN}${channel_label}${NC}"
    hr
    echo ""
    if _is_installed; then
        local ver
        ver=$(grep "^PROMETHEON_VERSION=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "unknown")
        if [[ "$WIZARD_RELEASE_CHANNEL" == "client" && "$ver" == "latest" ]]; then
            echo -e "  Status : ${GREEN}Installed${NC}  (${YELLOW}.env says latest${NC} — run Update to pin ${CLIENT_VERSION})"
        else
            echo -e "  Status : ${GREEN}Installed${NC}  (version: ${ver})"
        fi
    else
        echo -e "  Status : ${YELLOW}Not installed${NC}"
    fi
    echo ""
    echo "  1) Install"
    echo "  2) Update"
    echo "  3) Uninstall"
    echo "  4) Exit"
    echo ""
    read -rp "  Choice [1-4]: " CHOICE
    case "$CHOICE" in
        1) do_install ;;
        2)
            local DEFAULT_VERSION="$(_wizard_default_version)"
            if _is_installed; then
                local current_ver
                current_ver=$(grep "^PROMETHEON_VERSION=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "unknown")
                if [[ "$WIZARD_RELEASE_CHANNEL" == "client" && "$current_ver" == "latest" ]]; then
                    echo ""
                    info ".env uses Docker tag 'latest'. Press Enter to pin stable ${DEFAULT_VERSION}."
                    echo ""
                fi
            fi
            read -rp "  Target version [${DEFAULT_VERSION}]: " VER
            echo ""
            echo "  Update Type:"
            echo "  1) Standard Update (Preserve data)"
            echo "  2) Fresh Update (Wipe all data)"
            read -rp "  Choice [1-2]: " UPDATE_TYPE
            if [[ "$UPDATE_TYPE" == "2" ]]; then
                DELETE_VOLUMES=true
            fi
            do_update "${VER:-$DEFAULT_VERSION}"
            ;;
        3) do_uninstall ;;
        4) exit 0 ;;
        *) warn "Invalid choice."; _menu ;;
    esac
}

# ─── Entry point ─────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash prometheon_wizard.sh [install|update [version]|uninstall] [-v] [--delete-volumes]"

# Parse command line arguments
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -d|--developer)
            WIZARD_RELEASE_CHANNEL="developer"
            shift
            ;;
        -V|--version)
            echo "Prometheon Wizard v${WIZARD_VERSION}"
            exit 0
            ;;
        --delete-volumes)
            DELETE_VOLUMES=true
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional parameters
set -- "${ARGS[@]}"

debug "Verbose mode: $VERBOSE"
debug "Delete volumes mode: $DELETE_VOLUMES"

_wizard_default_version() {
    if [[ "$WIZARD_RELEASE_CHANNEL" == "developer" ]]; then
        echo "$DEVELOPER_DEFAULT_TAG"
    else
        echo "$CLIENT_VERSION"
    fi
}

# Map Docker image tag for install/update. Clients never use Hub tag "latest".
_resolve_image_version() {
    local requested="${1:-}"
    if [[ "$WIZARD_RELEASE_CHANNEL" == "client" ]]; then
        if [[ "$requested" == "latest" ]]; then
            info "Client channel uses stable ${CLIENT_VERSION} (not Docker tag latest)." >&2
            echo "$CLIENT_VERSION"
            return
        fi
        echo "$requested"
        return
    fi
    # Developer channel: pass through (latest, 1.6, etc.)
    echo "$requested"
}

# Fix servers that already have PROMETHEON_VERSION=latest in .env (client channel only).
_migrate_client_latest_env() {
    local current="${1:-}"
    local target="${2:-}"
    if [[ "$WIZARD_RELEASE_CHANNEL" != "client" || "$current" != "latest" ]]; then
        echo "$target"
        return
    fi
    if [[ "$target" == "$CLIENT_VERSION" ]]; then
        info "Migrating .env from Docker tag 'latest' to stable client release ${CLIENT_VERSION}." >&2
        echo "$CLIENT_VERSION"
        return
    fi
    echo "$target"
}

case "${1:-menu}" in
    install)   do_install ;;
    update)    do_update "${2:-$(_wizard_default_version)}" ;;
    repair)    do_repair ;;
    uninstall) do_uninstall ;;
    version)   echo "Prometheon Wizard v${WIZARD_VERSION}"; exit 0 ;;
    menu)      _menu ;;
    *)         error "Unknown command '${1}'. Usage: install | update [version] | repair | uninstall [-v] [--delete-volumes]" ;;
esac