//! Names and totals for showing entries: what every frontend's log or
//! timesheet needs on top of the raw rows.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core");
const Uuid = core.Uuid;

const store = @import("root.zig");
const Store = store.Store;

/// Every active organization, client, project, and workspace, for turning
/// ids into names.
pub const Names = struct {
    clients: []const store.Client,
    projects: []const store.Project,
    workspaces: []const store.Workspace,
    organizations: []const store.Organization = &.{},

    /// Allocated in `arena`.
    pub fn load(db: *Store, arena: Allocator) store.Error!Names {
        return .{
            .clients = try db.clients(arena),
            .projects = try db.projects(arena),
            .workspaces = try db.allWorkspaces(arena),
            .organizations = try db.organizations(arena),
        };
    }

    pub fn organization(n: Names, id: Uuid) ?store.Organization {
        return find(store.Organization, n.organizations, id);
    }

    /// The organization a project belongs to; none for unassigned time.
    pub fn organizationOf(n: Names, project_id: ?Uuid) ?store.Organization {
        const p = n.project(project_id orelse return null) orelse return null;
        return n.organization(p.organization_id orelse return null);
    }

    /// Whether time on `project_id` tracks itself and isn't work: its
    /// organization has no shift. Unassigned time is work.
    pub fn isPersonal(n: Names, project_id: ?Uuid) bool {
        const o = n.organizationOf(project_id) orelse return false;
        return o.tracking == .auto;
    }

    /// Whether time on `project_id` shows under organization `org`, or under
    /// every one (null). Unassigned time shows under shift organizations,
    /// since it's time on the clock no project has.
    pub fn inOrganization(n: Names, project_id: ?Uuid, org: ?Uuid) bool {
        const want = org orelse return true;
        if (n.organizationOf(project_id)) |o| return o.id.eql(want);
        const o = n.organization(want) orelse return false;
        return project_id == null and o.tracking == .shift;
    }

    /// The entries that show under `org` (null: all). Allocated in `arena`.
    pub fn only(n: Names, arena: Allocator, entries: []const store.Entry, org: ?Uuid) Allocator.Error![]store.Entry {
        var out: std.ArrayList(store.Entry) = .empty;
        for (entries) |e| if (n.inOrganization(e.project_id, org)) try out.append(arena, e);
        return out.items;
    }

    pub fn project(n: Names, id: Uuid) ?store.Project {
        return find(store.Project, n.projects, id);
    }

    pub fn workspace(n: Names, id: Uuid) ?store.Workspace {
        return find(store.Workspace, n.workspaces, id);
    }

    pub fn client(n: Names, id: Uuid) ?store.Client {
        return find(store.Client, n.clients, id);
    }

    /// The client a project bills to, if any.
    pub fn clientOf(n: Names, project_id: ?Uuid) ?store.Client {
        const p = n.project(project_id orelse return null) orelse return null;
        return n.client(p.client_id orelse return null);
    }

    /// `project/workspace`, `project`, or `(unassigned)`. Allocated in
    /// `arena` when it joins two names.
    pub fn label(n: Names, arena: Allocator, project_id: ?Uuid, workspace_id: ?Uuid) Allocator.Error![]const u8 {
        const pid = project_id orelse return "(unassigned)";
        const pname = if (n.project(pid)) |p| p.name else "(archived)";
        const w = n.workspace(workspace_id orelse return pname) orelse return pname;
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ pname, w.name });
    }

    fn find(comptime T: type, items: []const T, id: Uuid) ?T {
        for (items) |item| if (item.id.eql(id)) return item;
        return null;
    }
};

/// Seconds of `e` inside `[from, now]`, counting a running entry up to now.
pub fn clipped(e: store.Entry, from: i64, now: i64) i64 {
    return @max(0, @min(e.out_ts orelse now, now) - @max(e.in_ts, from));
}

pub const Total = struct {
    /// null: unassigned (by project) or no client (by client).
    id: ?Uuid,
    secs: i64,
};

pub const Totals = struct {
    /// Work: time on shift organizations' projects, and unassigned.
    by_project: []Total,
    by_client: []Total,
    /// Whether any time went to a project with a client; if not, a by-client
    /// breakdown says nothing.
    any_client: bool,
    /// All work time; personal time isn't in it.
    total: i64,
    /// Work time per organization; null is unassigned.
    by_organization: []Total = &.{},
    /// Time on projects of organizations with no shift, which tracks itself
    /// and never counts as work, per project.
    personal_by_project: []Total = &.{},
    personal: i64 = 0,
};

/// Time per project, client, and organization in `[from, now]`, in order
/// of first appearance, with personal time apart. Allocated in `arena`.
pub fn totals(arena: Allocator, names: Names, entries: []const store.Entry, from: i64, now: i64) Allocator.Error!Totals {
    var by_project: std.ArrayList(Total) = .empty;
    var by_client: std.ArrayList(Total) = .empty;
    var by_org: std.ArrayList(Total) = .empty;
    var personal_by_project: std.ArrayList(Total) = .empty;
    var any_client = false;
    var total: i64 = 0;
    var personal: i64 = 0;

    for (entries) |e| {
        const secs = clipped(e, from, now);
        if (names.isPersonal(e.project_id)) {
            personal += secs;
            try add(arena, &personal_by_project, e.project_id, secs);
            continue;
        }
        total += secs;
        try add(arena, &by_project, e.project_id, secs);
        const cl = names.clientOf(e.project_id);
        any_client = any_client or cl != null;
        try add(arena, &by_client, if (cl) |c| c.id else null, secs);
        try add(arena, &by_org, if (names.organizationOf(e.project_id)) |o| o.id else null, secs);
    }
    return .{
        .by_project = by_project.items,
        .by_client = by_client.items,
        .any_client = any_client,
        .total = total,
        .by_organization = by_org.items,
        .personal_by_project = personal_by_project.items,
        .personal = personal,
    };
}

