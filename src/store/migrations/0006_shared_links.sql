-- One id can link to more than one project: a repo two projects work in, say.
-- Each project links to an id once, so linking it again to another of the
-- project's workspaces moves that link. Where an id links to several,
-- auto-switch decides which (src/integrations/place.zig).
--
-- A new provider:
--   keyword  word   a word or phrase, lowercased, that names the project in
--                   a window's title: a Rex session or tab, an editor
--
-- SQLite can't drop a table constraint, so the table is rebuilt.

create table links_new (
    id blob primary key not null check (length(id) = 16),
    provider text not null,
    -- the provider's noun: 'project', 'workspace', ...
    kind text not null,
    external_id text not null,
    project_id blob not null references projects (id),
    workspace_id blob references workspaces (id),
    created_ts integer not null,
    updated_ts integer not null,
    deleted_ts integer,
    unique (provider, kind, external_id, project_id)
) strict;

insert into links_new (id, provider, kind, external_id, project_id, workspace_id,
                       created_ts, updated_ts, deleted_ts)
select id, provider, kind, external_id, project_id, workspace_id,
       created_ts, updated_ts, deleted_ts
from links;

drop table links;
alter table links_new rename to links;
