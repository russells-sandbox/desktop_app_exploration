#!/usr/bin/env bash
# Profile build times for all seven recipe-manager stacks on
# Linux, into a CSV at the repository root, in the same order
# as build_all_linux.sh.
#
# For each stack it measures two builds, back to back:
#   clean   — build artifacts removed first, then built.
#   cached  — the same build command again, with no clean and
#             no source changes in between.
#
# Usage:
#   ./profile_build_times_linux.sh [--jobs N] [--output FILE]
#
#   --jobs N    Parallelism for the builds. Default: nproc.
#   --output FILE
#               CSV file. Default: build_times.csv in the
#               repository root. The file is appended to;
#               the header is written only if the file does
#               not already have content, so repeated runs
#               accumulate comparable rows (distinguished by
#               timestamp).
#
# Output columns:
#   timestamp,stack,build_type,build_time_seconds,cores_used,status
#
#   timestamp          When the measurement started (local time).
#   stack              rust-egui, rust-iced, cpp-imgui, cpp-gtk4,
#                      odin-raygui, odin-microui, zig-dvui.
#   build_type         clean | cached, as above.
#   build_time_seconds Wall-clock time for that build command,
#                      to the millisecond.
#   cores_used         The --jobs value (nproc by default).
#   status             success | failed. A failed build still
#                      gets a row, with the time it took, and
#                      the script continues with the next
#                      stack instead of stopping; it exits
#                      non-zero at the end if any build failed.
#
# What "cores used" means here, precisely: cargo is given
# `-j <jobs>` and CMake is given `--parallel <jobs>`, so for
# the Rust and C++ stacks cores_used is the parallelism
# actually passed to the build. Odin and Zig have no jobs
# flag in their build scripts; they use internal parallelism
# based on the machine's available cores, so for them
# cores_used is the machine's core count (nproc by default),
# not a measured CPU utilisation. Times from machines with
# different core counts are therefore only comparable with
# cores_used taken into account.
#
# What "clean" removes, per stack (so a clean time is not
# accidentally a re-download time):
#   Rust:  `cargo clean` removes target/ only. The cargo
#          registry cache is kept, so dependencies are
#          rebuilt, not re-downloaded.
#   C++:   `rm -rf build/`. Note cpp-imgui fetches ImGui via
#          FetchContent on configure, so its clean time does
#          include that fetch.
#   Odin:  `rm -f <binary>`. Odin has no incremental build
#          cache directory, so clean and cached times for
#          the Odin stacks are expected to be similar —
#          that similarity is itself the finding.
#   Zig:   `rm -rf zig-out/ .zig-cache/`. zig-pkg/ (the
#          fetched-dependency cache) is kept, so a clean
#          build does not re-fetch DVUI.
#
# A missing toolchain is checked before any cleaning, so a
# stack whose toolchain is not installed gets failed rows
# without deleting its existing build output.
#
# Unlike build_all_linux.sh, this script deliberately has no
# `set -e`: a failed build must not hide the other stacks'
# times (see the status column above).
set -uo pipefail

# Run from the repository root, so this works from anywhere.
cd "$(dirname "$0")"

JOBS="$(nproc)"
OUTPUT="build_times.csv"

usage() {
    echo "Usage: $0 [--jobs N] [--output FILE]"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --jobs)
            JOBS="$2"; shift 2
            ;;
        --output)
            OUTPUT="$2"; shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$JOBS" in
    ""|*[!0-9]*|0)
        echo "Jobs must be a positive number: $JOBS" >&2
        exit 1
        ;;
esac

STACKS=(
    "rust-egui"
    "rust-iced"
    "cpp-imgui"
    "cpp-gtk4"
    "odin-raygui"
    "odin-microui"
    "zig-dvui"
)

# The command that builds a stack, run from that stack's
# directory. Rust needs the rustup PATH entry that
# build_all_linux.sh and rust-iced/build_linux.sh also use.
build_stack() {
    case "$1" in
        rust-egui)
            (cd rust-egui && export PATH="$HOME/.cargo/bin:$PATH" && cargo build -j "$JOBS")
            ;;
        rust-iced)
            (cd rust-iced && export PATH="$HOME/.cargo/bin:$PATH" && cargo build -j "$JOBS")
            ;;
        cpp-imgui)
            (cd cpp-imgui && cmake -S . -B build && cmake --build build --parallel "$JOBS")
            ;;
        cpp-gtk4)
            (cd cpp-gtk4 && cmake -S . -B build && cmake --build build --parallel "$JOBS")
            ;;
        odin-raygui)
            (cd odin-raygui && odin build src -out:odin-raygui)
            ;;
        odin-microui)
            (cd odin-microui && odin build src -out:odin-microui)
            ;;
        zig-dvui)
            (cd zig-dvui && zig build)
            ;;
    esac
}

