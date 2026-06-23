//! Aot (array-of-tables) view. Spans multiple `[[name]]` headers plus
//! their children in `Document.entries`. Follows the project's
//! diagnostic pattern.

const std = @import("std");
const doc_mod = @import("document.zig");
const kbdiag = @import("kbwinnow").kbdiagnostic;
const mut = @import("mut.zig");
const mut_table = @import("mut_table.zig");

pub const Error = mut.Error;
const Allocator = std.mem.Allocator;

pub const Aot = struct {
    const Self = @This();

    doc: *doc_mod.Document,
    aotPath: []const u8,
    headerIndices: std.ArrayList(usize) = .empty,

    pub const Iterator = struct {
        aot: *const Aot,
        index: usize = 0,

        pub fn next(self: *Iterator) ?mut_table.Table {
            if (self.index >= self.aot.headerIndices.items.len) return null;
            const header_idx = self.aot.headerIndices.items[self.index];
            defer self.index += 1;
            return mut_table.Table.forHeaderIndex(self.aot.doc, header_idx);
        }
    };

    pub fn at(
        doc: *doc_mod.Document,
        gpa: Allocator,
        path: []const u8,
    ) Allocator.Error!Self {
        var self = Self{ .doc = doc, .aotPath = path };
        try self.refresh(gpa);
        return self;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.headerIndices.deinit(gpa);
    }

    pub fn refresh(self: *Self, gpa: Allocator) Allocator.Error!void {
        self.headerIndices.clearRetainingCapacity();
        for (self.doc.entries.items, 0..) |e, i| {
            if (e.kind == .table_header and e.is_array and std.mem.eql(u8, e.path, self.aotPath)) {
                try self.headerIndices.append(gpa, i);
            }
        }
    }

    pub fn count(self: *const Self) usize {
        return self.headerIndices.items.len;
    }

    pub fn iterator(self: *const Self) Iterator {
        return .{ .aot = self };
    }

    pub fn append(
        self: *Self,
        gpa: Allocator,
        diag: ?*mut.Diagnostic,
    ) Error!mut_table.Table {
        try self.refresh(gpa);
        const new_idx = doc_mod.countHeaders(self.doc.entries.items, self.aotPath, null);
        const path_dup = gpa.dupe(u8, self.aotPath) catch return failOom(diag);
        errdefer gpa.free(path_dup);
        const leaf_dup = gpa.dupe(u8, "") catch return failOom(diag);
        errdefer gpa.free(leaf_dup);
        const entry: doc_mod.Entry = .{
            .kind = .table_header,
            .path = path_dup,
            .table_index = new_idx,
            .parent_array_index = 0,
            .is_array = true,
            .key = leaf_dup,
            .key_span = .{ .offset = 0, .length = 0 },
            .value = .{ .kind = .bare, .raw = "", .span = .{ .offset = 0, .length = 0 } },
            .header_span = .{ .offset = 0, .length = 0 },
            .leading = &.{},
            .trailing = &.{},
        };
        self.doc.entries.append(gpa, entry) catch return failOom(diag);
        try self.refresh(gpa);
        return mut_table.Table.forAotElement(self.doc, self.aotPath, new_idx);
    }

    pub fn pop(
        self: *Self,
        gpa: Allocator,
        diag: ?*mut.Diagnostic,
    ) Error!mut_table.Table {
        try self.refresh(gpa);
        if (self.headerIndices.items.len == 0) {
            if (diag) |d| {
                d.* = mut.nonExistentKey(null, .{ .offset = 0, .length = 0 }).diagnostic();
            }
            return Error.NonExistentKey;
        }
        const last_idx = self.headerIndices.items[self.headerIndices.items.len - 1];
        const removed_table = mut_table.Table.forHeaderIndex(self.doc, last_idx);
        removeRange(self.doc, last_idx);
        reindexAfterRemove(self.doc, self.aotPath);
        try self.refresh(gpa);
        return removed_table;
    }

    pub fn remove(
        self: *Self,
        gpa: Allocator,
        index: usize,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        try self.refresh(gpa);
        if (index >= self.headerIndices.items.len) {
            if (diag) |d| {
                d.* = mut.nonExistentKey(null, .{ .offset = 0, .length = 0 }).diagnostic();
            }
            return Error.NonExistentKey;
        }
        const header_idx = self.headerIndices.items[index];
        removeRange(self.doc, header_idx);
        reindexAfterRemove(self.doc, self.aotPath);
        try self.refresh(gpa);
    }
};

