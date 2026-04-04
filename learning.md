# Learning Notes


## Date

2026-04-04

## Problem Summary

Downloads from YouTube were failing after format selection, even though metadata extraction looked normal.

Observed behavior:

- Cookies were extracted successfully from Chrome.
- Video info and player JSON endpoints were fetched successfully.
- yt-dlp selected a valid format (example: format `95`).
- Media download phase failed with repeated `HTTP Error 403: Forbidden`.
- After retries, fragments were skipped and output ended with `ERROR: The downloaded file is empty`.

## What I Initially Suspected

Possible causes considered during investigation:

- Broken cookie extraction/decryption on Linux.
- Expired or restricted HLS fragment URLs.
- Format-specific issue with HLS format `95`.
- YouTube client/token mismatch behavior that allows metadata but blocks media URLs.

## Investigation Process

1. Reviewed the native host downloader logic in `native_app/downloader.py`.
2. Confirmed the worker executes yt-dlp directly and did not have a fallback strategy.
3. Checked the download log at `~/Downloads/Engine Video Downloader/download.log`.
4. Verified this pattern repeated in multiple sessions:
   - extraction succeeds,
   - download starts,
   - fragments fail with 403,
   - empty output file.
5. Listed formats for the same video with the same flags to compare stream types.
6. Probed direct download with non-HLS format `18` using cookies.
   - Result: still 403.
7. Probed download without cookies using Android client mode:
   - `--extractor-args "youtube:player_client=android"`
   - Result: download succeeded.

## Root Cause

This was not a simple cookie extraction failure.

The key issue was request context mismatch for media URLs:

- Metadata endpoints remained accessible.
- Actual media URLs were denied (403) under the original cookie/client path.
- The downloader had no automatic retry strategy to switch request mode.

In short: extraction could succeed while media fetch still fails.

## Implemented Fix

A YouTube-specific fallback path was added in `native_app/downloader.py`.

### Primary attempt (unchanged)

- Keep current behavior first:
  - use cookies (if available),
  - use configured JS runtime,
  - honor user-selected format.

### Automatic fallback after failure

If primary attempt fails and URL is YouTube:

- Retry without browser cookies.
- Use Android client extractor args:
  - `youtube:player_client=android`
- Adjust fallback format selector when needed:
  - numeric selectors such as `95` switch to `bv*+ba/b`.
  - audio-only selectors prefer `bestaudio/best`.

### Why this works

Switching client mode and removing cookie context can avoid the blocked media URL path that produces 403 in web/tv cookie flows.

## Validation Results

Tested on the same failing URL from the report.

- Primary run still failed with repeated 403 (expected, confirms reproduction).
- Fallback auto-triggered.
- Retry completed successfully and produced a valid output file.

## Files Changed

- `native_app/downloader.py`
- `learning.md`

## Practical Takeaways

1. Successful extraction does not guarantee downloadable media URLs.
2. Repeated fragment 403 plus empty output usually indicates request context mismatch, not only bad network.
3. A robust downloader should include at least one alternate YouTube retrieval strategy.
4. Keep a fallback that avoids reusing a failing numeric format ID.

## Future Improvements

- Detect 403 signatures from stderr and show a clearer user-facing error reason.
- Offer optional user toggles in the extension UI:
  - normal mode (cookies),
  - compatibility mode (no cookies, android client).
- Add regression test scripts for known problematic videos and formats.
