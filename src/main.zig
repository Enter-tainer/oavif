const std = @import("std");
const fssimu2 = @import("fssimu2");
const io = @import("io.zig");
const a = @import("parse_args.zig");
const tq = @import("tq.zig");
const print = std.debug.print;
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("jpeglib.h");
    @cInclude("webp/decode.h");
    @cInclude("avif/avif.h");
});

const VERSION = @import("build_opts").version;

pub const EncCtx = struct {
    o: a.AvifEncOptions = a.AvifEncOptions{},
    t: tq.TQCtx = tq.TQCtx{},
    q: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    rgb: []const u8 = undefined,
    size: usize = 0,
};

pub fn computeScoreAtQuality(e: *EncCtx, allocator: std.mem.Allocator) !f64 {
    var avif_data = try std.ArrayListAligned(u8, null).initCapacity(allocator, 0);
    defer avif_data.deinit(allocator);
    try encodeAvifToBuffer(e, allocator, &avif_data);

    const decoded_rgb = try decodeAvifToRgb(allocator, avif_data.items);
    defer allocator.free(decoded_rgb);

    return try fssimu2.computeSsimu2(allocator, e.rgb, decoded_rgb, e.w, e.h, 3, null);
}

fn encodeAvifToBuffer(e: *EncCtx, allocator: std.mem.Allocator, output: *std.ArrayListAligned(u8, null)) !void {
    const o: *a.AvifEncOptions = &e.o;
    const image = c.avifImageCreate(e.w, e.h, if (o.tenbit) 10 else 8, c.AVIF_PIXEL_FORMAT_YUV444);
    if (image == null) return error.OutOfMemory;
    defer c.avifImageDestroy(image);

    var rgb_img = c.avifRGBImage{};
    c.avifRGBImageSetDefaults(&rgb_img, image);
    rgb_img.format = c.AVIF_RGB_FORMAT_RGB;
    rgb_img.pixels = @ptrCast(@constCast(e.rgb.ptr));
    rgb_img.rowBytes = e.w * 3;

    const convert_result = c.avifImageRGBToYUV(image, &rgb_img);
    if (convert_result != c.AVIF_RESULT_OK) return error.ConvertFailed;

    const avifenc = c.avifEncoderCreate();
    if (avifenc == null) return error.OutOfMemory;
    defer c.avifEncoderDestroy(avifenc);

    e.o.copyToEncoder(@ptrCast(avifenc));

    avifenc.*.quality = @intCast(e.q);

    var avif_output = c.avifRWData{ .data = null, .size = 0 };
    if (c.avifEncoderAddImage(avifenc, image, 1, c.AVIF_ADD_IMAGE_FLAG_SINGLE) != c.AVIF_RESULT_OK)
        return error.AddImageFailed;
    if (c.avifEncoderFinish(avifenc, &avif_output) != c.AVIF_RESULT_OK)
        return error.FinishFailed;
    defer c.avifRWDataFree(&avif_output);

    try output.appendSlice(allocator, @as([*]const u8, @ptrCast(avif_output.data))[0..avif_output.size]);
}

// TODO: Refactor to eliminate duplicate functionality with `loadAVIF()` in `io.zig`
// TODO: Confirm we're using dav1d when possible
fn decodeAvifToRgb(allocator: std.mem.Allocator, avif_data: []const u8) ![]u8 {
    const decoder = c.avifDecoderCreate();
    if (decoder == null) return error.OutOfMemory;
    defer c.avifDecoderDestroy(decoder);

    var set_result = c.avifDecoderSetIOMemory(decoder, avif_data.ptr, avif_data.len);
    if (set_result != c.AVIF_RESULT_OK) return error.SetIOMemoryFailed;

    set_result = c.avifDecoderParse(decoder);
    if (set_result != c.AVIF_RESULT_OK) return error.ParseFailed;

    set_result = c.avifDecoderNextImage(decoder);
    if (set_result != c.AVIF_RESULT_OK) return error.NoImageDecoded;

    var rgb = c.avifRGBImage{};
    c.avifRGBImageSetDefaults(&rgb, decoder.*.image);
    rgb.format = c.AVIF_RGB_FORMAT_RGB;

    set_result = c.avifRGBImageAllocatePixels(&rgb);
    if (set_result != c.AVIF_RESULT_OK) return error.AllocatePixelsFailed;
    defer c.avifRGBImageFreePixels(&rgb);

    set_result = c.avifImageYUVToRGB(decoder.*.image, &rgb);
    if (set_result != c.AVIF_RESULT_OK) return error.YUVToRGBFailed;

    const img = decoder.*.image;
    const width = img.*.width;
    const height = img.*.height;
    const row_bytes = rgb.rowBytes;
    const out_size = width * height * 3;
    const out = try allocator.alloc(u8, out_size);

    const src_pixels: [*]const u8 = @ptrCast(rgb.pixels);
    for (0..height) |y| {
        const src_off = y * row_bytes;
        const dst_off = y * width * 3;
        @memcpy(out[dst_off .. dst_off + width * 3], src_pixels[src_off .. src_off + width * 3]);
    }

    return out;
}

