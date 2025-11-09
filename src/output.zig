const std = @import("std");
const types = @import("types.zig");
const parallel = @import("parallel.zig");

const SuspiciousFile = types.SuspiciousFile;
const SharedAnalysisState = parallel.SharedAnalysisState;

/// Print to both writer and console
fn printBoth(writer: anytype, comptime fmt: []const u8, args_tuple: anytype) !void {
    try writer.print(fmt, args_tuple);
    std.debug.print(fmt, args_tuple);
}

/// Print summary statistics
pub fn printSummary(
    state: *SharedAnalysisState,
    writer: anytype,
    elapsed_s: f64,
) !void {
    try printBoth(writer, "\n═══════════════════════════════════════\n", .{});
    try printBoth(writer, "📊 Summary:\n", .{});
    try printBoth(writer, "   Total FLAC files found: {}\n", .{state.total_files});
    try printBoth(writer, "   Valid lossless FLAC: {}\n", .{state.valid_lossless});
    try printBoth(writer, "   Definitely transcoded: {}\n", .{state.definitely_transcoded});
    try printBoth(writer, "   Likely transcoded: {}\n", .{state.likely_transcoded});
    try printBoth(writer, "   Invalid/Corrupted: {}\n", .{state.invalid_flac});
    try printBoth(writer, "   Analysis time: {d:.2}s ({d:.1} files/sec)\n", .{
        elapsed_s,
        @as(f64, @floatFromInt(state.total_files)) / elapsed_s,
    });
    try printBoth(writer, "═══════════════════════════════════════\n", .{});
}

/// Print detailed information about suspicious files
pub fn printSuspiciousFiles(
    suspicious_files: []const SuspiciousFile,
    writer: anytype,
) !void {
    if (suspicious_files.len == 0) return;

    try printBoth(writer, "\n⚠️  Suspicious/Transcoded Files:\n", .{});

    for (suspicious_files) |file| {
        const type_str = if (file.is_definitely) "DEFINITELY TRANSCODED" else "LIKELY TRANSCODED";
        try printBoth(writer, "\n   [{s}] {s}\n", .{ type_str, file.path });
        try printBoth(writer, "      Sample rate: {}Hz, Bit depth: {}bit, Channels: {}\n", .{
            file.sample_rate,
            file.bits_per_sample,
            file.channels,
        });
        try printBoth(writer, "      Overall Confidence: {d:.1}%\n\n", .{file.confidence * 100.0});

        // Detailed diagnostic breakdown
        try printBoth(writer, "      🔍 Diagnostic Details:\n", .{});

        // Spectral Analysis
        const expected_cutoff = @as(f64, @floatFromInt(file.sample_rate)) / 2.0;
        const cutoff_loss = expected_cutoff - file.cutoff;
        const cutoff_loss_pct = (cutoff_loss / expected_cutoff) * 100.0;
        const cutoff_status = if (cutoff_loss_pct > 10.0) "❌ FAIL" else if (cutoff_loss_pct > 5.0) "⚠️ WARN" else "✓ PASS";
        try printBoth(writer, "         • Spectral Analysis: {s}\n", .{cutoff_status});
        try printBoth(writer, "           - Frequency cutoff: {d:.1}kHz (expected: ~{d:.1}kHz)\n", .{
            file.cutoff / 1000.0,
            expected_cutoff / 1000.0,
        });
        try printBoth(writer, "           - Missing high frequencies: {d:.1}kHz ({d:.1}%)\n", .{
            cutoff_loss / 1000.0,
            cutoff_loss_pct,
        });

        // Bit Depth Validation
        if (!file.bit_depth_valid) {
            try printBoth(writer, "         • Bit Depth Validation: ❌ FAIL\n", .{});
            try printBoth(writer, "           - Claims: {d}-bit, Actually: {d}-bit\n", .{
                file.bits_per_sample,
                file.actual_bit_depth,
            });
            try printBoth(writer, "           - Issue: Upsampled/padded lower bit depth audio\n", .{});
        } else {
            try printBoth(writer, "         • Bit Depth Validation: ✓ PASS\n", .{});
            try printBoth(writer, "           - Genuine {d}-bit audio detected\n", .{file.bits_per_sample});
        }

        // Histogram Analysis
        if (file.histogram_suspicious) {
            try printBoth(writer, "         • Histogram Analysis: ⚠️ SUSPICIOUS\n", .{});
            try printBoth(writer, "           - Suspicion score: {d:.1}%\n", .{file.histogram_score * 100.0});
            try printBoth(writer, "           - Issue: Non-uniform sample distribution (quantization patterns)\n", .{});
        } else {
            const histogram_msg = if (file.histogram_score > 0.0) "✓ PASS" else "⊘ NOT EVALUATED";
            try printBoth(writer, "         • Histogram Analysis: {s}\n", .{histogram_msg});
            if (file.histogram_score > 0.0) {
                try printBoth(writer, "           - Sample distribution looks natural\n", .{});
            }
        }

        // Frequency Band Analysis
        const band_status = if (file.bands_suspicious) "⚠️ SUSPICIOUS" else "✓ PASS";
        try printBoth(writer, "         • Frequency Band Analysis: {s}\n", .{band_status});
        if (file.bands_suspicious) {
            try printBoth(writer, "           - Suspicion score: {d:.1}%\n", .{file.band_analysis.suspicious_score * 100.0});
            try printBoth(writer, "           - High band rolloff: {d:.1}% (energy drop from mid to high)\n", .{file.band_analysis.high_band_rolloff * 100.0});
            try printBoth(writer, "           - Issue: Excessive high frequency attenuation (lossy codec filtering)\n", .{});
        } else {
            try printBoth(writer, "           - Low band: {d:.4}, Mid band: {d:.4}, High band: {d:.4}\n", .{
                file.band_analysis.low_band_energy,
                file.band_analysis.mid_band_energy,
                file.band_analysis.high_band_energy,
            });
            try printBoth(writer, "           - High band rolloff: {d:.1}% (normal range)\n", .{file.band_analysis.high_band_rolloff * 100.0});
        }

        // Spectral Flatness Measurement
        const flatness_status = if (file.flatness_suspicious) "⚠️ SUSPICIOUS" else "✓ PASS";
        try printBoth(writer, "         • Spectral Flatness: {s}\n", .{flatness_status});
        if (file.spectral_flatness > 0.0) {
            try printBoth(writer, "           - Flatness value: {d:.4} ", .{file.spectral_flatness});
            if (file.flatness_suspicious) {
                try printBoth(writer, "(low - structured spectrum)\n", .{});
                try printBoth(writer, "           - Issue: Highly structured spectrum typical of lossy codec artifacts\n", .{});
            } else {
                try printBoth(writer, "(normal - natural spectrum)\n", .{});
            }
        } else {
            try printBoth(writer, "           - Not calculated\n", .{});
        }
    }
    try printBoth(writer, "\n", .{});
}

