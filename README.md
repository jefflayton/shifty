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
zig build test-macos        # menu bar app model tests (macOS only)
```

Set `SHIFTY_OPEN_ON_LAUNCH=1` to open the menu bar popover at launch, e.g.
`open --env SHIFTY_OPEN_ON_LAUNCH=1 zig-out/Shifty.app`.

## Menu bar

Set your shift length, clock-in time (**Now** sets it to the current time), and breaks; Shifty shows
when to clock out. Your shift and alarms are saved, and a shift that ended more than 12 hours ago
rolls over to today without its breaks.

### Alarms

Add alarms from the **+** next to *Alarms*:

- **At clock out**, or **N min before clock out**: these follow your clock-out time, so adding an
  unexpected break moves them later, even re-arming one that already rang.
- **At a set time**: a fixed time of day during your shift.

When an alarm rings, Shifty plays its alarm sound and shows a window with **Snooze** (5 min) and
**Stop**. A notification is scheduled as a backup in case Shifty isn't running.

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
