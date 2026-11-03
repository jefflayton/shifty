-- Break presets: breaks you plan once and get on every shift they apply to.
--
-- A scheduled preset is a break at set local times on set weekdays, like a
-- class on Tuesdays and Thursdays from 11 to 2. It's put on the shift as an
-- ordinary break when you clock in, so you can still move or delete it for
-- the day.
--
-- A window preset is a break of at least `minimum_secs` that has to start
-- between `earliest_secs` and `latest_secs` of time worked, like lunch. It
-- never adds a break; it's what lunch alarms and the timesheet check against.
--
-- The lunch window moves here from the `lunch` setting, and its alarms point
-- at it.

create table break_presets (
    id blob primary key not null check (length(id) = 16),
    name text not null,
    kind text not null check (kind in ('scheduled', 'window')),
    -- ISO weekdays it applies on: bit 0 is Monday, bit 6 Sunday.
    weekdays integer not null default 127 check (weekdays between 0 and 127),
    -- scheduled: local wall clock, seconds since midnight
    start_secs integer,
    end_secs integer,
    -- window: time worked
    earliest_secs integer,
    latest_secs integer,
    minimum_secs integer,
    enabled integer not null default 1 check (enabled in (0, 1)),
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    check (
        (
            kind = 'scheduled'
            and start_secs between 0 and 86399
            and end_secs > start_secs and end_secs <= 86400
            and earliest_secs is null and latest_secs is null and minimum_secs is null
        )
        or (
            kind = 'window'
            and earliest_secs >= 0 and latest_secs > earliest_secs and minimum_secs > 0
            and start_secs is null and end_secs is null
        )
    )
) strict;

-- The lunch window, with the settings saved before, or off with the
-- defaults (3h to 5h of work, at least 30 minutes).
insert into break_presets (
    id, name, kind, earliest_secs, latest_secs, minimum_secs, enabled, created_ts, updated_ts
)
select
    randomblob(16),
    'Lunch',
    'window',
    coalesce(json_extract(s.value, '$.earliest_mins'), 180) * 60,
    coalesce(json_extract(s.value, '$.latest_mins'), 300) * 60,
    coalesce(json_extract(s.value, '$.minimum_mins'), 30) * 60,
    coalesce(json_extract(s.value, '$.enabled'), 0),
    coalesce(s.updated_ts, unixepoch()),
    coalesce(s.updated_ts, unixepoch())
from (select 1) left join settings s on s.key = 'lunch' and json_valid(s.value);

delete from settings where key = 'lunch';

-- Alarms learn breaks: some minutes before a break starts or ends. Lunch
-- alarms become window alarms that name their window.
create table alarm_rules_new (
    id blob primary key not null check (length(id) = 16),
    kind text not null check (
        kind in (
            'before_clock_out', 'at_time', 'window_opens', 'before_window_closes',
            'before_break', 'before_break_ends'
        )
    ),
    minutes integer,
    -- local wall clock, so "ring at 4:30" follows you across zones
    time_of_day_secs integer,
    preset_id blob references break_presets (id),
    enabled integer not null default 1 check (enabled in (0, 1)),
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    check (
        (
            kind in ('before_clock_out', 'before_break', 'before_break_ends')
            and minutes >= 0 and time_of_day_secs is null and preset_id is null
        )
        or (
            kind = 'at_time'
            and time_of_day_secs between 0 and 86399
            and minutes is null and preset_id is null
        )
        or (
            kind = 'window_opens'
            and minutes is null and time_of_day_secs is null and preset_id is not null
        )
        or (
            kind = 'before_window_closes'
            and minutes >= 0 and time_of_day_secs is null and preset_id is not null
        )
    )
) strict;

insert into alarm_rules_new (
    id, kind, minutes, time_of_day_secs, preset_id, enabled, created_ts, updated_ts, deleted_ts
)
select
    id,
    case kind
        when 'lunch_opens' then 'window_opens'
        when 'before_lunch_closes' then 'before_window_closes'
        else kind
    end,
    minutes,
    time_of_day_secs,
    case
        when kind in ('lunch_opens', 'before_lunch_closes')
            then (select id from break_presets where kind = 'window')
    end,
    enabled,
    created_ts,
    updated_ts,
    deleted_ts
from alarm_rules;

drop table alarm_rules;
alter table alarm_rules_new rename to alarm_rules;
