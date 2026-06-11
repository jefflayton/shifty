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

#endif // SHIFTY_H
