const ROOT_ID = "ai-video-downloader-root";
const BUTTON_ID = "ai-video-downloader-btn";
const PANEL_ID = "ai-video-downloader-panel";
const LIST_ID = "ai-video-downloader-list";
const TOAST_ID = "ai-video-downloader-toast";
const POSITION_STORAGE_KEY = "ai-video-downloader-position-v1";
let lastUrl = location.href;
let formatsCache = new Map();
let loadingFormats = false;
let activeDownloadSelector = "";
let dragState = null;
let suppressClickUntil = 0;

function isWatchPage() {
  return location.hostname.includes("youtube.com") && location.pathname === "/watch";
}

function getPlayer() {
  return document.querySelector("#movie_player") || document.querySelector(".html5-video-player");
}

function getVideoTitle() {
  return document.title.replace(/\s*-\s*YouTube$/i, "").trim();
}

function showToast(message, isError = false) {
  let toast = document.getElementById(TOAST_ID);

  if (!toast) {
    toast = document.createElement("div");
    toast.id = TOAST_ID;
    toast.style.position = "fixed";
    toast.style.right = "20px";
    toast.style.bottom = "20px";
    toast.style.zIndex = "2147483647";
    toast.style.padding = "10px 14px";
    toast.style.borderRadius = "10px";
    toast.style.fontFamily = "Arial, sans-serif";
    toast.style.fontSize = "13px";
    toast.style.boxShadow = "0 8px 24px rgba(0, 0, 0, 0.25)";
    toast.style.transition = "opacity 0.2s ease";
    document.body.appendChild(toast);
  }

  toast.textContent = message;
  toast.style.background = isError ? "#b3261e" : "#111827";
  toast.style.color = "#ffffff";
  toast.style.opacity = "1";

  window.clearTimeout(showToast.timeoutId);
  showToast.timeoutId = window.setTimeout(() => {
    if (toast) {
      toast.style.opacity = "0";
    }
  }, 2800);
}

function createIconMarkup() {
  return `
    <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true">
      <path d="M12 3a1 1 0 0 1 1 1v8.17l2.58-2.58a1 1 0 1 1 1.41 1.42l-4.29 4.29a1 1 0 0 1-1.4 0l-4.3-4.3a1 1 0 0 1 1.42-1.4L11 12.16V4a1 1 0 0 1 1-1Z" fill="currentColor"></path>
      <path d="M5 18a1 1 0 0 1 1-1h12a1 1 0 1 1 0 2H6a1 1 0 0 1-1-1Z" fill="currentColor"></path>
    </svg>
  `;
}

function getStoredPosition() {
  try {
    const raw = window.localStorage.getItem(POSITION_STORAGE_KEY);
    if (!raw) {
      return null;
    }

    const parsed = JSON.parse(raw);
    if (typeof parsed?.x !== "number" || typeof parsed?.y !== "number") {
      return null;
    }

    return {
      x: Math.min(Math.max(parsed.x, 0), 1),
      y: Math.min(Math.max(parsed.y, 0), 1),
    };
  } catch {
    return null;
  }
}

