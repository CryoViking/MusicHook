# MusicHook

A local-first CLI and Zen extension for starting focus music without opening YouTube’s distraction labyrinth.

## Goal

From the terminal, start a named YouTube Music or YouTube playlist in an existing Zen favourite/pinned tab—without focusing Zen.

```sh
music play dusk
music play longform
music sync
music list
```

The CLI is for beginning a work session. Once I deliberately open Zen and control music manually, MusicHook must leave the session alone.

## Principles

- Local-only; never publicly distributed.
- No browser focus or window switching during normal commands.
- No Google credentials or browser cookies exposed to the CLI.
- Playlist aliases and configuration belong to the CLI.
- The Zen extension is a minimal bridge and page controller.
- Support both music.youtube.com and www.youtube.com.
- Prefer existing Zen favourite/pinned tabs; only open/reload the configured playlist tab when necessary.
- Keep permissions and accepted commands minimal.

## Architecture

music CLI
  ↕ Unix-domain socket
MusicHook native host (Zig)
  ↕ Firefox native messaging
Zen extension (JavaScript)
  ↕ content scripts
YouTube Music / YouTube favourite tabs

The native host is long-lived while Zen is running. It relays requests and replies between the CLI and extension.

## Initial Commands

```sh
music sync [youtube|ytmusic]
music list
music play <alias>
music pause
music resume
music status
music alias set <alias> <playlist>
music alias remove <alias>
```

Example configuration:

```
[playlists.dusk]
source = "ytmusic"
url = "https://music.youtube.com/playlist?list=..."

[playlists.longform]
source = "youtube"
url = "https://www.youtube.com/playlist?list=..."
```

## Implementation Phases

### 1. Define the protocol

- Define JSON request/response messages.
- Define error messages for Zen closed, extension unavailable, missing playlist, and playback failure.
- Keep commands explicit: play, pause, resume, status, sync.

### 2. Zig CLI

- Implement command parsing.
- Read/write local playlist configuration.
- Connect to the Unix socket, send one request, print one response, exit.
- Begin with synchronous request/response handling.

### 3. Zig native host

- Implement Firefox native-messaging framing over stdin/stdout.
- Create a user-only Unix socket.
- Relay messages between CLI and extension.
- Use a small poll() event loop only when multiplexing is needed.
- Restrict socket and state directories to the current user.

### 4. Zen extension

- Fixed extension ID.
- Native-messaging connection maintained by the background script.
- Content scripts limited to:
    - https://music.youtube.com/*
    - https://www.youtube.com/*

- Locate existing matching favourite/pinned tabs without activating them.
- Play, pause, resume, report status.
- Maintain separate page-control logic for YouTube Music and normal YouTube.

### 5. Playlist synchronisation

- Visit or reuse each service’s playlist-library page in a background tab.
- Extract playlist names and canonical URLs.
- Return results to the CLI for local alias management.
- Treat DOM scraping as replaceable, since YouTube may alter its UI.

### 6. Installation and persistence

- Package the extension as a private, unlisted Mozilla-signed XPI.
- Install the native-messaging manifest for the current user.
- Build the Zig binary locally on each machine.
- Document installation and uninstall steps.

## Security Boundaries

- Native host allowlists only MusicHook’s extension ID.
- Unix socket is accessible only by the current user.
- Extension permissions are limited to YouTube and YouTube Music.
- CLI accepts only a small validated command schema.
- Never log cookies, OAuth tokens, browser history, or unrelated tab URLs.

## Non-Goals

- Replacing YouTube Music or building a full media player.
- Managing queues after the initial playlist starts.
- Preventing deliberate manual browsing or music changes.
- Synchronising configuration between machines automatically.
- General-purpose browser automation.

## Definition of Done

music play <alias> starts the configured playlist in its existing Zen favourite/pinned tab, without bringing Zen forward; errors are clear; and manual control in Zen remains entirely uninterrupted.
