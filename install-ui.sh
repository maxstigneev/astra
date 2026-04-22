#!/bin/bash
set -euo pipefail

log() { echo -e "\e[32m[INFO]\e[0m ${1-}"; }
warn() { echo -e "\e[33m[WARN]\e[0m ${1-}"; }
fail() { echo -e "\e[31m[ERROR]\e[0m ${1-}" >&2; exit 1; }

UI_ROOT="/var/www/ui"
APP_ROOT="/opt/ui"
API_SCRIPT="$APP_ROOT/api_server.py"
API_SERVICE="ui-api.service"
NGINX_SITE="/etc/nginx/sites-available/ui"
NGINX_LINK="/etc/nginx/sites-enabled/ui"
API_PORT="9180"
UI_PORT="8080"

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
    apt-get update -y >/dev/null
  apt-get install -y curl nginx python3 >/dev/null
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

write_service_unit() {
  log "Создание systemd-юнита..."
    cat > "/etc/systemd/system/$API_SERVICE" <<EOF
[Unit]
Description=Astra API веб-интерфейса
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_ROOT
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
}

print_summary() {
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    echo
  log "Веб-интерфейс установлен"
  echo
  echo "Панель управления: http://$host_ip:$UI_PORT"
  echo "Проверка API: http://$host_ip:$UI_PORT/api/health"
}

main() {
  require_supported_os
    require_root
    install_dependencies
    download_ui
    write_service_unit
    write_nginx_site
    enable_services
    print_summary
}

main