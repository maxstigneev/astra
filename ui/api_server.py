#!/usr/bin/env python3
import json
import os
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

VIDEO_DIR = Path("/var/www/video")
HLS_DIR = Path("/var/www/hls")
PLAYLIST_PATH = HLS_DIR / "index.m3u8"
CHANNELS_ROOT = Path("/var/lib/astra-vod/channels")
CHANNELS_HLS_DIR = HLS_DIR / "channels"
API_HOST = "127.0.0.1"
API_PORT = 9180
API_KEY = os.environ.get("UI_API_KEY", "")
SERVICE_UNITS = [
    ("nginx.service", "nginx"),
    ("hls.service", "hls"),
    ("ui-api.service", "ui-api"),
]
STATE_LABELS = {
    "active": "активна",
    "inactive": "неактивна",
    "failed": "ошибка",
    "activating": "запускается",
    "deactivating": "останавливается",
    "running": "работает",
    "exited": "завершена",
    "dead": "остановлена",
    "loaded": "загружена",
    "enabled": "включена",
    "disabled": "выключена",
    "masked": "замаскирована",
    "not-found": "не найдена",
    "unknown": "неизвестно",
    "online": "онлайн",
    "degraded": "нестабильно",
    "offline": "неактивен",
}
STREAM_STATUS_TITLES = {
    "online": "В РАБОТЕ",
    "degraded": "НЕСТАБИЛЕН",
    "offline": "НЕ АКТИВЕН",
}


def ensure_dirs():
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    HLS_DIR.mkdir(parents=True, exist_ok=True)
    CHANNELS_ROOT.mkdir(parents=True, exist_ok=True)
    CHANNELS_HLS_DIR.mkdir(parents=True, exist_ok=True)


def iso_timestamp(timestamp):
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat()


def run_command(args):
    result = subprocess.run(args, capture_output=True, text=True)
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def sanitize_filename(raw_name):
    safe_name = Path(raw_name).name.strip()
    return safe_name or None


def sanitize_channel_key(raw_value):
    value = (raw_value or "").strip().lower()
    if not value:
        return None

    output = []
    previous_dash = False
    for char in value:
        if char.isalnum():
            output.append(char)
            previous_dash = False
        elif char in {"-", "_", " "}:
            if not previous_dash:
                output.append("-")
                previous_dash = True

    normalized = "".join(output).strip("-")
    return normalized or None


def unique_destination_path(directory, filename):
    candidate = directory / filename
    if not candidate.exists():
        return candidate

    stem = candidate.stem
    suffix = candidate.suffix
    counter = 2
    while True:
        next_candidate = directory / f"{stem}_{counter}{suffix}"
        if not next_candidate.exists():
            return next_candidate
        counter += 1


def label_for_state(value):
    return STATE_LABELS.get(value, value)


def get_service_status(unit_name, label):
    code, stdout, stderr = run_command(
        [
            "systemctl",
            "show",
            unit_name,
            "--property=LoadState,ActiveState,SubState,UnitFileState",
            "--value",
        ]
    )

    lines = stdout.splitlines()
    while len(lines) < 4:
        lines.append("unknown")

    load_state, active_state, sub_state, unit_file_state = [line or "unknown" for line in lines[:4]]
    healthy = load_state != "not-found" and active_state == "active"

    return {
        "unit": unit_name,
        "name": label,
        "healthy": healthy,
        "loadState": load_state,
        "loadStateLabel": label_for_state(load_state),
        "activeState": active_state,
        "activeStateLabel": label_for_state(active_state),
        "subState": sub_state,
        "subStateLabel": label_for_state(sub_state),
        "unitFileState": unit_file_state,
        "unitFileStateLabel": label_for_state(unit_file_state),
        "healthLabel": "Исправна" if healthy else label_for_state(load_state),
        "details": stderr,
        "exitCode": code,
    }


def collect_services():
    return [get_service_status(unit_name, label) for unit_name, label in SERVICE_UNITS]


