-- Ids are 16-byte UUIDv7 blobs. Times are unix seconds. Rows are soft
-- deleted (`deleted_ts`) so a future sync can carry the delete.

-- One row. Stable identity for this install, for sync later.
create table meta (
    id integer primary key check (id = 1),
    replica_id blob not null check (length(replica_id) = 16)
) strict;

-- ── Organization ────────────────────────────────────────────────────────────

-- Who gets billed.
create table clients (
    id blob primary key not null check (length(id) = 16),
    name text not null,
    created_ts integer not null,
    updated_ts integer not null,
    archived_ts integer,
    deleted_ts integer
) strict;

create table projects (
    id blob primary key not null check (length(id) = 16),
    -- null: no client (personal, unbilled)
    client_id blob references clients (id),
    name text not null,
    -- '#rrggbb'
    color text,
    created_ts integer not null,
    updated_ts integer not null,
    archived_ts integer,
    deleted_ts integer
) strict;

create table workspaces (
    id blob primary key not null check (length(id) = 16),
    project_id blob not null references projects (id),
    name text not null,
    created_ts integer not null,
    updated_ts integer not null,
    archived_ts integer,
    deleted_ts integer
) strict;

-- Optional bridges to other tools (Situ, git remotes, ...). `external_id` is
-- opaque: Shifty never parses another tool's ids.
create table links (
    id blob primary key not null check (length(id) = 16),
    provider text not null,
    -- the provider's noun: 'project', 'workspace', ...
    kind text not null,
    external_id text not null,
    project_id blob not null references projects (id),
    workspace_id blob references workspaces (id),
    created_ts integer not null,
    updated_ts integer not null,
    unique (provider, kind, external_id)
) strict;

-- ── Timeline ────────────────────────────────────────────────────────────────

-- out_ts null: on shift now.
create table shifts (
    id blob primary key not null check (length(id) = 16),
    in_ts integer not null,
    utc_offset_secs integer not null check (utc_offset_secs between -64800 and 64800),
    -- IANA name, null if unknown
    tz text,
    target_secs integer not null check (target_secs > 0),
    out_ts integer,
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    check (out_ts is null or out_ts > in_ts)
) strict;

-- out_ts null: on break now. Breaks use their shift's zone.
create table breaks (
    id blob primary key not null check (length(id) = 16),
    shift_id blob not null references shifts (id),
    in_ts integer not null,
    out_ts integer,
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    check (out_ts is null or out_ts > in_ts)
) strict;

-- out_ts null: the running timer. project_id null: unassigned time.
create table entries (
    id blob primary key not null check (length(id) = 16),
    project_id blob references projects (id),
    workspace_id blob references workspaces (id),
    in_ts integer not null,
    utc_offset_secs integer not null check (utc_offset_secs between -64800 and 64800),
    tz text,
    out_ts integer,
    source text not null check (
        source in ('manual', 'menubar', 'tui', 'cli', 'editor', 'calendar')
    ),
    note text,
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    check (out_ts is null or out_ts > in_ts)
) strict;

-- At most one of each running at a time, whichever frontend starts it.
create unique index one_open_shift on shifts ((1))
where out_ts is null and deleted_ts is null;
create unique index one_open_break on breaks ((1))
where out_ts is null and deleted_ts is null;
create unique index one_open_entry on entries ((1))
where out_ts is null and deleted_ts is null;

create index breaks_by_shift on breaks (shift_id, in_ts) where deleted_ts is null;
create index entries_by_time on entries (in_ts) where deleted_ts is null;
create index entries_by_project on entries (project_id, in_ts)
where deleted_ts is null;

-- ── Settings shared by every frontend ──────────────────────────────────────

create table alarm_rules (
    id blob primary key not null check (length(id) = 16),
    kind text not null check (kind in ('before_clock_out', 'at_time')),
    minutes integer,
    -- local wall clock, so "ring at 4:30" follows you across zones
    time_of_day_secs integer,
    enabled integer not null default 1 check (enabled in (0, 1)),
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    check (
        (kind = 'before_clock_out' and minutes >= 0 and time_of_day_secs is null)
        or (
            kind = 'at_time'
            and time_of_day_secs between 0 and 86399
            and minutes is null
        )
    )
) strict;

-- Frontend-only prefs (menu bar display mode) stay in UserDefaults.
create table settings (
    key text primary key not null,
    value text not null,
    updated_ts integer not null
) strict;
