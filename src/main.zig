const std = @import("std");
const log = std.log.scoped(.lyrics);

const vaxis = @import("vaxis");

const mem = @import("mem.zig");
const Mpd = @import("Mpd.zig");
const Lyrics = @import("Lyrics.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    state: Mpd.Status.State,
    song: mem.OwnedPtr(Mpd.Song),
    lyrics: ?mem.OwnedPtr(Lyrics),
    lyrics_id: usize,
};

const ServerEvent = union(enum) {
    shutdown,
};
const Queue = vaxis.Queue(ServerEvent, 512);

fn lyricsThread(loop: *vaxis.Loop(Event), events: *Queue) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) log.err("memory leak", .{});
    const alloc = gpa.allocator();

    var mpd = try Mpd.init(alloc, "localhost", 6600);
    defer mpd.deinit();

    var current: ?struct { id: u64, ls: Lyrics, ts: u64 } = null;
    while (true) {
        if (events.tryPop()) |e| switch (e) {
            .shutdown => break,
        };

        var status = try mpd.status();
        defer status.deinit();

        const state = status.state();
        loop.postEvent(.{ .state = state });
        if (state != .play) {
            // wait for next music
            _ = try mpd.idle(&.{.player});
            continue;
        }

        if (current == null or current.?.id != status.songId()) {
            var song = try mpd.currentSong();
            defer song.deinit();

            loop.postEvent(.{
                .song = try mem.ownedPtr(alloc, try song.dupe(alloc)),
            });

            const query = try std.fmt.allocPrint(alloc, "{}", .{song});
            defer alloc.free(query);

            const lyrics = Lyrics.init(alloc, query) catch |e| switch (e) {
                error.Command => {
                    // could not fetch lyrics, wait for next music
                    _ = try mpd.idle(&.{.player});
                    continue;
                },
                else => return e,
            };
            errdefer lyrics.deinit();

            if (current) |cur| {
                cur.ls.deinit();
            }

            if (lyrics.lyrics.len == 0) {
                loop.postEvent(.{ .lyrics = null });

                _ = try mpd.idle(&.{.player});
                continue;
            } else {
                loop.postEvent(.{
                    .lyrics = try mem.ownedPtr(alloc, try lyrics.dupe(alloc)),
                });
            }

            current = .{ .id = status.songId(), .ls = lyrics, .ts = 0 };
        }

        if (current) |*cur| {
            const elapsed = status.elapsed();
            const id = blk: {
                for (0..cur.ls.lyrics.len - 1) |i| {
                    if (elapsed < cur.ls.lyrics[i + 1].timestamp) {
                        break :blk i;
                    }
                }

                if (cur.ls.lyrics.len != 0) {
                    break :blk cur.ls.lyrics.len - 1;
                }

                break :blk null;
            };

            if (id) |id_| {
                loop.postEvent(.{ .lyrics_id = id_ });
            }
        }

        std.time.sleep(std.time.ns_per_ms * 100);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer if (gpa.deinit() != .ok) log.err("memory leak", .{});
    const alloc = gpa.allocator();

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();

    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());

    var song: ?Mpd.Song = null;
    defer if (song) |*s| s.deinit();

    var lyrics: ?Lyrics = null;
    defer if (lyrics) |*l| l.deinit();

    var lyrics_id: usize = 0;

    var state: Mpd.Status.State = .stop;

    var queue = Queue{};

    const thread = try std.Thread.spawn(.{}, lyricsThread, .{ &loop, &queue });
    defer thread.join();

    while (true) {
        switch (loop.nextEvent()) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or
                    key.matches('q', .{}))
                {
                    queue.push(.shutdown);
                    break;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                }
            },

            .winsize => |ws| try vx.resize(alloc, tty.anyWriter(), ws),
            .state => |s| state = s,

            .song => |s| {
                defer s.deinit();

                if (song) |*so| so.deinit();
                song = s.p.*;
                if (lyrics) |*ll| ll.deinit();
                lyrics = null;
            },

            .lyrics => |l| {
                defer if (l) |ll| ll.deinit();

                if (lyrics) |*ll| ll.deinit();
                lyrics = if (l) |ll| ll.p.* else null;
            },

            .lyrics_id => |n| lyrics_id = n,
        }

        const win = vx.window();
        win.clear();

        const stateS = try std.fmt.allocPrint(alloc, "{}", .{state});
        defer alloc.free(stateS);

        const stateBox = win.child(.{
            .height = .{ .limit = 3 },
            .width = .{ .limit = stateS.len + 2 },
            .border = .{ .where = .all },
        });

        const titleBox = win.child(.{
            .x_off = stateS.len + 2,
            .height = .{ .limit = 3 },
            .border = .{ .where = .all },
        });

        const currentLyricBox = win.child(.{
            .y_off = 3,
            .height = .{ .limit = 3 },
            .border = .{ .where = .all },
        });

        const lyricsBox = win.child(.{
            .y_off = 6,
            .height = .{ .limit = win.height - 3 },
            .border = .{ .where = .all },
        });

        const black: vaxis.Color = .{ .index = 0 };
        const red: vaxis.Color = .{ .index = 1 };
        const gray: vaxis.Color = .{ .index = 8 };

        if (song) |s| {
            const full = try std.fmt.allocPrint(
                alloc,
                "{s} - {s} - {s}",
                .{ s.artist(), s.album(), s.title() },
            );
            defer alloc.free(full);
            _ = try titleBox.printSegment(.{
                .text = full,
            }, .{});

            _ = try stateBox.printSegment(
                .{ .text = stateS },
                .{},
            );

            var offset: usize = 0;
            if (lyrics) |ls_| {
                if (lyrics_id < ls_.lyrics.len) {
                    _ = try currentLyricBox.printSegment(
                        .{ .text = ls_.lyrics[lyrics_id].text },
                        .{ .wrap = .none },
                    );
                }

                lyricsBox.clear();

                var start: usize = 0;
                const ls = if (ls_.lyrics.len > lyricsBox.height) blk: {
                    start = @min(lyrics_id -| lyricsBox.height / 2, ls_.lyrics.len -| lyricsBox.height);
                    break :blk ls_.lyrics[start..@min(start + lyricsBox.height, ls_.lyrics.len)];
                } else ls_.lyrics;

                for (ls, 0..) |l, i| {
                    const style: vaxis.Style = switch (std.math.order(i + start, lyrics_id)) {
                        .lt => .{ .fg = gray },
                        .eq => .{ .fg = red, .bg = black },
                        .gt => .{ .fg = .default },
                    };

                    const res = try lyricsBox.printSegment(
                        .{
                            .text = l.text,
                            .style = style,
                        },
                        .{
                            .row_offset = offset,
                            .wrap = .none,
                        },
                    );

                    offset = res.row + 1;
                }
            }

            try vx.render(tty.anyWriter());
        }
    }
}
