const std = @import("std");
const log = std.log.scoped(.lyrics_mem);

pub fn OwnedPtr(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        p: *T,

        pub fn init(allocator: std.mem.Allocator, x: T) error{OutOfMemory}!OwnedPtr(T) {
            const p = try allocator.create(T);
            p.* = x;

            return .{
                .allocator = allocator,
                .p = p,
            };
        }

        pub fn deinit(self: OwnedPtr(T)) void {
            self.allocator.destroy(self.p);
        }
    };
}

pub fn ownedPtr(allocator: std.mem.Allocator, x: anytype) error{OutOfMemory}!OwnedPtr(@TypeOf(x)) {
    return try OwnedPtr(@TypeOf(x)).init(allocator, x);
}
