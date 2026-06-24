//! TOML parser using kbwinnow parser combinators.
//!
//! Low-level token parsing (strings, keys, numbers, booleans,
//! datetimes) uses kbwinnow's combinator API — each parser is a
//! struct with a `parseNext(ctx)` method returning
//! `error{Backtrack,Cut}!T`.
//!
//! The high-level document loop (trivia, table headers, key-value
//! entries) is hand-written because it manages DocBuilder state
//! (table path, conflict tracking, array counts) alongside the
//! cursor — the same pattern kbkdl uses.

const std = @import("std");
const kbwinnow = @import("kbwinnow");
const doc = @import("document.zig");
const diagmod = @import("diagnostics.zig");
const kbdiagnostic = @import("kbdiagnostic");

const Str = kbwinnow.Str;
const Stream = kbwinnow.stream_interface.Stream;
const ParseContext = kbwinnow.ParseContext;
const DiagnosticContext = kbwinnow.DiagnosticContext;

const token = kbwinnow.token;
const combinator = kbwinnow.combinator;
const parser_mod = kbwinnow.parser;

const take_while_1 = token.take_while_1;
const alt = combinator.alt;
const eof_fn = combinator.eof;

// ── Public API ───────────────────────────────────────────────────────────
pub const ParseError = error{ InvalidToml, DuplicateKey, OutOfMemory };

/// Parse a TOML document from a kbwinnow Stream.
/// Skip whitespace (space, tab, newline, carriage return) on the stream.
fn skipWs(s: Stream) void {
    while (s.peekByte(0)) |b| {
        if (b == ' ' or b == '\t' or b == '\n' or b == '\r') {
            _ = s.nextByte();
        } else break;
    }
}

/// Skip horizontal whitespace (space, tab only) on the stream.
fn skipHws(s: Stream) void {
    while (s.peekByte(0)) |b| {
        if (b == ' ' or b == '\t') {
            _ = s.nextByte();
        } else break;
    }
}

/// On error, `out_diagnostic` is set to the diagnostic with error details.
pub fn parse(alloc: std.mem.Allocator, name: []const u8, input: []const u8, out_diagnostic: ?*?kbdiagnostic.Diagnostic) ParseError!doc.Document {
    // Validate UTF-8
    if (!isValidUtf8(input)) return error.InvalidToml;

    // Normalize CRLF → LF
    const normalized = try normalizeCrlf(alloc, input);
    defer if (normalized.ptr != input.ptr) alloc.free(normalized);

    var ds = Str.init(normalized);
    var ctx = DiagnosticContext.init(alloc, ds.interface());
    defer ctx.deinit();
    const pc = ctx.asContext();

    var builder: DocBuilder = .{
        .alloc = alloc,
        .entries = .empty,
        .source = .{ .name = name, .data = normalized },
        .seen = std.StringHashMap(void).init(alloc),
        .tables = std.StringHashMap(void).init(alloc),
        .dotted_implicit = std.StringHashMap(void).init(alloc),
        .header_implicit = std.StringHashMap(void).init(alloc),
        .array_tables = std.StringHashMap(void).init(alloc),
        .array_counts = std.StringHashMap(usize).init(alloc),
        .pending_trivia = .empty,
    };
    parseDocument(pc, &builder) catch {
        const dup = builder.duplicate_key_detected;
        if (out_diagnostic) |od| od.* = ctx.diagnostic();
        builder.deinit();
        if (dup) return error.DuplicateKey;
        return error.InvalidToml;
    };
    if (ds.remaining().len > 0) {
        ctx.reportEx(.{
            .message = "unexpected content after value",
            .code = diagCode(.unexpected_token),
            .span = .{ .offset = ds.cursor(), .length = ds.remaining().len },
        });
        if (out_diagnostic) |od| od.* = ctx.diagnostic();
        builder.deinit();
        return error.InvalidToml;
    }

    const document: doc.Document = .{ .entries = builder.entries, .allocator = alloc };
    builder.entries = .empty;
    builder.deinitNonEntries();
    return document;
}

fn normalizeCrlf(alloc: std.mem.Allocator, input: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '\r') == null) return input;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\r') {
            if (i + 1 >= input.len or input[i + 1] != '\n') return error.InvalidToml;
            try buf.append(alloc, '\n');
            i += 1;
        } else {
            try buf.append(alloc, input[i]);
        }
    }
    return buf.toOwnedSlice(alloc);
}

// ── DocBuilder ───────────────────────────────────────────────────────────

const DocBuilder = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(doc.Entry),
    source: kbdiagnostic.NamedSource,
    table_path: []const u8 = "",
    table_is_array: bool = false,
    active_array_path: []const u8 = "",
    active_array_index: usize = 0,
    parent_array_index: usize = 0,
    seen: std.StringHashMap(void),
    tables: std.StringHashMap(void),
    dotted_implicit: std.StringHashMap(void),
    header_implicit: std.StringHashMap(void),
    array_tables: std.StringHashMap(void),
    array_counts: std.StringHashMap(usize),
    pending_trivia: std.ArrayList(doc.Trivia),
    duplicate_key_detected: bool = false,
    temp_allocs: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *DocBuilder) void {
        for (self.entries.items) |*entry| {
            self.alloc.free(entry.key);
            self.alloc.free(entry.path);
            doc.Document.deinitScalar(self.alloc, &entry.value);
            if (entry.leading.len > 0) self.alloc.free(entry.leading);
            if (entry.trailing.len > 0) self.alloc.free(entry.trailing);
        }
        self.entries.deinit(self.alloc);
        self.seen.deinit();
        self.tables.deinit();
        self.dotted_implicit.deinit();
        self.header_implicit.deinit();
        self.array_tables.deinit();
        self.array_counts.deinit();
        for (self.pending_trivia.items) |t| {
            if (t.text.len > 0) self.alloc.free(t.text);
        }
        self.pending_trivia.deinit(self.alloc);
        for (self.temp_allocs.items) |a| self.alloc.free(a);
        self.temp_allocs.deinit(self.alloc);
    }
    /// Free builder state (hash maps, trivia) without freeing entries.
    /// Used on the success path after entries have been moved to Document.
    fn deinitNonEntries(self: *DocBuilder) void {
        self.seen.deinit();
        self.tables.deinit();
        self.dotted_implicit.deinit();
        self.header_implicit.deinit();
        self.array_tables.deinit();
        self.array_counts.deinit();
        self.pending_trivia.deinit(self.alloc);
        for (self.temp_allocs.items) |a| self.alloc.free(a);
        self.temp_allocs.deinit(self.alloc);
    }

    fn appendEntry(self: *DocBuilder, entry: doc.Entry) std.mem.Allocator.Error!void {
        try self.entries.append(self.alloc, entry);
    }

    fn takePendingTrivia(self: *DocBuilder) std.mem.Allocator.Error![]doc.Trivia {
        const items = try self.pending_trivia.toOwnedSlice(self.alloc);
        self.pending_trivia = .empty;
        return items;
    }

    fn addPendingTrivia(self: *DocBuilder, t: doc.Trivia) std.mem.Allocator.Error!void {
        try self.pending_trivia.append(self.alloc, t);
    }

    fn currentTablePath(self: *const DocBuilder) []const u8 {
        return self.table_path;
    }

    fn setTablePath(self: *DocBuilder, path: []const u8) void {
        self.table_path = path;
    }

    fn setArrayTablePath(self: *DocBuilder, path: []const u8, index: usize, parent_idx: usize) void {
        self.table_path = path;
        self.table_is_array = true;
        self.active_array_path = path;
        self.active_array_index = index;
        self.parent_array_index = parent_idx;
    }
};

// ── UTF-8 / control char ─────────────────────────────────────────────────

fn isControlChar(c: u8) bool {
    return (c <= 0x08) or (c >= 0x0b and c <= 0x0c) or (c >= 0x0e and c <= 0x1f) or c == 0x7f;
}

fn isValidUtf8(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        const seq_len: usize = switch (c) {
            0x00...0x7f => 1,
            0xc2...0xdf => 2,
            0xe0...0xef => 3,
            0xf0...0xf4 => 4,
            else => return false,
        };
        if (i + seq_len > input.len) return false;
        if (seq_len > 1) {
            if (input[i + 1] & 0xc0 != 0x80) return false;
            if (seq_len > 2) {
                if (input[i + 2] & 0xc0 != 0x80) return false;
                if (seq_len > 3) {
                    if (input[i + 3] & 0xc0 != 0x80) return false;
                    if (c == 0xf0 and input[i + 1] < 0x90) return false;
                    if (c == 0xf4 and input[i + 1] > 0x8f) return false;
                }
                if (c == 0xe0 and input[i + 1] < 0xa0) return false;
                if (c == 0xed and input[i + 1] > 0x9f) return false;
            }
        }
        i += seq_len;
    }
    return true;
}

// ── String parsers (combinator structs) ──────────────────────────────────

/// Single-line basic string `"..."`.
const BasicStringP = struct {
    const Self = @This();
    pub fn parseNext(_: Self, ctx: ParseContext) error{ Backtrack, Cut }![]const u8 {
        const s = ctx.stream();
        if (s.peekByte(0) != @as(?u8, '"')) return error.Backtrack;
        if (s.startsWith("\"\"\"")) return error.Backtrack; // let MlBasicStringP handle it
        const start = s.cursor();
        _ = s.nextByte();
        while (true) {
            const b = s.nextByte() orelse return cutUnterm(ctx, start);
            if (b == '"') return s.data()[start..s.cursor()];
            if (b == '\n') return cutUnterm(ctx, start);
            if (isControlChar(b)) return cutEscape(ctx, s.cursor() - 1, 1);
            if (b == '\\') {
                const esc = s.nextByte() orelse return cutUnterm(ctx, start);
                switch (esc) {
                    '\\', '"', 'b', 't', 'n', 'f', 'r', 'u', 'U', 'x', 'e' => {},
                    else => return cutEscape(ctx, s.cursor() - 2, 2),
                }
            }
        }
    }
};

