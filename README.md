# Shifty

Work-in-progress time tracker and shift calculator for macOS. Lives in your menu bar.

Built with Zig 0.16. The UI is a native macOS menu bar app (Obj-C/Swift bridge via `menubar.h/m`). Core logic — clock-in/out, timezone handling, time math — is written in Zig.

## Requirements

- [mise](https://mise.jdx.dev/) (manages Zig, ZLS, watchexec)
- macOS (only platform supported right now)

## Getting started

Trust the mise config, then run the watcher:

```sh
mise trust mise.toml
mise run watch
```

The `watch` task rebuilds and reruns on any `.zig`, `.m`, or `.h` file change.

## Project layout

```
src/
  main.zig      # entry point, menu bar event loop
  router.zig    # maps menu actions to handlers
  state.zig     # global app state (timezone, etc.)
  time.zig      # time math
  menubar.h/m   # Obj-C menu bar bridge
platforms/
  macos/        # macOS app bundle
```

## Status

Early. Clock-in and timezone actions wire up end-to-end. Shift calculation and persistence are next.
