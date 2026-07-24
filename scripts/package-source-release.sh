#!/bin/sh
set -eu

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' "Usage: $0 [--output-dir ABSOLUTE_PATH]"
}

output_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
  --output-dir)
    [ "$#" -ge 2 ] || fail "--output-dir needs a path"
    output_dir=$2
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

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

if [ -z "$output_dir" ]; then
  output_dir="$repo_dir/out/release"
fi

case "$output_dir" in
/*) ;;
*) fail "--output-dir must be an absolute path" ;;
esac

version=$(awk -F '"' '
  /^[[:space:]]*\.version[[:space:]]*=/ { print $2; exit }
' "$repo_dir/build.zig.zon")

[ -n "$version" ] || fail "could not read the package version from build.zig.zon"

repo_parent=$(dirname -- "$repo_dir")
repo_name=$(basename -- "$repo_dir")
archive_name="MusicHook-$version.tar.gz"
archive_path="$output_dir/$archive_name"
checksum_path="$archive_path.sha256"

mkdir -p "$output_dir"
rm -f -- "$archive_path" "$checksum_path"

tar -czf "$archive_path" \
  --exclude="$repo_name/.git" \
  --exclude="$repo_name/.zig-cache" \
  --exclude="$repo_name/zig-out" \
  --exclude="$repo_name/out" \
  --exclude="$repo_name/.test-home" \
  --exclude="$repo_name/.DS_Store" \
  -C "$repo_parent" \
  "$repo_name"

tar -tzf "$archive_path" >/dev/null || fail "generated source archive could not be read"

source_sha256=$(shasum -a 256 "$archive_path" | awk '{ print $1 }')
[ -n "$source_sha256" ] || fail "could not calculate source archive SHA-256"

printf '%s  %s\n' "$source_sha256" "$archive_name" > "$checksum_path"

printf '%s\n' "Prepared MusicHook source release:"
printf '%s\n' "  Archive: $archive_path"
printf '%s\n' "  SHA-256: $checksum_path"
