//! Array view. Pointer to a `Scalar { kind = .array }` plus mutation
//! helpers. Follows the project's diagnostic pattern: every mutating
//! method takes `gpa` and an optional `diag` last parameter; populates
//! `diag.*` with a `MutationDiagnostic` on failure when non-null.
//!
//! **Conventions**:
//!
//! - The view borrows a `Scalar` of kind `.array`. Caller asserts
//!   `Scalar.kind == .array`.
//! - `children` is reallocated as items are added/removed.
//! - After any mutation, `scalar.raw` is regenerated in place so the
//!   caller can `doc.render` and see the new content immediately.

const std = @import("std");
const doc_mod = @import("document.zig");
const kbdiagnostic = @import("kbdiagnostic");
const mut = @import("mut.zig");

pub const Error = mut.Error;

const Allocator = std.mem.Allocator;

/// View over an inline array scalar. Borrows from a `Document`.
/// All mutating methods take `gpa` and an optional `?*mut.Diagnostic`
/// as the trailing parameter (defaults to `null`).
pub const Array = struct {
    const Self = @This();

    /// Backing scalar. Caller's responsibility: `Scalar.kind == .array`.
    scalar: *doc_mod.Scalar,

    pub const Iterator = struct {
        array: *const Array,
        index: usize = 0,

        pub fn next(self: *Iterator) ?mut.Item {
            if (self.index >= self.array.scalar.children.len) return null;
            defer self.index += 1;
            return doc_mod.scalarToItem(self.array.scalar.children[self.index]);
        }
    };

    // --- Read API -------------------------------------------------------

    /// Number of children.
    pub fn count(self: *const Self) usize {
        return self.scalar.children.len;
    }

    /// Iterate. Read-only.
    pub fn iterator(self: *const Self) Iterator {
        return .{ .array = self };
    }

    /// Borrow raw children. Read-only.
    pub fn unwrap(self: *const Self) []const doc_mod.Scalar {
        return self.scalar.children;
    }

    // --- Write API (all take gpa + optional diag) --------------------

    /// Append `item`. Raises `Error.TypeMismatch` for body-level tags.
    pub fn append(
        self: *Self,
        gpa: Allocator,
        item: mut.Item,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        switch (item) {
            .tableHeader, .aot, .comment, .whitespace, .nullMarker => {
                if (diag) |d| {
                    d.* = mut.typeMismatch(
                        null,
                        self.scalar.span,
                        "scalar, nested array, or inline table",
                    ).diagnostic();
                }
                return Error.TypeMismatch;
            },
            else => {},
        }
        const old = self.scalar.children;
        var new_ptr: []doc_mod.Scalar = gpa.alloc(doc_mod.Scalar, old.len + 1) catch {
            if (diag) |d| d.* = oomDiagnostic(self.scalar.span);
            return Error.OutOfMemory;
        };
        std.mem.copyForwards(doc_mod.Scalar, new_ptr[0..old.len], old);
        new_ptr[old.len] = doc_mod.itemToScalar(item) catch return Error.OutOfMemory;
        if (old.len > 0) gpa.free(old);
        self.scalar.children = new_ptr;
        doc_mod.regenRawInPlace(gpa, self.scalar);
    }

    pub fn extend(
        self: *Self,
        gpa: Allocator,
        items: []const mut.Item,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        for (items) |it| try self.append(gpa, it, diag);
    }

    pub fn insert(
        self: *Self,
        gpa: Allocator,
        index: usize,
        item: mut.Item,
        diag: ?*mut.Diagnostic,
    ) Error!void {
        if (index > self.scalar.children.len) {
            if (diag) |d| {
                d.* = mut.typeMismatch(
                    null,
                    self.scalar.span,
                    "array index within bounds",
                ).diagnostic();
            }
            return Error.TypeMismatch;
        }
        switch (item) {
            .tableHeader, .aot, .comment, .whitespace, .nullMarker => {
                if (diag) |d| {
                    d.* = mut.typeMismatch(
                        null,
                        self.scalar.span,
                        "scalar, nested array, or inline table",
                    ).diagnostic();
                }
                return Error.TypeMismatch;
            },
            else => {},
        }
        const old = self.scalar.children;
        var new_ptr: []doc_mod.Scalar = gpa.alloc(doc_mod.Scalar, old.len + 1) catch {
            if (diag) |d| d.* = oomDiagnostic(self.scalar.span);
            return Error.OutOfMemory;
        };
        std.mem.copyForwards(doc_mod.Scalar, new_ptr[0..index], old[0..index]);
        new_ptr[index] = doc_mod.itemToScalar(item) catch return Error.OutOfMemory;
        std.mem.copyForwards(doc_mod.Scalar, new_ptr[index + 1 ..], old[index..]);
        if (old.len > 0) gpa.free(old);
        self.scalar.children = new_ptr;
        doc_mod.regenRawInPlace(gpa, self.scalar);
    }

    pub fn pop(
        self: *Self,
        gpa: Allocator,
        diag: ?*mut.Diagnostic,
    ) Error!?mut.Item {
        if (self.scalar.children.len == 0) return null;
        const old = self.scalar.children;
        const last = old[old.len - 1];
        if (old.len == 1) {
            gpa.free(old);
            self.scalar.children = &.{};
        } else {
            const new_ptr: []doc_mod.Scalar = gpa.alloc(doc_mod.Scalar, old.len - 1) catch {
                if (diag) |d| d.* = oomDiagnostic(self.scalar.span);
                return Error.OutOfMemory;
            };
            std.mem.copyForwards(doc_mod.Scalar, new_ptr, old[0 .. old.len - 1]);
            gpa.free(old);
            self.scalar.children = new_ptr;
        }
        doc_mod.regenRawInPlace(gpa, self.scalar);
        return doc_mod.scalarToItem(last);
    }

    pub fn remove(
        self: *Self,
        gpa: Allocator,
        index: usize,
        diag: ?*mut.Diagnostic,
    ) Error!mut.Item {
        if (index >= self.scalar.children.len) {
            if (diag) |d| {
                d.* = mut.typeMismatch(
                    null,
                    self.scalar.span,
                    "array index within bounds",
                ).diagnostic();
            }
            return Error.TypeMismatch;
        }
        const old = self.scalar.children;
        const removed = old[index];
        if (old.len == 1) {
            gpa.free(old);
            self.scalar.children = &.{};
        } else {
            const new_ptr: []doc_mod.Scalar = gpa.alloc(doc_mod.Scalar, old.len - 1) catch {
                if (diag) |d| d.* = oomDiagnostic(self.scalar.span);
                return Error.OutOfMemory;
            };
            std.mem.copyForwards(doc_mod.Scalar, new_ptr[0..index], old[0..index]);
            std.mem.copyForwards(doc_mod.Scalar, new_ptr[index..], old[index + 1 ..]);
            gpa.free(old);
            self.scalar.children = new_ptr;
        }
        doc_mod.regenRawInPlace(gpa, self.scalar);
        return doc_mod.scalarToItem(removed);
    }

    /// Remove all items. Frees the children slice.
    /// Remove all items. Frees the children slice and their allocations.
    pub fn clear(self: *Self, gpa: Allocator) void {
        if (self.scalar.children.len > 0) {
            for (self.scalar.children) |*child| {
                doc_mod.Document.deinitScalar(gpa, child);
            }
            gpa.free(self.scalar.children);
            self.scalar.children = &.{};
            doc_mod.regenRawInPlace(gpa, self.scalar);
        }
    }
};

