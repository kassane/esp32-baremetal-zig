const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const esp32 = buildEsp32(b, .{
        .target = target,
        .optimize = optimize,
    });
    const esp32s3 = buildEsp32S3(b, .{
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(esp32);
    b.installArtifact(esp32s3);
}

fn buildEsp32(b: *std.Build, opt: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
}) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "esp32_baremetal_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("esp32/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });
    exe.entry = .disabled;
    exe.setLinkerScript(b.path("esp32/xtensa.x"));

    return exe;
}

fn buildEsp32S3(b: *std.Build, opt: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
}) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "esp32s3_baremetal_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("esp32s3/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });
    return exe;
}
