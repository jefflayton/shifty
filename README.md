# Shifty

Work-in-progress time tracker and shift calculator for macOS that lives in your menu bar.

The backend logic and builds are done with Zig 0.16. The UI is built with Swift and SwiftUI.

## Installation

Download `Shifty.dmg` from the latest release in [Releases](https://github.com/jefflayton/shifty/releases).

The application is currently not properly signed. 

Go to `System Settings -> Privacy & Security -> Security` and click allow for `Shifty.app`.

Or, in your terminal run: 
```sh
xattr -dr com.apple.quarantine /Applications/Shifty.app
```

## Development
### Requirements

- [mise](https://mise.jdx.dev/) (manages Zig, ZLS, watchexec)
- macOS (only platform supported right now)

### Getting started

Trust the mise config, then build and run whichever frontend you're working on:

```sh
mise trust mise.toml
mise run run:macos   # menu bar app (alias: rm)
mise run run:tui     # terminal UI   (alias: rt)
mise run run:cli -- -s 9am -b 12pm 1pm   # CLI (alias: rc)
mise run test        # unit tests   (alias: t)
```

### Building

```sh
zig build macos             # zig-out/Shifty.app
zig build macos -Dbundle    # also zig-out/Shifty.dmg
zig build tui               # zig-out/bin/shifty-tui
zig build cli               # zig-out/bin/shifty
zig build all               # tests + every frontend for this platform
```

## CLI

```
Usage: shifty [options]

  -s, --start <time>         Clock-in time (default: now)
                             e.g. 9:00, 9am, 21:30, "9:30 PM"
  -l, --length <duration>    Shift length (default: 8h)
                             e.g. 8, 7.5, 7:30, 7h30m
  -b, --break <start> <end>  Add a break; repeatable
                             e.g. -b 12pm 12:30pm
```

```sh
$ shifty -s 9am -b 12pm 12:30pm
Clock Out: 05:30 PM
```

## TUI

`shifty-tui` calculates the clock-out time live as you type.

| Key | Action |
| --- | --- |
| `tab` / `enter` / `↓` / `ctrl+n` | Next field |
| `shift+tab` / `↑` / `ctrl+p` | Previous field |
| `ctrl+t` | Add a break |
| `ctrl+x` | Remove the focused break |
| `ctrl+c` | Quit |

Invalid fields are outlined in red.
