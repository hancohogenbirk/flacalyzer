const std = @import("std");
const mem = std.mem;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
const types = @import("types.zig");
const flac_decoder = @import("flac_decoder.zig");

const SuspiciousFile = types.SuspiciousFile;

/// Thread-safe shared state for parallel processing
pub const SharedAnalysisState = struct {
    allocator: mem.Allocator,
    mutex: Mutex,

    // Counters (protected by mutex)
    total_files: u32,
    valid_lossless: u32,
    definitely_transcoded: u32,
    likely_transcoded: u32,
    invalid_flac: u32,

    // Results collection
    suspicious_files: std.ArrayList(SuspiciousFile),
    output_buffer: std.ArrayList(u8),

    // Atomic progress counter (lock-free)
    files_processed: Atomic(u32),
    total_flac_count: u32,

    pub fn init(allocator: mem.Allocator, total_count: u32) SharedAnalysisState {
        return SharedAnalysisState{
            .allocator = allocator,
            .mutex = Mutex{},
            .total_files = 0,
            .valid_lossless = 0,
            .definitely_transcoded = 0,
            .likely_transcoded = 0,
            .invalid_flac = 0,
            .suspicious_files = .empty,
            .output_buffer = .empty,
            .files_processed = Atomic(u32).init(0),
            .total_flac_count = total_count,
        };
    }

    pub fn deinit(self: *SharedAnalysisState) void {
        for (self.suspicious_files.items) |file| {
            self.allocator.free(file.path);
        }
        self.suspicious_files.deinit(self.allocator);
        self.output_buffer.deinit(self.allocator);
    }
};

/// Work queue for distributing files to threads
pub const WorkQueue = struct {
    allocator: mem.Allocator,
    mutex: Mutex,
    files: std.ArrayList([]const u8),
    next_index: usize,

    pub fn init(allocator: mem.Allocator) WorkQueue {
        return WorkQueue{
            .allocator = allocator,
            .mutex = Mutex{},
            .files = .empty,
            .next_index = 0,
        };
    }

    pub fn deinit(self: *WorkQueue) void {
        for (self.files.items) |path| {
            self.allocator.free(path);
        }
        self.files.deinit(self.allocator);
    }

    pub fn addFile(self: *WorkQueue, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const path_copy = try self.allocator.dupe(u8, path);
        try self.files.append(self.allocator, path_copy);
    }

    pub fn getNextFile(self: *WorkQueue) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.next_index >= self.files.items.len) {
            return null;
        }

        const file = self.files.items[self.next_index];
        self.next_index += 1;
        return file;
    }

    pub fn getTotalFiles(self: *WorkQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.files.items.len;
    }
};

/// Worker thread context
pub const WorkerContext = struct {
    allocator: mem.Allocator,
    queue: *WorkQueue,
    state: *SharedAnalysisState,
};

/// Worker thread function - processes files from the queue
pub fn workerThread(ctx: WorkerContext) void {
    while (ctx.queue.getNextFile()) |file_path| {
        // Analyze the file
        const analysis = flac_decoder.analyzeFlac(ctx.allocator, file_path) catch |err| {
            // Handle error
            ctx.state.mutex.lock();
            ctx.state.invalid_flac += 1;
            ctx.state.mutex.unlock();

            const writer = ctx.state.output_buffer.writer(ctx.allocator);
            ctx.state.mutex.lock();
            writer.print("✗ {s} - Error: {}\n", .{ file_path, err }) catch {};
            ctx.state.mutex.unlock();

            _ = ctx.state.files_processed.fetchAdd(1, .monotonic);
            continue;
        };

        if (analysis.is_valid_flac) {
            ctx.state.mutex.lock();
            defer ctx.state.mutex.unlock();

            const writer = ctx.state.output_buffer.writer(ctx.allocator);

            switch (analysis.transcoding_confidence) {
                .definitely_transcoded => {
                    ctx.state.definitely_transcoded += 1;
                    ctx.state.suspicious_files.append(ctx.allocator, SuspiciousFile{
                        .path = ctx.allocator.dupe(u8, analysis.path) catch "",
                        .sample_rate = analysis.sample_rate,
                        .bits_per_sample = analysis.bits_per_sample,
                        .channels = analysis.channels,
                        .cutoff = analysis.frequency_cutoff,
                        .confidence = analysis.confidence_value,
                        .is_definitely = true,
                        .bit_depth_valid = analysis.bit_depth_valid,
                        .actual_bit_depth = analysis.actual_bit_depth,
                        .histogram_suspicious = analysis.histogram_suspicious,
                        .histogram_score = analysis.histogram_score,
                        .bands_suspicious = analysis.bands_suspicious,
                        .band_analysis = analysis.band_analysis,
                        .spectral_flatness = analysis.spectral_flatness,
                        .flatness_suspicious = analysis.flatness_suspicious,
                    }) catch {};
                },
                .likely_transcoded => {
                    ctx.state.likely_transcoded += 1;
                    ctx.state.suspicious_files.append(ctx.allocator, SuspiciousFile{
                        .path = ctx.allocator.dupe(u8, analysis.path) catch "",
                        .sample_rate = analysis.sample_rate,
                        .bits_per_sample = analysis.bits_per_sample,
                        .channels = analysis.channels,
                        .cutoff = analysis.frequency_cutoff,
                        .confidence = analysis.confidence_value,
                        .is_definitely = false,
                        .bit_depth_valid = analysis.bit_depth_valid,
                        .actual_bit_depth = analysis.actual_bit_depth,
                        .histogram_suspicious = analysis.histogram_suspicious,
                        .histogram_score = analysis.histogram_score,
                        .bands_suspicious = analysis.bands_suspicious,
                        .band_analysis = analysis.band_analysis,
                        .spectral_flatness = analysis.spectral_flatness,
                        .flatness_suspicious = analysis.flatness_suspicious,
                    }) catch {};
                },
                .not_transcoded => {
                    ctx.state.valid_lossless += 1;
                },
            }

            const status = switch (analysis.transcoding_confidence) {
                .definitely_transcoded => "❌ TRANSCODED",
                .likely_transcoded => "⚠️  SUSPICIOUS",
                .not_transcoded => "✓ LOSSLESS",
            };

            writer.print("{s} {s} [{}Hz, {}bit, {}ch, cutoff: {d:.1}kHz]", .{
                status,
                analysis.path,
                analysis.sample_rate,
                analysis.bits_per_sample,
                analysis.channels,
                analysis.frequency_cutoff / 1000.0,
            }) catch {};

            if (analysis.confidence_value > 0.0) {
                writer.print(" (confidence: {d:.1}%)", .{analysis.confidence_value * 100.0}) catch {};
            }

            if (!analysis.bit_depth_valid) {
                writer.print(" ⚠️ FAKE {d}-BIT (actually {d}-bit)", .{ analysis.bits_per_sample, analysis.actual_bit_depth }) catch {};
            }

            if (analysis.histogram_suspicious) {
                writer.print(" ⚠️ QUANTIZED (histogram score: {d:.0}%)", .{analysis.histogram_score * 100.0}) catch {};
            }

            writer.print("\n", .{}) catch {};
        } else {
            ctx.state.mutex.lock();
            defer ctx.state.mutex.unlock();

            ctx.state.invalid_flac += 1;
            const err_msg = analysis.error_msg orelse "Unknown error";
            const writer = ctx.state.output_buffer.writer(ctx.allocator);
            writer.print("✗ {s} - {s}\n", .{ analysis.path, err_msg }) catch {};
        }

        _ = ctx.state.files_processed.fetchAdd(1, .monotonic);
    }
}