clean_stack() {
    case "$1" in
        rust-egui)
            (cd rust-egui && export PATH="$HOME/.cargo/bin:$PATH" && cargo clean)
            ;;
        rust-iced)
            (cd rust-iced && export PATH="$HOME/.cargo/bin:$PATH" && cargo clean)
            ;;
        cpp-imgui)
            rm -rf cpp-imgui/build
            ;;
        cpp-gtk4)
            rm -rf cpp-gtk4/build
            ;;
        odin-raygui)
            rm -f odin-raygui/odin-raygui
            ;;
        odin-microui)
            rm -f odin-microui/odin-microui
            ;;
        zig-dvui)
            rm -rf zig-dvui/zig-out zig-dvui/.zig-cache
            ;;
    esac
}

# The toolchain a stack's build needs, for the pre-clean check.
toolchain_for() {
    case "$1" in
        rust-egui|rust-iced) echo "cargo" ;;
        cpp-imgui|cpp-gtk4) echo "cmake" ;;
        odin-raygui|odin-microui) echo "odin" ;;
        zig-dvui) echo "zig" ;;
    esac
}

# Measure one build of one stack and append its CSV row.
# Returns the build's exit status.
measure() {
    local stack="$1" type="$2"
    local start_ts start_ns end_ns status ms sec rem status_text
    start_ts=$(date '+%Y-%m-%d %H:%M:%S')
    start_ns=$(date +%s%N)
    build_stack "$stack"
    status=$?
    end_ns=$(date +%s%N)
    ms=$(( (end_ns - start_ns) / 1000000 ))
    sec=$(( ms / 1000 ))
    rem=$(( ms % 1000 ))
    if [ "$status" -eq 0 ]; then
        status_text="success"
    else
        status_text="failed"
    fi
    printf '%s,%s,%s,%d.%03d,%s,%s\n' \
        "$start_ts" "$stack" "$type" "$sec" "$rem" "$JOBS" "$status_text" >> "$OUTPUT"
    return "$status"
}

# Record a failed row without running a build (used when the
# toolchain is missing, so nothing is cleaned or built).
record_failed() {
    local stack="$1" type="$2"
    local start_ts
    start_ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s,%s,%s,0.000,%s,failed\n' \
        "$start_ts" "$stack" "$type" "$JOBS" >> "$OUTPUT"
}

if [ ! -s "$OUTPUT" ]; then
    echo "timestamp,stack,build_type,build_time_seconds,cores_used,status" > "$OUTPUT"
fi

echo "Profiling builds with $JOBS core(s) into $OUTPUT."

failed=()
for stack in "${STACKS[@]}"; do
    toolchain=$(toolchain_for "$stack")
    # For Rust, cargo lives in $HOME/.cargo/bin, which is not
    # necessarily on PATH; check there too.
    if ! command -v "$toolchain" >/dev/null 2>&1 \
        && ! [ -x "$HOME/.cargo/bin/$toolchain" ]; then
        echo "Skipping $stack: $toolchain not installed." >&2
        record_failed "$stack" "clean"
        record_failed "$stack" "cached"
        failed+=("$stack (toolchain $toolchain missing)")
        continue
    fi

    echo "=== $stack (clean) ==="
    clean_stack "$stack"
    if ! measure "$stack" "clean"; then
        failed+=("$stack (clean build failed)")
    fi

    echo "=== $stack (cached) ==="
    if ! measure "$stack" "cached"; then
        failed+=("$stack (cached build failed)")
    fi
done

if [ "${#failed[@]}" -ne 0 ]; then
    echo "Some builds failed:" >&2
    for failure in "${failed[@]}"; do
        echo "  - $failure" >&2
    done
    exit 1
fi

echo "All builds succeeded. Results are in $OUTPUT."
