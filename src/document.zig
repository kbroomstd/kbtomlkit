//! TOML document model: ordered entries with trivia, plus the output surface
//! (render, jsonStringify). Parser cursor state lives in `parser.zig`, not here.

const std = @import("std");
const kbdiagnostic = @import("kbdiagnostic");
const parser_mod = @import("parser.zig");
const mut = @import("mut.zig");

const path_sep: u8 = '\x02';

pub const TriviaKind = enum { comment, blank, whitespace };

pub const Trivia = struct {
    kind: TriviaKind,
    text: []const u8,
    span: kbdiagnostic.SourceSpan,
};

pub const ScalarKind = enum {
    string,
    integer,
    float,
    boolean,
    datetime,
    datetime_local,
    date_local,
    time_local,
    bare,
    array,
    inline_table,
};

pub const Scalar = struct {
    kind: ScalarKind,
    raw: []const u8,
    span: kbdiagnostic.SourceSpan,
    children: []Scalar = &.{},
    key: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try writeScalarJson(jws, self);
    }
};

pub const Entry = struct {
    kind: enum { key_value, table_header } = .key_value,
    path: []const u8 = "",
    table_index: usize = 0,
    parent_array_index: usize = 0,
    dotted: bool = false,
    is_array: bool = false,
    key: []const u8,
    key_span: kbdiagnostic.SourceSpan,
    value: Scalar,
    leading: []const Trivia = &.{},
    trailing: []const Trivia = &.{},
    header_span: ?kbdiagnostic.SourceSpan = null,
};

/// The parsed result plus its output surface. Parser-private state (cursor,
/// seen/tables maps) does not live here.
pub const Document = struct {
    const Self = @This();

    entries: std.ArrayList(Entry),
    allocator: Allocator = undefined,

    pub const empty: Self = .{ .entries = .empty };
    /// Allocator used to build this `Document`. Stored so mutation helpers
    /// can allocate without requiring callers to thread the allocator
    /// through every view method. The convention is "view is a borrow;
    /// allocator lives on the document" for views; per-call allocators
    /// still pass through for the unmanaged collection pattern.
    pub fn allocatorOf(self: *const Self) Allocator {
        return self.allocator;
    }

    pub fn deinitScalar(gpa: Allocator, scalar: *Scalar) void {
        gpa.free(scalar.raw);
        if (scalar.key) |k| gpa.free(k);
        for (scalar.children) |*child| {
            deinitScalar(gpa, child);
        }
        if (scalar.children.len > 0) gpa.free(scalar.children);
    }

    /// Release all allocated memory. Standard pattern for unmanaged
    pub fn deinit(self: *Self, gpa: Allocator) void {
        for (self.entries.items) |*entry| {
            gpa.free(entry.key);
            gpa.free(entry.path);
            deinitScalar(gpa, &entry.value);
            for (entry.leading) |t| {
                if (t.text.len > 0) gpa.free(t.text);
            }
            if (entry.leading.len > 0) gpa.free(entry.leading);
            for (entry.trailing) |t| {
                if (t.text.len > 0) gpa.free(t.text);
            }
            if (entry.trailing.len > 0) gpa.free(entry.trailing);
        }
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    /// Produce a TOML text rendering of the document. Caller owns the
    /// returned slice and must free it with `gpa`.
    pub fn render(self: *const Self, gpa: Allocator) (Allocator.Error || std.Io.Writer.Error)![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try self.renderTo(&out.writer);
        return out.toOwnedSlice();
    }

    /// Stream the TOML rendering into a caller-provided writer. Use this when
    /// you already hold a Writer (e.g. writing to a file).
    pub fn renderTo(self: *const Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.entries.items, 0..) |e, i| {
            for (e.leading) |t| {
                try w.writeAll(t.text);
                try w.writeByte('\n');
            }
            if (e.kind == .table_header) {
                if (i != 0) try w.writeByte('\n');
                if (e.is_array) try w.writeByte('[');
                try w.writeByte('[');
                try w.writeAll(e.path);
                if (e.is_array) try w.writeByte(']');
                try w.writeByte(']');
                try w.writeByte('\n');
                continue;
            }
            if (i != 0) try w.writeByte('\n');
            try w.writeAll(e.key);
            try w.writeAll(" = ");
            try w.writeAll(e.value.raw);
            for (e.trailing) |t| {
                try w.writeByte(' ');
                try w.writeAll(t.text);
            }
        }
    }

    /// JSON encoding for the toml-test decoder harness. Uses `std.json.Stringify`.
    pub fn jsonStringify(self: Self, jws: anytype) !void {
        emitObject(self.entries.items, "", null, null, jws) catch return error.WriteFailed;
    }

    /// Regenerate `Scalar.raw` from `Scalar.children` for container kinds.
    /// Leaf scalars return `raw` unchanged. Caller assigns the returned
    /// slice back to `scalar.raw` and frees the previous one with `gpa`.
    pub fn regenerateScalarRaw(gpa: std.mem.Allocator, scalar: *Scalar) anyerror![]u8 {
        switch (scalar.kind) {
            .array => {
                var buf: std.Io.Writer.Allocating = .init(gpa);
                defer buf.deinit();
                try buf.writer.writeByte('[');
                for (scalar.children, 0..) |c, i| {
                    if (i != 0) try buf.writer.writeByte(',');
                    try buf.writer.writeAll(c.raw);
                }
                try buf.writer.writeByte(']');
                return buf.toOwnedSlice();
            },
            .inline_table => {
                var buf: std.Io.Writer.Allocating = .init(gpa);
                defer buf.deinit();
                try buf.writer.writeByte('{');
                for (scalar.children, 0..) |c, i| {
                    if (i != 0) try buf.writer.writeAll(", ");
                    const key = c.key orelse return error.OutOfMemory;
                    try buf.writer.writeAll(key);
                    try buf.writer.writeAll(" = ");
                    try buf.writer.writeAll(c.raw);
                }
                try buf.writer.writeByte('}');
                return buf.toOwnedSlice();
            },
            else => return try gpa.dupe(u8, scalar.raw),
        }
    }
};

