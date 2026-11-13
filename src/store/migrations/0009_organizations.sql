-- Organizations: who the time is for, above projects. Two companies you
-- work for are two organizations; your own projects are a third.
--
-- An organization tracks one of two ways:
--   shift  its time is on the clock. Every shift organization shares the
--          one shift: clocking in and out, breaks, lunch, the day's length
--          and the weekly goal are the same for all of them, and each keeps
--          its own projects.
--   auto   it has no shift. Its time tracks itself from where you work (a
--          project's keywords, repos, folders, and apps), stops when you
--          go idle or the Mac sleeps, and never counts as worked time.
--
-- Each organization will be its own account in a synced Shifty, several
-- signed in at once, so a project belongs to exactly one. Projects keep
-- their meaning (the product); workspaces (repos) stay under projects.
--
-- The projects you have go to a "Work" organization on the shift, and a
-- "Personal" one that tracks itself is there to move your own projects to.

create table organizations (
    id blob primary key not null check (length(id) = 16),
    name text not null,
    tracking text not null default 'shift' check (tracking in ('shift', 'auto')),
    -- '#rrggbb'
    color text,
    created_ts integer not null,
    updated_ts integer not null,
    archived_ts integer,
    deleted_ts integer
) strict;

-- Nullable only because SQLite can't add a required column to a table
-- with rows; Shifty always sets it.
alter table projects add column organization_id blob references organizations (id);

insert into organizations (id, name, tracking, created_ts, updated_ts)
values
    (randomblob(16), 'Work', 'shift', unixepoch(), unixepoch()),
    (randomblob(16), 'Personal', 'auto', unixepoch(), unixepoch());

update projects set organization_id = (
    select id from organizations where tracking = 'shift' order by rowid limit 1
)
where organization_id is null;

create index projects_by_organization on projects (organization_id) where deleted_ts is null;
