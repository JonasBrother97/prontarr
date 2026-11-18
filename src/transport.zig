const std = @import("std");
const c = @import("curl");

pub const Connection = struct {
    url: []const u8,
    api_key: ?[]const u8 = null,
    host_header: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
};
pub const Config = struct {
    radarr: ?Connection = null,
    sonarr: ?Connection = null,
    qbittorrent: ?Connection = null,
};
pub const max_body = 2 * 1024 * 1024;

pub fn init() !void {
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.TransportInit;
}
pub fn deinit() void {
    c.curl_global_cleanup();
}

pub fn validate(connection: Connection) !void {
    if (connection.url.len == 0 or connection.url.len > 1024) return error.InvalidConnectionUrl;
    for (connection.url) |char| if (char <= 32 or char == 127) {
        return error.InvalidConnectionUrl;
    };
    const uri = std.Uri.parse(connection.url) catch return error.InvalidConnectionUrl;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidConnectionUrl;
    if (uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidConnectionUrl;
    for ([_]?[]const u8{ connection.api_key, connection.cookie }) |optional| {
        if (optional) |secret| {
            if (secret.len == 0 or secret.len > 2048) return error.InvalidCredential;
            for (secret) |char| if (char < 32 or char == 127) {
                return error.InvalidCredential;
            };
        }
    }
    if (connection.host_header) |host| {
        if (host.len == 0 or host.len > 255) return error.InvalidHostHeader;
        for (host) |char| if (!std.ascii.isAlphanumeric(char) and std.mem.findScalar(u8, ".-:[]", char) == null) {
            return error.InvalidHostHeader;
        };
    }
}

pub fn load(init_ctx: std.process.Init) !Config {
    const path = init_ctx.environ_map.get("PRONTARR_CONNECTIONS") orelse return .{};
    const stat = try std.Io.Dir.cwd().statFile(init_ctx.io, path, .{});
    if (comptime @import("builtin").os.tag != .windows) {
        if (stat.permissions.toMode() & 0o077 != 0) return error.ConnectionsFileMustBePrivate;
    }
    const arena = init_ctx.arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init_ctx.io, path, arena, .limited(64 * 1024));
    const config = try std.json.parseFromSliceLeaky(Config, arena, bytes, .{});
    inline for (.{ "radarr", "sonarr", "qbittorrent" }) |name| {
        if (@field(config, name)) |connection| {
            try validate(connection);
            if (!std.mem.eql(u8, name, "qbittorrent") and connection.api_key == null) return error.MissingApiKey;
        }
    }
    return config;
}

const Buffer = struct {
    allocator: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    too_large: bool = false,
    fn write(data: [*c]u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
        const self: *Buffer = @ptrCast(@alignCast(context.?));
        const len = std.math.mul(usize, size, count) catch return 0;
        if (len > max_body - self.body.items.len) {
            self.too_large = true;
            return 0;
        }
        self.body.appendSlice(self.allocator, data[0..len]) catch return 0;
        return len;
    }
};

// Only fixed adapter GET paths reach this function. No arbitrary upstream proxy,
// redirects, cookies from a response, verbose logging or mutation methods.
pub fn get(allocator: std.mem.Allocator, connection: Connection, path: []const u8) ![]const u8 {
    const handle = c.curl_easy_init() orelse return error.TransportInit;
    defer c.curl_easy_cleanup(handle);
    const url = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ std.mem.trimEnd(u8, connection.url, "/"), path }, 0);
    var headers: ?*c.struct_curl_slist = null;
    defer c.curl_slist_free_all(headers);
    if (connection.api_key) |key| {
        const header = try std.fmt.allocPrintSentinel(allocator, "X-Api-Key: {s}", .{key}, 0);
        headers = c.curl_slist_append(headers, header) orelse return error.OutOfMemory;
    }
    if (connection.host_header) |host| {
        const header = try std.fmt.allocPrintSentinel(allocator, "Host: {s}", .{host}, 0);
        headers = c.curl_slist_append(headers, header) orelse return error.OutOfMemory;
    }
    var buffer = Buffer{ .allocator = allocator };
    try option(handle, c.CURLOPT_URL, url.ptr);
    try option(handle, c.CURLOPT_HTTPHEADER, headers);
    try option(handle, c.CURLOPT_WRITEFUNCTION, &Buffer.write);
    try option(handle, c.CURLOPT_WRITEDATA, &buffer);
    try option(handle, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 1000));
    try option(handle, c.CURLOPT_TIMEOUT_MS, @as(c_long, 3000));
    try option(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    try option(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
    try option(handle, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, "http,https"));
    try option(handle, c.CURLOPT_PROXY, @as([*:0]const u8, ""));
    try option(handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
    try option(handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
    if (connection.cookie) |cookie| try option(handle, c.CURLOPT_COOKIE, (try allocator.dupeSentinel(u8, cookie, 0)).ptr);
    const result = c.curl_easy_perform(handle);
    if (buffer.too_large) return error.ResponseTooLarge;
    if (result == c.CURLE_OPERATION_TIMEDOUT) return error.UpstreamTimeout;
    if (result == c.CURLE_PEER_FAILED_VERIFICATION) return error.InvalidUpstreamCertificate;
    if (result != c.CURLE_OK) return error.UpstreamUnavailable;
    var status: c_long = 0;
    if (c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK) return error.UpstreamUnavailable;
    if (status == 401 or status == 403) return error.UpstreamUnauthorized;
    if (status >= 300 and status < 400) return error.UpstreamRedirectBlocked;
    if (status != 200) return error.UpstreamHttpError;
    return buffer.body.items;
}
fn option(handle: ?*c.CURL, key: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(handle, key, value) != c.CURLE_OK) return error.TransportConfiguration;
}
