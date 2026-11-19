const std = @import("std");
const DB = @import("zqlite");
const T = @import("transport.zig");
const P = @import("planner.zig");
const J = @import("json_helpers.zig");
const E = @import("engine.zig");
const C = @import("curl");
const A = std.mem.Allocator;
pub const Stage = enum { queued, analyzing, ready, claiming, compact, upgrading, completed, review, cancelled };
pub const State = struct {
    generation: i64 = 1,
    automatic: bool = false,
    adopt_original: bool = false,
    target: P.Ref,
    policy: E.Policy = .{},
    stage: Stage = .queued,
    analysis: ?P.Analysis = null,
    token: ?[]const u8 = null,
    compact_hash: ?[]const u8 = null,
    upgrade_hash: ?[]const u8 = null,
    upgrade_selection_ids: []const []const u8 = &.{},
    original_stopped: bool = false,
    baseline: []const P.FileState = &.{},
    error_code: ?[]const u8 = null,
    cancel_requested: bool = false,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    compact_sent_at_ms: i64 = 0,
    upgrade_sent_at_ms: i64 = 0,
};
pub const Summary = struct { id: i64, target: P.Ref, title: []const u8, stage: Stage, error_code: ?[]const u8, created_at_ms: i64, updated_at_ms: i64, compact_hash: ?[]const u8, upgrade_hash: ?[]const u8 };
pub const Event = struct { id: i64, kind: []const u8, detail: []const u8, created_at: []const u8 };
pub const Runtime = struct {
    io: std.Io,
    allocator: A,
    pool: *DB.Pool,
    config: T.Config,
    last_job_id: i64 = 0,
    next_scan_ms: i64 = 0,
    pub fn create(self: *Runtime, a: A, target: P.Ref, policy: E.Policy) !i64 {
        return self.createInternal(a, target, policy, false);
    }
    fn createInternal(self: *Runtime, a: A, target: P.Ref, policy: E.Policy, automatic: bool) !i64 {
        try P.validate(target);
        var canonical = target;
        const ids = try a.dupe(i64, target.episode_ids);
        std.mem.sort(i64, ids, {}, std.sort.asc(i64));
        canonical.episode_ids = ids;
        const key = try std.json.Stringify.valueAlloc(a, canonical, .{});
        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const state = State{ .automatic = automatic, .target = canonical, .policy = policy, .created_at_ms = now, .updated_at_ms = now };
        const value = try std.json.Stringify.valueAlloc(a, state, .{});
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        try db.exec("INSERT INTO live_jobs(request_key,state) VALUES(?1,?2) ON CONFLICT(request_key) DO NOTHING", .{ key, value });
        const row = (try db.row("SELECT id FROM live_jobs WHERE request_key=?1", .{key})) orelse return error.JobNotFound;
        defer row.deinit();
        return row.int(0);
    }
    pub fn load(self: *Runtime, a: A, id: i64) !State {
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        const row = (try db.row("SELECT state,cancel_requested FROM live_jobs WHERE id=?1", .{id})) orelse return error.JobNotFound;
        defer row.deinit();
        var state = try std.json.parseFromSliceLeaky(State, a, row.text(0), .{ .allocate = .alloc_always });
        state.cancel_requested = row.int(1) != 0;
        return state;
    }
    pub fn save(self: *Runtime, a: A, id: i64, state: *State, kind: []const u8, detail: []const u8) !void {
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        if (kind.len == 0) {
            if (try db.row("SELECT state FROM live_jobs WHERE id=?1", .{id})) |row| {
                defer row.deinit();
                const unchanged = try std.json.Stringify.valueAlloc(a, state, .{});
                if (std.mem.eql(u8, unchanged, row.text(0))) return;
            }
        }
        state.updated_at_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const body = try std.json.Stringify.valueAlloc(a, state, .{});
        try db.transaction();
        errdefer db.rollback();
        try db.exec("UPDATE live_jobs SET state=?1,cancel_requested=CASE WHEN ?3 THEN 0 ELSE cancel_requested END WHERE id=?2", .{ body, id, state.stage == .cancelled });
        if (kind.len > 0) try db.exec("INSERT INTO live_events(job_id,kind,detail) VALUES(?1,?2,?3)", .{ id, kind, detail });
        try db.commit();
    }
    pub fn requestStart(self: *Runtime, a: A, id: i64) !void {
        var state = try self.load(a, id);
        if (!self.allowed(state.target)) return error.ExecutionNotAllowed;

        if (state.stage != .ready) return error.JobNotReady;
        if (state.analysis == null) return error.AnalysisMissing;
        const report = state.analysis.?.report;
        if (!allFiles(report.files) and report.compact_candidate_id == null) return error.NoCompactCandidate;
        if (allFiles(report.files) and report.upgrade_candidate_id == null) return error.NoUpgradeCandidate;
        if (state.analysis.?.report.created_at_ms + 5 * 60 * 1000 < std.Io.Timestamp.now(self.io, .real).toMilliseconds()) return error.AnalysisExpired;
        state.stage = .claiming;
        state.error_code = null;
        try self.save(a, id, &state, "execution_requested", "Execution requested for the allowed scope.");
    }
    pub fn cancel(self: *Runtime, a: A, id: i64) !void {
        const state = try self.load(a, id);
        if (state.stage == .completed or state.stage == .cancelled) return;
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        try db.exec("UPDATE live_jobs SET cancel_requested=1 WHERE id=?1", .{id});
        try db.exec("INSERT INTO live_events(job_id,kind,detail) VALUES(?1,'cancel_requested','Cancellation requested; downloads will not be removed.')", .{id});
    }
    pub fn reanalyze(self: *Runtime, a: A, id: i64) !void {
        var state = try self.load(a, id);
        if (state.cancel_requested or state.token != null or state.original_stopped or (state.stage != .ready and state.stage != .review and state.stage != .cancelled and state.stage != .completed)) return error.JobBusy;
        const db = try self.pool.acquire(self.io);
        {
            defer self.pool.release(self.io, db);
            if (try db.row("SELECT policy FROM settings WHERE id=1", .{})) |row| {
                defer row.deinit();
                state.policy = try std.json.parseFromSliceLeaky(E.Policy, a, row.text(0), .{});
            } else state.policy = .{};
        }
        state.stage = .queued;
        state.analysis = null;
        state.error_code = null;
        state.compact_hash = null;
        state.upgrade_hash = null;
        state.baseline = &.{};
        state.upgrade_selection_ids = &.{};
        state.adopt_original = false;
        state.generation += 1;
        try self.save(a, id, &state, "analysis_requested", "New analysis requested with current default profiles and limits.");
    }
    pub fn allowed(self: *const Runtime, ref: P.Ref) bool {
        if (!self.config.execution.enabled) return false;
        if ((ref.app == .radarr and self.config.execution.allow_all_movies) or (ref.app == .sonarr and self.config.execution.allow_all_series)) return true;
        const ids = if (ref.app == .radarr) self.config.execution.allowed_movie_ids else self.config.execution.allowed_series_ids;
        for (ids) |id| if (id == ref.media_id) {
            return true;
        };
        return false;
    }
    pub fn summaries(self: *Runtime, a: A) ![]const Summary {
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        var rows = try db.rows("SELECT id,state FROM live_jobs WHERE json_extract(state,'$.stage') IN ('queued','analyzing','claiming','compact','upgrading') OR cancel_requested=1 OR id IN (SELECT id FROM live_jobs ORDER BY id DESC LIMIT 100) ORDER BY id DESC", .{});
        defer rows.deinit();
        var list: std.ArrayList(Summary) = .empty;
        while (rows.next()) |row| {
            const state = try std.json.parseFromSliceLeaky(State, a, row.text(1), .{ .allocate = .alloc_always });
            try list.append(a, summary(row.int(0), state));
        }
        if (rows.err) |err| return err;
        return list.items;
    }
    pub fn events(self: *Runtime, a: A, id: i64) ![]const Event {
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        var rows = try db.rows("SELECT id,kind,detail,created_at FROM live_events WHERE job_id=?1 ORDER BY id DESC LIMIT 100", .{id});
        defer rows.deinit();
        var list: std.ArrayList(Event) = .empty;
        while (rows.next()) |row| try list.append(a, .{ .id = row.int(0), .kind = try a.dupe(u8, row.text(1)), .detail = try a.dupe(u8, row.text(2)), .created_at = try a.dupe(u8, row.text(3)) });
        if (rows.err) |err| return err;
        return list.items;
    }
    pub fn run(self: *Runtime) std.Io.Cancelable!void {
        while (true) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            self.tick(arena.allocator()) catch |err| std.log.err("controller tick: {s}", .{@errorName(err)});
            arena.deinit();
            try std.Io.sleep(self.io, .fromMilliseconds(2000), .awake);
        }
    }
    fn tick(self: *Runtime, a: A) !void {
        if (self.config.execution.automatic and self.next_scan_ms <= std.Io.Timestamp.now(self.io, .real).toMilliseconds()) {
            self.next_scan_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds() + 15000;
            self.scan(a) catch |err| std.log.warn("automatic intake: {s}", .{@errorName(err)});
        }
        const jobs = try self.summaries(a);
        var offset: usize = 0;
        for (jobs, 0..) |job, index| {
            if (job.id == self.last_job_id) offset = index + 1;
        }
        for (0..jobs.len) |index| {
            const job = jobs[(index + offset) % jobs.len];
            var state = try self.load(a, job.id);
            if (state.cancel_requested) {
                self.last_job_id = job.id;
                try self.compensate(a, job.id, &state);
                state.stage = .cancelled;
                state.cancel_requested = false;
                try self.save(a, job.id, &state, "cancelled", "Plan cancelled; copies preserved.");
                return;
            }
            switch (state.stage) {
                .queued, .analyzing => {
                    self.last_job_id = job.id;
                    state.stage = .analyzing;
                    try self.save(a, job.id, &state, "analysis_started", "Checking manifests, the native profile and releases.");
                    const analysis = P.analyze(a, self.io, self.config, state.target, state.policy, true) catch |err| {
                        state.stage = .review;
                        state.error_code = @errorName(err);
                        try self.save(a, job.id, &state, "analysis_failed", @errorName(err));
                        return;
                    };
                    const fresh = try self.load(a, job.id);
                    if (fresh.cancel_requested) return;
                    state.analysis = analysis;
                    state.target = analysis.report.target;
                    state.stage = .ready;
                    state.error_code = null;
                    try self.save(a, job.id, &state, "analysis_ready", "Analysis saved; no release was downloaded.");
                    if (state.automatic) {
                        if (allFiles(analysis.report.files)) {
                            state.stage = .completed;
                            try self.save(a, job.id, &state, "already_available", "A library copy is already available; native upgrades remain unchanged.");
                        } else self.requestStart(a, job.id) catch |err| {
                            state.stage = .review;
                            state.error_code = @errorName(err);
                            try self.save(a, job.id, &state, "needs_review", @errorName(err));
                        };
                    }
                    return;
                },
                .claiming, .compact, .upgrading => {
                    self.last_job_id = job.id;
                    const had_error = state.error_code != null;
                    self.advance(a, job.id, &state) catch |err| {
                        const previous_error = state.error_code;
                        state.error_code = @errorName(err);
                        if (err == error.UpstreamUnavailable or err == error.UpstreamTimeout or err == error.UpstreamUnauthorized or err == error.VpnNotHealthy) {
                            if (previous_error == null or !std.mem.eql(u8, previous_error.?, @errorName(err))) try self.save(a, job.id, &state, "waiting_external", @errorName(err));
                            return;
                        }
                        if (err == error.ExternalDownloadDetected) {
                            self.compensate(a, job.id, &state) catch |recovery_error| {
                                state.stage = .review;
                                state.error_code = @errorName(recovery_error);
                                try self.save(a, job.id, &state, "needs_review", "External download detected; restoring the original needs attention.");
                                return;
                            };
                            state.stage = .cancelled;
                            state.error_code = null;
                            try self.save(a, job.id, &state, "external_handoff", "Another app changed this download. Prontarr released control and preserved the replacement; native cleanup and upgrades remain enabled.");
                            return;
                        }
                        state.stage = .review;
                        self.restoreOriginal(a, job.id, &state) catch {};
                        try self.save(a, job.id, &state, "needs_review", @errorName(err));
                        return;
                    };
                    if (had_error) {
                        state.error_code = null;
                        try self.save(a, job.id, &state, "external_recovered", "Connection and checks restored; plan resumed.");
                    }
                    return;
                },
                else => {},
            }
        }
    }
    fn readPolicy(self: *Runtime, a: A) !E.Policy {
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        if (try db.row("SELECT policy FROM settings WHERE id=1", .{})) |row| {
            defer row.deinit();
            return std.json.parseFromSliceLeaky(E.Policy, a, row.text(0), .{});
        }
        return .{};
    }
    fn scan(self: *Runtime, a: A) !void {
        try self.vpn(a);
        const qb = self.config.qbittorrent orelse return error.ConnectionNotConfigured;
        const torrents = try P.get(a, qb, "/api/v2/torrents/info");
        if (torrents != .array) return error.InvalidUpstreamResponse;
        const policy = try self.readPolicy(a);
        for ([_]P.AppKind{ .radarr, .sonarr }) |app| {
            const conn = P.connection(self.config, app) catch continue;
            const queue = try P.get(a, conn, "/api/v3/queue?page=1&pageSize=1000");
            if ((J.num(queue, "totalRecords") orelse 1001) > 1000) continue;
            for (J.items(queue, "records")) |record| {
                const mid = J.num(record, if (app == .radarr) "movieId" else "seriesId") orelse continue;
                const hash = J.str(record, "downloadId") orelse continue;
                if (!J.validHash(hash)) continue;
                const ref = P.Ref{ .app = app, .media_id = mid, .original_hash = try std.ascii.allocLowerString(a, hash) };
                if (!self.allowed(ref)) continue;
                {
                    const db = try self.pool.acquire(self.io);
                    defer self.pool.release(self.io, db);
                    if (try db.row("SELECT 1 FROM intake_seen WHERE app=?1 AND media_id=?2 AND hash=?3", .{ @tagName(app), mid, ref.original_hash.? })) |row| {
                        row.deinit();
                        continue;
                    }
                    if (try db.row("SELECT 1 FROM live_jobs WHERE json_extract(state,'$.target.app')=?1 AND json_extract(state,'$.target.media_id')=?2 AND (json_extract(state,'$.stage') IN ('queued','analyzing','claiming','compact','upgrading') OR json_extract(state,'$.token') IS NOT NULL)", .{ @tagName(app), mid })) |row| {
                        row.deinit();
                        continue;
                    }
                }
                var torrent: ?J.Value = null;
                for (J.array(torrents)) |item| if (std.ascii.eqlIgnoreCase(J.str(item, "hash") orelse "", hash)) {
                    torrent = item;
                    break;
                };
                const info = torrent orelse continue;
                const status = J.str(info, "state") orelse continue;
                if (std.mem.startsWith(u8, status, "stopped") or std.mem.startsWith(u8, status, "paused") or std.mem.eql(u8, status, "error") or std.mem.eql(u8, status, "missingFiles")) continue;
                const progress = J.field(info, "progress");
                const fraction: f64 = if (progress == .float) progress.float else if (progress == .integer) @floatFromInt(progress.integer) else continue;
                if (!std.math.isFinite(fraction) or fraction < 0 or fraction >= 1) continue;
                const resolution = J.num(J.field(J.field(record, "quality"), "quality"), "resolution") orelse 0;
                if (fraction >= 0.1 and resolution > 1080) continue;
                const m = try P.media(a, self.config, ref);
                if (!(J.flag(m, "monitored") orelse false)) continue;
                if (app == .radarr and (J.flag(m, "hasFile") orelse true)) continue;
                const id = try self.createInternal(a, ref, policy, true);
                const db = try self.pool.acquire(self.io);
                defer self.pool.release(self.io, db);
                try db.exec("INSERT INTO intake_seen(app,media_id,hash,job_id) VALUES(?1,?2,?3,?4) ON CONFLICT DO NOTHING", .{ @tagName(app), mid, ref.original_hash.?, id });
            }
        }
    }
    fn vpn(self: *Runtime, a: A) !void {
        const connection = self.config.vpn_health orelse return error.ExecutionNotAllowed;
        const result = try P.get(a, connection, "/health");
        if (!(J.flag(result, "healthy") orelse false)) return error.VpnNotHealthy;
    }
    fn coordinator(self: *Runtime, a: A, id: i64, state: *State, release: bool) !void {
        if (self.config.execution.standalone) {
            const db = try self.pool.acquire(self.io);
            defer self.pool.release(self.io, db);
            if (release) {
                try db.exec("DELETE FROM live_ownership WHERE app=?1 AND media_id=?2 AND job_id=?3", .{ @tagName(state.target.app), state.target.media_id, id });
                state.token = null;
            } else {
                try db.exec("INSERT INTO live_ownership(app,media_id,job_id) VALUES(?1,?2,?3) ON CONFLICT(app,media_id) DO UPDATE SET job_id=excluded.job_id WHERE job_id=excluded.job_id", .{ @tagName(state.target.app), state.target.media_id, id });
                if (db.changes() == 0) return error.OwnershipConflict;
                state.token = try std.fmt.allocPrint(a, "local:{d}", .{id});
            }
            return;
        }
        const conn = self.config.coordinator orelse return error.ExecutionNotAllowed;
        const body = try std.json.Stringify.valueAlloc(a, .{ .app = @tagName(state.target.app), .media_id = state.target.media_id, .job_id = id, .token = state.token }, .{});
        const result = try J.parse(a, try T.mutate(a, conn, if (release) .ownership_release else .ownership_claim, body));
        if (release) {
            state.token = null;
        } else state.token = J.str(result, "token") orelse return error.OwnershipNotConfirmed;
    }
    fn releaseById(analysis: P.Analysis, id: []const u8) ?P.Release {
        for (analysis.releases) |release| if (std.mem.eql(u8, release.candidate.id, id)) {
            return release;
        };
        return null;
    }
    fn ensureOwner(self: *Runtime, a: A, id: i64, state: *State) !void {
        const was_unclaimed = state.token == null;
        try self.coordinator(a, id, state, false);
        if (was_unclaimed) try self.save(a, id, state, "ownership_confirmed", "Prontarr is the exclusive controller for this scope.");
    }
    fn nativeProfile(self: *Runtime, a: A, state: State) !J.Value {
        const m = try P.media(a, self.config, state.target);
        return P.loadProfile(a, self.config, state.target.app, P.selectedProfileId(state.policy, state.target.app, false) orelse J.num(m, "qualityProfileId") orelse return error.InvalidQualityProfile);
    }
    fn allFiles(current: []const P.FileState) bool {
        if (current.len == 0) return false;
        for (current) |file| if (!file.has_file or file.file_id == null) {
            return false;
        };
        return true;
    }
    fn changedFiles(before: []const P.FileState, after: []const P.FileState) bool {
        if (before.len == 0 or !allFiles(after)) return false;
        for (before) |old| {
            var changed = false;
            for (after) |next| if (old.episode_id == next.episode_id and old.file_id != next.file_id) {
                changed = true;
            };
            if (!changed) return false;
        }
        return true;
    }
    fn effect(self: *Runtime, _: A, id: i64, key: []const u8, kind: []const u8) !bool {
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        try db.exec("INSERT INTO live_effects(job_id,effect_key,kind,status) VALUES(?1,?2,?3,'planned') ON CONFLICT(job_id,effect_key) DO NOTHING", .{ id, key, kind });
        if (db.changes() > 0) return true;
        const row = (try db.row("SELECT status FROM live_effects WHERE job_id=?1 AND effect_key=?2", .{ id, key })) orelse return false;
        defer row.deinit();
        return std.mem.eql(u8, row.text(0), "planned");
    }
    fn effectStatus(self: *Runtime, id: i64, key: []const u8, status: []const u8) !void {
        const db = try self.pool.acquire(self.io);
        defer self.pool.release(self.io, db);
        try db.exec("UPDATE live_effects SET status=?1 WHERE job_id=?2 AND effect_key=?3", .{ status, id, key });
    }
    fn controlTorrent(self: *Runtime, a: A, id: i64, state: State, hash: []const u8, start: bool) !void {
        if (!J.validHash(hash)) return error.InvalidTorrentHash;
        try self.vpn(a);
        const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ if (start) "resume" else "stop", hash });
        _ = try self.effect(a, id, key, if (start) "qbit_start" else "qbit_stop");
        _ = try T.mutate(a, self.config.qbittorrent orelse return error.ConnectionNotConfigured, if (start) .qbit_start else .qbit_stop, try std.fmt.allocPrint(a, "hashes={s}", .{hash}));
        try self.effectStatus(id, key, "confirmed");
        _ = state;
    }
    fn restoreOriginal(self: *Runtime, a: A, id: i64, state: *State) !void {
        if (state.original_stopped) {
            if (state.target.original_hash) |hash| try self.controlTorrent(a, id, state.*, hash, true);
            state.original_stopped = false;
            try self.save(a, id, state, "original_resumed", "Original download progress preserved.");
        }
    }
    fn compensate(self: *Runtime, a: A, id: i64, state: *State) !void {
        try self.restoreOriginal(a, id, state);
        if (state.token != null) try self.coordinator(a, id, state, true);
    }
    fn queueHash(self: *Runtime, a: A, state: State, title: []const u8) !?[]const u8 {
        const queue = try P.get(a, try P.connection(self.config, state.target.app), "/api/v3/queue?page=1&pageSize=1000");
        for (J.items(queue, "records")) |record| {
            const mid = J.num(record, if (state.target.app == .radarr) "movieId" else "seriesId");
            if (mid != state.target.media_id) continue;
            if (std.mem.eql(u8, J.str(record, "title") orelse "", title)) return J.str(record, "downloadId");
        }
        return null;
    }
    fn queueRecordOwned(self: *Runtime, a: A, id: i64, state: State, record: J.Value, hash: []const u8) !bool {
        for ([_]?[]const u8{ state.target.original_hash, state.compact_hash, state.upgrade_hash }) |known| {
            if (known) |value| if (std.ascii.eqlIgnoreCase(value, hash)) return true;
        }
        // Episode plans can have several compact hashes. Match each queue entry to
        // a journaled request, not merely to an old release-search candidate.
        const analysis = state.analysis orelse return false;
        for ([_]bool{ false, true }) |upgrade| {
            const releases = if (upgrade) try activeUpgrades(a, state) else try choices(a, analysis, false);
            for (releases) |release| {
                const title_matches = std.mem.eql(u8, J.str(record, "title") orelse "", release.candidate.title);
                const matches = if (release.info_hash) |value| std.ascii.eqlIgnoreCase(value, hash) else title_matches;
                if (!matches) continue;
                const role: []const u8 = if (upgrade) "grab_upgrade" else "grab_compact";
                const key = if (release.candidate.episode_id == 0) try std.fmt.allocPrint(a, "{d}:{s}", .{ state.generation, role }) else try std.fmt.allocPrint(a, "{d}:{s}:{d}", .{ state.generation, role, release.candidate.episode_id });
                const db = try self.pool.acquire(self.io);
                defer self.pool.release(self.io, db);
                if (try db.row("SELECT 1 FROM live_effects WHERE job_id=?1 AND effect_key=?2 AND status IN ('sending','sent','uncertain')", .{ id, key })) |row| {
                    row.deinit();
                    return true;
                }
            }
        }
        return false;
    }
    fn queueRecordInScope(state: State, record: J.Value) bool {
        if (J.num(record, if (state.target.app == .radarr) "movieId" else "seriesId") != state.target.media_id) return false;
        if (state.target.app == .sonarr) {
            if (J.num(record, "episodeId")) |episode_id| {
                for (state.target.episode_ids) |wanted| if (wanted == episode_id) return true;
                return false;
            }
        }
        return true;
    }
    fn respectExternalQueue(self: *Runtime, a: A, id: i64, state: State) !void {
        const queue = try P.get(a, try P.connection(self.config, state.target.app), "/api/v3/queue?page=1&pageSize=1000");
        if ((J.num(queue, "totalRecords") orelse 1001) > 1000) return error.QueueScopeUnknown;
        var external = false;
        for (J.items(queue, "records")) |record| {
            if (!queueRecordInScope(state, record)) continue;
            const hash = J.str(record, "downloadId") orelse return error.QueueScopeUnknown;
            if (!J.validHash(hash)) return error.QueueScopeUnknown;
            if (try self.queueRecordOwned(a, id, state, record, hash)) continue;
            const db = try self.pool.acquire(self.io);
            defer self.pool.release(self.io, db);
            // Do not immediately take over a Cleanuparr/native replacement on the
            // next automatic intake scan after releasing this plan.
            try db.exec("INSERT INTO intake_seen(app,media_id,hash,job_id) VALUES(?1,?2,?3,?4) ON CONFLICT DO NOTHING", .{ @tagName(state.target.app), state.target.media_id, try std.ascii.allocLowerString(a, hash), id });
            external = true;
        }
        if (external) return error.ExternalDownloadDetected;
    }
    fn grab(self: *Runtime, a: A, id: i64, state: *State, release: P.Release, upgrade: bool) !void {
        if (release.guid.len == 0) return error.ExistingReleaseCannotBeGrabbed;
        const key = if (release.candidate.episode_id == 0) try std.fmt.allocPrint(a, "{d}:{s}", .{ state.generation, if (upgrade) "grab_upgrade" else "grab_compact" }) else try std.fmt.allocPrint(a, "{d}:{s}:{d}", .{ state.generation, if (upgrade) "grab_upgrade" else "grab_compact", release.candidate.episode_id });
        try self.vpn(a);
        const first = try self.effect(a, id, key, "arr_grab");
        if (first) {
            try self.respectExternalQueue(a, id, state.*);
            const fresh = try self.load(a, id);
            if (fresh.cancel_requested) return error.CancelRequested;
            try self.effectStatus(id, key, "sending");
            const payload = try std.json.Stringify.valueAlloc(a, .{ .guid = release.guid, .indexerId = release.indexer_id }, .{});
            _ = T.mutate(a, try P.connection(self.config, state.target.app), .arr_grab, payload) catch |err| {
                try self.effectStatus(id, key, "uncertain");
                if (err == error.UpstreamTimeout or err == error.UpstreamUnavailable) {
                    try self.save(a, id, state, "grab_uncertain", "Uncertain response; do not repeat the grab. Reconcile the queue or import.");
                    return;
                }
                return err;
            };
            try self.effectStatus(id, key, "sent");
            try self.save(a, id, state, if (upgrade) "upgrade_grabbed" else "compact_grabbed", release.candidate.title);
        }
        const found = try self.queueHash(a, state.*, release.candidate.title);
        const hash = found orelse release.info_hash;
        if (hash) |value| if (J.validHash(value)) {
            if (upgrade) state.upgrade_hash = value else state.compact_hash = value;
        };
    }
    fn choices(a: A, analysis: P.Analysis, upgrade: bool) ![]const P.Release {
        const selections = if (upgrade) analysis.report.upgrade_selections else analysis.report.compact_selections;
        var out: std.ArrayList(P.Release) = .empty;
        for (selections) |selection| {
            const value = releaseById(analysis, selection.candidate_id) orelse return error.AnalysisMissing;
            var duplicate = false;
            for (out.items) |previous| if (std.mem.eql(u8, previous.candidate.id, value.candidate.id)) {
                duplicate = true;
            };
            if (!duplicate) try out.append(a, value);
        }
        if (out.items.len == 0) {
            if (if (upgrade) analysis.report.upgrade_candidate_id else analysis.report.compact_candidate_id) |id| try out.append(a, releaseById(analysis, id) orelse return error.AnalysisMissing);
        }
        return out.items;
    }
    fn activeUpgrades(a: A, state: State) ![]const P.Release {
        const analysis = state.analysis orelse return error.AnalysisMissing;
        if (state.upgrade_selection_ids.len == 0) return choices(a, analysis, true);
        var out: std.ArrayList(P.Release) = .empty;
        for (state.upgrade_selection_ids) |id| try out.append(a, releaseById(analysis, id) orelse return error.AnalysisMissing);
        return out.items;
    }
    fn usesOriginal(state: State) bool {
        return state.target.original_hash != null and !state.adopt_original;
    }
    fn beginUpgrade(self: *Runtime, a: A, id: i64, state: *State, current: []const P.FileState, profile: J.Value) !void {
        const targets = try choices(a, state.analysis orelse return error.AnalysisMissing, true);
        var baseline: std.ArrayList(P.FileState) = .empty;
        var ids: std.ArrayList([]const u8) = .empty;
        for (targets) |target| {
            var selected = false;
            for (current) |file| {
                if (!usesOriginal(state.*) and file.episode_id != target.candidate.episode_id) continue;
                const result = P.compare(profile, file.quality_id, file.format_score, target.candidate.quality_id, target.candidate.format_score);
                if (result.better == null) return error.NotAVerifiedUpgrade;
                if (!result.better.?) continue;
                var duplicate = false;
                for (baseline.items) |before| if (before.episode_id == file.episode_id) {
                    duplicate = true;
                };
                if (!duplicate) try baseline.append(a, file);
                selected = true;
            }
            if (selected) try ids.append(a, target.candidate.id);
        }
        if (baseline.items.len == 0) {
            try self.compensate(a, id, state);
            state.stage = .completed;
            try self.save(a, id, state, "completed", "A watchable copy is available. No higher approved release currently meets the final profile; native Arr searches remain enabled.");
            return;
        }
        state.baseline = baseline.items;
        state.upgrade_selection_ids = ids.items;
        state.stage = .upgrading;
        state.upgrade_sent_at_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        try self.save(a, id, state, "upgrade_planned", "Upgrade confirmed by the profile; first copy remains available.");
        if (usesOriginal(state.*)) {
            state.upgrade_hash = state.target.original_hash;
            try self.restoreOriginal(a, id, state);
        } else {
            for (try activeUpgrades(a, state.*)) |target| try self.grab(a, id, state, target, true);
        }
        try self.save(a, id, state, "", "");
    }
    fn advance(self: *Runtime, a: A, id: i64, state: *State) !void {
        if (!self.allowed(state.target)) return error.ExecutionNotAllowed;
        try self.vpn(a);
        const analysis = state.analysis orelse return error.AnalysisMissing;
        const profile = try self.nativeProfile(a, state.*);
        const current = try P.files(a, self.config, state.target, profile);
        const compact = try choices(a, analysis, false);
        if (state.stage == .compact or state.stage == .upgrading) try self.respectExternalQueue(a, id, state.*);
        if (state.stage == .claiming) {
            const queue = try P.get(a, try P.connection(self.config, state.target.app), "/api/v3/queue?page=1&pageSize=1000");
            if ((J.num(queue, "totalRecords") orelse 1001) > 1000) return error.QueueScopeUnknown;
            for (J.items(queue, "records")) |record| {
                if (!queueRecordInScope(state.*, record)) continue;
                const hash = J.str(record, "downloadId") orelse return error.QueueScopeUnknown;
                if (state.target.original_hash == null or !std.ascii.eqlIgnoreCase(hash, state.target.original_hash.?)) return error.ExistingDownloadNeedsAnalysis;
            }
            if (state.target.original_hash) |hash| {
                const source = analysis.report.original orelse return error.OriginalUpgradeNeedsVerification;
                const info = try P.get(a, self.config.qbittorrent orelse return error.ConnectionNotConfigured, try std.fmt.allocPrint(a, "/api/v2/torrents/info?hashes={s}", .{hash}));
                if (J.array(info).len != 1) return error.OriginalTorrentNotFound;
                const torrent = J.array(info)[0];
                if (!std.ascii.eqlIgnoreCase(J.str(torrent, "hash") orelse "", hash)) return error.OriginalTorrentNotFound;
                const status = J.str(torrent, "state") orelse return error.UnknownTorrentState;
                if ((std.mem.startsWith(u8, status, "stopped") or std.mem.startsWith(u8, status, "paused")) and !state.original_stopped) return error.RespectManualPause;
                const raw = J.field(torrent, "progress");
                const progress: f64 = if (raw == .float) raw.float else if (raw == .integer) @floatFromInt(raw.integer) else return error.UnknownTorrentState;
                if (!std.math.isFinite(progress) or progress < 0 or progress > 1 or std.mem.eql(u8, status, "error") or std.mem.eql(u8, status, "missingFiles")) return error.UnknownTorrentState;
                state.adopt_original = source.compact;
                if (!allFiles(current) and !source.compact) {
                    if (!std.math.isFinite(progress) or progress >= 0.1) return error.RespectExistingProgress;
                    if (compact.len != (if (state.target.app == .radarr) @as(usize, 1) else state.target.episode_ids.len)) return error.NoCompactCandidate;
                    for (compact) |candidate| if (P.compare(profile, candidate.candidate.quality_id, candidate.candidate.format_score, source.quality_id, source.format_score).better != true) return error.NotAVerifiedUpgrade;
                }
            }
        }
        try self.ensureOwner(a, id, state);
        if (state.stage == .claiming and allFiles(current)) return self.beginUpgrade(a, id, state, current, profile);
        if (state.stage == .claiming) {
            if (state.adopt_original) {
                state.compact_hash = state.target.original_hash;
            } else {
                const wanted: usize = if (state.target.app == .radarr) 1 else state.target.episode_ids.len;
                if (compact.len != wanted) return error.NoCompactCandidate;
                for (compact) |selected| if (!selected.candidate.compact or !selected.candidate.native_approved or selected.guid.len == 0) return error.UnsafeCandidate;
                if (state.target.original_hash) |hash| {
                    state.original_stopped = true;
                    try self.save(a, id, state, "original_stop_planned", "Record recovery actions before pausing the original.");
                    try self.controlTorrent(a, id, state.*, hash, false);
                }
            }
            state.stage = .compact;
            state.compact_sent_at_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            try self.save(a, id, state, "awaiting_compact", if (state.adopt_original) "The existing compact download was adopted without another grab." else "First copy is downloading; library preserved.");
            if (!state.adopt_original) for (compact) |selected| {
                try self.grab(a, id, state, selected, false);
            };
            try self.save(a, id, state, "", "");
            return;
        }
        if (state.stage == .compact) {
            if (!allFiles(current)) {
                if (std.Io.Timestamp.now(self.io, .real).toMilliseconds() - state.compact_sent_at_ms > 6 * 3600 * 1000) return error.CompactImportTimeout;
                if (!state.adopt_original) for (compact) |selected| {
                    try self.grab(a, id, state, selected, false);
                };
                try self.save(a, id, state, "", "");
                return;
            }
            try self.save(a, id, state, "compact_imported", "Imported files confirmed for all items; recording file identities before upgrading.");
            return self.beginUpgrade(a, id, state, current, profile);
        }
        if (state.stage == .upgrading) {
            if (changedFiles(state.baseline, current)) {
                const targets = try activeUpgrades(a, state.*);
                for (state.baseline) |before| {
                    var after: ?P.FileState = null;
                    for (current) |file| if (file.episode_id == before.episode_id) {
                        after = file;
                        break;
                    };
                    const file = after orelse return error.UnknownFileIdentity;
                    var expected_target: ?P.Candidate = null;
                    for (targets) |target| if (usesOriginal(state.*) or target.candidate.episode_id == file.episode_id) {
                        expected_target = target.candidate;
                        break;
                    };
                    const target = expected_target orelse return error.AnalysisMissing;
                    const rank = P.qualityRank(profile, file.quality_id orelse return error.UnknownFileIdentity) orelse return error.InvalidQualityProfile;
                    const expected = P.qualityRank(profile, target.quality_id) orelse return error.InvalidQualityProfile;
                    if (rank.rank < expected.rank or (rank.rank == expected.rank and (file.format_score orelse return error.UnknownFileIdentity) < target.format_score)) return error.ImportedFileDoesNotMeetTarget;
                    if (P.compare(profile, before.quality_id, before.format_score, file.quality_id.?, file.format_score orelse return error.UnknownFileIdentity).better != true) return error.NotAVerifiedUpgrade;
                }
                try self.compensate(a, id, state);
                state.stage = .completed;
                try self.save(a, id, state, "completed", "Arr imported the upgrade and replaced the library copy. Prontarr did not directly delete any files.");
                return;
            }
            if (usesOriginal(state.*)) {
                try self.restoreOriginal(a, id, state);
            } else {
                for (try activeUpgrades(a, state.*)) |target| try self.grab(a, id, state, target, true);
            }
            try self.save(a, id, state, "", "");
        }
    }
};
pub fn summary(id: i64, state: State) Summary {
    return .{ .id = id, .target = state.target, .title = if (state.analysis) |analysis| analysis.report.title else "Analyzing title…", .stage = state.stage, .error_code = state.error_code, .created_at_ms = state.created_at_ms, .updated_at_ms = state.updated_at_ms, .compact_hash = state.compact_hash, .upgrade_hash = state.upgrade_hash };
}
pub fn migrate(conn: DB.Conn) !void {
    try conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS live_jobs(id INTEGER PRIMARY KEY,request_key TEXT UNIQUE NOT NULL,state TEXT NOT NULL,cancel_requested INTEGER NOT NULL DEFAULT 0);
        \\CREATE TABLE IF NOT EXISTS live_events(id INTEGER PRIMARY KEY,job_id INTEGER NOT NULL,kind TEXT NOT NULL,detail TEXT NOT NULL,created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')));
        \\CREATE TABLE IF NOT EXISTS live_effects(id INTEGER PRIMARY KEY,job_id INTEGER NOT NULL,effect_key TEXT NOT NULL,kind TEXT NOT NULL,status TEXT NOT NULL,UNIQUE(job_id,effect_key));
        \\CREATE TABLE IF NOT EXISTS live_ownership(app TEXT NOT NULL,media_id INTEGER NOT NULL,job_id INTEGER NOT NULL,PRIMARY KEY(app,media_id));
        \\CREATE TABLE IF NOT EXISTS intake_seen(app TEXT NOT NULL,media_id INTEGER NOT NULL,hash TEXT NOT NULL,job_id INTEGER,PRIMARY KEY(app,media_id,hash));
        \\PRAGMA user_version=3;
    );
}
pub fn lockProcess(a: A, path: []const u8) !c_int {
    const file = try std.fmt.allocPrintSentinel(a, "{s}.controller.lock", .{path}, 0);
    const fd = C.open(file.ptr, C.O_CREAT | C.O_RDWR | C.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.ControllerLockFailed;
    if (C.flock(fd, C.LOCK_EX | C.LOCK_NB) != 0) {
        _ = C.close(fd);
        return error.ControllerAlreadyRunning;
    }
    return fd;
}
pub fn unlockProcess(fd: c_int) void {
    _ = C.close(fd);
}
