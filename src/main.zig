const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Thread = std.Thread;

// Import modules
const types = @import("types.zig");
const parallel = @import("parallel.zig");
const output = @import("output.zig");
const utils = @import("utils.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse command line arguments
    var search_path: []const u8 = ".";
    var num_threads: u32 = 0; // 0 = auto-detect

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--threads") or mem.eql(u8, args[i], "-j")) {
            if (i + 1 < args.len) {
                num_threads = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Invalid thread count: {s}\n", .{args[i + 1]});
                    return error.InvalidArgument;
                };
                i += 1;
            }
        } else if (!mem.startsWith(u8, args[i], "-")) {
            search_path = args[i];
        }
    }

    // Auto-detect CPU count if not specified
    if (num_threads == 0) {
        num_threads = @min(Thread.getCpuCount() catch 4, 16); // Cap at 16 threads
    }

    // Print header
    std.debug.print("🎵 FLAC Lossless Analyzer with FFT Spectral Analysis (Zig Edition - Parallel)\n", .{});
    std.debug.print("Scanning directory: {s}\n", .{search_path});
    std.debug.print("Using {} worker threads\n", .{num_threads});

    // Count FLAC files
    std.debug.print("Counting FLAC files...\n", .{});
    const total_flac_count = utils.countFlacFiles(allocator, search_path);
    std.debug.print("Found {} FLAC files to analyze\n", .{total_flac_count});

    if (total_flac_count == 0) {
        std.debug.print("No FLAC files found!\n", .{});
        return;
    }

    // Collect all file paths
    std.debug.print("Collecting file paths...\n", .{});
    var queue = parallel.WorkQueue.init(allocator);
    defer queue.deinit();

    try utils.collectFlacFiles(allocator, search_path, &queue);
    std.debug.print("Collected {} files\n\n", .{queue.getTotalFiles()});

    // Initialize shared state
    var state = parallel.SharedAnalysisState.init(allocator, total_flac_count);
    defer state.deinit();

    // Write header to output buffer
    const writer = state.output_buffer.writer(allocator);
    try writer.print("🎵 FLAC Lossless Analyzer with FFT Spectral Analysis (Zig Edition - Parallel)\n", .{});
    try writer.print("Scanning directory: {s}\n", .{search_path});
    try writer.print("Using {} worker threads\n\n", .{num_threads});

    // Spawn worker threads
    const worker_ctx = parallel.WorkerContext{
        .allocator = allocator,
        .queue = &queue,
        .state = &state,
    };

    const threads = try allocator.alloc(Thread, num_threads);
    defer allocator.free(threads);

    const start_time = std.time.milliTimestamp();

    // Start workers
    for (threads) |*thread| {
        thread.* = try Thread.spawn(.{}, parallel.workerThread, .{worker_ctx});
    }

    // Progress reporter
    while (state.files_processed.load(.monotonic) < total_flac_count) {
        const processed = state.files_processed.load(.monotonic);
        const percentage = if (total_flac_count > 0)
            (@as(f64, @floatFromInt(processed)) / @as(f64, @floatFromInt(total_flac_count))) * 100.0
        else
            0.0;

        std.debug.print("\r🔍 [{d}/{d}] {d:.1}% analyzing...", .{ processed, total_flac_count, percentage });
        Thread.sleep(100 * std.time.ns_per_ms);
    }

    // Wait for all workers to finish
    for (threads) |thread| {
        thread.join();
    }

    const end_time = std.time.milliTimestamp();
    const elapsed_ms = end_time - start_time;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

    // Clear the progress line
    std.debug.print("\r{s: <100}\r", .{""});

    // Calculate totals
    state.mutex.lock();
    state.total_files = state.valid_lossless + state.definitely_transcoded + state.likely_transcoded;
    state.mutex.unlock();

    // Print summary
    try output.printSummary(&state, writer, elapsed_s);

    // Print suspicious files details
    try output.printSuspiciousFiles(state.suspicious_files.items, writer);

    // Print method notes
    try output.printMethodNotes(writer);

    // Write to result.txt
    try fs.cwd().writeFile(.{ .sub_path = "result.txt", .data = state.output_buffer.items });
    std.debug.print("\n✅ Results written to result.txt\n", .{});
}

