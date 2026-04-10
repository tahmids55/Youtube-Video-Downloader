#!/usr/bin/env python3
import importlib.util
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
from pathlib import Path

HOST_NAME = "com.ai.downloader"
DEFAULT_OUTPUT_DIR = Path.home() / "Downloads" / "Engine Video Downloader"
TERMINAL_CANDIDATES = [
    "x-terminal-emulator",
    "gnome-terminal",
    "konsole",
    "xfce4-terminal",
    "xterm",
]
BROWSER_CANDIDATES = [
    ("chrome", ["google-chrome", "google-chrome-stable"]),
    ("brave", ["brave-browser"]),
    ("chromium", ["chromium", "chromium-browser"]),
]


def log(message: str) -> None:
    print(f"[{HOST_NAME}] {message}", file=sys.stderr, flush=True)



def read_message():
    raw_length = sys.stdin.buffer.read(4)
    if not raw_length:
        return None

    if len(raw_length) != 4:
        raise RuntimeError("Failed to read native message length header")

    message_length = struct.unpack("<I", raw_length)[0]
    message = sys.stdin.buffer.read(message_length).decode("utf-8")
    return json.loads(message)



def send_message(payload):
    encoded = json.dumps(payload).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(encoded)))
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()



def ensure_output_dir() -> Path:
    DEFAULT_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    return DEFAULT_OUTPUT_DIR



