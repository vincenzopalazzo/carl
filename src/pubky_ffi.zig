//! C ABI bindings to `native/carl_pubky_bridge` (Pubky Rust SDK).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    FfiFailed,
    InvalidResponse,
    OutOfMemory,
};

const c = struct {
    pub extern "C" fn carl_pubky_free(ptr: ?[*:0]u8) void;
    pub extern "C" fn carl_pubky_generate_secret_key() ?[*:0]u8;
    pub extern "C" fn carl_pubky_public_key_from_secret(secret_key: [*:0]const u8) ?[*:0]u8;
    pub extern "C" fn carl_pubky_signup(
        secret_key: [*:0]const u8,
        homeserver: [*:0]const u8,
        signup_token: ?[*:0]const u8,
    ) ?[*:0]u8;
    pub extern "C" fn carl_pubky_signin(secret_key: [*:0]const u8) ?[*:0]u8;
    pub extern "C" fn carl_pubky_put(
        secret_key: [*:0]const u8,
        path: [*:0]const u8,
        content: [*:0]const u8,
    ) ?[*:0]u8;
    pub extern "C" fn carl_pubky_get(url: [*:0]const u8) ?[*:0]u8;
    pub extern "C" fn carl_pubky_build_file_url(pubky_z32: [*:0]const u8, path: [*:0]const u8) ?[*:0]u8;
};

pub const Response = struct {
    parsed: ?std.json.Parsed(std.json.Value),
    ok: bool,
    error_msg: []const u8,

    pub fn deinit(self: *Response, allocator: Allocator) void {
        if (self.parsed) |*p| p.deinit();
        if (!self.ok and self.error_msg.len > 0) allocator.free(self.error_msg);
    }

    pub fn dataObject(self: *const Response) ?std.json.ObjectMap {
        if (!self.ok) return null;
        const parsed = self.parsed orelse return null;
        const root = parsed.value;
        if (root != .object) return null;
        const data = root.object.get("data") orelse return null;
        if (data != .object) return null;
        return data.object;
    }
};

fn asZ(s: []const u8) [*:0]const u8 {
    return @ptrCast(s.ptr);
}

fn call(allocator: Allocator, ptr: ?[*:0]u8) Error!Response {
    const raw = ptr orelse return error.FfiFailed;
    defer c.carl_pubky_free(raw);
    const s = std.mem.span(raw);
    return parseEnvelope(allocator, s);
}

fn parseEnvelope(allocator: Allocator, s: []const u8) Error!Response {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, s, .{}) catch return error.InvalidResponse;
    const root = parsed.value;
    if (root != .object) {
        parsed.deinit();
        return error.InvalidResponse;
    }
    const ok_val = root.object.get("ok") orelse {
        parsed.deinit();
        return error.InvalidResponse;
    };
    if (ok_val != .bool) {
        parsed.deinit();
        return error.InvalidResponse;
    }
    if (ok_val.bool) {
        return .{ .parsed = parsed, .ok = true, .error_msg = "" };
    }
    const err_val = root.object.get("error") orelse {
        parsed.deinit();
        return error.InvalidResponse;
    };
    const msg = switch (err_val) {
        .string => |t| try allocator.dupe(u8, t),
        else => try allocator.dupe(u8, "pubky bridge error"),
    };
    parsed.deinit();
    return .{ .parsed = null, .ok = false, .error_msg = msg };
}

fn dupField(allocator: Allocator, obj: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const v = obj.get(key) orelse return error.InvalidResponse;
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.InvalidResponse,
    };
}

pub fn generateSecretKey(allocator: Allocator) Error!struct {
    secret_key: []const u8,
    public_key: []const u8,
    uri: []const u8,
} {
    var resp = try call(allocator, c.carl_pubky_generate_secret_key());
    defer resp.deinit(allocator);
    if (!resp.ok) return error.FfiFailed;
    const obj = resp.dataObject() orelse return error.InvalidResponse;
    return .{
        .secret_key = try dupField(allocator, obj, "secret_key"),
        .public_key = try dupField(allocator, obj, "public_key"),
        .uri = try dupField(allocator, obj, "uri"),
    };
}

pub fn publicKeyFromSecret(allocator: Allocator, secret: []const u8) Error!struct {
    public_key: []const u8,
    uri: []const u8,
} {
    var resp = try call(allocator, c.carl_pubky_public_key_from_secret(asZ(secret)));
    defer resp.deinit(allocator);
    if (!resp.ok) return error.FfiFailed;
    const obj = resp.dataObject() orelse return error.InvalidResponse;
    return .{
        .public_key = try dupField(allocator, obj, "public_key"),
        .uri = try dupField(allocator, obj, "uri"),
    };
}

pub fn signup(allocator: Allocator, secret: []const u8, homeserver: []const u8, signup_token: ?[]const u8) Error!void {
    const token_ptr: ?[*:0]const u8 = if (signup_token) |t| asZ(t) else null;
    var resp = try call(allocator, c.carl_pubky_signup(asZ(secret), asZ(homeserver), token_ptr));
    defer resp.deinit(allocator);
    if (!resp.ok) {
        logErr(resp.error_msg);
        return error.FfiFailed;
    }
}

pub fn signin(allocator: Allocator, secret: []const u8) Error!void {
    var resp = try call(allocator, c.carl_pubky_signin(asZ(secret)));
    defer resp.deinit(allocator);
    if (!resp.ok) {
        logErr(resp.error_msg);
        return error.FfiFailed;
    }
}

pub fn put(allocator: Allocator, secret: []const u8, path: []const u8, content: []const u8) Error!void {
    var resp = try call(allocator, c.carl_pubky_put(asZ(secret), asZ(path), asZ(content)));
    defer resp.deinit(allocator);
    if (!resp.ok) {
        logErr(resp.error_msg);
        return error.FfiFailed;
    }
}

pub fn get(allocator: Allocator, url: []const u8) Error![]const u8 {
    var resp = try call(allocator, c.carl_pubky_get(asZ(url)));
    defer resp.deinit(allocator);
    if (!resp.ok) {
        logErr(resp.error_msg);
        return error.FfiFailed;
    }
    return try dupField(allocator, resp.dataObject() orelse return error.InvalidResponse, "content");
}

pub fn buildFileUrl(allocator: Allocator, pubky_z32: []const u8, path: []const u8) Error![]const u8 {
    var resp = try call(allocator, c.carl_pubky_build_file_url(asZ(pubky_z32), asZ(path)));
    defer resp.deinit(allocator);
    if (!resp.ok) {
        logErr(resp.error_msg);
        return error.FfiFailed;
    }
    return try dupField(allocator, resp.dataObject() orelse return error.InvalidResponse, "url");
}

fn logErr(msg: []const u8) void {
    const scoped = std.log.scoped(.pubky);
    scoped.warn("{s}", .{msg});
}

test "parseEnvelope error" {
    const allocator = std.testing.allocator;
    var resp = try parseEnvelope(allocator, "{\"ok\":false,\"error\":\"nope\"}");
    defer resp.deinit(allocator);
    try std.testing.expect(!resp.ok);
    try std.testing.expectEqualStrings("nope", resp.error_msg);
}
