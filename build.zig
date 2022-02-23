const std = @import("std");

pub const esvc_core = std.build.Pkg{
    .name = "esvc-core",
    .path = std.build.FileSource{
        .path = "core/main.zig",
    },
    .dependencies = &[_]std.build.Pkg{},
};

const exvc_src = "exvc/main.zig";

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    //const lib = b.addStaticLibrary("esvc2", "src/main.zig");
    //lib.setBuildMode(mode);
    //lib.install();

    const test_step = b.step("test", "Run tests");
    for ([_][]const u8{ esvc_core.path.path, exvc_src }) |test_file| {
        const tests = b.addTest(test_file);
        tests.setBuildMode(mode);
        test_step.dependOn(&tests.step);
    }

    const exvc_exe = b.addExecutable("exvc", exvc_src);
    exvc_exe.addPackage(esvc_core);
    exvc_exe.setTarget(target);
    exvc_exe.setBuildMode(mode);
    exvc_exe.install();

    const exvc_run_cmd = exvc_exe.run();
    exvc_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| exvc_run_cmd.addArgs(args);

    const exvc_run_step = b.step("exvc-run", "Run exvc");
    exvc_run_step.dependOn(&exvc_run_cmd.step);
}
