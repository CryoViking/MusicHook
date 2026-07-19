#!/usr/bin/env fish

if test (count $argv) -ne 2
    echo "Usage: ./_test_tools/quick_test_add.fish <alias> <youtube-url>"
    exit 2
end

set -l test_dir "$PWD/.test-home"

if test -d "$test_dir"
    rm -rf "$test_dir"
end

printf "\n" | env HOME="$test_dir" zig-out/bin/music init
or exit $status

env HOME="$test_dir" zig-out/bin/music add $argv[1] $argv[2]
or exit $status

set -l library_file \
    "$test_dir/.config/music_hook/data/music_library.zon"

rg -F -q $argv[1] "$library_file"
or begin
    echo "Alias was not written to the test library: $argv[1]"
    exit 1
end

rg -F -q $argv[2] "$library_file"
or begin
    echo "URL was not written to the test library: $argv[2]"
    exit 1
end

echo "Verified alias and URL in test library."

cat "$test_dir/.config/music_hook/data/music_library.zon"
