# MCP Manager

A macOS menu bar app that keeps your MCP servers in step across **Claude Code** and **Codex**. Themed with the Orc design system.

- **Global MCPs:** add, rename and remove. Adding writes to Claude and Codex at the same time. A server that only one client has is flagged "Claude only" or "Codex only", with a **Sync** button.
- **Project MCPs:** fuzzy-search any project Claude or Codex knows about (type `reels`, `rls`, …) and see every MCP configured for it.
- **Menu bar:** quick list, sync, project search, and shortcuts into the full window.

## Build and run

```sh
./build.sh            # builds "build/MCP Manager.app"
./build.sh --install  # also copies it to ~/Applications
bin/test              # core tests (real temp files, no mocks)
```

SwiftPM is not used. Everything compiles with plain `swiftc` (macOS 14+, Command Line Tools are enough).

To try the app without touching your real configs, point it at a throwaway home:

```sh
open -n "build/MCP Manager.app" --env MCP_MANAGER_HOME="$(bin/fixture-home "$(mktemp -d)")"
```

## Files it reads and writes

| Where | Claude | Codex |
| --- | --- | --- |
| Global (read + write) | `~/.claude.json` → `mcpServers` | `~/.codex/config.toml` (or `$CODEX_HOME`) → `[mcp_servers.*]` |
| Project (read only) | `~/.claude.json` → `projects[path].mcpServers`, `<project>/.mcp.json` | `<project>/.codex/config.toml` |

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
