browser.runtime.onMessage.addListener(async (request) => {
  const video = document.querySelector('video');

  // NOTE: Before any of the other logic since it returns
  // a different object "type" from the script
  if (request.command === "playback_state") {
    return {
      is_playing: video !== null && !video.paused,
    };
  }


  if (video === null) {
    return {
      status: "failed",
      error_code: "playback_failed",
    };
  }

  switch (request.command) {
    case "pause":
      video.pause();
      return {
        status: "ok",
        error_code: null,
      };
    case "resume":
      try {
        await video.play();
        return {
          status: "ok",
          error_code: null,
        };
      } catch (error) {
        console.error("MusicHook could not resume playback:", error);
        return {
          status: "failed",
          error_code: "playback_failed",
        };
      }
    default:
      return {
        status: "failed",
        error_code: "playback_failed",
      };
  }
});