def get_node_version(node_path: str) -> tuple[int, int, int] | None:
    try:
        result = subprocess.run(
            [node_path, "--version"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except Exception:
        return None

    version_text = (result.stdout or result.stderr or "").strip()
    match = re.search(r"v?(\d+)\.(\d+)\.(\d+)", version_text)
    if not match:
        return None

    return tuple(int(part) for part in match.groups())



def resolve_node_runtime() -> str | None:
    env_path = os.environ.get("AI_VIDEO_JS_RUNTIME", "").strip()
    if env_path and Path(env_path).is_file():
        return env_path

    candidates: list[str] = []

    direct = shutil.which("node")
    if direct:
        candidates.append(direct)

    nvm_root = Path.home() / ".nvm" / "versions" / "node"
    if nvm_root.exists():
        versions = sorted(nvm_root.glob("*/bin/node"))
        candidates.extend(str(path) for path in versions)

    fallback_paths = [
        Path.home() / ".local" / "bin" / "node",
        Path("/usr/local/bin/node"),
        Path("/usr/bin/node"),
    ]
    for candidate in fallback_paths:
        if candidate.is_file():
            candidates.append(str(candidate))

    best_path = None
    best_version = None
    seen = set()

    for candidate in candidates:
        resolved = str(Path(candidate).resolve())
        if resolved in seen:
            continue
        seen.add(resolved)

        version = get_node_version(resolved)
        if version is None:
            continue

        if version[0] < 20:
            if best_path is None:
                best_path = resolved
                best_version = version
            continue

        if best_version is None or version > best_version or (best_version[0] < 20):
            best_path = resolved
            best_version = version

    if best_path:
        return best_path

    return None



def resolve_cookie_browser() -> str | None:
    preferred = os.environ.get("AI_VIDEO_BROWSER", "").strip().lower()
    if preferred:
        return preferred

    for browser_name, executables in BROWSER_CANDIDATES:
        for executable in executables:
            if shutil.which(executable):
                return browser_name

    return None



def has_secretstorage() -> bool:
    return importlib.util.find_spec("secretstorage") is not None



def get_yt_dlp_environment() -> tuple[dict[str, str], str | None, str | None, str]:
    environment = os.environ.copy()
    yt_dlp_path = shutil.which("yt-dlp") or "yt-dlp"
    node_runtime = resolve_node_runtime()
    cookie_browser = resolve_cookie_browser()

    if node_runtime:
        node_dir = str(Path(node_runtime).resolve().parent)
        environment["PATH"] = f"{node_dir}:{environment.get('PATH', '')}"

    return environment, yt_dlp_path, node_runtime, cookie_browser



def build_yt_dlp_base_command(
    url: str,
    node_runtime: str | None,
    cookie_browser: str | None,
    yt_dlp_path: str,
    *,
    include_cookies: bool = True,
    extractor_args: str | None = None,
) -> list[str]:
    command = [
        yt_dlp_path,
        "--newline",
        "--progress",
        "--remote-components",
        "ejs:github",
    ]

    if node_runtime:
        command.extend(["--js-runtimes", f"node:{node_runtime}"])

    if include_cookies and cookie_browser:
        command.extend(["--cookies-from-browser", cookie_browser])

    if extractor_args:
        command.extend(["--extractor-args", extractor_args])

    command.append(url)
    return command


def is_youtube_url(url: str) -> bool:
    lowered = url.lower()
    return "youtube.com" in lowered or "youtu.be" in lowered


def extract_height_from_label(format_label: str) -> int | None:
    label = format_label.strip().lower()
    if not label:
        return None

    res_match = re.search(r"(\d{3,4})x(\d{3,4})", label)
    if res_match:
        return int(res_match.group(2))

    p_match = re.search(r"(\d{3,4})p", label)
    if p_match:
        return int(p_match.group(1))

    return None


def resolve_youtube_fallback_selector(format_selector: str, format_label: str = "") -> str:
    selector = format_selector.strip()
    if not selector:
        return "bv*+ba/b"

    lowered = selector.lower()
    lowered_label = format_label.strip().lower()
    if "audio only" in lowered_label or ("audio" in lowered and "video" not in lowered):
        return "bestaudio/best"

    target_height = extract_height_from_label(format_label)
    if target_height:
        return f"bv*[height<={target_height}]+ba/b"

    if "+" in selector and "/best" in selector:
        return "bv*+ba/b"

    if re.fullmatch(r"\d+(\+\d+)?", selector):
        return "bv*+ba/b"

    return selector



def build_download_command(url: str, format_selector: str = "", format_label: str = "") -> list[str]:
    output_dir = ensure_output_dir()
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--worker",
        url,
        "--output-dir",
        str(output_dir),
    ]

    if format_selector:
        command.extend(["--format-selector", format_selector])

    if format_label:
        command.extend(["--format-label", format_label])

    return command



def build_terminal_shell_command(command: list[str], log_file: Path) -> str:
    joined_command = shlex.join(command)
    quoted_log = shlex.quote(str(log_file))
    return (
        "set -o pipefail; "
        f"mkdir -p {shlex.quote(str(log_file.parent))}; "
        f"echo \"\\n=== $(date '+%Y-%m-%d %H:%M:%S') ===\" | tee -a {quoted_log}; "
        f"echo \"Logging to: {log_file}\" | tee -a {quoted_log}; "
        f"{joined_command} 2>&1 | tee -a {quoted_log}; "
        "status=${PIPESTATUS[0]}; "
        "echo; "
        "if [ $status -eq 0 ]; then "
        "  echo 'Download complete.'; "
        "else "
        "  echo \"Download failed with exit code $status.\"; "
        "fi; "
        "read -r -p 'Press Enter to close...' _; "
        "exit $status"
    )



def launch_terminal(command: list[str]) -> tuple[bool, str]:
    output_dir = ensure_output_dir()
    log_file = output_dir / "download.log"
    shell_command = build_terminal_shell_command(command, log_file)

    for terminal in TERMINAL_CANDIDATES:
        terminal_path = shutil.which(terminal)
        if not terminal_path:
            continue

        try:
            if terminal == "gnome-terminal":
                subprocess.Popen([
                    terminal_path,
                    "--",
                    "bash",
                    "-lc",
                    shell_command,
                ])
            elif terminal == "konsole":
                subprocess.Popen([
                    terminal_path,
                    "--hold",
                    "-e",
                    "bash",
                    "-lc",
                    shell_command,
                ])
            elif terminal == "xfce4-terminal":
                subprocess.Popen([
                    terminal_path,
                    "--hold",
                    "-e",
                    f"bash -lc {shlex.quote(shell_command)}",
                ])
            elif terminal == "xterm":
                subprocess.Popen([
                    terminal_path,
                    "-hold",
                    "-e",
                    "bash",
                    "-lc",
                    shell_command,
                ])
            else:
                subprocess.Popen([
                    terminal_path,
                    "-e",
                    "bash",
                    "-lc",
                    shell_command,
                ])

            return True, f"Download launched in {terminal}. Progress is also saved to {log_file}."
        except Exception as exc:
            log(f"Failed to launch {terminal}: {exc}")

    return False, "No supported terminal emulator found. Falling back to background download log."



def launch_background(command: list[str]) -> tuple[bool, str]:
    output_dir = ensure_output_dir()
    log_file = output_dir / "download.log"

    with open(log_file, "a", encoding="utf-8") as stream:
        stream.write("\n=== New download session ===\n")
        stream.flush()
        subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)

    return True, f"Download started. Progress is being written to {log_file}."



def format_resolution(format_info: dict) -> str:
    if format_info.get("resolution"):
        return str(format_info["resolution"])
    if format_info.get("height"):
        return f"{format_info['height']}p"
    if format_info.get("format_note"):
        return str(format_info["format_note"])
    return "Unknown"



def format_size(format_info: dict) -> str:
    size = format_info.get("filesize") or format_info.get("filesize_approx")
    if not size:
        return ""

    units = ["B", "KB", "MB", "GB"]
    value = float(size)
    index = 0
    while value >= 1024 and index < len(units) - 1:
        value /= 1024
        index += 1
    return f"{value:.1f} {units[index]}"



