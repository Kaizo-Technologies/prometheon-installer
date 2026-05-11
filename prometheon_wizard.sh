#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  Prometheon Wizard  |  Install · Update · Uninstall
#  Usage:  sudo bash prometheon_wizard.sh [install|update [version]|uninstall]
#          sudo bash prometheon_wizard.sh          ← interactive menu
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${GREEN}[✔]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1"; exit 1; }
hr()    { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }

INSTALL_DIR="/opt/prometheon"

# ─── Embedded assets ─────────────────────────────────────────────────────────
# Written to INSTALL_DIR during install (and optionally refresh on update).

_write_compose() {
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
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
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
    image: kaizotechnologies/prometheon-1_frontend:${PROMETHEON_VERSION:-latest}
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
    image: kaizotechnologies/prometheon-1_backend:${PROMETHEON_VERSION:-latest}
    container_name: prometheon_backend
    restart: always
    command: ["-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
    env_file:
      - .env
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-prometheon}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-prometheon_db}
      SQLITE_URL: sqlite+aiosqlite:////app/data/backup.db
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      CELERY_BROKER_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      CELERY_RESULT_BACKEND: redis://:${REDIS_PASSWORD}@redis:6379/2
    volumes:
      - sqlite_data:/app/data
      - ./backups:/app/backups
      - ./license:/app/license
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    healthcheck:
      test: ["CMD", "python3", "-c",
             "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 60s
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

  celery_worker:
    image: kaizotechnologies/prometheon-1_backend:${PROMETHEON_VERSION:-latest}
    container_name: prometheon_celery_worker
    restart: always
    command: ["-m", "celery", "-A", "app.workers.celery_app",
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
      - sqlite_data:/app/data
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
          memory: 1G
        reservations:
          memory: 512M
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

  celery_beat:
    image: kaizotechnologies/prometheon-1_backend:${PROMETHEON_VERSION:-latest}
    container_name: prometheon_celery_beat
    restart: always
    command: ["-m", "celery", "-A", "app.workers.celery_app",
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
      - sqlite_data:/app/data
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


volumes:
  postgres_data:
  redis_data:
  sqlite_data:

networks:
  prometheon_net:
    driver: bridge
__COMPOSE__
}

_write_nginx() {
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
    }
}
__NGINX__
}

_write_sql() {
cat > "${INSTALL_DIR}/init.sql" <<'__SQL__'
-- Prometheon-1 | PostgreSQL initialisation
-- Executed once on first startup when the data volume is empty.

-- pgcrypto: enables gen_random_bytes(), pgp_sym_encrypt/decrypt(), etc.
-- Available for column-level encryption of sensitive fields if needed in future
-- schema migrations (e.g. AES-encrypted audit rows or config secrets).
CREATE EXTENSION IF NOT EXISTS pgcrypto;
__SQL__
}

# ─── Shared helpers ───────────────────────────────────────────────────────────

_is_installed() { [[ -f "${INSTALL_DIR}/.env" ]]; }

_require_docker() {
    if ! command -v docker &>/dev/null; then
        info "Docker not found — installing Docker Engine..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable --now docker
        log "Docker installed"
    else
        log "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
    fi
    if ! docker compose version &>/dev/null; then
        info "Installing Docker Compose plugin..."
        apt-get install -y docker-compose-plugin
    fi
}

_wait_healthy() {
    local url="${1}"
    info "Waiting for services to be ready..."
    local attempts=0
    while [[ $attempts -lt 24 ]]; do
        if curl -fsk "${url}/health" &>/dev/null || \
           curl -fsk "http://localhost/health"  &>/dev/null; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 5
    done
    if [[ $attempts -lt 24 ]]; then
        echo ""
        echo -e "${GREEN}${BOLD}  ✔  Prometheon is running!${NC}"
    else
        warn "Health check timed out. Services may still be starting."
        info "Check logs: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
    fi
}

# ─── Install ──────────────────────────────────────────────────────────────────

