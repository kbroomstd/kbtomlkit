//! Table view. A path-prefixed slice of `Document.entries` exposing the
//! tomlkit `Container` surface in Zig idioms. Every mutating method
//! follows the project's diagnostic pattern: takes `gpa` and an
//! optional `diag` last parameter; populates `diag.*` with a
//! `MutationDiagnostic` on failure when non-null.
//!
//! **Conventions**:
//!
//! - `path` is the stored table path (segments joined by literal `.`).
//! - `key` is a single segment, escaped (`\.` for literal `.`, `\\` for
//!   literal `\`).
//! - A `key_value` entry with `entry.path == self.prefix` belongs to
//!   this table.
//! - When `table_index` is set, only entries with that index are
//!   visible (used for Aot elements).
//! - A `table_header` entry whose `path` starts with `self.prefix + "."`
//!   represents a sub-table of this one.

const std = @import("std");
const doc_mod = @import("document.zig");
const mut = @import("mut.zig");

pub const Error = mut.Error;

const Allocator = std.mem.Allocator;

/// View over a table at a stored-path prefix. Borrows from `Document`.
/// All mutating methods take `gpa` and an optional `?*mut.Diagnostic`
/// as the trailing parameter (defaults to `null`).
pub const Table = struct {
    const Self = @This();

    /// Document this view borrows from. Lifetime equals the Document.
    doc: *doc_mod.Document,

    /// Stored path of this table. Empty string is the root table.
    prefix: []const u8,

    /// When non-null, restrict children to entries whose `table_index`
    /// equals this value. Set by `forAotElement` to select one element
    /// of an array-of-tables.
    table_index: ?usize = null,

    pub const Iterator = struct {
        entries: []const doc_mod.Entry,
        prefix: []const u8,
        table_index: ?usize,
        index: usize = 0,

        pub fn next(self: *Iterator) ?Entry {
            while (self.index < self.entries.len) : (self.index += 1) {
                const e = self.entries[self.index];
                if (e.kind != .key_value) continue;
                if (!std.mem.eql(u8, e.path, self.prefix)) continue;
                if (self.table_index) |want| if (e.table_index != want) continue;
                return .{
                    .key = doc_mod.unmaterializeSegment(e.key),
                    .raw = e.value.raw,
                    .kind = e.value.kind,
                };
            }
            return null;
        }
    };

    /// Read-only snapshot of one key/value pair.
    pub const Entry = struct {
        key: []const u8,
        raw: []const u8,
        kind: doc_mod.ScalarKind,
    };

    // --- Construction ----------------------------------------------------

    /// Construct a view of the root table of `doc`.
    pub fn root(doc: *doc_mod.Document) Self {
        return .{ .doc = doc, .prefix = "" };
    }

    /// Construct a view of the table at `path`.
    pub fn at(doc: *doc_mod.Document, path: []const u8) Self {
        return .{ .doc = doc, .prefix = path };
    }

    /// Construct a view of the Aot element at `aotPath` with `table_index`.
    pub fn forAotElement(doc: *doc_mod.Document, aotPath: []const u8, index: usize) Self {
        return .{ .doc = doc, .prefix = aotPath, .table_index = index };
    }

    /// Construct a view of the table that the entry at `header_index`
    /// opens (header is a `table_header` entry).
    pub fn forHeaderIndex(doc: *doc_mod.Document, header_index: usize) Self {
        const header = doc.entries.items[header_index];
        return .{
            .doc = doc,
            .prefix = header.path,
            .table_index = if (header.is_array) header.table_index else null,
        };
    }

    // --- Read API --------------------------------------------------------

    /// Number of direct key/value children. Trivia does not count.
    pub fn count(self: *const Self) usize {
        var n: usize = 0;
        for (self.doc.entries.items) |e| {
            if (e.kind != .key_value) continue;
            if (!std.mem.eql(u8, e.path, self.prefix)) continue;
            if (self.table_index) |want| if (e.table_index != want) continue;
            n += 1;
        }
        return n;
    }

    /// True if a key/value child exists at `key` in this table.
    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.findKeyValueIndex(key) != null;
    }

    /// Look up the scalar value at `key`. Returns null if absent.
    pub fn get(self: *const Self, key: []const u8) ?doc_mod.Scalar {
        const idx = self.findKeyValueIndex(key) orelse return null;
        return self.doc.entries.items[idx].value;
    }

    /// Iterate the direct key/value children.
    pub fn iterator(self: *const Self) Iterator {
        return .{
            .entries = self.doc.entries.items,
            .prefix = self.prefix,
            .table_index = self.table_index,
        };
    }

    // --- Write API (all take gpa + optional diag) -----------------------

    /// Set `key` to `item`, replacing any existing value.
    pub fn set(
        self: *Self,
        gpa: Allocator,
        key: []const u8,
        item: mut.Item,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        const escaped = validateKey(gpa, key, diag) orelse return error.InvalidPath;
        errdefer gpa.free(escaped);

        if (self.findKeyValueIndex(key)) |idx| {
            const new_scalar = itemToScalar(gpa, item, diag) orelse return error.KeyTypeError;
            const entry = &self.doc.entries.items[idx];
            gpa.free(entry.value.raw);
            if (entry.value.children.len > 0) gpa.free(entry.value.children);
            entry.value = new_scalar;
            return;
        }

        const new_scalar = itemToScalar(gpa, item, diag) orelse return error.KeyTypeError;
        try self.doc.entries.append(gpa, .{
            .kind = .key_value,
            .path = self.prefix,
            .table_index = self.table_index orelse 0,
            .parent_array_index = 0,
            .key = escaped,
            .key_span = .{ .offset = 0, .length = escaped.len },
            .value = new_scalar,
            .leading = &.{},
            .trailing = &.{},
        });
    }

    /// Add `key`/`item`; raises `Error.KeyAlreadyPresent` if `key`
    /// already exists in this table.
    pub fn add(
        self: *Self,
        gpa: Allocator,
        key: []const u8,
        item: mut.Item,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        const escaped = validateKey(gpa, key, diag) orelse return error.InvalidPath;
        errdefer gpa.free(escaped);

        if (self.findKeyValueIndex(key)) |idx| {
            const entry = self.doc.entries.items[idx];
            const span = entry.header_span orelse entry.key_span;
            if (diag) |d| d.* = mut.keyAlreadyPresent(null, span).diagnostic();
            return error.KeyAlreadyPresent;
        }

        const new_scalar = itemToScalar(gpa, item, diag) orelse return error.KeyTypeError;
        try self.doc.entries.append(gpa, .{
            .kind = .key_value,
            .path = self.prefix,
            .table_index = self.table_index orelse 0,
            .parent_array_index = 0,
            .key = escaped,
            .key_span = .{ .offset = 0, .length = escaped.len },
            .value = new_scalar,
            .leading = &.{},
            .trailing = &.{},
        });
    }

    /// Append `key`/`item` without checking for duplicates.
    pub fn append(
        self: *Self,
        gpa: Allocator,
        key: []const u8,
        item: mut.Item,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        const escaped = validateKey(gpa, key, diag) orelse return error.InvalidPath;
        const new_scalar = itemToScalar(gpa, item, diag) orelse return error.KeyTypeError;
        try self.doc.entries.append(gpa, .{
            .kind = .key_value,
            .path = self.prefix,
            .table_index = self.table_index orelse 0,
            .parent_array_index = 0,
            .key = escaped,
            .key_span = .{ .offset = 0, .length = escaped.len },
            .value = new_scalar,
            .leading = &.{},
            .trailing = &.{},
        });
    }

    /// Remove the entry at `key`.
    pub fn remove(
        self: *Self,
        gpa: Allocator,
        key: []const u8,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        _ = gpa;
        const idx = self.findKeyValueIndex(key) orelse {
            if (diag) |d| {
                d.* = mut.nonExistentKey(null, .{
                    .offset = self.prefix.len,
                    .length = key.len,
                }).diagnostic();
            }
            return error.NonExistentKey;
        };
        const entry = self.doc.entries.items[idx];
        freeEntry(self.doc.allocator, entry);
        _ = self.doc.entries.orderedRemove(idx);
    }

    /// Equality. Two tables are equal when their direct children match
    /// key-for-key and value-for-value.
    pub fn eql(self: *const Self, other: Self) bool {
        if (self.count() != other.count()) return false;
        var it = self.iterator();
        while (it.next()) |e| {
            const other_val = other.get(e.key) orelse return false;
            if (other_val.kind != e.kind) return false;
            if (!std.mem.eql(u8, other_val.raw, e.raw)) return false;
        }
        return true;
    }

    // --- Internals -------------------------------------------------------

    fn validateKey(gpa: Allocator, key: []const u8, diag: ?*mut.Diagnostic) ?[]const u8 {
        if (key.len == 0) {
            if (diag) |d| d.* = mut.invalidPath("key is empty").diagnostic();
            return null;
        }
        if (std.mem.indexOfScalar(u8, key, '.') != null) {
            if (diag) |d| {
                d.* = mut.keyTypeError(
                    null,
                    .{ .offset = 0, .length = key.len },
                    "simple key",
                    "dotted key",
                ).diagnostic();
            }
            return null;
        }
        return mut.escapeKey(gpa, key) catch {
            if (diag) |d| d.* = mut.invalidPath("escape allocation failed").diagnostic();
            return null;
        };
    }

    fn findKeyValueIndex(self: *const Self, key: []const u8) ?usize {
        const escaped = mut.escapeKey(self.doc.allocator, key) catch return null;
        defer self.doc.allocator.free(escaped);
        var i: usize = 0;
        while (i < self.doc.entries.items.len) : (i += 1) {
            const e = self.doc.entries.items[i];
            if (e.kind != .key_value) continue;
            if (!std.mem.eql(u8, e.path, self.prefix)) continue;
            if (self.table_index) |want| if (e.table_index != want) continue;
            if (std.mem.eql(u8, e.key, escaped)) return i;
        }
        return null;
    }
};

