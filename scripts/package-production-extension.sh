#!/bin/sh
set -eu

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 [--output ABSOLUTE_PATH.xpi]"
}

output_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
  --output)
    [ "$#" -ge 2 ] ||
      fail "--output needs a path"

    output_path=$2
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

command -v zip >/dev/null 2>&1 ||
  fail "zip is required to build an XPI"

command -v unzip >/dev/null 2>&1 ||
  fail "unzip is required to verify the generated XPI"

script_dir=$(
  CDPATH= cd -- "$(dirname -- "$0")" &&
    pwd -P
)

repo_dir=$(
  CDPATH= cd -- "$script_dir/.." &&
    pwd -P
)

if [ -z "$output_path" ]; then
  output_path="$repo_dir/out/MusicHook.xpi"
fi

case "$output_path" in
/*.xpi)
  ;;
/*)
  fail "--output must end in .xpi"
  ;;
*)
  fail "--output must be an absolute path"
  ;;
esac

production_manifest=\
"$repo_dir/package_resources/production_extension/manifest.json"

background_script="$repo_dir/extension/background.js"
content_script="$repo_dir/extension/content.js"

[ -f "$production_manifest" ] ||
  fail "production manifest is missing"

[ -f "$background_script" ] ||
  fail "background script is missing"

[ -f "$content_script" ] ||
  fail "content script is missing"

output_dir=$(dirname -- "$output_path")
mkdir -p "$output_dir"

staging_dir=$(mktemp -d)

cleanup() {
  [ -z "${staging_dir:-}" ] ||
    rm -rf -- "$staging_dir"
}

trap cleanup EXIT HUP INT TERM

cp "$production_manifest" "$staging_dir/manifest.json"
cp "$background_script" "$staging_dir/background.js"
cp "$content_script" "$staging_dir/content.js"

rm -f -- "$output_path"

(
  cd "$staging_dir"
  zip -X -q -r "$output_path" \
    manifest.json \
    background.js \
    content.js
)

unzip -t "$output_path" >/dev/null ||
  fail "generated XPI did not pass ZIP validation"

printf '%s\n' "Built unsigned MusicHook extension submission package:"
printf '%s\n' "  $output_path"
printf '%s\n' "Submit this XPI to AMO for unlisted signing; do not install it in Zen."
