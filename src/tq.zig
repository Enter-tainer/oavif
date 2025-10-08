const std = @import("std");
const a = @import("parse_args.zig");
const print = std.debug.print;
const computeScoreAtQuality = @import("main.zig").computeScoreAtQuality;
const EncCtx = @import("main.zig").EncCtx;

pub const TQCtx = struct {
    max_pass: usize = 6,
    num_pass: usize = 0,
    tolerance: f64 = 1.0,
    score: f64 = 0.0,
};

const PassResult = struct {
    quality: u32,
    score: f64,
};

inline fn predictQFromScore(tgt: f64) u32 {
    // Use exponential formula to predict Q from target SSIMULACRA2
    // Q = 6.83 * e^(0.0282 * target)
    const q = 6.83 * @exp(0.0282 * tgt);
    return @intFromFloat(@min(100.0, @round(q)));
}

inline fn linearInterpolate(scores: []const f64, qualities: []const f64, target: f64) ?f64 {
    if (scores.len < 2) return null;
    if (scores[1] == scores[0]) return null;

    const t = (target - scores[0]) / (scores[1] - scores[0]);
    return qualities[0] + (qualities[1] - qualities[0]) * t;
}

inline fn quadraticInterpolate(scores: []const f64, qualities: []const f64, target: f64) ?f64 {
    if (scores.len < 3) return null;

    const x0 = scores[0];
    const x1 = scores[1];
    const x2 = scores[2];
    const y0 = qualities[0];
    const y1 = qualities[1];
    const y2 = qualities[2];

    const denom = (x0 - x1) * (x0 - x2) * (x1 - x2);
    if (@abs(denom) < 0.001) return null;

    const coeff_a = (x2 * (y1 - y0) + x1 * (y0 - y2) + x0 * (y2 - y1)) / denom;
    const coeff_b = (x2 * x2 * (y0 - y1) + x1 * x1 * (y2 - y0) + x0 * x0 * (y1 - y2)) / denom;
    const coeff_c = (x1 * x2 * (x1 - x2) * y0 + x2 * x0 * (x2 - x0) * y1 + x0 * x1 * (x0 - x1) * y2) / denom;

    return coeff_a * target * target + coeff_b * target + coeff_c;
}

fn interpolateQuantizer(
    allocator: std.mem.Allocator,
    lo_bound: u32,
    hi_bound: u32,
    history: []const PassResult,
    target: f64,
) !u32 {
    const binary_search = @divFloor(lo_bound + hi_bound, 2);

    if (history.len == 0)
        return binary_search;

    var sorted = try std.ArrayList(PassResult).initCapacity(allocator, history.len);
    defer sorted.deinit(allocator);
    try sorted.appendSlice(allocator, history);

    std.mem.sort(PassResult, sorted.items, {}, struct {
        fn lessThan(_: void, lhs: PassResult, rhs: PassResult) bool {
            return lhs.score < rhs.score;
        }
    }.lessThan);

    var scores = try std.ArrayList(f64).initCapacity(allocator, 0);
    defer scores.deinit(allocator);
    var qualities = try std.ArrayList(f64).initCapacity(allocator, 0);
    defer qualities.deinit(allocator);

    for (sorted.items) |item| {
        try scores.append(allocator, item.score);
        try qualities.append(allocator, @floatFromInt(item.quality));
    }

    const pred = switch (history.len) {
        1 => binary_search,
        2 => blk: {
            if (linearInterpolate(scores.items, qualities.items, target)) |r|
                break :blk @as(u32, @intFromFloat(std.math.clamp(@round(r), 0, 100)));
            break :blk binary_search;
        },
        else => blk: {
            if (quadraticInterpolate(scores.items, qualities.items, target)) |r|
                break :blk @as(u32, @intFromFloat(std.math.clamp(@round(r), 0, 100)));
            if (linearInterpolate(scores.items, qualities.items, target)) |lr|
                break :blk @as(u32, @intFromFloat(std.math.clamp(@round(lr), 0, 100)));
            break :blk binary_search;
        },
    };

    return std.math.clamp(pred, lo_bound, hi_bound);
}

pub fn findTargetQuality(
    e: *EncCtx,
    allocator: std.mem.Allocator,
) !void {
    // TODO: these should be parameters
    const tolerance: f64 = 1.0;

    var history = try std.ArrayList(PassResult).initCapacity(allocator, 0);
    defer history.deinit(allocator);

    var lo_bound: u32 = 0;
    var hi_bound: u32 = 100;

    for (0..e.t.max_pass) |pass| {
        e.t.num_pass = pass;
        e.q = if (pass == 0)
            predictQFromScore(e.o.score_tgt)
        else
            try interpolateQuantizer(allocator, lo_bound, hi_bound, history.items, e.o.score_tgt);

        print("Probe {}/{}: Q={} (range: {}-{})\n", .{ pass + 1, e.t.max_pass, e.q, lo_bound, hi_bound });

        if (blk: {
            for (history.items) |h|
                if (h.quality == e.q)
                    break :blk true;
            break :blk false;
        }) {
            print("Quality {} already probed, stopping\n", .{e.q});
            break;
        }

        e.t.score = try computeScoreAtQuality(e, allocator);
        print("  Score: {d:.2}\n", .{e.t.score});

        try history.append(allocator, PassResult{ .quality = e.q, .score = e.t.score });

        const abs_err = @abs(e.t.score - e.o.score_tgt);
        if (pass == 0) {
            const err_bound: u32 = @intFromFloat(@ceil(abs_err) * 4.0);
            if (e.t.score - e.o.score_tgt > 0) {
                hi_bound = e.q;
                lo_bound = if (e.q > err_bound) e.q - err_bound else 0;
            } else {
                lo_bound = e.q;
                hi_bound = @min(100, e.q + err_bound);
            }

            print("  Bounding search based on error: range now {}-{}\n", .{ lo_bound, hi_bound });
        }

        if (abs_err < tolerance) {
            print("Target reached within tolerance\n", .{});
            return;
        }

        if (pass > 0) {
            if (e.t.score > e.o.score_tgt)
                hi_bound = e.q
            else
                lo_bound = e.q;
        }

        if (lo_bound >= hi_bound - 1) {
            print("Search range collapsed\n", .{});
            break;
        }
    }

    var best_q: ?u32 = null;
    var best_score: f64 = 0;

    for (history.items) |h| {
        if (h.score >= e.o.score_tgt)
            if (best_q == null or h.quality < best_q.?) {
                best_q = h.quality;
                best_score = h.score;
            };
    }
    if (best_q) |q| {
        print("Best quality: {} (score: {d:.2})\n", .{ q, best_score });
        e.q = q;
        e.t.score = best_score;
        return;
    }

    var highest_score: f64 = 0;
    var highest_q: u32 = 0;
    for (history.items) |h|
        if (h.score > highest_score) {
            highest_score = h.score;
            highest_q = h.quality;
        };

    e.q = highest_q;
    e.t.score = highest_score;
    print("No pass met target, returning highest scoring quality: {} (score: {d:.2})\n", .{ highest_q, highest_score });
    return;
}