/// Print analysis method notes
pub fn printMethodNotes(writer: anytype) !void {
    try printBoth(writer, "\n💡 Note: Transcoding detection uses multiple analysis methods:\n", .{});
    try printBoth(writer, "   1. FFT Spectral Analysis - detects frequency cutoffs from lossy codecs\n", .{});
    try printBoth(writer, "   2. Bit Depth Validation - detects upsampled lower bit depth files\n", .{});
    try printBoth(writer, "   3. Histogram Analysis - detects quantization patterns in sample distribution\n", .{});
    try printBoth(writer, "   4. Frequency Band Analysis - detects energy distribution anomalies across bands\n", .{});
    try printBoth(writer, "   5. Spectral Flatness - measures spectrum structure (noise-like vs tone-like)\n", .{});
}

/// Print quarantine operation summary
pub fn printQuarantineSummary(
    quarantine_result: anytype,
    threshold_name: []const u8,
    likely_remaining: u32,
    writer: anytype,
) !void {
    try writer.print("\n🗂️  Quarantine Summary:\n", .{});
    try writer.print("   ✅ Quarantined {} file{s}\n", .{
        quarantine_result.moved_count,
        if (quarantine_result.moved_count == 1) "" else "s",
    });

    if (quarantine_result.moved_count > 0 and quarantine_result.moved_files.items.len > 0) {
        const max_display = 10;
        const count = @min(quarantine_result.moved_files.items.len, max_display);

        for (quarantine_result.moved_files.items[0..count]) |path| {
            try writer.print("   ✓ {s}\n", .{path});
        }

        if (quarantine_result.moved_files.items.len > max_display) {
            try writer.print("   ... and {} more\n", .{quarantine_result.moved_files.items.len - max_display});
        }
    }

    if (quarantine_result.skipped_count > 0) {
        try writer.print("   ⊘ Skipped {} file{s} (already in quarantine)\n", .{
            quarantine_result.skipped_count,
            if (quarantine_result.skipped_count == 1) "" else "s",
        });
    }

    if (quarantine_result.failed_count > 0) {
        try writer.print("   ✗ Failed to move {} file{s} (check permissions)\n", .{
            quarantine_result.failed_count,
            if (quarantine_result.failed_count == 1) "" else "s",
        });
    }

    // Hint about threshold if using 'high' and there are likely transcoded files
    if (std.mem.eql(u8, threshold_name, "high") and likely_remaining > 0) {
        try writer.print("\n   💡 Use --threshold all to quarantine {} more \"LIKELY transcoded\" file{s}\n", .{
            likely_remaining,
            if (likely_remaining == 1) "" else "s",
        });
    }
}
