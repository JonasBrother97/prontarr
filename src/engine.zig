const std = @import("std");

pub const Stage = enum { missing, compact_downloading, watchable, upgrading, complete };
pub const Action = enum { wait, download_compact, search_upgrade, keep_available, complete };
pub const ProfilePair = struct { initial_id: ?i64 = null, final_id: ?i64 = null };
pub const Policy = struct {
    radarr_profiles: ProfilePair = .{},
    sonarr_profiles: ProfilePair = .{},
    max_compact_bytes: u64 = 4 * 1024 * 1024 * 1024,
    min_seeders: u32 = 3,
    min_resolution: u16 = 720,
    max_resolution: u16 = 1080,
};
pub const Candidate = struct {
    id: []const u8,
    title: []const u8,
    bytes: u64,
    seeders: u32,
    resolution: u16,
    original_audio: bool = true,
    arr_approved: bool = true,
    remux: bool = false,
};
pub const Snapshot = struct {
    stage: Stage = .missing,
    imported_episodes: u32 = 0,
    expected_episodes: u32 = 1,
    upgrade_import_confirmed: bool = false,
};
pub const Input = struct {
    title: []const u8,
    policy: Policy = .{},
    snapshot: Snapshot = .{},
    candidates: []const Candidate = &.{},
};
pub const Decision = struct {
    action: Action,
    next_stage: Stage,
    candidate_id: ?[]const u8 = null,
    reason: []const u8,
    estimated_speed: bool = true,
    may_remove_first_copy: bool = false,
};

pub fn validate(input: Input) !void {
    if (std.mem.trim(u8, input.title, " \t\r\n").len == 0 or input.title.len > 300) return error.InvalidTitle;
    if (input.snapshot.expected_episodes == 0 or input.snapshot.expected_episodes > 1000) return error.InvalidEpisodeCount;
    if (input.snapshot.imported_episodes > input.snapshot.expected_episodes) return error.InvalidEpisodeCount;
    for ([_]ProfilePair{ input.policy.radarr_profiles, input.policy.sonarr_profiles }) |pair| {
        if ((pair.initial_id != null and pair.initial_id.? <= 0) or (pair.final_id != null and pair.final_id.? <= 0)) return error.InvalidProfileId;
    }
    if (input.policy.max_compact_bytes == 0 or input.policy.min_seeders == 0) return error.InvalidPolicy;
    if (input.policy.min_resolution > input.policy.max_resolution or input.policy.max_resolution > 1080) return error.InvalidPolicy;
    if (input.policy.min_resolution != 720 and input.policy.min_resolution != 1080) return error.InvalidPolicy;
    if (input.policy.max_resolution != 720 and input.policy.max_resolution != 1080) return error.InvalidPolicy;
    if (input.candidates.len > 1000) return error.TooManyCandidates;
    for (input.candidates) |c| {
        if (c.id.len == 0 or c.id.len > 200 or c.title.len > 500) return error.InvalidCandidate;
    }
    for (input.candidates, 0..) |c, i| {
        for (input.candidates[0..i]) |previous| {
            if (std.mem.eql(u8, previous.id, c.id)) return error.DuplicateCandidateId;
        }
    }
}

pub fn eligible(c: Candidate, p: Policy) bool {
    return c.arr_approved and c.original_audio and !c.remux and c.bytes > 0 and
        c.bytes <= p.max_compact_bytes and c.seeders >= p.min_seeders and
        c.resolution >= p.min_resolution and c.resolution <= p.max_resolution;
}

// A relative availability heuristic, never a promise of download throughput.
fn score(c: Candidate) f64 {
    const gib = @as(f64, @floatFromInt(c.bytes)) / (1024 * 1024 * 1024);
    return @log2(@as(f64, @floatFromInt(c.seeders)) + 1) / std.math.pow(f64, @max(gib, 0.4), 0.45);
}

