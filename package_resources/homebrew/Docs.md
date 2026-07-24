# MusicHook Homebrew Release Notes

MusicHook is distributed through the first-party GitHub tap
`CryoViking/homebrew-musichook`. Users install it with:

```fish
brew install cryoviking/musichook/music-hook
```

The formula must reference a versioned GitHub Release source archive and its
SHA-256 checksum. Do not publish a formula containing a local `file://` URL.
`scripts/package-homebrew-formula.sh` renders the formula after the source
archive has been uploaded.

The tap's default GitHub Actions workflows build bottles. Once a formula pull
request is reviewed and its checks pass, publish those bottles with the tap's
`brew pr-pull` workflow. Users with a matching bottle then download it instead
of compiling MusicHook or installing Zig. A source build remains Homebrew's
fallback when no compatible bottle exists.

The signed Zen extension is intentionally outside the formula. It is released
separately because Mozilla signing is an extension-distribution concern, not a
Homebrew build step.