def build_format_list(url: str) -> dict:
    environment, yt_dlp_path, node_runtime, cookie_browser = get_yt_dlp_environment()
    command = build_yt_dlp_base_command(url, node_runtime, cookie_browser, yt_dlp_path)
    command[-1:-1] = ["--dump-single-json", "--no-download"]

    result = subprocess.run(command, capture_output=True, text=True, env=environment, check=False)
    if result.returncode != 0:
        error = (result.stderr or result.stdout or "Could not list formats.").strip().splitlines()[-1]
        return {"ok": False, "error": error}

    data = json.loads(result.stdout)
    formats = []
    seen = set()

    best_selector = "bv*+ba/b"
    formats.append({
        "label": "Best quality",
        "meta": "Best video + audio",
        "selector": best_selector,
        "recommended": True,
    })
    seen.add(best_selector)

    best_audio_selector = "bestaudio/best"
    formats.append({
        "label": "Audio only • BEST",
        "meta": "Best available audio track",
        "selector": best_audio_selector,
        "recommended": False,
    })
    seen.add(best_audio_selector)

    candidates = [
        item for item in data.get("formats", [])
        if item.get("vcodec") not in (None, "none")
        and item.get("ext") != "mhtml"
        and not str(item.get("format_id", "")).startswith("sb")
    ]

    candidates.sort(
        key=lambda item: (
            int(item.get("height") or 0),
            float(item.get("fps") or 0),
            float(item.get("tbr") or 0),
        ),
        reverse=True,
    )

    for item in candidates:
        format_id = str(item.get("format_id", "")).strip()
        if not format_id:
            continue

        has_audio = item.get("acodec") not in (None, "none")
        selector = format_id if has_audio else f"{format_id}+bestaudio/best"
        if selector in seen:
            continue

        resolution = format_resolution(item)
        extension = item.get("ext", "video")
        fps = f"{int(item['fps'])}fps" if item.get("fps") else ""
        size = format_size(item)
        audio_note = "Muxes best audio" if not has_audio else "Video + audio"
        meta_parts = [part for part in [extension, fps, size, audio_note] if part]

        formats.append({
            "label": f"{resolution} • {extension.upper()}",
            "meta": " • ".join(meta_parts),
            "selector": selector,
            "recommended": False,
        })
        seen.add(selector)

        if len(formats) >= 12:
            break

    audio_candidates = [
        item for item in data.get("formats", [])
        if item.get("acodec") not in (None, "none")
        and item.get("vcodec") in (None, "none")
        and item.get("ext") != "mhtml"
        and not str(item.get("format_id", "")).startswith("sb")
    ]

    audio_candidates.sort(
        key=lambda item: (
            float(item.get("abr") or 0),
            float(item.get("asr") or 0),
            float(item.get("tbr") or 0),
        ),
        reverse=True,
    )

    for item in audio_candidates:
        format_id = str(item.get("format_id", "")).strip()
        if not format_id or format_id in seen:
            continue

        extension = item.get("ext", "audio")
        abr = f"{int(item['abr'])}kbps" if item.get("abr") else ""
        asr = f"{int(item['asr'] / 1000)}kHz" if item.get("asr") else ""
        size = format_size(item)
        language = item.get("language") if item.get("language") not in (None, "und") else ""
        meta_parts = [part for part in [extension, abr, asr, size, language, "Audio only"] if part]

        formats.append({
            "label": f"Audio only • {extension.upper()}",
            "meta": " • ".join(meta_parts),
            "selector": format_id,
            "recommended": False,
        })
        seen.add(format_id)

        if len(formats) >= 16:
            break

    return {"ok": True, "formats": formats}



def handle_download_request(message: dict) -> dict:
    url = message.get("url", "").strip()
    if not url:
        return {"ok": False, "error": "Missing URL."}

    if shutil.which("yt-dlp") is None:
        return {"ok": False, "error": "yt-dlp is not installed or not in PATH."}

    if shutil.which("ffmpeg") is None:
        return {"ok": False, "error": "ffmpeg is not installed or not in PATH."}

    format_selector = message.get("formatSelector", "").strip()
    format_label = message.get("formatLabel", "").strip()
    command = build_download_command(url, format_selector, format_label)
    started, detail = launch_terminal(command)
    if started:
        message_text = detail if not format_label else f"{detail} Selected format: {format_label}."
        return {"ok": True, "message": message_text}

    log(detail)
    return {"ok": True, "message": launch_background(command)[1]}