def collect_videos():
    ensure_dirs()
    files = []
    total_bytes = 0
    for path in VIDEO_DIR.glob("*.mp4"):
        if not path.is_file():
            continue

        stat = path.stat()
        total_bytes += stat.st_size
        files.append(
            {
                "name": path.name,
                "sizeBytes": stat.st_size,
                "modifiedAt": iso_timestamp(stat.st_mtime),
                "modifiedTs": stat.st_mtime,
            }
        )

    files.sort(key=lambda item: item["modifiedTs"], reverse=True)
    for item in files:
        item.pop("modifiedTs", None)

    return {
        "count": len(files),
        "totalBytes": total_bytes,
        "recentFiles": files[:12],
        "directoryExists": True,
    }


def channel_root(channel_key):
    return CHANNELS_ROOT / channel_key


def channel_playlist_file(channel_key):
    return channel_root(channel_key) / "playlist.txt"


def channel_metadata_file(channel_key):
    return channel_root(channel_key) / "channel.json"


def channel_pid_file(channel_key):
    return channel_root(channel_key) / "ffmpeg.pid"


def channel_log_file(channel_key):
    return channel_root(channel_key) / "ffmpeg.log"


def channel_hls_dir(channel_key):
    return CHANNELS_HLS_DIR / channel_key


def channel_stream_path(channel_key):
    return channel_hls_dir(channel_key) / "index.m3u8"


def read_channel_metadata(channel_key):
    path = channel_metadata_file(channel_key)
    if not path.exists():
        return None

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def write_channel_metadata(channel_key, payload):
    root = channel_root(channel_key)
    root.mkdir(parents=True, exist_ok=True)
    channel_metadata_file(channel_key).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def stop_channel_process(channel_key):
    pid_path = channel_pid_file(channel_key)
    if not pid_path.exists():
        return False

    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        pid_path.unlink(missing_ok=True)
        return False

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pid_path.unlink(missing_ok=True)
        return False
    except OSError:
        pid_path.unlink(missing_ok=True)
        return False

    pid_path.unlink(missing_ok=True)
    return True


def cleanup_channel_hls(channel_key):
    output_dir = channel_hls_dir(channel_key)
    if not output_dir.exists():
        return

    for path in output_dir.iterdir():
        if path.is_file():
            path.unlink()


def build_channel_playlist(channel_key, files):
    root = channel_root(channel_key)
    root.mkdir(parents=True, exist_ok=True)
    playlist_path = channel_playlist_file(channel_key)

    lines = []
    for file_item in sorted(files, key=lambda item: int(item.get("order", 0))):
        filename = sanitize_filename(file_item.get("filename") or "")
        if not filename:
            continue

        file_path = VIDEO_DIR / filename
        if not file_path.is_file():
            raise FileNotFoundError(f"Файл не найден: {filename}")

        lines.append(f"file '{file_path}'")

    playlist_path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return playlist_path, len(lines)


def start_channel_process(channel_key):
    playlist_path = channel_playlist_file(channel_key)
    if not playlist_path.exists() or playlist_path.stat().st_size == 0:
        raise RuntimeError("Плейлист канала пуст")

    stop_channel_process(channel_key)
    cleanup_channel_hls(channel_key)

    output_dir = channel_hls_dir(channel_key)
    output_dir.mkdir(parents=True, exist_ok=True)

    with channel_log_file(channel_key).open("ab") as log_file:
        process = subprocess.Popen(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "warning",
                "-nostdin",
                "-y",
                "-re",
                "-stream_loop",
                "-1",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                str(playlist_path),
                "-map",
                "0:v:0",
                "-map",
                "0:a:0?",
                "-c:v",
                "copy",
                "-c:a",
                "aac",
                "-b:a",
                "192k",
                "-ar",
                "48000",
                "-af",
                "aresample=async=1:first_pts=0",
                "-f",
                "hls",
                "-hls_time",
                "4",
                "-hls_list_size",
                "6",
                "-hls_start_number_source",
                "epoch",
                "-hls_flags",
                "delete_segments+append_list+omit_endlist+independent_segments+temp_file+discont_start",
                "-hls_segment_filename",
                str(output_dir / "segment_%09d.ts"),
                str(output_dir / "index.m3u8"),
            ],
            stdout=log_file,
            stderr=log_file,
            start_new_session=True,
        )

    channel_pid_file(channel_key).write_text(str(process.pid), encoding="utf-8")
    return process.pid


