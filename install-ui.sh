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
    apt-get install -y nginx python3 >/dev/null
}

write_api_server() {
    log "Создание API-сервиса..."
    mkdir -p "$APP_ROOT"

    cat > "$API_SCRIPT" <<'PYEOF'
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

    def log_message(self, format, *args):
        return


def main():
    server = HTTPServer((API_HOST, API_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

    chmod +x "$API_SCRIPT"
}

write_ui_files() {
    log "Создание файлов веб-интерфейса..."
    mkdir -p "$UI_ROOT"

    cat > "$UI_ROOT/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="ru">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>MOOVI Playout Панель управления</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700;800&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="/styles.css">
  </head>
  <body>
    <div class="background-orb orb-a"></div>
    <div class="background-orb orb-b"></div>
    <main class="shell">
      <section class="hero panel">
        <div>
          <p class="eyebrow">MOOVI Playout</p>
          <h2>Управление сервисом</h2>
          <p class="hero-copy">Состояние потока, видеофайлов и служб</p>
        </div>
        <div class="hero-actions">
          <button id="refreshButton" class="button" type="button">Обновить сейчас</button>
          <p id="updatedAt" class="meta">Ожидание первого обновления...</p>
        </div>
      </section>

      <section class="summary-grid">
        <article class="panel metric-card">
          <p class="metric-label">Поток</p>
          <div class="metric-row">
            <strong id="streamStatus" class="metric-value">--</strong>
            <span id="streamBadge" class="status-pill neutral">Неизвестно</span>
          </div>
          <p id="streamMeta" class="meta">Состояние плейлиста ожидается</p>
        </article>

        <article class="panel metric-card">
          <p class="metric-label">Исходные файлы</p>
          <div class="metric-row">
            <strong id="videoCount" class="metric-value">0</strong>
            <span id="videoSize" class="status-pill neutral">0 B</span>
          </div>
          <p class="meta">/var/www/video</p>
        </article>

        <article class="panel metric-card">
          <p class="metric-label">Сегменты</p>
          <div class="metric-row">
            <strong id="segmentCount" class="metric-value">0</strong>
            <span id="playlistBadge" class="status-pill neutral">Плейлист отсутствует</span>
          </div>
          <p id="playlistMeta" class="meta">Данных HLS пока нет</p>
        </article>

        <article class="panel metric-card">
          <p class="metric-label">Службы</p>
          <div class="metric-row">
            <strong id="healthyServices" class="metric-value">0/0</strong>
            <span id="serviceBadge" class="status-pill neutral">Неизвестно</span>
          </div>
          <p class="meta">nginx, hls, ui-api</p>
        </article>
      </section>

      <section class="content-grid">
        <article class="panel">
          <div class="section-head">
            <h2>Состояние служб</h2>
            <span class="meta">Текущее состояние systemd</span>
          </div>
          <div id="servicesTable" class="table-shell"></div>
        </article>

        <article class="panel">
          <div class="section-head">
            <h2>Последние видео</h2>
            <span class="meta">Сначала новые файлы</span>
          </div>
          <div id="fileList" class="file-list"></div>
        </article>

        <article class="panel panel-wide">
          <div class="section-head">
            <h2>Обзор системы</h2>
            <span class="meta">Полезные данные о работе сервиса</span>
          </div>
          <div class="system-grid">
            <div>
              <p class="metric-label">Путь к плейлисту</p>
              <p id="playlistPath" class="mono">/var/www/hls/index.m3u8</p>
            </div>
            <div>
              <p class="metric-label">Свободно на диске</p>
              <p id="diskFree" class="mono">--</p>
            </div>
            <div>
              <p class="metric-label">Занято на диске</p>
              <p id="diskUsed" class="mono">--</p>
            </div>
            <div>
              <p class="metric-label">API панели</p>
              <p class="mono">127.0.0.1:9180</p>
            </div>
          </div>
        </article>
      </section>
    </main>
    <script src="/app.js" defer></script>
  </body>
</html>
HTMLEOF

    cat > "$UI_ROOT/styles.css" <<'CSSEOF'
:root {
  --bg: #07111f;
  --bg-soft: rgba(13, 26, 45, 0.7);
  --panel: rgba(10, 21, 37, 0.82);
  --panel-border: rgba(160, 198, 255, 0.12);
  --text: #ecf3ff;
  --muted: #8fa6c6;
  --accent: #5eead4;
  --accent-strong: #22c55e;
  --danger: #fb7185;
  --warning: #fbbf24;
  --shadow: 0 24px 80px rgba(2, 8, 20, 0.45);
  --radius: 24px;
}

* {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  min-height: 100%;
  font-family: "Roboto", "Segoe UI", "Helvetica Neue", sans-serif;
  background:
    radial-gradient(circle at top left, rgba(34, 197, 94, 0.18), transparent 30%),
    radial-gradient(circle at top right, rgba(94, 234, 212, 0.14), transparent 32%),
    linear-gradient(180deg, #08111d 0%, #050b14 100%);
  color: var(--text);
}

body {
  position: relative;
  overflow-x: hidden;
}

.background-orb {
  position: fixed;
  width: 28rem;
  height: 28rem;
  border-radius: 50%;
  filter: blur(70px);
  opacity: 0.34;
  pointer-events: none;
  animation: drift 16s ease-in-out infinite;
}

.orb-a {
  top: -10rem;
  left: -6rem;
  background: rgba(94, 234, 212, 0.34);
}

.orb-b {
  right: -7rem;
  bottom: -8rem;
  background: rgba(34, 197, 94, 0.24);
  animation-delay: -8s;
}

.shell {
  width: min(1280px, calc(100% - 2rem));
  margin: 0 auto;
  padding: 2rem 0 3rem;
}

.panel {
  background: var(--panel);
  border: 1px solid var(--panel-border);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  backdrop-filter: blur(18px);
}

.hero {
  display: grid;
  gap: 1.5rem;
  grid-template-columns: 1.6fr 1fr;
  padding: 2rem;
  animation: rise-in 0.8s ease both;
}

.eyebrow {
  margin: 0 0 1rem;
  color: var(--accent);
  letter-spacing: 0.18em;
  text-transform: uppercase;
  font-size: 0.78rem;
}

h1,
h2,
p {
  margin: 0;
}

h1 {
  font-size: 3rem;
  line-height: 0.98;
  max-width: 11ch;
}

h2 {
  font-size: 1.2rem;
}

.hero-copy,
.meta {
  color: var(--muted);
}

.hero-copy {
  margin-top: 1rem;
  max-width: 52ch;
  line-height: 1.6;
}

.hero-actions {
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  align-items: flex-end;
  gap: 1rem;
}

.button {
  border: 0;
  border-radius: 999px;
  padding: 0.95rem 1.35rem;
  background: linear-gradient(135deg, #5eead4, #22c55e);
  color: #042031;
  font-weight: 700;
  cursor: pointer;
  transition: transform 160ms ease, box-shadow 160ms ease;
  box-shadow: 0 12px 30px rgba(34, 197, 94, 0.24);
}

.button:hover {
  transform: translateY(-1px);
  box-shadow: 0 18px 40px rgba(34, 197, 94, 0.28);
}

.summary-grid,
.content-grid {
  display: grid;
  gap: 1rem;
  margin-top: 1rem;
}

.summary-grid {
  grid-template-columns: repeat(4, minmax(0, 1fr));
}

.content-grid {
  grid-template-columns: 1.1fr 0.9fr;
}

.panel-wide {
  grid-column: 1 / -1;
}

.metric-card {
  position: relative;
  padding: 1.3rem;
  padding-top: 4.2rem;
  animation: rise-in 0.9s ease both;
}

.metric-card:nth-child(2) {
  animation-delay: 60ms;
}

.metric-card:nth-child(3) {
  animation-delay: 120ms;
}

.metric-card:nth-child(4) {
  animation-delay: 180ms;
}

.metric-label {
  margin-bottom: 0.8rem;
  padding-top: 0.6rem;
  color: var(--muted);
  font-size: 0.82rem;
  text-transform: uppercase;
  letter-spacing: 0.12em;
}

.metric-row {
  display: flex;
  justify-content: flex-start;
  align-items: flex-end;
  gap: 1rem;
  margin-bottom: 0.8rem;
}

.metric-card .status-pill {
  position: absolute;
  top: 1.3rem;
  right: 1.3rem;
}

.metric-value {
  font-size: 2rem;
}

.status-pill {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 6rem;
  padding: 0.5rem 0.75rem;
  border-radius: 999px;
  font-size: 0.8rem;
  font-weight: 700;
}

.status-pill.good {
  background: rgba(34, 197, 94, 0.15);
  color: #9ef7b2;
}

.status-pill.warn {
  background: rgba(251, 191, 36, 0.14);
  color: #fbd56f;
}

.status-pill.bad {
  background: rgba(251, 113, 133, 0.14);
  color: #ff9caf;
}

.status-pill.neutral {
  background: rgba(143, 166, 198, 0.14);
  color: #b9cae3;
}

.panel {
  padding: 1.3rem;
}

.section-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 1rem;
  margin-bottom: 1rem;
}

.table-shell,
.file-list {
  display: grid;
  gap: 0.75rem;
}

.table-row,
.file-item {
  display: grid;
  gap: 0.75rem;
  padding: 0.95rem 1rem;
  border-radius: 18px;
  background: var(--bg-soft);
  border: 1px solid rgba(160, 198, 255, 0.08);
}

.table-row {
  grid-template-columns: 1.1fr 0.9fr 0.9fr 0.8fr;
  align-items: center;
}

.file-item {
  grid-template-columns: 1.3fr 0.8fr 0.9fr;
  align-items: center;
}

.mono {
  font-family: "SFMono-Regular", Consolas, "Liberation Mono", monospace;
  word-break: break-all;
}

.system-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
}

@keyframes rise-in {
  from {
    opacity: 0;
    transform: translateY(20px);
  }

  to {
    opacity: 1;
    transform: translateY(0);
  }
}

@keyframes drift {
  0%,
  100% {
    transform: translate3d(0, 0, 0) scale(1);
  }

  50% {
    transform: translate3d(1rem, -1.4rem, 0) scale(1.07);
  }
}

@media (max-width: 980px) {
  .hero,
  .content-grid,
  .summary-grid,
  .system-grid,
  .table-row,
  .file-item {
    grid-template-columns: 1fr;
  }

  .shell {
    width: min(100% - 1rem, 1180px);
  }
}
CSSEOF

    cat > "$UI_ROOT/app.js" <<'JSEOF'
const refreshButton = document.getElementById("refreshButton");
const updatedAt = document.getElementById("updatedAt");
const streamStatus = document.getElementById("streamStatus");
const streamBadge = document.getElementById("streamBadge");
const streamMeta = document.getElementById("streamMeta");
const videoCount = document.getElementById("videoCount");
const videoSize = document.getElementById("videoSize");
const segmentCount = document.getElementById("segmentCount");
const playlistBadge = document.getElementById("playlistBadge");
const playlistMeta = document.getElementById("playlistMeta");
const healthyServices = document.getElementById("healthyServices");
const serviceBadge = document.getElementById("serviceBadge");
const servicesTable = document.getElementById("servicesTable");
const fileList = document.getElementById("fileList");
const playlistPath = document.getElementById("playlistPath");
const diskFree = document.getElementById("diskFree");
const diskUsed = document.getElementById("diskUsed");

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return "0 B";
  }

  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return `${value.toFixed(value >= 10 || unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}

function formatDate(value) {
  if (!value) {
    return "--";
  }
  return new Date(value).toLocaleString("ru-RU");
}

function toneForStatus(status) {
  if (status === "online" || status === "active") {
    return "good";
  }
  if (status === "degraded" || status === "activating") {
    return "warn";
  }
  if (status === "offline" || status === "failed" || status === "inactive" || status === "not-found") {
    return "bad";
  }
  return "neutral";
}

function applyPill(node, label, tone) {
  node.textContent = label;
  node.className = `status-pill ${tone}`;
}

function renderServices(services) {
  servicesTable.innerHTML = "";
  services.forEach((service) => {
    const row = document.createElement("div");
    row.className = "table-row";
    row.innerHTML = `
      <div>
        <strong>${service.name}</strong>
        <p class="meta mono">${service.unit}</p>
      </div>
      <div>
        <p class="metric-label">Статус</p>
        <p>${service.activeStateLabel}</p>
      </div>
      <div>
        <p class="metric-label">Подстатус</p>
        <p>${service.subStateLabel}</p>
      </div>
      <div>
        <span class="status-pill ${service.healthy ? "good" : toneForStatus(service.loadState)}">${service.healthLabel}</span>
      </div>
    `;
    servicesTable.appendChild(row);
  });
}

function renderFiles(files) {
  fileList.innerHTML = "";
  if (!files.length) {
    const empty = document.createElement("div");
    empty.className = "file-item";
    empty.innerHTML = `
      <div>
        <strong>Видеофайлы не найдены</strong>
        <p class="meta">Добавьте mp4-файлы в /var/www/video</p>
      </div>
      <div class="mono">0 B</div>
      <div class="meta">--</div>
    `;
    fileList.appendChild(empty);
    return;
  }

  files.forEach((file) => {
    const item = document.createElement("div");
    item.className = "file-item";
    item.innerHTML = `
      <div>
        <strong>${file.name}</strong>
        <p class="meta">Исходный файл</p>
      </div>
      <div class="mono">${formatBytes(file.sizeBytes)}</div>
      <div class="meta">${formatDate(file.modifiedAt)}</div>
    `;
    fileList.appendChild(item);
  });
}

function renderPayload(payload) {
  const healthyCount = payload.services.filter((service) => service.healthy).length;

  streamStatus.textContent = payload.stream.statusLabel;
  applyPill(streamBadge, payload.stream.statusBadgeLabel, toneForStatus(payload.stream.status));
  streamMeta.textContent = payload.stream.playlistUpdatedAt
    ? `Плейлист обновлен: ${formatDate(payload.stream.playlistUpdatedAt)}`
    : "Плейлист еще не создан";

  videoCount.textContent = String(payload.videos.count);
  applyPill(videoSize, formatBytes(payload.videos.totalBytes), "neutral");

  segmentCount.textContent = String(payload.stream.segmentCount);
  applyPill(
    playlistBadge,
    payload.stream.playlistExists ? "Плейлист готов" : "Плейлист отсутствует",
    payload.stream.playlistExists ? "good" : "bad"
  );
  playlistMeta.textContent = payload.stream.directoryExists ? payload.stream.playlistPath : "Каталог HLS не найден";

  healthyServices.textContent = `${healthyCount}/${payload.services.length}`;
  applyPill(
    serviceBadge,
    healthyCount === payload.services.length ? "Все в порядке" : "Требуется внимание",
    healthyCount === payload.services.length ? "good" : "warn"
  );

  playlistPath.textContent = payload.stream.playlistPath;
  diskFree.textContent = formatBytes(payload.system.disk.freeBytes);
  diskUsed.textContent = formatBytes(payload.system.disk.usedBytes);
  updatedAt.textContent = `Последнее обновление: ${formatDate(payload.generatedAt)}`;

  renderServices(payload.services);
  renderFiles(payload.videos.recentFiles);
}

async function refresh() {
  refreshButton.disabled = true;
  refreshButton.textContent = "Обновление...";
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`Запрос завершился со статусом ${response.status}`);
    }
    const payload = await response.json();
    renderPayload(payload);
  } catch (error) {
    streamStatus.textContent = "ОШИБКА";
    applyPill(streamBadge, "Недоступно", "bad");
    streamMeta.textContent = error.message;
    updatedAt.textContent = "API панели недоступно";
  } finally {
    refreshButton.disabled = false;
    refreshButton.textContent = "Обновить сейчас";
  }
}

refreshButton.addEventListener("click", refresh);
refresh();
window.setInterval(refresh, 5000);
JSEOF
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

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

    ln -sf "$NGINX_SITE" "$NGINX_LINK"
}

enable_services() {
  log "Включение и запуск служб..."
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
  log "Установка веб-интерфейса завершена"
  echo "Панель управления: http://$host_ip:$UI_PORT"
  echo "Проверка API: http://$host_ip:$UI_PORT/api/health"
}

main() {
  require_supported_os
    require_root
    install_dependencies
    write_api_server
    write_ui_files
    write_service_unit
    write_nginx_site
    enable_services
    print_summary
}

main