const NATIVE_HOST_NAME = "com.ai.downloader";

function sendToNative(payload, sendResponse) {
  chrome.runtime.sendNativeMessage(NATIVE_HOST_NAME, payload, (response) => {
    if (chrome.runtime.lastError) {
      sendResponse({
        ok: false,
        error: chrome.runtime.lastError.message
      });
      return;
    }

    sendResponse(response || { ok: true });
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message?.videoUrl) {
    return false;
  }

  if (message.type === "download") {
    sendToNative(
      {
        action: "download",
        url: message.videoUrl,
        formatSelector: message.formatSelector || "",
        formatLabel: message.formatLabel || "",
        pageTitle: message.pageTitle || "",
        source: sender?.tab?.url || message.videoUrl,
        requestedAt: new Date().toISOString()
      },
      sendResponse
    );

    return true;
  }

  if (message.type === "listFormats") {
    sendToNative(
      {
        action: "list_formats",
        url: message.videoUrl,
        pageTitle: message.pageTitle || "",
        source: sender?.tab?.url || message.videoUrl,
        requestedAt: new Date().toISOString()
      },
      sendResponse
    );

    return true;
  }

  if (message.type === "ping") {
    sendToNative(
      {
        action: "ping",
        url: message.videoUrl,
        requestedAt: new Date().toISOString()
      },
      sendResponse
    );

    return true;
  }

  return false;
});
