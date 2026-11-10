#ifndef SHIFTY_H
#define SHIFTY_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
  int64_t in_ts;
  int64_t out_ts;
} ShiftInterval;

int64_t clockIn(int64_t shift, int64_t in_ts, const ShiftInterval *breaks,
                size_t breaks_len);

// ── Store ───────────────────────────────────────────────────────────────────
// The shared database (src/store/ffi.zig). Times are unix seconds. Not
// thread-safe: use a handle from one thread at a time.

typedef enum {
  SHIFTY_OK = 0,
  SHIFTY_NONE = 1, // a read found nothing
  SHIFTY_BUSY = -1,
  SHIFTY_CONFLICT = -2,
  SHIFTY_NOT_FOUND = -3,
  SHIFTY_MISMATCH = -4,
  SHIFTY_CORRUPT = -5,
  SHIFTY_TOO_NEW = -6, // written by a newer Shifty
  SHIFTY_NO_MEMORY = -7,
  SHIFTY_IO = -8,
} ShiftyResult;

typedef struct ShiftyStore ShiftyStore;

typedef struct {
  uint8_t bytes[16];
} ShiftyId;

typedef struct {
  ShiftyId id;
  int64_t in_ts;
  int64_t target_secs;
} ShiftyShift;

typedef struct {
  ShiftyId id;
  int64_t in_ts;
  int64_t out_ts; // meaningless while running
  int32_t running;
} ShiftyBreak;

typedef enum {
  SHIFTY_ALARM_BEFORE_CLOCK_OUT = 0,     // value: minutes before clock out
  SHIFTY_ALARM_AT_TIME = 1,              // value: seconds since local midnight
  SHIFTY_ALARM_WINDOW_OPENS = 2,         // value: unused; preset_id: the window
  SHIFTY_ALARM_BEFORE_WINDOW_CLOSES = 3, // value: minutes before it closes; preset_id
  SHIFTY_ALARM_BEFORE_BREAK = 4,         // value: minutes before each break starts
  SHIFTY_ALARM_BEFORE_BREAK_ENDS = 5,    // value: minutes before each break ends
} ShiftyAlarmKind;

typedef struct {
  ShiftyId id;
  int32_t kind; // ShiftyAlarmKind
  int32_t enabled;
  int64_t value;
  ShiftyId preset_id; // window alarms only; zeros otherwise
} ShiftyAlarmRule;

typedef enum {
  SHIFTY_PRESET_SCHEDULED = 0, // a break at set local times
  SHIFTY_PRESET_WINDOW = 1,    // a break that has to start within time worked, like lunch
} ShiftyPresetKind;

typedef struct {
  ShiftyId id;
  int32_t kind; // ShiftyPresetKind
  int32_t enabled;
  int32_t weekdays; // ISO weekdays: bit 0 is Monday, bit 6 Sunday
  int64_t start_secs, end_secs; // scheduled: local seconds since midnight
  int64_t earliest_secs, latest_secs, minimum_secs; // window: time worked
} ShiftyBreakPreset;

// A NULL path opens the shared default ($SHIFTY_DB, else
// ~/Library/Application Support/Shifty/shifty.db).
ShiftyResult shifty_store_open(const char *path, ShiftyStore **out);
void shifty_store_close(ShiftyStore *store);
// Changes when another process writes.
ShiftyResult shifty_data_version(ShiftyStore *store, int64_t *out);

ShiftyResult shifty_current_shift(ShiftyStore *store, ShiftyShift *out);
// `presets` nonzero puts the day's scheduled break presets on the shift.
ShiftyResult shifty_start_shift(ShiftyStore *store, int64_t in_ts, int64_t target_secs,
                                int32_t presets, ShiftyId *out);
// The breaks the scheduled presets would put on a shift clocking in at
// `in_ts`. Fills up to `cap`; `count` gets the total.
ShiftyResult shifty_scheduled_breaks(ShiftyStore *store, int64_t in_ts, int64_t target_secs,
                                     ShiftInterval *out, size_t cap, size_t *count);
ShiftyResult shifty_edit_shift(ShiftyStore *store, ShiftyId shift_id, int64_t in_ts,
                               int64_t target_secs, int64_t now);
ShiftyResult shifty_end_shift(ShiftyStore *store, int64_t now);
// An ended shift recorded after the fact; its length is out - in.
ShiftyResult shifty_add_shift(ShiftyStore *store, int64_t in_ts, int64_t out_ts, ShiftyId *out);
// Moves an ended shift's clock in and out. SHIFTY_NOT_FOUND for the open shift.
ShiftyResult shifty_set_shift_times(ShiftyStore *store, ShiftyId shift_id, int64_t in_ts,
                                    int64_t out_ts, int64_t now);
// Deletes a shift and its breaks; time tracked during it stays.
ShiftyResult shifty_delete_shift(ShiftyStore *store, ShiftyId shift_id, int64_t now);
// Brings back a deleted shift and the breaks deleted with it. SHIFTY_NOT_FOUND
// unless it's deleted; SHIFTY_CONFLICT if it was open and another shift is.
ShiftyResult shifty_restore_shift(ShiftyStore *store, ShiftyId shift_id, int64_t now);
// Stops the running entry where a planned break on the open shift began after
// it started. SHIFTY_OK if one was stopped, SHIFTY_NONE otherwise.
ShiftyResult shifty_stop_for_breaks(ShiftyStore *store, int64_t now);
// SHIFTY_OK if a forgotten shift was closed, SHIFTY_NONE otherwise.
ShiftyResult shifty_close_stale_shift(ShiftyStore *store, int64_t now);

