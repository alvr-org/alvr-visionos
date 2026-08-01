#!/bin/bash
# Offline macOS harness for the Steam Controller (2026) driver.
#
# Compiles the REAL driver sources from ALVRClient/Input/ rather than a copy,
# so what it exercises is the code that ships on visionOS. Both of the serious
# bugs found so far (a weak CBPeripheral that dropped connections silently, and
# lizard mode being a watchdog rather than a latch) were only visible this way.
#
# Usage:
#   tools/steam-controller-harness/build.sh
#   script -q /dev/null ./tools/steam-controller-harness/steam_harness
#
# Two things that will waste your time otherwise:
#   * Bluetooth needs the calling process to hold a TCC grant. Run it from a
#     Terminal that has one. An agent/sandboxed process gets total silence.
#   * Pipe through `script -q /dev/null` or block-buffered stdout is discarded
#     and it looks identical to a hung delegate.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/ALVRClient/Input"

# Swift only allows top-level statements in a file literally named main.swift.
cp "$HERE/harness_main.swift" "$HERE/main.swift"

swiftc -O \
    "$SRC/InputTypes.swift" \
    "$SRC/SteamControllerDevice.swift" \
    "$HERE/main.swift" \
    -o "$HERE/steam_harness" \
    -framework CoreBluetooth

# Standalone GATT dumper. Independent of the driver on purpose: use it when the
# driver cannot connect at all, or to check whether a characteristic UUID moved.
swiftc -O "$HERE/triton_probe.swift" \
    -o "$HERE/triton_probe" \
    -framework CoreBluetooth

echo "built:"
echo "  $HERE/steam_harness   — exercises the real driver"
echo "  $HERE/triton_probe    — dumps GATT services + raw packet hex"
