#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
EXTENSION_DIR="$ROOT_DIR/extension"
NATIVE_APP_DIR="$ROOT_DIR/native_app"
DOWNLOADER_PATH="$NATIVE_APP_DIR/downloader.py"
TEMPLATE_PATH="$NATIVE_APP_DIR/com.ai.downloader.json.template"
LOCAL_MANIFEST_PATH="$NATIVE_APP_DIR/com.ai.downloader.json"
DOWNLOAD_DIR="$HOME/Downloads/Engine Video Downloader"
INSTALL_LOG_PATH="$DOWNLOAD_DIR/install-engines.log"

CHROME_NM_DIR="$HOME/.config/google-chrome/NativeMessagingHosts"
CHROMIUM_NM_DIR="$HOME/.config/chromium/NativeMessagingHosts"
BRAVE_NM_DIR="$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"

AUTO_INSTALL_ENGINES=1
declare -a POSITIONAL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --install-engines)
      AUTO_INSTALL_ENGINES=1
      ;;
    --no-install-engines)
      AUTO_INSTALL_ENGINES=0
      ;;
    -h|--help)
      echo "Usage: $0 [extension-id] [chrome|chromium|brave|auto|all] [--install-engines|--no-install-engines]"
      exit 0
      ;;
    *)
      POSITIONAL_ARGS+=("$arg")
      ;;
  esac
done

EXTENSION_ID="${POSITIONAL_ARGS[0]:-}"
TARGET_BROWSER="${POSITIONAL_ARGS[1]:-auto}"

PKG_MANAGER=""
declare -a SYSTEM_PACKAGES=()
declare -a PIP_PACKAGES=()
declare -a MISSING_ENGINES=()
REQUIRED_MISSING_COUNT=0

print_header() {
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     Engine Video Downloader — Installer          ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

ok() {
  echo -e "  ${GREEN}✓${NC} $1"
}

warn() {
  echo -e "  ${YELLOW}!${NC} $1"
}

fail() {
  echo -e "  ${RED}✗${NC} $1"
}

command_version() {
  "$1" "$2" 2>/dev/null | head -n 1 | tr -d '\r'
}

add_unique() {
  local -n arr_ref="$1"
  local value="$2"
  local item
  for item in "${arr_ref[@]:-}"; do
    [[ "$item" == "$value" ]] && return
  done
  arr_ref+=("$value")
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  else
    echo "none"
  fi
}

queue_system_package() {
  local apt_name="$1"
  local dnf_name="${2:-$1}"
  local pacman_name="${3:-$1}"
  local selected_name="$apt_name"

  case "$PKG_MANAGER" in
    dnf) selected_name="$dnf_name" ;;
    pacman) selected_name="$pacman_name" ;;
  esac

  add_unique SYSTEM_PACKAGES "$selected_name"
}

queue_missing_engine() {
  local label="$1"
  add_unique MISSING_ENGINES "$label"
}

node_is_20_plus() {
  local version="$1"
  local major="${version%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 20 ))
}

