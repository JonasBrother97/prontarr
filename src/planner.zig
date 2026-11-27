const std = @import("std");
const J = @import("json_helpers.zig");
const T = @import("transport.zig");
const E = @import("engine.zig");
const A = std.mem.Allocator;
pub const AppKind = enum { radarr, sonarr };
pub const Ref = struct { app: AppKind, media_id: i64, episode_ids: []const i64 = &.{}, original_hash: ?[]const u8 = null };
pub const FileState = struct { episode_id: i64, has_file: bool, file_id: ?i64, quality_id: ?i64 = null, format_score: ?i64 = null };
pub const ScopeFile = struct { bytes: u64 = 0, name: []const u8, selected: bool, episode_ids: []const i64 };
pub const Scope = struct { verified: bool, contained_episode_ids: []const i64, selected_episode_ids: []const i64, absent_queue_episode_ids: []const i64, files: []const ScopeFile, warnings: []const []const u8 };
pub const QualityRank = struct { rank: i64, allowed: bool };
pub const Comparison = struct { better: ?bool, reason: []const u8 };
pub const Candidate = struct {
    episode_id: i64 = 0,
    id: []const u8,
    title: []const u8,
    bytes: u64,
    seeds: u32,
    resolution: u16,
    quality_id: i64,
    quality: []const u8,
    format_score: i64,
    original_audio: bool,
    native_approved: bool,
    compact: bool,
    upgrade: ?bool,
    reason: []const u8,
    surround_hint: bool = false,
};
pub const Release = struct { candidate: Candidate, guid: []const u8, indexer_id: i64, info_hash: ?[]const u8 = null };
pub const Selection = struct { episode_id: i64, candidate_id: []const u8 };
pub const Original = struct { hash: []const u8, title: []const u8, quality_id: i64, format_score: i64, resolution: u16, bytes: u64, compact: bool, paused: bool, progress: f64 };
pub const Report = struct { original: ?Original = null, compact_selections: []const Selection = &.{}, upgrade_selections: []const Selection = &.{}, target: Ref, title: []const u8, profile_name: []const u8, initial_profile_name: ?[]const u8 = null, initial_profile_id: ?i64 = null, final_profile_id: ?i64 = null, native_profile_name: ?[]const u8 = null, upgrade_allowed: bool, scope: ?Scope = null, files: []const FileState, candidates: []const Candidate, compact_candidate_id: ?[]const u8 = null, upgrade_candidate_id: ?[]const u8 = null, searched: bool, created_at_ms: i64, notes: []const []const u8 = &.{} };
pub const Analysis = struct { report: Report, releases: []const Release };
pub fn connection(config: T.Config, app: AppKind) !T.Connection {
    return (if (app == .radarr) config.radarr else config.sonarr) orelse error.ConnectionNotConfigured;
}
pub fn get(a: A, c: T.Connection, path: []const u8) !J.Value {
    return J.parse(a, try T.get(a, c, path));
}
pub fn validate(ref: Ref) !void {
    if (ref.media_id <= 0 or ref.episode_ids.len > 500) return error.InvalidMediaReference;
    if (ref.app == .sonarr and ref.episode_ids.len == 0 and ref.original_hash == null) return error.UnknownEpisodeScope;
    if (ref.app == .radarr and ref.episode_ids.len != 0) return error.InvalidMediaReference;
    for (ref.episode_ids, 0..) |id, i| {
        if (id <= 0) return error.InvalidMediaReference;
        for (ref.episode_ids[0..i]) |prev| if (prev == id) {
            return error.DuplicateEpisode;
        };
    }
    if (ref.original_hash) |hash| if (!J.validHash(hash)) {
        return error.InvalidTorrentHash;
    };
}
fn contains(ids: []const i64, id: i64) bool {
    for (ids) |v| if (v == id) {
        return true;
    };
    return false;
}
fn addUnique(a: A, list: *std.ArrayList(i64), id: i64) !void {
    if (!contains(list.items, id)) try list.append(a, id);
}
fn normalized(a: A, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| if (std.ascii.isAlphanumeric(c)) {
        try out.append(a, std.ascii.toLower(c));
    };
    return out.items;
}
fn video(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".mkv", ".mp4", ".avi", ".m4v", ".ts", ".wmv", ".webm", ".mpg", ".mpeg" }) |x| if (std.ascii.eqlIgnoreCase(ext, x)) {
        return true;
    };
    return false;
}
pub fn qualityRank(profile: J.Value, id: i64) ?QualityRank {
    for (J.items(profile, "items"), 0..) |item, rank| {
        if (findQuality(item, id, J.flag(item, "allowed") orelse false)) |allowed| return .{ .rank = @intCast(rank), .allowed = allowed };
    }
    return null;
}
fn findQuality(item: J.Value, id: i64, allowed: bool) ?bool {
    if (J.num(item, "id") == id) return allowed;
    if (J.num(J.field(item, "quality"), "id")) |found| if (found == id) {
        return allowed;
    };
    for (J.items(item, "items")) |child| if (findQuality(child, id, allowed and (J.flag(child, "allowed") orelse false))) |result| {
        return result;
    };
    return null;
}
pub fn formatScore(profile: J.Value, object: J.Value) ?i64 {
    if (J.field(object, "customFormats") != .array) return J.num(object, "customFormatScore");
    var total: i64 = 0;
    for (J.items(object, "customFormats")) |format| {
        const id = J.num(format, "id") orelse continue;
        for (J.items(profile, "formatItems")) |entry| if (J.num(entry, "format") == id) {
            total += J.num(entry, "score") orelse 0;
        };
    }
    return total;
}
pub fn compare(profile: J.Value, current_quality: ?i64, current_score: ?i64, next_quality: i64, next_score: i64) Comparison {
    if (!(J.flag(profile, "upgradeAllowed") orelse false)) return .{ .better = false, .reason = "Upgrades are disabled in the native profile." };
    const before = qualityRank(profile, current_quality orelse return .{ .better = null, .reason = "Current quality is unknown." }) orelse return .{ .better = null, .reason = "Current quality is not in the profile." };
    const after = qualityRank(profile, next_quality) orelse return .{ .better = false, .reason = "Candidate quality is not in the profile." };
    if (!after.allowed or next_score < (J.num(profile, "minFormatScore") orelse 0)) return .{ .better = false, .reason = "Quality or formats are not allowed by the profile." };
    if (J.num(profile, "cutoff")) |cutoff| {
        if (qualityRank(profile, cutoff)) |limit| {
            if (before.rank >= limit.rank and current_score != null and current_score.? >= (J.num(profile, "cutoffFormatScore") orelse 0)) return .{ .better = false, .reason = "The profile quality and format cutoffs have already been met." };
        }
    }
    if (after.rank > before.rank) return .{ .better = true, .reason = "Higher quality in the native profile hierarchy." };
    if (after.rank < before.rank) return .{ .better = false, .reason = "Lower quality in the native profile hierarchy." };
    const score = current_score orelse return .{ .better = null, .reason = "Current score is unknown; do not assume an upgrade within the same quality." };
    const better = next_score > score and next_score - score >= (J.num(profile, "minUpgradeFormatScore") orelse 1);
    return .{ .better = better, .reason = if (better) "Same quality, with sufficient format improvement for the profile." else "Does not meet the profile minimum format improvement." };
}
pub fn selectedProfileId(policy: E.Policy, app: AppKind, initial: bool) ?i64 {
    const pair = if (app == .radarr) policy.radarr_profiles else policy.sonarr_profiles;
    return if (initial) pair.initial_id else pair.final_id;
}
pub fn loadProfile(a: A, config: T.Config, app: AppKind, id: i64) !J.Value {
    const profile = try get(a, try connection(config, app), try std.fmt.allocPrint(a, "/api/v3/qualityprofile/{d}", .{id}));
    if (J.field(profile, "items") != .array or J.str(profile, "name") == null) return error.InvalidQualityProfile;
    return profile;
}
fn scoreFor(profile: J.Value, object: J.Value, allow_native: bool) ?i64 {
    if (!allow_native and J.field(object, "customFormats") != .array) return null;
    return formatScore(profile, object);
}
pub fn media(a: A, config: T.Config, ref: Ref) !J.Value {
    const c = try connection(config, ref.app);
    return get(a, c, try std.fmt.allocPrint(a, "/api/v3/{s}/{d}", .{ if (ref.app == .radarr) "movie" else "series", ref.media_id }));
}
pub fn files(a: A, config: T.Config, ref: Ref, profile: J.Value) ![]const FileState {
    const c = try connection(config, ref.app);
    const assigned = try media(a, config, ref);
    const allow_native = (J.num(profile, "id") orelse J.num(assigned, "qualityProfileId")) == J.num(assigned, "qualityProfileId");
    var result: std.ArrayList(FileState) = .empty;
    if (ref.app == .radarr) {
        const m = try media(a, config, ref);
        const has = J.flag(m, "hasFile") orelse return error.UnknownFileIdentity;
        var f = J.field(m, "movieFile");
        const id = J.num(f, "id");
        if (has and (id == null or id.? <= 0)) return error.UnknownFileIdentity;
        // Embedded MovieFile resources omit computed custom formats in Radarr.
        // Load the dedicated resource before comparing a post-import upgrade.
        if (has and J.field(f, "customFormats") != .array) {
            f = try get(a, c, try std.fmt.allocPrint(a, "/api/v3/moviefile/{d}", .{id.?}));
            if (J.num(f, "id") != id) return error.UnknownFileIdentity;
        }
        try result.append(a, .{ .episode_id = 0, .has_file = has, .file_id = if (has) id else null, .quality_id = J.num(J.field(J.field(f, "quality"), "quality"), "id"), .format_score = scoreFor(profile, f, allow_native) });
    } else {
        if (ref.episode_ids.len == 0) return error.UnknownEpisodeScope;
        for (ref.episode_ids) |id| {
            const ep = try get(a, c, try std.fmt.allocPrint(a, "/api/v3/episode/{d}", .{id}));
            if (J.num(ep, "seriesId") != ref.media_id) return error.EpisodeSeriesMismatch;
            const has = J.flag(ep, "hasFile") orelse return error.UnknownFileIdentity;
            const fid = J.num(ep, "episodeFileId");
            if (has and (fid == null or fid.? <= 0)) return error.UnknownFileIdentity;
            const f = if (has) try get(a, c, try std.fmt.allocPrint(a, "/api/v3/episodefile/{d}", .{fid.?})) else J.Value.null;
            try result.append(a, .{ .episode_id = id, .has_file = has, .file_id = if (has) fid else null, .quality_id = J.num(J.field(J.field(f, "quality"), "quality"), "id"), .format_score = scoreFor(profile, f, allow_native) });
        }
    }
    return result.items;
}
pub fn scope(a: A, config: T.Config, ref: Ref, m: J.Value) !Scope {
    const hash = ref.original_hash orelse return error.TorrentRequired;
    const qb = config.qbittorrent orelse return error.ConnectionNotConfigured;
    const raw = try get(a, qb, try std.fmt.allocPrint(a, "/api/v2/torrents/files?hash={s}", .{hash}));
    if (raw != .array or raw.array.items.len == 0 or raw.array.items.len > 2000) return error.InvalidTorrentManifest;
    const c = try connection(config, ref.app);
    const catalogue = try get(a, c, try std.fmt.allocPrint(a, "/api/v3/episode?seriesId={d}", .{ref.media_id}));
    if (catalogue != .array) return error.InvalidEpisodeCatalogue;
    var contained: std.ArrayList(i64) = .empty;
    var selected: std.ArrayList(i64) = .empty;
    var manifest: std.ArrayList(ScopeFile) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    const title_norm = try normalized(a, J.str(m, "title") orelse return error.InvalidMediaReference);
    for (J.array(raw)) |file| {
        const name = J.str(file, "name") orelse return error.InvalidTorrentManifest;
        if (!video(name)) continue;
        const priority = J.num(file, "priority");
        const enabled = (priority orelse 0) > 0;
        var ids: std.ArrayList(i64) = .empty;
        const base = std.fs.path.basename(name);
        const parsed = try get(a, c, try std.fmt.allocPrint(a, "/api/v3/parse?title={s}", .{try J.encode(a, base)}));
        const info = J.field(parsed, "parsedEpisodeInfo");
        const series_name = try normalized(a, J.str(info, "seriesTitle") orelse "");
        var matches = title_norm.len > 0 and std.mem.eql(u8, title_norm, series_name);
        for (J.items(m, "alternateTitles")) |alt| {
            const norm = try normalized(a, J.str(alt, "title") orelse "");
            if (norm.len > 0 and std.mem.eql(u8, norm, series_name)) matches = true;
        }
        if (matches) {
            const season = J.num(info, "seasonNumber");
            for (J.items(info, "episodeNumbers")) |number| {
                const n = J.int(number) orelse continue;
                var found: ?i64 = null;
                for (J.array(catalogue)) |ep| if (J.num(ep, "seasonNumber") == season and J.num(ep, "episodeNumber") == n and J.num(ep, "seriesId") == ref.media_id) {
                    if (found != null) return error.AmbiguousEpisodeIdentity;
                    found = J.num(ep, "id");
                };
                if (found) |id| {
                    try addUnique(a, &ids, id);
                    try addUnique(a, &contained, id);
                    if (enabled) try addUnique(a, &selected, id);
                }
            }
        }
        if (ids.items.len == 0 or priority == null) try warnings.append(a, try std.fmt.allocPrint(a, "File scope or priority is unconfirmed: {s}", .{base}));
        try manifest.append(a, .{ .bytes = @intCast(@max(0, J.num(file, "size") orelse 0)), .name = name, .selected = enabled, .episode_ids = ids.items });
    }
    var absent: std.ArrayList(i64) = .empty;
    const queue = try get(a, c, "/api/v3/queue?page=1&pageSize=1000&includeEpisode=true");
    if ((J.num(queue, "totalRecords") orelse 1001) > 1000) try warnings.append(a, "Native queue is partial; the pack cannot be confirmed.");
    for (J.items(queue, "records")) |record| {
        const other = J.str(record, "downloadId") orelse continue;
        if (!std.ascii.eqlIgnoreCase(other, hash)) continue;
        if (J.num(record, "episodeId")) |id| if (!contains(contained.items, id)) {
            try addUnique(a, &absent, id);
        };
    }
    return .{ .verified = warnings.items.len == 0 and manifest.items.len > 0 and selected.items.len > 0, .contained_episode_ids = contained.items, .selected_episode_ids = selected.items, .absent_queue_episode_ids = absent.items, .files = manifest.items, .warnings = warnings.items };
}
fn hasLanguage(raw: J.Value, id: i64) bool {
    if (id <= 0) return false;
    for (J.items(raw, "languages")) |language| if (J.num(language, "id") == id) {
        return true;
    };
    return false;
}
fn hasText(a: A, title: []const u8, needle: []const u8) !bool {
    const lower = try std.ascii.allocLowerString(a, title);
    return std.mem.find(u8, lower, needle) != null;
}
fn surround(a: A, raw: J.Value, title: []const u8) !bool {
    for (J.items(raw, "customFormats")) |format| {
        const name = J.str(format, "name") orelse continue;
        if (try hasText(a, name, "5.1") or try hasText(a, name, "7.1")) return true;
    }
    return try hasText(a, title, "5.1") or try hasText(a, title, "5 1") or try hasText(a, title, "7.1");
}
fn compactScore(candidate: Candidate) f64 {
    const gib = @as(f64, @floatFromInt(candidate.bytes)) / (1024 * 1024 * 1024);
    return @log2(@as(f64, @floatFromInt(candidate.seeds)) + 1) / std.math.pow(f64, @max(gib, 0.4), 0.45);
}
pub fn queueOnlyRejections(raw: J.Value) bool {
    const reasons = J.items(raw, "rejections");
    if (reasons.len == 0 or (J.flag(raw, "temporarilyRejected") orelse false)) return false;
    for (reasons) |value| {
        const reason = J.text(value) orelse return false;
        if (!std.mem.startsWith(u8, reason, "Quality for release in queue") and !std.mem.startsWith(u8, reason, "Existing release in queue")) return false;
    }
    return true;
}
fn compactCap(policy: E.Policy, app: AppKind, m: J.Value) u64 {
    if (app == .radarr) return policy.max_compact_bytes;
    const runtime: i64 = @min(600, @max(1, J.num(m, "runtime") orelse 45));
    return @min(policy.max_compact_bytes, @as(u64, @intCast(@min(2684354560, @max(644245094, runtime * 45 * 1024 * 1024)))));
}
fn originalRelease(a: A, config: T.Config, ref: Ref, profile: J.Value, initial: J.Value, assigned: i64, policy: E.Policy, m: J.Value, manifest: ?Scope) !?Original {
    const hash = ref.original_hash orelse return null;
    if (ref.app == .sonarr and (manifest == null or !manifest.?.verified)) return error.UnverifiedTorrentScope;
    const qb = config.qbittorrent orelse return error.ConnectionNotConfigured;
    const list = try get(a, qb, try std.fmt.allocPrint(a, "/api/v2/torrents/info?hashes={s}", .{hash}));
    if (J.array(list).len != 1) return error.OriginalTorrentNotFound;
    const torrent = J.array(list)[0];
    if (!std.ascii.eqlIgnoreCase(hash, J.str(torrent, "hash") orelse "")) return error.OriginalTorrentNotFound;
    const size = J.num(torrent, "size") orelse return error.UnknownTorrentState;
    if (size <= 0) return error.UnknownTorrentState;
    const status = J.str(torrent, "state") orelse return error.UnknownTorrentState;
    const progress = J.field(torrent, "progress");
    const fraction: f64 = if (progress == .float) progress.float else if (progress == .integer) @floatFromInt(progress.integer) else return error.UnknownTorrentState;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.UnknownTorrentState;
    const queue = try get(a, try connection(config, ref.app), "/api/v3/queue?page=1&pageSize=1000");
    if ((J.num(queue, "totalRecords") orelse 1001) > 1000) return error.QueueScopeUnknown;
    var found: std.ArrayList(i64) = .empty;
    var qid: ?i64 = null;
    var score: ?i64 = null;
    var initial_score: ?i64 = null;
    var resolution: i64 = 0;
    for (J.items(queue, "records")) |record| {
        if (!std.ascii.eqlIgnoreCase(J.str(record, "downloadId") orelse "", hash) or J.num(record, if (ref.app == .radarr) "movieId" else "seriesId") != ref.media_id) continue;
        const eid = if (ref.app == .radarr) 0 else J.num(record, "episodeId") orelse continue;
        if (ref.app == .sonarr and !contains(ref.episode_ids, eid)) continue;
        const quality = J.field(J.field(record, "quality"), "quality");
        const next_id = J.num(quality, "id") orelse return error.UnknownOriginalQuality;
        const next_score = scoreFor(profile, record, (J.num(profile, "id") orelse assigned) == assigned) orelse return error.UnknownOriginalFormats;
        const next_initial = scoreFor(initial, record, (J.num(initial, "id") orelse assigned) == assigned) orelse return error.UnknownOriginalFormats;
        if (qid != null and (qid.? != next_id or score.? != next_score or initial_score.? != next_initial)) return error.InconsistentOriginalQuality;
        qid = next_id;
        score = next_score;
        initial_score = next_initial;
        resolution = J.num(quality, "resolution") orelse return error.UnknownOriginalQuality;
        try addUnique(a, &found, eid);
    }
    if (qid == null or (ref.app == .sonarr and found.items.len != ref.episode_ids.len)) return error.OriginalQueueScopeMismatch;
    const final_rank = qualityRank(profile, qid.?) orelse return error.InvalidQualityProfile;
    if (!final_rank.allowed or score.? < (J.num(profile, "minFormatScore") orelse 0)) return error.OriginalProfileRejected;
    const initial_rank = qualityRank(initial, qid.?);
    const cap = compactCap(policy, ref.app, m);
    var compact = initial_rank != null and initial_rank.?.allowed and initial_score.? >= (J.num(initial, "minFormatScore") orelse 0) and resolution >= policy.min_resolution and resolution <= policy.max_resolution;
    if (ref.app == .radarr) compact = compact and @as(u64, @intCast(size)) <= cap else {
        for (manifest.?.files) |file| if (file.selected and (file.bytes == 0 or file.bytes > cap * file.episode_ids.len)) {
            compact = false;
        };
    }
    return .{ .hash = hash, .title = J.str(torrent, "name") orelse "Existing release", .quality_id = qid.?, .format_score = score.?, .resolution = @intCast(resolution), .bytes = @intCast(size), .compact = compact, .paused = std.mem.startsWith(u8, status, "stopped") or std.mem.startsWith(u8, status, "paused"), .progress = fraction };
}
pub fn revalidateUpgrade(a: A, io: std.Io, config: T.Config, target: Ref, policy: E.Policy, selected: Release) !void {
    var ref = target;
    // A new release is checked on its own merits, without the queue-conflict exception.
    ref.original_hash = null;
    if (ref.app == .sonarr) ref.episode_ids = &.{selected.candidate.episode_id};
    const refreshed = try analyze(a, io, config, ref, policy, true);
    if (!refreshed.report.upgrade_allowed or refreshed.report.files.len != 1) return error.UpgradeReleaseIneligible;
    for (refreshed.releases) |release| {
        if (!std.mem.eql(u8, release.candidate.id, selected.candidate.id)) continue;
        if (release.candidate.upgrade == false or release.candidate.seeds < policy.min_seeders) break;
        if (refreshed.report.files[0].has_file and release.candidate.upgrade != true) break;
        // Import verification still uses the selected quality and score. A changed
        // candidate needs a new analysis before it can become the plan's target.
        if (release.candidate.quality_id != selected.candidate.quality_id or release.candidate.format_score != selected.candidate.format_score) break;
        if (selected.info_hash) |expected| {
            if (release.info_hash) |fresh| {
                if (!std.ascii.eqlIgnoreCase(expected, fresh)) break;
            }
        }
        return;
    }
    return error.UpgradeReleaseIneligible;
}

