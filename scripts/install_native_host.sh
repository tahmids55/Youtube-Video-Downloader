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
DOWNLOAD_DIR="$HOME/Downloads/AI Video Downloader"

CHROME_NM_DIR="$HOME/.config/google-chrome/NativeMessagingHosts"
CHROMIUM_NM_DIR="$HOME/.config/chromium/NativeMessagingHosts"
BRAVE_NM_DIR="$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"

EXTENSION_ID="${1:-}"
TARGET_BROWSER="${2:-auto}"

print_header() {
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     AI Video Downloader — Installer          ║"
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

echo -e "${YELLOW}[1/5]${NC} Checking project files..."
[[ -d "$EXTENSION_DIR" ]] && ok "Extension folder found: $EXTENSION_DIR" || { fail "Missing extension folder: $EXTENSION_DIR"; exit 1; }
[[ -f "$DOWNLOADER_PATH" ]] && ok "Native downloader found: $DOWNLOADER_PATH" || { fail "Missing downloader: $DOWNLOADER_PATH"; exit 1; }
[[ -f "$TEMPLATE_PATH" ]] && ok "Native host template found" || { fail "Missing host template: $TEMPLATE_PATH"; exit 1; }

echo -e "\n${YELLOW}[2/5]${NC} Checking dependencies..."
if command -v python3 >/dev/null 2>&1; then
  ok "$(command_version python3 --version)"
else
  fail "Python 3 not found"
  exit 1
fi

if command -v yt-dlp >/dev/null 2>&1; then
  ok "yt-dlp $(command_version yt-dlp --version)"
else
  fail "yt-dlp not found in PATH"
fi

if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg found"
else
  fail "ffmpeg not found"
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
  ok "Node runtime selected: $NODE_PATH (v$NODE_VERSION)"
else
  warn "Node.js 20+ not detected; YouTube format extraction may fail"
fi

if command -v x-terminal-emulator >/dev/null 2>&1 || command -v gnome-terminal >/dev/null 2>&1 || command -v konsole >/dev/null 2>&1 || command -v xfce4-terminal >/dev/null 2>&1 || command -v xterm >/dev/null 2>&1; then
  ok "Terminal emulator found"
else
  warn "No supported terminal emulator found; downloader will fall back to log file mode"
fi

echo -e "\n${YELLOW}[3/5]${NC} Setting up downloader..."
chmod +x "$DOWNLOADER_PATH"
ok "Made downloader executable"
mkdir -p "$DOWNLOAD_DIR"
ok "Download directory ready: $DOWNLOAD_DIR"

echo -e "\n${YELLOW}[4/5]${NC} Configuring extension ID..."
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

echo -e "\n${YELLOW}[5/5]${NC} Installing native messaging host..."
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
      echo "  Usage: $0 [extension-id] [chrome|chromium|brave|auto|all]"
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
echo "  • Download log: $HOME/Downloads/AI Video Downloader/download.log"
echo "  • Host manifest copy: $LOCAL_MANIFEST_PATH"
