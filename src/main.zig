const std = @import("std");
const httpz = @import("httpz");
const zqlite = @import("zqlite");
const engine = @import("engine.zig");
const transport = @import("transport.zig");
const observe = @import("observe.zig");
const controller = @import("controller.zig");
const planner = @import("planner.zig");
const J = @import("json_helpers.zig");

const App = struct {
    io: std.Io,
    pool: *zqlite.Pool,
    connections: transport.Config,
    controller: *controller.Runtime,
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
    try controller.migrate(conn);
}
fn configure(conn: zqlite.Conn, _: ?*anyopaque) !void {
    try conn.execNoArgs("PRAGMA synchronous=FULL");
    try conn.busyTimeout(3000);
}

pub fn main(init: std.process.Init) !void {
    try transport.init();
    defer transport.deinit();
    const connections = try transport.load(init);
    const path = init.environ_map.get("PRONTARR_DB") orelse "prontarr.sqlite";
    const process_lock = try controller.lockProcess(init.arena.allocator(), path);
    defer controller.unlockProcess(process_lock);
    const path_z = try init.arena.allocator().dupeSentinel(u8, path, 0);
    var pool = try zqlite.Pool.init(init.gpa, .{ .path = path_z, .size = 2, .on_first_connection = migrate, .on_connection = configure });
    defer pool.deinit();
    inline for (.{ "", "-wal", "-shm" }) |suffix| {
        const name = try std.fmt.allocPrint(init.arena.allocator(), "{s}{s}", .{ path, suffix });
        if (std.Io.Dir.cwd().openFile(init.io, name, .{})) |file| {
            defer file.close(init.io);
            try file.setPermissions(init.io, .fromMode(0o600));
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
    }
    var runtime = controller.Runtime{ .io = init.io, .allocator = init.gpa, .pool = pool, .config = connections };
    var background = try init.io.concurrent(controller.Runtime.run, .{&runtime});
    defer background.cancel(init.io) catch {};
    var app = App{ .io = init.io, .pool = pool, .connections = connections, .controller = &runtime };
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
    router.get("/api/plans/:id", getPlan, .{});
    router.get("/api/connections", connectionInfo, .{});
    router.post("/api/observe", observeLive, .{});
    router.get("/api/jobs", liveJobs, .{});
    router.post("/api/jobs", createLiveJob, .{});
    router.get("/api/jobs/:id", liveJob, .{});
    router.post("/api/jobs/:id/start", startLiveJob, .{});
    router.post("/api/jobs/:id/cancel", cancelLiveJob, .{});
    router.post("/api/jobs/:id/analyze", analyzeLiveJob, .{});
    router.get("/api/library", library, .{});
    router.get("/api/library/:app/:id/episodes", libraryEpisodes, .{});
    std.log.info("Prontarr 0.4.0 — http://127.0.0.1:5882 — controlled execution available", .{});
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
fn health(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .status = "ok", .version = "0.4.0", .mode = if (app.connections.execution.enabled) "controlled" else "read_only", .observation_available = true, .live_actions_enabled = app.connections.execution.enabled }, .{});
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

fn getPlan(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = std.fmt.parseInt(i64, req.param("id") orelse "", 10) catch return failure(res, 400, "Identificador de plano inválido.");
    if (id <= 0) return failure(res, 400, "Identificador de plano inválido.");
    const conn = try app.pool.acquire(app.io);
    defer app.pool.release(app.io, conn);
    const row = (try conn.row("SELECT id,input,decision,created_at FROM plans WHERE id=?1", .{id})) orelse return failure(res, 404, "Plano não encontrado.");
    defer row.deinit();
    const input = try std.json.parseFromSliceLeaky(engine.Input, res.arena, row.text(1), .{ .allocate = .alloc_always });
    const decision = try std.json.parseFromSliceLeaky(engine.Decision, res.arena, row.text(2), .{ .allocate = .alloc_always });
    try res.json(.{ .id = row.int(0), .input = input, .decision = decision, .created_at = row.text(3), .simulation = true }, .{});
}

fn jobId(req: *httpz.Request) !i64 {
    const id = try std.fmt.parseInt(i64, req.param("id") orelse "", 10);
    if (id <= 0) return error.InvalidJobId;
    return id;
}
fn liveJobs(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .items = try app.controller.summaries(res.arena), .execution_enabled = app.connections.execution.enabled }, .{});
}
fn createLiveJob(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const input = (req.json(struct { target: planner.Ref }) catch return failure(res, 400, "Referência de mídia inválida.")) orelse return failure(res, 400, "Dados ausentes.");
    planner.validate(input.target) catch return failure(res, 400, "Referência de mídia inválida.");
    const db = try app.pool.acquire(app.io);
    var policy = engine.Policy{};
    {
        defer app.pool.release(app.io, db);
        if (try db.row("SELECT policy FROM settings WHERE id=1", .{})) |row| {
            defer row.deinit();
            policy = try std.json.parseFromSliceLeaky(engine.Policy, res.arena, row.text(0), .{});
        }
    }
    const id = try app.controller.create(res.arena, input.target, policy);
    res.status = 202;
    try res.json(.{ .id = id }, .{});
}
fn liveJob(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = jobId(req) catch return failure(res, 400, "Identificador inválido.");
    const state = app.controller.load(res.arena, id) catch return failure(res, 404, "Plano não encontrado.");
    try res.json(.{ .job = controller.summary(id, state), .report = if (state.analysis) |value| value.report else null, .events = try app.controller.events(res.arena, id), .execution_allowed = app.controller.allowed(state.target) }, .{});
}
fn startLiveJob(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = jobId(req) catch return failure(res, 400, "Identificador inválido.");
    app.controller.requestStart(res.arena, id) catch |err| return failure(res, 409, @errorName(err));
    res.status = 202;
    try res.json(.{ .accepted = true }, .{});
}
fn cancelLiveJob(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = jobId(req) catch return failure(res, 400, "Identificador inválido.");
    app.controller.cancel(res.arena, id) catch |err| return failure(res, 409, @errorName(err));
    try res.json(.{ .accepted = true }, .{});
}
fn analyzeLiveJob(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = jobId(req) catch return failure(res, 400, "Identificador inválido.");
    app.controller.reanalyze(res.arena, id) catch |err| return failure(res, 409, @errorName(err));
    try res.json(.{ .accepted = true }, .{});
}
fn library(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const Media = struct { app: planner.AppKind, id: i64, title: []const u8, has_file: ?bool, monitored: bool };
    var out: std.ArrayList(Media) = .empty;
    for ([_]planner.AppKind{ .radarr, .sonarr }) |kind| {
        const conn = planner.connection(app.connections, kind) catch continue;
        const values = try planner.get(res.arena, conn, if (kind == .radarr) "/api/v3/movie" else "/api/v3/series");
        for (J.array(values)) |value| {
            try out.append(res.arena, .{ .app = kind, .id = J.num(value, "id") orelse continue, .title = J.str(value, "title") orelse continue, .has_file = J.flag(value, "hasFile"), .monitored = J.flag(value, "monitored") orelse false });
        }
    }
    try res.json(.{ .items = out.items }, .{});
}
fn libraryEpisodes(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!std.mem.eql(u8, req.param("app") orelse "", "sonarr")) return failure(res, 400, "Aplicação inválida.");
    const id = jobId(req) catch return failure(res, 400, "Série inválida.");
    const values = try planner.get(res.arena, try planner.connection(app.connections, .sonarr), try std.fmt.allocPrint(res.arena, "/api/v3/episode?seriesId={d}", .{id}));
    const Episode = struct { id: i64, title: []const u8, season: i64, episode: i64, has_file: bool };
    var out: std.ArrayList(Episode) = .empty;
    for (J.array(values)) |value| try out.append(res.arena, .{ .id = J.num(value, "id") orelse continue, .title = J.str(value, "title") orelse "", .season = J.num(value, "seasonNumber") orelse 0, .episode = J.num(value, "episodeNumber") orelse 0, .has_file = J.flag(value, "hasFile") orelse false });
    try res.json(.{ .items = out.items }, .{});
}
