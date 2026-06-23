const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // [[ dependencies
    const kbwinnow_dep = b.dependency("kbwinnow", .{
        .target = target,
        .optimize = optimize,
    });
    const kbwinnow_mod = kbwinnow_dep.module("kbwinnow");

    const kbdiagnostic_dep = b.dependency("kbdiagnostic", .{
        .target = target,
        .optimize = optimize,
    });
    const kbdiagnostc_mod = kbdiagnostic_dep.module("kbdiagnostic");
    // end dependencies ]]

    const mod = b.addModule("kbtomlkit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "kbwinnow", .module = kbwinnow_mod },
            .{ .name = "kbdiagnostic", .module = kbdiagnostc_mod },
        },
    });

    const exe_tomltest_decoder = b.addExecutable(.{
        .name = "kbtomlkit-tomltest-decoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tomltest_decoder.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kbtomlkit", .module = mod },
            },
        }),
    });
    b.installArtifact(exe_tomltest_decoder);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    if (b.lazyDependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
    })) |ohsnap_dep| {
        mod_tests.root_module.addImport("ohsnap", ohsnap_dep.module("ohsnap"));
    }
}
