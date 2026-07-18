# MusicHook Firefox/Zen WebExtension Reference

This page records the Mozilla WebExtension rules that constrain MusicHook's
browser bridge. It is a reference for the extension boundary, not a user guide
or a future-feature roadmap.

## Identity and native-host name

```text
Add-on ID: @music-hook.automatacrypt
Native-host name: music_hook_host
```

The native-host name is passed to:

```js
browser.runtime.connectNative("music_hook_host")
```

It must exactly match the native-host manifest's `name` property. Native-host
permission is granted to the extension ID, not to a local directory.

## Manifest restrictions

MusicHook uses Manifest V3. Firefox currently uses
`background.scripts` for background extension code; it does not support
`background.service_worker`.

The extension requests:

- `nativeMessaging`, which permits `browser.runtime.connectNative()`;
- host permissions only for `https://music.youtube.com/*` and
  `https://www.youtube.com/*`.

The host permissions let the extension query tabs by URL and access those
sites. They avoid the broad `tabs` permission, which would expose URL and
title metadata for every tab.

Native messaging is available from background extension code, not content
scripts. If MusicHook later needs page-level DOM control, a content script must
communicate with the background script using ordinary extension messages.

## Native-host manifest restrictions

Firefox launches `music-hook-host` from a separate, machine-local manifest.
The macOS per-user location used by MusicHook is:

```text
~/Library/Application Support/Mozilla/NativeMessagingHosts/music_hook_host.json
```

Its relevant form is:

```json
{
  "name": "music_hook_host",
  "description": "MusicHook native messaging host",
  "path": "/absolute/path/to/music-hook-host",
  "type": "stdio",
  "allowed_extensions": ["@music-hook.automatacrypt"]
}
```

`path` must be an absolute path. Do not commit the generated manifest: its
path is machine-specific. MusicHook commits a template and renders the local
manifest through `scripts/install-native-host.sh` instead.

`allowed_extensions` is the security boundary that prevents other extensions
from connecting to MusicHook's native host.

## Native-message framing

The extension exchanges plain JavaScript objects through a `runtime.Port`:

```js
port.postMessage(message)
port.onMessage.addListener(listener)
```

Firefox owns the native-messaging length framing at this boundary. The
extension must not add or parse a four-byte message length. The Zig host owns
that framing on its stdin/stdout side through `bridge_module/frame.zig`.

## Current `play` behaviour

The background script receives a validated shared request, such as:

```json
{
  "command": "play",
  "url": "https://music.youtube.com/watch?v=example"
}
```

It then:

1. Finds open tabs whose URLs are YouTube or YouTube Music.
2. Chooses the first pinned eligible tab; otherwise it uses the first eligible
   tab returned by `tabs.query()`.
3. Navigates that tab to the requested URL without activating or focusing it.
4. Returns `ok` when Zen accepts the navigation request.

Navigation acceptance is not a browser guarantee that audible media has
started. MusicHook currently relies on Zen's autoplay permission for YouTube
and YouTube Music. If audible autoplay is blocked, Zen must be configured to
allow it for those sites. A future page-level playback confirmation would need
a content script and must treat `HTMLMediaElement.play()` rejection as a real
failure.

There is intentionally no queueing, retrying, cancellation, tab creation, or
content-script playback control in this first slice.

## Mozilla references

- [Native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)
- [Native manifests](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests)
- [Background manifest key](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background)
- [Manifest permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions)
- [`tabs.query()`](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/query)
- [`tabs.update()`](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/update)
- [`HTMLMediaElement.play()`](https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/play)
- [Firefox autoplay settings](https://support.mozilla.org/en-US/kb/block-autoplay)
