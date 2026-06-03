//! End-to-end behavioral tests for `relay.zig` driven by the in-process
//! `mock_relay.MockRelay`. These exercise the actual ws.Conn → nostr-message
//! → Relay pipeline; they're the only test surface that catches bugs in
//! message routing, EOSE handling, OK matching, and the `subscribeAndCollect`
//! / `publishAndWait` state machines.
//!
//! What they don't cover (deliberately):
//!   - TLS (wss://): mock is plaintext only
//!   - Real-relay rate limiting / NIP-42 AUTH challenges
//!   - Frame fragmentation (mock always sends single-frame messages)

const std = @import("std");
const testing = std.testing;
const mock_relay = @import("mock_relay.zig");
const relay_mod = @import("relay.zig");
const nostr = @import("nostr.zig");
const secp = @import("secp.zig");

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

/// Build a known-good signed Nostr event for use in mock responses.
fn buildTestEvent(allocator: std.mem.Allocator, kind: u32, content: []const u8) !nostr.Event {
    var sk: secp.SecretKey = undefined;
    try secp.fromHex("0000000000000000000000000000000000000000000000000000000000000003", &sk);
    const pk = try secp.publicKeyFromSecret(sk);

    const tags = try allocator.alloc(nostr.Tag, 0);
    errdefer allocator.free(tags);
    const content_dup = try allocator.dupe(u8, content);
    errdefer allocator.free(content_dup);

    var ev: nostr.Event = .{
        .id = undefined,
        .pubkey = pk,
        .created_at = 1_700_000_000,
        .kind = kind,
        .tags = tags,
        .content = content_dup,
        .sig = undefined,
    };
    try nostr.sign(&ev, sk, allocator);
    return ev;
}

/// Serialize a signed event the same way `nostr.encodeEvent` does, but as a
/// bare JSON object (for use inside the mock's `sendEvent` wrapper).
fn eventJsonAlloc(allocator: std.mem.Allocator, event: nostr.Event) ![]u8 {
    const wrapped = try nostr.encodeEvent(allocator, event);
    defer allocator.free(wrapped);
    // wrapped = `["EVENT",{...}]`; strip the leading `["EVENT",` and trailing `]`.
    const start = "[\"EVENT\",".len;
    return allocator.dupe(u8, wrapped[start .. wrapped.len - 1]);
}

const ServerScript = struct {
    mock: *mock_relay.MockRelay,
    // Action queue executed by the worker thread.
    action: union(enum) {
        eose_then_close,
        one_event_then_eose: struct { event_json: []const u8 },
        many_events_then_eose: struct { events_json: []const []const u8 },
        ok_accepted,
        ok_rejected: []const u8,
        notice_then_eose: []const u8,
        no_response_then_close,
    },
    /// Sub_id captured from the client's REQ. Written by the worker, read by
    /// the test after `join()`.
    captured_sub_id: ?[]u8 = null,
    allocator: std.mem.Allocator,

    fn run(self: *ServerScript) void {
        self.runImpl() catch |err| {
            std.log.warn("mock relay server thread errored: {}", .{err});
        };
        // Make sure we always close so the client's read can return.
        self.mock.forceClose();
    }

    fn runImpl(self: *ServerScript) !void {
        try self.mock.accept();

        switch (self.action) {
            .eose_then_close => {
                const req = try self.mock.recvText();
                defer self.allocator.free(req);
                self.captured_sub_id = try extractSubId(self.allocator, req);
                if (self.captured_sub_id) |sid| try self.mock.sendEose(sid);
            },
            .one_event_then_eose => |args| {
                const req = try self.mock.recvText();
                defer self.allocator.free(req);
                self.captured_sub_id = try extractSubId(self.allocator, req);
                if (self.captured_sub_id) |sid| {
                    try self.mock.sendEvent(sid, args.event_json);
                    try self.mock.sendEose(sid);
                }
            },
            .many_events_then_eose => |args| {
                const req = try self.mock.recvText();
                defer self.allocator.free(req);
                self.captured_sub_id = try extractSubId(self.allocator, req);
                if (self.captured_sub_id) |sid| {
                    for (args.events_json) |ev_json| {
                        try self.mock.sendEvent(sid, ev_json);
                    }
                    try self.mock.sendEose(sid);
                }
            },
            .ok_accepted => {
                const evt = try self.mock.recvText();
                defer self.allocator.free(evt);
                const event_id = try extractEventId(self.allocator, evt);
                defer self.allocator.free(event_id);
                try self.mock.sendOk(event_id, true, "");
            },
            .ok_rejected => |reason| {
                const evt = try self.mock.recvText();
                defer self.allocator.free(evt);
                const event_id = try extractEventId(self.allocator, evt);
                defer self.allocator.free(event_id);
                try self.mock.sendOk(event_id, false, reason);
            },
            .notice_then_eose => |msg| {
                const req = try self.mock.recvText();
                defer self.allocator.free(req);
                self.captured_sub_id = try extractSubId(self.allocator, req);
                try self.mock.sendNotice(msg);
                if (self.captured_sub_id) |sid| try self.mock.sendEose(sid);
            },
            .no_response_then_close => {
                const req = self.mock.recvText() catch null;
                if (req) |r| self.allocator.free(r);
                // Just close without responding.
            },
        }
    }
};

