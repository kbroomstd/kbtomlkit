const std = @import("std");
const kbdiagnostic = @import("kbdiagnostic");

pub const ParseErrorKind = enum {
    unexpected_token,
    duplicate_key,
    invalid_escape,
    invalid_number,
    invalid_datetime,
    unterminated_string,
};

pub const ParseDiagnostic = struct {
    kind: ParseErrorKind,
    text: []const u8,
    source: *const kbdiagnostic.SourceCode,
    span: kbdiagnostic.SourceSpan,
    help_text: ?[]const u8 = null,
    labels_buf: [1]kbdiagnostic.LabeledSpan,

    pub fn diagnostic(self: *const @This()) kbdiagnostic.Diagnostic {
        return kbdiagnostic.Diagnostic.implBy(self);
    }

    pub fn code(self: *const @This()) ?[]const u8 {
        return switch (self.kind) {
            .unexpected_token => "toml.parse.unexpected_token",
            .duplicate_key => "toml.parse.duplicate_key",
            .invalid_escape => "toml.parse.invalid_escape",
            .invalid_number => "toml.parse.invalid_number",
            .invalid_datetime => "toml.parse.invalid_datetime",
            .unterminated_string => "toml.parse.unterminated_string",
        };
    }

    pub fn severity(_: *const @This()) ?kbdiagnostic.Severity {
        return .Error;
    }

    pub fn help(self: *const @This()) ?[]const u8 {
        return self.help_text;
    }

    pub fn sourceCode(self: *const @This()) ?*const kbdiagnostic.SourceCode {
        return self.source;
    }

    pub fn labels(self: *const @This()) ?[]const kbdiagnostic.LabeledSpan {
        return self.labels_buf[0..];
    }

    pub fn message(self: *const @This()) []const u8 {
        return self.text;
    }
};

pub fn duplicateKey(source: *const kbdiagnostic.SourceCode, offset: usize, length: usize) ParseDiagnostic {
    return .{
        .kind = .duplicate_key,
        .text = "duplicate key",
        .source = source,
        .span = .{ .offset = offset, .length = length },
        .help_text = "keys must be unique within a table",
        .labels_buf = .{kbdiagnostic.LabeledSpan.newPrimary(null, offset, length)},
    };
}

pub fn invalidEscape(source: *const kbdiagnostic.SourceCode, offset: usize, length: usize) ParseDiagnostic {
    return .{
        .kind = .invalid_escape,
        .text = "invalid escape sequence",
        .source = source,
        .span = .{ .offset = offset, .length = length },
        .help_text = "use TOML 1.1 escape forms",
        .labels_buf = .{kbdiagnostic.LabeledSpan.newPrimary(null, offset, length)},
    };
}

pub fn unterminatedString(source: *const kbdiagnostic.SourceCode, offset: usize, length: usize) ParseDiagnostic {
    return .{
        .kind = .unterminated_string,
        .text = "unterminated string",
        .source = source,
        .span = .{ .offset = offset, .length = length },
        .help_text = "close string delimiters",
        .labels_buf = .{kbdiagnostic.LabeledSpan.newPrimary(null, offset, length)},
    };
}

pub fn invalidNumber(source: *const kbdiagnostic.SourceCode, offset: usize, length: usize) ParseDiagnostic {
    return .{
        .kind = .invalid_number,
        .text = "invalid number",
        .source = source,
        .span = .{ .offset = offset, .length = length },
        .help_text = "use canonical TOML numeric form",
        .labels_buf = .{kbdiagnostic.LabeledSpan.newPrimary(null, offset, length)},
    };
}

pub fn invalidDatetime(source: *const kbdiagnostic.SourceCode, offset: usize, length: usize) ParseDiagnostic {
    return .{
        .kind = .invalid_datetime,
        .text = "invalid datetime",
        .source = source,
        .span = .{ .offset = offset, .length = length },
        .help_text = "use TOML date, time, local datetime, or offset datetime forms",
        .labels_buf = .{kbdiagnostic.LabeledSpan.newPrimary(null, offset, length)},
    };
}

test "parse diagnostic renders graphical report" {
    const input = "key = \"\\q\"\n";
    const named = kbdiagnostic.NamedSource{ .name = "bad.toml", .data = input };
    const src = named.source();
    const d = invalidEscape(&src, 7, 2);
    const report = d.diagnostic();
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const handler = kbdiagnostic.GraphicalReportHandler{};
    try handler.base().display(std.testing.allocator, &writer, &report);
    try writer.flush();
    const out = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "toml.parse.invalid_escape") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "invalid escape sequence") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bad.toml") != null);
}

test "parse diagnostic code stable" {
    const input = "a = 1\n";
    const named = kbdiagnostic.NamedSource{ .name = "x.toml", .data = input };
    const src = named.source();
    const d = duplicateKey(&src, 0, 1);
    try std.testing.expectEqualStrings("toml.parse.duplicate_key", d.code().?);
}
