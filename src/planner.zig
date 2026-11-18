const std = @import("std");
const J = @import("json_helpers.zig");
const T = @import("transport.zig");
const E = @import("engine.zig");
const A = std.mem.Allocator;
pub const AppKind = enum { radarr, sonarr };
pub const Ref = struct { app: AppKind, media_id: i64, episode_ids: []const i64 = &.{}, original_hash: ?[]const u8 = null };
pub const FileState = struct { episode_id: i64, has_file: bool, file_id: ?i64, quality_id: ?i64 = null, format_score: ?i64 = null };
pub const ScopeFile = struct { name: []const u8, selected: bool, episode_ids: []const i64 };
pub const Scope = struct { verified: bool, contained_episode_ids: []const i64, selected_episode_ids: []const i64, absent_queue_episode_ids: []const i64, files: []const ScopeFile, warnings: []const []const u8 };
pub const QualityRank = struct { rank: i64, allowed: bool };
pub const Comparison = struct { better: ?bool, reason: []const u8 };
pub const Candidate = struct {
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
pub const Report = struct { target: Ref, title: []const u8, profile_name: []const u8, upgrade_allowed: bool, scope: ?Scope = null, files: []const FileState, candidates: []const Candidate, compact_candidate_id: ?[]const u8 = null, upgrade_candidate_id: ?[]const u8 = null, searched: bool, created_at_ms: i64, notes: []const []const u8 = &.{} };
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
    if (J.num(object, "customFormatScore")) |score| return score;
    if (J.field(object, "customFormats") != .array) return null;
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
    if (!(J.flag(profile, "upgradeAllowed") orelse false)) return .{ .better = false, .reason = "Upgrades desativados no perfil nativo." };
    const before = qualityRank(profile, current_quality orelse return .{ .better = null, .reason = "Qualidade atual desconhecida." }) orelse return .{ .better = null, .reason = "Qualidade atual não está no perfil." };
    const after = qualityRank(profile, next_quality) orelse return .{ .better = false, .reason = "Qualidade candidata não está no perfil." };
    if (!after.allowed or next_score < (J.num(profile, "minFormatScore") orelse 0)) return .{ .better = false, .reason = "Qualidade ou formatos não são permitidos pelo perfil." };
    if (J.num(profile, "cutoff")) |cutoff| {
        if (qualityRank(profile, cutoff)) |limit| {
            if (before.rank >= limit.rank and current_score != null and current_score.? >= (J.num(profile, "cutoffFormatScore") orelse 0)) return .{ .better = false, .reason = "Limites de qualidade e formatos do perfil já atingidos." };
        }
    }
    if (after.rank > before.rank) return .{ .better = true, .reason = "Qualidade superior na hierarquia do perfil nativo." };
    if (after.rank < before.rank) return .{ .better = false, .reason = "Qualidade inferior na hierarquia do perfil nativo." };
    const score = current_score orelse return .{ .better = null, .reason = "Pontuação atual desconhecida; não presumir upgrade dentro da mesma qualidade." };
    const better = next_score > score and next_score - score >= (J.num(profile, "minUpgradeFormatScore") orelse 1);
    return .{ .better = better, .reason = if (better) "Mesma qualidade, com ganho de formatos suficiente no perfil." else "Não atinge o ganho mínimo de formatos do perfil." };
}
pub fn media(a: A, config: T.Config, ref: Ref) !J.Value {
    const c = try connection(config, ref.app);
    return get(a, c, try std.fmt.allocPrint(a, "/api/v3/{s}/{d}", .{ if (ref.app == .radarr) "movie" else "series", ref.media_id }));
}
pub fn files(a: A, config: T.Config, ref: Ref, profile: J.Value) ![]const FileState {
    const c = try connection(config, ref.app);
    var result: std.ArrayList(FileState) = .empty;
    if (ref.app == .radarr) {
        const m = try media(a, config, ref);
        const has = J.flag(m, "hasFile") orelse return error.UnknownFileIdentity;
        const f = J.field(m, "movieFile");
        const id = J.num(f, "id");
        if (has and (id == null or id.? <= 0)) return error.UnknownFileIdentity;
        try result.append(a, .{ .episode_id = 0, .has_file = has, .file_id = if (has) id else null, .quality_id = J.num(J.field(J.field(f, "quality"), "quality"), "id"), .format_score = formatScore(profile, f) });
    } else {
        if (ref.episode_ids.len == 0) return error.UnknownEpisodeScope;
        for (ref.episode_ids) |id| {
            const ep = try get(a, c, try std.fmt.allocPrint(a, "/api/v3/episode/{d}", .{id}));
            if (J.num(ep, "seriesId") != ref.media_id) return error.EpisodeSeriesMismatch;
            const has = J.flag(ep, "hasFile") orelse return error.UnknownFileIdentity;
            const fid = J.num(ep, "episodeFileId");
            if (has and (fid == null or fid.? <= 0)) return error.UnknownFileIdentity;
            const f = if (has) try get(a, c, try std.fmt.allocPrint(a, "/api/v3/episodefile/{d}", .{fid.?})) else J.Value.null;
            try result.append(a, .{ .episode_id = id, .has_file = has, .file_id = if (has) fid else null, .quality_id = J.num(J.field(J.field(f, "quality"), "quality"), "id"), .format_score = formatScore(profile, f) });
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
        if (ids.items.len == 0 or priority == null) try warnings.append(a, try std.fmt.allocPrint(a, "Arquivo sem escopo ou prioridade confirmados: {s}", .{base}));
        try manifest.append(a, .{ .name = name, .selected = enabled, .episode_ids = ids.items });
    }
    var absent: std.ArrayList(i64) = .empty;
    const queue = try get(a, c, "/api/v3/queue?page=1&pageSize=1000&includeEpisode=true");
    if ((J.num(queue, "totalRecords") orelse 1001) > 1000) try warnings.append(a, "Fila nativa parcial; pacote não pode ser confirmado.");
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
pub fn analyze(a: A, io: std.Io, config: T.Config, reference: Ref, policy: E.Policy, search_sources: bool) !Analysis {
    try validate(reference);
    var ref = reference;
    const c = try connection(config, ref.app);
    const m = try media(a, config, ref);
    const title = J.str(m, "title") orelse return error.InvalidMediaReference;
    const profile = try get(a, c, try std.fmt.allocPrint(a, "/api/v3/qualityprofile/{d}", .{J.num(m, "qualityProfileId") orelse return error.InvalidQualityProfile}));
    var manifest: ?Scope = null;
    if (ref.app == .sonarr and ref.original_hash != null) {
        manifest = try scope(a, config, ref, m);
        if (manifest.?.verified) ref.episode_ids = manifest.?.selected_episode_ids;
    }
    const current = if (ref.app == .radarr or ref.episode_ids.len > 0) try files(a, config, ref, profile) else &.{};
    var releases: std.ArrayList(Release) = .empty;
    var candidates: std.ArrayList(Candidate) = .empty;
    var compact: ?usize = null;
    var best: ?usize = null;
    if (search_sources) {
        const path = if (ref.app == .radarr) try std.fmt.allocPrint(a, "/api/v3/release?movieId={d}", .{ref.media_id}) else if (ref.episode_ids.len == 1) try std.fmt.allocPrint(a, "/api/v3/release?episodeId={d}", .{ref.episode_ids[0]}) else null;
        if (path) |url| {
            const raw_list = try J.parse(a, try T.search(a, c, url));
            if (raw_list != .array) return error.InvalidUpstreamResponse;
            for (J.array(raw_list)[0..@min(J.array(raw_list).len, 1000)]) |raw| {
                const guid = J.str(raw, "guid") orelse continue;
                const indexer = J.num(raw, "indexerId") orelse continue;
                const release_title = J.str(raw, "title") orelse continue;
                const q = J.field(J.field(raw, "quality"), "quality");
                const qid = J.num(q, "id") orelse continue;
                const resolution = J.num(q, "resolution") orelse 0;
                const size = J.num(raw, "size") orelse 0;
                if (size <= 0 or resolution < 0 or resolution > 65535) continue;
                const score = formatScore(profile, raw) orelse continue;
                const original = hasLanguage(raw, J.num(J.field(m, "originalLanguage"), "id") orelse 0);
                const allowed = (J.flag(raw, "approved") orelse false) and !(J.flag(raw, "rejected") orelse true) and !(J.flag(raw, "temporarilyRejected") orelse false) and (J.flag(raw, "downloadAllowed") orelse false) and std.mem.eql(u8, J.str(raw, "protocol") orelse "", "torrent") and original and score >= (J.num(profile, "minFormatScore") orelse 0);
                const disallowed_3d = try hasText(a, release_title, "hsbs") or try hasText(a, release_title, ".3d.") or try hasText(a, release_title, " 3d ");
                const remux = std.mem.eql(u8, J.str(q, "modifier") orelse "", "remux");
                var cap = policy.max_compact_bytes;
                if (ref.app == .sonarr) {
                    const runtime = J.num(m, "runtime") orelse 45;
                    cap = @intCast(@min(2684354560, @max(644245094, runtime * 45 * 1024 * 1024)));
                }
                const seeds = @max(0, J.num(raw, "seeders") orelse 0);
                const is_compact = allowed and !disallowed_3d and !remux and resolution >= policy.min_resolution and resolution <= policy.max_resolution and @as(u64, @intCast(size)) <= cap and seeds >= policy.min_seeders and !(J.flag(raw, "fullSeason") orelse false);
                var upgrade: ?bool = true;
                for (current) |file| {
                    if (!file.has_file) {
                        upgrade = null;
                        continue;
                    }
                    const comparison = compare(profile, file.quality_id, file.format_score, qid, score);
                    if (comparison.better == null) {
                        if (upgrade != false) upgrade = null;
                    } else if (!comparison.better.?) upgrade = false;
                }
                if (!allowed or disallowed_3d) upgrade = false;
                const native_reason = if (J.items(raw, "rejections").len > 0) "Rejeitado pelo Arr; consulte os detalhes no aplicativo de origem." else if (!original) "Idioma original não confirmado." else if (disallowed_3d) "Versão 3D excluída da primeira cópia." else if (!allowed) "Não foi aprovado pelo perfil nativo." else "Aprovado pelo perfil nativo; disponibilidade é estimada por seeds e tamanho.";
                const id = try J.hash(a, try std.fmt.allocPrint(a, "{d}:{s}", .{ indexer, guid }));
                const candidate = Candidate{ .id = id, .title = release_title, .bytes = @intCast(size), .seeds = @intCast(@min(seeds, std.math.maxInt(u32))), .resolution = @intCast(resolution), .quality_id = qid, .quality = J.str(q, "name") orelse "Unknown", .format_score = score, .original_audio = original, .native_approved = allowed and !disallowed_3d, .compact = is_compact, .upgrade = upgrade, .reason = native_reason, .surround_hint = try surround(a, raw, release_title) };
                const idx = candidates.items.len;
                try candidates.append(a, candidate);
                try releases.append(a, .{ .candidate = candidate, .guid = guid, .indexer_id = indexer, .info_hash = J.str(raw, "infoHash") });
                if (is_compact) {
                    if (compact == null or (candidate.surround_hint and !candidates.items[compact.?].surround_hint) or (candidate.surround_hint == candidates.items[compact.?].surround_hint and compactScore(candidate) > compactScore(candidates.items[compact.?]))) compact = idx;
                }
                if (allowed and !disallowed_3d and seeds >= policy.min_seeders and upgrade != false) {
                    const rank = qualityRank(profile, qid) orelse continue;
                    if (!rank.allowed) continue;
                    if (best == null) {
                        best = idx;
                    } else {
                        const previous = candidates.items[best.?];
                        const prev_rank = qualityRank(profile, previous.quality_id) orelse continue;
                        if (rank.rank > prev_rank.rank or (rank.rank == prev_rank.rank and (score > previous.format_score or (score == previous.format_score and candidate.seeds > previous.seeds)))) best = idx;
                    }
                }
            }
        }
    }
    return .{ .report = .{ .target = ref, .title = title, .profile_name = J.str(profile, "name") orelse "Unknown", .upgrade_allowed = J.flag(profile, "upgradeAllowed") orelse false, .scope = manifest, .files = current, .candidates = candidates.items, .compact_candidate_id = if (compact) |idx| candidates.items[idx].id else null, .upgrade_candidate_id = if (best) |idx| candidates.items[idx].id else null, .searched = search_sources, .created_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds() }, .releases = releases.items };
}