/// Parse `["REQ","<sub_id>",...]` and return a copy of sub_id.
fn extractSubId(allocator: std.mem.Allocator, req: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, req, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len < 2) return null;
    const verb = parsed.value.array.items[0];
    const sid = parsed.value.array.items[1];
    if (verb != .string or sid != .string) return null;
    if (!std.mem.eql(u8, verb.string, "REQ")) return null;
    return try allocator.dupe(u8, sid.string);
}

/// Parse `["EVENT", {"id": "...", ...}]` and return a copy of the event id.
fn extractEventId(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len < 2) return error.BadJson;
    const verb = parsed.value.array.items[0];
    const obj = parsed.value.array.items[1];
    if (verb != .string or !std.mem.eql(u8, verb.string, "EVENT")) return error.BadJson;
    if (obj != .object) return error.BadJson;
    const id_v = obj.object.get("id") orelse return error.BadJson;
    if (id_v != .string) return error.BadJson;
    return try allocator.dupe(u8, id_v.string);
}

// -----------------------------------------------------------------------
// Tests: subscribeAndCollect
// -----------------------------------------------------------------------

test "subscribeAndCollect: empty result on EOSE" {
    const allocator = testing.allocator;

    var mock = try mock_relay.MockRelay.start(allocator);
    defer mock.deinit();
    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    var script: ServerScript = .{
        .mock = &mock,
        .action = .eose_then_close,
        .allocator = allocator,
    };
    const t = try std.Thread.spawn(.{}, ServerScript.run, .{&script});
    defer t.join();

    var r = try relay_mod.Relay.connect(allocator, url);
    defer r.deinit();

    const events = try relay_mod.subscribeAndCollect(allocator, &r, .{ .kinds = &[_]u32{1} }, .{
        .timeout_ms = 5_000,
        .max_events = 100,
        .verify_signatures = true,
    });
    defer {
        for (events) |e| e.deinit(allocator);
        allocator.free(events);
    }

    try testing.expectEqual(@as(usize, 0), events.len);
    if (script.captured_sub_id) |sid| allocator.free(sid);
}

test "subscribeAndCollect: returns a single signed event and EOSE-terminates" {
    const allocator = testing.allocator;

    var mock = try mock_relay.MockRelay.start(allocator);
    defer mock.deinit();
    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    var ev = try buildTestEvent(allocator, 1, "hello mock");
    defer ev.deinit(allocator);
    const ev_json = try eventJsonAlloc(allocator, ev);
    defer allocator.free(ev_json);

    var script: ServerScript = .{
        .mock = &mock,
        .action = .{ .one_event_then_eose = .{ .event_json = ev_json } },
        .allocator = allocator,
    };
    const t = try std.Thread.spawn(.{}, ServerScript.run, .{&script});
    defer t.join();

    var r = try relay_mod.Relay.connect(allocator, url);
    defer r.deinit();

    const events = try relay_mod.subscribeAndCollect(allocator, &r, .{ .kinds = &[_]u32{1} }, .{
        .timeout_ms = 5_000,
        .max_events = 100,
        .verify_signatures = true,
    });
    defer {
        for (events) |e| e.deinit(allocator);
        allocator.free(events);
    }

    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("hello mock", events[0].content);
    try testing.expectEqualSlices(u8, &ev.id, &events[0].id);
    if (script.captured_sub_id) |sid| allocator.free(sid);
}

