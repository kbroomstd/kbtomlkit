//! Mutation/writing API. Mirrors python-poetry/tomlkit's `Container`,
//! `Item`, `Aot`, `Array`, `Table`, `InlineTable` surface in Zig idioms
//! (no operator overloading; explicit method names; `Aot` not `AoT`).
//!
//! Follows the project's diagnostic pattern: every mutating function
//! takes `gpa: std.mem.Allocator` followed by `diag: ?*mut.Diagnostic`
//! and returns `(Allocator.Error || mut.Error)!T`. On failure with
//! non-null `diag`, the function fills `diag.*` with a `MutationDiagnostic`
//! that implements the `kbdiag.Diagnostic` vtable. The `null` default
//! makes diagnostics opt-in.
//!
//! Example:
//!
//! ```zig
//! var d: mut.Diagnostic = undefined;
//! view.set(gpa, "k", item, &d) catch |err| {
//!     const handler = kbdiag.GraphicalReportHandler{};
//!     var w = std.fs.File.stderr().writer(&.{});
//!     try handler.display(std.heap.page_allocator, &w, &d);
//!     return err;
//! };
//! ```
//!

const std = @import("std");
const doc_mod = @import("document.zig");
const parser_mod = @import("parser.zig");
const kbdiag = @import("kbwinnow").kbdiagnostic;
const Allocator = std.mem.Allocator;

// --- Re-exports -------------------------------------------------------------

/// Re-exported document types.
pub const Document = doc_mod.Document;
pub const Entry = doc_mod.Entry;
pub const Scalar = doc_mod.Scalar;
pub const ScalarKind = doc_mod.ScalarKind;
pub const Trivia = doc_mod.Trivia;
pub const TriviaKind = doc_mod.TriviaKind;

/// Re-exported escape helpers. Promote-then-fork from `document.zig` and
/// `parser.zig` so callers can manipulate key paths without reaching
/// into the internals.
pub const escapeKey = parser_mod.escapeKey;
pub const materializeKey = parser_mod.materializeKey;
pub const unmaterializeSegment = doc_mod.unmaterializeSegment;
pub const materializeSegment = doc_mod.materializeSegment;

/// Re-exported prefix-tree helpers. These operate on the canonical
/// stored path form (escaped dots, literal `.` separator).
pub const pathPrefix = doc_mod.pathPrefix;
pub const childPrefix = doc_mod.childPrefix;
pub const childName = doc_mod.childName;
pub const countHeaders = doc_mod.countHeaders;
pub const indexOfUnescapedDot = doc_mod.indexOfUnescapedDot;
/// Re-export the `kbdiagnostic` vtable so callers don't need a second
/// import. `mut.Diagnostic` is the parameter type for every mutation
/// method; populate it via `MutationDiagnostic` (below).
pub const Diagnostic = kbdiag.Diagnostic;
pub const Severity = kbdiag.Severity;
pub const LabeledSpan = kbdiag.LabeledSpan;
pub const SourceSpan = kbdiag.SourceSpan;
pub const SourceCode = kbdiag.SourceCode;
pub const NamedSource = kbdiag.NamedSource;

/// Path separator between segments in stored `Document.entries[i].path`.
/// Mirrors the parser's actual encoding.
pub const path_sep = parser_mod.path_sep;

/// Canonical error set. Consolidates every error a mutating function can
/// produce. Allocator failures are merged in via the union
/// `Allocator.Error || mut.Error`; Zig deduplicates `OutOfMemory`.
pub const Error = error{
    KeyAlreadyPresent,
    NonExistentKey,
    KeyTypeError,
    TypeMismatch,
    InvalidPath,
    OutOfMemory,
};

/// Discriminates the kind of diagnostic emitted by mutation methods.
/// Mirrors the `ParseErrorKind` enum in `src/diagnostics.zig`.
pub const MutationErrorKind = enum {
    key_already_present,
    non_existent_key,
    key_type_error,
    type_mismatch,
    invalid_path,
    out_of_memory,
};