// Fills up to `cap` breaks; `count` gets the total, which may exceed `cap`.
ShiftyResult shifty_breaks(ShiftyStore *store, ShiftyId shift_id, ShiftyBreak *out, size_t cap,
                           size_t *count);
ShiftyResult shifty_put_break(ShiftyStore *store, ShiftyId break_id, ShiftyId shift_id,
                              int64_t in_ts, int64_t out_ts, int32_t running, int64_t now);
ShiftyResult shifty_delete_break(ShiftyStore *store, ShiftyId break_id, int64_t now);

ShiftyResult shifty_alarm_rules(ShiftyStore *store, ShiftyAlarmRule *out, size_t cap,
                                size_t *count);
ShiftyResult shifty_put_alarm_rule(ShiftyStore *store, ShiftyAlarmRule rule, int64_t now);
ShiftyResult shifty_delete_alarm_rule(ShiftyStore *store, ShiftyId rule_id, int64_t now);

// Break presets, windows first, as a UTF-8 JSON array of {"id","name","kind",
// "enabled","weekdays","start_secs","end_secs","earliest_secs","latest_secs",
// "minimum_secs"} (times null where they don't apply). Release with
// shifty_free.
ShiftyResult shifty_break_presets_json(ShiftyStore *store, char **out, size_t *len);
ShiftyResult shifty_put_break_preset(ShiftyStore *store, ShiftyBreakPreset preset,
                                     const char *name, int64_t now);
// Deletes a break preset and its alarms; breaks it put on shifts stay.
ShiftyResult shifty_delete_break_preset(ShiftyStore *store, ShiftyId preset_id, int64_t now);

// Copies up to `cap` bytes (no NUL); `len` gets the full length.
ShiftyResult shifty_setting(ShiftyStore *store, const char *key, char *buf, size_t cap,
                            size_t *len);
// A NULL value removes the setting.
ShiftyResult shifty_set_setting(ShiftyStore *store, const char *key, const char *value,
                                int64_t now);

// ── Timesheet ───────────────────────────────────────────────────────────────

// The entries and shifts (with their breaks) overlapping [from, to) plus every
// active client, project, and workspace, as UTF-8 JSON: {"entries":[...],
// "shifts":[...],"clients":[...],"projects":[...],"workspaces":[...]}. Ids
// are UUID strings. Release with shifty_free.
ShiftyResult shifty_timesheet_json(ShiftyStore *store, int64_t from, int64_t to, char **out,
                                   size_t *len);
void shifty_free(char *ptr, size_t len);

// Time recorded after the fact. NULL ids leave it unassigned; a workspace
// implies its project.
ShiftyResult shifty_add_entry(ShiftyStore *store, const ShiftyId *project_id,
                              const ShiftyId *workspace_id, int64_t in_ts, int64_t out_ts,
                              const char *note, ShiftyId *out);
// Replaces an entry's project, times, and note. `running` nonzero keeps a
// running entry running.
ShiftyResult shifty_edit_entry(ShiftyStore *store, ShiftyId entry_id, const ShiftyId *project_id,
                               const ShiftyId *workspace_id, int64_t in_ts, int64_t out_ts,
                               int32_t running, const char *note, int64_t now);
ShiftyResult shifty_delete_entry(ShiftyStore *store, ShiftyId entry_id, int64_t now);
// Brings back a deleted entry as it was. SHIFTY_NOT_FOUND unless it's deleted;
// SHIFTY_CONFLICT if it was running and another entry runs now.
ShiftyResult shifty_restore_entry(ShiftyStore *store, ShiftyId entry_id, int64_t now);
ShiftyResult shifty_create_project(ShiftyStore *store, const char *name,
                                   const ShiftyId *client_id, const char *color, int64_t now,
                                   ShiftyId *out);

// Starts tracking now: stops the running entry and ends a break in progress.
// NULL ids leave it unassigned; a workspace implies its project.
ShiftyResult shifty_start_entry(ShiftyStore *store, const ShiftyId *project_id,
                                const ShiftyId *workspace_id, const char *note, int64_t now,
                                ShiftyId *out);
// Stops the running entry; SHIFTY_NONE if nothing was running.
ShiftyResult shifty_stop_entry(ShiftyStore *store, int64_t now);

// ── Projects ────────────────────────────────────────────────────────────────

// Every active project, client, and workspace, plus each project's usage, as
// UTF-8 JSON: {"projects":[...],"clients":[...],"workspaces":[...],"usage":
// [{"project_id","entries","seconds","last_ts"}]}. A running entry counts up
// to `now`. Release with shifty_free.
ShiftyResult shifty_projects_json(ShiftyStore *store, int64_t now, char **out, size_t *len);
// Replaces a project's name, client, and color ('#rrggbb', or NULL for none).
ShiftyResult shifty_edit_project(ShiftyStore *store, ShiftyId project_id, const char *name,
                                 const ShiftyId *client_id, const char *color, int64_t now);
// Deletes a project and its workspaces. Its time stays, unassigned.
ShiftyResult shifty_delete_project(ShiftyStore *store, ShiftyId project_id, int64_t now);

#endif // SHIFTY_H