test "subscribeAndCollect: max_events cap stops collection before EOSE" {
    const allocator = testing.allocator;

    var mock = try mock_relay.MockRelay.start(allocator);
    defer mock.deinit();
    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    // Build 5 events and tell the mock to push them all before EOSE.
    var ev1 = try buildTestEvent(allocator, 1, "one");
    defer ev1.deinit(allocator);
    var ev2 = try buildTestEvent(allocator, 1, "two");
    defer ev2.deinit(allocator);
    var ev3 = try buildTestEvent(allocator, 1, "three");
    defer ev3.deinit(allocator);
    var ev4 = try buildTestEvent(allocator, 1, "four");
    defer ev4.deinit(allocator);
    var ev5 = try buildTestEvent(allocator, 1, "five");
    defer ev5.deinit(allocator);

    const j1 = try eventJsonAlloc(allocator, ev1);
    defer allocator.free(j1);
    const j2 = try eventJsonAlloc(allocator, ev2);
    defer allocator.free(j2);
    const j3 = try eventJsonAlloc(allocator, ev3);
    defer allocator.free(j3);
    const j4 = try eventJsonAlloc(allocator, ev4);
    defer allocator.free(j4);
    const j5 = try eventJsonAlloc(allocator, ev5);
    defer allocator.free(j5);

    var event_jsons = [_][]const u8{ j1, j2, j3, j4, j5 };
    var script: ServerScript = .{
        .mock = &mock,
        .action = .{ .many_events_then_eose = .{ .events_json = &event_jsons } },
        .allocator = allocator,
    };
    const t = try std.Thread.spawn(.{}, ServerScript.run, .{&script});
    defer t.join();

    var r = try relay_mod.Relay.connect(allocator, url);
    defer r.deinit();

    const events = try relay_mod.subscribeAndCollect(allocator, &r, .{ .kinds = &[_]u32{1} }, .{
        .timeout_ms = 5_000,
        .max_events = 3, // cap at 3 even though 5 are available
        .verify_signatures = true,
    });
    defer {
        for (events) |e| e.deinit(allocator);
        allocator.free(events);
    }

    try testing.expectEqual(@as(usize, 3), events.len);
    if (script.captured_sub_id) |sid| allocator.free(sid);
}

test "subscribeAndCollect: NOTICE is consumed without breaking the loop" {
    const allocator = testing.allocator;

    var mock = try mock_relay.MockRelay.start(allocator);
    defer mock.deinit();
    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    var script: ServerScript = .{
        .mock = &mock,
        .action = .{ .notice_then_eose = "you are not auth'd" },
        .allocator = allocator,
    };
    const t = try std.Thread.spawn(.{}, ServerScript.run, .{&script});
    defer t.join();

    var r = try relay_mod.Relay.connect(allocator, url);
    defer r.deinit();

    const events = try relay_mod.subscribeAndCollect(allocator, &r, .{ .kinds = &[_]u32{1} }, .{
        .timeout_ms = 5_000,
        .max_events = 10,
        .verify_signatures = true,
    });
    defer {
        for (events) |e| e.deinit(allocator);
        allocator.free(events);
    }

    try testing.expectEqual(@as(usize, 0), events.len);
    if (script.captured_sub_id) |sid| allocator.free(sid);
}

test "subscribeAndCollect: short timeout fires when relay never sends EOSE" {
    const allocator = testing.allocator;

    var mock = try mock_relay.MockRelay.start(allocator);
    defer mock.deinit();
    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    var script: ServerScript = .{
        .mock = &mock,
        .action = .no_response_then_close,
        .allocator = allocator,
    };
    const t = try std.Thread.spawn(.{}, ServerScript.run, .{&script});
    defer t.join();

    var r = try relay_mod.Relay.connect(allocator, url);
    defer r.deinit();

    const start = std.time.milliTimestamp();
    const events = try relay_mod.subscribeAndCollect(allocator, &r, .{ .kinds = &[_]u32{1} }, .{
        .timeout_ms = 500, // tight bound
        .max_events = 10,
        .verify_signatures = true,
    });
    const elapsed = std.time.milliTimestamp() - start;
    defer {
        for (events) |e| e.deinit(allocator);
        allocator.free(events);
    }

    try testing.expectEqual(@as(usize, 0), events.len);
    // PR 21 fix made timeout a true upper bound. Allow 2x slack for thread
    // scheduling on CI workers.
    try testing.expect(elapsed < 1500);
}

// -----------------------------------------------------------------------
// Tests: publishAndWait
// -----------------------------------------------------------------------

