-- Entries learn what kind of time they are. A meeting is time on a project
-- like any other, worked and not a break, but kept apart so it can be
-- listed: its note is the meeting's title.
--
--   work     the default: a timer, or time added after the fact
--   meeting  a call, logged by the menu bar or with `shifty start -m`

alter table entries add column kind text not null default 'work'
    check (kind in ('work', 'meeting'));

create index entries_meetings on entries (in_ts)
where kind = 'meeting' and deleted_ts is null;
