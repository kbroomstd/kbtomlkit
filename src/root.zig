const std = @import("std");

pub const diagnostics = @import("diagnostics.zig");
pub const document = @import("document.zig");
pub const parser = @import("parser.zig");
pub const mut = @import("mut.zig");
pub const toml_file = @import("toml_file.zig");

test "mut table add rejects duplicate with diagnostic" {
    const gpa = std.testing.allocator;
    var doc = try parser.parse(gpa, "x.toml", "k = 1\n", null);
    defer doc.deinit(gpa);
    var t = mut.Table.root(&doc);
    var d: mut.Diagnostic = undefined;
    const item = try mut.integer(gpa, @as(i64, 2));
    const result = t.add(gpa, "k", item, &d);
    if (result) |_| {} else |_| {
        gpa.free(item.integer.raw);
    }
    try std.testing.expectError(error.KeyAlreadyPresent, result);
    try std.testing.expectEqualStrings("kbtomlkit::key_already_present", d.code().?);
}

test "mut table remove raises non-existent with diagnostic" {
    const gpa = std.testing.allocator;
    var doc = try parser.parse(gpa, "x.toml", "k = 1\n", null);
    defer doc.deinit(gpa);
    var t = mut.Table.root(&doc);
    var d: mut.Diagnostic = undefined;
    const result = t.remove(gpa, "missing", &d);
    try std.testing.expectError(error.NonExistentKey, result);
    try std.testing.expectEqualStrings("kbtomlkit::non_existent_key", d.code().?);
}

test "mut table set replaces existing key" {
    const gpa = std.testing.allocator;
    var doc = try parser.parse(gpa, "x.toml", "host = \"127.0.0.1\"\n", null);
    defer doc.deinit(gpa);
    var t = mut.Table.root(&doc);
    try t.set(gpa, "host", try mut.string(gpa, "10.0.0.1"), null);
    try std.testing.expectEqualStrings("\"10.0.0.1\"", t.get("host").?.raw);
}

test "mut table count and iterator" {
    const gpa = std.testing.allocator;
    var doc = try parser.parse(gpa, "x.toml", "a = 1\nb = 2\nc = 3\n", null);
    defer doc.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), doc.entries.items.len);
    var t = mut.Table.root(&doc);
    try std.testing.expectEqual(@as(usize, 3), t.count());
    try std.testing.expect(t.contains("a"));
    try std.testing.expect(t.contains("b"));
    try std.testing.expect(t.contains("c"));
}

test "mut diagnostic vtable round-trip" {
    var d = mut.keyAlreadyPresent(null, .{ .offset = 5, .length = 3 });
    const diag = d.diagnostic();
    try std.testing.expectEqualStrings("kbtomlkit::key_already_present", diag.code().?);
    try std.testing.expectEqualStrings("key already present in this table", diag.message());
}

test "TomlFile round-trip" {
    const gpa = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var tf = try toml_file.TomlFile.init(gpa, "example.toml");
    defer tf.deinit(gpa);

    var doc = try parser.parse(gpa, "", "", null);
    defer doc.deinit(gpa);
    var root = mut.Table.root(&doc);
    try root.set(gpa, "owner", try mut.string(gpa, "John"), null);

    try tf.write(std.testing.io, tmp_dir.dir, "example.toml", gpa, &doc, null);

    var doc2 = try tf.read(std.testing.io, tmp_dir.dir, "example.toml", gpa, null);
    defer doc2.deinit(gpa);

    var root2 = mut.Table.root(&doc2);
    try std.testing.expect(root2.contains("owner"));
}
