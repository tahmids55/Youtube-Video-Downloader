# Engine Video Downloader Prototype

Linux + Chrome prototype for injecting a `Download Video` button into the YouTube player and forwarding the current video URL to a native Python downloader via Chrome Native Messaging.

## Folder structure

- `extension/` — Chrome Manifest V3 extension
  - `manifest.json`
  - `content.js`
  - `background.js`
- `native_app/` — Python native messaging host
  - `downloader.py`
  - `com.ai.downloader.json.template`
- `scripts/`
  - `install_native_host.sh`

## What it does

1. Detects YouTube watch pages.
2. Injects a compact IDM-style download icon inside the player.
3. Opens a format picker with available download options.
4. Sends the current page URL and selected format to the native host.
5. Starts `yt-dlp` in a separate terminal window.
6. Downloads the selected format and merges to MP4 with `ffmpeg` when needed.

## Requirements

Install the required packages first:

- Python 3.10+
- Google Chrome on Linux
- `yt-dlp`
- `ffmpeg`
- `python3-secretstorage` on Linux if you want `yt-dlp --cookies-from-browser` to decrypt Chrome/Brave cookies reliably
- Node.js 20+ recommended for current YouTube JS challenge handling

Example install commands on Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y python3 python3-pip ffmpeg xterm python3-secretstorage
python3 -m pip install --user -U yt-dlp
```

If YouTube downloads start failing after a site change, update `yt-dlp` again before troubleshooting further.

`xterm` is optional but recommended as a terminal fallback if your desktop does not already provide `x-terminal-emulator`.

## Load the extension

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Click **Load unpacked**.
4. Select the `extension/` folder from this project.
5. Copy the extension ID shown in Chrome.

## Install the native host

From the project root, run:

```bash
chmod +x scripts/install_native_host.sh
./scripts/install_native_host.sh
```

The installer now:

- checks Python, `yt-dlp`, `ffmpeg`, `aria2c`, `secretstorage`, Node.js, and terminal support
- shows which dependencies are present or missing
- prompts for the extension ID if you do not pass one
- installs the native host for detected Chrome-compatible browsers automatically

Optional non-interactive usage:

```bash
./scripts/install_native_host.sh <YOUR_EXTENSION_ID> chrome
```

Supported browser arguments:

- `chrome`
- `chromium`
- `brave`
- `auto`
- `all`

This writes the native messaging host manifest to:

- Chrome: `~/.config/google-chrome/NativeMessagingHosts/com.ai.downloader.json`
- Chromium: `~/.config/chromium/NativeMessagingHosts/com.ai.downloader.json`
- Brave: `~/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.ai.downloader.json`

## How to use

1. Restart Chrome after installing the native host.
2. Open any YouTube watch page.
3. Wait for the red `Download Video` button to appear on the player.
4. Click it.
5. A terminal window should open and show `yt-dlp` progress.
6. When the download finishes or fails, the terminal stays open until you press Enter.
7. The same output is also written to `~/Downloads/Engine Video Downloader/download.log`.
8. Downloaded files are saved to:

```text
~/Downloads/Engine Video Downloader
```

## Notes

- The native host validates that both `yt-dlp` and `ffmpeg` exist in `PATH`.
- The downloader automatically tries to pass Chrome/Brave/Chromium cookies to `yt-dlp` using `--cookies-from-browser` to reduce YouTube bot-check failures.
- The downloader also tries to locate `node` and passes it to `yt-dlp` as a JavaScript runtime.
- The downloader enables `yt-dlp` remote EJS components to improve YouTube challenge solving and format availability.
- If no supported terminal emulator is available, the downloader falls back to a background process and writes progress to:

```text
~/Downloads/Engine Video Downloader/download.log
```

- The extension currently targets YouTube watch pages only.
- The button is re-injected on YouTube SPA navigation.

### Optional environment overrides

If auto-detection picks the wrong browser or JS runtime, launch Chrome from a shell with either of these set:

```bash
export AI_VIDEO_BROWSER=chrome
export AI_VIDEO_JS_RUNTIME=/absolute/path/to/node
google-chrome
```

## Manual native host manifest example

If you do not want to use the install script, create:

```text
~/.config/google-chrome/NativeMessagingHosts/com.ai.downloader.json
```

With content like:

```json
{
  "name": "com.ai.downloader",
  "description": "Native host for the Engine Video Downloader prototype",
  "path": "/absolute/path/to/native_app/downloader.py",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://YOUR_EXTENSION_ID/"
  ]
}
```

Make sure the Python file is executable:

```bash
chmod +x native_app/downloader.py
```
