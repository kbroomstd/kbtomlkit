const std = @import("std");
const kbtomlkit = @import("kbtomlkit");
const doc = kbtomlkit.document;

pub fn encodeDecoderOutput(allocator: std.mem.Allocator, document: *const doc.Document) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };
    try json.write(document.*);
    return try out.toOwnedSlice();
}

pub fn decodeInput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var document = try kbtomlkit.parser.parse(allocator, "stdin.toml", input);
    defer document.deinit(allocator);
    return try encodeDecoderOutput(allocator, &document);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stdin_buf: [4096]u8 = undefined;
    var input_buf: std.array_list.Aligned(u8, .of(u8)) = .empty;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buf);
    stdin_reader.interface.appendRemaining(allocator, &input_buf, .limited(1024 * 1024)) catch std.process.exit(1);
    const input = try input_buf.toOwnedSlice(allocator);
    defer allocator.free(input);

    const json = decodeInput(allocator, input) catch {
        std.process.exit(1);
    };
    defer allocator.free(json);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout_writer.interface.writeAll(json);
    try stdout_writer.interface.flush();
}