function saveStoredPosition(x, y) {
  window.localStorage.setItem(POSITION_STORAGE_KEY, JSON.stringify({ x, y }));
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function getButtonMetrics(root, player) {
  return {
    rootWidth: root.offsetWidth || 58,
    rootHeight: root.offsetHeight || 26,
    playerWidth: player.clientWidth || 0,
    playerHeight: player.clientHeight || 0,
  };
}

function applyRootPosition(root, player, normalizedPosition = null) {
  const stored = normalizedPosition || getStoredPosition() || { x: 0.94, y: 0.08 };
  const { rootWidth, rootHeight, playerWidth, playerHeight } = getButtonMetrics(root, player);
  const maxLeft = Math.max(playerWidth - rootWidth - 8, 8);
  const maxTop = Math.max(playerHeight - rootHeight - 8, 8);
  const left = clamp(Math.round(stored.x * maxLeft), 8, maxLeft);
  const top = clamp(Math.round(stored.y * maxTop), 8, maxTop);

  root.style.left = `${left}px`;
  root.style.top = `${top}px`;
  root.style.right = "auto";
  updatePanelAlignment(root, player);
}

function updatePanelAlignment(root, player) {
  const panel = document.getElementById(PANEL_ID);
  if (!panel || !player) {
    return;
  }

  const playerRect = player.getBoundingClientRect();
  const rootRect = root.getBoundingClientRect();
  const anchorLeft = rootRect.left - playerRect.left;
  const anchorCenter = anchorLeft + rootRect.width / 2;
  const useRightAlign = anchorCenter > playerRect.width * 0.62;

  root.style.alignItems = useRightAlign ? "flex-end" : "flex-start";
  panel.style.transformOrigin = useRightAlign ? "top right" : "top left";
}

function persistCurrentPosition(root, player) {
  const { rootWidth, rootHeight, playerWidth, playerHeight } = getButtonMetrics(root, player);
  const maxLeft = Math.max(playerWidth - rootWidth - 8, 8);
  const maxTop = Math.max(playerHeight - rootHeight - 8, 8);
  const left = parseFloat(root.style.left || "8");
  const top = parseFloat(root.style.top || "8");

  saveStoredPosition(
    maxLeft <= 8 ? 0.94 : clamp((left - 8) / Math.max(maxLeft - 8, 1), 0, 1),
    maxTop <= 8 ? 0.08 : clamp((top - 8) / Math.max(maxTop - 8, 1), 0, 1),
  );
}

function onDragMove(event) {
  if (!dragState) {
    return;
  }

  const { root, player, offsetX, offsetY } = dragState;
  const playerRect = player.getBoundingClientRect();
  const left = clamp(event.clientX - playerRect.left - offsetX, 8, Math.max(playerRect.width - root.offsetWidth - 8, 8));
  const top = clamp(event.clientY - playerRect.top - offsetY, 8, Math.max(playerRect.height - root.offsetHeight - 8, 8));

  root.style.left = `${left}px`;
  root.style.top = `${top}px`;
  root.style.right = "auto";
  dragState.moved = true;
  updatePanelAlignment(root, player);
}

function stopDragging() {
  if (!dragState) {
    return;
  }

  const { root, button, player, moved } = dragState;
  button.style.cursor = "grab";
  button.style.opacity = "1";
  if (moved) {
    suppressClickUntil = Date.now() + 250;
    persistCurrentPosition(root, player);
  }

  window.removeEventListener("pointermove", onDragMove);
  window.removeEventListener("pointerup", stopDragging);
  window.removeEventListener("pointercancel", stopDragging);
  dragState = null;
}

function enableDragging(root, button, player) {
  button.style.cursor = "grab";

  button.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) {
      return;
    }

    const rootRect = root.getBoundingClientRect();
    dragState = {
      root,
      button,
      player,
      offsetX: event.clientX - rootRect.left,
      offsetY: event.clientY - rootRect.top,
      moved: false,
    };

    button.style.cursor = "grabbing";
    button.style.opacity = "0.92";
    window.addEventListener("pointermove", onDragMove);
    window.addEventListener("pointerup", stopDragging);
    window.addEventListener("pointercancel", stopDragging);
  });
}

function formatBytes(value) {
  if (!value || value <= 0) {
    return "";
  }

  const units = ["B", "KB", "MB", "GB"];
  let size = value;
  let unitIndex = 0;

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }

  return `${size.toFixed(size >= 10 ? 0 : 1)} ${units[unitIndex]}`;
}

