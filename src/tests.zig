const std = @import("std");
const transport = @import("transport.zig");
const observe = @import("observe.zig");

test {
    _ = @import("engine.zig");
}

test "connection URLs cannot carry credentials or use other protocols" {
    for ([_][]const u8{ "file:///etc/passwd", "ftp://example.test", "http://user:secret@example.test", "http://example.test/?api_key=secret", "http://example.test/#fragment", "http://example.test/\r\nInjected:yes" }) |url| {
        try std.testing.expectError(error.InvalidConnectionUrl, transport.validate(.{ .url = url }));
    }
    try transport.validate(.{ .url = "https://example.test/radarr/", .api_key = "fixture" });
}
test "header injection is rejected" {
    try std.testing.expectError(error.InvalidCredential, transport.validate(.{ .url = "http://localhost", .api_key = "abc\r\nX-Leak: secret" }));
    try std.testing.expectError(error.InvalidHostHeader, transport.validate(.{ .url = "http://localhost", .host_header = "host\nX: value" }));
}
fn item() observe.Item {
    return .{
        .app = "sonarr",
        .queue_id = 1,
        .media_id = 2,
        .episode_id = 3,
        .title = "Fixture",
        .resolution = 2160,
        .custom_format_score = 1000,
        .download_id = "fixture",
        .status = "downloading",
        .has_file = false,
        .torrent = .{ .hash = "fixture", .name = "Fixture", .state = "downloading", .progress = 0.01, .bytes = 20 * 1024 * 1024 * 1024, .download_speed = 1000, .seeds = 5, .eta_seconds = null },
    };
}
test "unknown file identity and multi episode packs stay under review" {
    var record = item();
    record.has_file = null;
    observe.recommend(&record, .{});
    try std.testing.expectEqual(observe.Advice.needs_review, record.advice);
    record = item();
    record.multi_episode_download = true;
    observe.recommend(&record, .{});
    try std.testing.expectEqual(observe.Advice.needs_review, record.advice);
    record = item();
    record.queue_scope_partial = true;
    observe.recommend(&record, .{});
    try std.testing.expectEqual(observe.Advice.needs_review, record.advice);
}
test "existing pauses and download progress are preserved" {
    var record = item();
    record.torrent.?.state = "stoppedDL";
    observe.recommend(&record, .{});
    try std.testing.expectEqual(observe.Advice.respect_pause, record.advice);
    record = item();
    record.torrent.?.progress = 0.2;
    observe.recommend(&record, .{});
    try std.testing.expectEqual(observe.Advice.wait_for_import, record.advice);
}
test "large new source is only a suggestion for compact evaluation" {
    var record = item();
    observe.recommend(&record, .{});
    try std.testing.expectEqual(observe.Advice.consider_compact, record.advice);
    record = item();
    record.has_file = true;
    record.file_id = 42;
    observe.recommend(&record, .{});
    try std.testing.expectEqual(observe.Advice.keep_upgrade, record.advice);
}