/// Remove all entries from `header_idx` (inclusive) until the next
/// `[[` header or end-of-document. Frees owned memory.
fn removeRange(doc: *doc_mod.Document, header_idx: usize) void {
    var end: usize = header_idx + 1;
    while (end < doc.entries.items.len) {
        if (doc.entries.items[end].kind == .table_header) break;
        end += 1;
    }
    const gpa = doc.allocator;
    var removed: usize = 0;
    while (removed < end - header_idx) : (removed += 1) {
        const entry = doc.entries.items[header_idx];
        gpa.free(entry.key);
        gpa.free(entry.value.raw);
        if (entry.value.children.len > 0) gpa.free(entry.value.children);
        if (entry.leading.len > 0) gpa.free(entry.leading);
        if (entry.trailing.len > 0) gpa.free(entry.trailing);
        _ = doc.entries.orderedRemove(header_idx);
    }
}

/// Re-index Aot entries under `aotPath` after removal so the
/// `table_index` of remaining headers stays contiguous from zero.
fn reindexAfterRemove(doc: *doc_mod.Document, aotPath: []const u8) void {
    var next: usize = 0;
    for (doc.entries.items) |*e| {
        if (e.kind == .table_header and e.is_array and std.mem.eql(u8, e.path, aotPath)) {
            e.table_index = next;
            next += 1;
        }
    }
}

fn failOom(diag: ?*mut.Diagnostic) Error {
    if (diag) |d| {
        var md: mut.MutationDiagnostic = .{
            .kind = .out_of_memory,
            .message_text = "out of memory allocating Aot entry",
            .code_str = "kbtomlkit::out_of_memory",
            .help_text = null,
            .source = null,
            .span = .{ .offset = 0, .length = 0 },
            .labels_buf = .{kbdiag.LabeledSpan.newPrimary(null, 0, 0)},
        };
        d.* = md.diagnostic();
    }
    return Error.OutOfMemory;
}

const parser_mod = @import("parser.zig");

fn makeDoc(gpa: Allocator, input: []const u8) !doc_mod.Document {
    return try parser_mod.parse(gpa, "x.toml", input);
}

test "aot append pop" {
    const gpa = std.testing.allocator;
    var doc = try makeDoc(gpa, "");
    defer doc.deinit(gpa);
    var aot = try Aot.at(&doc, gpa, "servers");
    defer aot.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), aot.count());
    var s1 = try aot.append(gpa, null);
    try s1.set(gpa, "host", try mut.string(gpa, "127.0.0.1"), null);
    try std.testing.expectEqual(@as(usize, 1), aot.count());

    _ = try aot.pop(gpa, null);
    try std.testing.expectEqual(@as(usize, 0), aot.count());
}

test "aot append multiple elements" {
    const gpa = std.testing.allocator;
    var doc = try makeDoc(gpa, "");
    defer doc.deinit(gpa);
    var aot = try Aot.at(&doc, gpa, "servers");
    defer aot.deinit(gpa);

    var s1 = try aot.append(gpa, null);
    try s1.set(gpa, "host", try mut.string(gpa, "127.0.0.1"), null);
    var s2 = try aot.append(gpa, null);
    try s2.set(gpa, "host", try mut.string(gpa, "10.0.0.1"), null);

    try std.testing.expectEqual(@as(usize, 2), aot.count());

    var it = aot.iterator();
    const first = it.next().?;
    try std.testing.expectEqualStrings("\"127.0.0.1\"", first.get("host").?.raw);
    const second = it.next().?;
    try std.testing.expectEqualStrings("\"10.0.0.1\"", second.get("host").?.raw);
}

test "aot out of bounds remove" {
    const gpa = std.testing.allocator;
    var doc = try makeDoc(gpa, "");
    defer doc.deinit(gpa);
    var aot = try Aot.at(&doc, gpa, "servers");
    defer aot.deinit(gpa);

    var d: mut.Diagnostic = undefined;
    const result = aot.remove(gpa, 0, &d);
    try std.testing.expectError(error.NonExistentKey, result);
    try std.testing.expectEqualStrings("kbtomlkit::non_existent_key", d.code().?);
}

test "aot refresh counts existing elements" {
    const gpa = std.testing.allocator;
    var doc = try makeDoc(gpa, "[[servers]]\nhost = \"127.0.0.1\"\n[[servers]]\nhost = \"10.0.0.1\"\n");
    defer doc.deinit(gpa);
    var aot = try Aot.at(&doc, gpa, "servers");
    defer aot.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), aot.count());
}
