#!/usr/bin/env fish

set -l alias test_alias
set -l url "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
set -l test_dir "$PWD/.test-home"
set -l music_bin "$PWD/zig-out/bin/music"
set -l library_file \
    "$test_dir/.config/music_hook/data/music_library.zon"

if test -d "$test_dir"
    rm -rf "$test_dir"
end

printf "\n" | env HOME="$test_dir" "$music_bin" init
or exit $status

env HOME="$test_dir" "$music_bin" add "$alias" "$url"
or exit $status

rg -F -q -- "$alias" "$library_file"
or begin
    echo "Alias was not written: $alias"
    exit 1
end

rg -F -q -- "$url" "$library_file"
or begin
    echo "URL was not written: $url"
    exit 1
end

echo "Playing the stored alias: $alias"
env HOME="$test_dir" "$music_bin" play "$alias"
or exit $status

echo "Alias playback request completed."