fn add(arena: Allocator, list: *std.ArrayList(Total), id: ?Uuid, secs: i64) Allocator.Error!void {
    for (list.items) |*t| {
        const same = if (t.id) |a| (if (id) |b| a.eql(b) else false) else id == null;
        if (same) {
            t.secs += secs;
            return;
        }
    }
    try list.append(arena, .{ .id = id, .secs = secs });
}

const testing = std.testing;

test "totals - by project and client, clipped to the range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var db: Store = try .open(io, ":memory:");
    defer db.deinit();
    const acme = try db.createClient("Acme", 0);
    const web = try db.createProject(.{ .name = "web", .client_id = acme }, 0);
    const api = try db.createProject(.{ .name = "api", .client_id = acme }, 0);
    const internal = try db.createProject(.{ .name = "internal" }, 0);
    const main = try db.createWorkspace(web, "main", 0);

    const at = struct {
        fn f(ts: i64) core.local.Stamp {
            return .{ .ts = ts, .utc_offset_secs = 0, .tz = null };
        }
    }.f;
    _ = try db.startEntry(.{ .workspace_id = main, .source = .tui }, at(0)); // 50 before `from`
    _ = try db.startEntry(.{ .project_id = internal, .source = .tui }, at(100));
    _ = try db.startEntry(.{ .project_id = api, .source = .tui }, at(200));
    _ = try db.startEntry(.{ .source = .tui }, at(300));
    _ = try db.startEntry(.{ .project_id = web, .source = .tui }, at(400)); // running

    const names: Names = try .load(&db, a);
    try testing.expectEqualStrings("web/main", try names.label(a, web, main));
    try testing.expectEqualStrings("internal", try names.label(a, internal, null));
    try testing.expectEqualStrings("(unassigned)", try names.label(a, null, null));

    const entries = try db.entriesBetween(a, 50, 450);
    const t = try totals(a, names, entries, 50, 450);
    try testing.expectEqual(400, t.total);
    try testing.expect(t.any_client);

    try testing.expectEqual(4, t.by_project.len);
    try testing.expect(t.by_project[0].id.?.eql(web));
    try testing.expectEqual(50 + 50, t.by_project[0].secs);
    try testing.expectEqual(null, t.by_project[3].id);
    try testing.expectEqual(100, t.by_project[3].secs);

    try testing.expectEqual(2, t.by_client.len);
    try testing.expect(t.by_client[0].id.?.eql(acme));
    try testing.expectEqual(200, t.by_client[0].secs);
    try testing.expectEqual(null, t.by_client[1].id);
    try testing.expectEqual(200, t.by_client[1].secs);
    try testing.expectEqual(0, t.personal);
}

test "totals - personal time apart, and by organization" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db: Store = try .open(testing.io, ":memory:");
    defer db.deinit();

    const orgs = try db.organizations(a);
    try testing.expectEqual(2, orgs.len);
    const work = orgs[0].id;
    const personal = orgs[1].id;
    try testing.expectEqual(store.Tracking.auto, orgs[1].tracking);
    const other = try db.createOrganization(.{ .name = "Other Co" }, 0);

    const web = try db.createProject(.{ .name = "web" }, 0);
    const side = try db.createProject(.{ .name = "side", .organization_id = personal }, 0);
    const theirs = try db.createProject(.{ .name = "theirs", .organization_id = other }, 0);

    const at = struct {
        fn f(ts: i64) core.local.Stamp {
            return .{ .ts = ts, .utc_offset_secs = 0, .tz = null };
        }
    }.f;
    _ = try db.addEntry(.{ .project_id = web, .source = .cli }, at(0), 100);
    _ = try db.addEntry(.{ .project_id = side, .source = .cli }, at(100), 400);
    _ = try db.addEntry(.{ .project_id = theirs, .source = .cli }, at(400), 450);
    _ = try db.addEntry(.{ .source = .cli }, at(450), 460);

    const names: Names = try .load(&db, a);
    try testing.expect(names.isPersonal(side));
    try testing.expect(!names.isPersonal(web));
    try testing.expect(!names.isPersonal(null));
    try testing.expect(names.organizationOf(web).?.id.eql(work));

    const entries = try db.entriesBetween(a, 0, 1000);
    const t = try totals(a, names, entries, 0, 1000);
    try testing.expectEqual(160, t.total);
    try testing.expectEqual(300, t.personal);
    try testing.expectEqual(3, t.by_project.len);
    try testing.expectEqual(1, t.personal_by_project.len);
    try testing.expect(t.personal_by_project[0].id.?.eql(side));
    try testing.expectEqual(3, t.by_organization.len);
    try testing.expect(t.by_organization[0].id.?.eql(work));
    try testing.expectEqual(null, t.by_organization[2].id);

    // Filtered: unassigned time shows under shift organizations only.
    try testing.expectEqual(2, (try names.only(a, entries, work)).len);
    try testing.expectEqual(2, (try names.only(a, entries, other)).len);
    try testing.expectEqual(1, (try names.only(a, entries, personal)).len);
    try testing.expectEqual(4, (try names.only(a, entries, null)).len);
}