const Allocator = std.mem.Allocator;

pub fn indexOfUnescapedDot(path: []const u8, start: usize) ?usize {
    var i: usize = start;
    while (i < path.len) : (i += 1) {
        if (path[i] == '\\' and i + 1 < path.len) {
            i += 1;
            continue;
        }
        if (path[i] == '.') return i;
    }
    return null;
}

pub fn pathPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    const next = path[prefix.len];
    if (next == '.') {
        if (prefix.len > 0 and path[prefix.len - 1] == '\\') return false;
        return true;
    }
    return false;
}

pub fn childPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) {
        const dot = indexOfUnescapedDot(path, 0) orelse return path;
        return path[0..dot];
    }
    if (!pathPrefix(path, prefix) or path.len == prefix.len) return null;
    const rest = path[prefix.len + 1 ..];
    const dot = indexOfUnescapedDot(rest, 0) orelse return path;
    return path[0 .. prefix.len + 1 + dot];
}

pub fn childName(path: []const u8, prefix: []const u8) []const u8 {
    if (prefix.len == 0) {
        const dot = indexOfUnescapedDot(path, 0) orelse return unmaterializeSegment(path);
        return unmaterializeSegment(path[0..dot]);
    }
    const rest = path[prefix.len + 1 ..];
    const dot = indexOfUnescapedDot(rest, 0) orelse return unmaterializeSegment(rest);
    return unmaterializeSegment(rest[0..dot]);
}

/// Inverse of `materializeSegment`. The materialized form uses `\x01` to
/// mark an empty key segment and `\\x` escapes to carry literal `.` and
/// `\`; this function undoes both so callers see the original key text.
pub fn unmaterializeSegment(seg: []const u8) []const u8 {
    if (seg.len == 1 and seg[0] == '\x01') return "";
    return seg;
}

