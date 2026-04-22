#!/usr/bin/env python3
import json
import shutil
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

VIDEO_DIR = Path("/var/www/video")
HLS_DIR = Path("/var/www/hls")
PLAYLIST_PATH = HLS_DIR / "index.m3u8"
API_HOST = "127.0.0.1"
API_PORT = 9180
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


def iso_timestamp(timestamp):
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat()


def run_command(args):
    result = subprocess.run(args, capture_output=True, text=True)
    return result.returncode, result.stdout.strip(), result.stderr.strip()


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
    if not VIDEO_DIR.exists():
        return {
            "count": 0,
            "totalBytes": 0,
            "recentFiles": [],
            "directoryExists": False,
        }

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
        "stream": collect_stream(services),
        "system": collect_system(),
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

        if path == "/health":
            self._send_json({"status": "ok", "timestamp": time.time()})
            return

        self._send_json({"error": "не найдено"}, status_code=404)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/videos/delete-all":
            result = delete_source_files()
            self._send_json({
                "status": "ok",
                "message": "Исходные файлы удалены",
                **result,
            })
            return

        self._send_json({"error": "не найдено"}, status_code=404)

    def log_message(self, format, *args):
        return


def main():
    server = HTTPServer((API_HOST, API_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()