function createRoot() {
  const player = getPlayer();
  const root = document.createElement("div");
  root.id = ROOT_ID;
  root.style.position = "absolute";
  root.style.top = "12px";
  root.style.left = "12px";
  root.style.right = "auto";
  root.style.zIndex = "9999";
  root.style.display = "flex";
  root.style.flexDirection = "column";
  root.style.alignItems = "flex-start";
  root.style.gap = "8px";
  root.style.userSelect = "none";

  const button = document.createElement("button");
  button.id = BUTTON_ID;
  button.type = "button";
  button.title = "Download video";
  button.innerHTML = createIconMarkup();
  button.style.width = "56px";
  button.style.height = "24px";
  button.style.display = "inline-flex";
  button.style.alignItems = "center";
  button.style.justifyContent = "center";
  button.style.border = "1px solid rgba(255,255,255,0.18)";
  button.style.borderRadius = "999px";
  button.style.background = "linear-gradient(180deg, #34d399 0%, #059669 100%)";
  button.style.color = "#ffffff";
  button.style.boxShadow = "0 8px 18px rgba(0, 0, 0, 0.28)";
  button.style.cursor = "grab";
  button.style.backdropFilter = "blur(6px)";
  button.style.padding = "0 8px";

  const grip = document.createElement("div");
  grip.style.display = "grid";
  grip.style.gridTemplateColumns = "repeat(2, 2px)";
  grip.style.gridAutoRows = "2px";
  grip.style.gap = "2px";
  grip.style.marginRight = "6px";
  for (let index = 0; index < 6; index += 1) {
    const dot = document.createElement("span");
    dot.style.width = "2px";
    dot.style.height = "2px";
    dot.style.borderRadius = "999px";
    dot.style.background = "rgba(255,255,255,0.7)";
    grip.appendChild(dot);
  }

  const icon = document.createElement("span");
  icon.style.display = "inline-flex";
  icon.style.alignItems = "center";
  icon.style.justifyContent = "center";
  icon.innerHTML = createIconMarkup();

  button.appendChild(grip);
  button.appendChild(icon);

  button.addEventListener("mouseenter", () => {
    button.style.transform = "translateY(-1px)";
    button.style.filter = "brightness(1.05)";
  });

  button.addEventListener("mouseleave", () => {
    button.style.transform = "translateY(0)";
    button.style.filter = "brightness(1)";
  });

  button.addEventListener("click", async (event) => {
    if (Date.now() < suppressClickUntil) {
      return;
    }

    event.stopPropagation();
    if (!isWatchPage()) {
      showToast("Open a YouTube watch page first.", true);
      return;
    }

    const panel = document.getElementById(PANEL_ID);
    const shouldOpen = panel.style.display === "none";
    panel.style.display = shouldOpen ? "flex" : "none";
    button.style.background = shouldOpen
      ? "linear-gradient(180deg, #10b981 0%, #047857 100%)"
      : "linear-gradient(180deg, #34d399 0%, #059669 100%)";

    if (shouldOpen) {
      await loadFormats();
    }
  });

  const panel = document.createElement("div");
  panel.id = PANEL_ID;
  panel.style.display = "none";
  panel.style.width = "250px";
  panel.style.maxHeight = "300px";
  panel.style.overflow = "hidden";
  panel.style.borderRadius = "12px";
  panel.style.background = "rgba(17, 24, 39, 0.96)";
  panel.style.border = "1px solid rgba(255,255,255,0.1)";
  panel.style.boxShadow = "0 18px 40px rgba(0, 0, 0, 0.35)";
  panel.style.color = "#ffffff";
  panel.style.fontFamily = "Arial, sans-serif";
  panel.style.flexDirection = "column";

  const header = document.createElement("div");
  header.style.display = "flex";
  header.style.alignItems = "center";
  header.style.justifyContent = "space-between";
  header.style.padding = "10px 12px";
  header.style.borderBottom = "1px solid rgba(255,255,255,0.08)";

  const title = document.createElement("div");
  title.textContent = "Download";
  title.style.fontSize = "13px";
  title.style.fontWeight = "700";

  const refresh = document.createElement("button");
  refresh.type = "button";
  refresh.textContent = "↻";
  refresh.title = "Refresh formats";
  refresh.style.border = "0";
  refresh.style.background = "transparent";
  refresh.style.color = "#9ca3af";
  refresh.style.cursor = "pointer";
  refresh.style.fontSize = "14px";
  refresh.addEventListener("click", async (event) => {
    event.stopPropagation();
    await loadFormats(true);
  });

  header.appendChild(title);
  header.appendChild(refresh);

  const list = document.createElement("div");
  list.id = LIST_ID;
  list.style.maxHeight = "248px";
  list.style.overflowY = "auto";
  list.style.padding = "8px";

  panel.appendChild(header);
  panel.appendChild(list);
  root.appendChild(button);
  root.appendChild(panel);

  renderFormats([{ label: "Best quality", meta: "Video + audio", selector: "bv*+ba/b", recommended: true }]);
  if (player) {
    enableDragging(root, button, player);
    window.requestAnimationFrame(() => applyRootPosition(root, player));
  }

  return root;
}

