const std = @import("std");

const io = @import("io.zig");
const a = @import("parse_args.zig");
const tq = @import("tq.zig");

const print = std.debug.print;
const VERSION = @import("build_opts").version;

// AVIF encoded data buffer
const EncBuffer = struct {
    q: ?u32 = null, // Q used
    data: ?std.ArrayList(u8) = null, // AVIF
    size: usize = 0, // data size

    pub fn deinitCache(buf: *EncBuffer, allocator: std.mem.Allocator) void {
        if (buf.data) |*data| {
            data.deinit(allocator);
            buf.data = null;
        }
        buf.q = null;
    }
};

// Encoder Context
pub const EncCtx = struct {
    o: a.AvifEncOptions = a.AvifEncOptions{}, // user options
    t: tq.TQCtx = tq.TQCtx{}, // TQ context
    q: u32 = 0, // final chosen Q, updated in-loop
    w: u32 = 0, // input width
    h: u32 = 0, // input height
    rgb: []const u8 = undefined, // decoded input RGB buffer
    src: io.Image = undefined, // input image
    buf: EncBuffer = EncBuffer{}, // compressed AVIF
};

pub fn main() !void {
    print("\x1b[31moavif\x1b[0m | {s}\n", .{VERSION});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var show_help = false;
    var show_version = false;
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    for (1..args.len) |i| {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))
            show_help = true
        else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))
            show_version = true
        else
            break;
    }

    if (show_help) return a.printUsage();
    if (show_version) return io.printVersion(VERSION);

    var e: EncCtx = EncCtx{};
    try e.o.parseArgs(args, &input_file, &output_file);
    const o = &e.o;

    const input_path =
        if (input_file) |in| in else return error.MissingInputOrOutput;
    const output_path =
        if (output_file) |out| out else return error.MissingInputOrOutput;

    e.src = try io.loadImage(allocator, input_path);
    defer e.src.deinit(allocator);
    const src = &e.src;

    print("Read {}x{}, {s}, {} bytes\n", .{
        src.width,
        src.height,
        if (src.channels > 3) "RGBA" else "RGB",
        (try std.fs.cwd().statFile(input_file.?)).size,
    });

    e.rgb = if (e.src.channels == 3) src.data else try src.toRGB8(allocator);
    defer if (e.src.channels != 3) allocator.free(e.rgb);
    e.w = @intCast(e.src.width);
    e.h = @intCast(e.src.height);

    print("Searching [tgt {}±{d:.1}, speed {}, {}-pass]\n", .{ o.score_tgt, o.tolerance, o.speed, o.max_pass });

    try tq.findTargetQuality(&e, allocator);
    defer e.buf.deinitCache(allocator);
    const buf = &e.buf;

    print("Found q{} (score {d:.2}, {} passes)\n", .{ e.q, e.t.score, e.t.num_pass });

    // if we have a buffer at the best Q, write
    if (buf.q.? == e.q) {
        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();
        try file.writeAll(buf.data.?.items);
    } else try io.encodeAvifToFile(&e, allocator, output_path);

    const bpp: f64 = @as(f64, @floatFromInt(e.buf.size * 8)) / @as(f64, @floatFromInt(e.w * e.h));
    print("Compressed to {} bytes ({d:.3} bpp)\n", .{ e.buf.size, bpp });
}