/// Single-line literal string `'...'`.
const LiteralStringP = struct {
    const Self = @This();
    pub fn parseNext(_: Self, ctx: ParseContext) error{ Backtrack, Cut }![]const u8 {
        const s = ctx.stream();
        if (s.peekByte(0) != @as(?u8, '\'')) return error.Backtrack;
        if (s.startsWith("'''")) return error.Backtrack; // let MlLiteralStringP handle it
        const start = s.cursor();
        _ = s.nextByte();
        while (true) {
            const b = s.nextByte() orelse return cutUnterm(ctx, start);
            if (b == '\'') return s.data()[start..s.cursor()];
            if (b == '\n') return cutUnterm(ctx, start);
            if (isControlChar(b)) return cutEscape(ctx, s.cursor() - 1, 1);
        }
    }
};

/// Multiline basic string `"""..."""`.
const MlBasicStringP = struct {
    const Self = @This();
    pub fn parseNext(_: Self, ctx: ParseContext) error{ Backtrack, Cut }![]const u8 {
        const s = ctx.stream();
        if (!s.startsWith("\"\"\"")) return error.Backtrack;
        const start = s.cursor();
        _ = s.take(3);
        // Trim leading newline
        if (s.startsWith("\n")) _ = s.take(1)
        else if (s.startsWith("\r\n")) _ = s.take(2);
        while (true) {
            const b = s.nextByte() orelse return cutUnterm(ctx, start);
            if (b == '"') {
                var q: usize = 1;
                while (s.peekByte(@intCast(q - 1)) == @as(?u8, '"')) q += 1;
                if (q >= 3) {
                    s.setCursor(s.cursor() + (q - 1));
                    return s.data()[start..s.cursor()];
                }
                continue;
            }
            if (b == '\\') {
                const esc = s.nextByte() orelse return cutUnterm(ctx, start);
                if (esc == ' ' or esc == '\t' or esc == '\n' or esc == '\r') {
                    var saw_nl = (esc == '\n' or esc == '\r');
                    while (true) {
                        const cb = s.peekByte(0) orelse break;
                        if (cb == '\n' or cb == '\r') saw_nl = true;
                        if (cb != ' ' and cb != '\t' and cb != '\n' and cb != '\r') break;
                        _ = s.nextByte();
                    }
                    if (!saw_nl) return cutEscape(ctx, s.cursor() - 1, 1);
                } else {
                    switch (esc) {
                        '\\', '"', 'b', 't', 'n', 'f', 'r', 'u', 'U', 'x', 'e' => {},
                        else => return cutEscape(ctx, s.cursor() - 2, 2),
                    }
                }
                continue;
            }
            if (b == '\r') return cutEscape(ctx, s.cursor() - 1, 1);
            if (isControlChar(b) and b != '\t') return cutEscape(ctx, s.cursor() - 1, 1);
        }
    }
};

/// Multiline literal string `'''...'''`.
const MlLiteralStringP = struct {
    const Self = @This();
    pub fn parseNext(_: Self, ctx: ParseContext) error{ Backtrack, Cut }![]const u8 {
        const s = ctx.stream();
        if (!s.startsWith("'''")) return error.Backtrack;
        const start = s.cursor();
        _ = s.take(3);
        if (s.startsWith("\n")) _ = s.take(1)
        else if (s.startsWith("\r\n")) _ = s.take(2);
        while (true) {
            const b = s.nextByte() orelse return cutUnterm(ctx, start);
            if (b == '\'') {
                var q: usize = 1;
                while (s.peekByte(@intCast(q - 1)) == @as(?u8, '\'')) q += 1;
                if (q >= 3) {
                    s.setCursor(s.cursor() + (q - 1));
                    return s.data()[start..s.cursor()];
                }
                continue;
            }
            if (b == '\r') return cutEscape(ctx, s.cursor() - 1, 1);
            if (isControlChar(b) and b != '\t') return cutEscape(ctx, s.cursor() - 1, 1);
        }
    }
};

const string_parser = alt(.{ BasicStringP{}, LiteralStringP{}, MlBasicStringP{}, MlLiteralStringP{} });

fn cutUnterm(ctx: ParseContext, start: usize) error{ Backtrack, Cut } {
    ctx.reportEx(.{
        .message = diagMessage(.unterminated_string),
        .code = diagCode(.unterminated_string),
        .span = .{ .offset = start, .length = ctx.stream().cursor() - start },
    });
    ctx.cut();
    return error.Cut;
}

fn cutEscape(ctx: ParseContext, offset: usize, length: usize) error{ Backtrack, Cut } {
    ctx.reportEx(.{
        .message = diagMessage(.invalid_escape),
        .code = diagCode(.invalid_escape),
        .span = .{ .offset = offset, .length = length },
    });
    ctx.cut();
    return error.Cut;
}

// ── Key parsers (combinator structs) ─────────────────────────────────────

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

const BareKeyP = struct {
    const Self = @This();
    pub fn parseNext(_: Self, ctx: ParseContext) error{ Backtrack, Cut }![]const u8 {
        const s = ctx.stream();
        if (s.peekByte(0)) |b| {
            if (!isBareKeyChar(b)) return error.Backtrack;
        } else return error.Backtrack;
        return take_while_1(isBareKeyChar).parseNext(ctx);
    }
};

const QuotedKeyP = struct {
    const Self = @This();
    pub fn parseNext(_: Self, ctx: ParseContext) error{ Backtrack, Cut }![]const u8 {
        return alt(.{ BasicStringP{}, LiteralStringP{} }).parseNext(ctx);
    }
};

const simple_key = alt(.{ BareKeyP{}, QuotedKeyP{} });

// ── Document parser ──────────────────────────────────────────────────────

const DiagKind = enum {
    duplicate_key,
    invalid_escape,
    unterminated_string,
    invalid_number,
    invalid_datetime,
    unexpected_token,
    unterminated_container,
};

fn diagCode(kind: DiagKind) []const u8 {
    return switch (kind) {
        .duplicate_key => "toml.parse.duplicate_key",
        .invalid_escape => "toml.parse.invalid_escape",
        .unterminated_string => "toml.parse.unterminated_string",
        .invalid_number => "toml.parse.invalid_number",
        .invalid_datetime => "toml.parse.invalid_datetime",
        .unexpected_token => "toml.parse.unexpected_token",
        .unterminated_container => "toml.parse.unterminated_container",
    };
}

fn diagMessage(kind: DiagKind) []const u8 {
    return switch (kind) {
        .duplicate_key => "duplicate key",
        .invalid_escape => "invalid escape sequence",
        .unterminated_string => "unterminated string",
        .invalid_number => "invalid number",
        .invalid_datetime => "invalid datetime",
        .unexpected_token => "unexpected token",
        .unterminated_container => "unterminated array or inline table",
    };
}

fn diagHelp(kind: DiagKind) ?[]const u8 {
    return switch (kind) {
        .duplicate_key => "keys must be unique within a table",
        .invalid_escape => "use TOML escape forms: \\n, \\t, \\\\, \\\", \\uXXXX, etc.",
        .unterminated_string => "close the string with the matching delimiter",
        .invalid_number => "use a canonical TOML numeric form",
        .invalid_datetime => "use TOML date, time, local datetime, or offset datetime forms",
        .unexpected_token => null,
        .unterminated_container => "close the array with `]` or inline table with `}`",
    };
}

/// parseDocument — line-oriented top-level loop.
fn parseDocument(ctx: ParseContext, builder: *DocBuilder) anyerror!void {
    const alloc = builder.alloc;
    const s = ctx.stream();
    while (true) {
        if (s.remaining().len == 0) return;
        const line_start = s.cursor();
        // Skip leading whitespace (space/tab only, not newline).
        skipHws(s);
        const content_start = s.cursor();
        if (content_start >= s.data().len) return;

        // Comment line
        if (s.peekByte(0) == @as(?u8, '#')) {
            const cs = s.cursor();
            while (true) {
                const b = s.nextByte() orelse break;
                if (b == '\n') {
                    s.setCursor(s.cursor() - 1);
                    break;
                }
            }
            const comment_text = s.data()[cs..s.cursor()];
            if (hasControlChars(comment_text)) {
                ctx.reportEx(.{
                    .message = diagMessage(.invalid_escape),
                    .code = diagCode(.invalid_escape),
                    .span = .{ .offset = line_start, .length = s.cursor() - line_start },
                });
                ctx.cut();
                return error.Cut;
            }
            try builder.addPendingTrivia(.{
                .kind = .comment,
                .text = try alloc.dupe(u8, comment_text),
                .span = .{ .offset = content_start, .length = comment_text.len },
            });
            consumeNewline(s);
            continue;
        }

        // Blank line
        if (s.peekByte(0) == @as(?u8, '\n')) {
            try builder.addPendingTrivia(.{
                .kind = .blank,
                .text = "",
                .span = .{ .offset = s.cursor(), .length = 0 },
            });
            _ = s.nextByte();
            continue;
        }

        // Table header `[...]` or `[[...]]`
        if (s.peekByte(0) == @as(?u8, '[')) {
            try parseTableHeader(ctx, builder);
            continue;
        }

        // Key-value entry
        try parseKeyValue(ctx, builder);
    }
}

fn consumeNewline(s: Stream) void {
    if (s.peekByte(0) == @as(?u8, '\n')) {
        _ = s.nextByte();
    }
}

