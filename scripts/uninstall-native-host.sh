#!/bin/sh
set -eu

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 [--manifest-dir ABSOLUTE_PATH]"
}

manifest_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
  --manifest-dir)
    [ "$#" -ge 2 ] ||
      fail "--manifest-dir needs a path"

    manifest_dir=$2
    shift 2
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "unknown argument: $1"
    ;;
  esac
done

if [ -z "$manifest_dir" ]; then
  user_home=${HOME:?HOME must be set}

  case "$(uname -s)" in
  Darwin)
    manifest_dir="$user_home/Library/Application Support/zen/NativeMessagingHosts"
    ;;
  Linux)
    manifest_dir="$user_home/.mozilla/native-messaging-hosts"
    ;;
  *)
    fail "unsupported platform; pass --manifest-dir explicitly"
    ;;
  esac
fi

case "$manifest_dir" in
/*)
  ;;
*)
  fail "--manifest-dir must be an absolute path"
  ;;
esac

manifest_path="$manifest_dir/music_hook_host.json"

if [ ! -e "$manifest_path" ] && [ ! -L "$manifest_path" ]; then
  printf '%s\n' "MusicHook native-host manifest is not installed:"
  printf '%s\n' "  $manifest_path"
  exit 0
fi

rm -- "$manifest_path"

printf '%s\n' "Removed MusicHook native-host manifest:"
printf '%s\n' "  $manifest_path"