/// Diagnostic payload for mutation failures. Lives on the stack of the
/// failing function; lifetime ends with the return. Mirrors the
/// `ParseDiagnostic` shape in `src/diagnostics.zig` exactly:
///
/// - holds a borrowed `SourceCode` (or null when no source applies),
/// - holds a fixed-size labels buffer (mutation diagnostics are typically
///   single-span — one label is enough; the buffer is sized `[1]` so
///   extending later is a one-line change),
/// - exposes `code()`, `severity()`, `message()`, `sourceCode()`,
///   `labels()` per the `kbdiag.Diagnostic` vtable contract.
///
/// The `diagnostic(self)` method returns a `kbdiag.Diagnostic` vtable
/// view of `self` via `kbdiag.Diagnostic.implBy(self)`.
pub const MutationDiagnostic = struct {
    const Self = @This();

    kind: MutationErrorKind,
    message_text: []const u8,
    code_str: []const u8,
    help_text: ?[]const u8,
    source: ?*const kbdiag.SourceCode,
    span: kbdiag.SourceSpan,
    labels_buf: [1]kbdiag.LabeledSpan,

    /// Construct a `kbdiag.Diagnostic` vtable view of `self`.
    pub fn diagnostic(self: *const Self) kbdiag.Diagnostic {
        return kbdiag.Diagnostic.implBy(self);
    }

    // --- vtable methods (consumed by `kbdiag.Diagnostic.implBy`) ---

    pub fn code(self: *const Self) ?[]const u8 {
        return self.code_str;
    }

    pub fn severity(_: *const Self) ?kbdiag.Severity {
        return .Error;
    }

    pub fn help(self: *const Self) ?[]const u8 {
        return self.help_text;
    }

    pub fn message(self: *const Self) []const u8 {
        return self.message_text;
    }

    pub fn sourceCode(self: *const Self) ?*const kbdiag.SourceCode {
        return self.source;
    }

    pub fn labels(self: *const Self) ?[]const kbdiag.LabeledSpan {
        return self.labels_buf[0..];
    }
};

// --- Constructors for common MutationDiagnostic variants -------------------

/// Build a `MutationDiagnostic` for `Error.KeyAlreadyPresent`. The
/// caller fills `span`; this helper wires the static fields and
/// derives the label span from it.
pub fn keyAlreadyPresent(
    source: ?*const kbdiag.SourceCode,
    span: kbdiag.SourceSpan,
) MutationDiagnostic {
    return .{
        .kind = .key_already_present,
        .message_text = "key already present in this table",
        .code_str = "kbtomlkit::key_already_present",
        .help_text = "use set() to replace, or remove() first",
        .source = source,
        .span = span,
        .labels_buf = .{kbdiag.LabeledSpan.newPrimary("this key", span.offset, span.length)},
    };
}

/// Build a `MutationDiagnostic` for `Error.NonExistentKey`.
pub fn nonExistentKey(
    source: ?*const kbdiag.SourceCode,
    span: kbdiag.SourceSpan,
) MutationDiagnostic {
    return .{
        .kind = .non_existent_key,
        .message_text = "key not present in this table",
        .code_str = "kbtomlkit::non_existent_key",
        .help_text = "use contains() to test before remove()",
        .source = source,
        .span = span,
        .labels_buf = .{kbdiag.LabeledSpan.newPrimary("this key", span.offset, span.length)},
    };
}