function renderFormats(formats, errorMessage = "") {
  const list = document.getElementById(LIST_ID);
  if (!list) {
    return;
  }

  list.innerHTML = "";

  if (errorMessage) {
    const errorItem = document.createElement("div");
    errorItem.textContent = errorMessage;
    errorItem.style.padding = "10px";
    errorItem.style.fontSize = "12px";
    errorItem.style.color = "#fca5a5";
    list.appendChild(errorItem);
    return;
  }

  formats.forEach((format) => {
    const row = document.createElement("button");
    row.type = "button";
    row.style.width = "100%";
    row.style.display = "flex";
    row.style.flexDirection = "column";
    row.style.alignItems = "flex-start";
    row.style.gap = "2px";
    row.style.padding = "10px";
    row.style.marginBottom = "6px";
    row.style.border = format.recommended ? "1px solid rgba(16,185,129,0.55)" : "1px solid rgba(255,255,255,0.08)";
    row.style.borderRadius = "10px";
    row.style.background = activeDownloadSelector === format.selector
      ? "rgba(16, 185, 129, 0.22)"
      : "rgba(255,255,255,0.04)";
    row.style.color = "#ffffff";
    row.style.cursor = "pointer";
    row.style.textAlign = "left";

    const label = document.createElement("div");
    label.textContent = format.label;
    label.style.fontSize = "12px";
    label.style.fontWeight = "700";

    const meta = document.createElement("div");
    meta.textContent = format.meta || "";
    meta.style.fontSize = "11px";
    meta.style.color = "#cbd5e1";

    row.appendChild(label);
    row.appendChild(meta);
    row.addEventListener("click", () => startDownload(format));
    list.appendChild(row);
  });
}

async function loadFormats(force = false) {
  const cacheKey = window.location.href;
  if (!force && formatsCache.has(cacheKey)) {
    renderFormats(formatsCache.get(cacheKey));
    return;
  }

  if (loadingFormats) {
    return;
  }

  loadingFormats = true;
  renderFormats([], "Loading formats…");

  try {
    const response = await chrome.runtime.sendMessage({
      type: "listFormats",
      videoUrl: window.location.href,
      pageTitle: getVideoTitle()
    });

    if (!response?.ok) {
      throw new Error(response?.error || "Could not load formats.");
    }

    const formats = response.formats?.length
      ? response.formats
      : [{ label: "Best quality", meta: "Video + audio", selector: "bv*+ba/b", recommended: true }];

    formatsCache.set(cacheKey, formats);
    renderFormats(formats);
  } catch (error) {
    renderFormats([], `Format load failed: ${error.message}`);
  } finally {
    loadingFormats = false;
  }
}

async function startDownload(format) {
  activeDownloadSelector = format.selector;
  renderFormats(formatsCache.get(window.location.href) || [format]);

  try {
    const response = await chrome.runtime.sendMessage({
      type: "download",
      videoUrl: window.location.href,
      pageTitle: getVideoTitle(),
      formatSelector: format.selector,
      formatLabel: format.label
    });

    if (!response?.ok) {
      throw new Error(response?.error || "Native app did not accept the request.");
    }

    showToast(response.message || `Download started: ${format.label}`);
    closePanel();
  } catch (error) {
    showToast(`Download failed: ${error.message}`, true);
  } finally {
    activeDownloadSelector = "";
    renderFormats(formatsCache.get(window.location.href) || [format]);
  }
}

function closePanel() {
  const panel = document.getElementById(PANEL_ID);
  const button = document.getElementById(BUTTON_ID);
  if (panel) {
    panel.style.display = "none";
  }
  if (button) {
    button.style.background = "linear-gradient(180deg, #34d399 0%, #059669 100%)";
  }
}

function ensureButton() {
  if (!isWatchPage()) {
    document.getElementById(ROOT_ID)?.remove();
    return;
  }

  const player = getPlayer();
  if (!player) {
    return;
  }

  if (document.getElementById(ROOT_ID)) {
    applyRootPosition(document.getElementById(ROOT_ID), player);
    return;
  }

  const computedStyle = window.getComputedStyle(player);
  if (computedStyle.position === "static") {
    player.style.position = "relative";
  }

  player.appendChild(createRoot());
}

function watchNavigation() {
  setInterval(() => {
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      closePanel();
      dragState = null;
      window.setTimeout(ensureButton, 800);
    }
  }, 500);
}

document.addEventListener("click", (event) => {
  const root = document.getElementById(ROOT_ID);
  if (root && !root.contains(event.target)) {
    closePanel();
  }
});

window.addEventListener("resize", () => {
  const root = document.getElementById(ROOT_ID);
  const player = getPlayer();
  if (root && player) {
    applyRootPosition(root, player);
  }
});

const observer = new MutationObserver(() => {
  ensureButton();
});

observer.observe(document.documentElement, {
  childList: true,
  subtree: true
});

watchNavigation();
window.addEventListener("load", () => window.setTimeout(ensureButton, 1200));
window.setTimeout(ensureButton, 1800);
