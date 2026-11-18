const std = @import("std");
const c = @import("curl");

pub const Connection = struct {
    url: []const u8,
    api_key: ?[]const u8 = null,
    host_header: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    basic_auth: ?[]const u8 = null,
};
pub const Execution = struct {
    standalone: bool = false,
    automatic: bool = false,
    allow_all_movies: bool = false,
    allow_all_series: bool = false,
    enabled: bool = false,
    allowed_movie_ids: []const i64 = &.{},
    allowed_series_ids: []const i64 = &.{},
};
pub const Config = struct {
    radarr: ?Connection = null,
    sonarr: ?Connection = null,
    qbittorrent: ?Connection = null,
    coordinator: ?Connection = null,
    vpn_health: ?Connection = null,
    execution: Execution = .{},
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
    for ([_]?[]const u8{ connection.api_key, connection.cookie, connection.basic_auth }) |optional| {
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

pub fn publicAuthority(url: []const u8) ![]const u8 {
    try validate(.{ .url = url });
    if (!std.mem.startsWith(u8, url, "https://")) return error.PublicUrlRequiresHttps;
    const authority = url[8..];
    if (authority.len == 0 or authority.len > 255) return error.InvalidPublicUrl;
    for (authority) |char| if (!std.ascii.isAlphanumeric(char) and std.mem.findScalar(u8, ".-:", char) == null) return error.InvalidPublicUrl;
    return authority;
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
    inline for (.{ "radarr", "sonarr", "qbittorrent", "coordinator", "vpn_health" }) |name| {
        if (@field(config, name)) |connection| {
            try validate(connection);
            if ((std.mem.eql(u8, name, "radarr") or std.mem.eql(u8, name, "sonarr")) and connection.api_key == null) return error.MissingApiKey;
        }
    }
    for ([_][]const i64{ config.execution.allowed_movie_ids, config.execution.allowed_series_ids }) |ids| {
        if (ids.len > 1000) return error.InvalidExecutionScope;
        for (ids) |id| if (id <= 0) return error.InvalidExecutionScope;
    }
    if (config.execution.automatic and (!config.execution.enabled or !config.execution.standalone)) return error.AutomaticExecutionRequiresStandaloneMode;
    if (config.execution.enabled and ((!config.execution.standalone and config.coordinator == null) or config.vpn_health == null)) return error.ExecutionRequiresCoordinatorAndVpnHealth;
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

// Adapter paths are internal. Mutations use the explicit operation allowlist below;
// redirects, response cookies and verbose transport logging remain disabled.
pub fn get(allocator: std.mem.Allocator, connection: Connection, path: []const u8) ![]const u8 {
    return request(allocator, connection, path, null, false, 3000);
}
pub fn search(allocator: std.mem.Allocator, connection: Connection, path: []const u8) ![]const u8 {
    return request(allocator, connection, path, null, false, 90000);
}
pub const Mutation = enum { arr_grab, qbit_stop, qbit_start, ownership_claim, ownership_release };
pub fn mutate(allocator: std.mem.Allocator, connection: Connection, action: Mutation, payload: []const u8) ![]const u8 {
    const path = switch (action) {
        .arr_grab => "/api/v3/release",
        .qbit_stop => "/api/v2/torrents/stop",
        .qbit_start => "/api/v2/torrents/start",
        .ownership_claim => "/ownership/claim",
        .ownership_release => "/ownership/release",
    };
    return request(allocator, connection, path, payload, action == .qbit_stop or action == .qbit_start, 15000);
}
fn request(allocator: std.mem.Allocator, connection: Connection, path: []const u8, payload: ?[]const u8, form: bool, timeout: c_long) ![]const u8 {
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
    if (payload != null) {
        const header: [*:0]const u8 = if (form) "Content-Type: application/x-www-form-urlencoded" else "Content-Type: application/json";
        headers = c.curl_slist_append(headers, header) orelse return error.OutOfMemory;
    }
    var buffer = Buffer{ .allocator = allocator };
    try option(handle, c.CURLOPT_URL, url.ptr);
    try option(handle, c.CURLOPT_HTTPHEADER, headers);
    try option(handle, c.CURLOPT_WRITEFUNCTION, &Buffer.write);
    try option(handle, c.CURLOPT_WRITEDATA, &buffer);
    try option(handle, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 1000));
    try option(handle, c.CURLOPT_TIMEOUT_MS, timeout);
    try option(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    try option(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
    try option(handle, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, "http,https"));
    try option(handle, c.CURLOPT_PROXY, @as([*:0]const u8, ""));
    try option(handle, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
    try option(handle, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
    if (connection.cookie) |cookie| try option(handle, c.CURLOPT_COOKIE, (try allocator.dupeSentinel(u8, cookie, 0)).ptr);
    if (connection.basic_auth) |auth| {
        try option(handle, c.CURLOPT_HTTPAUTH, @as(c_long, c.CURLAUTH_BASIC));
        try option(handle, c.CURLOPT_USERPWD, (try allocator.dupeSentinel(u8, auth, 0)).ptr);
    }
    if (payload) |body| {
        try option(handle, c.CURLOPT_POST, @as(c_long, 1));
        try option(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
        try option(handle, c.CURLOPT_POSTFIELDS, body.ptr);
    }
    const result = c.curl_easy_perform(handle);
    if (buffer.too_large) return error.ResponseTooLarge;
    if (result == c.CURLE_OPERATION_TIMEDOUT) return error.UpstreamTimeout;
    if (result == c.CURLE_PEER_FAILED_VERIFICATION) return error.InvalidUpstreamCertificate;
    if (result != c.CURLE_OK) return error.UpstreamUnavailable;
    var status: c_long = 0;
    if (c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK) return error.UpstreamUnavailable;
    if (status == 401 or status == 403) return error.UpstreamUnauthorized;
    if (status >= 300 and status < 400) return error.UpstreamRedirectBlocked;
    if (status == 409) return error.UpstreamConflict;
    if (status < 200 or status > 204) return error.UpstreamHttpError;
    return buffer.body.items;
}
fn option(handle: ?*c.CURL, key: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(handle, key, value) != c.CURLE_OK) return error.TransportConfiguration;
}
