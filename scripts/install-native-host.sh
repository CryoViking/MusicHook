#!/bin/sh
set -eu

umask 077

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
    manifest_dir="$user_home/Library/Application Support/Mozilla/NativeMessagingHosts"
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

script_dir=$(
  CDPATH= cd -- "$(dirname -- "$0")" &&
    pwd -P
)

repo_dir=$(
  CDPATH= cd -- "$script_dir/.." &&
    pwd -P
)

host_path="$repo_dir/zig-out/bin/music-hook-host"
template_path="$repo_dir/installation/firefox/music_hook_host.json.template"
manifest_path="$manifest_dir/music_hook_host.json"

[ -x "$host_path" ] ||
  fail "native host is missing; run 'zig build' first"

[ -f "$template_path" ] ||
  fail "native-host manifest template is missing"

command -v jq >/dev/null 2>&1 ||
  fail "jq is required to validate the rendered manifest"

case "$host_path" in
*'"'* | *'\'*)
  fail "host path contains JSON-unsafe characters"
  ;;
esac

mkdir -p "$manifest_dir"

temporary_path=$(mktemp "$manifest_dir/.music_hook_host.XXXXXX")

cleanup() {
  [ -z "${temporary_path:-}" ] ||
    rm -f -- "$temporary_path"
}

trap cleanup EXIT HUP INT TERM

awk -v host_path="$host_path" '
      BEGIN {
          marker = "__MUSIC_HOOK_HOST_PATH__"
          replacements = 0
      }

      {
          position = index($0, marker)

          if (position == 0) {
              print
              next
          }

          replacements += 1

          print substr($0, 1, position - 1) \
              host_path \
              substr($0, position + length(marker))
      }

      END {
          if (replacements != 1) exit 1
      }
  ' "$template_path" >"$temporary_path" ||
  fail "could not render native-host manifest"

jq empty "$temporary_path" ||
  fail "rendered native-host manifest is invalid JSON"

chmod 600 "$temporary_path"
mv "$temporary_path" "$manifest_path"
temporary_path=""

printf '%s\n' "Installed MusicHook native-host manifest:"
printf '%s\n' "  $manifest_path"
printf '%s\n' "Host binary:"
printf '%s\n' "  $host_path"