def collect_channels():
    ensure_dirs()
    channels = []
    for metadata_path in CHANNELS_ROOT.glob("*/channel.json"):
        channel_key = metadata_path.parent.name
        metadata = read_channel_metadata(channel_key) or {}
        stream_path = channel_stream_path(channel_key)
        files = metadata.get("files") or []
        normalized_files = []
        for item in sorted(files, key=lambda row: int(row.get("order", 0))):
            normalized_files.append(
                {
                    "id": int(item.get("id") or 0),
                    "order": int(item.get("order") or 0),
                    "filename": item.get("filename") or "",
                    "title": item.get("title") or item.get("filename") or "",
                    "duration": int(item.get("duration") or 0),
                }
            )
        channels.append(
            {
                "channelKey": channel_key,
                "channelName": metadata.get("channelName") or channel_key,
                "itemCount": int(metadata.get("itemCount") or len(files)),
                "playlistExists": stream_path.exists(),
                "streamPath": str(stream_path),
                "updatedAt": metadata.get("updatedAt"),
                "files": normalized_files,
            }
        )

    channels.sort(key=lambda item: item.get("channelName", ""))
    return channels


def restore_saved_channels():
    ensure_dirs()
    for metadata_path in CHANNELS_ROOT.glob("*/channel.json"):
        channel_key = metadata_path.parent.name
        metadata = read_channel_metadata(channel_key)
        if not metadata:
            continue

        files = metadata.get("files") or []
        if not files:
            continue

        try:
            build_channel_playlist(channel_key, files)
            pid = start_channel_process(channel_key)
            metadata["pid"] = pid
            metadata["updatedAt"] = datetime.now(timezone.utc).isoformat()
            metadata["playlistPath"] = str(channel_playlist_file(channel_key))
            metadata["streamPath"] = str(channel_stream_path(channel_key))
            metadata["itemCount"] = len(files)
            write_channel_metadata(channel_key, metadata)
        except Exception:
            continue


def collect_stream(services):
    playlist_exists = PLAYLIST_PATH.exists()
    segment_paths = [path for path in HLS_DIR.glob("*.ts") if path.is_file()] if HLS_DIR.exists() else []
    playlist_mtime = PLAYLIST_PATH.stat().st_mtime if playlist_exists else None

    hls_service = next((service for service in services if service["name"] == "hls"), None)
    hls_active = bool(hls_service and hls_service["activeState"] == "active")

    if playlist_exists and segment_paths and hls_active:
        status = "online"
    elif playlist_exists and segment_paths:
        status = "degraded"
    else:
        status = "offline"

    return {
        "status": status,
        "statusLabel": STREAM_STATUS_TITLES.get(status, "НЕИЗВЕСТНО"),
        "statusBadgeLabel": label_for_state(status),
        "playlistExists": playlist_exists,
        "playlistPath": str(PLAYLIST_PATH),
        "playlistUpdatedAt": iso_timestamp(playlist_mtime) if playlist_mtime else None,
        "segmentCount": len(segment_paths),
        "directoryExists": HLS_DIR.exists(),
    }


def collect_system():
    usage = shutil.disk_usage("/var/www")
    return {
        "disk": {
            "totalBytes": usage.total,
            "usedBytes": usage.used,
            "freeBytes": usage.free,
        }
    }


def build_payload():
    services = collect_services()
    return {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "services": services,
        "videos": collect_videos(),
        "channels": collect_channels(),
        "stream": collect_stream(services),
        "system": collect_system(),
    }


def build_videos_payload():
    return {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "videos": collect_videos(),
    }


