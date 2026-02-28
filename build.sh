#!/usr/bin/env bash
set -euo pipefail

# ── Toolchain ─────────────────────────────────────────────────────────────────
# Requires the zig-espressif-bootstrap prebuilt binary.
# Download from: https://github.com/kassane/zig-espressif-bootstrap/releases
ZIG_ESPRESSIF_TOOLCHAIN="${HOME}/zig-bootstrap/zig-espressif-bootstrap/out/zig-relsafe-x86_64-linux-musl-baseline"
ZIG_XTENSA="${ZIG_ESPRESSIF_TOOLCHAIN}/zig"

# ── ESP-IDF (informational – not used directly in this baremetal build) ───────
# IDF_PATH is expected to be set in the environment (e.g. from export.sh).
# It is used here only for documentation/reference; chip headers are not linked.
IDF_PATH="${IDF_PATH:-}"

# ── QEMU ──────────────────────────────────────────────────────────────────────
QEMU_BIN="${QEMU_BIN:-${HOME}/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa}"

# ── Validation ────────────────────────────────────────────────────────────────
if [[ ! -x "${ZIG_XTENSA}" ]]; then
    echo "ERROR: zig-espressif not found at: ${ZIG_XTENSA}"
    echo "  Download from https://github.com/kassane/zig-espressif-bootstrap/releases"
    echo "  Expected layout: ${ZIG_ESPRESSIF_TOOLCHAIN}/zig"
    exit 1
fi

echo "Toolchain : ${ZIG_XTENSA}"
echo "Zig version: $("${ZIG_XTENSA}" version)"
if [[ -n "${IDF_PATH}" ]]; then
    echo "IDF_PATH  : ${IDF_PATH}"
else
    echo "IDF_PATH  : (not set – OK for baremetal builds)"
fi
echo ""

# ── Build / run ───────────────────────────────────────────────────────────────
# Special subcommands handled here; everything else is forwarded to zig build.
#
#   run-qemu-esp32    – build qemu-esp32 ELF, then launch QEMU for ESP32
#   run-qemu-esp32s3  – build qemu-esp32s3 ELF, then launch QEMU for ESP32-S3
#   run-qemu          – build both QEMU ELFs, then launch QEMU for ESP32-S3
#   <anything else>   – forwarded to: zig build --summary all [args]

_run_qemu() {
    local chip="$1" machine="$2"
    local elf="zig-out/bin/${chip}_qemu"
    if [[ ! -x "${QEMU_BIN}" ]]; then
        echo "ERROR: qemu-system-xtensa not found at: ${QEMU_BIN}"
        echo "  Install via: ${IDF_PATH:-(IDF_PATH not set)}/tools/idf_tools.py install qemu-xtensa"
        echo "  Or set QEMU_BIN=/path/to/qemu-system-xtensa"
        exit 1
    fi
    echo "Launching: ${QEMU_BIN} -nographic -machine ${machine} -kernel ${elf}"
    exec "${QEMU_BIN}" -nographic -machine "${machine}" -kernel "${elf}"
}

case "${1:-}" in
    run-qemu-esp32)
        "${ZIG_XTENSA}" build qemu-esp32 --summary all "${@:2}"
        _run_qemu esp32 esp32
        ;;
    run-qemu-esp32s3)
        "${ZIG_XTENSA}" build qemu-esp32s3 --summary all "${@:2}"
        _run_qemu esp32s3 esp32s3
        ;;
    run-qemu)
        "${ZIG_XTENSA}" build qemu --summary all "${@:2}"
        _run_qemu esp32s3 esp32s3
        ;;
    *)
        "${ZIG_XTENSA}" build --summary all "$@"
        ;;
esac
