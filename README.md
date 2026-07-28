# MusicHook

MusicHook is a local-first command-line companion for controlling YouTube and
YouTube Music playback in [Zen Browser](https://zen-browser.app/).

It is for the moment when you know what you want to hear, but do not want to
go hunting through tabs, search history, or a giant library UI. Save a small
collection of known favourites under memorable aliases, then play, pause, and
resume them from the terminal.

```fish
music play dusk
music pause
music resume
```

MusicHook is intentionally narrow. It is not a YouTube client, library mirror,
playlist synchroniser, recommendation engine, or background queue. It is a
small bridge between your terminal and an existing Zen tab.

## What it does

- Plays a direct YouTube or YouTube Music URL in an eligible Zen tab.
- Stores watch URLs and playlists under local aliases.
- Fetches a target's Open Graph title when adding it, so you do not have to
  enter metadata by hand.
- Lists saved tracks and playlists in compact, terminal-width-aware tables.
- Pauses the currently playing eligible tab and resumes the most recently
  MusicHook-controlled tab.
- Provides `music doctor` for configuration, data-library, and native-bridge
  diagnostics.

## How it works

```text
music CLI
    │ Unix-domain socket
    ▼
music-hook-host
    │ Firefox native messaging
    ▼
MusicHook Zen extension
    │ WebExtension tab and content-script APIs
    ▼
YouTube / YouTube Music tab
```

The CLI and native host are Zig binaries. The Zen extension is a separately
Mozilla-signed WebExtension. The host relays one validated request at a time;
there is intentionally no queue, cancellation protocol, or session recovery
layer yet.

## Supported production platform

The current production install path is **macOS with Zen Browser**. It uses
Homebrew for the native binaries and a Mozilla-signed XPI for the extension.

You also need:

- [Homebrew](https://brew.sh/);
- Zen Browser;
- an existing YouTube or YouTube Music tab when you want playback;
- autoplay enabled for YouTube and YouTube Music in Zen if Zen blocks audible
  autoplay.

Linux-oriented runtime paths exist in the code, but Linux packaging and Zen
installation are not a supported release path yet.

## Install

### 1. Install MusicHook with Homebrew

```fish
brew install cryoviking/musichook/music-hook
```

Homebrew may ask you to trust this third-party formula. Trust the specific
formula rather than the entire tap if prompted.

### 2. Register the production native host with Zen

```fish
music-hook-install-zen
```

This writes a per-user Zen native-messaging manifest at:

```text
~/Library/Application Support/Mozilla/NativeMessagingHosts/music_hook_host.json
```

It authorizes only the production MusicHook extension. The manifest points at
Homebrew's stable `opt` path, so ordinary Homebrew upgrades do not require
re-registering it.

### 3. Install the signed extension

1. Download the signed `MusicHook-<version>.xpi` from the
   [latest GitHub Release](https://github.com/CryoViking/MusicHook/releases/latest).
2. In Zen, open `about:addons`.
3. Open the gear menu and select **Install Add-on From File…**.
4. Choose the downloaded XPI and accept Zen's confirmation.
5. Reload the extension after registering the native host.

The extension has a stable ID and an HTTPS update manifest, so later signed
extension releases are discovered through Zen/Firefox's normal update checks.

### 4. Create the local library

```fish
music init
```

Press Enter to accept the displayed data-directory default, or provide another
absolute path. MusicHook writes manually editable ZON files:

```text
~/.config/music_hook/config.zon
~/.config/music_hook/data/music_library.zon
```

Finally, verify the whole chain:

```fish
music doctor
```

All four checks should report `ok`, including `native bridge`.

## Everyday use

Save a known favourite:

```fish
music add dusk "https://music.youtube.com/watch?v=example"
```

`add` verifies the URL before changing the library, fetches its page, reads its
Open Graph title, and stores the resulting target. Alias conflicts are rejected
before the network request.

Play by alias or direct URL:

```fish
music play dusk
music play "https://www.youtube.com/watch?v=example"
```

Inspect or maintain the local collection:

```fish
music list
music remove dusk
```

Control playback:

```fish
music pause
music resume
```

`play` prefers a pinned eligible tab for the requested site—YouTube for a
YouTube URL, YouTube Music for a Music URL—then falls back to the first
matching tab. `pause` finds a playing eligible tab; `resume` targets the last
tab MusicHook controlled. Neither command creates a browser tab.

## Data and privacy

MusicHook has no account, cloud library, OAuth flow, telemetry, or third-party
sync service.

- Configuration and the target library are stored locally as editable ZON.
- The native host listens only on a local Unix-domain socket in runtime state.
- The extension communicates with the local native host through Zen's native
  messaging boundary.
- `music add` makes a direct request to the supplied YouTube or YouTube Music
  URL to read its title. Playback remains in your existing browser session.

The extension's production manifest declares no data collection to Mozilla.

## Diagnostics and common repairs

Run this first when something does not connect:

```fish
music doctor
```

Useful interpretations:

- `config: failed (FileNotFound)`: run `music init`.
- `data directory` or `library file` failed: repair the configured path or
  rerun `music init`.
- `native bridge: failed (...)`: rerun `music-hook-install-zen`, then reload
  the extension in Zen.
- A `PlaybackFailed` response usually means there is no eligible playing tab,
  no media element is available yet, or Zen rejected autoplay.

To remove only Zen's native-host registration:

```fish
music-hook-uninstall-zen
```

Remove the extension through `about:addons`; remove the Homebrew package with:

```fish
brew uninstall music-hook
```

Neither command deletes your local configuration or library automatically.

## Development

MusicHook currently targets Zig `0.16.0`.

```fish
zig build
zig build test-host
zig build test-cli
```

The build-system test steps are normally silent on success. An exit status of
zero means the selected suite passed.

The committed extension directory is the development extension, with its own
development ID. The production extension is assembled from
`package_resources/production_extension/` and must be Mozilla-signed before
installation. See [extension/Docs.md](extension/Docs.md) for the WebExtension,
native-messaging, signing, and update constraints.

Maintainers: the complete local release runbook is intentionally Git-ignored
as `RELEASE_PROCESS.local.md`; it contains operational commands but no
credentials.

## Current boundaries

MusicHook deliberately does not currently provide:

- YouTube account or playlist synchronisation;
- OAuth or a remote API integration;
- a playback queue, cancellation, or resynchronisation protocol;
- automatic tab creation or a TUI;
- a supported Linux package/install path.

These are possible future learning directions, not promises on the current
release surface.

## License

MusicHook is licensed under the [MIT License](LICENSE.md).
