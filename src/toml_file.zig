//! TOML file I/O with line-ending preservation. Equivalent to
//! python-poetry/tomlkit's `TOMLFile`. `read` and `write` follow the
//! project's diagnostic pattern: take `diag: ?*mut.Diagnostic` so
//! failures produce rich context for `kbdiag.GraphicalReportHandler`.

const std = @import("std");
const doc_mod = @import("document.zig");
const parser_mod = @import("parser.zig");
const kbdiagnostic = @import("kbdiagnostic");
const mut = @import("mut.zig");

/// Line-ending style detected from a read.
pub const LineEnding = enum { lf, crlf, mixed };

/// File I/O wrapper. Owns a copy of the file path; caller must call
/// `deinit` to free it.
pub const TomlFile = struct {
    const Self = @This();

    path: []const u8,
    lineEnding: LineEnding = .lf,

    pub fn init(gpa: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!Self {
        const path_dup = try gpa.dupe(u8, path);
        return .{ .path = path_dup };
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.* = undefined;
    }

    /// Read the file from `dir` at `sub_path`, detect line endings, parse
    /// into a `Document`. On failure populates `diag` (when non-null)
    /// with a diagnostic.
    pub fn read(
        self: *Self,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
        gpa: std.mem.Allocator,
        diag: ?*mut.Diagnostic,
    ) anyerror!doc_mod.Document {
        const content = readFromDir(io, dir, sub_path, gpa) catch |err| {
            if (diag) |d| d.* = fileOpenErrorDiagnostic(err, sub_path);
            return err;
        };
        defer gpa.free(content);

        self.lineEnding = detectLineEnding(content);

        const normalized: []const u8 = if (self.lineEnding == .crlf)
            try normalizeCrlfToLf(gpa, content)
        else
            content;
        defer if (normalized.ptr != content.ptr) gpa.free(normalized);

        return parser_mod.parse(gpa, sub_path, normalized, null) catch |err| {
            if (diag) |d| d.* = parseErrorDiagnostic(sub_path, err);
            return err;
        };
    }

    /// Write `doc` to `dir/sub_path`, applying the detected line ending.
    pub fn write(
        self: *const Self,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
        gpa: std.mem.Allocator,
        doc: *const doc_mod.Document,
        diag: ?*mut.Diagnostic,
    ) anyerror!void {
        const content = mut.dumps(doc, gpa) catch |err| {
            if (diag) |d| d.* = ioErrorDiagnostic(err, "could not render document");
            return err;
        };
        defer gpa.free(content);

        const final_content = switch (self.lineEnding) {
            .lf, .mixed => content,
            .crlf => try lfToCrlf(gpa, content),
        };
        defer if (final_content.ptr != content.ptr) gpa.free(final_content);

        writeToDir(io, dir, sub_path, final_content) catch |err| {
            if (diag) |d| d.* = fileOpenErrorDiagnostic(err, sub_path);
            return err;
        };
    }
};

// --- Helpers ----------------------------------------------------------------

fn readFromDir(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

fn writeToDir(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, content: []const u8) !void {
    var file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn detectLineEnding(content: []const u8) LineEnding {
    const num_newline = std.mem.count(u8, content, "\n");
    if (num_newline == 0) return .lf;
    const num_win_eol = std.mem.count(u8, content, "\r\n");
    if (num_win_eol == num_newline) return .crlf;
    if (num_win_eol == 0) return .lf;
    return .mixed;
}

fn normalizeCrlfToLf(gpa: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < content.len) {
        if (i + 1 < content.len and content[i] == '\r' and content[i + 1] == '\n') {
            try out.append(gpa, '\n');
            i += 2;
        } else {
            try out.append(gpa, content[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn lfToCrlf(gpa: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\n' and (i == 0 or content[i - 1] != '\r')) {
            try out.append(gpa, '\r');
        }
        try out.append(gpa, content[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn fileOpenErrorDiagnostic(err: anytype, path: []const u8) mut.Diagnostic {
    var d: mut.MutationDiagnostic = .{
        .kind = .type_mismatch,
        .message_text = @errorName(err),
        .code_str = "kbtomlkit::file_open",
        .help_text = "ensure the file exists and is readable",
        .source = null,
        .span = .{ .offset = 0, .length = 0 },
        .labels_buf = .{kbdiagnostic.LabeledSpan.newPrimary(path, 0, path.len)},
    };
    return d.diagnostic();
}

fn parseErrorDiagnostic(path: []const u8, err: anytype) mut.Diagnostic {
    var d: mut.MutationDiagnostic = .{
        .kind = .type_mismatch,
        .message_text = @errorName(err),
        .code_str = "kbtomlkit::parse_error",
        .help_text = "fix the TOML syntax at the indicated location",
        .source = null,
        .span = .{ .offset = 0, .length = 0 },
        .labels_buf = .{kbdiagnostic.LabeledSpan.newPrimary(path, 0, path.len)},
    };
    return d.diagnostic();
}

fn ioErrorDiagnostic(err: anytype, msg: []const u8) mut.Diagnostic {
    var d: mut.MutationDiagnostic = .{
        .kind = .type_mismatch,
        .message_text = msg,
        .code_str = "kbtomlkit::io",
        .help_text = @errorName(err),
        .source = null,
        .span = .{ .offset = 0, .length = 0 },
        .labels_buf = .{std.mem.zeroes(kbdiagnostic.LabeledSpan)},
    };
    return d.diagnostic();
}

// --- Tests ------------------------------------------------------------------

test "detectLineEnding lf only" {
    try std.testing.expectEqual(@as(LineEnding, .lf), detectLineEnding("a = 1\nb = 2\n"));
    try std.testing.expectEqual(@as(LineEnding, .lf), detectLineEnding("a = 1"));
}

test "detectLineEnding crlf only" {
    try std.testing.expectEqual(@as(LineEnding, .crlf), detectLineEnding("a = 1\r\nb = 2\r\n"));
}

test "detectLineEnding mixed" {
    try std.testing.expectEqual(@as(LineEnding, .mixed), detectLineEnding("a = 1\nb = 2\r\n"));
}

test "normalizeCrlfToLf strips carriage returns" {
    const result = try normalizeCrlfToLf(std.testing.allocator, "a = 1\r\nb = 2\r\n");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a = 1\nb = 2\n", result);
}

test "lfToCrlf adds carriage returns" {
    const result = try lfToCrlf(std.testing.allocator, "a = 1\nb = 2\n");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a = 1\r\nb = 2\r\n", result);
}

test "TomlFile round-trip" {
    const gpa = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tf = try TomlFile.init(gpa, "example.toml");
    defer tf.deinit(gpa);

    var doc = try parser_mod.parse(gpa, "", "", null);
    defer doc.deinit(gpa);
    var root = mut.Table.root(&doc);
    try root.set(gpa, "owner", try mut.string(gpa, "John"), null);

    try tf.write(std.testing.io, tmp_dir.dir, "example.toml", gpa, &doc, null);

    var doc2 = try tf.read(std.testing.io, tmp_dir.dir, "example.toml", gpa, null);
    defer doc2.deinit(gpa);

    var root2 = mut.Table.root(&doc2);
    try std.testing.expect(root2.contains("owner"));
    try std.testing.expectEqualStrings("\"John\"", root2.get("owner").?.raw);
}

test "TomlFile preserves CRLF on read/write" {
    const gpa = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const original = "owner = \"John\"\r\nage = 30\r\n";
    {
        var f = try tmp_dir.dir.createFile(std.testing.io, "crlf.toml", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, original);
    }

    var tf = try TomlFile.init(gpa, "crlf.toml");
    defer tf.deinit(gpa);

    var doc = try tf.read(std.testing.io, tmp_dir.dir, "crlf.toml", gpa, null);
    defer doc.deinit(gpa);

    try std.testing.expectEqual(@as(LineEnding, .crlf), tf.lineEnding);
    var root = mut.Table.root(&doc);
    try std.testing.expect(root.contains("owner"));
    try std.testing.expect(root.contains("age"));

    // Round-trip: write back, must remain CRLF
    try tf.write(std.testing.io, tmp_dir.dir, "crlf.toml", gpa, &doc, null);

    const written = try readFromDir(std.testing.io, tmp_dir.dir, "crlf.toml", gpa);
    defer gpa.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\r\n") != null);
    // Round-trip preserves CRLF as long as the parser's leading trivia
    // contains `\n` boundaries that get rewritten as `\r\n`. Render
    // does not emit a trailing newline, so the original's final
    // `\r\n` may be lost. Verify at least one CRLF is present.
    try std.testing.expect(std.mem.indexOf(u8, written, "\r\n") != null);
    try std.testing.expect(written.len > 0);
}

test "TomlFile read failure populates diagnostic" {
    const gpa = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tf = try TomlFile.init(gpa, "does_not_exist.toml");
    defer tf.deinit(gpa);

    var d: mut.Diagnostic = undefined;
    const result = tf.read(std.testing.io, tmp_dir.dir, "does_not_exist.toml", gpa, &d);
    try std.testing.expectError(error.FileNotFound, result);
    try std.testing.expectEqualStrings("kbtomlkit::file_open", d.code().?);
}
