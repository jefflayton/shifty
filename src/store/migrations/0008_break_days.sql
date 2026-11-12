-- Breaks go back to the day they were taken, and one-off breaks.
--
-- Clocking in on a new day, the menu bar app could save the last shift's
-- breaks onto the new shift under their old ids, which moved each one off
-- its day: past days lost their lunch, and the new day showed it until you
-- deleted it. A break moved that way was saved during an earlier shift but
-- sits on a later one, at the same time of day some days on. It goes back
-- to the shift it was saved during, at its own time, if it fits inside that
-- shift and no break there overlaps it. One deleted on the day it landed on
-- comes back too: that was you clearing yesterday's lunch from today. One
-- changed after it landed stays: you made it that day's break.

create temp table moved_breaks as
select
    b.id as id,
    o.id as shift_id,
    -- Back as many local days as it was moved, in the zones of the two
    -- shifts, so it keeps its time of day across a clock change.
    b.in_ts + (s.utc_offset_secs - o.utc_offset_secs) - 86400 * (
        (b.in_ts + s.utc_offset_secs) / 86400 - (b.created_ts + o.utc_offset_secs) / 86400
    ) as in_ts,
    b.out_ts + (s.utc_offset_secs - o.utc_offset_secs) - 86400 * (
        (b.in_ts + s.utc_offset_secs) / 86400 - (b.created_ts + o.utc_offset_secs) / 86400
    ) as out_ts,
    o.in_ts as shift_in,
    o.out_ts as shift_out
from breaks b
join shifts s on s.id = b.shift_id
join shifts o on o.id = (
    -- The ended shift the break was saved during.
    select e.id from shifts e
    where e.id <> b.shift_id and e.deleted_ts is null and e.out_ts is not null
        and e.in_ts <= b.created_ts and b.created_ts <= e.out_ts + 300
    order by e.in_ts desc
    limit 1
)
-- Saved well before its own shift began: no frontend does that.
where b.out_ts is not null and b.created_ts < s.in_ts - 3600
    -- Not changed since it landed, unless to delete it.
    and (b.deleted_ts is not null or b.updated_ts <= s.in_ts + 300);

update breaks
set shift_id = m.shift_id, in_ts = m.in_ts, out_ts = m.out_ts, deleted_ts = null,
    updated_ts = unixepoch()
from moved_breaks m
where breaks.id = m.id
    and m.in_ts >= m.shift_in and m.out_ts <= m.shift_out
    and not exists (
        select 1 from breaks x
        where x.shift_id = m.shift_id and x.deleted_ts is null
            and x.id not in (select id from moved_breaks)
            and x.in_ts < m.out_ts and m.in_ts < coalesce(x.out_ts, m.out_ts)
    );

drop table moved_breaks;

-- A break on one day only, like the dentist on Thursday from 2 to 3. It
-- goes on that day's shift when you clock in, or straight away if you're
-- on that day's shift, until it starts.
create table one_off_breaks (
    id blob primary key not null check (length(id) = 16),
    name text not null,
    -- An SF Symbol name; null is the frontend's default.
    icon text check (icon is null or length(icon) between 1 and 100),
    in_ts integer not null,
    out_ts integer not null,
    -- Whether starting and ending it offers the clock links.
    clock_link integer not null default 0 check (clock_link in (0, 1)),
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    check (out_ts > in_ts and out_ts - in_ts <= 43200)
) strict;

create index one_off_breaks_by_time on one_off_breaks (in_ts) where deleted_ts is null;
