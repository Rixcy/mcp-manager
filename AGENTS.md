# Agent notes

The user works on this Mac while agents test the app. Never put a window on their screen or take focus:

- Screenshot the UI with `bin/capture <out-dir> [scene...]`. Add a scene in `Tools/Capture/main.swift` when a page is missing.
- Do not run `mcp-manager open`, launch `MCP Manager.app` or its binary, use `open -a`, or drive the app with `osascript`. A launch also reads and writes the real Claude and Codex configs.
- Do not write ad-hoc harnesses that call `makeKeyAndOrderFront`, `NSApp.activate` or `setActivationPolicy(.regular)`.
- `bin/test` runs the core tests headless.
