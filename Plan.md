# MusicHook

MusicHook is a local-first CLI for starting known favourite YouTube and YouTube Music targets in an already-open Zen browser, without manually navigating into YouTube's distraction labyrinth.

It is deliberately a small launcher, not a replacement YouTube library or media player.

## Product boundary

The user keeps a small, manually curated collection of favourites in their head and in a local ZON library. MusicHook makes those favourites quick to start, change, pause, or resume from the terminal.

Once the user deliberately opens Zen and takes over playback manually, MusicHook leaves the session alone.

Supported playable targets are YouTube and YouTube Music URLs. A single track, playlist, or long-form mix is simply a playable target; duration is not a separate type.

## Architecture

```text
music CLI
  ↕ Unix-domain socket
music-hook-host
  ↕ Firefox native messaging
Zen extension
  ↕ content script
YouTube Music / YouTube tabs
```

- `music` is the CLI binary.
- `music-hook-host` is a separate native-messaging host binary.
- The host is a deliberately simple serial relay: one framed request from the CLI, one framed request to the extension, one validated response back to the CLI.
- The Unix socket path is runtime state, not configuration: prefer an absolute `$XDG_RUNTIME_DIR/music_hook/host.sock`, otherwise an absolute `$TMPDIR/music_hook/host.sock`.
- The extension prefers a matching pinned/favourite tab, then the first eligible tab. It does not focus Zen during normal playback commands.

## Current commands

```sh
music init
music add <alias> <YouTube URL>
music remove <alias>
music play <alias-or-YouTube-URL>
music pause
music resume
```

`music add` checks for an alias conflict before making any metadata request. It resolves the supplied public URL, stores the discovered title plus source and kind metadata, then writes the target to the local library.

Missing aliases are normal not-found results, not errors.

## Completed work

- Shared native-message framing and validated bridge request/response protocol.
- Unix-socket CLI client and native-host serial relay, including focused integration tests.
- Zen/Firefox extension installation tooling and native-messaging bridge.
- Direct URL playback, pause, and resume through the extension.
- Tab selection that distinguishes YouTube from YouTube Music and prefers pinned/favourite eligible tabs.
- Local ZON configuration and library creation through `music init`.
- Local target add/remove operations with duplicate-alias protection and manually inspectable ZON output.
- Metadata resolution through a public request to the supplied URL, using Open Graph title metadata; no Google credentials or browser cookies are exposed to the CLI.
- Alias playback: resolve a locally stored target, then reuse the normal host/extension playback path.
- Repeatable Fish smoke-test helpers using an ignored `.test-home` and a deliberate public `test_alias` fixture.

## Next smallest step: `music list`

`music list` is the last intended local-library command for this first finished shape.

```text
load config
→ open local library
→ print known aliases, titles, sources, kinds, and URLs
```

It requires no browser, extension, API, or network access. It is an occasional inspection tool, not a browsing or discovery interface.

## Deferred: `music doctor`

`doctor` is a diagnostic command, not a playback-state query. It should eventually report independent checks clearly, without changing playback:

```text
config:       config.zon exists, parses, and validates
data library: configured directory exists and is usable
library file: music_library.zon exists, parses, and validates
native bridge: host can round-trip a harmless request through the extension
```

When a prerequisite fails, dependent checks should say `skipped` rather than inventing secondary failures. For example, a missing data directory means the library-file check is skipped.

The native-bridge check must prove the host ↔ extension native-messaging connection, not merely that the CLI can connect to a Unix socket. It should not require a playable tab or report a missing YouTube tab as a doctor failure.

The existing placeholder `status` command should be renamed to `doctor` when this work begins.

## Deferred: playlist smoke testing

Manual smoke tests should later confirm that a stored playlist URL plays correctly through the extension. This is verification work, not a reason to create a separate playlist architecture.

## Remove `sync` now

Remove the current unimplemented `sync` command from the parser, CLI protocol, and command dispatch. It does not belong to the first product boundary and should not remain as a misleading placeholder.

## Possible future learning exercise: OAuth-backed sync

An opt-in future sync feature could be worthwhile as a learning project, not as a current product requirement. It would explore how a native local application safely integrates with a user-owned remote service, including:

- OAuth 2.0 consent and scope design.
- Authorization Code flow with PKCE for a local CLI application.
- Browser-based authorization and redirect/callback handling.
- Short-lived access tokens, refresh tokens, expiry, and revocation.
- Safe local token storage, preferably using an operating-system credential store rather than ZON or source control.
- YouTube Data API request design, pagination, quotas, and explicit error handling.
- A clear distinction between importing candidates and automatically changing the curated local library.

If this is ever attempted, it must remain explicitly opt-in, request the minimum scope, never log tokens, and never turn MusicHook into a full mirror of the user's YouTube library.

## Non-goals

- A complete YouTube or YouTube Music library manager.
- Recommendation, discovery, or browsing features.
- General-purpose browser automation.
- Queueing, cancellation, resynchronisation, or distributed-systems complexity in the native host.
- Automatically synchronising configuration between machines.
- Requiring Google credentials for normal add, remove, list, play, pause, or resume use.

## Definition of done for the first version

The user can initialise a local library, add and remove known favourites, list them, and play a direct URL or stored alias through an existing Zen tab. Pause and resume work through the same bridge. Errors are clear, browser focus is not stolen, and the tool remains small enough to support focused work rather than becoming another place to browse.
