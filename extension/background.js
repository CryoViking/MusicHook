const native_host_name = "music_hook_host";

const eligible_tab_urls = [
  "https://music.youtube.com/*",
  "https://www.youtube.com/*"
];

async function play_in_eligible_tab(url) {
  const tabs = await browser.tabs.query({
    url: eligible_tab_urls,
  });

  // NOTE: Takes advantage of the Zen's pinned tabs.
  const target_tab = tabs.find((tab) => tab.pinned) ?? tabs[0];

  if (target_tab === undefined) {
    return {
      status: "failed",
      error_code: "zen_unavailable",
    };
  }

  await browser.tabs.update(target_tab.id, { url });

  return {
    status: "ok",
    error_code: null,
  };
}

async function handle_native_request(port, request) {
  console.info(
    "MusicHook received a native request:",
    request.command,
  );

  if (request.command !== "play" || typeof request.url !== "string") {
    port.postMessage({
      status: "failed",
      error_code: "playback_failed",
    });
    return;
  }

  try {
    const response = await play_in_eligible_tab(request.url);
    port.postMessage(response);
  } catch (error) {
    console.error("MusicHook could not navigate to an eligible tab:", error);

    port.postMessage({
      status: "failed",
      error_code: "playback_failed",
    });
  }
}

function connection_to_native_host() {
  const port = browser.runtime.connectNative(native_host_name);

  port.onMessage.addListener((request) => {
    handle_native_request(port, request);
  });

  port.onDisconnect.addListener(() => {
    const reason = browser.runtime.lastError?.message ??
      "Native host disconnected.";

    console.error("MusicHook native host disconnected:", reason);
  });

  return port;
}

const nativePort = connection_to_native_host();
