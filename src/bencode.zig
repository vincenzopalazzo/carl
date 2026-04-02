const std = @import("std");
const Allocator = std.mem.Allocator;

/// A bencode value. Bencode supports four types: integers, byte strings,
/// lists, and dictionaries. Byte strings are raw `[]const u8` -- they are
/// NOT assumed to be UTF-8.
pub const Value = union(enum) {
    integer: i64,
    string: []const u8,
    list: []const Value,
    dict: []const DictEntry,

    pub const DictEntry = struct {
        key: []const u8,
        value: Value,
    };

    /// Look up a key in a dict value. Returns null if this is not a dict
    /// or the key is not present.
    pub fn dictGet(self: Value, key: []const u8) ?Value {
        switch (self) {
            .dict => |entries| {
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, key)) return entry.value;
                }
                return null;
            },
            else => return null,
        }
    }

    /// Get the integer value or null.
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |v| v,
            else => null,
        };
    }

    /// Get the string value or null.
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |v| v,
            else => null,
        };
    }

    /// Get the list value or null.
    pub fn asList(self: Value) ?[]const Value {
        return switch (self) {
            .list => |v| v,
            else => null,
        };
    }

    /// Free all memory owned by this value. After calling this, the value
    /// must not be used.
    pub fn deinit(self: Value, allocator: Allocator) void {
        switch (self) {
            .integer => {},
            .string => |s| allocator.free(s),
            .list => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .dict => |entries| {
                for (entries) |entry| {
                    allocator.free(entry.key);
                    entry.value.deinit(allocator);
                }
                allocator.free(entries);
            },
        }
    }
};

pub const DecodeError = error{
    UnexpectedByte,
    UnexpectedEnd,
    InvalidInteger,
    InvalidStringLength,
    UnsortedDictKeys,
    DuplicateDictKey,
    LeadingZero,
    NegativeZero,
    OutOfMemory,
};

/// Decode a bencoded byte string into a Value. The returned value owns
/// allocated memory -- call `value.deinit(allocator)` when done.
pub fn decode(allocator: Allocator, input: []const u8) DecodeError!Value {
    var pos: usize = 0;
    const value = try decodeAt(allocator, input, &pos);
    if (pos != input.len) {
        value.deinit(allocator);
        return error.UnexpectedByte;
    }
    return value;
}

fn decodeAt(allocator: Allocator, input: []const u8, pos: *usize) DecodeError!Value {
    if (pos.* >= input.len) return error.UnexpectedEnd;

    return switch (input[pos.*]) {
        'i' => decodeInt(input, pos),
        'l' => decodeList(allocator, input, pos),
        'd' => decodeDict(allocator, input, pos),
        '0'...'9' => decodeString(allocator, input, pos),
        else => error.UnexpectedByte,
    };
}

fn decodeInt(input: []const u8, pos: *usize) DecodeError!Value {
    pos.* += 1; // skip 'i'

    if (pos.* >= input.len) return error.UnexpectedEnd;

    const start = pos.*;
    if (pos.* < input.len and input[pos.*] == '-') {
        pos.* += 1;
    }

    if (pos.* >= input.len or input[pos.*] < '0' or input[pos.*] > '9') {
        return error.InvalidInteger;
    }

    while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') {
        pos.* += 1;
    }

    if (pos.* >= input.len) return error.UnexpectedEnd;
    if (input[pos.*] != 'e') return error.UnexpectedByte;

    const num_str = input[start..pos.*];
    pos.* += 1; // skip 'e'

    if (num_str.len > 1 and num_str[0] == '0') return error.LeadingZero;
    if (num_str.len > 2 and num_str[0] == '-' and num_str[1] == '0') return error.LeadingZero;
    if (std.mem.eql(u8, num_str, "-0")) return error.NegativeZero;

    const value = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidInteger;
    return .{ .integer = value };
}