// ── Table header ─────────────────────────────────────────────────────────

fn parseTableHeader(ctx: ParseContext, builder: *DocBuilder) anyerror!void {
    const alloc = builder.alloc;
    const s = ctx.stream();
    const start = s.cursor();
    const is_array = s.startsWith("[[");
    _ = if (is_array) s.take(2) else s.take(1);

    // Capture path text
    const path_start = s.cursor();
    var depth: usize = 1;
    while (true) {
        const b = s.nextByte() orelse {
            ctx.reportEx(.{
                .message = diagMessage(.unterminated_container),
                .code = diagCode(.unterminated_container),
                .span = .{ .offset = start, .length = s.cursor() - start },
            });
            ctx.cut();
            return error.Cut;
        };
        if (b == '[' or b == '{') depth += 1;
        if (b == ']' or b == '}') {
            depth -= 1;
            if (depth == 0) {
                s.setCursor(s.cursor() - 1);
                break;
            }
        }
    }
    const path_text = s.data()[path_start..s.cursor()];

    if (is_array) {
        if (!s.startsWith("]]")) {
            ctx.reportEx(.{
                .message = diagMessage(.unterminated_container),
                .code = diagCode(.unterminated_container),
                .span = .{ .offset = start, .length = s.cursor() - start },
            });
            ctx.cut();
            return error.Cut;
        }
        _ = s.take(2);
    } else {
        if (s.peekByte(0) != @as(?u8, ']')) {
            ctx.reportEx(.{
                .message = diagMessage(.unterminated_container),
                .code = diagCode(.unterminated_container),
                .span = .{ .offset = start, .length = s.cursor() - start },
            });
            ctx.cut();
            return error.Cut;
        }
        _ = s.nextByte();
    }

    // After the closing bracket(s), only whitespace and/or a comment
    // are allowed before the newline/EOF.
    while (s.peekByte(0)) |b| {
        if (b == ' ' or b == '\t') {
            _ = s.nextByte();
        } else break;
    }
    // Check for invalid trailing content (not comment, not newline, not EOF).
    if (s.peekByte(0)) |b| {
        if (b != '#' and b != '\n') {
            ctx.reportEx(.{
                .message = diagMessage(.unexpected_token),
                .code = diagCode(.unexpected_token),
                .span = .{ .offset = s.cursor(), .length = 1 },
            });
            ctx.cut();
            return error.Cut;
        }
    }
    var line_end = s.cursor();
    while (line_end < s.data().len and s.data()[line_end] != '\n') : (line_end += 1) {}
    s.setCursor(line_end);
    consumeNewline(s);

    // Parse the path using combinator parser
    var path_ds = Str.init(path_text);
    var path_ctx = DiagnosticContext.init(alloc, path_ds.interface());
    defer path_ctx.deinit();
    const path = parseDottedKeyPath(path_ctx.asContext(), alloc) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        ctx.reportEx(.{
            .message = "invalid table header path",
            .code = diagCode(.unexpected_token),
            .span = .{ .offset = start, .length = s.cursor() - start },
        });
        ctx.cut();
        return error.Cut;
    };
    // Validate: entire path text must be consumed, path must be non-empty.
    if (path_ds.remaining().len > 0 or path.len == 0) {
        ctx.reportEx(.{
            .message = "invalid table header path",
            .code = diagCode(.unexpected_token),
            .span = .{ .offset = start, .length = s.cursor() - start },
        });
        ctx.cut();
        return error.Cut;
    }
    try builder.temp_allocs.append(alloc, path);
    // Conflict detection (same logic as old parser)
    if (!is_array) {
        const repeated = isArrayChild(builder, path);
        if ((arrayTableDescendantConflict(path, &builder.array_tables) or builder.array_tables.contains(path)) and !repeated)
            return reportDupKey(ctx, builder, start);
        if (builder.dotted_implicit.contains(path) and !repeated)
            return reportDupKey(ctx, builder, start);
        if (builder.tables.contains(path) and !repeated)
            return reportDupKey(ctx, builder, start);
        if (pathHasValuePrefix(path, &builder.seen) and !repeated)
            return reportDupKey(ctx, builder, start);
        if (pathHasSubKey(path, &builder.seen) and !builder.header_implicit.contains(path) and !repeated)
            return reportDupKey(ctx, builder, start);
        try markHeaderImplicit(&builder.header_implicit, path);
        const keep_ctx = builder.table_is_array and
            (std.mem.startsWith(u8, path, builder.currentTablePath()) or
            (builder.active_array_path.len > 0 and std.mem.startsWith(u8, path, builder.active_array_path)));
        try builder.tables.put(path, {});
        builder.setTablePath(path);
        builder.table_is_array = keep_ctx;
        const split = splitKeyPath(path);
        try builder.appendEntry(.{
            .kind = .table_header,
            .path = try alloc.dupe(u8, path),
            .table_index = if (keep_ctx) builder.active_array_index else 0,
            .is_array = false,
            .key = try materializeKey(alloc, split.leaf),
            .key_span = .{ .offset = start, .length = s.cursor() - start },
            .value = .{ .kind = .bare, .raw = try alloc.dupe(u8, ""), .span = .{ .offset = start, .length = 0 } },
            .header_span = .{ .offset = start, .length = s.cursor() - start },
            .leading = try builder.takePendingTrivia(),
        });
        return;
    }
    // Array table
    const repeated = isArrayChild(builder, path);
    if (!builder.array_tables.contains(path) and anyArrayTableAncestorConflict(path, &builder.array_tables) and !repeated) {
        return reportDupKey(ctx, builder, start);
    }
    if (!builder.array_tables.contains(path) and (pathConflictWithKeys(path, &builder.seen) or builder.tables.contains(path)) and !repeated) {
        return reportDupKey(ctx, builder, start);
    }
    try markHeaderImplicit(&builder.header_implicit, path);
    const parent_idx: usize = if (!builder.table_is_array) 0 else arrayParentIdx(builder, path);
    const count_key = try std.fmt.allocPrint(alloc, "{d}@{s}", .{ parent_idx, path });
    try builder.temp_allocs.append(alloc, count_key);
    const count = builder.array_counts.get(count_key) orelse 0;
    try builder.array_counts.put(count_key, count + 1);
    if (!builder.array_tables.contains(path)) try builder.array_tables.put(path, {});
    const split = splitKeyPath(path);
    builder.setArrayTablePath(path, count, parent_idx);
    try builder.appendEntry(.{
        .kind = .table_header,
        .path = try alloc.dupe(u8, path),
        .table_index = count,
        .parent_array_index = parent_idx,
        .is_array = true,
        .key = try materializeKey(alloc, split.leaf),
        .key_span = .{ .offset = start, .length = s.cursor() - start },
        .value = .{ .kind = .bare, .raw = try alloc.dupe(u8, ""), .span = .{ .offset = start, .length = 0 } },
        .header_span = .{ .offset = start, .length = s.cursor() - start },
        .leading = try builder.takePendingTrivia(),
    });
}

fn reportDupKey(ctx: ParseContext, builder: *DocBuilder, offset: usize) error{ Backtrack, Cut } {
    builder.duplicate_key_detected = true;
    ctx.reportEx(.{
        .message = diagMessage(.duplicate_key),
        .code = diagCode(.duplicate_key),
        .span = .{ .offset = offset, .length = 1 },
    });
    ctx.cut();
    return error.Cut;
}

// ── Key-value entry ──────────────────────────────────────────────────────

