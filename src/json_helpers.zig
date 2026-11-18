const std = @import("std");
pub const Value = std.json.Value;
pub fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
pub fn text(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
pub fn str(value: Value, name: []const u8) ?[]const u8 {
    return text(field(value, name));
}
pub fn int(value: Value) ?i64 {
    return switch (value) {
        .integer => value.integer,
        .float => if (std.math.isFinite(value.float) and value.float >= -9e15 and value.float <= 9e15) @intFromFloat(value.float) else null,
        else => null,
    };
}
pub fn num(value: Value, name: []const u8) ?i64 {
    return int(field(value, name));
}
pub fn boolean(value: Value) ?bool {
    return if (value == .bool) value.bool else null;
}
pub fn flag(value: Value, name: []const u8) ?bool {
    return boolean(field(value, name));
}
pub fn array(value: Value) []const Value {
    return if (value == .array) value.array.items else &.{};
}
pub fn items(value: Value, name: []const u8) []const Value {
    return array(field(value, name));
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch return error.InvalidUpstreamResponse;
}
pub fn encode(a: std.mem.Allocator, text_value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (text_value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.findScalar(u8, "-_.~", byte) != null) try out.append(a, byte) else try out.appendSlice(a, &.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
    return out.items;
}
pub fn hash(a: std.mem.Allocator, text_value: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text_value, &digest, .{});
    const out = try a.alloc(u8, 64);
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 15];
    }
    return out;
}
pub fn validHash(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |char| if (!std.ascii.isHex(char)) {
        return false;
    };
    return true;
}
