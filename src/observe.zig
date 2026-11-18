const std = @import("std");
const transport = @import("transport.zig");
const engine = @import("engine.zig");
const Allocator = std.mem.Allocator;

pub const Advice = enum { wait_for_import, consider_compact, keep_upgrade, respect_pause, needs_review };
pub const Torrent = struct {
    hash: []const u8,
    name: []const u8,
    state: []const u8,
    progress: f64,
    bytes: u64,
    download_speed: u64,
    seeds: u32,
    eta_seconds: ?u64,
};
pub const Item = struct {
    app: []const u8,
    queue_id: i64,
    media_id: ?i64,
    episode_id: ?i64,
    season_number: ?u16 = null,
    episode_number: ?u16 = null,
    title: []const u8,
    resolution: u16,
    custom_format_score: ?i64,
    download_id: ?[]const u8,
    status: []const u8,
    has_file: ?bool = null,
    file_id: ?i64 = null,
    multi_episode_download: bool = false,
    queue_scope_partial: bool = false,
    advice: Advice = .needs_review,
    reason: []const u8 = "Not enough data to recommend a change.",
    torrent: ?Torrent = null,
};
pub const Service = struct {
    name: []const u8,
    configured: bool,
    connected: bool = false,
    version: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    total_records: u64 = 0,
    truncated: bool = false,
};
pub const Result = struct {
    observed_at_ms: i64,
    mode: []const u8 = "read_only",
    live_actions_enabled: bool = false,
    services: []const Service,
    items: []const Item,
    torrents: []const Torrent,
    policy: engine.Policy,
};
const RawTorrent = struct {
    hash: []const u8,
    name: []const u8,
    state: []const u8,
    progress: f64 = 0,
    size: u64 = 0,
    dlspeed: u64 = 0,
    num_seeds: u32 = 0,
    eta: u64 = 8640000,
};
const Quality = struct { quality: struct { resolution: u16 = 0 } = .{} };
const Record = struct {
    id: i64,
    movieId: ?i64 = null,
    seriesId: ?i64 = null,
    episodeId: ?i64 = null,
    title: []const u8 = "Untitled",
    downloadId: ?[]const u8 = null,
    status: []const u8 = "unknown",
    quality: Quality = .{},
    customFormatScore: ?i64 = null,
};
const Queue = struct { records: []const Record, totalRecords: u64 };
const Media = struct {
    hasFile: ?bool = null,
    episodeFileId: i64 = 0,
    movieFile: ?struct { id: i64 = 0 } = null,
    seasonNumber: ?u16 = null,
    episodeNumber: ?u16 = null,
};

fn parse(comptime T: type, allocator: Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidUpstreamResponse;
}
fn json(comptime T: type, allocator: Allocator, connection: transport.Connection, path: []const u8) !T {
    return parse(T, allocator, try transport.get(allocator, connection, path));
}
fn fileState(allocator: Allocator, connection: transport.Connection, app: []const u8, record: Record) !struct { has_file: bool, file_id: ?i64, season_number: ?u16, episode_number: ?u16 } {
    const id = if (std.mem.eql(u8, app, "radarr")) record.movieId else record.episodeId;
    if (id == null or id.? <= 0) return error.UnknownEpisodeScope;
    const path = try std.fmt.allocPrint(allocator, "/api/v3/{s}/{d}", .{ if (std.mem.eql(u8, app, "radarr")) "movie" else "episode", id.? });
    const media = try json(Media, allocator, connection, path);
    const file_id = if (std.mem.eql(u8, app, "radarr")) (if (media.movieFile) |file| file.id else 0) else media.episodeFileId;
    const has_file = media.hasFile orelse return error.UnknownFileIdentity;
    if (has_file and file_id <= 0) return error.UnknownFileIdentity;
    return .{ .has_file = has_file, .file_id = if (has_file) file_id else null, .season_number = media.seasonNumber, .episode_number = media.episodeNumber };
}

pub fn recommend(item: *Item, policy: engine.Policy) void {
    if (item.has_file == null or item.torrent == null) return;
    const torrent = item.torrent.?;
    if (std.mem.startsWith(u8, torrent.state, "stopped") or std.mem.startsWith(u8, torrent.state, "paused")) {
        item.advice = .respect_pause;
        item.reason = "Download is paused, possibly manually or by existing automation; preserve the pause.";
    } else if (item.multi_episode_download) {
        item.advice = .needs_review;
        item.reason = "The same torrent appears in multiple episodes. Confirm the full pack scope before suggesting any changes.";
    } else if (item.queue_scope_partial) {
        item.advice = .needs_review;
        item.reason = "The episode queue is partial; confirm the full scope before suggesting any changes.";
    } else if (item.has_file.?) {
        item.advice = .keep_upgrade;
        item.reason = "An imported file already exists. Keep the watchable copy while Arr evaluates the current download.";
    } else if (torrent.progress >= 0.10) {
        item.advice = .wait_for_import;
        item.reason = "Download has passed 10%; preserve progress and wait for import.";
    } else if (torrent.bytes == 0 or item.resolution == 0 or std.mem.eql(u8, torrent.state, "metaDL") or std.mem.eql(u8, torrent.state, "forcedMetaDL")) {
        item.advice = .needs_review;
        item.reason = "Metadata or size is not confirmed; do not suggest a release replacement.";
    } else if (item.resolution < policy.min_resolution or (item.custom_format_score orelse 0) < 0 or std.mem.eql(u8, torrent.state, "error") or std.mem.eql(u8, torrent.state, "missingFiles")) {
        item.advice = .needs_review;
        item.reason = "Quality, score or torrent state requires review; preserve the current download.";
    } else if (torrent.bytes > policy.max_compact_bytes or item.resolution > policy.max_resolution) {
        item.advice = .consider_compact;
        item.reason = "No watchable copy yet and a large download has just started. Consider a compact alternative; no search or replacement was performed.";
    } else {
        item.advice = .wait_for_import;
        item.reason = "First copy meets size and resolution limits. Wait for Arr to confirm import.";
    }
}