fn parseKeyValue(ctx: ParseContext, builder: *DocBuilder) anyerror!void {
    const alloc = builder.alloc;
    const s = ctx.stream();
    const start = s.cursor();

    // Find end of first line
    var first_end = s.cursor();
    while (first_end < s.data().len and s.data()[first_end] != '\n') : (first_end += 1) {}
    var line_text = trimTrailingCR(s.data()[start..first_end]);
    const comment_idx = findCommentStart(line_text);
    const pre_comment = if (comment_idx) |ci| std.mem.trim(u8, line_text[0..ci], " \t") else line_text;
    const eq = findUnquotedEq(pre_comment) orelse {
        ctx.reportEx(.{
            .message = "expected `=` after key",
            .code = diagCode(.unexpected_token),
            .span = .{ .offset = start, .length = line_text.len },
        });
        ctx.cut();
        return error.Cut;
    };
    const key_raw = std.mem.trim(u8, pre_comment[0..eq], " \t");
    if (key_raw.len == 0) {
        ctx.reportEx(.{
            .message = "missing key before `=`",
            .code = diagCode(.unexpected_token),
            .span = .{ .offset = start, .length = line_text.len },
        });
        ctx.cut();
        return error.Cut;
    }

    const trailing_trivia = if (comment_idx) |ci| blk: {
        var trailing: usize = ci;
        while (trailing < line_text.len and line_text[trailing] == ' ') : (trailing += 1) {}
        break :blk doc.Trivia{
            .kind = .comment,
            .text = try alloc.dupe(u8, line_text[trailing..]),
            .span = .{ .offset = start + trailing, .length = line_text.len - trailing },
        };
    } else null;
    // Reject control characters in comments (TOML spec: comments may not contain control chars)
    if (comment_idx) |ci| {
        var cc: usize = ci;
        while (cc < line_text.len) : (cc += 1) {
            if (isControlChar(line_text[cc]) and line_text[cc] != '\t') {
                ctx.reportEx(.{
                    .message = "control character in comment",
                    .code = diagCode(.invalid_escape),
                    .span = .{ .offset = start + cc, .length = 1 },
                });
                ctx.cut();
                return error.Cut;
            }
        }
    }

    // Collect value text (possibly multi-line)
    var value_buf: std.ArrayList(u8) = .empty;
    {
        const value_raw = std.mem.trim(u8, pre_comment[eq + 1 ..], " \t");
        try value_buf.appendSlice(alloc, value_raw);
    }
    s.setCursor(first_end);
    while (true) {
        if (valueComplete(value_buf.items)) break;
        if (first_end >= s.data().len) break;
        _ = s.nextByte();
        const ls = s.cursor();
        var le = ls;
        while (le < s.data().len and s.data()[le] != '\n') : (le += 1) {}
        try value_buf.append(alloc, '\n');
        try value_buf.appendSlice(alloc, s.data()[ls..le]);
        s.setCursor(le);
        first_end = le;
    }
    // Advance cursor to end of line, then consume newline
    s.setCursor(first_end);
    consumeNewline(s);

    // Parse the value using combinator-based parser
    const value_text = value_buf.items;
    const val = parseValueCombinator(alloc, start, value_text) catch |e| {
        value_buf.deinit(alloc);
        return e;
    };
    value_buf.deinit(alloc);

    // Parse the key path using combinator parser
    const key_path = try parseDottedKeyFromSlice(alloc, key_raw);
    const full_key = try scopedKey(builder.currentTablePath(), key_path, alloc);
    const split = splitKeyPath(full_key);
    const dotted = isDottedKey(key_path);

    // Conflict detection
    const rep = isRepeatedArrayValue(builder, full_key);
    if (!rep and (pathConflictWithKeys(full_key, &builder.seen) or
        pathConflictsAsSibling(full_key, builder.currentTablePath(), &builder.tables) or
        pathConflictsWithArrayTables(full_key, &builder.array_tables)))
    {
        doc.Document.deinitScalar(alloc, @constCast(&val));
        alloc.free(key_path);
        alloc.free(full_key);
        return reportDupKey(ctx, builder, start);
    }
    if (!rep) {
        const seen_key = if (builder.active_array_index > 0)
            try std.fmt.allocPrint(alloc, "{d}@{s}", .{ builder.active_array_index, full_key })
        else
            full_key;
        defer if (builder.active_array_index > 0) alloc.free(seen_key);
        try builder.seen.put(seen_key, {});
        try markDottedImplicit(alloc, &builder.dotted_implicit, &builder.temp_allocs, builder.currentTablePath(), key_path);
    }

    // Track temp allocations for cleanup; entry.path gets its own copy
    try builder.temp_allocs.append(alloc, key_path);
    try builder.temp_allocs.append(alloc, full_key);

    try builder.appendEntry(.{
        .kind = .key_value,
        .path = try alloc.dupe(u8, split.parent),
        .table_index = if (builder.table_is_array) builder.active_array_index else 0,
        .parent_array_index = if (builder.table_is_array) builder.parent_array_index else 0,
        .dotted = dotted,
        .key = try materializeKey(alloc, split.leaf),
        .key_span = .{ .offset = start, .length = split.leaf.len },
        .value = val,
        .leading = try builder.takePendingTrivia(),
        .trailing = if (trailing_trivia) |t| try alloc.dupe(doc.Trivia, &.{t}) else &.{},
    });
}

fn isRepeatedArrayValue(d: *const DocBuilder, full_key: []const u8) bool {
    const rep1 = d.table_is_array and std.mem.startsWith(u8, full_key, d.currentTablePath()) and full_key.len > d.currentTablePath().len;
    const rep2 = if (!rep1 and d.table_is_array and d.active_array_path.len > 0 and !std.mem.eql(u8, d.currentTablePath(), d.active_array_path))
        std.mem.startsWith(u8, full_key, d.active_array_path) and full_key.len > d.active_array_path.len
    else
        false;
    return rep1 or rep2;
}

// ── Value parser (combinator-based) ──────────────────────────────────────

/// Parse a value from captured text. Used for both single-line and
/// multi-line values. Dispatches to the appropriate combinator parser.
fn parseValueCombinator(alloc: std.mem.Allocator, offset: usize, raw: []const u8) anyerror!doc.Scalar {
    if (raw.len == 0) return error.InvalidToml;
    const kind = parseValueKind(raw);

    // Validate based on kind
    if (kind == .bare) return error.InvalidToml;
    if (kind == .integer and (!isValidIntegerToken(raw) or isInvalidInteger(raw))) return error.InvalidToml;
    if (kind == .float and !isSpecialFloat(raw) and (!isValidFloatToken(raw) or isInvalidFloat(raw))) return error.InvalidToml;
    if ((kind == .datetime or kind == .datetime_local or kind == .date_local or kind == .time_local) and isInvalidDatetime(raw)) return error.InvalidToml;

    // Validate and decode strings using combinator parser
    if (kind == .string) {
        var ds = Str.init(raw);
        var vctx = DiagnosticContext.init(alloc, ds.interface());
        defer vctx.deinit();
        const result = string_parser.parseNext(vctx.asContext());
        if (result == error.Backtrack or result == error.Cut) return error.InvalidToml;
        // Reject if extra content follows a single-line string
        const is_multiline = raw.len >= 3 and ((raw[0] == '"' and raw[1] == '"' and raw[2] == '"') or (raw[0] == '\'' and raw[1] == '\'' and raw[2] == '\''));
        if (!is_multiline and ds.remaining().len > 0) return error.InvalidToml;
    }

    // Store raw canonical form. Strings keep their quotes so
    // writeScalarJson can decode them during JSON output.
    const stored_raw = try canonicalScalarRaw(alloc, kind, raw);
    var val = doc.Scalar{
        .kind = kind,
        .raw = stored_raw,
        .span = .{ .offset = offset, .length = raw.len },
    };

    if (kind == .array) {
        if (raw.len < 2 or raw[raw.len - 1] != ']') return error.InvalidToml;
        val.children = try parseArrayChildren(alloc, offset, raw);
    } else if (kind == .inline_table) {
        if (raw.len < 2 or raw[raw.len - 1] != '}') return error.InvalidToml;
        val.children = try parseInlineTableChildren(alloc, offset, raw);
    }
    return val;
}

fn parseArrayChildren(alloc: std.mem.Allocator, offset: usize, raw: []const u8) anyerror![]doc.Scalar {
    const inner = raw[1 .. raw.len - 1];
    var list: std.ArrayList(doc.Scalar) = .empty;
    errdefer {
        for (list.items) |c| {
            alloc.free(c.raw);
            if (c.children.len > 0) alloc.free(c.children);
        }
        list.deinit(alloc);
    }
    var pos: usize = 0;
    while (pos < inner.len) {
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t' or inner[pos] == '\n' or inner[pos] == '\r')) : (pos += 1) {}
        if (pos >= inner.len) break;
        const start = pos;
        const end = findValueEnd(inner, pos);
        if (end == pos) return error.InvalidToml;
        const text = std.mem.trim(u8, inner[start..end], " \t\r\n");
        try list.append(alloc, try parseValueCombinator(alloc, offset + 1 + start, text));
        pos = end;
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t' or inner[pos] == '\n' or inner[pos] == '\r')) : (pos += 1) {}
        if (pos < inner.len and inner[pos] == ',') pos += 1;
    }
    return list.toOwnedSlice(alloc);
}

fn parseInlineTableChildren(alloc: std.mem.Allocator, offset: usize, raw: []const u8) anyerror![]doc.Scalar {
    const inner = raw[1 .. raw.len - 1];
    var list: std.ArrayList(doc.Scalar) = .empty;
    errdefer {
        for (list.items) |c| {
            alloc.free(c.raw);
            if (c.key) |k| alloc.free(k);
            for (c.children) |*child| {
                doc.Document.deinitScalar(alloc, child);
            }
            if (c.children.len > 0) alloc.free(c.children);
        }
        list.deinit(alloc);
    }
    var pos: usize = 0;
    var seen_keys = std.StringHashMap(void).init(alloc);
    defer {
        var kit = seen_keys.iterator();
        while (kit.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        seen_keys.deinit();
    }
    while (pos < inner.len) {
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t' or inner[pos] == '\n' or inner[pos] == '\r')) : (pos += 1) {}
        if (pos >= inner.len) break;
        const key_start = pos;
        const key_end = findInlineKeyEnd(inner, pos);
        if (key_end == pos) return error.InvalidToml;
        const key_text = inner[key_start..key_end];
        pos = key_end;
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t' or inner[pos] == '\n' or inner[pos] == '\r')) : (pos += 1) {}
        if (pos >= inner.len or inner[pos] != '=') return error.InvalidToml;
        pos += 1;
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t' or inner[pos] == '\n' or inner[pos] == '\r')) : (pos += 1) {}
        const val_start = pos;
        const val_end = findValueEnd(inner, pos);
        if (val_end == pos) return error.InvalidToml;
        const val_text = std.mem.trim(u8, inner[val_start..val_end], " \t");
        var val = try parseValueCombinator(alloc, offset + 1 + val_start, val_text);
        const key = try parseDottedKeyFromSlice(alloc, key_text);
        var kit = seen_keys.iterator();
        while (kit.next()) |entry| {
            if (pathSegmentsConflict(key, entry.key_ptr.*)) return error.InvalidToml;
        }
        try seen_keys.put(key, {});
        const split = splitKeyPath(key);
        val.key = try materializeKey(alloc, split.leaf);
        try list.append(alloc, val);
        pos = val_end;
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t' or inner[pos] == '\n' or inner[pos] == '\r')) : (pos += 1) {}
        if (pos < inner.len and inner[pos] == ',') pos += 1;
    }
    return list.toOwnedSlice(alloc);
}

// ── Value kind classification ────────────────────────────────────────────

fn parseValueKind(raw: []const u8) doc.ScalarKind {
    if (raw.len == 0) return .bare;
    if (std.mem.eql(u8, raw, "inf") or std.mem.eql(u8, raw, "+inf") or std.mem.eql(u8, raw, "-inf") or std.mem.eql(u8, raw, "nan") or std.mem.eql(u8, raw, "+nan") or std.mem.eql(u8, raw, "-nan")) return .float;
    return switch (raw[0]) {
        '"' => .string,
        '\'' => .string,
        '[' => .array,
        '{' => .inline_table,
        else => blk: {
            if ((std.ascii.isDigit(raw[0]) or raw[0] == '+' or raw[0] == '-' or raw[0] == '.') and isFloat(raw)) break :blk .float;
            if (isDatetimeCandidate(raw)) break :blk classifyDatetime(raw);
            if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "false")) break :blk .boolean;
            if (std.ascii.isDigit(raw[0]) or ((raw[0] == '+' or raw[0] == '-') and raw.len > 1 and std.ascii.isDigit(raw[1]))) break :blk .integer;
            break :blk .bare;
        },
    };
}

