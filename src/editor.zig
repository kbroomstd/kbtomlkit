const std = @import("std");
const doc = @import("document.zig");

pub fn appendString(document: *doc.Document, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try document.append(allocator, .{
        .key = key,
        .key_span = .{ .offset = 0, .length = key.len },
        .value = .{ .kind = .string, .raw = value, .span = .{ .offset = 0, .length = value.len } },
    });
}

pub fn replaceRaw(document: *doc.Document, idx: usize, raw: []const u8) void {
    document.replaceValue(idx, raw);
}

test "editor append and replace" {
    const gpa = std.testing.allocator;
    var d = try doc.Document.init(gpa, "x.toml", "a = 1\n");
    defer d.deinit(gpa);
    try appendString(&d, gpa, "name", "\"kb\"");
    replaceRaw(&d, 0, "2");
    const out = try d.render(gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a = 2\nname = \"kb\"", out);
}

test "editor handles array and inline table raw replace" {
    const gpa = std.testing.allocator;
    var d = try doc.Document.init(gpa, "x.toml", "arr = [1]\nobj = { name = \"kb\" }\n");
    defer d.deinit(gpa);
    replaceRaw(&d, 0, "[1, 2]");
    replaceRaw(&d, 1, "{ name = \"kb\", active = true }");
    const out = try d.render(gpa);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[1, 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "active = true") != null);
}
