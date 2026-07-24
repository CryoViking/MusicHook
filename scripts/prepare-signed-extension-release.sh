#!/bin/sh
set -eu

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 --signed-xpi ABSOLUTE_PATH.xpi --download-url HTTPS_URL [--output-dir ABSOLUTE_PATH]"
}

signed_xpi=""
download_url=""
output_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
  --signed-xpi)
    [ "$#" -ge 2 ] || fail "--signed-xpi needs a path"
    signed_xpi=$2
    shift 2
    ;;
  --download-url)
    [ "$#" -ge 2 ] || fail "--download-url needs a URL"
    download_url=$2
    shift 2
    ;;
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

[ -n "$signed_xpi" ] || fail "--signed-xpi is required"
[ -n "$download_url" ] || fail "--download-url is required"

case "$signed_xpi" in
/*.xpi) ;;
/*) fail "--signed-xpi must end in .xpi" ;;
*) fail "--signed-xpi must be an absolute path" ;;
esac

case "$download_url" in
https://*) ;;
*) fail "--download-url must begin with https://" ;;
esac

[ -f "$signed_xpi" ] || fail "signed XPI is missing: $signed_xpi"

command -v unzip >/dev/null 2>&1 || fail "unzip is required"
command -v plutil >/dev/null 2>&1 || fail "plutil is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

sh "$script_dir/check-release-metadata.sh" --quiet

if [ -z "$output_dir" ]; then
  output_dir="$repo_dir/out/extension-release"
fi

case "$output_dir" in
/*) ;;
*) fail "--output-dir must be an absolute path" ;;
esac

production_manifest="$repo_dir/package_resources/production_extension/manifest.json"
updates_template="$repo_dir/package_resources/production_extension/updates.json.template"

[ -f "$production_manifest" ] || fail "production manifest is missing"
[ -f "$updates_template" ] || fail "update-manifest template is missing"

unzip -t "$signed_xpi" >/dev/null || fail "signed XPI did not pass ZIP validation"

temporary_dir=$(mktemp -d)
cleanup() {
  [ -z "${temporary_dir:-}" ] || rm -rf -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

signed_manifest="$temporary_dir/manifest.json"
unzip -p "$signed_xpi" manifest.json > "$signed_manifest" ||
  fail "signed XPI does not contain manifest.json"

plutil -convert xml1 -o /dev/null "$signed_manifest" ||
  fail "signed XPI manifest is invalid JSON"

cmp -s "$production_manifest" "$signed_manifest" ||
  fail "signed XPI manifest does not match the current production manifest"

extension_id=$(plutil -extract browser_specific_settings.gecko.id raw -expect string "$production_manifest")
extension_version=$(plutil -extract version raw -expect string "$production_manifest")

[ -n "$extension_id" ] || fail "production manifest has no Gecko extension ID"
[ -n "$extension_version" ] || fail "production manifest has no extension version"

mkdir -p "$output_dir"

release_xpi="$output_dir/MusicHook-$extension_version.xpi"
checksum_path="$release_xpi.sha256"
updates_path="$output_dir/updates.json"

cp "$signed_xpi" "$release_xpi"
extension_sha256=$(shasum -a 256 "$release_xpi" | awk '{ print $1 }')
[ -n "$extension_sha256" ] || fail "could not calculate signed XPI SHA-256"

printf '%s  %s\n' "$extension_sha256" "$(basename -- "$release_xpi")" > "$checksum_path"

render_marker() {
  marker=$1
  value=$2
  input=$3
  output=$4

  awk -v marker="$marker" -v value="$value" '
    {
      position = index($0, marker)
      if (position == 0) {
        print
        next
      }

      replacements += 1
      print substr($0, 1, position - 1) value substr($0, position + length(marker))
    }

    END {
      if (replacements != 1) exit 1
    }
  ' "$input" > "$output" || fail "could not render update-manifest marker: $marker"
}

temporary_updates="$temporary_dir/updates.json"
cp "$updates_template" "$temporary_updates"

for marker_value in \
  "__MUSIC_HOOK_EXTENSION_ID__=$extension_id" \
  "__MUSIC_HOOK_EXTENSION_VERSION__=$extension_version" \
  "__MUSIC_HOOK_EXTENSION_XPI_URL__=$download_url" \
  "__MUSIC_HOOK_EXTENSION_XPI_SHA256__=$extension_sha256"
do
  marker=${marker_value%%=*}
  value=${marker_value#*=}
  rendered="$temporary_dir/updates-rendered.json"
  render_marker "$marker" "$value" "$temporary_updates" "$rendered"
  mv "$rendered" "$temporary_updates"
done

plutil -convert xml1 -o /dev/null "$temporary_updates" ||
  fail "rendered update manifest is invalid JSON"

mv "$temporary_updates" "$updates_path"

printf '%s\n' "Prepared MusicHook signed-extension release assets:"
printf '%s\n' "  XPI:          $release_xpi"
printf '%s\n' "  SHA-256:      $checksum_path"
printf '%s\n' "  Update JSON:  $updates_path"
printf '%s\n' ""
printf '%s\n' "Upload the XPI and SHA-256 file to the matching GitHub Release."
printf '%s\n' "Publish updates.json at the update_url embedded in the production manifest."
