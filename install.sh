#!/bin/bash
set -euo pipefail

# ---------- UI ----------

log() { echo -e "\e[32m[INFO]\e[0m $1"; }
warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

progress() {
    local duration=$1
    local steps=20
    local delay=$(awk "BEGIN {print $duration/$steps}")
    for ((i=1;i<=steps;i++)); do
        printf "\r["
        printf "%0.s#" $(seq 1 $i)
        printf "%0.s." $(seq $i $steps)
        printf "] %d%%" $((i*100/steps))
        sleep "$delay"
    done
    echo
}

# ---------- INPUT ----------

ask_swap() {
    echo
    echo "Swap не установлен. Установить?"
    echo "1) Да"
    echo "2) Нет"

    read -rp "> [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1) ask_swap_size ;;
        2) SWAP_SIZE="" ;;
        *) warn "Неверный выбор. Использую 'Да'"; ask_swap_size ;;
    esac
}

ask_nginx() {
    if dpkg -s nginx >/dev/null 2>&1; then
        INSTALL_NGINX=1
        return
    fi

    echo
    echo "Установить nginx?"
    echo "1) Да"
    echo "2) Нет"

    read -rp "> [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1) INSTALL_NGINX=1 ;;
        2) INSTALL_NGINX=0 ;;
        *) warn "Неверный выбор. Использую 'Да'"; INSTALL_NGINX=1 ;;
    esac
}

ask_swap_size() {
    echo
    echo "Выберите размер swap:"
    echo "1) 1 GB"
    echo "2) 2 GB"
    echo "3) 4 GB"
    echo "4) 8 GB"

    while true; do
        read -rp "> [3]: " size_choice
        echo
        size_choice=${size_choice:-3}

        case "$size_choice" in
            1) SWAP_SIZE="1GB"; break ;;
            2) SWAP_SIZE="2GB"; break ;;
            3) SWAP_SIZE="4GB"; break ;;
            4) SWAP_SIZE="8GB"; break ;;
            *) echo "Введите число от 1 до 4" ;;
        esac
    done
}

ask_ui_install() {
    echo
    echo "Установить веб-интерфейс для мониторинга?"
    echo "1) Да"
    echo "2) Нет"

    read -rp "> [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1) download_ui; install_ui ;;
        2) warn "Установка UI пропущена" ;;
        *) warn "Неверный выбор. Использую 'Да'"; download_ui; install_ui ;;
    esac
}

ask_astra_install() {
    echo
    echo "Установить Cesbo Astra?"
    echo "1) Да"
    echo "2) Нет"

    read -rp "> [1]: " choice
    echo
    choice=${choice:-1}

    case "$choice" in
        1) setup_astra ;;
        2) warn "Установка Astra пропущена" ;;
        *) warn "Неверный выбор. Использую 'Да'"; setup_astra ;;
    esac
}

ask_system_tune() {
    echo
    echo "Настроить систему для оптимальной работы с Astra? (потребуется перезагрузка)"
    echo "1) Да"
    echo "2) Нет"

    read -rp "> [1]: " choice
    echo
    choice=${choice:-1}

    case "$choice" in
        1) setup_system_tune ;;
        2) warn "Настройка системы пропущена" ;;
        *) warn "Неверный выбор. Использую 'Да'"; setup_system_tune ;;
    esac
}

ask_test_video() {
    echo
    echo "Добавить тестовое видео для проверки работы?"
    echo "1) Да"
    echo "2) Нет"

    read -rp "> [1]: " choice
    echo
    choice=${choice:-1}

    case "$choice" in
        1) download_test_video ;;
        2) warn "Тестовое видео не будет добавлено" ;;
        *) warn "Неверный выбор. Использую 'Да'"; download_test_video ;;
    esac
}

# ---------- ACTIONS ----------

download_ui() {
    curl -fsSL https://raw.githubusercontent.com/maxstigneev/astra/main/install-ui.sh -o install-ui.sh
    chmod +x install-ui.sh
}