fn oomDiagnostic(span: kbdiagnostic.SourceSpan) kbdiagnostic.Diagnostic {
    var d: mut.MutationDiagnostic = .{
        .kind = .out_of_memory,
        .message_text = "out of memory growing array",
        .code_str = "kbtomlkit::out_of_memory",
        .help_text = null,
        .source = null,
        .span = span,
        .labels_buf = .{kbdiagnostic.LabeledSpan.newPrimary(null, span.offset, span.length)},
    };
    return d.diagnostic();
}


fn findArrayScalar(doc: *doc_mod.Document) *doc_mod.Scalar {
    return &doc.entries.items[0].value;
}
// --- Tests ------------------------------------------------------------------

test "array append grows" {
    const gpa = std.testing.allocator;
    var doc = try doc_mod.makeDoc(gpa, "ports = []\n");
    defer doc.deinit(gpa);
    var arr = Array{ .scalar = findArrayScalar(&doc) };
    try std.testing.expectEqual(@as(usize, 0), arr.count());
    try arr.append(gpa, try mut.integer(gpa, @as(i64, 80)), null);
    try arr.append(gpa, try mut.integer(gpa, @as(i64, 443)), null);
    try std.testing.expectEqual(@as(usize, 2), arr.count());
}

test "array append regenerates raw" {
    const gpa = std.testing.allocator;
    var doc = try doc_mod.makeDoc(gpa, "ports = []\n");
    defer doc.deinit(gpa);
    var arr = Array{ .scalar = findArrayScalar(&doc) };
    try arr.append(gpa, try mut.integer(gpa, @as(i64, 80)), null);
    try arr.append(gpa, try mut.integer(gpa, @as(i64, 443)), null);
    try std.testing.expect(std.mem.indexOf(u8, doc.entries.items[0].value.raw, "80") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.entries.items[0].value.raw, "443") != null);
}