fn encodeAvif(e: *EncCtx, allocator: std.mem.Allocator, output_path: []const u8) !void {
    var avif_data = try std.ArrayListAligned(u8, null).initCapacity(allocator, 0);
    defer avif_data.deinit(allocator);
    try encodeAvifToBuffer(e, allocator, &avif_data);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(avif_data.items);
    e.size = avif_data.items.len;
}

fn printVersion() void {
    const jpeg_version = c.LIBJPEG_TURBO_VERSION_NUMBER;
    const jpeg_major: comptime_int = jpeg_version / 1_000_000;
    const jpeg_minor: comptime_int = (jpeg_version / 1_000) % 1_000;
    const jpeg_patch: comptime_int = jpeg_version % 1_000;
    const jpeg_simd: bool = c.WITH_SIMD != 0;

    const webp_version = c.WebPGetDecoderVersion();
    const webp_major = webp_version >> 16;
    const webp_minor = (webp_version >> 8) & 0xFF;
    const webp_patch = webp_version & 0xFF;

    const avif_major: comptime_int = c.AVIF_VERSION_MAJOR;
    const avif_minor: comptime_int = c.AVIF_VERSION_MINOR;
    const avif_patch: comptime_int = c.AVIF_VERSION_PATCH;
    print("avif-tq {s}\n", .{VERSION});
    print("libjpeg-turbo {d}.{d}.{d} ", .{ jpeg_major, jpeg_minor, jpeg_patch });
    print("[simd: {}]\n", .{jpeg_simd});
    print("libwebp {d}.{d}.{d}\n", .{ webp_major, webp_minor, webp_patch });
    print("libavif {d}.{d}.{d}\n", .{ avif_major, avif_minor, avif_patch });
}

pub fn main() !void {
    print("\x1b[31mavif-tq\x1b[0m | {s}\n", .{VERSION});
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
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            show_version = true;
        } else {
            break;
        }
    }

    if (show_help) return a.printUsage();
    if (show_version) return printVersion();

    var e: EncCtx = EncCtx{};
    var o: *a.AvifEncOptions = &e.o;

    try o.parseArgs(args, &input_file, &output_file);

    const input_path =
        if (input_file) |in| in else return error.MissingInputOrOutput;
    const output_path =
        if (output_file) |out| out else return error.MissingInputOrOutput;

    var ref_image: io.Image = try io.loadImage(allocator, input_path);
    defer ref_image.deinit(allocator);

    print("Read {}x{}, {s}, {} bytes\n", .{
        ref_image.width,
        ref_image.height,
        if (ref_image.channels > 3) "RGBA" else "RGB",
        (try std.fs.cwd().statFile(input_file.?)).size,
    });

    e.rgb = if (ref_image.channels == 3) ref_image.data else try io.toRGB8(allocator, ref_image);
    defer if (ref_image.channels != 3) allocator.free(e.rgb);
    e.w = @intCast(ref_image.width);
    e.h = @intCast(ref_image.height);

    print("Searching [tgt {}, speed {}, {}-pass]\n", .{ o.score_tgt, o.speed, e.o.max_pass });

    try tq.findTargetQuality(&e, allocator);

    print("Found q{} (score {d:.2}, {} passes)\n", .{ e.q, e.t.score, e.t.num_pass });

    try encodeAvif(&e, allocator, output_path);

    const bpp: f64 = @as(f64, @floatFromInt(e.size * 8)) / @as(f64, @floatFromInt(e.w * e.h));
    print("Compressed to {} bytes ({d:.3} bpp)\n", .{ e.size, bpp });
}
