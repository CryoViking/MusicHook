# MusicHook

A local-first CLI and Zen extension for starting focus music without opening YouTube’s distraction labyrinth.

## Goal

From the terminal, start a named YouTube Music or YouTube target in an existing Zen favourite/pinned tab—without focusing Zen. A target can be a playlist or a single playable track of any length, including a long-form mix.

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
- Target aliases and configuration belong to the CLI.
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
music alias set <alias> <url>
music alias remove <alias>
```

Example configuration:

```
[targets.dusk]
title = "Dusk Focus"
kind = "playlist"
source = "ytmusic"
url = "https://music.youtube.com/playlist?list=..."

[targets.longform]
title = "Long-form Mix"
kind = "track"
source = "youtube"
url = "https://www.youtube.com/watch?v=..."
```

`kind` is local metadata for later browsing and filtering. A long-form mix is a `track`; it differs from another track only in duration.

## Product Milestones

1. **Core play bridge.** Build the CLI, native host, and Zen extension path so `music play <alias>` can start an existing target without focusing Zen.
2. **Local target configuration.** Store manually added playlist and track targets locally with a stable alias, title, kind, source, and canonical URL or ID. The alias may match the title, but the stored identity remains stable when titles are renamed or duplicated.
3. **Extension queue.** Let the extension queue the current YouTube or YouTube Music target for later import, persisting the candidate until the native host acknowledges it.
4. **Sync import and deduplication.** Extend `music sync` to import queued candidates and discover visible library playlists, generate or request a local alias, and deduplicate by canonical URL or ID without overwriting an existing target.

## Implementation Phases

### 1. Define the protocol

- Define JSON request/response messages.
- Define error messages for Zen closed, extension unavailable, missing playlist, and playback failure.
- Keep commands explicit: play, pause, resume, status, sync.

### 2. Zig CLI

- Implement command parsing.
- Read/write local target configuration.
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

### 5. Target synchronisation and queue import

- Visit or reuse each service’s playlist-library page in a background tab.
- Extract playlist names and canonical URLs.
- Queue the current target from the extension for later import.
- Persist queued candidates until the native host acknowledges import.
- Return discovered and queued targets to the CLI for local alias management.
- Deduplicate imports by canonical URL or ID; never overwrite an existing target alias automatically.
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

music play <alias> starts the configured target in its existing Zen favourite/pinned tab, without bringing Zen forward; errors are clear; and manual control in Zen remains entirely uninterrupted.