pub fn decide(input: Input) Decision {
    const s = input.snapshot;
    const all_available = s.imported_episodes == s.expected_episodes;
    if (s.stage == .complete) return .{ .action = .complete, .next_stage = .complete, .reason = "Plan completed; no further action." };
    if (s.stage == .upgrading) {
        if (all_available and s.upgrade_import_confirmed) return .{
            .action = .complete,
            .next_stage = .complete,
            .reason = "Upgrade import confirmed for the full scope. Arr handles replacement.",
        };
        return .{ .action = .keep_available, .next_stage = .upgrading, .reason = "Keep the first copy until the upgrade is confirmed for every episode." };
    }
    if (all_available) return .{ .action = .search_upgrade, .next_stage = .upgrading, .reason = "First copy imported for the full scope; the upgrade can begin." };
    if (s.stage != .missing) return .{ .action = .wait, .next_stage = s.stage, .reason = "Wait for all episodes to be imported; a completed download alone is not enough." };
    var best: ?Candidate = null;
    for (input.candidates) |candidate| {
        if (!eligible(candidate, input.policy)) continue;
        if (best == null or score(candidate) > score(best.?)) best = candidate;
    }
    if (best) |candidate| return .{
        .action = .download_compact,
        .next_stage = .compact_downloading,
        .candidate_id = candidate.id,
        .reason = "Eligible compact release with the best estimated availability relative to size. Actual speed is not guaranteed.",
    };
    return .{ .action = .wait, .next_stage = .missing, .reason = "No compact release meets the constraints. Preserve any existing download." };
}

test "never start an upgrade while a season is partly imported" {
    const d = decide(.{ .title = "Season", .snapshot = .{ .stage = .compact_downloading, .expected_episodes = 8, .imported_episodes = 7 } });
    try std.testing.expectEqual(Action.wait, d.action);
}
test "reject forbidden audio even with many seeds" {
    const candidates = [_]Candidate{
        .{ .id = "dub", .title = "Dubbed", .bytes = 100, .seeders = 9999, .resolution = 1080, .original_audio = false },
        .{ .id = "good", .title = "Original", .bytes = 1024 * 1024 * 1024, .seeders = 20, .resolution = 1080 },
    };
    const d = decide(.{ .title = "Movie", .candidates = &candidates });
    try std.testing.expectEqualStrings("good", d.candidate_id.?);
}
test "no candidate does not cancel original download" {
    const d = decide(.{ .title = "Movie" });
    try std.testing.expectEqual(Action.wait, d.action);
    try std.testing.expect(!d.may_remove_first_copy);
}
test "partial upgraded season cannot complete" {
    const d = decide(.{ .title = "Season", .snapshot = .{ .stage = .upgrading, .expected_episodes = 8, .imported_episodes = 7, .upgrade_import_confirmed = true } });
    try std.testing.expectEqual(Action.keep_available, d.action);
}
test "respect arr rejection and size limit" {
    try std.testing.expect(!eligible(.{ .id = "a", .title = "Blocked", .bytes = 100, .seeders = 100, .resolution = 1080, .arr_approved = false }, .{}));
    try std.testing.expect(!eligible(.{ .id = "b", .title = "Huge", .bytes = 20 * 1024 * 1024 * 1024, .seeders = 100, .resolution = 1080 }, .{}));
}
test "confirmed upgrade completes without issuing a deletion" {
    const d = decide(.{ .title = "Movie", .snapshot = .{ .stage = .upgrading, .imported_episodes = 1, .upgrade_import_confirmed = true } });
    try std.testing.expectEqual(Action.complete, d.action);
    try std.testing.expect(!d.may_remove_first_copy);
}

test "ambiguous release identities are rejected before selection" {
    const candidates = [_]Candidate{
        .{ .id = "same", .title = "A", .bytes = 100, .seeders = 10, .resolution = 1080 },
        .{ .id = "same", .title = "B", .bytes = 100, .seeders = 20, .resolution = 1080 },
    };
    try std.testing.expectError(error.DuplicateCandidateId, validate(.{ .title = "Movie", .candidates = &candidates }));
}

test "impossible scope and unrecognized resolutions are rejected" {
    try std.testing.expectError(error.InvalidEpisodeCount, validate(.{ .title = "Movie", .snapshot = .{ .imported_episodes = 2 } }));
    try std.testing.expectError(error.InvalidPolicy, validate(.{ .title = "Movie", .policy = .{ .min_resolution = 0 } }));
    try std.testing.expectError(error.InvalidTitle, validate(.{ .title = "  " }));
}