/// Build a `MutationDiagnostic` for `Error.KeyTypeError`. The
/// `expected` and `actual` slices are concatenated into the help text.
pub fn keyTypeError(
    source: ?*const kbdiag.SourceCode,
    span: kbdiag.SourceSpan,
    expected: []const u8,
    actual: []const u8,
) MutationDiagnostic {
    var help_buf: [128]u8 = undefined;
    const help_text = std.fmt.bufPrint(
        &help_buf,
        "expected {s}, got {s}",
        .{ expected, actual },
    ) catch "expected one kind, got another";
    return .{
        .kind = .key_type_error,
        .message_text = "key has wrong kind for this view",
        .code_str = "kbtomlkit::key_type_error",
        .help_text = help_text,
        .source = source,
        .span = span,
        .labels_buf = .{kbdiag.LabeledSpan.newPrimary("this key", span.offset, span.length)},
    };
}

/// Build a `MutationDiagnostic` for `Error.TypeMismatch`.
pub fn typeMismatch(
    source: ?*const kbdiag.SourceCode,
    span: kbdiag.SourceSpan,
    expected_kind: []const u8,
) MutationDiagnostic {
    var help_buf: [128]u8 = undefined;
    const help_text = std.fmt.bufPrint(
        &help_buf,
        "expected {s}",
        .{expected_kind},
    ) catch "expected another kind";
    return .{
        .kind = .type_mismatch,
        .message_text = "operation does not apply to this kind",
        .code_str = "kbtomlkit::type_mismatch",
        .help_text = help_text,
        .source = source,
        .span = span,
        .labels_buf = .{kbdiag.LabeledSpan.newPrimary("this item", span.offset, span.length)},
    };
}

/// Build a `MutationDiagnostic` for `Error.InvalidPath`. `message` is
/// embedded directly (no allocation — caller owns the string).
pub fn invalidPath(message: []const u8) MutationDiagnostic {
    return .{
        .kind = .invalid_path,
        .message_text = message,
        .code_str = "kbtomlkit::invalid_path",
        .help_text = "the path produced an empty key after escape",
        .source = null,
        .span = .{ .offset = 0, .length = 0 },
        .labels_buf = .{kbdiag.LabeledSpan.newPrimary("this path", 0, 0)},
    };
}

// --- Item sum type ----------------------------------------------------------

/// Discriminates the kind of `Item`. Mirrors tomlkit's `Item` plus the
/// extra variants (`comment`, `whitespace`, `nullMarker`) the document
/// already carries as `Scalar` or `Trivia` payloads.
pub const ItemTag = enum {
    integer,
    float,
    bool,
    string,
    datetime,
    datetimeLocal,
    dateLocal,
    timeLocal,
    bare,
    array,
    inlineTable,
    tableHeader,
    aot,
    comment,
    whitespace,
    nullMarker,
};

/// Sum type for everything that can appear as a value in a `Table`,
/// `InlineTable`, or `Array`. Each variant carries the raw text the
/// renderer needs to reproduce byte-for-byte; concrete operations
/// (splitting a dotted key, iterating an array) live on the view
/// types (`Table`, `Array`, etc.) not on `Item`.
pub const Item = union(ItemTag) {
    integer: Scalar,
    float: Scalar,
    bool: Scalar,
    string: Scalar,
    datetime: Scalar,
    datetimeLocal: Scalar,
    dateLocal: Scalar,
    timeLocal: Scalar,
    bare: Scalar,
    array: Array,
    inlineTable: InlineTable,
    tableHeader: Table,
    aot: Aot,
    comment: []const u8,
    whitespace: []const u8,
    nullMarker: void,
};

// --- View forward declarations ---------------------------------------------

pub const Table = @import("mut_table.zig").Table;
pub const InlineTable = @import("mut_inline.zig").InlineTable;
pub const Array = @import("mut_array.zig").Array;
pub const Aot = @import("mut_aot.zig").Aot;

// --- Scalar factories ------------------------------------------------------

/// Build an `Item.integer` from a Zig integer. Caller owns `raw` for
/// the lifetime of the item; the storage is moved into the document
/// on `Table.set` and freed with `Document.deinit`.
pub fn integer(gpa: Allocator, value: anytype) Allocator.Error!Item {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info != .int and info != .comptime_int) return error.InvalidToml;
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
    return .{ .integer = .{
        .kind = .integer,
        .raw = try gpa.dupe(u8, text),
        .span = .{ .offset = 0, .length = text.len },
    } };
}

