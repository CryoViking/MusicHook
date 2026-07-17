#!/usr/bin/env fish

set -l test_dir "$PWD/.test-home"
set -l music "$PWD/zig-out/bin/music"

if test -d "$test_dir"
    rm -rf "$test_dir"
end

set -l default_data_path "$test_dir/.config/music_hook/data"
set -l config_path "$test_dir/.config/music_hook/config.zon"
set -l alternate_data_path "$test_dir/alternate-data"

echo "First initialization: accepting default"
printf '\n' | env HOME="$test_dir" "$music" init
or exit 1

test -f "$config_path"
or begin
    echo "FAIL: config.zon was not created"
    exit 1
end

test -f "$default_data_path/music_library.zon"
or begin
    echo "FAIL: default music library was not created"
    exit 1
end

echo "Second initialization: accepting existing default"
printf '\n' | env HOME="$test_dir" "$music" init
or exit 1

test -f "$default_data_path/music_library.zon"
or begin
    echo "FAIL: existing library disappeared"
    exit 1
end

echo "Third initialization: selecting a new data path"
printf '%s\n' "$alternate_data_path" | env HOME="$test_dir" "$music" init
or exit 1

test -f "$alternate_data_path/music_library.zon"
or begin
    echo "FAIL: alternate library was not created"
    exit 1
end

test -f "$default_data_path/music_library.zon"
or begin
    echo "FAIL: original library was overwritten or removed"
    exit 1
end

rg -q --fixed-strings -- "$alternate_data_path" "$config_path"
or begin
    echo "FAIL: config.zon did not update to the alternate data path"
    exit 1
end

echo
echo "PASS: initialization and reconfiguration completed safely"
echo
echo "Current config:"
cat "$config_path"
