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

Builds are dev builds unless you pass `-Drelease`, so you can test a branch next to the installed
app without touching its data:

- The TUI, CLI, and app share `~/Library/Application Support/Shifty Dev/shifty.db` instead of the
  real database. A branch's migration can't upgrade the database the installed app reads.
- The app is "Shifty Dev" (`com.jeffreylayton.shifty.dev`), with its own settings, login item,
  notifications, and log (`~/Library/Logs/Shifty Dev`), and no update feed.

Set `SHIFTY_DB` to use another database. `-Drelease` builds use the real one and the real bundle
id; the release workflow builds with it.

Set `SHIFTY_OPEN_ON_LAUNCH=1` to open the menu bar popover at launch, e.g.
`open --env SHIFTY_OPEN_ON_LAUNCH=1 zig-out/Shifty.app`, or `SHIFTY_OPEN_TIMESHEET=1` to open the
timesheet window.

## Menu bar

Set your shift length, clock-in time (**Now** sets it to the current time), and breaks; Shifty shows
when to clock out. Your shift and alarms are saved, and a shift that ended more than 12 hours ago
rolls over to today, with today's [scheduled breaks](#scheduled-breaks) instead of yesterday's.

Click **Clock In** to start tracking the shift for real. Once you're clocked in, from the menu
bar, the TUI, or `shifty in`, the popover shows that shift, and changes from any of them show
up in the others within a couple of seconds. **Clock Out** ends it. Until you clock in, the
popover is just a calculator. Alarm rules and the clock links are shared the same way.

