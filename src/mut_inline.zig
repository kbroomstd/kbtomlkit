//! InlineTable view. Pointer to a `Scalar { kind = .inline_table }`
//! plus mutation helpers. Follows the project's diagnostic pattern.
//!
//! After every mutation, `scalar.raw` is regenerated in place so the
//! caller can `doc.render` and see the new content immediately.

const std = @import("std");
const doc_mod = @import("document.zig");
const mut = @import("mut.zig");

pub const Error = mut.Error;
const Allocator = std.mem.Allocator;

pub const InlineTable = struct {
    const Self = @This();

    scalar: *doc_mod.Scalar,

    pub const Entry = struct {
        key: []const u8,
        item: mut.Item,
    };

    pub const Iterator = struct {
        table: *const InlineTable,
        index: usize = 0,

        pub fn next(self: *Iterator) ?Entry {
            if (self.index >= self.table.scalar.children.len) return null;
            const c = self.table.scalar.children[self.index];
            defer self.index += 1;
            return .{
                .key = c.key orelse "",
                .item = scalarToItem(c),
            };
        }
    };

    pub fn count(self: *const Self) usize {
        return self.scalar.children.len;
    }

    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.findIndex(key) != null;
    }

    pub fn get(self: *const Self, key: []const u8) ?mut.Item {
        const idx = self.findIndex(key) orelse return null;
        return scalarToItem(self.scalar.children[idx]);
    }

    pub fn iterator(self: *const Self) Iterator {
        return .{ .table = self };
    }

    pub fn unwrap(self: *const Self) []const doc_mod.Scalar {
        return self.scalar.children;
    }

    /// Borrowed `*Scalar` for use by views that wrap inline tables.
    pub fn ownerScalar(self: *const Self) *doc_mod.Scalar {
        return @constCast(self.scalar);
    }

    pub fn set(
        self: *Self,
        gpa: Allocator,
        key: []const u8,
        item: mut.Item,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        if (std.mem.indexOfScalar(u8, key, '.') != null) {
            if (diag) |d| {
                d.* = mut.keyTypeError(
                    null,
                    .{ .offset = 0, .length = key.len },
                    "simple key",
                    "dotted key",
                ).diagnostic();
            }
            return Error.KeyTypeError;
        }
        const new_key = gpa.dupe(u8, key) catch return Error.OutOfMemory;
        errdefer gpa.free(new_key);
        var new_scalar = itemToScalar(item);
        new_scalar.key = new_key;
        if (self.findIndex(key)) |idx| {
            const old = self.scalar.children;
            gpa.free(old[idx].key orelse "");
            gpa.free(old[idx].raw);
            if (old[idx].children.len > 0) gpa.free(old[idx].children);
            self.scalar.children[idx] = new_scalar;
            regenRawInPlace(gpa, self.scalar);
            return;
        }
        try self.appendChild(gpa, new_scalar);
        regenRawInPlace(gpa, self.scalar);
    }

    pub fn add(
        self: *Self,
        gpa: Allocator,
        key: []const u8,
        item: mut.Item,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        if (std.mem.indexOfScalar(u8, key, '.') != null) {
            if (diag) |d| {
                d.* = mut.keyTypeError(
                    null,
                    .{ .offset = 0, .length = key.len },
                    "simple key",
                    "dotted key",
                ).diagnostic();
            }
            return Error.KeyTypeError;
        }
        if (self.findIndex(key) != null) {
            if (diag) |d| {
                d.* = mut.keyAlreadyPresent(null, .{ .offset = 0, .length = key.len }).diagnostic();
            }
            return Error.KeyAlreadyPresent;
        }
        const new_key = gpa.dupe(u8, key) catch return Error.OutOfMemory;
        errdefer gpa.free(new_key);
        var new_scalar = itemToScalar(item);
        new_scalar.key = new_key;
        try self.appendChild(gpa, new_scalar);
        regenRawInPlace(gpa, self.scalar);
    }

    pub fn remove(
        self: *Self,
        gpa: Allocator,
        key: []const u8,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        const idx = self.findIndex(key) orelse {
            if (diag) |d| {
                d.* = mut.nonExistentKey(null, .{ .offset = 0, .length = key.len }).diagnostic();
            }
            return Error.NonExistentKey;
        };
        const old = self.scalar.children;
        gpa.free(old[idx].key orelse "");
        gpa.free(old[idx].raw);
        if (old[idx].children.len > 0) gpa.free(old[idx].children);
        const new_ptr: []doc_mod.Scalar = gpa.alloc(doc_mod.Scalar, old.len - 1) catch return Error.OutOfMemory;
        std.mem.copyForwards(doc_mod.Scalar, new_ptr[0..idx], old[0..idx]);
        std.mem.copyForwards(doc_mod.Scalar, new_ptr[idx..], old[idx + 1 ..]);
        if (old.len > 0) gpa.free(old);
        self.scalar.children = new_ptr;
        regenRawInPlace(gpa, self.scalar);
    }

    fn appendChild(self: *Self, gpa: Allocator, new_scalar: doc_mod.Scalar) Allocator.Error!void {
        const old = self.scalar.children;
        const new_ptr: []doc_mod.Scalar = try gpa.alloc(doc_mod.Scalar, old.len + 1);
        std.mem.copyForwards(doc_mod.Scalar, new_ptr[0..old.len], old);
        new_ptr[old.len] = new_scalar;
        if (old.len > 0) gpa.free(old);
        self.scalar.children = new_ptr;
    }

    fn findIndex(self: *const Self, key: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.scalar.children.len) : (i += 1) {
            const c = self.scalar.children[i];
            const k = c.key orelse continue;
            const unmaterialized = doc_mod.unmaterializeSegment(k);
            if (std.mem.eql(u8, unmaterialized, key)) return i;
        }
        return null;
    }
};

