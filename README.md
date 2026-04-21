# Astra HLS Installer

Скрипт для быстрого развёртывания HLS стриминга из видео файлов (FFmpeg + Nginx + systemd).

## Что делает

- Устанавливает nginx, ffmpeg, inotify-tools
- Настраивает HLS стриминг
- Создаёт systemd сервис
- Автоматически обновляет поток при загрузке видео
- Опционально создаёт swap

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/maxstigneev/astra/main/install.sh -o install.sh
chmod +x install.sh
chmod +x install-ui.sh
sudo ./install.sh
```

После установки поток доступен по адресу:
http://IP_СЕРВЕРА/file-tv/index.m3u8

Видео файлы загружать в директорию:
/var/www/video

Файлы потока доступны в директории:
/var/www/hls

## Как работает
video files → playlist → ffmpeg → HLS → nginx

## Особенности

- Без перекодирования (-c copy) → минимальная нагрузка CPU
- Поддержка пробелов в именах файлов
- Защита от гонок (lock file)
- Идемпотентная установка
- Интерактивный installer

## Ограничения

Все видео должны быть:
- одинакового формата
- одинаковых кодеков
При разных параметрах возможны предупреждения DTS

## Файлы скриптов

/usr/local/bin/build_playlist.sh
/usr/local/bin/run_hls.sh

# Просмотр журнала

journalctl -u hls -n 50