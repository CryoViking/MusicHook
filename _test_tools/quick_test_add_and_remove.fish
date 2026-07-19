#!/usr/bin/env fish

if test (count $argv) -ne 2
    echo "Usage: ./_test_tools/quick_test_add_remove.fish <alias> <youtube-url>"
    exit 2
end

set -l alias $argv[1]
set -l url $argv[2]
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

env HOME="$test_dir" "$music_bin" remove "$alias"
or exit $status

if rg -F -q -- "$alias" "$library_file"
    echo "Alias still exists after removal: $alias"
    exit 1
end

env HOME="$test_dir" "$music_bin" remove "$alias"
or begin
    echo "Removing a missing alias should succeed"
    exit 1
end

echo "Verified add, remove, and missing-alias behaviour."
cat "$library_file"