/// Build an `Item.float` from a Zig float. The text is rendered with
/// `{d}` (shortest round-trippable form) and stored as the raw text.
/// Caller owns `raw` for the lifetime of the item.
pub fn floatFromText(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    return .{ .float = .{
        .kind = .float,
        .raw = try gpa.dupe(u8, text),
        .span = .{ .offset = 0, .length = text.len },
    } };
}

/// Build an `Item.bool` from a Zig bool.
pub fn boolean(gpa: Allocator, value: bool) Allocator.Error!Item {
    const text: []const u8 = if (value) "true" else "false";
    return .{ .bool = .{
        .kind = .boolean,
        .raw = try gpa.dupe(u8, text),
        .span = .{ .offset = 0, .length = text.len },
    } };
}

/// Build an `Item.string` from an unquoted string. The text is wrapped
/// in basic double quotes; only the standard escapes (`"`, `\`, `\n`,
/// `\r`, `\t`) are applied — full TOML 1.1 escape rules land in Step 8.
pub fn string(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '"');
    for (text) |c| switch (c) {
        '"' => try buf.appendSlice(gpa, "\\\""),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '\n' => try buf.appendSlice(gpa, "\\n"),
        '\r' => try buf.appendSlice(gpa, "\\r"),
        '\t' => try buf.appendSlice(gpa, "\\t"),
        else => try buf.append(gpa, c),
    };
    try buf.append(gpa, '"');
    const raw = try buf.toOwnedSlice(gpa);
    return .{ .string = .{
        .kind = .string,
        .raw = raw,
        .span = .{ .offset = 0, .length = raw.len },
    } };
}

/// Build a `datetime` `Item` from its rendered form. The caller
/// supplies the canonical TOML text (e.g. `"1979-05-27T07:32:00Z"`).
pub fn datetime(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    return .{ .datetime = .{
        .kind = .datetime,
        .raw = try gpa.dupe(u8, text),
        .span = .{ .offset = 0, .length = text.len },
    } };
}

/// Build a local datetime `Item`.
pub fn datetimeLocal(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    return .{ .datetimeLocal = .{
        .kind = .datetime_local,
        .raw = try gpa.dupe(u8, text),
        .span = .{ .offset = 0, .length = text.len },
    } };
}

/// Build a local date `Item`.
pub fn dateLocal(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    return .{ .dateLocal = .{
        .kind = .date_local,
        .raw = try gpa.dupe(u8, text),
        .span = .{ .offset = 0, .length = text.len },
    } };
}

/// Build a local time `Item`.
pub fn timeLocal(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    return .{ .timeLocal = .{
        .kind = .time_local,
        .raw = try gpa.dupe(u8, text),
        .span = .{ .offset = 0, .length = text.len },
    } };
}

/// Build a bare (unquoted) string `Item`. Bare strings in TOML 1.1 are
/// restricted to a small character set; the caller asserts validity.
pub fn bare(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    return .{ .bare = .{
        .kind = .bare,
        .raw = try gpa.dupe(u8, text),
        .span = .{ .offset = 0, .length = text.len },
    } };
}

/// Build a `comment` trivia item.
pub fn comment(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    return .{ .comment = try gpa.dupe(u8, text) };
}

/// Build a `whitespace` trivia item.
pub fn whitespace(gpa: Allocator, text: []const u8) Allocator.Error!Item {
    return .{ .whitespace = try gpa.dupe(u8, text) };
}

/// Build a `nullMarker` item (TOML 1.1 null).
pub fn nullMarker() Item {
    return .{ .nullMarker = {} };
}