/// Materialize a key segment into the canonical escaped form used inside
/// `Entry.path` and `Entry.key`. Empty segments are stored as the
/// sentinel byte `\x01`; literal `.` and `\` are escaped as `\.` and `\\`.
pub fn materializeSegment(allocator: Allocator, seg: []const u8) Allocator.Error![]const u8 {
    if (seg.len == 1 and seg[0] == '\x01') return try allocator.dupe(u8, "");
    if (std.mem.indexOfScalar(u8, seg, '\\') == null) return try allocator.dupe(u8, seg);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < seg.len) : (i += 1) {
        if (seg[i] == '\\' and i + 1 < seg.len) {
            try buf.append(allocator, seg[i + 1]);
            i += 1;
        } else {
            try buf.append(allocator, seg[i]);
        }
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn countHeaders(entries: []const Entry, path: []const u8, parent_idx: ?usize) usize {
    var n: usize = 0;
    for (entries) |entry| {
        if (entry.kind == .table_header and entry.is_array and std.mem.eql(u8, entry.path, path)) {
            if (parent_idx) |pidx| {
                if (entry.parent_array_index != pidx) continue;
            }
            n += 1;
        }
    }
    return n;
}

fn emitObject(
    entries: []const Entry,
    prefix: []const u8,
    array_index: ?usize,
    parent_array_index: ?usize,
    jws: anytype,
) anyerror!void {
    try jws.beginObject();
    try emitObjectBody(entries, prefix, array_index, parent_array_index, entries.len, jws);
    try jws.endObject();
}

fn emitObjectBody(
    entries: []const Entry,
    prefix: []const u8,
    array_index: ?usize,
    parent_array_index: ?usize,
    until: usize,
    jws: anytype,
) anyerror!void {
    var emitted = std.StringHashMap(void).init(std.heap.page_allocator);
    defer emitted.deinit();
    var i: usize = 0;
    while (i < until) : (i += 1) {
        const entry = entries[i];
        if (array_index) |idx| {
            if (entry.path.len >= prefix.len) {
                if (entry.kind == .key_value) {
                    if (entry.table_index != idx) continue;
                    if (entry.parent_array_index != (parent_array_index orelse 0)) continue;
                } else if (entry.kind == .table_header and !entry.is_array) {
                    if (entry.table_index != idx) continue;
                }
            }
        }
        if (!pathPrefix(entry.path, prefix)) continue;
        if (entry.path.len == prefix.len) {
            if (entry.kind != .key_value) continue;
            try jws.objectField(unmaterializeSegment(entry.key));
            try jws.write(entry.value);
            continue;
        }
        const child_prefix = childPrefix(entry.path, prefix) orelse continue;
        if (emitted.contains(child_prefix)) continue;
        try emitted.put(child_prefix, {});
        const array_count = countHeaders(entries[0..until], child_prefix, array_index);
        const name_raw = childName(child_prefix, prefix);
        const name = try materializeSegment(std.heap.page_allocator, name_raw);
        try jws.objectField(name);
        if (name.ptr != name_raw.ptr) std.heap.page_allocator.free(name);
        if (array_count > 0) {
            try jws.beginArray();
            var idx: usize = 0;
            while (idx < array_count) : (idx += 1) {
                try emitObject(entries, child_prefix, idx, array_index, jws);
            }
            try jws.endArray();
        } else {
            try emitObject(entries, child_prefix, array_index, parent_array_index, jws);
        }
    }
}

fn decodeHex(raw: []const u8) ?u21 {
    var value: u21 = 0;
    for (raw) |c| {
        const digit: u21 = switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => return null,
        };
        const next = std.math.add(u21, std.math.mul(u21, value, 16) catch return null, digit) catch return null;
        value = next;
    }
    return value;
}

