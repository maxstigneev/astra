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

    echo
}

ask_swap_size() {
    echo
    echo "Выберите размер swap:"
    echo "1) 1 GB"
    echo "2) 2 GB"
    echo "3) 4 GB"
    echo "4) 8 GB"

    while true; do
        read -rp "> [4]: " size_choice
        size_choice=${size_choice:-4}

        case "$size_choice" in
            1) SWAP_SIZE="1G"; break ;;
            2) SWAP_SIZE="2G"; break ;;
            3) SWAP_SIZE="4G"; break ;;
            4) SWAP_SIZE="8G"; break ;;
            *) echo "Введите число от 1 до 4" ;;
        esac
    done

    log "Выбран swap: $SWAP_SIZE"
}

# ---------- ACTIONS ----------

install_package() {
    local package_name=$1

    apt-get install -y "$package_name" >/dev/null
    log "$package_name установлен"
}

install_packages() {
    log "Обновление системы..."
    log
    apt-get update -y >/dev/null
    progress 1
    log

    log "Установка пакетов..."

    install_package ffmpeg
    install_package inotify-tools
    echo
    progress 2
    
    if [[ "${INSTALL_NGINX:-1}" -eq 1 ]]; then
        install_package nginx
    fi
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
    mkdir -p /var/www/video /var/www/hls/file-tv
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
HLS_DIR="/var/www/hls/file-tv"
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
    echo "   HLS Streaming Installer 🚀"
    echo "===================================="

    ask_nginx
    install_packages

    if ! swapon --show | grep -q '/swapfile'; then
        ask_swap
    fi

    if [[ -n "${SWAP_SIZE:-}" ]]; then
        setup_swap
    fi

    create_dirs
    create_scripts
    setup_nginx
    setup_service

    echo
    echo "===================================="
    log "УСТАНОВКА ЗАВЕРШЕНА ✅"
    echo "===================================="
    echo
    if [[ "${INSTALL_NGINX:-1}" -eq 1 ]]; then
        echo "📺 Поток доступен:"
        echo "http://$(hostname -I | awk '{print $1}')/file-tv/index.m3u8"
        echo
    else
        warn "nginx не установлен, HTTP-доступ к потоку не настроен"
        echo
    fi
    echo
    echo "📂 Кидай видео сюда:"
    echo "/var/www/video"
}

main