fn decodeString(allocator: Allocator, input: []const u8, pos: *usize) DecodeError!Value {
    const len_start = pos.*;
    while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') {
        pos.* += 1;
    }

    if (pos.* >= input.len or input[pos.*] != ':') {
        return error.UnexpectedByte;
    }

    const len_str = input[len_start..pos.*];
    if (len_str.len > 1 and len_str[0] == '0') return error.LeadingZero;

    const length = std.fmt.parseUnsigned(usize, len_str, 10) catch return error.InvalidStringLength;
    pos.* += 1; // skip ':'

    if (pos.* + length > input.len) return error.UnexpectedEnd;

    const data = allocator.alloc(u8, length) catch return error.OutOfMemory;
    @memcpy(data, input[pos.* .. pos.* + length]);
    pos.* += length;

    return .{ .string = data };
}

fn decodeList(allocator: Allocator, input: []const u8, pos: *usize) DecodeError!Value {
    pos.* += 1; // skip 'l'

    var items: std.ArrayList(Value) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (true) {
        if (pos.* >= input.len) return error.UnexpectedEnd;
        if (input[pos.*] == 'e') {
            pos.* += 1;
            break;
        }
        const item = try decodeAt(allocator, input, pos);
        items.append(allocator, item) catch {
            item.deinit(allocator);
            return error.OutOfMemory;
        };
    }

    return .{ .list = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

fn decodeDict(allocator: Allocator, input: []const u8, pos: *usize) DecodeError!Value {
    pos.* += 1; // skip 'd'

    var entries: std.ArrayList(Value.DictEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.key);
            entry.value.deinit(allocator);
        }
        entries.deinit(allocator);
    }

    var last_key: ?[]const u8 = null;

    while (true) {
        if (pos.* >= input.len) return error.UnexpectedEnd;
        if (input[pos.*] == 'e') {
            pos.* += 1;
            break;
        }

        if (input[pos.*] < '0' or input[pos.*] > '9') return error.UnexpectedByte;

        const key_value = try decodeString(allocator, input, pos);
        const key = key_value.string;

        if (last_key) |prev| {
            const ord = std.mem.order(u8, prev, key);
            switch (ord) {
                .gt => {
                    allocator.free(key);
                    return error.UnsortedDictKeys;
                },
                .eq => {
                    allocator.free(key);
                    return error.DuplicateDictKey;
                },
                .lt => {},
            }
        }
        last_key = key;

        const value = decodeAt(allocator, input, pos) catch |err| {
            allocator.free(key);
            return err;
        };

        entries.append(allocator, .{ .key = key, .value = value }) catch {
            allocator.free(key);
            value.deinit(allocator);
            return error.OutOfMemory;
        };
    }

    return .{ .dict = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

// --- Encoder ---

pub const EncodeError = error{OutOfMemory};

/// Encode a Value into bencoded bytes. Caller owns the returned slice.
pub fn encode(allocator: Allocator, value: Value) EncodeError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try encodeInto(allocator, &buf, value);
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn encodeInto(allocator: Allocator, buf: *std.ArrayList(u8), value: Value) EncodeError!void {
    switch (value) {
        .integer => |v| {
            var num_buf: [32]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{v}) catch unreachable;
            buf.append(allocator, 'i') catch return error.OutOfMemory;
            buf.appendSlice(allocator, num_str) catch return error.OutOfMemory;
            buf.append(allocator, 'e') catch return error.OutOfMemory;
        },
        .string => |s| {
            var len_buf: [20]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{s.len}) catch unreachable;
            buf.appendSlice(allocator, len_str) catch return error.OutOfMemory;
            buf.append(allocator, ':') catch return error.OutOfMemory;
            buf.appendSlice(allocator, s) catch return error.OutOfMemory;
        },
        .list => |items| {
            buf.append(allocator, 'l') catch return error.OutOfMemory;
            for (items) |item| {
                try encodeInto(allocator, buf, item);
            }
            buf.append(allocator, 'e') catch return error.OutOfMemory;
        },
        .dict => |entries| {
            buf.append(allocator, 'd') catch return error.OutOfMemory;
            for (entries) |entry| {
                var len_buf: [20]u8 = undefined;
                const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{entry.key.len}) catch unreachable;
                buf.appendSlice(allocator, len_str) catch return error.OutOfMemory;
                buf.append(allocator, ':') catch return error.OutOfMemory;
                buf.appendSlice(allocator, entry.key) catch return error.OutOfMemory;
                try encodeInto(allocator, buf, entry.value);
            }
            buf.append(allocator, 'e') catch return error.OutOfMemory;
        },
    }
}

