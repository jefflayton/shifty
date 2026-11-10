-- Break presets learn an icon and whether taking the break means clocking
-- out on your timeclock.
--
-- `icon` is an SF Symbol name, like "fork.knife"; null is the frontend's
-- default for that kind of break. Frontends that can't draw SF Symbols
-- ignore it.
--
-- `clock_link` is whether starting and ending the break offers the clock
-- links, as Clock Out and Clock In do. Lunch is usually clocked out for, so
-- the lunch window starts with it on.

alter table break_presets add column icon text
    check (icon is null or length(icon) between 1 and 100);
alter table break_presets add column clock_link integer not null default 0
    check (clock_link in (0, 1));

update break_presets set clock_link = 1 where kind = 'window';