do_install() {
    if _is_installed; then
        warn "Prometheon is already installed at ${INSTALL_DIR}."
        read -rp "  Re-install (overwrites config)? [y/N]: " CONFIRM
        [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { info "Aborted."; return; }
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
    local VERSION="${PROMETHEON_VERSION:-latest}"
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
    mkdir -p "${INSTALL_DIR}"/{backups,license,certs}

    _write_compose
    _write_nginx
    _write_sql

    log "Directories created at ${INSTALL_DIR}"

    info "Generating secure credentials..."
    local PG_PASSWORD REDIS_PASSWORD
    PG_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)

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
    info "Pulling public images (postgres, redis, nginx)..."
    docker pull postgres:17
    docker pull redis:latest
    docker pull nginx:alpine
    log "Public images ready"

    info "Logging in to Docker Hub..."
    echo "${PULL_TOKEN}" | docker login -u "kaizotechnologies" --password-stdin 2>/dev/null \
        || error "Docker Hub login failed. Check your pull token."

    info "Pulling Prometheon images (this may take several minutes)..."
    docker pull kaizotechnologies/prometheon-1_backend:"${VERSION}"
    docker pull kaizotechnologies/prometheon-1_frontend:"${VERSION}"

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
    info "Starting Prometheon..."
    cd "${INSTALL_DIR}"
    docker compose up -d || true
    sleep 8
    docker compose up -d

    _wait_healthy "${FRONTEND_URL}"

    echo ""
    hr
    echo -e "${BOLD}"
    echo "  ═══════════════════════════════════════════════════"
    echo "    Prometheon Installation Complete"
    echo "  ═══════════════════════════════════════════════════"
    echo -e "${NC}"
    echo "  Access URL    :  ${FRONTEND_URL}"
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

# ─── Update ───────────────────────────────────────────────────────────────────

do_update() {
    local TARGET_VERSION="${1:-latest}"
    _is_installed || error "Prometheon is not installed. Run: sudo bash prometheon_wizard.sh install"

    local PULL_TOKEN
    PULL_TOKEN=$(grep "^DOCKER_PULL_TOKEN=" "${INSTALL_DIR}/.env" | cut -d= -f2- || true)

    hr
    echo -e "${BOLD}  Prometheon Updater${NC}"
    hr

    local CURRENT_VERSION
    CURRENT_VERSION=$(grep "^PROMETHEON_VERSION=" "${INSTALL_DIR}/.env" | cut -d= -f2 || echo "unknown")
    info "Current version : ${CURRENT_VERSION}"
    info "Target version  : ${TARGET_VERSION}"
    echo ""

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
    echo "${PULL_TOKEN}" | docker login -u "kaizotechnologies" --password-stdin 2>/dev/null \
        || error "Docker Hub login failed."

    sed -i "s/^PROMETHEON_VERSION=.*/PROMETHEON_VERSION=${TARGET_VERSION}/" "${INSTALL_DIR}/.env"

    info "Pulling updated images..."
    cd "${INSTALL_DIR}"
    docker compose pull

    docker logout 2>/dev/null || true
    log "Images pulled"

    hr
    info "Refreshing configuration files..."
    _write_compose
    _write_nginx
    _write_sql
    log "Configuration files updated"

    info "Restarting services..."
    docker compose down
    docker compose up -d || true
    sleep 8
    docker compose up -d

    _wait_healthy "https://$(grep "^FRONTEND_URL=" "${INSTALL_DIR}/.env" | cut -d= -f2-)"

    echo ""
    hr
    log "Prometheon updated to ${TARGET_VERSION} and running"
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
            docker compose down -v --remove-orphans 2>/dev/null || true
            log "Containers and volumes removed"
        else
            docker compose down --remove-orphans 2>/dev/null || true
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
    hr
    echo ""
    if _is_installed; then
        local ver
        ver=$(grep "^PROMETHEON_VERSION=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "unknown")
        echo -e "  Status : ${GREEN}Installed${NC}  (version: ${ver})"
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
            read -rp "  Target version [latest]: " VER
            do_update "${VER:-latest}"
            ;;
        3) do_uninstall ;;
        4) exit 0 ;;
        *) warn "Invalid choice."; _menu ;;
    esac
}

# ─── Entry point ─────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash prometheon_wizard.sh [install|update [version]|uninstall]"

case "${1:-menu}" in
    install)   do_install ;;
    update)    do_update "${2:-latest}" ;;
    uninstall) do_uninstall ;;
    menu)      _menu ;;
    *)         error "Unknown command '${1}'. Usage: install | update [version] | uninstall" ;;
esac
