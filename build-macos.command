#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
APP_NAME="BPC E-bill Reconciler SwiftUI"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/BUILD}"
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$SCRIPT_DIR"
fi

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "This app can only be built and installed on macOS 14 or later."
fi
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if (( MACOS_MAJOR < 14 )); then
    fail "macOS 14 or later is required (found $MACOS_VERSION)."
fi
for tool in swiftc xcrun codesign ditto plutil; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool. Install Xcode Command Line Tools."
done
[[ -f "$SCRIPT_DIR/BPCApp.swift" ]] || fail "Missing source file: BPCApp.swift"
[[ -f "$SCRIPT_DIR/BPCServices.swift" ]] || fail "Missing source file: BPCServices.swift"
[[ -f "$SCRIPT_DIR/BPCAppInfo.plist" ]] || fail "Missing app metadata: BPCAppInfo.plist"
[[ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]] || fail "Missing app icon: Resources/AppIcon.icns"

mkdir -p -- "$OUTPUT_DIR" || fail "Could not create install directory: $OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
[[ ! -e "$APP_PATH" ]] || fail "Refusing to overwrite existing app bundle: $APP_PATH. Move it yourself or choose another OUTPUT_DIR."

STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.bpc-build-install.XXXXXX")" ||
    fail "Could not create a temporary build directory in $OUTPUT_DIR."
cleanup() {
    if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
}
trap cleanup EXIT

APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$SCRIPT_DIR/BPCAppInfo.plist" "$CONTENTS/Info.plist"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
plutil -lint "$CONTENTS/Info.plist" >/dev/null ||
    fail "The app's Info.plist is invalid."

for arch in arm64 x86_64; do
    printf 'Compiling %s for %s...\n' "$APP_NAME" "$arch"
    swiftc -O -target "$arch-apple-macosx14.0" \
        "$SCRIPT_DIR/BPCApp.swift" "$SCRIPT_DIR/BPCServices.swift" \
        -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers \
        -framework CoreText -framework PDFKit -framework Vision \
        -o "$STAGING_DIR/$arch" ||
        fail "Compilation failed for $arch."
done

xcrun lipo -create "$STAGING_DIR/arm64" "$STAGING_DIR/x86_64" \
    -output "$CONTENTS/MacOS/$APP_NAME" ||
    fail "Could not create the universal app executable."
codesign --force --deep --sign - "$APP_BUNDLE" ||
    fail "Ad-hoc code signing failed."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" ||
    fail "The built app did not pass signature verification."

ditto "$APP_BUNDLE" "$STAGING_DIR/install.app" ||
    fail "Could not stage the verified app for installation."
mv -n -- "$STAGING_DIR/install.app" "$APP_PATH" ||
    fail "Could not move the app into $OUTPUT_DIR."
[[ ! -e "$STAGING_DIR/install.app" && -d "$APP_PATH" ]] ||
    fail "Install destination appeared during installation; the existing bundle was left untouched."
codesign --verify --deep --strict --verbose=2 "$APP_PATH" ||
    fail "Installed app failed signature verification."
printf 'Built, signed, and installed: %s\n' "$APP_PATH"
