#!/bin/sh
set -eu

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' "Usage: $0 [--quiet]"
}

quiet=false

while [ "$#" -gt 0 ]; do
  case "$1" in
  --quiet)
    quiet=true
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

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

package_metadata="$repo_dir/build.zig.zon"
production_manifest="$repo_dir/package_resources/production_extension/manifest.json"

[ -f "$package_metadata" ] || fail "build.zig.zon is missing"
[ -f "$production_manifest" ] || fail "production extension manifest is missing"

package_version=$(awk -F '"' '
  /^[[:space:]]*\.version[[:space:]]*=/ { print $2; exit }
' "$package_metadata")

extension_version=$(awk -F '"' '
  /^[[:space:]]*"version"[[:space:]]*:/ { print $4; exit }
' "$production_manifest")

[ -n "$package_version" ] || fail "could not read the package version from build.zig.zon"
[ -n "$extension_version" ] || fail "could not read the extension version from its manifest"

[ "$package_version" = "$extension_version" ] ||
  fail "release version mismatch: build.zig.zon is $package_version, production extension is $extension_version"

if [ "$quiet" = false ]; then
  printf '%s\n' "Release metadata is consistent: $package_version"
fi
