const std = @import("std");
const log = std.log.scoped(.mpd);

const maps = @import("ownedMaps.zig");

const Self = @This();

allocator: std.mem.Allocator,
stream: std.net.Stream,

const StringMap = maps.OwnedStringHashMap(u8);
pub const Song = struct {
    x: StringMap,

    pub fn init(alloc: std.mem.Allocator) !Song {
        return .{ .x = StringMap.init(alloc) };
    }

    pub fn deinit(self: Song) void {
        self.x.deinit();
    }

    pub fn dupe(self: Song, allocator: ?std.mem.Allocator) !Song {
        return .{
            .x = try self.x.dupe(allocator),
        };
    }

    pub fn title(self: Song) []const u8 {
        return self.x.get("Title") orelse "Unknown";
    }

    pub fn album(self: Song) []const u8 {
        return self.x.get("Album") orelse "Unknown";
    }

    pub fn artist(self: Song) []const u8 {
        return self.x.get("Artist") orelse "Unknown";
    }

    pub fn format(self: Song, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} - {s}", .{ self.artist(), self.title() });
    }
};

fn readLine(self: *Self) ![]u8 {
    var buf = std.ArrayList(u8).init(self.allocator);
    errdefer buf.deinit();

    try self.stream.reader().streamUntilDelimiter(buf.writer(), '\n', null);
    return try buf.toOwnedSlice();
}

fn getAnswer(self: *Self) !StringMap {
    var res = StringMap.init(self.allocator);
    errdefer res.deinit();

    while (self.readLine()) |line| {
        defer self.allocator.free(line);

        if (std.mem.startsWith(u8, line, "ACK")) {
            log.err("{s}", .{line});
            return error.Unknown;
        } else if (std.mem.startsWith(u8, line, "OK")) {
            break;
        } else {
            var it = std.mem.split(u8, line, ": ");
            const key = it.first();
            const value = it.next() orelse {
                log.err("ill formed response: {s}", .{line});
                return error.Unknown;
            };

            if (res.get(key)) |val| {
                log.err("key {s} is already set to {s}, ignoring value {s}", .{ key, val, value });
                continue;
            }

            try res.put(key, value);
        }
    } else |e| return e;

    return res;
}

pub fn init(alloc: std.mem.Allocator, host: []const u8, port: u16) !Self {
    var self: Self = .{
        .allocator = alloc,
        .stream = try std.net.tcpConnectToHost(alloc, host, port),
    };

    // we just check wether it errors
    var tmp = try self.getAnswer();
    tmp.deinit();

    return self;
}

pub fn deinit(self: Self) void {
    self.stream.close();
}

fn send(self: Self, comptime fmt: []const u8, args: anytype) !void {
    try self.stream.writer().print(fmt, args);
}

pub fn currentSong(self: *Self) !Song {
    try self.send("currentsong\n", .{});

    const answer = try self.getAnswer();
    errdefer self.freeLines(&answer);
    return Song{ .x = answer };
}

const Subsystem = enum {
    database,
    update,
    stored_playlist,
    playlist,
    player,
    mixer,
    output,
    options,
    partitions,
    sticker,
    subscription,
    message,
    neightbor,
    mount,

    pub fn parse(s: []const u8) !Subsystem {
        const map = std.StaticStringMap(Subsystem).initComptime(&.{
            .{ "database", .database },
            .{ "update", .update },
            .{ "stored_playlist", .stored_playlist },
            .{ "playlist", .playlist },
            .{ "player", .player },
            .{ "mixer", .mixer },
            .{ "output", .output },
            .{ "options", .options },
            .{ "partitions", .partitions },
            .{ "sticker", .sticker },
            .{ "subscription", .subscription },
            .{ "message", .message },
            .{ "neightbor", .neightbor },
            .{ "mount", .mount },
        });
        return map.get(s) orelse error.Unknown;
    }

    pub fn format(self: Subsystem, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll(switch (self) {
            .database => "database",
            .update => "update",
            .stored_playlist => "stored_playlist",
            .playlist => "playlist",
            .player => "player",
            .mixer => "mixer",
            .output => "output",
            .options => "options",
            .partitions => "partitions",
            .sticker => "sticker",
            .subscription => "subscription",
            .message => "message",
            .neightbor => "neightbor",
            .mount => "mount",
        });
    }
};

pub fn idle(self: *Self, subsystems: []const Subsystem) !Subsystem {
    var args = std.ArrayList(u8).init(self.allocator);
    defer args.deinit();

    for (subsystems) |subsystem| {
        try args.writer().print(" {}", .{subsystem});
    }

    try self.send("idle {s}\n", .{args.items});
    var answer = try self.getAnswer();
    defer answer.deinit();

    const changed = answer.get("changed") orelse {
        log.err("malformed idle response, expected `changed`", .{});
        return error.Unknown;
    };

    return Subsystem.parse(changed);
}

pub const Status = struct {
    x: StringMap,

    pub fn init(alloc: std.mem.Allocator) Status {
        return .{ .x = StringMap.init(alloc) };
    }

    pub fn deinit(self: *Status) void {
        self.x.deinit();
    }

    pub fn elapsed(self: Status) u64 {
        const elapsed_ = self.x.get("elapsed") orelse
            std.debug.panic("status did not return an `elapsed` field", .{});

        const f = std.fmt.parseFloat(f64, elapsed_) catch |e|
            std.debug.panic("could not parse float: {}", .{e});

        return @intFromFloat(f * std.time.ns_per_s);
    }

    pub fn songId(self: Status) u64 {
        const id = self.x.get("songid") orelse
            std.debug.panic("status did not return a `songid` field", .{});

        return std.fmt.parseInt(u64, id, 0) catch |e|
            std.debug.panic("could not parse int: {}", .{e});
    }

    pub const State = enum {
        play,
        pause,
        stop,

        pub fn format(self: State, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll(switch (self) {
                .play => "playing",
                .pause => "paused",
                .stop => "stopped",
            });
        }
    };

    pub fn state(self: Status) State {
        const state_ = self.x.get("state") orelse
            std.debug.panic("status did not return a `state` field", .{});

        return std.StaticStringMap(State).initComptime(&.{
            .{ "play", .play },
            .{ "pause", .pause },
            .{ "stop", .stop },
        })
            .get(state_) orelse
            std.debug.panic("unknown state value: {s}", .{state_});
    }
};

pub fn status(self: *Self) !Status {
    try self.send("status\n", .{});

    const answer = try self.getAnswer();
    errdefer self.freeLines(&answer);
    return Status{ .x = answer };
}
