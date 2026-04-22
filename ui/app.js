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
const deleteAllButton = document.getElementById("deleteAllButton");
const playlistPath = document.getElementById("playlistPath");
const diskFree = document.getElementById("diskFree");
const diskUsed = document.getElementById("diskUsed");
const streamLink = document.getElementById("streamLink");
const apiStatusLink = document.getElementById("apiStatusLink");
const apiHealthLink = document.getElementById("apiHealthLink");

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

function updateLinks() {
	const baseUrl = `${window.location.protocol}//${window.location.hostname}`;
	const baseUrlWithPort = `${baseUrl}:${window.location.port}`;

	streamLink.href = `${baseUrl}/index.m3u8`;
	streamLink.textContent = `${baseUrl}/index.m3u8`;

	apiStatusLink.href = `${baseUrlWithPort}/api/status`;
	apiStatusLink.textContent = `${baseUrlWithPort}/api/status`;

	apiHealthLink.href = `${baseUrlWithPort}/api/health`;
	apiHealthLink.textContent = `${baseUrlWithPort}/api/health`;
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
	deleteAllButton.disabled = true;
	// refreshButton.textContent = "Обновление...";
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
		deleteAllButton.disabled = false;
		refreshButton.textContent = "Обновить сейчас";
	}
}

async function deleteAllFiles() {
	const confirmed = window.confirm("Удалить все файлы из /var/www/video?");
	if (!confirmed) {
		return;
	}

	deleteAllButton.disabled = true;
	deleteAllButton.textContent = "Удаление...";

	try {
		const response = await fetch("/api/videos/delete-all", {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
			},
		});

		if (!response.ok) {
			throw new Error(`Удаление завершилось со статусом ${response.status}`);
		}

		await refresh();
	} catch (error) {
		streamMeta.textContent = error.message;
	} finally {
		deleteAllButton.disabled = false;
		deleteAllButton.textContent = "Удалить все";
	}
}

refreshButton.addEventListener("click", refresh);
deleteAllButton.addEventListener("click", deleteAllFiles);
updateLinks();
refresh();
window.setInterval(refresh, 5000);