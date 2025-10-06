const std = @import("std");
const print = std.debug.print;
const c = @cImport({
    @cInclude("avif/avif.h");
});

pub const AVIF_MAX_SPEED = 10;
pub const AVIF_MIN_QUALITY = 0;
pub const AVIF_MAX_QUALITY = 100;

const ARG_QUALITY: [:0]const u8 = "--quality";
const ARG_QUALITY_ALPHA: [:0]const u8 = "--quality-alpha";
const ARG_SPEED: [:0]const u8 = "--speed";
const ARG_MAX_THREADS: [:0]const u8 = "--max-threads";
const ARG_TILE_ROWS_LOG2: [:0]const u8 = "--tile-rows-log2";
const ARG_TILE_COLS_LOG2: [:0]const u8 = "--tile-cols-log2";
const ARG_AUTO_TILING: [:0]const u8 = "--auto-tiling";
const ARG_TARGET_SCORE: [:0]const u8 = "--target";
const ARG_TENBIT: [:0]const u8 = "--tenbit";

pub const AvifEncOptions = struct {
    quality: i32 = 60,
    quality_alpha: i32 = 100, // AVIF_QUALITY_LOSSLESS
    speed: i32 = 6, // AVIF_SPEED_DEFAULT
    max_threads: i32 = 1,
    tile_rows_log2: i32 = 0,
    tile_cols_log2: i32 = 0,
    auto_tiling: bool = true,
    target_score: f64 = 80.0,
    tenbit: bool = true,

    pub fn copyToEncoder(options: *const AvifEncOptions, encoder: *c.avifEncoder) void {
        encoder.quality = options.quality;
        encoder.qualityAlpha = options.quality_alpha;
        encoder.speed = options.speed;
        encoder.maxThreads = options.max_threads;
        encoder.tileRowsLog2 = options.tile_rows_log2;
        encoder.tileColsLog2 = options.tile_cols_log2;
        encoder.autoTiling = if (options.auto_tiling) c.AVIF_TRUE else c.AVIF_FALSE;
    }
};

fn intCliArg(arg_idx: *usize, args: [][:0]u8, min: i64, max: i64, arg: [:0]const u8) !i64 {
    if (arg_idx.* >= args.len or args[arg_idx.*][0] == '-') {
        print("Error: Missing {s} value\n", .{arg});
        return error.MissingOptionValue;
    }
    const tmp: i64 = try std.fmt.parseInt(i64, args[arg_idx.*], 10);
    if (tmp < min or tmp > max) {
        print("Error: {s} must be between {d} and {d}\n", .{ arg, min, max });
        return error.InvalidOptionValue;
    }
    arg_idx.* += 1;
    return tmp;
}

fn floatCliArg(arg_idx: *usize, args: [][:0]u8, min: f64, max: f64, arg: [:0]const u8) !f64 {
    if (arg_idx.* >= args.len or args[arg_idx.*][0] == '-') {
        print("Error: Missing {s} value\n", .{arg});
        return error.MissingOptionValue;
    }
    const tmp: f64 = try std.fmt.parseFloat(f64, args[arg_idx.*]);
    if (tmp < min or tmp > max) {
        print("Error: {s} must be between {d} and {d}\n", .{ arg, min, max });
        return error.InvalidOptionValue;
    }
    arg_idx.* += 1;
    return tmp;
}

fn uintCliArg(arg_idx: *usize, args: [][:0]u8, min: u64, max: u64, arg: [:0]const u8) !u64 {
    if (arg_idx.* >= args.len or args[arg_idx.*][0] == '-') {
        print("Error: Missing {s} value\n", .{arg});
        return error.MissingOptionValue;
    }
    const tmp: u64 = try std.fmt.parseInt(u64, args[arg_idx.*], 10);
    if (tmp < min or tmp > max) {
        print("Error: {s} must be between {d} and {d}\n", .{ arg, min, max });
        return error.InvalidOptionValue;
    }
    arg_idx.* += 1;
    return tmp;
}

