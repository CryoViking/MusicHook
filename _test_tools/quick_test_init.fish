#!/usr/bin/env fish

set -l test_dir "$PWD/.test-home"
if test -d "$test_dir"
    rm -rf "$test_dir"
end

HOME="$test_dir" zig-out/bin/music init