fn itemToScalar(item: mut.Item) doc_mod.Scalar {
    return switch (item) {
        .integer => |s| s,
        .float => |s| s,
        .bool => |s| s,
        .string => |s| s,
        .datetime => |s| s,
        .datetimeLocal => |s| s,
        .dateLocal => |s| s,
        .timeLocal => |s| s,
        .bare => |s| s,
        .array => |a| .{
            .kind = .array,
            .raw = a.scalar.raw,
            .span = a.scalar.span,
            .children = a.scalar.children,
        },
        .inlineTable => |t| .{
            .kind = .inline_table,
            .raw = t.ownerScalar().raw,
            .span = t.ownerScalar().span,
            .children = t.ownerScalar().children,
            .key = null,
        },
        .comment, .whitespace, .nullMarker, .tableHeader, .aot => .{
            .kind = .bare,
            .raw = "",
            .span = .{ .offset = 0, .length = 0 },
        },
    };
}

fn scalarToItem(s: doc_mod.Scalar) mut.Item {
    return switch (s.kind) {
        .integer => .{ .integer = s },
        .float => .{ .float = s },
        .boolean => .{ .bool = s },
        .string => .{ .string = s },
        .datetime => .{ .datetime = s },
        .datetime_local => .{ .datetimeLocal = s },
        .date_local => .{ .dateLocal = s },
        .time_local => .{ .timeLocal = s },
        .array => .{ .array = .{ .scalar = @constCast(&s) } },
        .inline_table => .{ .inlineTable = .{ .scalar = @constCast(&s) } },
        else => .{ .bare = s },
    };
}

fn regenRawInPlace(gpa: Allocator, scalar: *doc_mod.Scalar) void {
    const new_raw = doc_mod.Document.regenerateScalarRaw(gpa, scalar) catch return;
    if (new_raw.ptr != scalar.raw.ptr) {
        gpa.free(scalar.raw);
        scalar.raw = new_raw;
    } else {
        gpa.free(new_raw);
    }
}

const parser_mod = @import("parser.zig");

fn makeDoc(gpa: Allocator, input: []const u8) !doc_mod.Document {
    return try parser_mod.parse(gpa, "x.toml", input);
}

test "inline set remove" {
    const gpa = std.testing.allocator;
    var doc = try makeDoc(gpa, "point = {x = 1}\n");
    defer doc.deinit(gpa);
    var it = InlineTable{ .scalar = &doc.entries.items[0].value };

    try it.set(gpa, "y", try mut.integer(gpa, @as(i64, 2)), null);
    try std.testing.expect(it.contains("x"));
    try std.testing.expect(it.contains("y"));

    try it.remove(gpa, "x", null);
    try std.testing.expect(!it.contains("x"));
    try std.testing.expect(it.contains("y"));
}

test "inline set regenerates raw" {
    const gpa = std.testing.allocator;
    var doc = try makeDoc(gpa, "point = {x = 1}\n");
    defer doc.deinit(gpa);
    var it = InlineTable{ .scalar = &doc.entries.items[0].value };

    try it.set(gpa, "y", try mut.integer(gpa, @as(i64, 2)), null);
    try std.testing.expect(std.mem.indexOf(u8, doc.entries.items[0].value.raw, "x") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.entries.items[0].value.raw, "y") != null);
}

test "inline add rejects duplicate with diagnostic" {
    const gpa = std.testing.allocator;
    var doc = try makeDoc(gpa, "point = {x = 1, y = 2}\n");
    defer doc.deinit(gpa);
    var it = InlineTable{ .scalar = &doc.entries.items[0].value };

    try it.add(gpa, "z", try mut.integer(gpa, @as(i64, 3)), null);
    try std.testing.expect(it.contains("z"));

    var d: mut.Diagnostic = undefined;
    const result = it.add(gpa, "z", try mut.integer(gpa, @as(i64, 4)), &d);
    try std.testing.expectError(error.KeyAlreadyPresent, result);
    try std.testing.expectEqualStrings("kbtomlkit::key_already_present", d.code().?);
}

test "inline iterator yields entries" {
    const gpa = std.testing.allocator;
    var doc = try makeDoc(gpa, "point = {x = 1, y = 2}\n");
    defer doc.deinit(gpa);
    var it = InlineTable{ .scalar = &doc.entries.items[0].value };

    try std.testing.expectEqual(@as(usize, 2), it.count());
    var it_iter = it.iterator();
    const first = it_iter.next().?;
    try std.testing.expect(std.mem.eql(u8, first.key, "x") or std.mem.eql(u8, first.key, "y"));
    const second = it_iter.next().?;
    try std.testing.expect(std.mem.eql(u8, second.key, "x") or std.mem.eql(u8, second.key, "y"));
    try std.testing.expect(it_iter.next() == null);
}