fn isSpecialFloat(raw: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(raw, "inf") or
        std.ascii.startsWithIgnoreCase(raw, "+inf") or
        std.ascii.startsWithIgnoreCase(raw, "-inf") or
        std.ascii.startsWithIgnoreCase(raw, "nan") or
        std.ascii.startsWithIgnoreCase(raw, "+nan") or
        std.ascii.startsWithIgnoreCase(raw, "-nan");
}

fn isDatetimeCandidate(raw: []const u8) bool {
    return raw.len > 0 and std.ascii.isDigit(raw[0]) and (std.mem.indexOfScalar(u8, raw, ':') != null or std.mem.indexOfScalar(u8, raw, '-') != null);
}

fn classifyDatetime(raw: []const u8) doc.ScalarKind {
    if (std.mem.indexOfAny(u8, raw, "Zz") != null) return .datetime;
    if (std.mem.indexOfAny(u8, raw, "Tt")) |t| {
        if (std.mem.indexOfAny(u8, raw[t + 1 ..], "+-") != null) return .datetime;
        return .datetime_local;
    }
    if (std.mem.indexOfScalar(u8, raw, ' ')) |s| {
        if (std.mem.indexOfAny(u8, raw[s + 1 ..], "+-") != null) return .datetime;
        return .datetime_local;
    }
    if (std.mem.indexOfScalar(u8, raw, ':') != null and std.mem.indexOfScalar(u8, raw, '-') == null) return .time_local;
    if (std.mem.indexOfScalar(u8, raw, '-') != null and std.mem.indexOfScalar(u8, raw, ':') == null) return .date_local;
    if (std.mem.indexOfScalar(u8, raw, ':') != null and std.mem.indexOfScalar(u8, raw, '-') != null) return .datetime_local;
    return .datetime;
}

fn isFloat(raw: []const u8) bool {
    var start: usize = 0;
    if (raw.len > 0 and (raw[0] == '+' or raw[0] == '-')) start = 1;
    if (raw.len > start + 1 and raw[start] == '0' and (raw[start + 1] == 'x' or raw[start + 1] == 'o' or raw[start + 1] == 'b')) return false;
    for (raw) |c| switch (c) {
        ':', 'T', 't', 'Z', 'z', ' ' => return false,
        else => {},
    };
    return std.mem.indexOfAny(u8, raw, ".eE") != null;
}

// ── Validation (copied from old parser, pure functions) ──────────────────

fn isValidIntegerToken(raw: []const u8) bool {
    if (raw.len == 0) return false;
    var i: usize = 0;
    const had_sign = raw[0] == '+' or raw[0] == '-';
    if (had_sign) i = 1;
    if (i >= raw.len) return false;
    if (raw[i] == '0' and i + 1 < raw.len) {
        const next = raw[i + 1];
        if (next == 'x' or next == 'o' or next == 'b') {
            if (had_sign) return false;
            i += 2;
            if (i >= raw.len) return false;
            var saw_digit = false;
            while (i < raw.len) : (i += 1) {
                const c = raw[i];
                if (c == '_') { if (!saw_digit) return false; }
                else if (next == 'x') { if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f') and !(c >= 'A' and c <= 'F')) return false; saw_digit = true; }
                else if (next == 'o') { if (c < '0' or c > '7') return false; saw_digit = true; }
                else if (next == 'b') { if (c != '0' and c != '1') return false; saw_digit = true; }
            }
            return saw_digit;
        }
        return false;
    }
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (!std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

fn isValidFloatToken(raw: []const u8) bool {
    if (raw.len == 0) return false;
    var i: usize = 0;
    if (raw[0] == '+' or raw[0] == '-') i = 1;
    if (i >= raw.len) return false;
    var saw_digit = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (std.ascii.isDigit(c)) { saw_digit = true; continue; }
        switch (c) { '_', '.', 'e', 'E', '+', '-' => {}, else => return false }
    }
    return saw_digit;
}

fn isInvalidInteger(raw: []const u8) bool {
    if (raw.len == 0) return true;
    var i: usize = 0;
    if (raw[0] == '+' or raw[0] == '-') i = 1;
    if (i >= raw.len) return true;
    if (raw[i] == '0' and i + 1 < raw.len) {
        const prefix = raw[i + 1];
        if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
            i += 2;
            if (i >= raw.len) return true;
            var saw_digit = false;
            var prev_us = false;
            while (i < raw.len) : (i += 1) {
                const c = raw[i];
                if (c == '_') { if (prev_us or !saw_digit) return true; if (i + 1 >= raw.len) return true; prev_us = true; continue; }
                prev_us = false;
                saw_digit = true;
                if (prefix == 'x') { if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f') and !(c >= 'A' and c <= 'F')) return true; }
                else if (prefix == 'o') { if (c < '0' or c > '7') return true; }
                else if (prefix == 'b') { if (c != '0' and c != '1') return true; }
            }
            return !saw_digit or prev_us;
        }
        return true;
    }
    var saw_digit = false;
    var prev_us = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        switch (c) {
            '0'...'9' => { saw_digit = true; prev_us = false; },
            '_' => { if (prev_us or !saw_digit or i + 1 >= raw.len or !std.ascii.isDigit(raw[i + 1])) return true; prev_us = true; },
            else => return true,
        }
    }
    return !saw_digit or prev_us;
}

fn isInvalidFloat(raw: []const u8) bool {
    if (isSpecialFloat(raw)) return false;
    if (!isFloat(raw)) return false;
    var i: usize = 0;
    if (raw[0] == '+' or raw[0] == '-') i = 1;
    if (i >= raw.len or raw[i] == '.' or raw[i] == '_') return true;
    if (i + 1 < raw.len and raw[i] == '0' and std.ascii.isDigit(raw[i + 1])) return true;
    var saw_digit = false;
    var saw_dot = false;
    var saw_exp = false;
    var prev_underscore = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        switch (c) {
            '0'...'9' => { saw_digit = true; prev_underscore = false; },
            '_' => {
                if (prev_underscore or !saw_digit or i + 1 >= raw.len) return true;
                if (!std.ascii.isDigit(raw[i + 1])) return true;
                prev_underscore = true;
            },
            '.' => {
                if (saw_dot or saw_exp or !saw_digit or i + 1 >= raw.len or !std.ascii.isDigit(raw[i + 1])) return true;
                saw_dot = true; prev_underscore = false;
            },
            'e', 'E' => {
                if (saw_exp or !saw_digit or i + 1 >= raw.len) return true;
                saw_exp = true; prev_underscore = false;
                i += 1;
                if (raw[i] == '+' or raw[i] == '-') { if (i + 1 >= raw.len) return true; i += 1; }
                if (!std.ascii.isDigit(raw[i])) return true;
                prev_underscore = false;
                while (i + 1 < raw.len and (std.ascii.isDigit(raw[i + 1]) or raw[i + 1] == '_')) : (i += 1) {
                    if (raw[i + 1] == '_' and (i + 2 >= raw.len or !std.ascii.isDigit(raw[i + 2]))) return true;
                }
            },
            else => return true,
        }
    }
    if (!saw_digit) return true;
    if (prev_underscore) return true;
    return false;
}

fn isInvalidDatePart(raw: []const u8) bool {
    var parts = std.mem.splitScalar(u8, raw, '-');
    const y = parts.next() orelse return true;
    const m = parts.next() orelse return true;
    const d = parts.next() orelse return true;
    if (parts.next() != null) return true;
    if (y.len != 4 or m.len != 2 or d.len != 2) return true;
    const month = std.fmt.parseInt(u8, m, 10) catch return true;
    const day = std.fmt.parseInt(u8, d, 10) catch return true;
    if (month < 1 or month > 12) return true;
    const max_day: u8 = switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => blk: {
            const year = std.fmt.parseInt(i32, y, 10) catch return true;
            const leap = @mod(year, 400) == 0 or (@mod(year, 4) == 0 and @mod(year, 100) != 0);
            break :blk if (leap) 29 else 28;
        },
        else => return true,
    };
    if (day < 1 or day > max_day) return true;
    return false;
}

