const std = @import("std");
const log = std.log.scoped(.lyrics);

pub fn OwnedStringHashMap(comptime T: type) type {
    const K = []const u8;
    const V = []const T;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        h: std.hash_map.StringHashMapUnmanaged(V),

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .allocator = alloc,
                .h = .{},
            };
        }

        pub fn deinit(self: Self) void {
            var it = self.h.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            var h = self.h;
            h.deinit(self.allocator);
        }

        pub fn dupe(self: Self, allocator: ?std.mem.Allocator) !Self {
            const alloc = if (allocator) |a| a else self.allocator;
            var res = Self.init(alloc);

            var it = self.h.iterator();
            while (it.next()) |entry| {
                try res.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            return res;
        }

        pub fn contains(self: Self, key: K) bool {
            return self.h.contains(key);
        }

        pub fn get(self: Self, key: K) ?V {
            return self.h.get(key);
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.h.getEntry(key)) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }

            try self.h.put(
                self.allocator,
                try self.allocator.dupe(u8, key),
                try self.allocator.dupe(T, value),
            );
        }
    };
}
