#!/bin/bash
set -euo pipefail

log() { echo -e "\e[32m[INFO]\e[0m ${1-}"; }
warn() { echo -e "\e[33m[WARN]\e[0m ${1-}"; }
fail() { echo -e "\e[31m[ERROR]\e[0m ${1-}" >&2; exit 1; }

UI_ROOT="/var/www/ui"
APP_ROOT="/opt/ui"
API_SCRIPT="$APP_ROOT/api_server.py"
APP_ENV_FILE="$APP_ROOT/.env"
API_SERVICE="ui-api.service"
NGINX_SITE="/etc/nginx/sites-available/ui"
NGINX_LINK="/etc/nginx/sites-enabled/ui"
API_PORT="9180"
UI_PORT="8080"
UPLOAD_LIMIT="500M"
API_KEY_VALUE=""

wait_for_apt_lock() {
  local waited=0
  local timeout=300

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
    || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
    || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
    || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    if [[ "$waited" -eq 0 ]]; then
      warn "Обнаружена блокировка apt/dpkg (часто из-за unattended-upgrades). Жду освобождения..."
    fi

    if [[ "$waited" -ge "$timeout" ]]; then
      fail "Блокировка apt/dpkg не освобождена за ${timeout} секунд. Повторите установку позже."
    fi

    sleep 5
    waited=$((waited + 5))
  done
}

apt_get_retry() {
  local tries=0
  local max_tries=5

  while true; do
    if apt-get "$@"; then
      return 0
    fi

    tries=$((tries + 1))
    if [[ "$tries" -ge "$max_tries" ]]; then
      fail "Не удалось выполнить apt-get $* после ${max_tries} попыток"
    fi

    warn "apt-get $* завершился с ошибкой, повтор через 5 сек (попытка $((tries + 1))/${max_tries})"
    wait_for_apt_lock
    sleep 5
  done
}

require_supported_os() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    fail "Этот скрипт предназначен для серверов Ubuntu/Debian и не может запускаться на macOS"
  fi

  if [[ ! -f /etc/os-release ]]; then
    fail "Не удалось определить операционную систему. Нужен сервер Ubuntu/Debian"
  fi

  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
    fail "Неподдерживаемая ОС: ${PRETTY_NAME:-неизвестно}. Используйте сервер Ubuntu или Debian"
  fi
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "Запустите этот скрипт от root"
    fi
}

install_dependencies() {
    log "Установка зависимостей..."
    wait_for_apt_lock
    apt_get_retry update -y >/dev/null
    wait_for_apt_lock
    apt_get_retry install -y curl nginx python3 >/dev/null
}

download_ui() {
  log "Загрузка файлов UI..."
  mkdir -p "$APP_ROOT" "$UI_ROOT"

  curl -fsSL https://raw.githubusercontent.com/maxstigneev/astra/main/ui/api_server.py -o "$API_SCRIPT"
  curl -fsSL https://raw.githubusercontent.com/maxstigneev/astra/main/ui/app.js -o "$UI_ROOT/app.js"
  curl -fsSL https://raw.githubusercontent.com/maxstigneev/astra/main/ui/index.html -o "$UI_ROOT/index.html"
  curl -fsSL https://raw.githubusercontent.com/maxstigneev/astra/main/ui/styles.css -o "$UI_ROOT/styles.css"

  chmod +x "$API_SCRIPT"
}

generate_api_key() {
  local generated_key

  generated_key="$(openssl rand -hex 32 2>/dev/null || true)"
  if [[ -z "$generated_key" ]]; then
    generated_key="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  fi

  printf "%s" "$generated_key"
}

setup_api_env() {
  local existing_key
  local generated_key

  log "Настройка API-ключа..."
  mkdir -p "$APP_ROOT"

  existing_key=""
  if [[ -f "$APP_ENV_FILE" ]]; then
    existing_key="$(grep -E '^UI_API_KEY=' "$APP_ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  fi

  if [[ -n "$existing_key" ]]; then
    API_KEY_VALUE="$existing_key"
    log "Используется существующий API-ключ из $APP_ENV_FILE"
    return
  fi

  generated_key="$(generate_api_key)"

  if [[ -f "$APP_ENV_FILE" ]]; then
    printf "\nUI_API_KEY=%s\n" "$generated_key" >> "$APP_ENV_FILE"
  else
    cat > "$APP_ENV_FILE" <<EOF
UI_API_KEY=$generated_key
EOF
  fi

  chmod 600 "$APP_ENV_FILE"
  API_KEY_VALUE="$generated_key"
  log "API-ключ сгенерирован и сохранен в $APP_ENV_FILE"
}

write_service_unit() {
  log "Создание systemd-юнита..."
    cat > "/etc/systemd/system/$API_SERVICE" <<EOF
[Unit]
Description=Astra API веб-интерфейса
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_ROOT
EnvironmentFile=$APP_ENV_FILE
ExecStart=/usr/bin/python3 $API_SCRIPT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_site() {
  log "Создание конфигурации nginx..."
    cat > "$NGINX_SITE" <<EOF
server {
    listen $UI_PORT;
    listen [::]:$UI_PORT;
    server_name _;

    client_max_body_size $UPLOAD_LIMIT;

    root $UI_ROOT;
    index index.html;

    location = /api/status {
        proxy_pass http://127.0.0.1:$API_PORT/status;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        add_header Cache-Control "no-store";
    }

    location = /api/health {
        proxy_pass http://127.0.0.1:$API_PORT/health;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location = /api/videos/delete-all {
      proxy_pass http://127.0.0.1:$API_PORT/videos/delete-all;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location = /api/videos/delete-by-name {
      limit_except POST { deny all; }
      proxy_pass http://127.0.0.1:$API_PORT/videos/delete-by-name;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location = /api/videos/upload {
      limit_except POST { deny all; }
      proxy_pass http://127.0.0.1:$API_PORT/videos/upload;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_request_buffering off;
      proxy_read_timeout 600s;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

    ln -sf "$NGINX_SITE" "$NGINX_LINK"
}

enable_services() {
  log "Включение и запуск служб..."
  echo
    systemctl daemon-reload
    systemctl enable --now ui-api >/dev/null
    nginx -t >/dev/null
    systemctl enable nginx >/dev/null
    systemctl restart nginx
    echo
    log "Веб-интерфейс установлен"
    log "Скопируйте API-ключ для системы отправки файлов:"
    echo
    echo "$API_KEY_VALUE"
    echo "Ключ сохранен в: $APP_ENV_FILE"
}

main() {
  require_supported_os
    require_root
    install_dependencies
    download_ui
    setup_api_env
    write_service_unit
    write_nginx_site
    enable_services
}

main