fn isInvalidTimePart(raw: []const u8) bool {
    var time = if (std.mem.indexOfScalar(u8, raw, 'T')) |idx| raw[idx + 1 ..] else raw;
    if (time.len > 0 and (time[time.len - 1] == 'Z' or time[time.len - 1] == 'z')) {
        time = time[0 .. time.len - 1];
    } else if (std.mem.lastIndexOfAny(u8, time, "+-")) |tz| {
        if (tz > 0 and std.mem.indexOfScalar(u8, time[tz..], ':') != null) {
            const off = time[tz + 1 ..];
            var off_parts = std.mem.splitScalar(u8, off, ':');
            const oh = off_parts.next() orelse return true;
            const om = off_parts.next() orelse return true;
            if (off_parts.next() != null) return true;
            if (oh.len != 2 or om.len != 2) return true;
            if ((std.fmt.parseInt(u8, oh, 10) catch return true) > 23) return true;
            if ((std.fmt.parseInt(u8, om, 10) catch return true) > 59) return true;
            time = time[0..tz];
        }
    }
    var parts = std.mem.splitScalar(u8, time, ':');
    const h = parts.next() orelse return true;
    const min = parts.next() orelse return true;
    const sec = parts.next();
    if (parts.next() != null) return true;
    if (sec == null) return true; // TOML requires seconds
    if (h.len != 2 or min.len != 2) return true;
    const hour = std.fmt.parseInt(u8, h, 10) catch return true;
    const minute = std.fmt.parseInt(u8, min, 10) catch return true;
    if (hour > 23 or minute > 59) return true;
    if (sec) |s| {
        if (s.len < 2) return true;
        const second = std.fmt.parseInt(u8, s[0..2], 10) catch return true;
        if (second > 60) return true;
        if (s.len > 2) {
            if (s[2] != '.' or s.len == 3) return true;
            for (s[3..]) |c| if (!std.ascii.isDigit(c)) return true;
        }
    }
    return false;
}

fn isInvalidDatetime(raw: []const u8) bool {
    if (raw.len == 0) return true;
    if (std.mem.indexOfScalar(u8, raw, ' ') != null) {
        const s_idx = std.mem.indexOfScalar(u8, raw, ' ') orelse return true;
        if (s_idx == 0) return true;
        if (isInvalidDatePart(raw[0..s_idx])) return true;
        const rest = raw[s_idx + 1 ..];
        if (rest.len == 0) return true;
        if (rest[rest.len - 1] == 'Z' or rest[rest.len - 1] == 'z') {
            if (rest.len < 2) return true;
            return isInvalidTimePart(rest[0 .. rest.len - 1]);
        }
        return isInvalidTimePart(rest);
    }
    if (std.mem.indexOfAny(u8, raw, "Tt") != null or std.mem.indexOfAny(u8, raw, "Zz") != null) {
        const t = std.mem.indexOfAny(u8, raw, "Tt") orelse return true;
        if (t == 0) return true;
        if (isInvalidDatePart(raw[0..t])) return true;
        return isInvalidTimePart(raw[t + 1 ..]);
    }
    if (std.mem.indexOfScalar(u8, raw, ':') != null and std.mem.indexOfScalar(u8, raw, '-') == null) {
        return isInvalidTimePart(raw);
    }
    if (std.mem.indexOfScalar(u8, raw, '-') != null and std.mem.indexOfScalar(u8, raw, ':') == null) {
        return isInvalidDatePart(raw);
    }
    if (std.mem.indexOfScalar(u8, raw, ':') != null and std.mem.indexOfScalar(u8, raw, '-') != null) {
        return isInvalidDatePart(raw) or isInvalidTimePart(raw);
    }
    return true;
}

fn canonicalScalarRaw(alloc: std.mem.Allocator, kind: doc.ScalarKind, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    return switch (kind) {
        .float => if (raw.len > 0 and raw[0] == '+') try alloc.dupe(u8, raw[1..]) else try alloc.dupe(u8, raw),
        .datetime => blk: {
            var out = try alloc.dupe(u8, raw);
            for (out) |*c| c.* = switch (c.*) { 't', ' ' => 'T', 'z' => 'Z', else => c.* };
            if (std.mem.indexOfScalar(u8, out, 'T')) |t| {
                if (std.mem.indexOfScalar(u8, out[t + 1 ..], ':')) |m| {
                    const after_min = t + 1 + m + 1;
                    const tail = out[after_min..];
                    var tz: ?usize = null;
                    for (tail, 0..) |c, i| {
                        if (c == 'Z') { tz = i; break; }
                        if (i > 0 and (c == '+' or c == '-')) { tz = i; break; }
                    }
                    const sec_end = if (tz) |z| after_min + z else out.len;
                    if (std.mem.indexOfScalar(u8, out[after_min..sec_end], ':') == null) {
                        var buf = try alloc.alloc(u8, out.len + 3);
                        @memcpy(buf[0..sec_end], out[0..sec_end]);
                        buf[sec_end] = ':';
                        buf[sec_end + 1] = '0';
                        buf[sec_end + 2] = '0';
                        @memcpy(buf[sec_end + 3 ..], out[sec_end..]);
                        alloc.free(out);
                        out = buf;
                    }
                }
            } else if (std.mem.indexOfScalar(u8, out, ':') != null) {
                if (std.mem.indexOfScalar(u8, out, ':') == std.mem.lastIndexOfScalar(u8, out, ':')) {
                    var buf = try alloc.alloc(u8, out.len + 3);
                    @memcpy(buf[0..out.len], out);
                    @memcpy(buf[out.len..], ":00");
                    alloc.free(out);
                    out = buf;
                }
            }
            break :blk out;
        },
        .datetime_local, .time_local => blk: {
            var out = try alloc.dupe(u8, raw);
            if (kind == .time_local) {
                if (std.mem.indexOfScalar(u8, out, ':')) |m| {
                    if (std.mem.indexOfScalar(u8, out[m + 1 ..], ':') == null) {
                        var buf = try alloc.alloc(u8, out.len + 3);
                        @memcpy(buf[0..out.len], out);
                        @memcpy(buf[out.len..], ":00");
                        alloc.free(out);
                        out = buf;
                    }
                }
            } else if (std.mem.indexOfAny(u8, out, "Tt ") != null) {
                if (std.mem.indexOfScalar(u8, out, 'T')) |t| {
                    if (std.mem.indexOfScalar(u8, out[t + 1 ..], ':')) |m| {
                        if (std.mem.indexOfScalar(u8, out[t + 1 + m + 1 ..], ':') == null) {
                            var buf = try alloc.alloc(u8, out.len + 3);
                            @memcpy(buf[0..out.len], out);
                            @memcpy(buf[out.len..], ":00");
                            alloc.free(out);
                            out = buf;
                        }
                    }
                } else if (std.mem.indexOfScalar(u8, out, ':')) |m| {
                    if (std.mem.indexOfScalar(u8, out[m + 1 ..], ':') == null) {
                        var buf = try alloc.alloc(u8, out.len + 3);
                        @memcpy(buf[0..out.len], out);
                        @memcpy(buf[out.len..], ":00");
                        alloc.free(out);
                        out = buf;
                    }
                }
            }
            break :blk out;
        },
        .integer => blk: {
            const neg = raw.len > 0 and raw[0] == '-';
            const body = if (raw[0] == '+' or raw[0] == '-') raw[1..] else raw;
            if (body.len > 0 and body[0] == '0') {
                if (body.len == 1) break :blk try alloc.dupe(u8, "0");
                const prefix = body[1];
                if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(alloc);
                    var j: usize = 2;
                    while (j < body.len) : (j += 1) { if (body[j] != '_') try buf.append(alloc, body[j]); }
                    const base: u8 = if (prefix == 'x') 16 else if (prefix == 'o') 8 else 2;
                    const value_u = std.fmt.parseInt(u64, buf.items, base) catch return error.OutOfMemory;
                    break :blk try std.fmt.allocPrint(alloc, "{s}{}", .{ if (neg) "-" else "", value_u });
                }
                var all_zero = true;
                for (body) |c| { if (c != '0' and c != '_') all_zero = false; }
                if (all_zero) break :blk try alloc.dupe(u8, "0");
            }
            break :blk try alloc.dupe(u8, if (neg) raw else body);
        },
        else => try alloc.dupe(u8, raw),
    };
}

// ── Key path utilities ───────────────────────────────────────────────────

pub fn materializeKey(allocator: std.mem.Allocator, leaf: []const u8) ![]const u8 {
    if (std.mem.eql(u8, leaf, "\x01")) return try allocator.dupe(u8, "");
    if (std.mem.indexOf(u8, leaf, "\\") != null) {
        // Count exact output size first
        var exact_len: usize = 0;
        var ci: usize = 0;
        while (ci < leaf.len) {
            if (leaf[ci] == '\\' and ci + 1 < leaf.len) { exact_len += 1; ci += 2; }
            else { exact_len += 1; ci += 1; }
        }
        var out = try allocator.alloc(u8, exact_len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < leaf.len) {
            if (leaf[i] == '\\' and i + 1 < leaf.len) { out[j] = leaf[i + 1]; j += 1; i += 2; }
            else { out[j] = leaf[i]; j += 1; i += 1; }
        }
        return out;
    }
    return try allocator.dupe(u8, leaf);
}

pub fn escapeKey(gpa: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error![]const u8 {
    if (key.len == 0) return try gpa.dupe(u8, "\x01");
    var needs_escape = false;
    for (key) |c| if (c == '.' or c == '\\') { needs_escape = true; break; };
    if (!needs_escape) return try gpa.dupe(u8, key);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (key) |c| switch (c) {
        '.' => try buf.appendSlice(gpa, "\\."),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        else => try buf.append(gpa, c),
    };
    return try buf.toOwnedSlice(gpa);
}

pub const path_sep: u8 = '\x02';

fn splitKeyPath(path: []const u8) struct { parent: []const u8, leaf: []const u8 } {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.' and (i == 0 or path[i - 1] != '\\'))
            return .{ .parent = path[0..i], .leaf = path[i + 1 ..] };
    }
    return .{ .parent = "", .leaf = path };
}

fn scopedKey(table_path: []const u8, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (table_path.len == 0) return try allocator.dupe(u8, key);
    var buf = try allocator.alloc(u8, table_path.len + 1 + key.len);
    @memcpy(buf[0..table_path.len], table_path);
    buf[table_path.len] = '.';
    @memcpy(buf[table_path.len + 1 ..], key);
    return buf;
}

