#!/usr/bin/env bash
# Builds build/MCP Manager.app. Pass --install to copy it to ~/Applications.
# Never launches the app: a launch reads and writes the real Claude/Codex configs.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO/build"
APP_BUNDLE="$BUILD_DIR/MCP Manager.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
APP_DEST="$HOME/Applications/MCP Manager.app"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help)
            echo "usage: $0 [--install]"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

echo "==> Scaffolding $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$REPO/Info.plist" "$CONTENTS/Info.plist"

echo "==> Generating icon"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

SVG_SOURCE="$REPO/assets/mcp-manager-icon.svg"
ICON_PNG="$WORKDIR/icon-1024.png"
RSVG="$(command -v rsvg-convert || true)"
if [[ -z "$RSVG" && -x /opt/homebrew/bin/rsvg-convert ]]; then
    RSVG=/opt/homebrew/bin/rsvg-convert
fi

if [[ -n "$RSVG" ]]; then
    "$RSVG" -w 1024 -h 1024 "$SVG_SOURCE" -o "$ICON_PNG"
elif command -v qlmanage >/dev/null 2>&1; then
    qlmanage -t -s 1024 -o "$WORKDIR" "$SVG_SOURCE" >/dev/null 2>&1 || true
    if [[ -f "$WORKDIR/$(basename "$SVG_SOURCE").png" ]]; then
        mv "$WORKDIR/$(basename "$SVG_SOURCE").png" "$ICON_PNG"
    fi
fi

if [[ -f "$ICON_PNG" ]]; then
    ICONSET="$WORKDIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
else
    echo "NOTE: no SVG renderer found; the app will use the default icon"
fi

echo "==> Compiling Swift sources"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    "$REPO"/Sources/Core/*.swift "$REPO"/Sources/App/*.swift \
    -o "$MACOS_DIR/MCPManager"

echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP_BUNDLE"

if [[ "$INSTALL" == 1 ]]; then
    echo "==> Installing to $APP_DEST"
    rm -rf "$APP_DEST"
    mkdir -p "$(dirname "$APP_DEST")"
    ditto "$APP_BUNDLE" "$APP_DEST"
    echo "==> Installed: $APP_DEST"
else
    echo "==> Built: $APP_BUNDLE (run with --install to copy to ~/Applications)"
fi
