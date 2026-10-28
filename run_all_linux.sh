#!/usr/bin/env bash
# Run all seven recipe-manager stacks on Linux, one after
# another, in the same order as build_all_linux.sh.
#
# Build first with ./build_all_linux.sh. Each app runs in the
# foreground from its own directory, so its recipes.db and
# images/ (which are relative to the working directory) are
# the ones in that stack's folder. Close an app's window to
# move on to the next stack.
#
# Unlike build_all_linux.sh, this does not stop at the first
# failure: every stack still gets run, failures are reported
# at the end, and the script exits non-zero if any app failed.
# That is why there is no `set -e` here (see below).
set -uo pipefail

# Run from the repository root, so this works from anywhere.
cd "$(dirname "$0")"

# Stack name, directory, and binary (relative to that
# directory), in build_all_linux.sh order. These are the
# binaries the per-stack build_linux.sh scripts (and, for
# rust-egui, the plain `cargo build` in build_all_linux.sh)
# produce.
STACKS=(
    "rust-egui|rust-egui|target/debug/rust-egui"
    "rust-iced|rust-iced|target/debug/rust-iced"
    "cpp-imgui|cpp-imgui|build/cpp-imgui"
    "cpp-gtk4|cpp-gtk4|build/cpp-gtk4"
    "odin-raygui|odin-raygui|odin-raygui"
    "odin-microui|odin-microui|odin-microui"
    "zig-dvui|zig-dvui|zig-out/bin/zig-dvui"
)

# Check every binary exists before running any of them, so a
# missing build fails up front instead of part-way through.
missing=0
for entry in "${STACKS[@]}"; do
    IFS='|' read -r name dir binary <<< "$entry"
    if [ ! -x "$dir/$binary" ]; then
        echo "Missing: $name ($dir/$binary) — run ./build_all_linux.sh first." >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    exit 1
fi

failed=()
for entry in "${STACKS[@]}"; do
    IFS='|' read -r name dir binary <<< "$entry"
    echo "=== $name ==="
    # Subshell cd, so the app runs from its own directory
    # (see the header) and the next stack still starts from
    # the repository root.
    (cd "$dir" && "./$binary")
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "!!! $name exited with status $status." >&2
        failed+=("$name (status $status)")
    fi
done

if [ "${#failed[@]}" -ne 0 ]; then
    echo "Some stacks failed:" >&2
    for failure in "${failed[@]}"; do
        echo "  - $failure" >&2
    done
    exit 1
fi

echo "All stacks ran."