fn isDottedKey(key: []const u8) bool {
    var i: usize = 0;
    while (i < key.len) : (i += 1) {
        if (key[i] == '\\' and i + 1 < key.len) { i += 1; continue; }
        if (key[i] == '.') return true;
    }
    return false;
}

fn parseDottedKeyPath(ctx: ParseContext, alloc: std.mem.Allocator) (std.mem.Allocator.Error || error{ Backtrack, Cut })![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    {
        const first = try simple_key.parseNext(ctx);
        try parts.append(alloc, try decodeKeyComponent(alloc, first));
    }
    while (true) {
        const s = ctx.stream();
        if (s.peekByte(0) != @as(?u8, '.')) break;
        _ = s.nextByte();
        const next = try simple_key.parseNext(ctx);
        try parts.append(alloc, try decodeKeyComponent(alloc, next));
    }
    // Ensure the entire input was consumed (validates bare key has no trailing junk)
    // Allow trailing whitespace (space/tab) which may exist in dotted keys like "count . b"
    {
        const s = ctx.stream();
        const remaining = s.remaining();
        var i: usize = 0;
        while (i < remaining.len and (remaining[i] == ' ' or remaining[i] == '\t')) i += 1;
        if (i < remaining.len) return error.Backtrack;
    }
    // Build materialized path: join with `.`, escape `.` and `\` in components.
    var total: usize = 0;
    for (parts.items, 0..) |p, i| {
        if (i > 0) total += 1;
        if (p.len == 0) {
            total += 1; // '\x01' marker for empty component
        } else {
            for (p) |c| {
                if (c == '.' or c == '\\') total += 2 else total += 1;
            }
        }
    }
    var out = try alloc.alloc(u8, total);
    var pos: usize = 0;
    for (parts.items, 0..) |p, i| {
        if (i > 0) { out[pos] = '.'; pos += 1; }
        if (p.len == 0) {
            out[pos] = '\x01';
            pos += 1;
        } else {
            for (p) |c| {
                if (c == '.' or c == '\\') {
                    out[pos] = '\\';
                    pos += 1;
                }
                out[pos] = c;
                pos += 1;
            }
        }
    }
    // Free temporary component allocations (parts items are heap-allocated dupes)
    for (parts.items) |p| alloc.free(p);
    return out;
}

/// Decode a key component from the combinator parser output.
/// For bare keys: returns as-is (or `\x01` if empty).
/// For quoted keys: strips quotes and decodes escape sequences.
fn decodeKeyComponent(alloc: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    if (raw.len == 0) return try alloc.dupe(u8, "\x01");
    // Quoted key (basic or literal string)
    if (raw[0] == '"') {
        return doc.decodeTomlString(raw) catch return error.OutOfMemory;
    }
    if (raw[0] == '\'') {
        // Literal string: just strip the quotes
        if (raw.len < 2) return try alloc.dupe(u8, "");
        return try alloc.dupe(u8, raw[1 .. raw.len - 1]);
    }
    // Bare key: return as-is
    return try alloc.dupe(u8, raw);
}

fn parseDottedKeyFromSlice(alloc: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    var ds = Str.init(raw);
    var diag_ctx = DiagnosticContext.init(alloc, ds.interface());
    defer diag_ctx.deinit();
    return parseDottedKeyPath(diag_ctx.asContext(), alloc) catch return error.OutOfMemory;
}

// ── Conflict tracking ────────────────────────────────────────────────────

fn pathSegmentsConflict(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.startsWith(u8, a, b)) {
        if (a.len > b.len and a[b.len] == '.' and (b.len == 0 or a[b.len - 1] != '\\')) return true;
        return false;
    }
    if (std.mem.startsWith(u8, b, a)) {
        if (b.len > a.len and b[a.len] == '.' and (a.len == 0 or b[a.len - 1] != '\\')) return true;
        return false;
    }
    return false;
}

fn pathConflictWithKeys(path: []const u8, seen: *const std.StringHashMap(void)) bool {
    var it = seen.iterator();
    while (it.next()) |entry| { if (pathSegmentsConflict(path, entry.key_ptr.*)) return true; }
    return false;
}

fn pathHasValuePrefix(path: []const u8, seen: *const std.StringHashMap(void)) bool {
    if (seen.contains(path)) return true;
    var i: usize = 0;
    while (i < path.len) : (i += 1) { if (path[i] == '.' and seen.contains(path[0..i])) return true; }
    return false;
}

fn pathHasSubKey(path: []const u8, seen: *const std.StringHashMap(void)) bool {
    var it = seen.iterator();
    while (it.next()) |entry| {
        const other = entry.key_ptr.*;
        if (other.len > path.len and std.mem.startsWith(u8, other, path) and other[path.len] == '.') return true;
    }
    return false;
}

fn markHeaderImplicit(header_implicit: *std.StringHashMap(void), path: []const u8) !void {
    var i: usize = 0;
    while (i < path.len) : (i += 1) { if (path[i] == '.') try header_implicit.put(path[0..i], {}); }
}

fn markDottedImplicit(alloc: std.mem.Allocator, dotted_implicit: *std.StringHashMap(void), temp_allocs: *std.ArrayList([]const u8), current_path: []const u8, key_path: []const u8) !void {
    if (key_path.len == 0) return;
    var buf = try alloc.alloc(u8, current_path.len + 1 + key_path.len);
    defer alloc.free(buf);
    @memcpy(buf[0..current_path.len], current_path);
    var path_len = current_path.len;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= key_path.len) : (i += 1) {
        if (i < key_path.len and key_path[i] != '.') continue;
        if (i != key_path.len) {
            buf[path_len] = '.';
            path_len += 1;
            @memcpy(buf[path_len..][0..(i - start)], key_path[start..i]);
            path_len += i - start;
            const key = try alloc.dupe(u8, buf[0..path_len]);
            try temp_allocs.append(alloc, key);
            try dotted_implicit.put(key, {});
        }
        start = i + 1;
    }
}

fn isArrayChild(d: *const DocBuilder, path: []const u8) bool {
    if (!d.table_is_array) return false;
    const cur = d.currentTablePath();
    if (std.mem.startsWith(u8, path, cur) and path.len > cur.len) return true;
    if (d.active_array_path.len > 0 and !std.mem.eql(u8, cur, d.active_array_path))
        if (std.mem.startsWith(u8, path, d.active_array_path) and path.len > d.active_array_path.len) return true;
    return false;
}

fn arrayParentIdx(d: *const DocBuilder, path: []const u8) usize {
    const cur = d.currentTablePath();
    if (std.mem.eql(u8, path, cur)) return d.parent_array_index;
    if (std.mem.startsWith(u8, path, cur) and path.len > cur.len) return d.active_array_index;
    if (d.active_array_path.len > 0 and !std.mem.eql(u8, cur, d.active_array_path)) {
        if (std.mem.eql(u8, path, d.active_array_path)) return d.parent_array_index;
        if (std.mem.startsWith(u8, path, d.active_array_path) and path.len > d.active_array_path.len) return d.active_array_index;
    }
    return 0;
}

fn pathConflictsAsSibling(path: []const u8, table_path: []const u8, m: *const std.StringHashMap(void)) bool {
    var it = m.iterator();
    while (it.next()) |entry| {
        const other = entry.key_ptr.*;
        if (std.mem.eql(u8, other, table_path)) continue;
        if (table_path.len > other.len and std.mem.startsWith(u8, table_path, other) and table_path[other.len] == '.') continue;
        if (pathSegmentsConflict(path, other)) return true;
    }
    return false;
}

fn pathConflictsWithArrayTables(path: []const u8, m: *const std.StringHashMap(void)) bool {
    var it = m.iterator();
    while (it.next()) |entry| { if (pathSegmentsConflict(path, entry.key_ptr.*)) return true; }
    return false;
}

fn anyArrayTableAncestorConflict(path: []const u8, m: *const std.StringHashMap(void)) bool {
    var it = m.iterator();
    while (it.next()) |entry| {
        const other = entry.key_ptr.*;
        if (std.mem.startsWith(u8, path, other) and path.len > other.len and path[other.len] == '.') return true;
        if (std.mem.startsWith(u8, other, path) and other.len > path.len and other[path.len] == '.') return true;
    }
    return false;
}

fn arrayTableDescendantConflict(path: []const u8, m: *const std.StringHashMap(void)) bool {
    var it = m.iterator();
    while (it.next()) |entry| {
        const other = entry.key_ptr.*;
        if (std.mem.startsWith(u8, path, other) and path.len > other.len and path[other.len] == '.') return true;
    }
    return false;
}

// ── Helpers ──────────────────────────────────────────────────────────────

fn trimTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn hasControlChars(raw: []const u8) bool {
    for (raw) |c| if (isControlChar(c)) return true;
    return false;
}

fn findCommentStart(line: []const u8) ?usize {
    var in_basic = false;
    var in_literal = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (!in_basic and !in_literal and c == '"') {
            if (i + 2 < line.len and line[i + 1] == '"' and line[i + 2] == '"') return null;
            in_basic = true; continue;
        }
        if (!in_basic and !in_literal and c == '\'') {
            if (i + 2 < line.len and line[i + 1] == '\'' and line[i + 2] == '\'') return null;
            in_literal = true; continue;
        }
        if (in_basic) {
            if (c == '\\' and i + 1 < line.len) { i += 1; continue; }
            if (c == '"') in_basic = false;
            continue;
        }
        if (in_literal) { if (c == '\'') in_literal = false; continue; }
        if (c == '#') return i;
    }
    return null;
}