collect_dependency_status() {
  local collect_targets="$1"
  REQUIRED_MISSING_COUNT=0
  if [[ "$collect_targets" == "1" ]]; then
    SYSTEM_PACKAGES=()
    PIP_PACKAGES=()
    MISSING_ENGINES=()
  fi

  if command -v yt-dlp >/dev/null 2>&1; then
    ok "yt-dlp $(command_version yt-dlp --version)"
  else
    fail "yt-dlp not found in PATH"
    REQUIRED_MISSING_COUNT=$((REQUIRED_MISSING_COUNT + 1))
    if [[ "$collect_targets" == "1" ]]; then
      add_unique PIP_PACKAGES "yt-dlp"
      queue_missing_engine "yt-dlp"
    fi
  fi

  if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg found"
  else
    fail "ffmpeg not found"
    REQUIRED_MISSING_COUNT=$((REQUIRED_MISSING_COUNT + 1))
    if [[ "$collect_targets" == "1" ]]; then
      queue_system_package "ffmpeg"
      queue_missing_engine "ffmpeg"
    fi
  fi

  if command -v aria2c >/dev/null 2>&1; then
    ok "aria2c found (optional segmented downloads available)"
  else
    warn "aria2c not found (optional)"
  fi

  if has_python_module secretstorage; then
    ok "python3-secretstorage available"
  else
    warn "python3-secretstorage missing; browser cookie decryption may fail"
  fi

  mapfile -t NODE_STATUS < <(detect_node_status)
  NODE_PATH="${NODE_STATUS[0]:-}"
  NODE_VERSION="${NODE_STATUS[1]:-}"
  if [[ -n "$NODE_PATH" && -n "$NODE_VERSION" ]]; then
    if node_is_20_plus "$NODE_VERSION"; then
      ok "Node runtime selected: $NODE_PATH (v$NODE_VERSION)"
    else
      warn "Node runtime found but below 20: $NODE_PATH (v$NODE_VERSION)"
    fi
  else
    warn "Node.js 20+ not detected; YouTube format extraction may fail"
  fi

  if command -v x-terminal-emulator >/dev/null 2>&1 || command -v gnome-terminal >/dev/null 2>&1 || command -v konsole >/dev/null 2>&1 || command -v xfce4-terminal >/dev/null 2>&1 || command -v xterm >/dev/null 2>&1; then
    ok "Terminal emulator found"
  else
    warn "No supported terminal emulator found; downloader will fall back to log file mode"
  fi

  if [[ "$collect_targets" == "1" && ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    if ! python3 -m pip --version >/dev/null 2>&1; then
      queue_system_package "python3-pip" "python3-pip" "python-pip"
      queue_missing_engine "python3-pip"
    fi
  fi
}

run_engine_install_background() {
  local log_file="$INSTALL_LOG_PATH"
  mkdir -p "$DOWNLOAD_DIR"

  (
    set -euo pipefail
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Engine installation started"
    echo "Package manager: $PKG_MANAGER"

    case "$PKG_MANAGER" in
      apt)
        sudo apt-get update
        if [[ ${#SYSTEM_PACKAGES[@]} -gt 0 ]]; then
          sudo apt-get install -y "${SYSTEM_PACKAGES[@]}"
        fi
        ;;
      dnf)
        if [[ ${#SYSTEM_PACKAGES[@]} -gt 0 ]]; then
          sudo dnf install -y "${SYSTEM_PACKAGES[@]}"
        fi
        ;;
      pacman)
        if [[ ${#SYSTEM_PACKAGES[@]} -gt 0 ]]; then
          sudo pacman -S --noconfirm "${SYSTEM_PACKAGES[@]}"
        fi
        ;;
      *)
        echo "No supported package manager found for system package installation."
        ;;
    esac

    if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
      if python3 -m pip --version >/dev/null 2>&1; then
        python3 -m pip install --user -U "${PIP_PACKAGES[@]}" || \
          python3 -m pip install --user --break-system-packages -U "${PIP_PACKAGES[@]}"
      else
        echo "python3 -m pip is unavailable; skipped pip package installation."
      fi
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Engine installation finished"
  ) >"$log_file" 2>&1 &

  echo $!
}

wait_for_background_install() {
  local pid="$1"
  local spin='|/-\\'
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r  Installing missing engines in background... %c" "${spin:$i:1}"
    sleep 0.2
  done

  wait "$pid"
}

has_python_module() {
  python3 - <<PY >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("$1") else 1)
PY
}

detect_node_status() {
  python3 - "$DOWNLOADER_PATH" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("downloader", Path(sys.argv[1]))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
node = mod.resolve_node_runtime()
version = mod.get_node_version(node) if node else None
print(node or "")
print(".".join(map(str, version)) if version else "")
PY
}

resolve_browser_dir() {
  case "$1" in
    chrome) echo "$CHROME_NM_DIR" ;;
    chromium) echo "$CHROMIUM_NM_DIR" ;;
    brave) echo "$BRAVE_NM_DIR" ;;
    *) return 1 ;;
  esac
}

browser_installed() {
  case "$1" in
    chrome) [[ -d "$HOME/.config/google-chrome" ]] || command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1 ;;
    chromium) [[ -d "$HOME/.config/chromium" ]] || command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 ;;
    brave) [[ -d "$HOME/.config/BraveSoftware/Brave-Browser" ]] || command -v brave-browser >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

