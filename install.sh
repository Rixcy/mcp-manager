#!/usr/bin/env bash
# Installs or updates MCP Manager. Run it again any time to update.
#
#   curl -fsSL https://raw.githubusercontent.com/rixcy/mcp-manager/main/install.sh | bash
#
# Piped from curl, it keeps a clone in ~/.local/share/mcp-manager, pulls the
# latest main and rebuilds only when something changed. Run from a checkout
# (./install.sh), it builds that checkout as it is.
#
# Options: --build-only (stop after building build/MCP Manager.app), --force
# (rebuild even when up to date).
# Env: MCP_MANAGER_REPO, MCP_MANAGER_SRC, MCP_MANAGER_APP_DIR, MCP_MANAGER_BIN_DIR.
#
# Everything sits inside main so a partial download never runs half a script.
set -euo pipefail

REPO_URL="${MCP_MANAGER_REPO:-https://github.com/rixcy/mcp-manager.git}"
SRC_DIR="${MCP_MANAGER_SRC:-$HOME/.local/share/mcp-manager}"
APP_DIR="${MCP_MANAGER_APP_DIR:-$HOME/Applications}"
BIN_DIR="${MCP_MANAGER_BIN_DIR:-$HOME/.local/bin}"
BUNDLE_ID="com.rickbooth.mcp-manager"
# A private or missing repo fails at once instead of waiting for a password.
export GIT_TERMINAL_PROMPT=0
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

say() { printf '==> %s\n' "$*"; }
die() { printf 'mcp-manager install: %s\n' "$*" >&2; exit 1; }

check_requirements() {
    [[ "$(uname -s)" == "Darwin" ]] || die "MCP Manager is a macOS app."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    (( major >= 14 )) || die "macOS 14 or later is required (this Mac has $(sw_vers -productVersion))."
    if ! xcrun --find swiftc >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        die "Xcode Command Line Tools are needed to build it. Run: xcode-select --install, then run this again."
    fi
}

# Prints the source folder to build. A checkout builds itself; otherwise the
# managed clone is created or moved to the latest main.
fetch_source() {
    local self="${BASH_SOURCE[0]:-}"
    if [[ -f "$self" && -f "$(dirname "$self")/Sources/App/MCPManagerApp.swift" ]]; then
        (cd "$(dirname "$self")" && pwd)
        return
    fi
    if [[ -d "$SRC_DIR/.git" ]]; then
        say "Fetching the latest MCP Manager" >&2
        git -C "$SRC_DIR" fetch --quiet --depth 1 origin main >&2
        # The clone is managed by this script, so it always matches origin.
        git -C "$SRC_DIR" reset --quiet --hard FETCH_HEAD >&2
    else
        [[ -e "$SRC_DIR" ]] && die "$SRC_DIR exists but is not a git clone. Move it aside or set MCP_MANAGER_SRC."
        say "Downloading MCP Manager to $SRC_DIR" >&2
        mkdir -p "$(dirname "$SRC_DIR")"
        git clone --quiet --depth 1 --branch main "$REPO_URL" "$SRC_DIR" >&2
    fi
    printf '%s\n' "$SRC_DIR"
}

make_icon() {
    local repo="$1" resources="$2" workdir="$3"
    local svg="$repo/assets/mcp-manager-icon.svg" png="$workdir/icon-1024.png"
    local rsvg
    rsvg="$(command -v rsvg-convert || true)"
    if [[ -n "$rsvg" ]]; then
        "$rsvg" -w 1024 -h 1024 "$svg" -o "$png"
    else
        qlmanage -t -s 1024 -o "$workdir" "$svg" >/dev/null 2>&1 || true
        [[ -f "$workdir/$(basename "$svg").png" ]] && mv "$workdir/$(basename "$svg").png" "$png"
    fi
    if [[ ! -f "$png" ]]; then
        echo "NOTE: no SVG renderer found; the app will use the default icon"
        return
    fi
    local iconset="$workdir/AppIcon.iconset" size double
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        double=$((size * 2))
        sips -z "$size" "$size" "$png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -z "$double" "$double" "$png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
}

build_app() {
    local repo="$1" commit="$2" workdir="$3"
    local bundle="$repo/build/MCP Manager.app"
    local contents="$bundle/Contents"
    say "Building MCP Manager ($commit)"
    rm -rf "$bundle"
    mkdir -p "$contents/MacOS" "$contents/Resources"
    cp "$repo/Info.plist" "$contents/Info.plist"
    printf '%s\n' "$commit" > "$contents/Resources/source-commit"
    make_icon "$repo" "$contents/Resources" "$workdir"
    swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" \
        "$repo"/Sources/Core/*.swift "$repo"/Sources/App/*.swift \
        -o "$contents/MacOS/MCPManager"
    # Ad-hoc signed: built on this Mac, so Gatekeeper never quarantines it.
    codesign --force --sign - "$bundle" 2>/dev/null
}

install_app() {
    local repo="$1"
    local dest="$APP_DIR/MCP Manager.app"
    # A running copy would keep serving `mcp-manager open` from the old binary.
    local was_running=0
    if pgrep -qf "^$dest/Contents/MacOS/MCPManager"; then
        was_running=1
        say "Quitting the running MCP Manager"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        sleep 1
    fi
    say "Installing the app to $dest"
    mkdir -p "$APP_DIR"
    rm -rf "$dest"
    ditto "$repo/build/MCP Manager.app" "$dest"
    [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$dest"

    say "Installing the mcp-manager command to $BIN_DIR"
    mkdir -p "$BIN_DIR"
    install -m 0755 "$repo/bin/mcp-manager" "$BIN_DIR/mcp-manager"

    if (( was_running )); then
        open -a "$dest"
    fi
}

main() {
    local build_only=0 force=0 arg
    for arg in "$@"; do
        case "$arg" in
            --build-only) build_only=1 ;;
            --force) force=1 ;;
            -h|--help)
                sed -n '2,13p' "${BASH_SOURCE[0]}" 2>/dev/null | sed 's/^# \{0,1\}//'
                return 0
                ;;
            *) die "unknown option: $arg" ;;
        esac
    done

    check_requirements
    local repo commit installed=""
    repo="$(fetch_source)"
    commit="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
        commit="$commit-dirty"
    fi

    local dest="$APP_DIR/MCP Manager.app"
    [[ -f "$dest/Contents/Resources/source-commit" ]] && installed="$(<"$dest/Contents/Resources/source-commit")"
    if (( !build_only && !force )) && [[ "$installed" == "$commit" && "$commit" != *-dirty && -x "$BIN_DIR/mcp-manager" ]]; then
        say "MCP Manager is up to date ($commit). Open it with: mcp-manager open"
        return 0
    fi

    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT
    build_app "$repo" "$commit" "$WORKDIR"
    if (( build_only )); then
        say "Built: $repo/build/MCP Manager.app"
        return 0
    fi
    install_app "$repo"

    if [[ -n "$installed" ]]; then
        say "Updated MCP Manager ($installed -> $commit). Open it with: mcp-manager open"
    else
        say "Installed MCP Manager ($commit). Open it with: mcp-manager open"
    fi
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo "NOTE: $BIN_DIR is not on your PATH. Add it, or run: $BIN_DIR/mcp-manager open" ;;
    esac
}

main "$@"
