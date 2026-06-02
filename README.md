# Shifty

Work-in-progress time tracker and shift calculator for macOS that lives in your menu bar.

The backend logic and builds are done with Zig 0.16. The UI is built with Swift and SwiftUI.

## Installation

Download `Shifty.dmg` from the latest release in [Releases](https://codeberg.org/jefflayton/shifty/releases).

## Development
### Requirements

- [mise](https://mise.jdx.dev/) (manages Zig, ZLS, watchexec)
- macOS (only platform supported right now)

### Getting started

Trust the mise config, then run the watcher:

```sh
mise trust mise.toml
mise watch -w src/ build run
```

The `watch` task rebuilds and reruns on any `.zig`, `.m`, or `.h` file change.

### Building

You can build the app on macOS with:

```sh
mise run build
```

This generates `Shifty.app` in `platform/macos` and `Shifty.dmg` in the project root.
