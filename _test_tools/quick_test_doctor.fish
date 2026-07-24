#!/usr/bin/env fish

set -l test_dir "$PWD/.test-home"
set -l music_bin "$PWD/zig-out/bin/music"
set -l library_file \
    "$test_dir/.config/music_hook/data/music_library.zon"
set -l healthy_report "$test_dir/doctor-healthy.txt"
set -l broken_report "$test_dir/doctor-missing-library.txt"

if test -d "$test_dir"
    rm -rf "$test_dir"
end

printf "\n" | env HOME="$test_dir" "$music_bin" init
or exit $status

env HOME="$test_dir" "$music_bin" doctor >"$healthy_report" 2>&1
set -l healthy_status $status
set -l healthy_output (string collect <"$healthy_report")

echo
echo "Healthy doctor report:"
printf '%s\n' "$healthy_output"

if test $healthy_status -ne 0
    echo "Healthy doctor check unexpectedly failed:"
    printf '%s\n' "$healthy_output"
    exit 1
end

printf '%s\n' "$healthy_output" | rg -F -q -- "config: ok"
or begin
    echo "Doctor did not report a healthy config"
    exit 1
end

printf '%s\n' "$healthy_output" | rg -F -q -- "data directory: ok"
or begin
    echo "Doctor did not report a healthy data directory"
    exit 1
end

printf '%s\n' "$healthy_output" | rg -F -q -- "library file: ok"
or begin
    echo "Doctor did not report a healthy library file"
    exit 1
end

rm "$library_file"

env HOME="$test_dir" "$music_bin" doctor >"$broken_report" 2>&1
set -l broken_status $status
set -l broken_output (string collect <"$broken_report")

echo
echo "Missing-library doctor report:"
printf '%s\n' "$broken_output"

if test $broken_status -eq 0
    echo "Doctor succeeded despite the missing library file:"
    printf '%s\n' "$broken_output"
    exit 1
end

printf '%s\n' "$broken_output" | rg -F -q -- "config: ok"
or begin
    echo "Doctor lost the healthy config result"
    exit 1
end

printf '%s\n' "$broken_output" | rg -F -q -- "data directory: ok"
or begin
    echo "Doctor lost the healthy data-directory result"
    exit 1
end

printf '%s\n' "$broken_output" | rg -F -q -- "library file: failed (FileNotFound)"
or begin
    echo "Doctor did not report the missing library file"
    exit 1
end

echo ""
echo "Verified healthy and failing local doctor checks."