write_manifest() {
  local output_path="$1"
  python3 - "$TEMPLATE_PATH" "$output_path" "$DOWNLOADER_PATH" "$EXTENSION_ID" <<'PY'
import json
import pathlib
import sys

template_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
downloader_path = pathlib.Path(sys.argv[3]).resolve()
extension_id = sys.argv[4]

data = json.loads(template_path.read_text(encoding="utf-8"))
data["path"] = str(downloader_path)
data["allowed_origins"] = [f"chrome-extension://{extension_id}/"]
out_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

print_header

PKG_MANAGER="$(detect_package_manager)"

echo -e "${YELLOW}[1/6]${NC} Checking project files..."
[[ -d "$EXTENSION_DIR" ]] && ok "Extension folder found: $EXTENSION_DIR" || { fail "Missing extension folder: $EXTENSION_DIR"; exit 1; }
[[ -f "$DOWNLOADER_PATH" ]] && ok "Native downloader found: $DOWNLOADER_PATH" || { fail "Missing downloader: $DOWNLOADER_PATH"; exit 1; }
[[ -f "$TEMPLATE_PATH" ]] && ok "Native host template found" || { fail "Missing host template: $TEMPLATE_PATH"; exit 1; }

echo -e "\n${YELLOW}[2/6]${NC} Checking dependencies..."
if command -v python3 >/dev/null 2>&1; then
  ok "$(command_version python3 --version)"
else
  fail "Python 3 not found"
  exit 1
fi

collect_dependency_status 1

if [[ ${#MISSING_ENGINES[@]} -gt 0 ]]; then
  warn "Missing engines detected: ${MISSING_ENGINES[*]}"

  if [[ "$AUTO_INSTALL_ENGINES" -eq 1 ]]; then
    if [[ "$PKG_MANAGER" == "none" ]]; then
      warn "No supported package manager detected. Cannot auto-install system packages."
      warn "Install dependencies manually and re-run this installer."
      exit 1
    fi

    echo -e "\n${YELLOW}[3/6]${NC} Installing missing engines in background (sequential)..."
    echo "  Install log: $INSTALL_LOG_PATH"
    INSTALL_PID="$(run_engine_install_background)"
    if wait_for_background_install "$INSTALL_PID"; then
      printf "\r"
      ok "Background engine installation completed"
    else
      printf "\r"
      fail "Background engine installation failed. Check log: $INSTALL_LOG_PATH"
      exit 1
    fi

    echo -e "\n${YELLOW}[4/6]${NC} Re-checking dependencies after installation..."
    collect_dependency_status 0
    if (( REQUIRED_MISSING_COUNT > 0 )); then
      fail "Required dependencies are still missing after auto-install."
      echo "  Please review install log: $INSTALL_LOG_PATH"
      exit 1
    fi
  else
    warn "Auto engine installation is disabled by --no-install-engines"
    if (( REQUIRED_MISSING_COUNT > 0 )); then
      fail "Required dependencies are missing. Re-run with --install-engines or install manually."
      exit 1
    fi
  fi
else
  echo -e "\n${YELLOW}[3/6]${NC} Engine installation step skipped (all required engines are available)."
fi

echo -e "\n${YELLOW}[5/6]${NC} Setting up downloader..."
chmod +x "$DOWNLOADER_PATH"
ok "Made downloader executable"
mkdir -p "$DOWNLOAD_DIR"
ok "Download directory ready: $DOWNLOAD_DIR"

echo -e "\n${YELLOW}[6/6]${NC} Configuring extension ID and installing native host..."
if [[ -z "$EXTENSION_ID" ]]; then
  echo -e "  ${CYAN}Load the extension from:${NC} $EXTENSION_DIR"
  echo "    1. Open chrome://extensions/"
  echo "    2. Enable Developer mode"
  echo "    3. Click Load unpacked and select the extension folder"
  echo "    4. Copy the extension ID"
  echo
  read -r -p "  Enter your Chrome extension ID: " EXTENSION_ID
fi

if [[ -z "$EXTENSION_ID" ]]; then
  fail "Extension ID cannot be empty"
  exit 1
fi
ok "Extension ID set: $EXTENSION_ID"
declare -a BROWSERS_TO_INSTALL=()

if [[ "$TARGET_BROWSER" == "auto" || "$TARGET_BROWSER" == "all" ]]; then
  for browser in chrome chromium brave; do
    if browser_installed "$browser"; then
      BROWSERS_TO_INSTALL+=("$browser")
    fi
  done
else
  case "$TARGET_BROWSER" in
    chrome|chromium|brave)
      BROWSERS_TO_INSTALL+=("$TARGET_BROWSER")
      ;;
    *)
      fail "Unsupported browser target: $TARGET_BROWSER"
      echo "  Usage: $0 [extension-id] [chrome|chromium|brave|auto|all] [--install-engines|--no-install-engines]"
      exit 1
      ;;
  esac
fi

if [[ ${#BROWSERS_TO_INSTALL[@]} -eq 0 ]]; then
  warn "No installed Chrome-compatible browser detected. A local manifest copy will still be generated."
fi

for browser in "${BROWSERS_TO_INSTALL[@]}"; do
  host_dir="$(resolve_browser_dir "$browser")"
  mkdir -p "$host_dir"
  write_manifest "$host_dir/com.ai.downloader.json"
  ok "Installed native host for $browser → $host_dir/com.ai.downloader.json"
done

write_manifest "$LOCAL_MANIFEST_PATH"
ok "Saved local manifest copy: $LOCAL_MANIFEST_PATH"

echo
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Installation complete${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
echo
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Open chrome://extensions/"
echo "  2. Load unpacked → $EXTENSION_DIR"
echo "  3. Restart Chrome after the native host install"
echo "  4. Open a YouTube video and click the download icon"
echo
echo -e "${CYAN}Troubleshooting:${NC}"
echo "  • Worker test: python3 $DOWNLOADER_PATH --worker 'https://www.youtube.com/watch?v=HI51x7hjCu8' --output-dir /tmp"
echo "  • Download log: $HOME/Downloads/Engine Video Downloader/download.log"
echo "  • Host manifest copy: $LOCAL_MANIFEST_PATH"
