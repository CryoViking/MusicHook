#!/bin/sh
set -eu

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 --tap USER/REPOSITORY --homepage HTTPS_URL"
}

tap_name=""
homepage=""

while [ "$#" -gt 0 ]; do
  case "$1" in
  --tap)
    [ "$#" -ge 2 ] ||
      fail "--tap needs a name"

    tap_name=$2
    shift 2
    ;;
  --homepage)
    [ "$#" -ge 2 ] ||
      fail "--homepage needs a URL"

    homepage=$2
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

[ -n "$tap_name" ] ||
  fail "--tap is required"

[ -n "$homepage" ] ||
  fail "--homepage is required"

case "$tap_name" in
*/*)
  ;;
*)
  fail "--tap must have the form USER/REPOSITORY"
  ;;
esac

case "$homepage" in
https://*)
  ;;
*)
  fail "--homepage must begin with https://"
  ;;
esac

command -v brew >/dev/null 2>&1 ||
  fail "Homebrew is required"

script_dir=$(
  CDPATH= cd -- "$(dirname -- "$0")" &&
    pwd -P
)

repo_dir=$(
  CDPATH= cd -- "$script_dir/.." &&
    pwd -P
)

brew_local() {
  brew "$@"
}

if ! brew tap | grep -F -x -- "$tap_name" >/dev/null; then
  brew tap-new "$tap_name"
fi

tap_dir=$(brew --repository "$tap_name")
formula_dir="$tap_dir/Formula"
formula_name="music-hook"
formula_path="$formula_dir/$formula_name.rb"
formula_reference="$tap_name/$formula_name"

mkdir -p "$formula_dir"

sh "$repo_dir/scripts/package-source-release.sh"

source_archive=$(find "$repo_dir/out/release" -maxdepth 1 -name 'MusicHook-*.tar.gz' -print -quit)
[ -n "$source_archive" ] ||
  fail "source-release script did not create an archive"

source_sha256=$(shasum -a 256 "$source_archive" | awk '{ print $1 }')

sh "$repo_dir/scripts/package-homebrew-formula.sh" \
  --homepage "$homepage" \
  --source-url "file://$source_archive" \
  --source-sha256 "$source_sha256" \
  --allow-local-source

cp "$repo_dir/out/homebrew/$formula_name.rb" "$formula_path"

if brew_local list --formula "$formula_name" >/dev/null 2>&1; then
  brew_local reinstall --build-from-source "$formula_reference"
else
  brew_local install --build-from-source "$formula_reference"
fi

brew_local test "$formula_reference"

formula_prefix=$(brew_local --prefix "$formula_reference")

music_binary="$formula_prefix/bin/music"
host_binary="$formula_prefix/libexec/music-hook-host"
zen_installer="$formula_prefix/bin/music-hook-install-zen"
zen_uninstaller="$formula_prefix/bin/music-hook-uninstall-zen"

[ -x "$music_binary" ] ||
  fail "Homebrew did not install the music binary"

[ -x "$host_binary" ] ||
  fail "Homebrew did not install the native host"

[ -x "$zen_installer" ] ||
  fail "Homebrew did not install the Zen installer command"

[ -x "$zen_uninstaller" ] ||
  fail "Homebrew did not install the Zen uninstaller command"

manifest_dir="$repo_dir/out/homebrew-test/NativeMessagingHosts"
manifest_path="$manifest_dir/music_hook_host.json"

"$zen_installer" --manifest-dir "$manifest_dir"

[ -f "$manifest_path" ] ||
  fail "Zen installer did not create a native-host manifest"

plutil -convert xml1 -o /dev/null "$manifest_path" ||
  fail "generated native-host manifest is invalid"

grep -F -q -- "@music-hook.automatacrypt" "$manifest_path" ||
  fail "generated native-host manifest does not allow the production extension"

grep -F -q -- "$host_binary" "$manifest_path" ||
  fail "generated native-host manifest does not point at the installed host"

"$zen_uninstaller" --manifest-dir "$manifest_dir"

[ ! -e "$manifest_path" ] && [ ! -L "$manifest_path" ] ||
  fail "Zen uninstaller did not remove the native-host manifest"

printf '%s\n' "Verified the local Homebrew MusicHook package:"
printf '%s\n' "  Formula: $formula_reference"
printf '%s\n' "  Prefix:  $formula_prefix"
