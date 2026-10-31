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
  SHIFTY_ALARM_BEFORE_CLOCK_OUT = 0, // value: minutes before clock out
  SHIFTY_ALARM_AT_TIME = 1,          // value: seconds since local midnight
} ShiftyAlarmKind;

typedef struct {
  ShiftyId id;
  int32_t kind; // ShiftyAlarmKind
  int32_t enabled;
  int64_t value;
} ShiftyAlarmRule;

// A NULL path opens the shared default ($SHIFTY_DB, else
// ~/Library/Application Support/Shifty/shifty.db).
ShiftyResult shifty_store_open(const char *path, ShiftyStore **out);
void shifty_store_close(ShiftyStore *store);
// Changes when another process writes.
ShiftyResult shifty_data_version(ShiftyStore *store, int64_t *out);

ShiftyResult shifty_current_shift(ShiftyStore *store, ShiftyShift *out);
ShiftyResult shifty_start_shift(ShiftyStore *store, int64_t in_ts, int64_t target_secs,
                                ShiftyId *out);
ShiftyResult shifty_edit_shift(ShiftyStore *store, ShiftyId shift_id, int64_t in_ts,
                               int64_t target_secs, int64_t now);
ShiftyResult shifty_end_shift(ShiftyStore *store, int64_t now);
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

// Copies up to `cap` bytes (no NUL); `len` gets the full length.
ShiftyResult shifty_setting(ShiftyStore *store, const char *key, char *buf, size_t cap,
                            size_t *len);
// A NULL value removes the setting.
ShiftyResult shifty_set_setting(ShiftyStore *store, const char *key, const char *value,
                                int64_t now);

#endif // SHIFTY_H