fn findUnquotedEq(text: []const u8) ?usize {
    var in_basic = false;
    var in_literal = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => { if (in_basic) i += 1; },
            '"' => { if (!in_literal) in_basic = !in_basic; },
            '\'' => { if (!in_basic) in_literal = !in_literal; },
            '=' => if (!in_basic and !in_literal) return i,
            else => {},
        }
    }
    return null;
}

fn valueComplete(value_text: []const u8) bool {
    if (value_text.len == 0) return true;
    const first = value_text[0];
    if (first == '"') return stringComplete(value_text, '"');
    if (first == '\'') return stringComplete(value_text, '\'');
    if (first == '[') return containerComplete(value_text);
    if (first == '{') return containerComplete(value_text);
    return true;
}

fn stringComplete(value_text: []const u8, quote: u8) bool {
    const multiline = value_text.len >= 3 and value_text[0] == quote and value_text[1] == quote and value_text[2] == quote;
    if (!multiline) {
        var i: usize = 1;
        while (i < value_text.len) : (i += 1) {
            const c = value_text[i];
            if (c == quote) return true;
            if (c == '\n') return true;
            if (c == '\\' and quote == '"') i += 1;
        }
        return false;
    }
    if (value_text.len < 6) return false;
    var trailing_q: usize = 0;
    var j: usize = value_text.len;
    while (j > 0 and value_text[j - 1] == quote) : (j -= 1) trailing_q += 1;
    return trailing_q >= 3;
}

fn containerComplete(value_text: []const u8) bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < value_text.len) : (i += 1) {
        const c = value_text[i];
        switch (c) {
            '"' => {
                if (i + 2 < value_text.len and value_text[i + 1] == '"' and value_text[i + 2] == '"') {
                    var k: usize = i + 3;
                    while (k + 2 < value_text.len) : (k += 1) {
                        if (value_text[k] == '"' and value_text[k + 1] == '"' and value_text[k + 2] == '"') {
                            k += 3;
                            while (k < value_text.len and value_text[k] == '"') : (k += 1) {}
                            i = k - 1; break;
                        }
                    }
                } else {
                    // Scan to closing single quote
                    i += 1;
                    while (i < value_text.len) : (i += 1) {
                        if (value_text[i] == '"') break;
                        if (value_text[i] == '\\' and i + 1 < value_text.len) i += 1;
                    }
                }
            },
            '\'' => {
                if (i + 2 < value_text.len and value_text[i + 1] == '\'' and value_text[i + 2] == '\'') {
                    var k: usize = i + 3;
                    while (k + 2 < value_text.len) : (k += 1) {
                        if (value_text[k] == '\'' and value_text[k + 1] == '\'' and value_text[k + 2] == '\'') {
                            k += 3;
                            while (k < value_text.len and value_text[k] == '\'') : (k += 1) {}
                            i = k - 1; break;
                        }
                    }
                } else {
                    // Scan to closing single quote
                    i += 1;
                    while (i < value_text.len and value_text[i] != '\'') : (i += 1) {}
                }
            },
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) return true;
            },
            else => {},
        }
    }
    return false;
}


fn findValueEnd(text: []const u8, pos: usize) usize {
    var i: usize = pos;
    if (i >= text.len) return i;
    const c = text[i];
    if (c == '"' or c == '\'') {
        const quote = c;
        if (i + 2 < text.len and text[i + 1] == quote and text[i + 2] == quote) {
            i += 3;
            while (i + 2 < text.len) : (i += 1) {
                if (text[i] == quote and text[i + 1] == quote and text[i + 2] == quote) {
                    i += 3;
                    while (i < text.len and text[i] == quote) : (i += 1) {}
                    return i;
                }
            }
            return text.len;
        }
        i += 1;
        while (i < text.len and text[i] != quote) : (i += 1) {
            if (text[i] == '\\' and quote == '"' and i + 1 < text.len) i += 1;
        }
        if (i < text.len) i += 1;
        return i;
    }
    if (c == '[' or c == '{') {
        const open = c;
        const close: u8 = if (open == '[') ']' else '}';
        var depth: usize = 1;
        i += 1;
        while (i < text.len) {
            const ch = text[i];
            if (ch == open) {
                depth += 1;
            } else if (ch == close) {
                depth -= 1;
                if (depth == 0) return i + 1;
            } else if (ch == '"') {
                if (i + 2 < text.len and text[i + 1] == '"' and text[i + 2] == '"') {
                    // Multiline basic string
                    i += 3;
                    while (i + 2 < text.len) : (i += 1) {
                        if (text[i] == '"' and text[i + 1] == '"' and text[i + 2] == '"') {
                            i += 3;
                            while (i < text.len and text[i] == '"') : (i += 1) {}
                            break;
                        }
                    }
                } else {
                    // Single-line basic string: scan past content to closing quote
                    i += 1;
                    while (i < text.len and text[i] != '"') : (i += 1) {
                        if (text[i] == '\\' and i + 1 < text.len) i += 1;
                    }
                }
            } else if (ch == '\'') {
                if (i + 2 < text.len and text[i + 1] == '\'' and text[i + 2] == '\'') {
                    // Multiline literal string
                    i += 3;
                    while (i + 2 < text.len) : (i += 1) {
                        if (text[i] == '\'' and text[i + 1] == '\'' and text[i + 2] == '\'') {
                            i += 3;
                            while (i < text.len and text[i] == '\'') : (i += 1) {}
                            break;
                        }
                    }
                } else {
                    // Single-line literal string: scan past content to closing quote
                    i += 1;
                    while (i < text.len and text[i] != '\'') : (i += 1) {}
                }
            }
            i += 1;
        }
        return text.len;
    }
    while (i < text.len) {
        const ch = text[i];
        if (ch == ',' or ch == ']' or ch == '}' or ch == '#' or ch == '\n') return i;
        i += 1;
    }
    return i;
}

fn findInlineKeyEnd(text: []const u8, pos: usize) usize {
    var i: usize = pos;
    while (i < text.len) {
        switch (text[i]) {
            ' ', '\t', '=' => return i,
            '"' => { i += 1; while (i < text.len and text[i] != '"') : (i += 1) { if (text[i] == '\\' and i + 1 < text.len) i += 1; } if (i < text.len) i += 1; },
            '\'' => { i += 1; while (i < text.len and text[i] != '\'') : (i += 1) {} if (i < text.len) i += 1; },
            else => i += 1,
        }
    }
    return i;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "parse simple doc" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "name = \"kb\"\ncount = 1\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), d.entries.items.len);
}

test "parse tables and comments" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "# hi\n[db]\nport = 1 # comment\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), d.entries.items.len);
    try std.testing.expectEqualStrings("db", d.entries.items[0].path);
}

test "parse duplicate key fails" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.DuplicateKey, parse(gpa, "x.toml", "a = 1\na = 2\n", null));
}

test "parse array and inline table" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "arr = [1, 2]\nobj = { name = \"kb\" }\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(doc.ScalarKind, .array), d.entries.items[0].value.kind);
    try std.testing.expectEqual(@as(doc.ScalarKind, .inline_table), d.entries.items[1].value.kind);
}

test "parse dotted key" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "server.port = 8080\n", null);
    defer d.deinit(gpa);
    try std.testing.expect(d.entries.items[0].dotted);
}

test "parse multiline strings" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "desc = \"\"\"hello\nworld\"\"\"\n", null);
    defer d.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, d.entries.items[0].value.raw, "\"\"\""));
}

test "trivia before entry preserved" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "# hi\n\nname = \"kb\"\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), d.entries.items[0].leading.len);
}

test "literal string ok, invalid escape fails" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "note = 'ok'\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(doc.ScalarKind, .string), d.entries.items[0].value.kind);
    try std.testing.expectError(error.InvalidToml, parse(gpa, "x.toml", "bad = \"\\q\"\n", null));
}

test "unterminated string fails" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidToml, parse(gpa, "x.toml", "bad = \"abc\n", null));
}

test "parse datetime" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "ts = 1979-05-27T07:32:00Z\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(doc.ScalarKind, .datetime), d.entries.items[0].value.kind);
}

test "parse local date and time" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "d = 1979-05-27\nt = 07:32:00\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(doc.ScalarKind, .date_local), d.entries.items[0].value.kind);
    try std.testing.expectEqual(@as(doc.ScalarKind, .time_local), d.entries.items[1].value.kind);
}

test "invalid datetime fails" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidToml, parse(gpa, "x.toml", "ts = 1979-05-27T07:32\n", null));
    try std.testing.expectError(error.InvalidToml, parse(gpa, "x.toml", "d = 1979-5-27\n", null));
}

test "parse float" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "pi = 3.14\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(doc.ScalarKind, .float), d.entries.items[0].value.kind);
}

test "invalid float fails" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidToml, parse(gpa, "x.toml", "n = 1.\n", null));
}

test "bare values fail" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidToml, parse(gpa, "x.toml", "x = foo\n", null));
}

test "duplicate table header fails" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.DuplicateKey, parse(gpa, "x.toml", "[db]\nport = 1\n[db]\nname = \"x\"\n", null));
}

test "parse array of tables" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "[[products]]\nname = \"x\"\n[[products]]\nname = \"y\"\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), d.entries.items.len);
}

test "inline table children exist" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "obj = { name = \"kb\", active = true }\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), d.entries.items[0].value.children.len);
}

test "implicit array table parent conflict" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.DuplicateKey, parse(gpa, "x.toml", "[[albums.songs]]\nname = \"x\"\n[[albums]]\nname = \"y\"\n", null));
}

test "CRLF normalization" {
    const gpa = std.testing.allocator;
    var d = try parse(gpa, "x.toml", "a = 1\r\nb = 2\r\n", null);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), d.entries.items.len);
}