With a [clock link](#alarms) set, **Clock In** and **Clock Out** also offer to open it, so you can
punch your timeclock too. Choose **Always** or **Never** in Settings, or tick **Don't ask again**
in the prompt.

Under **Tracking**, pick the project you're working on to start a timer. Picking one while the
timer has no project assigns it, time so far included; picking a different project stops the
timer and starts a new one, so earlier time stays with its project. **Stop** stops it. It's the
same timer as `shifty start` and the TUI's, and a break or clock out stops it. A planned break,
like a [scheduled one](#scheduled-breaks), stops it where the break begins, even if no Shifty was
open then; a timer you start during the break keeps running.

For a break you didn't plan, click **Start Break** when you leave and **End Break** when you're back.
Until then, the menu bar icon turns into a cup and clock out moves later as the break goes on.

The menu bar shows your clock-out time next to the icon. **Settings…** (⌘,) opens the Settings
window. **General**: the days you work, what the menu bar shows (clock-out time, time left, time
until your next break, or just the icon), and whether Shifty opens at login. **Breaks**: the lunch
window and scheduled breaks. **Clock Links**: the links Clock In and Clock Out open.

Stay past clock out while you're clocked in, and Shifty counts the time over: **Time Left** (and
**Time Until Break**, with no break left) reads `+25m`, and the popover shows how far over you
are, with the time past the end on the shift bar. **Clock-Out Time** keeps showing the time; pick
**Clock-Out Time, Then Time Over** to see the clock-out time until you pass it and `+25m` after.

### Scheduled breaks

For a break at the same time on the same days, like a class on Tuesdays and Thursdays from 11 to
2, add it under **Scheduled Breaks** in Settings: a name, the days, and the times. When a new day's
shift starts (the popover rolling over to today, the TUI's clock in, or `shifty in`), it goes on
the shift as an ordinary break and pushes clock out later. To skip or move it for one day, edit or
remove that break in the popover or on the timesheet. A break that would start after clock out
isn't added, and one already underway when you clock in counts from clock in. Changes apply from
the next day's shift; to put one on today's shift too, click **Add to Today** beside it (shown
while it fits: it's for today, isn't over, and doesn't overlap a break you already have).

With **Time Until Break** in the menu bar, Shifty counts down to the next break, then to the end
of the one you're on; with no break left, it shows the time left. During a planned break the icon
turns into a cup, as it does for one you start yourself.

### Lunch window

Some jobs require lunch within a window of work. In California, for example, a 30-minute meal
break has to start before the end of the fifth hour. The lunch window is a break preset like a
scheduled break, kept in the shared database, but it adds no break: it's what Shifty checks your
breaks against. Turn on **Lunch window** in Settings and set
when it opens and closes, counted in time worked (3h and 5h by default), and how long a break has
to be to count as lunch (30 min). Shorter breaks before lunch push the window later.

On a shift long enough to need lunch, the popover's shift bar highlights the window until you
take it, then tints the break that was lunch. Add lunch alarms from the **+** next to *Alarms*:
**When lunch opens**, or **N min before lunch closes**. Adding one turns the lunch window on. They
ring until you've had lunch: going on a break quiets them, and a break shorter than lunch brings
them back. The timesheet shows the window on each day
and flags a lunch that started late or never happened.

### Alarms

Add alarms from the **+** next to *Alarms*:

- **At clock out**, or **N min before clock out**: these follow your clock-out time, so adding an
  unexpected break moves them later, even re-arming one that already rang.
- **At a set time**: a fixed time of day during your shift.
- **N min before a break**, or **When a break ends** (or N min before): these ring for each
  planned break on your shift, like a [scheduled one](#scheduled-breaks), so you leave for class
  on time and know when you're due back.
- **When lunch opens**, or **N min before lunch closes**: see [Lunch window](#lunch-window).

During a break, alarms that follow clock out wait for it to end, since clock out isn't known
until then. Set-time alarms still ring, so one can remind you when to come back.

When an alarm rings, Shifty plays its alarm sound and shows a window with **Snooze** and
**Stop**. Snooze waits 5 minutes unless you change it under **Alarms** in **Settings…** (1 to 60
minutes, kept in the `snooze_secs` setting). A notification is scheduled as a backup in case
Shifty isn't running.

To clock out from the alarm, set the clock link in **Settings…** to your timeclock page. Alarms
then show a **Clock Out** button that opens it and stops the alarm. If you clock in somewhere else,
turn on **Separate clock-in link**; the TUI and CLI read it from the `clock_in_link` setting, and
without it clocking in uses the clock-out link (`clock_out_link`).

### Timesheet and projects

**Open Timesheet…** in the popover (or the Dock icon while it's open) opens Shifty's window. Pick
Timesheet or Projects in its sidebar (⌘1, ⌘2).

- **Timesheet**: a week of shifts and tracked time. The strip at the top shows each day's hours
  by project inside the time you were on shift; click a day to jump to it. A day's shift sits
  on top: clock in and out and time worked (and how far past the shift's length, like `+25m`),
  over a timeline where project time is laid on the shift, so time on shift that no project has
  shows as bare shift. Below it, the day's entries and breaks are rows in the order they started.
  Page weeks with the toolbar's arrows (⌘← ⌘→) and **Today** (⌘T); the week's totals by shift,
  project, and client are in the inspector (⌥⌘I). **Clock Out** ends the shift you're on.
  - **Edit in place**: click an hour or minute and type, or use the arrow keys. Every change,
    deletes included, can be undone (⌘Z) and redone (⇧⌘Z).
  - **Keyboard**: click a row to select it, then ↑/↓ moves between rows, Return edits its start
    time, Delete deletes it, ⌘C copies it, and Esc clears the selection.
  - **Add** time, a forgotten shift, or a break with the toolbar's **+** (on the selected row's
    day, else today) or the **+** that shows on a day's header when you point at it.
  - Click a day's header to open it or fold it down to its total (Option-click folds or opens
    every day); every day but today starts folded, and clicking a day in the strip opens it.
- **Days you work**: pick them from the toolbar's calendar menu, or in Settings. Other days are
  hidden unless they have time on them.
- **Projects**: add one with the toolbar's **+** (⌘N), rename a project by editing its name, click
  its color to pick another, and delete it from the trash button, its right-click menu, or Delete. Deleting a project keeps its time, with no
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
in [-s <time>] [-l <len>]  Clock in (default: now, 8h), with the
                           day's scheduled breaks
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