def run_worker(url: str, output_dir: str, format_selector: str = "", format_label: str = "") -> int:
    output_path = Path(output_dir).expanduser().resolve()
    output_path.mkdir(parents=True, exist_ok=True)
    template = str(output_path / "%(title)s [%(id)s].%(ext)s")
    environment, yt_dlp_path, node_runtime, cookie_browser = get_yt_dlp_environment()

    print(f"Starting download for: {url}", flush=True)
    print(f"Output directory: {output_path}", flush=True)
    if cookie_browser:
        print(f"Using browser cookies from: {cookie_browser}", flush=True)
    else:
        print("Browser cookies: not configured", flush=True)
    if node_runtime:
        print(f"Using JS runtime: {node_runtime}", flush=True)
    else:
        print("JS runtime: not found; some YouTube formats may be unavailable", flush=True)
    if format_selector:
        print(f"Selected format: {format_selector}", flush=True)
    if format_label:
        print(f"Selected label: {format_label}", flush=True)

    if cookie_browser and sys.platform.startswith("linux") and not has_secretstorage():
        print(
            "Missing Python package 'secretstorage'. Chrome cookies may not decrypt correctly on Linux.",
            flush=True,
        )
        print(
            "Install one of: sudo apt install python3-secretstorage  OR  python3 -m pip install --user --break-system-packages secretstorage",
            flush=True,
        )

    print("Press Ctrl+C in this terminal to stop the current download.\n", flush=True)

    command = build_yt_dlp_base_command(url, node_runtime, cookie_browser, yt_dlp_path)
    command[-1:-1] = [
        "-f",
        format_selector or "bv*+ba/b",
        "--merge-output-format",
        "mp4",
        "-o",
        template,
    ]

    process = subprocess.Popen(command, env=environment)
    exit_code = process.wait()
    if exit_code == 0:
        return 0

    should_retry_without_cookies = (
        cookie_browser
        and is_youtube_url(url)
        and exit_code not in (130, 143)
    )
    if not should_retry_without_cookies:
        return exit_code

    fallback_selector = resolve_youtube_fallback_selector(format_selector, format_label)
    print(
        "Primary attempt failed. Retrying YouTube download without browser cookies...",
        flush=True,
    )
    print(
        f"Fallback format selector: {fallback_selector}",
        flush=True,
    )

    fallback_command = build_yt_dlp_base_command(
        url,
        node_runtime,
        cookie_browser,
        yt_dlp_path,
        include_cookies=False,
    )
    fallback_command[-1:-1] = [
        "-f",
        fallback_selector,
        "--merge-output-format",
        "mp4",
        "-o",
        template,
    ]

    fallback_process = subprocess.Popen(fallback_command, env=environment)
    fallback_exit_code = fallback_process.wait()
    if fallback_exit_code == 0:
        return 0

    print(
        "No-cookie fallback failed. Retrying with android compatibility client...",
        flush=True,
    )
    compatibility_command = build_yt_dlp_base_command(
        url,
        node_runtime,
        cookie_browser,
        yt_dlp_path,
        include_cookies=False,
        extractor_args="youtube:player_client=android",
    )
    compatibility_command[-1:-1] = [
        "-f",
        fallback_selector,
        "--merge-output-format",
        "mp4",
        "-o",
        template,
    ]

    compatibility_process = subprocess.Popen(compatibility_command, env=environment)
    return compatibility_process.wait()



def parse_args(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--worker":
        if len(argv) < 3:
            print("Missing URL for worker mode.", file=sys.stderr)
            return 2

        url = argv[2]
        output_dir = str(DEFAULT_OUTPUT_DIR)
        format_selector = ""
        format_label = ""
        index = 3
        while index < len(argv):
            if argv[index] == "--output-dir" and index + 1 < len(argv):
                output_dir = argv[index + 1]
                index += 2
                continue
            if argv[index] == "--format-selector" and index + 1 < len(argv):
                format_selector = argv[index + 1]
                index += 2
                continue
            if argv[index] == "--format-label" and index + 1 < len(argv):
                format_label = argv[index + 1]
                index += 2
                continue
            index += 1

        return run_worker(url, output_dir, format_selector, format_label)

    return run_host_loop()



def run_host_loop() -> int:
    log("Native host started.")

    while True:
        try:
            message = read_message()
            if message is None:
                log("Input stream closed. Exiting.")
                return 0

            action = message.get("action")
            if action == "download":
                response = handle_download_request(message)
            elif action == "list_formats":
                response = build_format_list(message.get("url", "").strip())
            elif action == "ping":
                response = {"ok": True, "message": "Native host reachable."}
            else:
                response = {"ok": False, "error": f"Unsupported action: {action}"}

            send_message(response)
        except Exception as exc:
            log(f"Unhandled error: {exc}")
            try:
                send_message({"ok": False, "error": str(exc)})
            except Exception:
                return 1


if __name__ == "__main__":
    sys.exit(parse_args(sys.argv))