fn itemToScalar(_: Allocator, item: mut.Item, diag: ?*mut.Diagnostic) ?doc_mod.Scalar {
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
        else => {
            if (diag) |d| {
                d.* = mut.keyTypeError(
                    null,
                    .{ .offset = 0, .length = 0 },
                    "scalar",
                    @tagName(item),
                ).diagnostic();
            }
            return null;
        },
    };
}

fn freeEntry(gpa: Allocator, entry: doc_mod.Entry) void {
    gpa.free(entry.key);
    gpa.free(entry.value.raw);
    if (entry.value.children.len > 0) gpa.free(entry.value.children);
    if (entry.leading.len > 0) gpa.free(entry.leading);
    if (entry.trailing.len > 0) gpa.free(entry.trailing);
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const parser_mod = @import("parser.zig");

fn makeDoc(gpa: Allocator, input: []const u8) !doc_mod.Document {
    return try parser_mod.parse(gpa, "x.toml", input);
}

test "table set replaces existing key" {
    const gpa = testing.allocator;
    var doc = try makeDoc(gpa, "host = \"127.0.0.1\"\n");
    defer doc.deinit(gpa);

    var t = Table.root(&doc);
    try t.set(gpa, "host", try mut.string(gpa, "10.0.0.1"), null);
    try testing.expectEqualStrings("\"10.0.0.1\"", t.get("host").?.raw);
}

test "table set appends new key" {
    const gpa = testing.allocator;
    var doc = try makeDoc(gpa, "name = \"x\"\n");
    defer doc.deinit(gpa);

    var t = Table.root(&doc);
    try t.set(gpa, "port", try mut.integer(gpa, @as(i64, 8080)), null);
    try testing.expect(t.contains("port"));
    try testing.expectEqual(@as(usize, 2), t.count());
}

test "table add rejects duplicate with diagnostic" {
    const gpa = testing.allocator;
    var doc = try makeDoc(gpa, "k = 1\n");
    defer doc.deinit(gpa);

    var t = Table.root(&doc);
    var d: mut.Diagnostic = undefined;
    const result = t.add(gpa, "k", try mut.integer(gpa, @as(i64, 2)), &d);
    try testing.expectError(error.KeyAlreadyPresent, result);
    try testing.expectEqualStrings("kbtomlkit::key_already_present", d.code().?);
}

test "table remove raises non-existent with diagnostic" {
    const gpa = testing.allocator;
    var doc = try makeDoc(gpa, "k = 1\n");
    defer doc.deinit(gpa);

    var t = Table.root(&doc);
    var d: mut.Diagnostic = undefined;
    const result = t.remove(gpa, "missing", &d);
    try testing.expectError(error.NonExistentKey, result);
    try testing.expectEqualStrings("kbtomlkit::non_existent_key", d.code().?);
}

test "table count and iterator on parsed document" {
    const gpa = testing.allocator;
    var doc = try makeDoc(gpa, "a = 1\nb = 2\nc = 3\n");
    defer doc.deinit(gpa);

    var t = Table.root(&doc);
    try testing.expectEqual(@as(usize, 3), t.count());

    var seen: usize = 0;
    var it = t.iterator();
    while (it.next()) |e| {
        try testing.expect(std.mem.eql(u8, e.key, "a") or
            std.mem.eql(u8, e.key, "b") or
            std.mem.eql(u8, e.key, "c"));
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "table forAotElement scopes by table_index" {
    const gpa = testing.allocator;
    var doc = try makeDoc(
        gpa,
        "[[servers]]\nhost = \"127.0.0.1\"\n[[servers]]\nhost = \"10.0.0.1\"\n",
    );
    defer doc.deinit(gpa);

    var s0 = Table.forAotElement(&doc, "servers", 0);
    try testing.expectEqualStrings("\"127.0.0.1\"", s0.get("host").?.raw);
    var s1 = Table.forAotElement(&doc, "servers", 1);
    try testing.expectEqualStrings("\"10.0.0.1\"", s1.get("host").?.raw);
}