/// Decode a TOML quoted string literal to its unquoted contents. The input
/// `raw` must include the surrounding quotes.
pub fn decodeTomlString(raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;
    const is_literal = raw[0] == '\'';
    const multiline = raw.len >= 6 and ((std.mem.startsWith(u8, raw, "\"\"\"") and std.mem.endsWith(u8, raw, "\"\"\"")) or (std.mem.startsWith(u8, raw, "'''") and std.mem.endsWith(u8, raw, "'''")));
    const start: usize = if (multiline) 3 else 1;
    var end: usize = raw.len;
    end -= if (multiline) 3 else 1;
    const body = raw[start..end];
    var i: usize = 0;
    if (multiline and body.len > 0 and body[0] == '\n') i = 1;
    if (multiline and body.len >= 2 and body[0] == '\r' and body[1] == '\n') i = 2;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (is_literal or c != '\\') {
            try out.append(allocator, c);
            continue;
        }
        if (i + 1 >= body.len) return error.InvalidToml;
        i += 1;
        if (!is_literal and multiline and (body[i] == ' ' or body[i] == '\t' or body[i] == '\r' or body[i] == '\n')) {
            var j: usize = i;
            var saw_newline = false;
            while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\r' or body[j] == '\n')) : (j += 1) {
                if (body[j] == '\r' or body[j] == '\n') saw_newline = true;
            }
            if (!saw_newline) return error.InvalidToml;
            i = j - 1;
            continue;
        }
        switch (body[i]) {
            'b' => try out.append(allocator, '\x08'),
            't' => try out.append(allocator, '\t'),
            'n' => try out.append(allocator, '\n'),
            'f' => try out.append(allocator, '\x0c'),
            'r' => try out.append(allocator, '\r'),
            '"' => try out.append(allocator, '"'),
            '\\' => try out.append(allocator, '\\'),
            '/' => try out.append(allocator, '/'),
            'x' => {
                if (i + 2 >= body.len) return error.InvalidToml;
                const cp = decodeHex(body[i + 1 .. i + 3]) orelse return error.InvalidToml;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidToml;
                try out.appendSlice(allocator, buf[0..len]);
                i += 2;
            },
            'e' => try out.append(allocator, 0x1b),
            'u', 'U' => {
                const digits: usize = if (body[i] == 'u') 4 else 8;
                if (i + digits >= body.len) return error.InvalidToml;
                const cp = decodeHex(body[i + 1 .. i + 1 + digits]) orelse return error.InvalidToml;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidToml;
                try out.appendSlice(allocator, buf[0..len]);
                i += digits;
            },
            '\n' => if (multiline) {
                var saw_newline = true;
                while (i + 1 < body.len) {
                    const n = body[i + 1];
                    if (n == ' ' or n == '\t' or n == '\r' or n == '\n') {
                        if (n == '\n' or n == '\r') saw_newline = true;
                        i += 1;
                        continue;
                    }
                    break;
                }
                if (!saw_newline) return error.InvalidToml;
            } else return error.InvalidToml,
            else => return error.InvalidToml,
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn tagForKind(kind: ScalarKind) []const u8 {
    return switch (kind) {
        .string => "string",
        .integer => "integer",
        .float => "float",
        .boolean => "bool",
        .datetime => "datetime",
        .datetime_local => "datetime-local",
        .date_local => "date-local",
        .time_local => "time-local",
        else => "string",
    };
}

fn classifyRaw(raw: []const u8) ScalarKind {
    if (raw.len == 0) return .bare;
    if (raw[0] == '"') return .string;
    if (raw[0] == '[') return .array;
    if (raw[0] == '{') return .inline_table;
    if (std.mem.indexOfScalar(u8, raw, '.') != null or std.mem.indexOfAny(u8, raw, "eE") != null) return .float;
    if (std.ascii.isDigit(raw[0])) return .integer;
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "false")) return .boolean;
    if (std.mem.indexOfScalar(u8, raw, 'T') != null or std.mem.indexOfScalar(u8, raw, 'Z') != null) return .datetime;
    if (std.mem.indexOfScalar(u8, raw, ':') != null and std.mem.indexOfScalar(u8, raw, '-') == null) return .time_local;
    if (std.mem.indexOfScalar(u8, raw, '-') != null and std.mem.indexOfScalar(u8, raw, ':') == null) return .date_local;
    if (std.mem.indexOfScalar(u8, raw, ':') != null and std.mem.indexOfScalar(u8, raw, '-') != null) return .datetime_local;
    return .bare;
}