pub fn analyze(a: A, io: std.Io, config: T.Config, reference: Ref, policy: E.Policy, search_sources: bool) !Analysis {
    try validate(reference);
    var ref = reference;
    const c = try connection(config, ref.app);
    const m = try media(a, config, ref);
    const title = J.str(m, "title") orelse return error.InvalidMediaReference;
    const assigned = J.num(m, "qualityProfileId") orelse return error.InvalidQualityProfile;
    const native = try loadProfile(a, config, ref.app, assigned);
    const final_id = selectedProfileId(policy, ref.app, false) orelse assigned;
    const initial_id = selectedProfileId(policy, ref.app, true) orelse assigned;
    const profile = if (final_id == assigned) native else try loadProfile(a, config, ref.app, final_id);
    const initial = if (initial_id == final_id) profile else if (initial_id == assigned) native else try loadProfile(a, config, ref.app, initial_id);
    var manifest: ?Scope = null;
    if (ref.app == .sonarr and ref.original_hash != null) {
        manifest = try scope(a, config, ref, m);
        if (!manifest.?.verified) return error.UnverifiedTorrentScope;
        ref.episode_ids = manifest.?.selected_episode_ids;
    }
    var current = try files(a, config, ref, profile);
    if (ref.app == .sonarr) {
        if (ref.episode_ids.len > 64) return error.EpisodeScopeTooLarge;
        var missing: std.ArrayList(i64) = .empty;
        var filtered: std.ArrayList(FileState) = .empty;
        for (current) |file| if (!file.has_file) {
            try missing.append(a, file.episode_id);
            try filtered.append(a, file);
        };
        if (missing.items.len > 0) {
            ref.episode_ids = missing.items;
            current = filtered.items;
        }
    }
    const original = try originalRelease(a, config, ref, profile, initial, assigned, policy, m, manifest);
    var releases: std.ArrayList(Release) = .empty;
    var candidates: std.ArrayList(Candidate) = .empty;
    var compact_choices: std.ArrayList(Selection) = .empty;
    var upgrade_choices: std.ArrayList(Selection) = .empty;
    const episode_queries: []const i64 = if (ref.app == .radarr) &.{0} else ref.episode_ids;
    if (search_sources) for (episode_queries) |eid| {
        var compact: ?usize = null;
        var best: ?usize = null;
        const episode = if (ref.app == .sonarr) try get(a, c, try std.fmt.allocPrint(a, "/api/v3/episode/{d}", .{eid})) else J.Value.null;
        const path = try std.fmt.allocPrint(a, "/api/v3/release?{s}={d}", .{ if (ref.app == .radarr) "movieId" else "episodeId", if (ref.app == .radarr) ref.media_id else eid });
        const raw_list = try J.parse(a, try T.search(a, c, path));
        if (raw_list != .array) return error.InvalidUpstreamResponse;
        for (J.array(raw_list)[0..@min(J.array(raw_list).len, 1000)]) |raw| {
            const guid = J.str(raw, "guid") orelse continue;
            const indexer = J.num(raw, "indexerId") orelse continue;
            const release_title = J.str(raw, "title") orelse continue;
            if (ref.app == .radarr) {
                if (J.num(raw, "mappedMovieId")) |mid| if (mid != ref.media_id) continue;
            } else {
                if (J.num(raw, "seriesId")) |mid| if (mid != ref.media_id) continue;
                const numbers = J.items(raw, "episodeNumbers");
                if (numbers.len != 1 or J.int(numbers[0]) != J.num(episode, "episodeNumber") or J.num(raw, "seasonNumber") != J.num(episode, "seasonNumber") or (J.flag(raw, "fullSeason") orelse false)) continue;
            }
            const q = J.field(J.field(raw, "quality"), "quality");
            const qid = J.num(q, "id") orelse continue;
            const resolution = J.num(q, "resolution") orelse 0;
            const size = J.num(raw, "size") orelse 0;
            if (size <= 0 or resolution < 0 or resolution > 65535) continue;
            const score = scoreFor(profile, raw, final_id == assigned) orelse continue;
            const initial_score = scoreFor(initial, raw, initial_id == assigned);
            const native_score = formatScore(native, raw) orelse continue;
            const initial_rank = qualityRank(initial, qid);
            const final_rank = qualityRank(profile, qid);
            const native_rank = qualityRank(native, qid);
            const initial_ok = initial_rank != null and initial_rank.?.allowed and initial_score != null and initial_score.? >= (J.num(initial, "minFormatScore") orelse 0);
            const final_ok = final_rank != null and final_rank.?.allowed and score >= (J.num(profile, "minFormatScore") orelse 0);
            const language_ok = hasLanguage(raw, J.num(J.field(m, "originalLanguage"), "id") orelse 0);
            const protocol_ok = std.mem.eql(u8, J.str(raw, "protocol") orelse "", "torrent");
            const strictly_approved = (J.flag(raw, "approved") orelse false) and !(J.flag(raw, "rejected") orelse true) and !(J.flag(raw, "temporarilyRejected") orelse false) and (J.flag(raw, "downloadAllowed") orelse false);
            const queue_override = original != null and !original.?.compact and queueOnlyRejections(raw) and native_rank != null and native_rank.?.allowed and native_score >= (J.num(native, "minFormatScore") orelse 0);
            const allowed = (strictly_approved or queue_override) and protocol_ok and language_ok;
            const disallowed_3d = try hasText(a, release_title, "hsbs") or try hasText(a, release_title, ".3d.") or try hasText(a, release_title, " 3d ");
            const remux = std.mem.eql(u8, J.str(q, "modifier") orelse "", "remux");
            const seeds = @max(0, J.num(raw, "seeders") orelse 0);
            const is_compact = allowed and initial_ok and !disallowed_3d and !remux and resolution >= policy.min_resolution and resolution <= policy.max_resolution and @as(u64, @intCast(size)) <= compactCap(policy, ref.app, m) and seeds >= policy.min_seeders;
            var upgrade: ?bool = true;
            for (current) |file| {
                if (file.episode_id != eid) continue;
                if (!file.has_file) {
                    upgrade = null;
                    continue;
                }
                upgrade = compare(profile, file.quality_id, file.format_score, qid, score).better;
            }
            if (!strictly_approved or !allowed or !final_ok or disallowed_3d) upgrade = false;
            const id = try J.hash(a, try std.fmt.allocPrint(a, "{d}:{d}:{s}", .{ eid, indexer, guid }));
            const candidate = Candidate{ .episode_id = eid, .id = id, .title = release_title, .bytes = @intCast(size), .seeds = @intCast(@min(seeds, std.math.maxInt(u32))), .resolution = @intCast(resolution), .quality_id = qid, .quality = J.str(q, "name") orelse "Unknown", .format_score = score, .original_audio = language_ok, .native_approved = allowed and !disallowed_3d, .compact = is_compact, .upgrade = upgrade, .reason = if (queue_override and !strictly_approved) "Only the queue conflict is superseded for the compact stage; native quality, language and format safeguards remain enforced." else if (!allowed) "Rejected by Arr; check the details in the source application." else if (disallowed_3d) "3D release excluded from the first copy." else "Approved by the native profile; availability is estimated from seeders and size.", .surround_hint = try surround(a, raw, release_title) };
            const idx = candidates.items.len;
            try candidates.append(a, candidate);
            try releases.append(a, .{ .candidate = candidate, .guid = guid, .indexer_id = indexer, .info_hash = J.str(raw, "infoHash") });
            if (allowed and final_ok and seeds >= policy.min_seeders and upgrade != false) {
                if (best == null) best = idx else {
                    const previous = candidates.items[best.?];
                    const before = qualityRank(profile, previous.quality_id) orelse continue;
                    if (final_rank.?.rank > before.rank or (final_rank.?.rank == before.rank and (score > previous.format_score or (score == previous.format_score and candidate.seeds > previous.seeds)))) best = idx;
                }
            }
        }
        // Choose only among this episode's compact candidates.
        for (candidates.items, 0..) |candidate, idx| if (candidate.episode_id == eid and candidate.compact) {
            if (compact == null or (candidate.surround_hint and !candidates.items[compact.?].surround_hint) or (candidate.surround_hint == candidates.items[compact.?].surround_hint and compactScore(candidate) > compactScore(candidates.items[compact.?]))) compact = idx;
        };
        if (compact) |idx| try compact_choices.append(a, .{ .episode_id = eid, .candidate_id = candidates.items[idx].id });
        if (best) |idx| try upgrade_choices.append(a, .{ .episode_id = eid, .candidate_id = candidates.items[idx].id });
    };
    if (original) |source| {
        const id = try J.hash(a, try std.fmt.allocPrint(a, "existing:{s}", .{source.hash}));
        const candidate = Candidate{ .id = id, .title = source.title, .bytes = source.bytes, .seeds = 0, .resolution = source.resolution, .quality_id = source.quality_id, .quality = "Existing queued release", .format_score = source.format_score, .original_audio = true, .native_approved = true, .compact = source.compact, .upgrade = if (source.compact) false else true, .reason = "Existing queued release; downloaded bytes are preserved." };
        try candidates.append(a, candidate);
        try releases.append(a, .{ .candidate = candidate, .guid = "", .indexer_id = 0, .info_hash = source.hash });
        if (source.compact) {
            compact_choices.clearRetainingCapacity();
            try compact_choices.append(a, .{ .episode_id = 0, .candidate_id = id });
        } else {
            upgrade_choices.clearRetainingCapacity();
            try upgrade_choices.append(a, .{ .episode_id = 0, .candidate_id = id });
        }
    }
    return .{ .report = .{ .target = ref, .title = title, .profile_name = J.str(profile, "name") orelse "Unknown", .initial_profile_name = J.str(initial, "name"), .initial_profile_id = initial_id, .final_profile_id = final_id, .native_profile_name = J.str(native, "name"), .upgrade_allowed = J.flag(profile, "upgradeAllowed") orelse false, .original = original, .scope = manifest, .files = current, .candidates = candidates.items, .compact_selections = compact_choices.items, .upgrade_selections = upgrade_choices.items, .compact_candidate_id = if (compact_choices.items.len > 0) compact_choices.items[0].candidate_id else null, .upgrade_candidate_id = if (upgrade_choices.items.len > 0) upgrade_choices.items[0].candidate_id else null, .searched = search_sources, .created_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds() }, .releases = releases.items };
}
