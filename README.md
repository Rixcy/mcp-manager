# MCP Manager

A macOS menu bar app that keeps your MCP servers in step across **Claude Code** and **Codex**. Themed with the Orc design system.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/screenshots/main-window-dark.png">
  <img alt="MCP Manager main window listing global MCPs shared by Claude and Codex" src="assets/screenshots/main-window-light.png" width="800">
</picture>

- **Global MCPs:** add, rename and remove. Adding writes to Claude and Codex at the same time. A server that only one client has is flagged "Claude only" or "Codex only", with a **Sync** button.
- **Project MCPs:** fuzzy-search any project Claude or Codex knows about (type `reels`, `rls`, …), see every MCP configured for it, and edit or remove each one in the file it came from.
- **Menu bar:** quick list, sync, project search, and shortcuts into the full window.

## Install and open

```sh
./install.sh        # builds the app, installs it to ~/Applications, adds `mcp-manager` to ~/.local/bin
mcp-manager open    # launches MCP Manager (if needed) and shows its window
bin/test            # core tests (real temp files, no mocks)
```

`./install.sh --build-only` stops after building `build/MCP Manager.app`. Set `MCP_MANAGER_BIN_DIR` to put the command somewhere other than `~/.local/bin`.

SwiftPM is not used. Everything compiles with plain `swiftc` (macOS 14+, Command Line Tools are enough).

To try the app without touching your real configs, point it at a throwaway home:

```sh
MCP_MANAGER_HOME="$(bin/fixture-home "$(mktemp -d)")" mcp-manager open
```

Quit any running copy first: the home is only read at launch.

## Files it reads and writes

| Where | Claude | Codex |
| --- | --- | --- |
| Global (read + write) | `~/.claude.json` → `mcpServers` | `~/.codex/config.toml` (or `$CODEX_HOME`) → `[mcp_servers.*]` |
| Project (edit and remove in place) | `~/.claude.json` → `projects[path].mcpServers`, `<project>/.mcp.json` | `<project>/.codex/config.toml` |

- Before every write, the original file is copied to `~/Library/Application Support/MCP Manager/Backups/`. The newest 20 per file are kept.
- Writes are atomic. If Claude or Codex rewrites the file mid-save, the edit is re-applied, up to 3 attempts.
- Codex TOML is edited in place. Comments and unrelated tables are kept byte for byte.
- Codex has no SSE transport, so an SSE server is added to Claude only, and the app says so.

## Layout

```text
Sources/Core   config models, Claude JSON + Codex TOML stores, fuzzy matcher (Foundation only)
Sources/App    SwiftUI menu bar extra and main window
Tests          swiftc-built test runner for Sources/Core
assets         app icon and logo (Orc-themed)
```
