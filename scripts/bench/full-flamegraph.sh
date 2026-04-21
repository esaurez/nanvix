#!/bin/bash
# Full end-to-end Nanvix flamegraph: Guest + Host (VMM + OS Kernel)
#
# Generates a single unified flamegraph with two root frames:
#   [GUEST]: Nanvix kernel + user app via 1kHz signal-based sampling
#   [HOST]:  nanvixd VMM + OS kernel via perf record
#
# Guest stacks are captured by the built-in profiler timer which
# sends SIGUSR1 to the vCPU thread and walks the frame-pointer
# chain through guest memory. Host stacks are captured by perf
# record (started automatically by nanvixd). Both sample at the
# same configurable frequency (NANVIX_PROFILER_FREQ_HZ, default
# 1kHz).
#
# Usage:
#   ./full-flamegraph.sh
#   ./full-flamegraph.sh --guest-elf /path/to/app.elf --user-symbols /path/to/app.elf.sym
#
# Requirements:
#   - nanvixd built with: z build --profile --release -- DEPLOYMENT_MODE=standalone
#   - cargo install inferno rustfilt
#   - perf (for host stacks; optional)

set -euo pipefail

# Defaults
NANVIX_DIR="${NANVIX_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
GUEST_ELF="${GUEST_ELF:-}"
KERNEL_SYMBOLS="${KERNEL_SYMBOLS:-$NANVIX_DIR/bin/kernel.elf}"
USER_SYMBOLS="${USER_SYMBOLS:-}"
SCRIPT="${SCRIPT:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./profiling-output}"
RAMFS_IMG="${RAMFS_IMG:-}"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --nanvix-dir) NANVIX_DIR="$2"; shift 2 ;;
        --guest-elf) GUEST_ELF="$2"; shift 2 ;;
        --kernel-symbols) KERNEL_SYMBOLS="$2"; shift 2 ;;
        --user-symbols) USER_SYMBOLS="$2"; shift 2 ;;
        --script) SCRIPT="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --ramfs) RAMFS_IMG="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

NANVIXD="$NANVIX_DIR/target/release-profiling/nanvixd"
MKRAMFS="$NANVIX_DIR/bin/mkramfs.elf"
if [ ! -x "$NANVIXD" ]; then
    NANVIXD="$NANVIX_DIR/bin/nanvixd"
fi

mkdir -p "$OUTPUT_DIR"

GUEST_FOLDED="$OUTPUT_DIR/guest.folded"
MERGED_FOLDED="$OUTPUT_DIR/merged.folded"
SVG_PATH="$OUTPUT_DIR/flamegraph.svg"
STDERR_PATH="$OUTPUT_DIR/nanvixd-stderr.txt"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Nanvix Full E2E Flamegraph (Guest + Host) — Linux/KVM    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Build ramfs if needed
CLEANUP_RAMFS=false
if [ -z "$RAMFS_IMG" ] || [ ! -f "$RAMFS_IMG" ]; then
    RAMFS_DIR="$OUTPUT_DIR/ramfs-content"
    mkdir -p "$RAMFS_DIR"

    if [ -z "$GUEST_ELF" ]; then
        echo "ERROR: --guest-elf is required (or set GUEST_ELF env var)"
        exit 1
    fi
    cp "$GUEST_ELF" "$RAMFS_DIR/$(basename "$GUEST_ELF")"

    if [ -z "$SCRIPT" ]; then
        SCRIPT='import math
for i in range(200):
    result = sum(math.factorial(j) for j in range(200))
    print(f"iter {i}: {len(str(result))} digits")
print("Done")'
    fi
    echo "$SCRIPT" > "$RAMFS_DIR/script.py"

    RAMFS_IMG="$OUTPUT_DIR/test.img"
    "$MKRAMFS" -o "$RAMFS_IMG" "$RAMFS_DIR"
    CLEANUP_RAMFS=true
    echo "  Ramfs: $RAMFS_IMG"
fi

# Set profiler env vars
export NANVIX_GUEST_PROFILE="$GUEST_FOLDED"
export NANVIX_KERNEL_SYMBOLS="$KERNEL_SYMBOLS"
[ -n "$USER_SYMBOLS" ] && export NANVIX_USER_SYMBOLS="$USER_SYMBOLS"

# Run nanvixd
echo "[RUN] Running nanvixd with profiling..."
rm -f "$GUEST_FOLDED"*
"$NANVIXD" -bin-dir "$NANVIX_DIR/bin" -ramfs "$RAMFS_IMG" \
    -- "${GUEST_ELF:-$NANVIX_DIR/bin/hello-rust-nostd.elf}" "-B /script.py" \
    2>"$STDERR_PATH" || true

echo ""
grep -E "GUEST_PROFILE|PROFILER|PERF_SESSION" "$STDERR_PATH" || true

# Find perf.data
PERF_DATA="$GUEST_FOLDED.perf.data"

# Merge stacks
echo ""
echo "[MERGE] Building unified flamegraph..."

# Guest stacks → [GUEST] prefix
if [ -s "$GUEST_FOLDED" ]; then
    cat "$GUEST_FOLDED" | rustfilt | \
        sed 's/</ /g; s/>/ /g; s/+0x[0-9a-f]*//g' | \
        sed 's/^/[GUEST];/' > "$MERGED_FOLDED"
    GUEST_COUNT=$(wc -l < "$MERGED_FOLDED")
    echo "  [GUEST]: $GUEST_COUNT stack entries"
else
    echo "  WARNING: No guest stacks (workload may be too short)"
    : > "$MERGED_FOLDED"
fi

# Host stacks from perf → [HOST] prefix
if [ -f "$PERF_DATA" ] && command -v perf &>/dev/null; then
    echo "  Extracting host stacks from perf.data..."
    KERNEL_FOLDED="$OUTPUT_DIR/kernel.folded"
    perf script -i "$PERF_DATA" 2>/dev/null | \
        inferno-collapse-perf 2>/dev/null | \
        sed 's/^/[HOST];/' > "$KERNEL_FOLDED" 2>/dev/null || true

    if [ -s "$KERNEL_FOLDED" ]; then
        HOST_COUNT=$(wc -l < "$KERNEL_FOLDED")
        echo "  [HOST]: $HOST_COUNT stack entries"
        cat "$KERNEL_FOLDED" >> "$MERGED_FOLDED"
    else
        echo "  No host stacks (perf may need CAP_SYS_ADMIN)"
    fi
elif [ -f "$PERF_DATA" ]; then
    echo "  perf not available — host stacks skipped"
    echo "  Use: perf report -i $PERF_DATA"
else
    echo "  No perf.data — host stacks skipped"
fi

# Generate SVG
echo "[SVG] Generating flamegraph..."
if [ -s "$MERGED_FOLDED" ]; then
    cat "$MERGED_FOLDED" | inferno-flamegraph \
        --title "Nanvix E2E Flamegraph (Guest + Host) — Linux/KVM" > "$SVG_PATH"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Results                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
ls -lh "$OUTPUT_DIR"/*.{svg,folded,txt} 2>/dev/null | awk '{print "  " $NF ": " $5}'
echo ""
if [ -f "$SVG_PATH" ]; then
    echo "  Flamegraph: $SVG_PATH"
fi

# Cleanup
if $CLEANUP_RAMFS; then
    rm -rf "$OUTPUT_DIR/ramfs-content" "$OUTPUT_DIR/test.img"
fi
