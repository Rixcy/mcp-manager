#!/usr/bin/env bash
# Builds "MCP Manager.app", installs it to ~/Applications and puts the
# `mcp-manager` command on your PATH. Pass --build-only to stop after the build.
# Never launches the app: a launch reads and writes the real Claude/Codex configs.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO/build"
APP_BUNDLE="$BUILD_DIR/MCP Manager.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
APP_DEST="$HOME/Applications/MCP Manager.app"
BIN_DIR="${MCP_MANAGER_BIN_DIR:-$HOME/.local/bin}"
BUNDLE_ID="com.rickbooth.mcp-manager"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --build-only) INSTALL=0 ;;
        -h|--help)
            echo "usage: $0 [--build-only]"
            echo "  installs the app to ~/Applications and the mcp-manager command to \$MCP_MANAGER_BIN_DIR (default ~/.local/bin)"
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

if [[ "$INSTALL" == 0 ]]; then
    echo "==> Built: $APP_BUNDLE"
    exit 0
fi

# A running copy would keep serving `mcp-manager open` from the old binary.
if pgrep -qf "^$APP_DEST/Contents/MacOS/MCPManager"; then
    echo "==> Quitting the running MCP Manager"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
fi

echo "==> Installing app to $APP_DEST"
rm -rf "$APP_DEST"
mkdir -p "$(dirname "$APP_DEST")"
ditto "$APP_BUNDLE" "$APP_DEST"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_DEST"
fi

echo "==> Installing mcp-manager to $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 0755 "$REPO/bin/mcp-manager" "$BIN_DIR/mcp-manager"

echo "==> Installed. Open it with: mcp-manager open"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "NOTE: $BIN_DIR is not on your PATH. Add it, or run $BIN_DIR/mcp-manager open" ;;
esac