// --- Tests ---

test "decode integer" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "i42e");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "decode zero" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "i0e");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 0), v.integer);
}

test "decode negative integer" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "i-3e");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(i64, -3), v.integer);
}

test "reject negative zero" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NegativeZero, decode(allocator, "i-0e"));
}

test "reject leading zero" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.LeadingZero, decode(allocator, "i03e"));
}

test "decode string" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "4:spam");
    defer v.deinit(allocator);
    try std.testing.expectEqualStrings("spam", v.string);
}

test "decode empty string" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "0:");
    defer v.deinit(allocator);
    try std.testing.expectEqualStrings("", v.string);
}

test "decode multi-digit string length" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "10:0123456789");
    defer v.deinit(allocator);
    try std.testing.expectEqualStrings("0123456789", v.string);
}

test "decode list" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "l4:spam4:eggse");
    defer v.deinit(allocator);
    const items = v.list;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("spam", items[0].string);
    try std.testing.expectEqualStrings("eggs", items[1].string);
}

test "decode empty list" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "le");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), v.list.len);
}

test "decode dict" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "d3:cow3:moo4:spam4:eggse");
    defer v.deinit(allocator);
    const cow = v.dictGet("cow").?;
    try std.testing.expectEqualStrings("moo", cow.string);
    const spam = v.dictGet("spam").?;
    try std.testing.expectEqualStrings("eggs", spam.string);
}

test "decode empty dict" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "de");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), v.dict.len);
}

test "decode nested dict with list" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "d4:spaml1:a1:bee");
    defer v.deinit(allocator);
    const spam = v.dictGet("spam").?;
    const items = spam.list;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("a", items[0].string);
    try std.testing.expectEqualStrings("b", items[1].string);
}

test "reject unsorted dict keys" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsortedDictKeys, decode(allocator, "d4:spam4:eggs3:cow3:mooe"));
}

test "reject duplicate dict keys" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.DuplicateDictKey, decode(allocator, "d3:cow3:moo3:cow4:moone"));
}

test "reject truncated input" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedEnd, decode(allocator, "i42"));
    try std.testing.expectError(error.UnexpectedEnd, decode(allocator, "4:sp"));
    try std.testing.expectError(error.UnexpectedEnd, decode(allocator, "l4:spam"));
}

test "reject trailing garbage" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedByte, decode(allocator, "i42eXX"));
}

test "decode binary string" {
    const allocator = std.testing.allocator;
    const v = try decode(allocator, "4:\x00\x01\x02\x03");
    defer v.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), v.string.len);
    try std.testing.expectEqual(@as(u8, 0x00), v.string[0]);
    try std.testing.expectEqual(@as(u8, 0x03), v.string[3]);
}

test "encode integer" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, .{ .integer = 42 });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("i42e", result);
}

test "encode negative integer" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, .{ .integer = -3 });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("i-3e", result);
}

test "encode string" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, .{ .string = "spam" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("4:spam", result);
}

test "encode empty string" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, .{ .string = "" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("0:", result);
}

test "roundtrip complex structure" {
    const allocator = std.testing.allocator;
    const input = "d3:numi42e4:spaml1:a1:bee";
    const v = try decode(allocator, input);
    defer v.deinit(allocator);
    const output = try encode(allocator, v);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(input, output);
}

test "roundtrip empty structures" {
    const allocator = std.testing.allocator;
    const l = try decode(allocator, "le");
    defer l.deinit(allocator);
    const l_enc = try encode(allocator, l);
    defer allocator.free(l_enc);
    try std.testing.expectEqualStrings("le", l_enc);

    const d = try decode(allocator, "de");
    defer d.deinit(allocator);
    const d_enc = try encode(allocator, d);
    defer allocator.free(d_enc);
    try std.testing.expectEqualStrings("de", d_enc);
}
