const std = @import("std");
const log = std.log.scoped(.lyrics);

fn eat(s: *[]const u8) error{SyntaxError}!u8 {
    if (s.len == 0) return error.SyntaxError;
    const c = s.*[0];
    s.* = s.*[1..];
    return c;
}

fn expect(c: u8, s: *[]const u8) error{SyntaxError}!void {
    if (try eat(s) != c)
        return error.SyntaxError;
}

pub const Lyric = struct {
    timestamp: u64,
    text: []const u8,

    pub fn parse(alloc: std.mem.Allocator, s_: []const u8) !Lyric {
        var s = s_;
        try expect('[', &s);

        var timestamp = @as(u64, @intCast(try eat(&s) - '0')) * 10 * std.time.ns_per_min;
        timestamp += @as(u64, @intCast(try eat(&s) - '0')) * std.time.ns_per_min;

        try expect(':', &s);

        timestamp += @as(u64, @intCast(try eat(&s) - '0')) * 10 * std.time.ns_per_s;
        timestamp += @as(u64, @intCast(try eat(&s) - '0')) * std.time.ns_per_s;

        try expect('.', &s);

        timestamp += @as(u64, @intCast(try eat(&s) - '0')) * std.time.ns_per_s / 10;
        timestamp += @as(u64, @intCast(try eat(&s) - '0')) * std.time.ns_per_s / 100;

        try expect(']', &s);

        expect(' ', &s) catch
            return .{ .timestamp = timestamp, .text = "" };

        return .{ .timestamp = timestamp, .text = try alloc.dupe(u8, s) };
    }

    pub fn deinit(self: Lyric, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
    }

    pub fn format(self: Lyric, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try std.fmt.format(writer, "{d}:{s}", .{ self.timestamp, self.text });
    }
};

const Self = @This();

allocator: std.mem.Allocator,
lyrics: []Lyric,

fn fromBuffer(alloc: std.mem.Allocator, buf: []const u8) !Self {
    var lyrics = std.ArrayList(Lyric).init(alloc);
    errdefer lyrics.deinit();

    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        if (line.len > 0) {
            const parsed = try Lyric.parse(alloc, line);
            errdefer parsed.deinit(alloc);

            try lyrics.append(parsed);
        }
    }

    return .{
        .lyrics = try lyrics.toOwnedSlice(),
        .allocator = alloc,
    };
}

pub fn init(alloc: std.mem.Allocator, query: []const u8) !Self {
    const path = try std.fs.realpathAlloc(alloc, "/home/flo/Music/lyrics");
    var dir = try std.fs.cwd().makeOpenPath(path, .{});
    defer dir.close();

    const filename = try std.fmt.allocPrint(alloc, "{s}.lrc", .{query});
    defer alloc.free(filename);

    const fullpath = try std.fs.path.join(alloc, &.{ path, filename });
    defer alloc.free(fullpath);

    const fullpath_ = fullpath[0..@min(fullpath.len, std.fs.max_path_bytes)];
    if (std.fs.openFileAbsolute(fullpath_, .{})) |file| {
        defer file.close();

        const stats = try file.stat();
        const buf = try file.readToEndAlloc(alloc, stats.size);
        defer alloc.free(buf);

        return fromBuffer(alloc, buf);
    } else |_| {
        const res = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "syncedlyrics", query, "-o", fullpath_ },
            .expand_arg0 = .expand,
        });
        defer alloc.free(res.stderr);
        defer alloc.free(res.stdout);

        if (res.stderr.len > 0) {
            log.err("could not fetch lyrics: {s}", .{res.stderr});
            return error.Command;
        }

        return fromBuffer(alloc, res.stdout);
    }
}

pub fn deinit(self: Self) void {
    for (self.lyrics) |l| {
        l.deinit(self.allocator);
    }

    self.allocator.free(self.lyrics);
}

pub fn dupe(self: Self, allocator: ?std.mem.Allocator) !Self {
    const alloc = if (allocator) |a| a else self.allocator;

    const lyrics = try alloc.alloc(Lyric, self.lyrics.len);
    errdefer alloc.free(lyrics);

    for (lyrics, self.lyrics) |*lp, l| {
        lp.* = .{
            .timestamp = l.timestamp,
            .text = try alloc.dupe(u8, l.text),
        };
    }

    return .{ .allocator = alloc, .lyrics = lyrics };
}

pub fn get(self: Self, timestamp: u64) ?Lyric {
    for (0..self.lyrics.len - 1) |i| {
        if (timestamp < self.lyrics[i + 1].timestamp) {
            return self.lyrics[i];
        }
    }

    if (self.lyrics.len != 0) {
        return self.lyrics[self.lyrics.len - 1];
    }

    return null;
}
