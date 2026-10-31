#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
APP_NAME="BPC E-bill Reconciler SwiftUI"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/BUILD}"
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$SCRIPT_DIR/$OUTPUT_DIR"
fi
APP_PATH="${APP_PATH:-$OUTPUT_DIR/$APP_NAME.app}"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "Verification requires macOS 14 or later."
fi
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if (( MACOS_MAJOR < 14 )); then
    fail "macOS 14 or later is required (found $MACOS_VERSION)."
fi
command -v codesign >/dev/null 2>&1 || fail "Required tool not found: codesign."
command -v plutil >/dev/null 2>&1 || fail "Required tool not found: plutil."
command -v lipo >/dev/null 2>&1 || fail "Required tool not found: lipo."
[[ -d "$APP_PATH" ]] || fail "App bundle not found: $APP_PATH"
[[ -f "$APP_PATH/Contents/Info.plist" ]] || fail "Missing app Info.plist in $APP_PATH"
[[ -x "$APP_PATH/Contents/MacOS/$APP_NAME" ]] || fail "Missing or non-executable app binary in $APP_PATH"

plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null ||
    fail "The app's Info.plist is invalid."
codesign --verify --deep --strict --verbose=2 "$APP_PATH" ||
    fail "The app's code signature is invalid."
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")" ||
    fail "Could not inspect the app executable architectures."
printf 'Verified: %s\nArchitectures: %s\n' "$APP_PATH" "$ARCHS"