install_ui() {
    # Проверяем, если UI уже установлен - удаляем папку UI
    echo
    if [ -d "/var/www/ui" ]; then
        
        log "Удаление старой версии UI..."
        rm -rf /var/www/ui
    fi
    log "Установка UI..."
    echo
    progress 1
    echo
    bash ./install-ui.sh
}

install_package() {
    local package_name=$1

    apt-get install -y "$package_name" >/dev/null
    log "$package_name установлен"
}

install_packages() {
    echo
    log "Обновление системы..."
    apt-get update -y >/dev/null
    echo
    progress 1
    echo

    log "Установка пакетов nginx, ffmpeg, inotify-tools..."
    if [[ "${INSTALL_NGINX:-1}" -eq 1 ]]; then
        install_package nginx
    fi

    install_package ffmpeg
    install_package inotify-tools
    echo
    progress 2
    echo
}

setup_swap() {
    if swapon --show | grep -q '/swapfile'; then
        warn "Swap уже есть"
        return
    fi

    log "Создание swap ($SWAP_SIZE)..."

    fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null \
        || dd if=/dev/zero of=/swapfile bs=1M count=$(echo "$SWAP_SIZE" | tr -d G)000

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

    log "Swap готов"
}

create_dirs() {
    log "Создание директорий..."
    mkdir -p /var/www/video /var/www/hls
}