def delete_source_files():
    deleted = []
    if not VIDEO_DIR.exists():
        return {"deletedCount": 0, "deletedFiles": deleted}

    for path in VIDEO_DIR.iterdir():
        if not path.is_file():
            continue

        path.unlink()
        deleted.append(path.name)

    return {"deletedCount": len(deleted), "deletedFiles": deleted}


def parse_json_body(handler):
    content_length = handler.headers.get("Content-Length")
    if not content_length:
        return None, "Требуется Content-Length"

    try:
        body_length = int(content_length)
    except ValueError:
        return None, "Некорректный Content-Length"

    if body_length <= 0:
        return None, "Пустое тело запроса"

    raw = handler.rfile.read(body_length)
    try:
        return json.loads(raw.decode("utf-8")), None
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, "Некорректный JSON"


def delete_files_by_basename(name):
    if not VIDEO_DIR.exists():
        return {
            "ok": True,
            "deletedCount": 0,
            "deletedFiles": [],
            "message": "Каталог с видео не найден",
        }

    requested = (name or "").strip()
    if not requested:
        return {
            "ok": False,
            "statusCode": 400,
            "error": "Требуется поле name в JSON",
        }

    if "/" in requested or "\\" in requested or requested in {".", ".."}:
        return {
            "ok": False,
            "statusCode": 400,
            "error": "Некорректное имя файла",
        }

    deleted = []
    for path in VIDEO_DIR.iterdir():
        if not path.is_file():
            continue
        if path.stem != requested:
            continue
        path.unlink()
        deleted.append(path.name)

    return {
        "ok": True,
        "deletedCount": len(deleted),
        "deletedFiles": deleted,
    }


def get_request_api_key(handler):
    value = handler.headers.get("X-API-Key", "")
    return value.strip()


def is_api_key_valid(handler):
    if not API_KEY:
        return False
    return get_request_api_key(handler) == API_KEY


def save_uploaded_video(handler):
    content_length = handler.headers.get("Content-Length")
    filename = handler.headers.get("X-Filename") or ""
    safe_name = sanitize_filename(filename)

    if not safe_name:
        return {
            "ok": False,
            "statusCode": 400,
            "error": "Требуется заголовок X-Filename",
        }

    if not content_length:
        return {
            "ok": False,
            "statusCode": 411,
            "error": "Требуется Content-Length",
        }

    try:
        bytes_to_read = int(content_length)
    except ValueError:
        return {
            "ok": False,
            "statusCode": 400,
            "error": "Некорректный Content-Length",
        }

    if bytes_to_read <= 0:
        return {
            "ok": False,
            "statusCode": 400,
            "error": "Пустое тело запроса",
        }

    ensure_dirs()
    destination = unique_destination_path(VIDEO_DIR, safe_name)

    remaining = bytes_to_read
    with destination.open("wb") as output:
        while remaining > 0:
            chunk = handler.rfile.read(min(65536, remaining))
            if not chunk:
                break
            output.write(chunk)
            remaining -= len(chunk)

    written_bytes = bytes_to_read - remaining
    if written_bytes != bytes_to_read:
        destination.unlink(missing_ok=True)
        return {
            "ok": False,
            "statusCode": 400,
            "error": "Тело запроса обрезано",
        }

    return {
        "ok": True,
        "filename": destination.name,
        "path": str(destination),
        "bytesWritten": written_bytes,
    }


def sync_channel(payload):
    ensure_dirs()

    channel_key = sanitize_channel_key(payload.get("channelKey"))
    files = payload.get("files") or []

    if not channel_key:
        return {"ok": False, "statusCode": 400, "error": "Требуется channelKey"}

    if not isinstance(files, list) or not files:
        return {"ok": False, "statusCode": 400, "error": "Требуется непустой список files"}

    playlist_path, item_count = build_channel_playlist(channel_key, files)
    pid = start_channel_process(channel_key)
    metadata = {
        "channelKey": channel_key,
        "channelName": (payload.get("channelName") or "").strip(),
        "files": files,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "playlistPath": str(playlist_path),
        "streamPath": str(channel_stream_path(channel_key)),
        "itemCount": item_count,
        "pid": pid,
    }
    write_channel_metadata(channel_key, metadata)

    return {
        "ok": True,
        "channelKey": channel_key,
        "playlistPath": str(playlist_path),
        "streamPath": str(channel_stream_path(channel_key)),
        "pid": pid,
        "itemCount": item_count,
    }