pub fn collect(allocator: Allocator, io: std.Io, config: transport.Config, policy: engine.Policy) !Result {
    const started = std.Io.Timestamp.now(io, .awake);
    const services = try allocator.alloc(Service, 3);
    services[0] = .{ .name = "radarr", .configured = config.radarr != null };
    services[1] = .{ .name = "sonarr", .configured = config.sonarr != null };
    services[2] = .{ .name = "qbittorrent", .configured = config.qbittorrent != null };
    var torrents: std.ArrayList(Torrent) = .empty;
    if (config.qbittorrent) |connection| qb: {
        const version = transport.get(allocator, connection, "/api/v2/app/version") catch |err| {
            services[2].error_code = @errorName(err);
            break :qb;
        };
        if (version.len == 0 or version.len > 128 or version[0] == '<') {
            services[2].error_code = "InvalidUpstreamResponse";
            break :qb;
        }
        const list = json([]const RawTorrent, allocator, connection, "/api/v2/torrents/info?limit=500") catch |err| {
            services[2].error_code = @errorName(err);
            break :qb;
        };
        services[2].version = std.mem.trim(u8, version, " \r\n\t");
        services[2].connected = true;
        services[2].total_records = list.len;
        services[2].truncated = list.len >= 500;
        for (list[0..@min(list.len, 500)]) |torrent| {
            if (!std.math.isFinite(torrent.progress) or torrent.progress < 0 or torrent.progress > 1) continue;
            try torrents.append(allocator, .{
                .hash = torrent.hash,
                .name = torrent.name,
                .state = torrent.state,
                .progress = torrent.progress,
                .bytes = torrent.size,
                .download_speed = torrent.dlspeed,
                .seeds = torrent.num_seeds,
                .eta_seconds = if (torrent.eta >= 8640000) null else torrent.eta,
            });
        }
    }
    var items: std.ArrayList(Item) = .empty;
    inline for (.{ "radarr", "sonarr" }, 0..) |name, service_index| {
        if (@field(config, name)) |connection| arr: {
            const status = json(struct { version: []const u8 }, allocator, connection, "/api/v3/system/status") catch |err| {
                services[service_index].error_code = @errorName(err);
                break :arr;
            };
            const queue = json(Queue, allocator, connection, "/api/v3/queue?page=1&pageSize=25&includeMovie=true&includeSeries=true&includeEpisode=true") catch |err| {
                services[service_index].error_code = @errorName(err);
                break :arr;
            };
            services[service_index].connected = true;
            services[service_index].version = status.version;
            services[service_index].total_records = queue.totalRecords;
            services[service_index].truncated = queue.totalRecords > @min(queue.records.len, 25) or queue.records.len > 25;
            for (queue.records[0..@min(queue.records.len, 25)]) |record| {
                var item = Item{
                    .app = name,
                    .queue_id = record.id,
                    .media_id = if (service_index == 0) record.movieId else record.seriesId,
                    .episode_id = record.episodeId,
                    .title = record.title,
                    .resolution = record.quality.quality.resolution,
                    .custom_format_score = record.customFormatScore,
                    .download_id = record.downloadId,
                    .status = record.status,
                    .queue_scope_partial = service_index == 1 and services[service_index].truncated,
                };
                if (record.downloadId) |hash| {
                    for (torrents.items) |torrent| {
                        if (std.ascii.eqlIgnoreCase(hash, torrent.hash)) {
                            item.torrent = torrent;
                            break;
                        }
                    }
                    if (service_index == 1) {
                        var matches: usize = 0;
                        for (queue.records) |other| {
                            if (other.downloadId) |other_hash| {
                                if (std.ascii.eqlIgnoreCase(hash, other_hash)) matches += 1;
                            }
                        }
                        item.multi_episode_download = matches > 1;
                    }
                }
                const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
                if (elapsed < 15_000) {
                    if (fileState(allocator, connection, name, record)) |state| {
                        item.has_file = state.has_file;
                        item.file_id = state.file_id;
                        item.season_number = state.season_number;
                        item.episode_number = state.episode_number;
                        recommend(&item, policy);
                    } else |_| {
                        item.reason = "Could not verify the file or episode scope; preserve the current state.";
                    }
                } else {
                    item.reason = "Observation time limit reached; check the status in another query.";
                }
                try items.append(allocator, item);
            }
        }
    }
    return .{
        .observed_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .services = services,
        .items = items.items,
        .torrents = torrents.items,
        .policy = policy,
    };
}
