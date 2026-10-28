#!/usr/bin/env bash
# Profile memory usage for cpp-gtk4 on Linux, into a CSV in
# this folder. Run it from anywhere; it cds to its own folder
# first, like build_linux.sh, so the binary and the CSV are
# always this stack's.
#
# How it gets a process to profile, in order:
#   1. A PID given with --pid (or as the only positional arg).
#   2. A running cpp-gtk4 process, if one is already
#      running. The script will not kill a process it did not
#      start.
#   3. Otherwise it launches ./build/cpp-gtk4 from this folder and
#      profiles it until it exits; if this script is
#      interrupted, it kills the process it launched.
#
# Usage:
#   ./profile_memory_linux.sh [--pid PID] [--interval SECONDS]
#                             [--duration SECONDS] [--output FILE]
#
#   --interval SECONDS  Time between samples. Default: 1.
#                       Fractional values (e.g. 0.5) are allowed.
#   --duration SECONDS  Stop after this many seconds. Without
#                       it, sampling runs until the profiled
#                       process exits (or this script is
#                       interrupted).
#   --output FILE       CSV file. Default: memory_profile.csv
#                       in this folder. The file is appended
#                       to; the header is written only if the
#                       file does not already have content.
#
# Output columns (all memory values in kB, from
# /proc/<pid>/smaps, summed over every mapping, as in the
# smaps script this is based on):
#   timestamp,elapsed_seconds,pid,Size_kB,Rss_kB,Pss_kB,
#   Shared_Clean_kB,Shared_Dirty_kB,Private_Clean_kB,Private_Dirty_kB
#
# What each memory value means:
#   Size           Total virtual address space reserved for
#                  this mapping.
#   Rss            Resident Set Size: amount of this mapping
#                  currently in physical RAM.
#   Pss            Proportional Set Size: shared pages divided
#                  proportionally among processes sharing them.
#   Shared_Clean   Clean (unmodified) pages shared with other
#                  processes (typically shared libraries or
#                  file-backed mappings).
#   Shared_Dirty   Modified pages that are shared between
#                  processes (less common; can occur with
#                  shared writable mappings).
#   Private_Clean  Clean (unmodified) pages only this process
#                  uses. Can be discarded and reloaded from
#                  disk if needed.
#   Private_Dirty  Modified pages only this process uses. Must
#                  be written to swap or otherwise preserved if
#                  reclaimed.
#
# No sudo is used: /proc/<pid>/smaps is readable for your own
# processes. Run the script with sudo only if you are profiling
# a process owned by another user.
set -uo pipefail

# Run from this script's directory, so this works from anywhere.
cd "$(dirname "$0")"

STACK="cpp-gtk4"
BINARY="./build/cpp-gtk4"
BINARY_NAME="cpp-gtk4"
OUTPUT="memory_profile.csv"
INTERVAL=1
DURATION=""
PID=""

usage() {
    echo "Usage: $0 [--pid PID] [--interval SECONDS] [--duration SECONDS] [--output FILE]"
    echo "  Without --pid, profiles a running $BINARY_NAME, or launches $BINARY."
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --pid)
            PID="$2"; shift 2
            ;;
        --interval)
            INTERVAL="$2"; shift 2
            ;;
        --duration)
            DURATION="$2"; shift 2
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
            # A lone positional argument is a PID.
            if [ -n "$PID" ]; then
                echo "Only one PID may be given." >&2
                exit 1
            fi
            PID="$1"; shift
            ;;
    esac
done

case "$PID" in
    ""|*[!0-9]*)
        if [ -n "$PID" ]; then
            echo "PID must be a number: $PID" >&2
            exit 1
        fi
        ;;
esac
case "$INTERVAL" in
    ""|*[!0-9.]*)
        echo "Interval must be a number of seconds: $INTERVAL" >&2
        exit 1
        ;;
esac

# One sample: the seven smaps totals, in the CSV column order,
# comma-separated, from /proc/<pid>/smaps. A field that is
# absent from smaps contributes 0 (awk treats an unset array
# element as 0 in numeric context).
sample() {
    awk '
        /^(Size|Rss|Pss|Shared_Clean|Shared_Dirty|Private_Clean|Private_Dirty):/ {
            sub(/:/, "", $1)
            mem[$1] += $2
        }
        END {
            printf "%d,%d,%d,%d,%d,%d,%d",
                mem["Size"] + 0, mem["Rss"] + 0, mem["Pss"] + 0,
                mem["Shared_Clean"] + 0, mem["Shared_Dirty"] + 0,
                mem["Private_Clean"] + 0, mem["Private_Dirty"] + 0
        }
    ' "/proc/$1/smaps"
}

# Only kill a process this script launched, and only if it is
# still running when the script exits. A process the script
# attached to is left alone. The INT/TERM trap exits (which
# then runs the EXIT trap); without the explicit exit, a
# Ctrl-C during sleep would just resume sampling.
cleanup() {
    if [ "$launched" -eq 1 ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
    fi
}

launched=0
if [ -z "$PID" ]; then
    # Attach to a running instance if there is one. pgrep -x
    # matches the process name exactly, so it cannot pick up
    # this script, a build script, or another stack's binary.
    # If several instances are running, profile the first and
    # say so, rather than silently mixing processes.
    matches=$(pgrep -x "$BINARY_NAME" || true)
    if [ -n "$matches" ]; then
        count=$(printf '%s\n' "$matches" | wc -l)
        if [ "$count" -gt 1 ]; then
            echo "Warning: $count $BINARY_NAME processes running; profiling the first." >&2
        fi
        PID=$(printf '%s\n' "$matches" | head -n 1)
    else
        if [ ! -x "$BINARY" ]; then
            echo "Not running and not built: $BINARY — run ./build_all_linux.sh first." >&2
            exit 1
        fi
        echo "Launching $BINARY for profiling."
        "$BINARY" &
        PID=$!
        launched=1
    fi
fi

trap cleanup EXIT
trap 'exit 130' INT TERM

if ! kill -0 "$PID" 2>/dev/null; then
    echo "No such process: $PID" >&2
    exit 1
fi
if [ ! -r "/proc/$PID/smaps" ]; then
    echo "Cannot read /proc/$PID/smaps (is that process yours?)." >&2
    exit 1
fi

if [ ! -s "$OUTPUT" ]; then
    echo "timestamp,elapsed_seconds,pid,Size_kB,Rss_kB,Pss_kB,Shared_Clean_kB,Shared_Dirty_kB,Private_Clean_kB,Private_Dirty_kB" > "$OUTPUT"
fi

echo "Profiling $STACK (pid $PID) every ${INTERVAL}s into $OUTPUT."
start=$(date +%s)
while kill -0 "$PID" 2>/dev/null; do
    now=$(date +%s)
    elapsed=$((now - start))
    if [ -n "$DURATION" ] && [ "$elapsed" -ge "$DURATION" ]; then
        break
    fi
    if [ ! -r "/proc/$PID/smaps" ]; then
        break
    fi
    values=$(sample "$PID")
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp,$elapsed,$PID,$values" >> "$OUTPUT"
    sleep "$INTERVAL"
done

echo "Done. Samples are in $OUTPUT."
