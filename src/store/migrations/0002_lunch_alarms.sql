-- Lunch alarms: one when the lunch window opens, and one some minutes before
-- it closes. SQLite can't change a check constraint, so the table is
-- rebuilt with the same columns and rows.

create table alarm_rules_new (
    id blob primary key not null check (length(id) = 16),
    kind text not null check (
        kind in ('before_clock_out', 'at_time', 'lunch_opens', 'before_lunch_closes')
    ),
    minutes integer,
    -- local wall clock, so "ring at 4:30" follows you across zones
    time_of_day_secs integer,
    enabled integer not null default 1 check (enabled in (0, 1)),
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    check (
        (
            kind in ('before_clock_out', 'before_lunch_closes')
            and minutes >= 0 and time_of_day_secs is null
        )
        or (
            kind = 'at_time'
            and time_of_day_secs between 0 and 86399
            and minutes is null
        )
        or (kind = 'lunch_opens' and minutes is null and time_of_day_secs is null)
    )
) strict;

insert into alarm_rules_new (
    id, kind, minutes, time_of_day_secs, enabled, created_ts, updated_ts, deleted_ts
)
select id, kind, minutes, time_of_day_secs, enabled, created_ts, updated_ts, deleted_ts
from alarm_rules;

drop table alarm_rules;
alter table alarm_rules_new rename to alarm_rules;
