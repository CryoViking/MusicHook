#!/usr/bin/env fish

set -l alias test_alias
set -l url "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
set -l test_dir "$PWD/.test-home"
set -l music_bin "$PWD/zig-out/bin/music"

if test -d "$test_dir"
    rm -rf "$test_dir"
end

printf "\n" | env HOME="$test_dir" "$music_bin" init
or exit $status

env HOME="$test_dir" "$music_bin" add "$alias" "$url"
or exit $status

echo "Listing saved targets:"
env HOME="$test_dir" "$music_bin" list
or exit $status

set -l list_output (env HOME="$test_dir" "$music_bin" list)
or exit $status

printf '%s\n' "$list_output" | rg -F -q -- "PLAYLISTS"
or begin
    echo "Playlist section was not printed"
    exit 1
end

printf '%s\n' "$list_output" | rg -F -q -- "No playlists saved."
or begin
    echo "Empty playlist message was not printed"
    exit 1
end

printf '%s\n' "$list_output" | rg -F -q -- "TRACKS"
or begin
    echo "Track section was not printed"
    exit 1
end

printf '%s\n' "$list_output" | rg -F -q -- "$alias"
or begin
    echo "Track alias was not printed: $alias"
    exit 1
end

printf '%s\n' "$list_output" | rg -F -q -- "$url"
or begin
    echo "Track URL was not printed: $url"
    exit 1
end

echo "Verified list sections and saved target output."
