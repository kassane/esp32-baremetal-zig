#!/usr/bin/env bash
set -euo pipefail

# ── Toolchain ─────────────────────────────────────────────────────────────────
# Requires the zig-espressif-bootstrap prebuilt binary.
# Download from: https://github.com/kassane/zig-espressif-bootstrap/releases
#
# Resolution order: $ZIG override → `zig` already on PATH → bootstrap prefix.
# This lets the script work unchanged in CI/containers (zig on PATH) and on a
# dev box that only has the prebuilt fork unpacked at the default location.
ZIG_BOOTSTRAP_PREFIX="${HOME}/zig-bootstrap/zig-espressif-bootstrap/out/zig-relsafe-x86_64-linux-musl-baseline"
if [[ -n "${ZIG:-}" ]]; then
    ZIG_XTENSA="${ZIG}"
elif command -v zig >/dev/null 2>&1; then
    ZIG_XTENSA="$(command -v zig)"
else
    ZIG_XTENSA="${ZIG_BOOTSTRAP_PREFIX}/zig"
fi

# Seconds each chip is booted in QEMU during `smoke` (firmware loops forever,
# so a clean run is one that is still executing when the timeout fires).
SMOKE_SECONDS="${SMOKE_SECONDS:-5}"

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
    echo "  Then either add its dir to PATH, set ZIG=/path/to/zig, or unpack it at:"
    echo "    ${ZIG_BOOTSTRAP_PREFIX}/zig"
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
#   smoke             – build both QEMU ELFs, boot each in QEMU and assert no
#                       CPU errors (non-interactive; used by CI)
#   <anything else>   – forwarded to: zig build --summary all [args]

_require_qemu() {
    if [[ ! -x "${QEMU_BIN}" ]]; then
        echo "ERROR: qemu-system-xtensa not found at: ${QEMU_BIN}"
        echo "  Install via: ${IDF_PATH:-(IDF_PATH not set)}/tools/idf_tools.py install qemu-xtensa"
        echo "  Or set QEMU_BIN=/path/to/qemu-system-xtensa"
        exit 1
    fi
}

_run_qemu() {
    local chip="$1" machine="$2"
    local elf="zig-out/bin/${chip}_qemu"
    _require_qemu
    echo "Launching: ${QEMU_BIN} -nographic -machine ${machine} -kernel ${elf}"
    exec "${QEMU_BIN}" -nographic -machine "${machine}" -kernel "${elf}"
}

# Non-interactive boot test: run the firmware for SMOKE_SECONDS and fail if the
# CPU reports any fault or if QEMU exits on its own (the blink loop never ends,
# so "still running at timeout" — rc 124 — is the success case).
_smoke_qemu() {
    local chip="$1" machine="$2"
    local elf="zig-out/bin/${chip}_qemu"
    [[ -x "${elf}" ]] || { echo "ERROR: ${elf} missing (run: $0 qemu)"; exit 1; }
    local log rc
    log="$(mktemp)"
    echo "Smoke-testing ${chip} in QEMU for ${SMOKE_SECONDS}s ..."
    set +e
    timeout "${SMOKE_SECONDS}" "${QEMU_BIN}" -nographic -machine "${machine}" \
        -kernel "${elf}" -d guest_errors,unimp >"${log}" 2>&1
    rc=$?
    set -e
    if grep -qiE 'exception|guest_errors|unimplemented|illegal' "${log}"; then
        echo "FAIL: ${chip} reported CPU errors:"; sed 's/^/  /' "${log}"; rm -f "${log}"; exit 1
    fi
    if [[ "${rc}" -ne 124 ]]; then
        echo "FAIL: ${chip} QEMU exited early (rc=${rc}); firmware should loop forever:"
        sed 's/^/  /' "${log}"; rm -f "${log}"; exit 1
    fi
    echo "PASS: ${chip} booted and ran ${SMOKE_SECONDS}s with no CPU errors."
    rm -f "${log}"
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
    smoke)
        "${ZIG_XTENSA}" build qemu --summary all "${@:2}"
        _require_qemu
        _smoke_qemu esp32 esp32
        _smoke_qemu esp32s3 esp32s3
        echo "All QEMU smoke tests passed."
        ;;
    *)
        "${ZIG_XTENSA}" build --summary all "$@"
        ;;
esac
