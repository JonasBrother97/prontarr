const std = @import("std");
const httpz = @import("httpz");
const zqlite = @import("zqlite");
const engine = @import("engine.zig");
const transport = @import("transport.zig");
const observe = @import("observe.zig");

const App = struct {
    io: std.Io,
    pool: *zqlite.Pool,
    connections: transport.Config,
    observation_lock: std.Io.Mutex = .init,

    pub fn dispatch(self: *App, action: httpz.Action(*App), req: *httpz.Request, res: *httpz.Response) !void {
        res.header("Cache-Control", "no-store");
        res.header("X-Content-Type-Options", "nosniff");
        res.header("Referrer-Policy", "no-referrer");
        res.header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
        const host = req.header("host") orelse "";
        if (!std.mem.eql(u8, host, "127.0.0.1:5882") and !std.mem.eql(u8, host, "localhost:5882")) return failure(res, 403, "Host não permitido; use localhost:5882.");
        if (req.header("origin")) |origin| {
            const allowed = [_][]const u8{ "http://127.0.0.1:5882", "http://localhost:5882", "http://127.0.0.1:5173", "http://localhost:5173" };
            var ok = false;
            for (allowed) |value| if (std.mem.eql(u8, origin, value)) {
                ok = true;
            };
            if (!ok) return failure(res, 403, "Origem não permitida.");
        }
        if (req.method == .POST or req.method == .PUT) {
            const content_type = req.header("content-type") orelse "";
            if (!std.mem.startsWith(u8, content_type, "application/json")) return failure(res, 415, "Envie application/json.");
        }
        action(self, req, res) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
            return failure(res, 500, "Falha interna; consulte o log local.");
        };
    }

    pub fn notFound(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
        return failure(res, 404, "Rota não encontrada.");
    }
};

fn failure(res: *httpz.Response, status: u16, message: []const u8) !void {
    res.status = status;
    try res.json(.{ .error_message = message }, .{});
}

fn migrate(conn: zqlite.Conn, _: ?*anyopaque) !void {
    try conn.execNoArgs(
        \\PRAGMA journal_mode=WAL;
        \\CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK(id=1), policy TEXT NOT NULL);
        \\CREATE TABLE IF NOT EXISTS plans (
        \\ id INTEGER PRIMARY KEY, title TEXT NOT NULL, input TEXT NOT NULL,
        \\ decision TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
        \\);
        \\PRAGMA user_version=1;
    );
}
fn configure(conn: zqlite.Conn, _: ?*anyopaque) !void {
    try conn.busyTimeout(3000);
}

pub fn main(init: std.process.Init) !void {
    try transport.init();
    defer transport.deinit();
    const connections = try transport.load(init);
    const path = init.environ_map.get("PRONTARR_DB") orelse "prontarr.sqlite";
    const path_z = try init.arena.allocator().dupeSentinel(u8, path, 0);
    var pool = try zqlite.Pool.init(init.gpa, .{ .path = path_z, .size = 2, .on_first_connection = migrate, .on_connection = configure });
    defer pool.deinit();
    var app = App{ .io = init.io, .pool = pool, .connections = connections };
    var server = try httpz.Server(*App).init(init.io, init.gpa, .{
        .address = .localhost(5882),
        .request = .{ .max_body_size = 1024 * 1024 },
        .thread_pool = .{ .count = 4 },
    }, &app);
    defer server.deinit();
    var router = try server.router(.{});
    router.get("/", index, .{});
    router.get("/app.js", js, .{});
    router.get("/app.css", css, .{});
    router.get("/api/health", health, .{});
    router.get("/api/policy", getPolicy, .{});
    router.put("/api/policy", putPolicy, .{});
    router.post("/api/simulate", simulate, .{});
    router.get("/api/plans", plans, .{});
    router.post("/api/plans", savePlan, .{});
    router.get("/api/connections", connectionInfo, .{});
    router.post("/api/observe", observeLive, .{});
    std.log.info("Prontarr 0.2.0 — http://127.0.0.1:5882 — read-only integrations", .{});
    try server.listen();
}

fn index(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body = @embedFile("index.html");
}
fn js(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.header("Content-Type", "text/javascript; charset=utf-8");
    res.body = @embedFile("app.js");
}
fn css(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.header("Content-Type", "text/css; charset=utf-8");
    res.body = @embedFile("app.css");
}
fn health(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .status = "ok", .version = "0.2.0", .mode = "read_only", .observation_available = true, .live_actions_enabled = false }, .{});
}

