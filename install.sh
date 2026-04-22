#!/bin/bash
set -euo pipefail

# ---------- UI ----------

log() { echo -e "\e[32m[INFO]\e[0m $1"; }
warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

render_progress() {
    local completed_steps=$1
    local total_steps=$2
    local status_text=$3
    local bar_width=20
    local filled=$((completed_steps * bar_width / total_steps))
    local empty=$((bar_width - filled))
    local percent=$((completed_steps * 100 / total_steps))

    printf "\r["
    printf "%0.s#" $(seq 1 "$filled")
    printf "%0.s." $(seq 1 "$empty")
    printf "] %d%% %s" "$percent" "$status_text"
}

run_with_progress() {
    local completed_steps=$1
    local total_steps=$2
    local status_text=$3
    local output_file spinner_index=0
    local spinner='|/-\\'

    shift 3

    output_file=$(mktemp)
    "$@" >"$output_file" 2>&1 &
    local command_pid=$!

    while kill -0 "$command_pid" 2>/dev/null; do
        render_progress "$completed_steps" "$total_steps" "$status_text ${spinner:spinner_index:1}"
        spinner_index=$(((spinner_index + 1) % 4))
        sleep 0.2
    done

    if ! wait "$command_pid"; then
        echo
        cat "$output_file"
        rm -f "$output_file"
        return 1
    fi

    rm -f "$output_file"
    render_progress "$((completed_steps + 1))" "$total_steps" "$status_text"
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
    echo
    choice=${choice:-1}

    case "$choice" in
        1) download_ui; install_ui ;;
        2) warn "Установка UI пропущена" ;;
        *) warn "Неверный выбор. Использую 'Да'"; download_ui; install_ui ;;
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
    run_with_progress 0 1 "Установка UI" bash ./install-ui.sh
}

install_package() {
    local package_name=$1
    local completed_steps=$2
    local total_steps=$3

    run_with_progress "$completed_steps" "$total_steps" "Установка $package_name" apt-get install -y "$package_name"
    log "$package_name установлен"
}

install_packages() {
    local total_steps=3
    local completed_steps=0

    if [[ "${INSTALL_NGINX:-1}" -eq 1 ]]; then
        total_steps=4
    fi

    echo
    log "Обновление системы..."
    run_with_progress "$completed_steps" "$total_steps" "Обновление системы" apt-get update -y
    completed_steps=$((completed_steps + 1))
    echo

    log "Установка пакетов..."
    if [[ "${INSTALL_NGINX:-1}" -eq 1 ]]; then
        install_package nginx "$completed_steps" "$total_steps"
        completed_steps=$((completed_steps + 1))
    fi

    install_package ffmpeg "$completed_steps" "$total_steps"
    completed_steps=$((completed_steps + 1))

    install_package inotify-tools "$completed_steps" "$total_steps"
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

mkdir -p "$HLS_DIR"

build_hls() {
    flock -n 9 || exit 0

    /usr/local/bin/build_playlist.sh

    rm -f "$HLS_DIR"/*.ts "$HLS_DIR"/*.m3u8

    if [ ! -s "$PLAYLIST" ]; then
        return
    fi

    ffmpeg -hide_banner -loglevel warning -nostdin -y \
        -f concat -safe 0 -i "$PLAYLIST" \
        -map 0:v:0 -map 0:a:0? \
        -c:v copy \
        -c:a aac -b:a 192k -ar 48000 \
        -af aresample=async=1:first_pts=0 \
        -f hls \
        -hls_time 4 \
        -hls_list_size 0 \
        -hls_playlist_type vod \
        -hls_flags independent_segments+temp_file \
        -hls_segment_filename "$HLS_DIR/segment_%03d.ts" \
        "$HLS_DIR/index.m3u8"
}

exec 9>"$LOCK_FILE"
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

    echo
    echo "===================================="
    echo "       УСТАНОВКА ЗАВЕРШЕНА!"
    echo "===================================="
    echo
    if [[ "${INSTALL_NGINX:-1}" -eq 1 ]]; then
        echo "Поток доступен по адресу:"
        echo "http://$(hostname -I | awk '{print $1}')/index.m3u8"
        echo
    else
        warn "nginx не установлен, HTTP-доступ к потоку не настроен"
        echo
    fi
    echo "Видеофайлы добавлять в директорию:"
    echo "/var/www/video"
}

main