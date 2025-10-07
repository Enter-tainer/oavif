const std = @import("std");
const a = @import("parse_args.zig");
const print = std.debug.print;
const computeScoreAtQuality = @import("main.zig").computeScoreAtQuality;

const ProbeResult = struct {
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
    lower_limit: u32,
    upper_limit: u32,
    history: []const ProbeResult,
    target: f64,
) !u32 {
    const binary_search = @divFloor(lower_limit + upper_limit, 2);

    if (history.len == 0)
        return binary_search;

    // Sort history by score
    var sorted = try std.ArrayList(ProbeResult).initCapacity(allocator, history.len);
    defer sorted.deinit(allocator);
    try sorted.appendSlice(allocator, history);

    std.mem.sort(ProbeResult, sorted.items, {}, struct {
        fn lessThan(_: void, lhs: ProbeResult, rhs: ProbeResult) bool {
            return lhs.score < rhs.score;
        }
    }.lessThan);

    // Extract scores and qualities
    var scores = try std.ArrayList(f64).initCapacity(allocator, 0);
    defer scores.deinit(allocator);
    var qualities = try std.ArrayList(f64).initCapacity(allocator, 0);
    defer qualities.deinit(allocator);

    for (sorted.items) |item| {
        try scores.append(allocator, item.score);
        try qualities.append(allocator, @floatFromInt(item.quality));
    }

    const predicted = switch (history.len) {
        1 => binary_search,
        2 => blk: {
            // Linear interpolation for 3rd probe
            const result = linearInterpolate(scores.items, qualities.items, target);
            if (result) |r| {
                break :blk @as(u32, @intFromFloat(@max(0.0, @min(100.0, @round(r)))));
            }
            break :blk binary_search;
        },
        else => blk: {
            // Quadratic interpolation for 4+ probes
            const result = quadraticInterpolate(scores.items, qualities.items, target);
            if (result) |r| {
                break :blk @as(u32, @intFromFloat(@max(0.0, @min(100.0, @round(r)))));
            }
            // Fallback to linear if quadratic fails
            const linear_result = linearInterpolate(scores.items, qualities.items, target);
            if (linear_result) |lr| {
                break :blk @as(u32, @intFromFloat(@max(0.0, @min(100.0, @round(lr)))));
            }
            break :blk binary_search;
        },
    };

    return std.math.clamp(predicted, lower_limit, upper_limit);
}

// TODO: If we're within a certain margin of the target, limit maximum step size
// to increase odds of landing on the target
pub fn findTargetQuality(
    allocator: std.mem.Allocator,
    ref_rgb: []const u8,
    width: u32,
    height: u32,
    target: f64,
    enc_options: a.AvifEncOptions,
) !u32 {
    const max_probes: usize = 6; // Av1an default
    const tolerance: f64 = 0.5; // Target tolerance

    var history = try std.ArrayList(ProbeResult).initCapacity(allocator, 0);
    defer history.deinit(allocator);

    var lower_limit: u32 = 0;
    var upper_limit: u32 = 100;

    var probe_count: usize = 0;
    while (probe_count < max_probes) : (probe_count += 1) {
        // Predict next quality to probe
        const next_q = if (probe_count == 0)
            predictQFromScore(target)
        else
            try interpolateQuantizer(allocator, lower_limit, upper_limit, history.items, target);

        print("Probe {}/{}: Q={} (range: {}-{})\n", .{ probe_count + 1, max_probes, next_q, lower_limit, upper_limit });

        // Check if we already probed this quality
        var already_probed = false;
        for (history.items) |h| {
            if (h.quality == next_q) {
                already_probed = true;
                break;
            }
        }

        if (already_probed) {
            print("Quality {} already probed, stopping\n", .{next_q});
            break;
        }

        // Perform the probe
        const score = try computeScoreAtQuality(allocator, ref_rgb, width, height, next_q, enc_options);
        print("  Score: {d:.2}\n", .{score});

        try history.append(allocator, ProbeResult{ .quality = next_q, .score = score });

        // Check if we're within tolerance
        if (@abs(score - target) < tolerance) {
            print("Target reached within tolerance\n", .{});
            return next_q;
        }

        // Narrow the search range
        if (score > target) {
            // Score too high, need lower quality (lower Q for AVIF)
            upper_limit = next_q;
        } else {
            // Score too low, need higher quality (higher Q for AVIF)
            lower_limit = next_q;
        }

        // Check if range collapsed
        if (lower_limit >= upper_limit - 1) {
            print("Search range collapsed\n", .{});
            break;
        }
    }

    // Find the best quality from history that meets or exceeds target
    var best_q: ?u32 = null;
    var best_score: f64 = 0;

    for (history.items) |h| {
        if (h.score >= target) {
            if (best_q == null or h.quality < best_q.?) {
                best_q = h.quality;
                best_score = h.score;
            }
        }
    }

    if (best_q) |q| {
        print("Best quality: {} (score: {d:.2})\n", .{ q, best_score });
        return q;
    }

    // If no probe met the target, return the highest quality probe
    var highest_score: f64 = 0;
    var highest_q: u32 = 0;
    for (history.items) |h| {
        if (h.score > highest_score) {
            highest_score = h.score;
            highest_q = h.quality;
        }
    }

    print("No probe met target, returning highest scoring quality: {} (score: {d:.2})\n", .{ highest_q, highest_score });
    return highest_q;
}
