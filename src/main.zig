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
    stop,
    shutdown,
    setTimestamp: usize,
};
const Queue = vaxis.Queue(ServerEvent, 512);

fn lyricsThread(loop: *vaxis.Loop(Event), events: *Queue) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer if (gpa.deinit() != .ok) log.err("memory leak", .{});
    const alloc = gpa.allocator();

    block: {
        var mpd = try Mpd.init(alloc, "localhost", 6600);
        defer mpd.deinit();

        var current: ?struct { id: u64, ls: ?Lyrics, ts: u64 } = null;
        while (true) {
            while (events.tryPop()) |e| switch (e) {
                .stop => break :block,
                .shutdown => return,
                .setTimestamp => |n| if (current) |cur| {
                    try mpd.seekId(cur.id, n);
                },
            };

            var status = try mpd.status();
            defer status.deinit();

            const state = status.state();
            loop.postEvent(.{ .state = state });

            if (current == null or current.?.id != status.songId()) {
                var song = try mpd.currentSong();
                defer song.deinit();

                loop.postEvent(.{
                    .song = try mem.ownedPtr(alloc, try song.dupe(alloc)),
                });

                const query = try std.fmt.allocPrint(alloc, "{}", .{song});
                defer alloc.free(query);

                const lyrics = Lyrics.init(alloc, query) catch |e| switch (e) {
                    error.Command => null,
                    else => return e,
                };
                errdefer if (lyrics) |l| l.deinit();

                if (current) |cur| {
                    if (cur.ls) |ls| ls.deinit();
                }

                if (lyrics == null or lyrics.?.lyrics.len == 0) {
                    loop.postEvent(.{ .lyrics = null });
                } else {
                    loop.postEvent(.{
                        .lyrics = try mem.ownedPtr(alloc, try lyrics.?.dupe(alloc)),
                    });
                }

                current = .{ .id = status.songId(), .ls = lyrics, .ts = 0 };
            }

            if (current) |*cur| if (cur.ls) |ls| {
                const elapsed = status.elapsed();
                const id = blk: {
                    for (0..ls.lyrics.len - 1) |i| {
                        if (elapsed < ls.lyrics[i + 1].timestamp) {
                            break :blk i;
                        }
                    }

                    if (ls.lyrics.len != 0) {
                        break :blk ls.lyrics.len - 1;
                    }

                    break :blk null;
                };

                if (id) |id_| {
                    loop.postEvent(.{ .lyrics_id = id_ });
                }
            };

            std.time.sleep(std.time.ns_per_ms * 100);
        }
    }

    log.debug("thread: got stop, waiting for shutdown", .{});

    while (true) switch (events.pop()) {
        .shutdown => return,
        else => {},
    };

    log.debug("thread: shutting down", .{});
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
                } else if (key.matches('k', .{})) {
                    if (lyrics) |l| {
                        const i = @max(lyrics_id -| 1, 0);
                        queue.push(.{ .setTimestamp = l.lyrics[i].timestamp });
                    }
                } else if (key.matches('j', .{})) {
                    if (lyrics) |l| {
                        if (lyrics_id == 0) {
                            queue.push(.{ .setTimestamp = 0 });
                        } else {
                            const i = @min(lyrics_id + 1, l.lyrics.len);
                            queue.push(.{ .setTimestamp = l.lyrics[i].timestamp });
                        }
                    }
                }
            },

            .winsize => |ws| try vx.resize(alloc, tty.anyWriter(), ws),
            .state => |s| state = s,

            .song => |s| {
                if (song) |so| so.deinit();
                song = s.p.*;
                s.deinit();

                if (lyrics) |ll| {
                    ll.deinit();
                    lyrics = null;
                }
            },

            .lyrics => |l| {
                defer if (l) |ll| ll.deinit();

                if (lyrics) |ll| {
                    ll.deinit();
                    lyrics = null;
                }

                if (l) |ll|
                    lyrics = ll.p.*;
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
            .border = .{ .where = .all, .glyphs = .single_square },
        });

        const titleBox = win.child(.{
            .x_off = stateS.len + 2,
            .height = .{ .limit = 3 },
            .border = .{ .where = .all, .glyphs = .single_square },
        });

        const lyricsBox = win.child(.{
            .y_off = 3,
            .border = .{ .where = .all, .glyphs = .single_square },
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
                lyricsBox.clear();

                var start: usize = 0;
                var ls = ls_.lyrics;

                if (ls_.lyrics.len > lyricsBox.height) {
                    start = @min(lyrics_id -| lyricsBox.height / 2, ls_.lyrics.len -| lyricsBox.height);
                    ls = ls_.lyrics[start..@min(start + lyricsBox.height, ls_.lyrics.len)];
                }

                for (ls, 0..) |l, i| {
                    const style: vaxis.Style = switch (std.math.order(i + start, lyrics_id)) {
                        .lt => .{ .fg = gray },
                        .eq => .{ .fg = red, .bg = black },
                        .gt => .{ .fg = .default },
                    };

                    const box = lyricsBox.child(.{
                        .y_off = offset,
                        .height = .{ .limit = 1 },
                    });

                    box.fill(.{ .style = style });

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

    loop.stop();
    queue.push(.stop);

    while (loop.tryEvent()) |e| switch (e) {
        .song => |s| {
            s.p.deinit();
            s.deinit();
        },
        .lyrics => |l| if (l) |ll| {
            ll.p.deinit();
            ll.deinit();
        },
        else => {},
    };

    queue.push(.shutdown);
    thread.detach();
}
