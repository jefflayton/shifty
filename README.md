# Shifty

Work-in-progress time tracker and shift calculator for macOS that lives in your menu bar.

The backend logic and builds are done with Zig 0.16. The UI is built with Swift and SwiftUI.

## AI disclosure

AI was used to help build Shifty. Parts of the code, tests, and CI were written with
[Claude Code](https://claude.com/claude-code), and commits it helped write carry a
`Co-Authored-By: Claude` trailer. All changes go through pull requests and CI before they are
merged.

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
`open --env SHIFTY_OPEN_ON_LAUNCH=1 zig-out/Shifty.app`, or `SHIFTY_OPEN_TIMESHEET=1` to open the
timesheet window. Set `SHIFTY_DB` to a scratch path to keep a dev build off your real data.

## Menu bar

Set your shift length, clock-in time (**Now** sets it to the current time), and breaks; Shifty shows
when to clock out. Your shift and alarms are saved, and a shift that ended more than 12 hours ago
rolls over to today without its breaks.

Click **Clock In** to start tracking the shift for real. Once you're clocked in, from the menu
bar, the TUI, or `shifty in`, the popover shows that shift, and changes from any of them show
up in the others within a couple of seconds. **Clock Out** ends it. Until you clock in, the
popover is just a calculator. Alarm rules and the clock-out link are shared the same way.

Under **Tracking**, pick the project you're working on to start a timer. Picking one while the
timer has no project assigns it, time so far included; picking a different project stops the
timer and starts a new one, so earlier time stays with its project. **Stop** stops it. It's the
same timer as `shifty start` and the TUI's, and a break or clock out stops it.

For a break you didn't plan, click **Start Break** when you leave and **End** when you're back.
Until then, the menu bar icon turns into a cup and clock out moves later as the break goes on.

The menu bar shows your clock-out time next to the icon. Under **Settings**, choose what it
shows (clock-out time, time left, or just the icon) and whether Shifty opens at login.

### Alarms

Add alarms from the **+** next to *Alarms*:

- **At clock out**, or **N min before clock out**: these follow your clock-out time, so adding an
  unexpected break moves them later, even re-arming one that already rang.
- **At a set time**: a fixed time of day during your shift.

During a break, alarms that follow clock out wait for it to end, since clock out isn't known
until then. Set-time alarms still ring, so one can remind you when to come back.

When an alarm rings, Shifty plays its alarm sound and shows a window with **Snooze** (5 min) and
**Stop**. A notification is scheduled as a backup in case Shifty isn't running.

To clock out from the alarm, set **Settings → Clock-Out Link…** to your timeclock page. Alarms then
show a **Clock Out** button that opens it and stops the alarm.

### Timesheet and projects

**Open Timesheet…** in the popover (or the Dock icon while it's open) opens Shifty's window. Switch
screens from its toolbar:

- **Timesheet**: a week of tracked time. The strip at the top shows each day's hours by project;
  click a day to jump to it. Add time after the fact with **+**, and edit times, projects, and
  notes in place.
- **Projects**: rename a project by editing its name, click its color to pick another, and delete
  it from the trash button or its right-click menu. Deleting a project keeps its time, with no
  project.

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

### Tracking time

Commands record shifts, breaks, and time per project in a local database that every Shifty
frontend shares: `~/Library/Application Support/Shifty/shifty.db` on macOS,
`$XDG_DATA_HOME/shifty/shifty.db` elsewhere, or `$SHIFTY_DB` if set.

```
status                     What's running: shift, break, timer
in [-s <time>] [-l <len>]  Clock in (default: now, 8h)
out                        Clock out
break                      Start or end a break
start [<project>[/<workspace>]] [-n <note>]
                           Track time. With no project, use the
                           linked Situ repo you're in, if any
stop                       Stop tracking
log [--week]               Time by project, today or the last 7 days
projects                   List projects and their workspaces
project add <name> [--client <name>] [--color <#rrggbb>]
project rename <name> <new name>
project color <name> <#rrggbb|none>
project delete <name>     Its time stays, unassigned
workspace add <project> <name>
clients                    List clients
client add <name>
link <project>[/<workspace>]
                           Link the Situ repo you're in to a project
```

```sh
$ shifty client add Acme
$ shifty project add web --client Acme
$ shifty workspace add web main
$ shifty in -s 9am
Clocked in at 09:00 AM. Clock out at 05:00 PM.
$ shifty start web/main -n "API review"
Tracking web/main since 10:55 AM.
$ shifty log
Fri Oct 30
  10:55 AM – 12:40 PM   1h 45m  web/main  API review
  12:40 PM –      now   3h 15m  internal

By project
   1h 45m  web  (Acme)
   3h 15m  internal

By client
   1h 45m  Acme
   3h 15m  (no client)

   5h 00m  total
```

Starting with no project inside a Situ repo (one with a
`situ.toml`) tracks whatever `shifty link` pointed that repo at.

## TUI

`shifty-tui` opens on your day: the shift and its clock out, what you're tracking, today's
entries, and totals by project and client. It reads the same database as the CLI and reloads
every second, so a `shifty start` in another terminal shows up right away.

| Key | Action |
| --- | --- |
| `s` | Start tracking: type to filter projects and workspaces, `↑`/`↓` to choose, `enter` to start. Inside a linked Situ repo, that repo's project comes first |
| `x` | Stop tracking |
| `n` | Add or edit the running entry's note |
| `b` | Start or end a break |
| `i` / `o` | Clock in now / clock out (asks first) |
| `c` | Open the calculator; `esc` comes back |
| `q` / `ctrl+c` | Quit |

The calculator works out a clock-out time live as you type, starting from the current shift.

| Key | Action |
| --- | --- |
| `tab` / `enter` / `↓` / `ctrl+n` | Next field |
| `shift+tab` / `↑` / `ctrl+p` | Previous field |
| `ctrl+t` | Add a break |
| `ctrl+x` | Remove the focused break |
| `ctrl+c` | Quit |

Invalid fields are outlined in red.
