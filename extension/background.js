const native_host_name = "music_hook_host";

let last_controlled_tab_id = null;
browser.tabs.onRemoved.addListener((tab_id) => {
  if (tab_id === last_controlled_tab_id) {
    last_controlled_tab_id = null;
  }
});

const youtube_tab_urls = [
  "https://www.youtube.com/*",
  "https://youtube.com/*"
];

const youtube_music_tab_urls = [
  "https://music.youtube.com/*",
];

const eligible_tab_urls = [
  ...youtube_tab_urls,
  ...youtube_music_tab_urls,
];

async function find_eligible_tab() {
  const tabs = await browser.tabs.query({
    url: eligible_tab_urls,
  });

  // NOTE: Takes advantage of the Zen's pinned tabs.
  return tabs.find((tab) => tab.pinned) ?? tabs[0];
}

async function find_preferred_tab(url_patterns) {
  const tabs = await browser.tabs.query({
    url: url_patterns,
  });

  return tabs.find((tab) => tab.pinned) ?? tabs[0];
}

async function play_in_eligible_tab(url) {
  const hostname = new URL(url).hostname;

  let target_tab_urls;
  switch (hostname) {
    case "music.youtube.com":
      target_tab_urls = youtube_music_tab_urls;
      break;

    case "youtube.com":
    case "www.youtube.com":
      target_tab_urls = youtube_tab_urls;
      break;

    default:
      return {
        status: "failed",
        error_code: "playback_failed",
      };
  };

  const target_tab = await find_preferred_tab(target_tab_urls);

  if (target_tab === undefined) {
    return {
      status: "failed",
      error_code: "zen_unavailable",
    };
  }

  await browser.tabs.update(target_tab.id, { url });
  last_controlled_tab_id = target_tab.id;

  return {
    status: "ok",
    error_code: null,
  };
}

function order_tabs_by_preference(tabs) {
  const pinned_tabs = tabs.filter((tab) => tab.pinned);
  const unpinned_tabs = tabs.filter((tab) => !tab.pinned);

  return [...pinned_tabs, ...unpinned_tabs];
}

async function find_playing_tab() {
  const tabs = await browser.tabs.query({
    url: eligible_tab_urls,
  });

  for (const tab of order_tabs_by_preference(tabs)) {
    const playback_state = await browser.tabs.sendMessage(
      tab.id,
      { command: "playback_state" },
    );

    if (playback_state.is_playing) {
      return tab;
    }
  }

  return undefined;
}

async function handle_native_request(port, request) {
  console.info(
    "MusicHook received a native request:",
    request.command,
  );

  try {
    let response;

    switch (request.command) {
      case "play":
        if (typeof request.url !== "string") {
          throw new Error("A play request needs a URL.");
        }

        response = await play_in_eligible_tab(request.url);
        break;
      case "pause":
        response = await pause_playing_tab();
        break;
      case "resume":
        response = await resume_last_controlled_tab();
        break;
      default:
        throw new Error("Unknown MusicHook command.");
    }
    port.postMessage(response);
  } catch (error) {
    console.error("MusicHook could not navigate to an eligible tab:", error);

    port.postMessage({
      status: "failed",
      error_code: "playback_failed",
    });
  }
}

async function pause_playing_tab() {
  const target_tab = await find_playing_tab();

  if (target_tab === undefined) {
    return {
      status: "ok",
      error_code: null,
    };
  }

  const response = await browser.tabs.sendMessage(
    target_tab.id,
    { command: "pause" },
  );

  if (response.status === "ok") {
    last_controlled_tab_id = target_tab.id;
  }

  return response;
}

async function resume_last_controlled_tab() {
  if (last_controlled_tab_id === null) {
    return {
      status: "failed",
      error_code: "playback_failed",
    };
  }

  return browser.tabs.sendMessage(
    last_controlled_tab_id,
    { command: "resume" },
  );
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