fn connectionInfo(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const Info = struct { name: []const u8, configured: bool, mode: []const u8 = "read_only" };
    var items: [3]Info = undefined;
    inline for (.{ "radarr", "sonarr", "qbittorrent" }, 0..) |name, i| {
        items[i] = .{ .name = name, .configured = @field(app.connections, name) != null };
    }
    try res.json(.{ .items = items, .live_actions_enabled = false }, .{});
}
fn observeLive(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    if (!app.observation_lock.tryLock()) return failure(res, 409, "Já há uma observação em andamento. Aguarde a conclusão.");
    defer app.observation_lock.unlock(app.io);
    const conn = try app.pool.acquire(app.io);
    var policy = engine.Policy{};
    {
        defer app.pool.release(app.io, conn);
        if (try conn.row("SELECT policy FROM settings WHERE id=1", .{})) |row| {
            defer row.deinit();
            policy = try std.json.parseFromSliceLeaky(engine.Policy, res.arena, row.text(0), .{});
        }
    }
    const result = try observe.collect(res.arena, app.io, app.connections, policy);
    try res.json(result, .{});
}
fn getPolicy(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const conn = try app.pool.acquire(app.io);
    defer app.pool.release(app.io, conn);
    if (try conn.row("SELECT policy FROM settings WHERE id=1", .{})) |row| {
        defer row.deinit();
        res.content_type = .JSON;
        res.body = try res.arena.dupe(u8, row.text(0));
    } else try res.json(engine.Policy{}, .{});
}
fn putPolicy(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const policy = (req.json(engine.Policy) catch return failure(res, 400, "Política inválida.")) orelse return failure(res, 400, "Política ausente.");
    engine.validate(.{ .title = "policy", .policy = policy }) catch return failure(res, 400, "Limites inválidos: seeds e tamanho devem ser positivos; resolução máxima é 1080p.");
    const json = try std.json.Stringify.valueAlloc(res.arena, policy, .{});
    const conn = try app.pool.acquire(app.io);
    defer app.pool.release(app.io, conn);
    try conn.exec("INSERT INTO settings(id,policy) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET policy=excluded.policy", .{json});
    try res.json(policy, .{});
}
fn readInput(req: *httpz.Request, res: *httpz.Response) !?engine.Input {
    const input = (req.json(engine.Input) catch {
        try failure(res, 400, "Dados da simulação inválidos.");
        return null;
    }) orelse {
        try failure(res, 400, "Corpo ausente.");
        return null;
    };
    engine.validate(input) catch |err| {
        try failure(res, 400, @errorName(err));
        return null;
    };
    return input;
}
fn simulate(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const input = (try readInput(req, res)) orelse return;
    try res.json(engine.decide(input), .{});
}
fn savePlan(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const input = (try readInput(req, res)) orelse return;
    const decision = engine.decide(input);
    const conn = try app.pool.acquire(app.io);
    defer app.pool.release(app.io, conn);
    try conn.exec("INSERT INTO plans(title,input,decision) VALUES(?1,?2,?3)", .{
        input.title,
        try std.json.Stringify.valueAlloc(res.arena, input, .{}),
        try std.json.Stringify.valueAlloc(res.arena, decision, .{}),
    });
    res.status = 201;
    try res.json(.{ .id = conn.lastInsertedRowId(), .decision = decision, .simulation = true }, .{});
}
fn plans(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const conn = try app.pool.acquire(app.io);
    defer app.pool.release(app.io, conn);
    var rows = try conn.rows("SELECT id,title,decision,created_at FROM plans ORDER BY id DESC LIMIT 100", .{});
    defer rows.deinit();
    const Plan = struct { id: i64, title: []const u8, decision: engine.Decision, created_at: []const u8 };
    var list: std.ArrayList(Plan) = .empty;
    while (rows.next()) |row| {
        const parsed = try std.json.parseFromSlice(engine.Decision, res.arena, row.text(2), .{ .allocate = .alloc_always });
        try list.append(res.arena, .{ .id = row.int(0), .title = try res.arena.dupe(u8, row.text(1)), .decision = parsed.value, .created_at = try res.arena.dupe(u8, row.text(3)) });
    }
    if (rows.err) |err| return err;
    try res.json(.{ .items = list.items, .simulation = true }, .{});
}