test "array append rejects comment with diagnostic" {
    const gpa = std.testing.allocator;
    var doc = try doc_mod.makeDoc(gpa, "ports = []\n");
    defer doc.deinit(gpa);
    var arr = Array{ .scalar = findArrayScalar(&doc) };

    const c1 = try mut.comment(gpa, "# bad");
    defer gpa.free(c1.comment);
    try std.testing.expectError(error.TypeMismatch, arr.append(gpa, c1, null));

    var d: mut.Diagnostic = undefined;
    const c2 = try mut.comment(gpa, "# bad");
    defer gpa.free(c2.comment);
    _ = arr.append(gpa, c2, &d) catch {};
    try std.testing.expectEqualStrings("kbtomlkit::type_mismatch", d.code().?);
    try std.testing.expect(d.severity() != null);
}

test "array insert and remove" {
    const gpa = std.testing.allocator;
    var doc = try doc_mod.makeDoc(gpa, "ports = [80, 443]\n");
    defer doc.deinit(gpa);
    var arr = Array{ .scalar = findArrayScalar(&doc) };

    const num_item = try mut.integer(gpa, @as(i64, 8080));
    try arr.insert(gpa, 1, num_item, null);
    try std.testing.expectEqual(@as(usize, 3), arr.count());

    const removed = try arr.remove(gpa, 1, null);
    defer gpa.free(removed.integer.raw);
    try std.testing.expectEqualStrings("8080", removed.integer.raw);
    try std.testing.expectEqual(@as(usize, 2), arr.count());

    const popped = try arr.pop(gpa, null);
    try std.testing.expect(popped != null);
    defer gpa.free(popped.?.integer.raw);
    try std.testing.expectEqualStrings("443", popped.?.integer.raw);
}

test "array clear empties" {
    const gpa = std.testing.allocator;
    var doc = try doc_mod.makeDoc(gpa, "ports = [80, 443]\n");
    defer doc.deinit(gpa);
    var arr = Array{ .scalar = findArrayScalar(&doc) };
    try std.testing.expectEqual(@as(usize, 2), arr.count());
    arr.clear(gpa);
    try std.testing.expectEqual(@as(usize, 0), arr.count());
}

test "array iterator yields items" {
    const gpa = std.testing.allocator;
    var doc = try doc_mod.makeDoc(gpa, "ports = [80, 443]\n");
    defer doc.deinit(gpa);
    var arr = Array{ .scalar = findArrayScalar(&doc) };

    var it = arr.iterator();
    const first = it.next().?;
    try std.testing.expectEqualStrings("80", first.integer.raw);
    const second = it.next().?;
    try std.testing.expectEqualStrings("443", second.integer.raw);
    try std.testing.expect(it.next() == null);
}

test "array extend appends all" {
    const gpa = std.testing.allocator;
    var doc = try doc_mod.makeDoc(gpa, "ports = [80]\n");
    defer doc.deinit(gpa);
    var arr = Array{ .scalar = findArrayScalar(&doc) };

    var items: [2]mut.Item = .{
        try mut.integer(gpa, @as(i64, 443)),
        try mut.integer(gpa, @as(i64, 8080)),
    };
    try arr.extend(gpa, &items, null);
    try std.testing.expectEqual(@as(usize, 3), arr.count());
}