create_scripts() {
    log "Создание build_playlist.sh..."

    cat > /usr/local/bin/build_playlist.sh << 'EOF'
#!/bin/bash
set -euo pipefail

VIDEO_DIR="/var/www/video"
PLAYLIST="/tmp/playlist.txt"

: > "$PLAYLIST"

find "$VIDEO_DIR" -maxdepth 1 -type f -name '*.mp4' | sort | while IFS= read -r f; do
    printf "file '%s'\n" "$f" >> "$PLAYLIST"
done
EOF

    chmod +x /usr/local/bin/build_playlist.sh

    log "Создание run_hls.sh..."

    cat > /usr/local/bin/run_hls.sh << 'EOF'
#!/bin/bash
set -euo pipefail

VIDEO_DIR="/var/www/video"
HLS_DIR="/var/www/hls"
PLAYLIST="/tmp/playlist.txt"
LOCK_FILE="/tmp/run_hls.lock"
PID_FILE="/tmp/run_hls.pid"

mkdir -p "$HLS_DIR"

cleanup_hls() {
    rm -f "$HLS_DIR"/*.ts "$HLS_DIR"/*.m3u8
}

stop_hls() {
    if [[ ! -f "$PID_FILE" ]]; then
        return
    fi

    local ffmpeg_pid
    ffmpeg_pid=$(cat "$PID_FILE")

    if kill -0 "$ffmpeg_pid" 2>/dev/null; then
        kill "$ffmpeg_pid" 2>/dev/null || true
        wait "$ffmpeg_pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
}

build_hls() {
    stop_hls

    /usr/local/bin/build_playlist.sh

    if [ ! -s "$PLAYLIST" ]; then
        return
    fi

    ffmpeg -hide_banner -loglevel warning -nostdin -y \
        -re \
        -stream_loop -1 \
        -f concat -safe 0 -i "$PLAYLIST" \
        -map 0:v:0 -map 0:a:0? \
        -c:v copy \
        -c:a aac -b:a 192k -ar 48000 \
        -af aresample=async=1:first_pts=0 \
        -f hls \
        -hls_time 4 \
        -hls_list_size 6 \
        -hls_start_number_source epoch \
        -hls_flags delete_segments+append_list+omit_endlist+independent_segments+temp_file+discont_start \
        -hls_segment_filename "$HLS_DIR/segment_%09d.ts" \
        "$HLS_DIR/index.m3u8" &

    echo $! > "$PID_FILE"
}

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
trap 'stop_hls' EXIT INT TERM

cleanup_hls
build_hls

while inotifywait -q -e close_write,moved_to,delete "$VIDEO_DIR"; do
    sleep 1
    build_hls
done
EOF

    chmod +x /usr/local/bin/run_hls.sh
}

setup_nginx() {
    if [[ "${INSTALL_NGINX:-1}" -ne 1 ]]; then
        warn "Настройка nginx пропущена"
        return
    fi

    log "Настройка nginx..."
    echo

    cat > /etc/nginx/sites-available/hls << 'EOF'
server {
    listen 80 default_server;
    server_name _;

    location / {
        root /var/www/hls;
        index index.m3u8;

        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0";

        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }

        try_files $uri $uri/ =404;
    }
}
EOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/hls /etc/nginx/sites-enabled/hls

    nginx -t
    systemctl restart nginx
    echo
}

setup_service() {
    log "Создание systemd сервиса..."
    echo

    cat > /etc/systemd/system/hls.service << 'EOF'
[Unit]
Description=HLS Stream (Single Hotel)
After=network.target

[Service]
ExecStart=/usr/local/bin/run_hls.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hls
    systemctl start hls
}

setup_astra() {
    log "Установка Cesbo Astra ..."
    echo
    curl -Lo /usr/bin/astra https://cesbo.com/astra-latest
    chmod +x /usr/bin/astra

    if command -v astra >/dev/null 2>&1; then
        echo
        log "Astra установлена"
        echo
        astra init
        echo
        log "Запуск сервиса Astra..."
        systemctl start astra
        log "Включение автозапуска Astra..."
        echo
        systemctl enable astra
        mkdir -p /etc/astra

        # ввод лицензионного ключа
        echo
        read -rp "Введите лицензионный ключ Astra (оставьте пустым, если нет): " license_key
        echo
        if [[ -n "$license_key" ]]; then
            curl -o /etc/astra/license.txt https://cesbo.com/astra-license/"$license_key"
            echo
            log "Лицензионный ключ сохранен"
            echo
        fi

    else
        echo
        warn "Не удалось установить Astra"
        echo
    fi
}

setup_system_tune() {
    log "Настройка системы для оптимальной работы с Astra..."
    curl -Lo /opt/tune.sh https://cdn.cesbo.com/astra/scripts/tune.sh
    chmod +x /opt/tune.sh
    /opt/tune.sh install
    log "Система настроена. Для применения изменений требуется перезагрузка сервера."
}

download_test_video() {
    log "Загрузка тестового видео..."
    curl -L https://github.com/chthomos/video-media-samples/raw/refs/heads/master/big-buck-bunny-1080p-30sec.mp4 -o /var/www/video/test.mp4
    echo
    log "Тестовое видео добавлено в /var/www/video/test.mp4"
}

# ---------- MAIN ----------

main() {
    clear
    echo "===================================="
    echo "      HLS Streaming Установка"
    echo "===================================="

    if ! swapon --show | grep -q '/swapfile'; then
        ask_swap
    fi

    if [[ -n "${SWAP_SIZE:-}" ]]; then
        setup_swap
    fi

    ask_nginx
    install_packages

    create_dirs
    create_scripts
    setup_nginx
    setup_service

    ask_ui_install
    ask_astra_install
    ask_test_video

    echo
    echo "===================================="
    echo "       УСТАНОВКА ЗАВЕРШЕНА!"
    echo "===================================="
    echo

    # проверяем, установлена ли астра, и если да - выводим информацию о ней
    if command -v astra >/dev/null 2>&1; then
        echo "Astra доступна по адресу:"
        echo "http://$(hostname -I | awk '{print $1}'):8000"
        echo
    fi

    if [[ "${INSTALL_NGINX:-1}" -eq 1 ]]; then
        echo "Поток видео файлов доступен по адресу:"
        echo "http://$(hostname -I | awk '{print $1}')/index.m3u8"
        echo
    else
        warn "nginx не установлен, HTTP-доступ к потоку не настроен"
        echo
    fi
    echo "Видеофайлы добавлять в директорию:"
    echo "/var/www/video"
    echo

    # Если UI установлен, выводим информацию о нем
    if [ -d "/var/www/ui" ]; then
        echo "Веб-интерфейс для мониторинга доступен по адресу:"
        echo "http://$(hostname -I | awk '{print $1}'):8080"
        echo
        echo "Проверка API: http://$(hostname -I | awk '{print $1}'):8080/api/health"
        echo
    fi
}

main