/// Parse a TOML string into a Document. Caller owns the Document and
/// must call `doc.deinit(gpa)` when done.
pub fn loads(gpa: Allocator, source: []const u8) parser_mod.ParseError!doc_mod.Document {
    return parser_mod.parse(gpa, "<inline>", source);
}

/// Render a Document to a TOML string. Caller frees with `gpa`.
pub fn dumps(doc: *const doc_mod.Document, gpa: Allocator) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    return doc.render(gpa);
}

/// Render the document to a TOML string. Equivalent to Python's
/// `Container.as_string`. Caller frees with `gpa`.
pub fn asString(doc: *doc_mod.Document, gpa: Allocator) Allocator.Error![]u8 {
    return doc.render(gpa);
}

/// Write the document's JSON representation into `out`. Equivalent to
/// Python's `repr(doc)`.
pub fn asJson(
    doc: *doc_mod.Document,
    gpa: Allocator,
    out: *std.ArrayList(u8),
) anyerror!void {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var s: std.json.Stringify = .{ .writer = &w.writer, .options = .{} };
    try doc.jsonStringify(&s);
    const slice = try w.toOwnedSlice();
    defer gpa.free(slice);
    try out.appendSlice(gpa, slice);
}

// --- Tests ------------------------------------------------------------------

test "stub" {
    try std.testing.expect(true);
}

test "mutationDiagnosticRoundTrip" {
    var d = keyAlreadyPresent(null, .{ .offset = 5, .length = 3 });
    const diag = d.diagnostic();
    try std.testing.expectEqualStrings("kbtomlkit::key_already_present", diag.code().?);
    try std.testing.expectEqualStrings("key already present in this table", diag.message());
    try std.testing.expectEqual(kbdiag.Severity.Error, diag.severity().?);
    try std.testing.expectEqualStrings("this key", diag.labels().?[0].label().?);
}

test "mutationDiagnosticNonExistent" {
    var d = nonExistentKey(null, .{ .offset = 1, .length = 4 });
    const diag = d.diagnostic();
    try std.testing.expectEqualStrings("kbtomlkit::non_existent_key", diag.code().?);
    try std.testing.expectEqualStrings("key not present in this table", diag.message());
    try std.testing.expect(diag.help() != null);
}

test "mutationDiagnosticInvalidPath" {
    var d = invalidPath("empty key segment");
    const diag = d.diagnostic();
    try std.testing.expectEqualStrings("kbtomlkit::invalid_path", diag.code().?);
    try std.testing.expectEqualStrings("empty key segment", diag.message());
}

test "mutationDiagnosticTypeMismatch" {
    var d = typeMismatch(null, .{ .offset = 0, .length = 0 }, "table");
    const diag = d.diagnostic();
    try std.testing.expectEqualStrings("kbtomlkit::type_mismatch", diag.code().?);
    try std.testing.expect(diag.help() != null);
}

test "escapeKey round-trip" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{ "plain", "", "with.dot", "with\\slash", "a.b\\c" };
    for (cases) |raw| {
        const escaped = try escapeKey(gpa, raw);
        defer gpa.free(escaped);
        const back = try materializeKey(gpa, escaped);
        defer gpa.free(back);
        try std.testing.expectEqualStrings(raw, back);
    }
}

test "scalar factories allocate and round-trip" {
    const gpa = std.testing.allocator;
    const i = try integer(gpa, @as(i64, 42));
    try std.testing.expectEqualStrings("42", i.integer.raw);
    const b = try boolean(gpa, true);
    try std.testing.expectEqualStrings("true", b.bool.raw);
    const s = try string(gpa, "hi\nthere");
    try std.testing.expect(std.mem.indexOf(u8, s.string.raw, "\\n") != null);
}

test "string factory escapes quotes and backslash" {
    const gpa = std.testing.allocator;
    const s = try string(gpa, "she said \"hi\"\\done");
    try std.testing.expect(std.mem.indexOf(u8, s.string.raw, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.string.raw, "\\\\") != null);
}
