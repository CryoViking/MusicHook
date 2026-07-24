#!/bin/sh
set -eu

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 --homepage HTTPS_URL --source-url HTTPS_URL --source-sha256 SHA256 [--output-dir ABSOLUTE_PATH] [--allow-local-source]"
}

homepage=""
source_url=""
source_sha256=""
output_dir=""
allow_local_source=false

while [ "$#" -gt 0 ]; do
  case "$1" in
  --homepage)
    [ "$#" -ge 2 ] ||
      fail "--homepage needs a URL"

    homepage=$2
    shift 2
    ;;
  --source-url)
    [ "$#" -ge 2 ] ||
      fail "--source-url needs a URL"

    source_url=$2
    shift 2
    ;;
  --source-sha256)
    [ "$#" -ge 2 ] ||
      fail "--source-sha256 needs a checksum"

    source_sha256=$2
    shift 2
    ;;
  --output-dir)
    [ "$#" -ge 2 ] ||
      fail "--output-dir needs a path"

    output_dir=$2
    shift 2
    ;;
  --allow-local-source)
    allow_local_source=true
    shift
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

[ -n "$homepage" ] ||
  fail "--homepage is required"

[ -n "$source_url" ] ||
  fail "--source-url is required"

[ -n "$source_sha256" ] ||
  fail "--source-sha256 is required"

case "$homepage" in
https://*)
  ;;
*)
  fail "--homepage must begin with https://"
  ;;
esac

case "$source_url" in
https://*)
  ;;
file://*)
  [ "$allow_local_source" = true ] ||
    fail "--source-url must begin with https://"
  ;;
*)
  fail "--source-url must begin with https://"
  ;;
esac

case "$source_sha256" in
*[!0123456789abcdefABCDEF]*)
  fail "--source-sha256 must be a 64-character hexadecimal SHA-256"
  ;;
esac

[ "${#source_sha256}" -eq 64 ] ||
  fail "--source-sha256 must be a 64-character hexadecimal SHA-256"

script_dir=$(
  CDPATH= cd -- "$(dirname -- "$0")" &&
    pwd -P
)

repo_dir=$(
  CDPATH= cd -- "$script_dir/.." &&
    pwd -P
)

sh "$script_dir/check-release-metadata.sh" --quiet

if [ -z "$output_dir" ]; then
  output_dir="$repo_dir/out"
fi

case "$output_dir" in
/*)
  ;;
*)
  fail "--output-dir must be an absolute path"
  ;;
esac

version=$(awk -F '"' '
  /^[[:space:]]*\.version[[:space:]]*=/ {
    print $2
    exit
  }
' "$repo_dir/build.zig.zon")

[ -n "$version" ] ||
  fail "could not read the package version from build.zig.zon"

formula_dir="$output_dir/homebrew"
formula_path="$formula_dir/music-hook.rb"
formula_template=\
"$repo_dir/package_resources/homebrew/music-hook.rb.template"

[ -f "$formula_template" ] ||
  fail "Homebrew formula template is missing"

mkdir -p "$formula_dir"

rm -f -- "$formula_path"

render_marker() {
  marker=$1
  value=$2
  destination=$3

  temporary_path=$(mktemp "$formula_dir/.music-hook-formula.XXXXXX")

  awk -v marker="$marker" -v value="$value" '
    {
      position = index($0, marker)

      if (position == 0) {
        print
        next
      }

      replacements += 1

      print substr($0, 1, position - 1) \
        value \
        substr($0, position + length(marker))
    }

    END {
      if (replacements != 1) exit 1
    }
  ' "$destination" >"$temporary_path" ||
    fail "could not render formula marker: $marker"

  mv "$temporary_path" "$destination"
}

cp "$formula_template" "$formula_path"

render_marker \
  "__MUSIC_HOOK_HOMEPAGE__" \
  "$homepage" \
  "$formula_path"

render_marker \
  "__MUSIC_HOOK_VERSION__" \
  "$version" \
  "$formula_path"

render_marker \
  "__MUSIC_HOOK_SOURCE_URL__" \
  "$source_url" \
  "$formula_path"

render_marker \
  "__MUSIC_HOOK_SOURCE_SHA256__" \
  "$source_sha256" \
  "$formula_path"

ruby -c "$formula_path" >/dev/null ||
  fail "rendered Homebrew formula has invalid Ruby syntax"

printf '%s\n' "Rendered MusicHook Homebrew formula:"
printf '%s\n' "  Formula: $formula_path"
printf '%s\n' "  Source:  $source_url"