test "publishAndWait: returns true on OK accepted=true" {
    const allocator = testing.allocator;

    var mock = try mock_relay.MockRelay.start(allocator);
    defer mock.deinit();
    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    var script: ServerScript = .{
        .mock = &mock,
        .action = .ok_accepted,
        .allocator = allocator,
    };
    const t = try std.Thread.spawn(.{}, ServerScript.run, .{&script});
    defer t.join();

    var ev = try buildTestEvent(allocator, 1, "publish me");
    defer ev.deinit(allocator);

    var r = try relay_mod.Relay.connect(allocator, url);
    defer r.deinit();

    const ok = relay_mod.publishAndWait(allocator, &r, ev, 5_000);
    try testing.expect(ok);
}

test "publishAndWait: returns false on OK accepted=false" {
    const allocator = testing.allocator;

    var mock = try mock_relay.MockRelay.start(allocator);
    defer mock.deinit();
    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    var script: ServerScript = .{
        .mock = &mock,
        .action = .{ .ok_rejected = "rate-limited: try again later" },
        .allocator = allocator,
    };
    const t = try std.Thread.spawn(.{}, ServerScript.run, .{&script});
    defer t.join();

    var ev = try buildTestEvent(allocator, 1, "rejected");
    defer ev.deinit(allocator);

    var r = try relay_mod.Relay.connect(allocator, url);
    defer r.deinit();

    const ok = relay_mod.publishAndWait(allocator, &r, ev, 5_000);
    try testing.expect(!ok);
}

// -----------------------------------------------------------------------
// Tests: subscribeWithReconnect
// -----------------------------------------------------------------------

test "subscribeWithReconnect: exits cleanly when shutdown is flipped" {
    const allocator = testing.allocator;

    // No relay running at all — connect will fail. We just verify that
    // setting the shutdown flag aborts the backoff loop quickly instead of
    // hammering the unreachable host.
    var shutdown = std.atomic.Value(bool).init(false);

    const Ctx = struct {
        fn cb(c: *anyopaque, ev: nostr.Event) void {
            _ = c;
            // We never expect to be called in this test. If we are, leak the
            // event to surface the bug.
            _ = ev;
        }
    };
    var ctx: u8 = 0;

    // Spawn the subscribe in a worker, flip shutdown after a short delay.
    const Worker = struct {
        fn run(alloc: std.mem.Allocator, sd: *std.atomic.Value(bool), c: *u8) void {
            // We expect SubscribeFailed once abandon_after_ms elapses, OR an
            // early return when shutdown flips. With a very short
            // abandon_after_ms and shutdown flipped quickly, the return
            // should be the shutdown path.
            relay_mod.subscribeWithReconnect(
                alloc,
                "ws://127.0.0.1:1", // port 1 — guaranteed connect refusal
                .{ .kinds = &[_]u32{1} },
                .{
                    .backoff = .{ .base_ms = 50, .max_ms = 200, .jitter_ms = 10, .abandon_after_ms = 60_000 },
                    .max_events = 1,
                    .shutdown = sd,
                    .verify_signatures = true,
                },
                @ptrCast(c),
                Ctx.cb,
            ) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{ allocator, &shutdown, &ctx });

    // Let the worker fail-connect at least once, then signal shutdown.
    std.Thread.sleep(150 * std.time.ns_per_ms);
    shutdown.store(true, .release);

    const start = std.time.milliTimestamp();
    t.join();
    const elapsed = std.time.milliTimestamp() - start;
    // The worker should observe shutdown within ~200 ms of the flag flip
    // (one backoff chunk). Heavily-loaded CI runners can add real thread
    // scheduling latency on top, so allow 5 s of slack — false positives
    // here are pure noise.
    try testing.expect(elapsed < 5_000);
}

test "publishAndWait: returns false when the relay closes silently" {
    const allocator = testing.allocator;

    var mock = try mock_relay.MockRelay.start(allocator);
    defer mock.deinit();
    const url = try mock.urlAlloc(allocator);
    defer allocator.free(url);

    var script: ServerScript = .{
        .mock = &mock,
        .action = .no_response_then_close,
        .allocator = allocator,
    };
    const t = try std.Thread.spawn(.{}, ServerScript.run, .{&script});
    defer t.join();

    var ev = try buildTestEvent(allocator, 1, "noreply");
    defer ev.deinit(allocator);

    var r = try relay_mod.Relay.connect(allocator, url);
    defer r.deinit();

    const ok = relay_mod.publishAndWait(allocator, &r, ev, 1_000);
    try testing.expect(!ok);
}
