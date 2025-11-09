const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Thread = std.Thread;

// Import modules
const types = @import("types.zig");
const parallel = @import("parallel.zig");
const output = @import("output.zig");
const utils = @import("utils.zig");
const quarantine = @import("quarantine.zig");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const config = try cli.parseArgs(allocator);
    defer allocator.free(config.search_path);
    defer if (config.quarantine_config.enabled) allocator.free(config.quarantine_config.target_dir);

    const search_path = config.search_path;
    var num_threads = config.num_threads;
    const quarantine_config = config.quarantine_config;

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

    // Quarantine suspicious files if enabled
    if (quarantine_config.enabled) {
        // Count files to quarantine based on threshold
        var files_to_quarantine: u32 = 0;
        for (state.suspicious_files.items) |file| {
            if (quarantine_config.threshold == .high) {
                if (file.is_definitely) files_to_quarantine += 1;
            } else {
                files_to_quarantine += 1; // All suspicious files
            }
        }

        if (files_to_quarantine == 0) {
            std.debug.print("\n📁 No files match quarantine threshold.\n", .{});
        } else {
            // Prompt user for confirmation
            const threshold_desc = if (quarantine_config.threshold == .high) "definitely transcoded" else "suspicious (likely + definitely transcoded)";
            std.debug.print("\n⚠️  Found {} {s} file{s}. Move to quarantine? [y/N]: ", .{
                files_to_quarantine,
                threshold_desc,
                if (files_to_quarantine == 1) "" else "s",
            });

            // Read user input
            var buf: [10]u8 = undefined;
            const bytes_read = try std.posix.read(std.posix.STDIN_FILENO, &buf);
            const user_input = buf[0..bytes_read];
            const trimmed = mem.trim(u8, user_input, &std.ascii.whitespace);

            if (mem.eql(u8, trimmed, "y") or mem.eql(u8, trimmed, "Y") or mem.eql(u8, trimmed, "yes") or mem.eql(u8, trimmed, "Yes")) {
                // User confirmed, proceed with quarantine
                var quarantine_result = try quarantine.quarantineFiles(
                    allocator,
                    state.suspicious_files.items,
                    config.search_path,
                    quarantine_config,
                );
                defer quarantine_result.deinit();

                // Calculate how many "likely" files remain (for hint)
                var likely_remaining: u32 = 0;
                if (quarantine_config.threshold == .high) {
                    for (state.suspicious_files.items) |file| {
                        if (!file.is_definitely) {
                            likely_remaining += 1;
                        }
                    }
                }

                // Print quarantine summary
                const threshold_name = if (quarantine_config.threshold == .high) "high" else "all";
                try output.printQuarantineSummary(
                    quarantine_result,
                    threshold_name,
                    likely_remaining,
                    writer,
                );
            } else {
                std.debug.print("❌ Quarantine cancelled.\n", .{});
            }
        }
    }

    // Write to result.txt
    try fs.cwd().writeFile(.{ .sub_path = "result.txt", .data = state.output_buffer.items });
    std.debug.print("\n✅ Results written to result.txt\n", .{});
}

// ============================================================================
// Test Discovery
// ============================================================================
// This ensures all tests from imported modules are discovered and run

test {
    std.testing.refAllDeclsRecursive(@This());
}