def delete_channel(channel_key):
    safe_key = sanitize_channel_key(channel_key)
    if not safe_key:
        return {"ok": False, "statusCode": 400, "error": "Требуется channelKey"}

    stop_channel_process(safe_key)
    cleanup_channel_hls(safe_key)

    root = channel_root(safe_key)
    if root.exists():
        shutil.rmtree(root, ignore_errors=True)

    output_dir = channel_hls_dir(safe_key)
    if output_dir.exists():
        shutil.rmtree(output_dir, ignore_errors=True)

    return {"ok": True, "channelKey": safe_key}


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, payload, status_code=200):
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/status":
            self._send_json(build_payload())
            return

        if path == "/videos/status":
            if not is_api_key_valid(self):
                self._send_json({"error": "не авторизован"}, status_code=401)
                return

            self._send_json(build_videos_payload())
            return

        if path == "/health":
            self._send_json({"status": "ok", "timestamp": time.time()})
            return

        self._send_json({"error": "не найдено"}, status_code=404)

    def do_POST(self):
        path = urlparse(self.path).path
        protected_paths = {
            "/videos/delete-all",
            "/videos/delete-by-name",
            "/videos/upload",
            "/channels/sync",
            "/channels/delete",
        }
        if path in protected_paths and not is_api_key_valid(self):
            self._send_json({"error": "не авторизован"}, status_code=401)
            return

        if path == "/videos/upload":
            result = save_uploaded_video(self)
            if not result.get("ok"):
                self._send_json({"error": result["error"]}, status_code=result["statusCode"])
                return

            self._send_json(
                {
                    "status": "ok",
                    "message": "Файл загружен",
                    "filename": result["filename"],
                    "path": result["path"],
                    "bytesWritten": result["bytesWritten"],
                },
                status_code=201,
            )
            return

        if path == "/videos/delete-all":
            result = delete_source_files()
            self._send_json({
                "status": "ok",
                "message": "Исходные файлы удалены",
                **result,
            })
            return

        if path == "/videos/delete-by-name":
            payload, error = parse_json_body(self)
            if error:
                self._send_json({"error": error}, status_code=400)
                return

            result = delete_files_by_basename(payload.get("name"))
            if not result.get("ok"):
                self._send_json({"error": result["error"]}, status_code=result["statusCode"])
                return

            self._send_json({
                "status": "ok",
                "message": "Файлы удалены",
                "deletedCount": result["deletedCount"],
                "deletedFiles": result["deletedFiles"],
            })
            return

        if path == "/channels/sync":
            payload, error = parse_json_body(self)
            if error:
                self._send_json({"error": error}, status_code=400)
                return

            try:
                result = sync_channel(payload)
            except FileNotFoundError as exc:
                self._send_json({"error": str(exc)}, status_code=404)
                return
            except RuntimeError as exc:
                self._send_json({"error": str(exc)}, status_code=400)
                return

            if not result.get("ok"):
                self._send_json({"error": result["error"]}, status_code=result["statusCode"])
                return

            self._send_json({
                "status": "ok",
                "message": "Канал синхронизирован",
                **result,
            })
            return

        if path == "/channels/delete":
            payload, error = parse_json_body(self)
            if error:
                self._send_json({"error": error}, status_code=400)
                return

            result = delete_channel(payload.get("channelKey"))
            if not result.get("ok"):
                self._send_json({"error": result["error"]}, status_code=result["statusCode"])
                return

            self._send_json({
                "status": "ok",
                "message": "Канал удален",
                **result,
            })
            return

        self._send_json({"error": "не найдено"}, status_code=404)

    def log_message(self, format, *args):
        return


def main():
    ensure_dirs()
    restore_saved_channels()
    server = ThreadingHTTPServer((API_HOST, API_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