fn writeScalarJson(jws: anytype, value: Scalar) !void {
    switch (value.kind) {
        .array => {
            try jws.beginArray();
            for (value.children) |child| try writeScalarJson(jws, child);
            try jws.endArray();
        },
        .inline_table => {
            try jws.beginObject();
            var emitted = std.StringHashMap(void).init(std.heap.page_allocator);
            defer {
                var it = emitted.iterator();
                while (it.next()) |entry| std.heap.page_allocator.free(entry.key_ptr.*);
                emitted.deinit();
            }
            for (value.children) |child| {
                const key = child.key orelse return error.WriteFailed;
                const dot = indexOfUnescapedDot(key, 0);
                const field_raw = if (dot) |d| key[0..d] else key;
                const field = materializeSegment(std.heap.page_allocator, field_raw) catch return error.WriteFailed;
                const gop = emitted.getOrPut(field) catch return error.WriteFailed;
                if (gop.found_existing) {
                    std.heap.page_allocator.free(field);
                    continue;
                }
                try jws.objectField(field);
                if (dot) |d| {
                    var sub_count: usize = 0;
                    for (value.children) |c| {
                        const k = c.key orelse return error.WriteFailed;
                        if (k.len > d and std.mem.startsWith(u8, k, field_raw) and k[d] == '.' and (d == 0 or k[d - 1] != '\\')) sub_count += 1;
                    }
                    if (sub_count > 0) {
                        var sub_children = std.heap.page_allocator.alloc(Scalar, sub_count) catch return error.WriteFailed;
                        var idx: usize = 0;
                        for (value.children) |c| {
                            const k = c.key orelse return error.WriteFailed;
                            if (k.len > d and std.mem.startsWith(u8, k, field_raw) and k[d] == '.' and (d == 0 or k[d - 1] != '\\')) {
                                var nested = c;
                                nested.key = k[d + 1 ..];
                                sub_children[idx] = nested;
                                idx += 1;
                            }
                        }
                        const nested_value = Scalar{
                            .kind = .inline_table,
                            .raw = "",
                            .span = child.span,
                            .children = sub_children,
                        };
                        try writeScalarJson(jws, nested_value);
                    }
                } else {
                    try writeScalarJson(jws, child);
                }
            }
            try jws.endObject();
        },
        else => {
            try jws.beginObject();
            try jws.objectField("type");
            try jws.write(tagForKind(value.kind));
            try jws.objectField("value");
            if (value.kind == .string) {
                const decoded = decodeTomlString(value.raw) catch return error.WriteFailed;
                defer std.heap.page_allocator.free(decoded);
                try jws.write(decoded);
            } else if (value.kind == .integer) {
                var buf: [128]u8 = undefined;
                var n: usize = 0;
                for (value.raw) |c| {
                    if (c == '_') continue;
                    if (n >= buf.len) return error.WriteFailed;
                    buf[n] = c;
                    n += 1;
                }
                try jws.write(buf[0..n]);
            } else if (value.kind == .datetime) {
                try jws.write(value.raw);
            } else if (value.kind == .datetime_local) {
                try jws.write(value.raw);
            } else if (value.kind == .date_local) {
                try jws.write(value.raw);
            } else if (value.kind == .time_local) {
                try jws.write(value.raw);
            } else if (value.kind == .boolean) {
                try jws.write(value.raw);
            } else {
                try jws.write(value.raw);
            }
            try jws.endObject();
        },
    }
}
// --- Shared helpers for mut_* views -----------------------------------------

/// Convert an `Item` to a `Scalar`. Leaf variants are extracted directly;
/// compound variants (`array`, `inlineTable`) build a fresh `Scalar` that
/// borrows the view's children. Trivia/body-level variants produce a bare
/// empty scalar. Caller owns nothing — the scalar borrows from the Item.
pub fn itemToScalar(item: mut.Item) Allocator.Error!Scalar {
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

/// Convert a `Scalar` back to an `Item`. Leaf kinds map directly; arrays
/// and inline tables wrap in their respective view types.
pub fn scalarToItem(s: Scalar) mut.Item {
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

/// Regenerate `scalar.raw` from `scalar.children` for container kinds.
/// No-op when the regenerated form equals the existing `raw` slice
/// (freeing both). Leaf scalars return `raw` unchanged.
fn regenRawInPlace(gpa: Allocator, scalar: *Scalar) void {
    const new_raw = Document.regenerateScalarRaw(gpa, scalar) catch return;
    if (new_raw.ptr != scalar.raw.ptr) {
        gpa.free(scalar.raw);
        scalar.raw = new_raw;
    } else {
        gpa.free(new_raw);
    }
}

// --- Test helpers -----------------------------------------------------------

pub fn makeDoc(gpa: Allocator, input: []const u8) !Document {
    return try parser_mod.parse(gpa, "x.toml", input, null);
}