fn boolCliArg(arg_idx: *usize, args: [][:0]u8, arg: [:0]const u8) !bool {
    if (arg_idx.* >= args.len or args[arg_idx.*][0] == '-') {
        print("Error: Missing {s} value\n", .{arg});
        return error.MissingOptionValue;
    }
    const tmp: i32 = try std.fmt.parseInt(i32, args[arg_idx.*], 10);
    if (tmp != 0 and tmp != 1) {
        print("Error: {s} must be 0 or 1\n", .{arg});
        return error.InvalidOptionValue;
    }
    arg_idx.* += 1;
    return tmp == 1;
}

pub fn parseArgs(args: [][:0]u8, input_file: *?[]const u8, output_file: *?[]const u8) !AvifEncOptions {
    var arg_idx: usize = 1;
    var options = AvifEncOptions{};

    while (arg_idx < args.len) {
        const arg = args[arg_idx];
        arg_idx += 1;

        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, ARG_QUALITY)) {
            options.quality = @intCast(try intCliArg(&arg_idx, args, AVIF_MIN_QUALITY, AVIF_MAX_QUALITY, ARG_QUALITY));
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, ARG_SPEED)) {
            options.speed = @intCast(try intCliArg(&arg_idx, args, -1, AVIF_MAX_SPEED, ARG_SPEED));
        } else if (std.mem.eql(u8, arg, ARG_QUALITY_ALPHA)) {
            options.quality_alpha = @intCast(try intCliArg(&arg_idx, args, AVIF_MIN_QUALITY, AVIF_MAX_QUALITY, ARG_QUALITY_ALPHA));
        } else if (std.mem.eql(u8, arg, ARG_MAX_THREADS)) {
            options.max_threads = @intCast(try intCliArg(&arg_idx, args, 0, 64, ARG_MAX_THREADS));
        } else if (std.mem.eql(u8, arg, ARG_TILE_ROWS_LOG2)) {
            options.tile_rows_log2 = @intCast(try intCliArg(&arg_idx, args, 0, 6, ARG_TILE_ROWS_LOG2));
        } else if (std.mem.eql(u8, arg, ARG_TILE_COLS_LOG2)) {
            options.tile_cols_log2 = @intCast(try intCliArg(&arg_idx, args, 0, 6, ARG_TILE_COLS_LOG2));
        } else if (std.mem.eql(u8, arg, ARG_AUTO_TILING)) {
            options.auto_tiling = try boolCliArg(&arg_idx, args, ARG_AUTO_TILING);
        } else if (std.mem.eql(u8, arg, ARG_TARGET_SCORE)) {
            options.target_score = try floatCliArg(&arg_idx, args, 30.0, 100.0, ARG_TARGET_SCORE);
        } else if (std.mem.eql(u8, arg, ARG_TENBIT)) {
            options.tenbit = try boolCliArg(&arg_idx, args, ARG_TENBIT);
        } else if (input_file.* == null) {
            input_file.* = arg;
        } else if (output_file.* == null) {
            output_file.* = arg;
        } else {
            print("Error: Unexpected argument: {s}\n", .{arg});
            return error.UnexpectedArgument;
        }
    }

    return options;
}

pub fn printUsage() void {
    print("\n", .{});
    print(
        \\usage:  avif-tq [encoder_options] <in> <out.avif>
        \\
        \\options:
        \\ -h, --help
        \\    show this help
        \\ -v, --version
        \\    show version information
        \\ -q, --quality N
        \\    quality factor for RGB (0..100=lossless) [60]
        \\ -s, --speed N
        \\    encoder speed (0..10) [6]
        \\ --target N
        \\    target SSIMULACRA2 score (0-100) [80]
        \\ --quality-alpha N
        \\    quality factor for alpha (0-100=lossless) [100]
        \\ --max-threads N
        \\    maximum number of threads to use [1]
        \\ --tile-rows-log2 N
        \\    tile rows log2 (0..6) [0]
        \\ --tile-cols-log2 N
        \\    tile columns log2 (0..6) [0]
        \\ --auto-tiling 0/1
        \\    enable automatic tiling [0]
    , .{});
    print("\n\n\x1b[37mInput image formats: PNG, PAM, JPEG, WebP, or AVIF\x1b[0m\n", .{});
}
