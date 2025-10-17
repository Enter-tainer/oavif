const std = @import("std");

fn getVersionString(b: *std.Build) ![]const u8 {
    const allocator = b.allocator;
    const command = [_][]const u8{ "git", "describe", "--tags", "--always" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &command,
    }) catch |err| {
        std.log.warn("Failed to get git version: {s}", .{@errorName(err)});
        return "unknown";
    };
    if (result.term.Exited != 0)
        return "unknown";
    const version = std.mem.trimRight(u8, result.stdout, "\r\n");
    return allocator.dupe(u8, version);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const target_os = target.result.os.tag;
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const version = getVersionString(b) catch "unknown";
    options.addOption([]const u8, "version", version);
    const strip: bool = if (optimize == std.builtin.OptimizeMode.ReleaseFast) true else false;
    const prefer_dynamic = b.option(bool, "dynamic-deps", "Link third-party libraries dynamically") orelse false;

    // fssimu2
    const fssimu2 = b.dependency("fssimu2", .{
        .target = target,
        .optimize = optimize,
    });

    // oavif
    const bin = b.addExecutable(.{
        .name = "oavif",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
        }),
    });
    bin.root_module.addOptions("build_opts", options);
    bin.root_module.addIncludePath(b.path("src"));
    bin.root_module.addIncludePath(b.path("src/include"));
    bin.root_module.addIncludePath(b.path("third-party/"));

    if (target_os == .windows) {
        const vcpkg_root = b.getenv("VCPKG_ROOT");
        const vcpkg_triplet = b.getenv("VCPKG_DEFAULT_TRIPLET") orelse "x64-windows";
        if (vcpkg_root) |root| {
            const triplet_root = b.pathJoin(&.{ root, "installed", vcpkg_triplet });
            bin.root_module.addIncludePath(.{ .path = b.pathJoin(&.{ triplet_root, "include" }) });
            bin.root_module.addLibraryPath(.{ .path = b.pathJoin(&.{ triplet_root, "lib" }) });
            bin.root_module.addLibraryPath(.{ .path = b.pathJoin(&.{ triplet_root, "lib", "manual-link" }) });
        } else {
            std.log.warn("VCPKG_ROOT not set; Windows builds may fail to locate dependencies", .{});
        }
    }

    // local import
    bin.root_module.addImport("fssimu2", fssimu2.module("fssimu2"));

    // system decoder libs
    const link_mode = if (prefer_dynamic) .dynamic else .static;
    bin.root_module.linkSystemLibrary("jpeg", .{ .preferred_link_mode = link_mode });
    bin.root_module.linkSystemLibrary("webp", .{ .preferred_link_mode = link_mode });
    bin.root_module.linkSystemLibrary("avif", .{ .preferred_link_mode = link_mode });
    bin.root_module.linkSystemLibrary("spng", .{ .preferred_link_mode = link_mode });

    b.installArtifact(bin);
}
