const std = @import("std");
const fssimu2 = @import("fssimu2");
const io = @import("io.zig");
const a = @import("parse_args.zig");
const print = std.debug.print;
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("jpeglib.h");
    @cInclude("webp/decode.h");
    @cInclude("avif/avif.h");
});

const VERSION = @import("build_opts").version;

fn findTargetQuality(allocator: std.mem.Allocator, ref_rgb: []const u8, width: u32, height: u32, target: f64, enc_options: a.AvifEncOptions) !u32 {
    var low: u32 = 0;
    var high: u32 = 100;

    while (low < high) {
        const mid = (low + high) / 2;
        const score = try computeScoreAtQuality(allocator, ref_rgb, width, height, mid, enc_options);
        if (score >= target) high = mid else low = mid + 1;
    }

    return low;
}

fn computeScoreAtQuality(allocator: std.mem.Allocator, ref_rgb: []const u8, width: u32, height: u32, quality: u32, enc_options: a.AvifEncOptions) !f64 {
    var avif_data = try std.ArrayListAligned(u8, null).initCapacity(allocator, 0);
    defer avif_data.deinit(allocator);
    try encodeAvifToBuffer(allocator, ref_rgb, width, height, quality, enc_options, &avif_data);

    const decoded_rgb = try decodeAvifToRgb(allocator, avif_data.items);
    defer allocator.free(decoded_rgb);

    return try fssimu2.computeSsimu2(allocator, ref_rgb, decoded_rgb, width, height, 3, null);
}

fn encodeAvifToBuffer(allocator: std.mem.Allocator, rgb: []const u8, width: u32, height: u32, quality: u32, enc_options: a.AvifEncOptions, output: *std.ArrayListAligned(u8, null)) !void {
    const image = c.avifImageCreate(width, height, 8, c.AVIF_PIXEL_FORMAT_YUV444);
    if (image == null) return error.OutOfMemory;
    defer c.avifImageDestroy(image);

    // Set RGB data
    var rgb_img = c.avifRGBImage{};
    c.avifRGBImageSetDefaults(&rgb_img, image);
    rgb_img.format = c.AVIF_RGB_FORMAT_RGB;
    rgb_img.pixels = @ptrCast(@constCast(rgb.ptr));
    rgb_img.rowBytes = width * 3;

    const convert_result = c.avifImageRGBToYUV(image, &rgb_img);
    if (convert_result != c.AVIF_RESULT_OK) return error.ConvertFailed;

    const encoder = c.avifEncoderCreate();
    if (encoder == null) return error.OutOfMemory;
    defer c.avifEncoderDestroy(encoder);

    // Apply encoder options
    enc_options.copyToEncoder(@ptrCast(encoder));

    // Override quality with the specific value for this encoding
    encoder.*.quality = @intCast(quality);

    var avif_output = c.avifRWData{ .data = null, .size = 0 };
    const add_result = c.avifEncoderAddImage(encoder, image, 1, c.AVIF_ADD_IMAGE_FLAG_SINGLE);
    if (add_result != c.AVIF_RESULT_OK) return error.AddImageFailed;

    const finish_result = c.avifEncoderFinish(encoder, &avif_output);
    if (finish_result != c.AVIF_RESULT_OK) return error.FinishFailed;

    defer c.avifRWDataFree(&avif_output);

    try output.appendSlice(allocator, @as([*]const u8, @ptrCast(avif_output.data))[0..avif_output.size]);
}

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

fn encodeAvif(allocator: std.mem.Allocator, rgb: []const u8, width: u32, height: u32, quality: u32, enc_options: a.AvifEncOptions, output_path: []const u8) !void {
    var avif_data = try std.ArrayListAligned(u8, null).initCapacity(allocator, 0);
    defer avif_data.deinit(allocator);
    try encodeAvifToBuffer(allocator, rgb, width, height, quality, enc_options, &avif_data);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(avif_data.items);
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

    // Parse encoder-specific arguments
    const enc_options = a.parseArgs(args, &input_file, &output_file) catch |err| {
        print("Error parsing arguments: {}\n", .{err});
        a.printUsage();
        return err;
    };

    if (input_file == null or output_file == null)
        return error.MissingInputOrOutput;

    const input_path = input_file.?;
    const output_path = output_file.?;

    // Use target score from options (with default value of 80.0)
    const target_score = enc_options.target_score;

    var ref_image = try io.loadImage(allocator, input_path);
    defer ref_image.deinit(allocator);

    // Convert to RGB if needed
    const ref_rgb = if (ref_image.channels == 3) ref_image.data else try io.toRGB8(allocator, ref_image);
    defer if (ref_image.channels != 3) allocator.free(ref_rgb);

    // Find the minimal quality that achieves >= target_score
    // Use default encoder options for quality finding
    const default_enc_options = a.AvifEncOptions{};
    const quality = try findTargetQuality(allocator, ref_rgb, @intCast(ref_image.width), @intCast(ref_image.height), target_score, default_enc_options);

    // Encode with that quality
    try encodeAvif(allocator, ref_rgb, @intCast(ref_image.width), @intCast(ref_image.height), quality, enc_options, output_path);

    print("Encoded AVIF with quality {}\n", .{quality});
}
