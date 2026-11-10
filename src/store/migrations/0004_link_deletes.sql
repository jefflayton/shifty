-- Links can be removed, like any other row: soft deleted, so a future sync
-- can carry the removal. Linking the same id again brings the row back.
--
-- Providers so far:
--   situ   project / workspace   ids from a repo's situ.toml
--   git    remote                a repo's origin, e.g. github.com/owner/repo
--   folder path                  an absolute directory, for repos without a
--                                remote and folders that aren't repos
--   app    bundle                a macOS app's bundle id

alter table links add column deleted_ts integer;
