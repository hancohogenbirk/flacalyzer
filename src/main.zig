const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const math = std.math;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;

// We'll use Zig's C interop to use libFLAC
// Link with: -lFLAC -lm
const c = @cImport({
    @cInclude("FLAC/stream_decoder.h");
    @cInclude("FLAC/metadata.h");
    @cInclude("math.h");
});

const BandAnalysisResult = struct {
    low_band_energy: f64, // 0-5 kHz
    mid_band_energy: f64, // 5-15 kHz
    high_band_energy: f64, // 15 kHz - Nyquist
    high_band_rolloff: f64, // How much energy drops off in high band
    suspicious_score: f64, // Overall suspiciousness (0-1)
};

const TranscodingConfidence = enum {
    not_transcoded,
    likely_transcoded,
    definitely_transcoded,

    fn fromAnalysis(cutoff_hz: f64, sample_rate: u32, energy_dropoff: f64) TranscodingConfidence {
        const nyquist = @as(f64, @floatFromInt(sample_rate)) / 2.0;
        const cutoff_ratio = cutoff_hz / nyquist;

        var confidence: f64 = 0.0;

        // If cutoff is below 85% of Nyquist, suspicious
        if (cutoff_ratio < 0.85) confidence += 0.3;

        // If cutoff is below 75% of Nyquist, very suspicious
        if (cutoff_ratio < 0.75) confidence += 0.3;

        // Sharp energy dropoff indicates brick-wall filtering
        if (energy_dropoff > 0.7) confidence += 0.4;

        if (confidence > 0.8) {
            return .definitely_transcoded;
        } else if (confidence > 0.4) {
            return .likely_transcoded;
        } else {
            return .not_transcoded;
        }
    }
};

const FlacAnalysis = struct {
    path: []const u8,
    is_valid_flac: bool,
    sample_rate: u32,
    bits_per_sample: u32,
    channels: u32,
    total_samples: u64,
    frequency_cutoff: f64,
    transcoding_confidence: TranscodingConfidence,
    confidence_value: f64,
    error_msg: ?[]const u8,
    bit_depth_valid: bool,
    actual_bit_depth: u32,
    histogram_suspicious: bool,
    histogram_score: f64,
    bands_suspicious: bool,
    band_analysis: BandAnalysisResult,
    spectral_flatness: f64,
    flatness_suspicious: bool,

    fn init(path: []const u8) FlacAnalysis {
        return FlacAnalysis{
            .path = path,
            .is_valid_flac = false,
            .sample_rate = 0,
            .bits_per_sample = 0,
            .channels = 0,
            .total_samples = 0,
            .frequency_cutoff = 0.0,
            .transcoding_confidence = .not_transcoded,
            .confidence_value = 0.0,
            .error_msg = null,
            .bit_depth_valid = true,
            .actual_bit_depth = 0,
            .histogram_suspicious = false,
            .histogram_score = 0.0,
            .bands_suspicious = false,
            .band_analysis = BandAnalysisResult{
                .low_band_energy = 0.0,
                .mid_band_energy = 0.0,
                .high_band_energy = 0.0,
                .high_band_rolloff = 0.0,
                .suspicious_score = 0.0,
            },
            .spectral_flatness = 0.0,
            .flatness_suspicious = false,
        };
    }
};

const DecoderContext = struct {
    sample_rate: u32 = 0,
    bits_per_sample: u32 = 0,
    channels: u32 = 0,
    total_samples: u64 = 0,
    has_error: bool = false,
    samples: std.ArrayList(f64),
    samples_to_collect: u32 = 100_000,
    blocks_to_skip: u32 = 5,

    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator) DecoderContext {
        return DecoderContext{
            .allocator = allocator,
            .samples = .empty,
        };
    }

    fn deinit(self: *DecoderContext) void {
        self.samples.deinit(self.allocator);
    }
};

fn metadataCallback(
    decoder: ?*const c.FLAC__StreamDecoder,
    metadata: [*c]const c.FLAC__StreamMetadata,
    client_data: ?*anyopaque,
) callconv(.c) void {
    _ = decoder;
    const ctx = @as(*DecoderContext, @ptrCast(@alignCast(client_data)));

    if (metadata.*.type == c.FLAC__METADATA_TYPE_STREAMINFO) {
        const info = metadata.*.data.stream_info;
        ctx.sample_rate = info.sample_rate;
        ctx.bits_per_sample = info.bits_per_sample;
        ctx.channels = info.channels;
        ctx.total_samples = info.total_samples;
    }
}

fn writeCallback(
    decoder: ?*const c.FLAC__StreamDecoder,
    frame: [*c]const c.FLAC__Frame,
    buffer: [*c]const [*c]const c.FLAC__int32,
    client_data: ?*anyopaque,
) callconv(.c) c.FLAC__StreamDecoderWriteStatus {
    _ = decoder;
    const ctx = @as(*DecoderContext, @ptrCast(@alignCast(client_data)));

    // Skip first few blocks
    if (ctx.blocks_to_skip > 0) {
        ctx.blocks_to_skip -= 1;
        return c.FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
    }

    // Collect samples for FFT analysis
    if (ctx.samples.items.len >= ctx.samples_to_collect) {
        return c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }

    const blocksize = frame.*.header.blocksize;

    var i: u32 = 0;
    while (i < blocksize and ctx.samples.items.len < ctx.samples_to_collect) : (i += 1) {
        // Use left channel (or first channel)
        const sample = buffer[0][i];
        ctx.samples.append(ctx.allocator, @as(f64, @floatFromInt(sample))) catch break;
    }

    return c.FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

fn errorCallback(
    decoder: ?*const c.FLAC__StreamDecoder,
    status: c.FLAC__StreamDecoderErrorStatus,
    client_data: ?*anyopaque,
) callconv(.c) void {
    _ = decoder;
    _ = status;
    const ctx = @as(*DecoderContext, @ptrCast(@alignCast(client_data)));
    ctx.has_error = true;
}

// Simple FFT implementation (Cooley-Tukey algorithm)
const Complex = struct {
    real: f64,
    imag: f64,

    fn init(r: f64, i: f64) Complex {
        return Complex{ .real = r, .imag = i };
    }

    fn add(self: Complex, other: Complex) Complex {
        return Complex.init(self.real + other.real, self.imag + other.imag);
    }

    fn sub(self: Complex, other: Complex) Complex {
        return Complex.init(self.real - other.real, self.imag - other.imag);
    }

    fn mul(self: Complex, other: Complex) Complex {
        return Complex.init(
            self.real * other.real - self.imag * other.imag,
            self.real * other.imag + self.imag * other.real,
        );
    }

    fn magnitude(self: Complex) f64 {
        return @sqrt(self.real * self.real + self.imag * self.imag);
    }
};

fn fft(allocator: mem.Allocator, input: []const f64, output: []Complex) !void {
    const n = input.len;

    // Apply Hann window
    for (input, 0..) |sample, i| {
        const window = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))));
        output[i] = Complex.init(sample * window, 0.0);
    }

    // Bit-reversal permutation
    var j: usize = 0;
    for (0..n - 1) |i| {
        if (i < j) {
            const temp = output[i];
            output[i] = output[j];
            output[j] = temp;
        }
        var m = n / 2;
        while (m >= 1 and j >= m) {
            j -= m;
            m /= 2;
        }
        j += m;
    }

    // FFT computation
    var len: usize = 2;
    while (len <= n) : (len *= 2) {
        const angle = -2.0 * math.pi / @as(f64, @floatFromInt(len));
        const wlen = Complex.init(@cos(angle), @sin(angle));

        var i: usize = 0;
        while (i < n) : (i += len) {
            var w = Complex.init(1.0, 0.0);

            var j_inner: usize = 0;
            while (j_inner < len / 2) : (j_inner += 1) {
                const u = output[i + j_inner];
                const v = w.mul(output[i + j_inner + len / 2]);
                output[i + j_inner] = u.add(v);
                output[i + j_inner + len / 2] = u.sub(v);
                w = w.mul(wlen);
            }
        }
    }

    _ = allocator;
}

// Analyze sample value distribution to detect lossy compression
fn analyzeHistogram(samples: []const f64, bits_per_sample: u32) struct { bool, f64 } {
    _ = bits_per_sample; // Reserved for future use
    if (samples.len < 10000) return .{ false, 0.0 };

    // Create a simplified histogram by binning sample values
    // Lossy codecs create gaps and non-uniform distributions
    const num_bins: usize = 256; // Use 256 bins for analysis
    var histogram = [_]u32{0} ** num_bins;

    // Find min and max to normalize
    var min_val: f64 = samples[0];
    var max_val: f64 = samples[0];
    for (samples) |sample| {
        if (sample < min_val) min_val = sample;
        if (sample > max_val) max_val = sample;
    }

    const range = max_val - min_val;
    if (range == 0) return .{ false, 0.0 };

    // Fill histogram
    const check_limit: usize = @min(samples.len, 50000);
    for (samples[0..check_limit]) |sample| {
        const normalized = (sample - min_val) / range;
        const bin = @min(@as(usize, @intFromFloat(normalized * @as(f64, @floatFromInt(num_bins - 1)))), num_bins - 1);
        histogram[bin] += 1;
    }

    // Analyze histogram for lossy compression patterns
    var empty_bins: u32 = 0;
    var populated_bins: u32 = 0;
    var max_bin_count: u32 = 0;

    for (histogram) |count| {
        if (count == 0) {
            empty_bins += 1;
        } else {
            populated_bins += 1;
            if (count > max_bin_count) max_bin_count = count;
        }
    }

    // Calculate "gappiness" - lossy codecs create gaps in the distribution
    const gappiness = @as(f64, @floatFromInt(empty_bins)) / @as(f64, @floatFromInt(num_bins));

    // Calculate variance in bin populations (uniformity check)
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    for (histogram) |count| {
        const val = @as(f64, @floatFromInt(count));
        sum += val;
        sum_sq += val * val;
    }
    const mean = sum / @as(f64, @floatFromInt(num_bins));
    const variance = (sum_sq / @as(f64, @floatFromInt(num_bins))) - (mean * mean);
    const std_dev = @sqrt(variance);
    const coefficient_of_variation = if (mean > 0) std_dev / mean else 0;

    // Detect "comb filtering" pattern - periodic gaps in histogram
    var comb_score: f64 = 0.0;
    var prev_empty = false;
    var gap_lengths = [_]u32{0} ** 32; // Track gap length patterns
    var current_gap_len: u32 = 0;

    for (histogram) |count| {
        const is_empty = count == 0;
        if (is_empty) {
            current_gap_len += 1;
        } else {
            if (prev_empty and current_gap_len > 0 and current_gap_len < gap_lengths.len) {
                gap_lengths[current_gap_len] += 1;
            }
            current_gap_len = 0;
        }
        prev_empty = is_empty;
    }

    // Look for periodic patterns in gap lengths (sign of quantization)
    var max_gap_pattern: u32 = 0;
    for (gap_lengths) |pattern_count| {
        if (pattern_count > max_gap_pattern) {
            max_gap_pattern = pattern_count;
        }
    }

    if (max_gap_pattern > 5) {
        comb_score = @as(f64, @floatFromInt(max_gap_pattern)) / 10.0;
    }

    // Score calculation (made more conservative to avoid false positives):
    // - High gappiness (>50%) is suspicious
    // - Very high coefficient of variation indicates non-uniform distribution
    // - Strong comb patterns are very suspicious
    var suspicion_score: f64 = 0.0;

    // More aggressive thresholds to reduce false positives
    if (gappiness > 0.50) suspicion_score += 0.3;
    if (gappiness > 0.60) suspicion_score += 0.2;
    if (coefficient_of_variation > 2.5) suspicion_score += 0.2;
    if (comb_score > 0.5) suspicion_score += 0.3;

    // Require higher score to flag as suspicious (70% instead of 40%)
    const is_suspicious = suspicion_score > 0.7;

    return .{ is_suspicious, suspicion_score };
}

// Analyze bit depth validity by checking least significant bits
fn analyzeBitDepth(samples: []const f64, claimed_bits: u32) struct { bool, u32 } {
    if (samples.len == 0) return .{ true, claimed_bits };
    if (claimed_bits <= 16) return .{ true, claimed_bits }; // Only validate 24-bit files

    // For 24-bit audio, check if lower 8 bits are actually used
    // If it's upscaled 16-bit, the lower 8 bits will be mostly zeros
    var used_lower_bits: u32 = 0;
    var samples_checked: u32 = 0;
    const check_limit: usize = @min(samples.len, 50000);

    for (samples[0..check_limit]) |sample| {
        // Convert float back to integer representation
        const int_sample = @as(i32, @intFromFloat(sample));

        // Check the lower 8 bits (for 24-bit vs 16-bit detection)
        const lower_8_bits = @abs(int_sample) & 0xFF;

        // If lower bits are non-zero, they're being used
        if (lower_8_bits != 0) {
            used_lower_bits += 1;
        }
        samples_checked += 1;
    }

    const usage_ratio = @as(f64, @floatFromInt(used_lower_bits)) / @as(f64, @floatFromInt(samples_checked));

    // If less than 1% of samples use the lower 8 bits, it's likely upscaled 16-bit
    if (usage_ratio < 0.01) {
        return .{ false, 16 }; // False 24-bit, actually 16-bit
    }

    // Check for 20-bit or other intermediate depths
    if (usage_ratio < 0.10 and claimed_bits == 24) {
        // Might be 20-bit padded to 24-bit
        var used_lower_4_bits: u32 = 0;
        for (samples[0..check_limit]) |sample| {
            const int_sample = @as(i32, @intFromFloat(sample));
            const lower_4_bits = @abs(int_sample) & 0x0F;
            if (lower_4_bits != 0) {
                used_lower_4_bits += 1;
            }
        }
        const usage_4bit = @as(f64, @floatFromInt(used_lower_4_bits)) / @as(f64, @floatFromInt(samples_checked));
        if (usage_4bit < 0.01) {
            return .{ false, 20 }; // Likely 20-bit
        }
    }

    return .{ true, claimed_bits };
}

// Analyze frequency bands to detect lossy codec patterns
// Divides spectrum into low, mid, and high bands and measures energy distribution
fn analyzeFrequencyBands(magnitude: []const f64, sample_rate: u32) BandAnalysisResult {
    const nyquist = @as(f64, @floatFromInt(sample_rate)) / 2.0;
    const num_bins = magnitude.len;
    const hz_per_bin = nyquist / @as(f64, @floatFromInt(num_bins));

    // Define band boundaries
    const low_cutoff = 5000.0; // 0-5 kHz (bass)
    const mid_cutoff = 15000.0; // 5-15 kHz (mids)
    // high band is 15 kHz to Nyquist (highs/treble)

    var low_band_energy: f64 = 0.0;
    var mid_band_energy: f64 = 0.0;
    var high_band_energy: f64 = 0.0;

    var low_band_count: u32 = 0;
    var mid_band_count: u32 = 0;
    var high_band_count: u32 = 0;

    for (magnitude, 0..) |mag, i| {
        const freq = @as(f64, @floatFromInt(i)) * hz_per_bin;

        if (freq < low_cutoff) {
            low_band_energy += mag;
            low_band_count += 1;
        } else if (freq < mid_cutoff) {
            mid_band_energy += mag;
            mid_band_count += 1;
        } else {
            high_band_energy += mag;
            high_band_count += 1;
        }
    }

    // Calculate average energy per bin for each band
    const low_avg = if (low_band_count > 0) low_band_energy / @as(f64, @floatFromInt(low_band_count)) else 0.0;
    const mid_avg = if (mid_band_count > 0) mid_band_energy / @as(f64, @floatFromInt(mid_band_count)) else 0.0;
    const high_avg = if (high_band_count > 0) high_band_energy / @as(f64, @floatFromInt(high_band_count)) else 0.0;

    // Calculate high band rolloff (how much energy drops from mid to high)
    const high_band_rolloff = if (mid_avg > 0.0)
        1.0 - (high_avg / mid_avg)
    else
        0.0;

    // Suspicion scoring
    var suspicion_score: f64 = 0.0;

    // High frequency bands should have *some* energy in lossless files
    // Severe rolloff indicates lossy codec filtering
    if (high_band_rolloff > 0.85) suspicion_score += 0.4; // >85% rolloff is very suspicious
    if (high_band_rolloff > 0.95) suspicion_score += 0.3; // >95% rolloff is extremely suspicious

    // Very low high band energy relative to total is suspicious
    const total_energy = low_band_energy + mid_band_energy + high_band_energy;
    const high_ratio = if (total_energy > 0.0) high_band_energy / total_energy else 0.0;

    if (high_ratio < 0.05) suspicion_score += 0.2; // <5% of total energy in high band
    if (high_ratio < 0.02) suspicion_score += 0.2; // <2% is very suspicious

    return BandAnalysisResult{
        .low_band_energy = low_avg,
        .mid_band_energy = mid_avg,
        .high_band_energy = high_avg,
        .high_band_rolloff = high_band_rolloff,
        .suspicious_score = suspicion_score,
    };
}

// Calculate spectral flatness (Wiener entropy)
// Measures how "noise-like" vs "tone-like" the spectrum is
// High flatness (close to 1.0) = noise-like (natural, lossless)
// Low flatness (close to 0.0) = tone-like (structured, potentially lossy-coded)
fn calculateSpectralFlatness(magnitude: []const f64) struct { f64, bool } {
    if (magnitude.len == 0) return .{ 0.0, false };

    // Focus on meaningful frequencies (skip DC and very low bins)
    const start_bin: usize = 5;
    if (magnitude.len <= start_bin) return .{ 0.0, false };

    const relevant_bins = magnitude[start_bin..];

    // Calculate arithmetic mean
    var arithmetic_sum: f64 = 0.0;
    var count: u32 = 0;

    for (relevant_bins) |mag| {
        if (mag > 0.0) {
            arithmetic_sum += mag;
            count += 1;
        }
    }

    if (count == 0) return .{ 0.0, false };
    const arithmetic_mean = arithmetic_sum / @as(f64, @floatFromInt(count));

    // Calculate geometric mean (using log-space to avoid underflow)
    var log_sum: f64 = 0.0;
    for (relevant_bins) |mag| {
        if (mag > 0.0) {
            log_sum += @log(mag);
        }
    }
    const log_mean = log_sum / @as(f64, @floatFromInt(count));
    const geometric_mean = @exp(log_mean);

    // Spectral flatness = geometric_mean / arithmetic_mean
    const flatness = if (arithmetic_mean > 0.0) geometric_mean / arithmetic_mean else 0.0;

    // Lossy codecs tend to have lower spectral flatness, especially in high frequencies
    // Typical lossless audio: flatness > 0.05 (varies by content)
    // Lossy transcoded: flatness < 0.03 (more structured/peaky spectrum)
    const is_suspicious = flatness < 0.03;

    return .{ flatness, is_suspicious };
}

fn analyzeSpectrum(allocator: mem.Allocator, samples: []const f64, sample_rate: u32) !struct { f64, TranscodingConfidence, f64, BandAnalysisResult, f64 } {
    const fft_size: usize = 8192;
    const hop_size: usize = fft_size / 2;

    if (samples.len < fft_size) {
        return .{ 0.0, .not_transcoded, 0.0, BandAnalysisResult{
            .low_band_energy = 0.0,
            .mid_band_energy = 0.0,
            .high_band_energy = 0.0,
            .high_band_rolloff = 0.0,
            .suspicious_score = 0.0,
        }, 0.0 };
    }

    var avg_magnitude = try allocator.alloc(f64, fft_size / 2);
    defer allocator.free(avg_magnitude);
    @memset(avg_magnitude, 0.0);

    var fft_buffer = try allocator.alloc(Complex, fft_size);
    defer allocator.free(fft_buffer);

    var num_ffts: u32 = 0;
    var i: usize = 0;

    while (i + fft_size <= samples.len) : (i += hop_size) {
        const chunk = samples[i .. i + fft_size];

        try fft(allocator, chunk, fft_buffer);

        for (fft_buffer[0 .. fft_size / 2], 0..) |sample, idx| {
            avg_magnitude[idx] += sample.magnitude();
        }

        num_ffts += 1;
    }

    if (num_ffts == 0) {
        return .{ 0.0, .not_transcoded, 0.0, BandAnalysisResult{
            .low_band_energy = 0.0,
            .mid_band_energy = 0.0,
            .high_band_energy = 0.0,
            .high_band_rolloff = 0.0,
            .suspicious_score = 0.0,
        }, 0.0 };
    }

    // Average magnitudes
    for (avg_magnitude) |*mag| {
        mag.* /= @as(f64, @floatFromInt(num_ffts));
    }

    // Find maximum magnitude
    var max_magnitude: f64 = 0.0;
    for (avg_magnitude) |mag| {
        if (mag > max_magnitude) max_magnitude = mag;
    }

    const threshold = max_magnitude * 0.03; // -30dB
    const freq_resolution = @as(f64, @floatFromInt(sample_rate)) / @as(f64, @floatFromInt(fft_size));
    const nyquist = @as(f64, @floatFromInt(sample_rate)) / 2.0;

    // Find cutoff frequency
    var cutoff_bin: usize = fft_size / 2 - 1;
    var found_cutoff = false;

    const start_bin: usize = (fft_size / 2) * 6 / 10;

    var bin_idx = fft_size / 2 - 1;
    while (bin_idx >= start_bin) : (bin_idx -= 1) {
        if (avg_magnitude[bin_idx] > threshold) {
            cutoff_bin = bin_idx;
            found_cutoff = true;
            break;
        }
        if (bin_idx == start_bin) break;
    }

    const cutoff_frequency = @as(f64, @floatFromInt(cutoff_bin)) * freq_resolution;

    // Measure energy dropoff
    const dropoff_range: usize = 20;
    var energy_dropoff: f64 = 0.0;

    if (cutoff_bin > dropoff_range and cutoff_bin < fft_size / 2 - dropoff_range) {
        var before_energy: f64 = 0.0;
        for (avg_magnitude[cutoff_bin - dropoff_range .. cutoff_bin]) |mag| {
            before_energy += mag;
        }
        before_energy /= @as(f64, @floatFromInt(dropoff_range));

        var after_energy: f64 = 0.0;
        for (avg_magnitude[cutoff_bin .. cutoff_bin + dropoff_range]) |mag| {
            after_energy += mag;
        }
        after_energy /= @as(f64, @floatFromInt(dropoff_range));

        if (before_energy > 0.0) {
            energy_dropoff = 1.0 - (after_energy / before_energy);
        }
    }

    // Perform band analysis
    const band_result = analyzeFrequencyBands(avg_magnitude, sample_rate);

    // Calculate spectral flatness
    const flatness_result = calculateSpectralFlatness(avg_magnitude);
    const spectral_flatness = flatness_result[0];

    if (!found_cutoff or cutoff_frequency > nyquist * 0.95) {
        return .{ cutoff_frequency, .not_transcoded, 0.0, band_result, spectral_flatness };
    }

    const confidence = TranscodingConfidence.fromAnalysis(cutoff_frequency, sample_rate, energy_dropoff);

    // Calculate confidence value
    const cutoff_ratio = cutoff_frequency / nyquist;
    var conf_val: f64 = 0.0;
    if (cutoff_ratio < 0.85) conf_val += 0.3;
    if (cutoff_ratio < 0.75) conf_val += 0.3;
    if (energy_dropoff > 0.7) conf_val += 0.4;

    return .{ cutoff_frequency, confidence, conf_val, band_result, spectral_flatness };
}

fn analyzeFlac(allocator: mem.Allocator, path: []const u8) !FlacAnalysis {
    var analysis = FlacAnalysis.init(path);

    const decoder = c.FLAC__stream_decoder_new() orelse {
        analysis.error_msg = "Failed to create decoder";
        return analysis;
    };
    defer c.FLAC__stream_decoder_delete(decoder);

    var ctx = DecoderContext.init(allocator);
    defer ctx.deinit();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const init_status = c.FLAC__stream_decoder_init_file(
        decoder,
        path_z.ptr,
        writeCallback,
        metadataCallback,
        errorCallback,
        &ctx,
    );

    if (init_status != c.FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        analysis.error_msg = "Failed to initialize decoder";
        return analysis;
    }

    if (c.FLAC__stream_decoder_process_until_end_of_metadata(decoder) == 0) {
        analysis.error_msg = "Failed to process metadata";
        return analysis;
    }

    // Process audio data for spectral analysis
    _ = c.FLAC__stream_decoder_process_until_end_of_stream(decoder);

    if (ctx.has_error) {
        analysis.error_msg = "Decoder error during processing";
        return analysis;
    }

    analysis.is_valid_flac = true;
    analysis.sample_rate = ctx.sample_rate;
    analysis.bits_per_sample = ctx.bits_per_sample;
    analysis.channels = ctx.channels;
    analysis.total_samples = ctx.total_samples;

    // Perform spectral analysis
    if (ctx.samples.items.len > 0) {
        const result = try analyzeSpectrum(allocator, ctx.samples.items, ctx.sample_rate);
        analysis.frequency_cutoff = result[0];
        analysis.transcoding_confidence = result[1];
        analysis.confidence_value = result[2];
        analysis.band_analysis = result[3];
        analysis.spectral_flatness = result[4];

        // Perform bit depth validation
        const bit_depth_result = analyzeBitDepth(ctx.samples.items, ctx.bits_per_sample);
        analysis.bit_depth_valid = bit_depth_result[0];
        analysis.actual_bit_depth = bit_depth_result[1];

        // Perform histogram analysis
        const histogram_result = analyzeHistogram(ctx.samples.items, ctx.bits_per_sample);
        analysis.histogram_suspicious = histogram_result[0];
        analysis.histogram_score = histogram_result[1];

        // Check if band analysis is suspicious (use as supporting evidence)
        analysis.bands_suspicious = analysis.band_analysis.suspicious_score > 0.7;

        // Check if spectral flatness is suspicious
        // Low flatness (<0.03) indicates highly structured spectrum typical of lossy codecs
        analysis.flatness_suspicious = analysis.spectral_flatness < 0.03 and analysis.spectral_flatness > 0.0;

        // Only use histogram and band analysis as SUPPORTING evidence when spectral analysis is already suspicious
        // This prevents false positives from natural audio characteristics
        if (analysis.histogram_suspicious and analysis.transcoding_confidence != .not_transcoded) {
            // Histogram analysis adds confidence only if spectral analysis already found issues
            analysis.confidence_value = @min(1.0, analysis.confidence_value + (analysis.histogram_score * 0.3));

            // Upgrade confidence level only if BOTH methods strongly agree
            if (analysis.transcoding_confidence == .likely_transcoded and analysis.histogram_score > 0.8) {
                analysis.transcoding_confidence = .definitely_transcoded;
            }
        }

        // Band analysis as supporting evidence - more aggressive than histogram
        if (analysis.bands_suspicious and analysis.transcoding_confidence != .not_transcoded) {
            analysis.confidence_value = @min(1.0, analysis.confidence_value + (analysis.band_analysis.suspicious_score * 0.4));

            // Upgrade if band analysis strongly indicates transcoding
            if (analysis.transcoding_confidence == .likely_transcoded and analysis.band_analysis.suspicious_score > 0.8) {
                analysis.transcoding_confidence = .definitely_transcoded;
            }
        }

        // Spectral flatness as supporting evidence - strong indicator
        if (analysis.flatness_suspicious and analysis.transcoding_confidence != .not_transcoded) {
            // Very low flatness is a strong indicator of lossy codec artifacts
            const flatness_contribution = (0.03 - analysis.spectral_flatness) / 0.03; // 0.0 to 1.0
            analysis.confidence_value = @min(1.0, analysis.confidence_value + (flatness_contribution * 0.5));

            // Upgrade if flatness is very low
            if (analysis.transcoding_confidence == .likely_transcoded and analysis.spectral_flatness < 0.015) {
                analysis.transcoding_confidence = .definitely_transcoded;
            }
        }
    }

    return analysis;
}

const SuspiciousFile = struct {
    path: []const u8,
    sample_rate: u32,
    bits_per_sample: u32,
    channels: u32,
    cutoff: f64,
    confidence: f64,
    is_definitely: bool,
    // Diagnostic information
    bit_depth_valid: bool,
    actual_bit_depth: u32,
    histogram_suspicious: bool,
    histogram_score: f64,
    bands_suspicious: bool,
    band_analysis: BandAnalysisResult,
    spectral_flatness: f64,
    flatness_suspicious: bool,
};

// Thread-safe shared state for parallel processing
const SharedAnalysisState = struct {
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

    fn init(allocator: mem.Allocator, total_count: u32) SharedAnalysisState {
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

    fn deinit(self: *SharedAnalysisState) void {
        for (self.suspicious_files.items) |file| {
            self.allocator.free(file.path);
        }
        self.suspicious_files.deinit(self.allocator);
        self.output_buffer.deinit(self.allocator);
    }
};

// Work queue for distributing files to threads
const WorkQueue = struct {
    allocator: mem.Allocator,
    mutex: Mutex,
    files: std.ArrayList([]const u8),
    next_index: usize,

    fn init(allocator: mem.Allocator) WorkQueue {
        return WorkQueue{
            .allocator = allocator,
            .mutex = Mutex{},
            .files = .empty,
            .next_index = 0,
        };
    }

    fn deinit(self: *WorkQueue) void {
        for (self.files.items) |path| {
            self.allocator.free(path);
        }
        self.files.deinit(self.allocator);
    }

    fn addFile(self: *WorkQueue, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const path_copy = try self.allocator.dupe(u8, path);
        try self.files.append(self.allocator, path_copy);
    }

    fn getNextFile(self: *WorkQueue) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.next_index >= self.files.items.len) {
            return null;
        }

        const file = self.files.items[self.next_index];
        self.next_index += 1;
        return file;
    }

    fn getTotalFiles(self: *WorkQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.files.items.len;
    }
};

// Worker thread context
const WorkerContext = struct {
    allocator: mem.Allocator,
    queue: *WorkQueue,
    state: *SharedAnalysisState,
};

// Worker thread function
fn workerThread(ctx: WorkerContext) void {
    while (ctx.queue.getNextFile()) |file_path| {
        // Analyze the file
        const analysis = analyzeFlac(ctx.allocator, file_path) catch |err| {
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

fn isFlacFile(path: []const u8) bool {
    if (path.len < 5) return false;
    const ext = path[path.len - 5 ..];
    return mem.eql(u8, ext, ".flac") or mem.eql(u8, ext, ".FLAC");
}

fn countFlacFiles(allocator: mem.Allocator, path: []const u8) u32 {
    var count: u32 = 0;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return count;
    defer dir.close();

    var iterator = dir.iterate();
    while (iterator.next() catch return count) |entry| {
        const entry_path = fs.path.join(allocator, &[_][]const u8{ path, entry.name }) catch continue;
        defer allocator.free(entry_path);

        switch (entry.kind) {
            .file => {
                if (isFlacFile(entry.name)) {
                    count += 1;
                }
            },
            .directory => {
                if (!mem.eql(u8, entry.name, ".") and !mem.eql(u8, entry.name, "..")) {
                    count += countFlacFiles(allocator, entry_path);
                }
            },
            else => {},
        }
    }

    return count;
}

// Collect FLAC file paths into work queue
fn collectFlacFiles(allocator: mem.Allocator, path: []const u8, queue: *WorkQueue) !void {
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory {s}: {}\n", .{ path, err });
        return;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const entry_path = try fs.path.join(allocator, &[_][]const u8{ path, entry.name });
        defer allocator.free(entry_path);

        switch (entry.kind) {
            .file => {
                if (isFlacFile(entry.name)) {
                    try queue.addFile(entry_path);
                }
            },
            .directory => {
                if (!mem.eql(u8, entry.name, ".") and !mem.eql(u8, entry.name, "..")) {
                    try collectFlacFiles(allocator, entry_path, queue);
                }
            },
            else => {},
        }
    }
}

fn walkDirectory(
    allocator: mem.Allocator,
    path: []const u8,
    total_files: *u32,
    valid_lossless: *u32,
    definitely_transcoded: *u32,
    likely_transcoded: *u32,
    invalid_flac: *u32,
    suspicious_files: *std.ArrayList(SuspiciousFile),
    output_writer: anytype,
    total_flac_count: u32,
) !void {
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open directory {s}: {}\n", .{ path, err });
        return;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const entry_path = try fs.path.join(allocator, &[_][]const u8{ path, entry.name });
        defer allocator.free(entry_path);

        switch (entry.kind) {
            .file => {
                if (isFlacFile(entry.name)) {
                    total_files.* += 1;

                    // Calculate percentage
                    const percentage = if (total_flac_count > 0)
                        (@as(f64, @floatFromInt(total_files.*)) / @as(f64, @floatFromInt(total_flac_count))) * 100.0
                    else
                        0.0;

                    // Show progress on console (will be overwritten)
                    const display_path = if (entry_path.len > 60)
                        entry_path[entry_path.len - 60 ..]
                    else
                        entry_path;
                    std.debug.print("\r🔍 [{d:3}/{d:3}] {d:5.1}% | {s}...", .{ total_files.*, total_flac_count, percentage, display_path });

                    const analysis = analyzeFlac(allocator, entry_path) catch |err| {
                        invalid_flac.* += 1;
                        try output_writer.print("✗ {s} - Error: {}\n", .{ entry_path, err });
                        continue;
                    };

                    if (analysis.is_valid_flac) {
                        const status = switch (analysis.transcoding_confidence) {
                            .definitely_transcoded => blk: {
                                definitely_transcoded.* += 1;
                                try suspicious_files.append(allocator, SuspiciousFile{
                                    .path = try allocator.dupe(u8, analysis.path),
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
                                });
                                break :blk "❌ TRANSCODED";
                            },
                            .likely_transcoded => blk: {
                                likely_transcoded.* += 1;
                                try suspicious_files.append(allocator, SuspiciousFile{
                                    .path = try allocator.dupe(u8, analysis.path),
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
                                });
                                break :blk "⚠️  SUSPICIOUS";
                            },
                            .not_transcoded => blk: {
                                valid_lossless.* += 1;
                                break :blk "✓ LOSSLESS";
                            },
                        };

                        try output_writer.print("{s} {s} [{}Hz, {}bit, {}ch, cutoff: {d:.1}kHz]", .{
                            status,
                            analysis.path,
                            analysis.sample_rate,
                            analysis.bits_per_sample,
                            analysis.channels,
                            analysis.frequency_cutoff / 1000.0,
                        });

                        if (analysis.confidence_value > 0.0) {
                            try output_writer.print(" (confidence: {d:.1}%)", .{analysis.confidence_value * 100.0});
                        }

                        // Show bit depth validation warning
                        if (!analysis.bit_depth_valid) {
                            try output_writer.print(" ⚠️ FAKE {d}-BIT (actually {d}-bit)", .{ analysis.bits_per_sample, analysis.actual_bit_depth });
                        }

                        // Show histogram analysis warning
                        if (analysis.histogram_suspicious) {
                            try output_writer.print(" ⚠️ QUANTIZED (histogram score: {d:.0}%)", .{analysis.histogram_score * 100.0});
                        }

                        try output_writer.print("\n", .{});
                    } else {
                        invalid_flac.* += 1;
                        const err_msg = analysis.error_msg orelse "Unknown error";
                        try output_writer.print("✗ {s} - {s}\n", .{ analysis.path, err_msg });
                    }
                }
            },
            .directory => {
                if (!mem.eql(u8, entry.name, ".") and !mem.eql(u8, entry.name, "..")) {
                    try walkDirectory(
                        allocator,
                        entry_path,
                        total_files,
                        valid_lossless,
                        definitely_transcoded,
                        likely_transcoded,
                        invalid_flac,
                        suspicious_files,
                        output_writer,
                        total_flac_count,
                    );
                }
            },
            else => {},
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments: [path] [--threads N]
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

    // Print to console
    std.debug.print("🎵 FLAC Lossless Analyzer with FFT Spectral Analysis (Zig Edition - Parallel)\n", .{});
    std.debug.print("Scanning directory: {s}\n", .{search_path});
    std.debug.print("Using {} worker threads\n", .{num_threads});

    // First, count total FLAC files
    std.debug.print("Counting FLAC files...\n", .{});
    const total_flac_count = countFlacFiles(allocator, search_path);
    std.debug.print("Found {} FLAC files to analyze\n", .{total_flac_count});

    if (total_flac_count == 0) {
        std.debug.print("No FLAC files found!\n", .{});
        return;
    }

    // Collect all file paths
    std.debug.print("Collecting file paths...\n", .{});
    var queue = WorkQueue.init(allocator);
    defer queue.deinit();

    try collectFlacFiles(allocator, search_path, &queue);
    std.debug.print("Collected {} files\n\n", .{queue.getTotalFiles()});

    // Initialize shared state
    var state = SharedAnalysisState.init(allocator, total_flac_count);
    defer state.deinit();

    // Write header to output buffer
    const output_writer = state.output_buffer.writer(allocator);
    try output_writer.print("🎵 FLAC Lossless Analyzer with FFT Spectral Analysis (Zig Edition - Parallel)\n", .{});
    try output_writer.print("Scanning directory: {s}\n", .{search_path});
    try output_writer.print("Using {} worker threads\n\n", .{num_threads});

    // Spawn worker threads
    const worker_ctx = WorkerContext{
        .allocator = allocator,
        .queue = &queue,
        .state = &state,
    };

    const threads = try allocator.alloc(Thread, num_threads);
    defer allocator.free(threads);

    const start_time = std.time.milliTimestamp();

    // Start workers
    for (threads) |*thread| {
        thread.* = try Thread.spawn(.{}, workerThread, .{worker_ctx});
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

    // Helper to print to both console and file
    const printBoth = struct {
        fn print(writer: anytype, comptime fmt: []const u8, args_tuple: anytype) !void {
            try writer.print(fmt, args_tuple);
            std.debug.print(fmt, args_tuple);
        }
    }.print;

    state.mutex.lock();
    state.total_files = state.valid_lossless + state.definitely_transcoded + state.likely_transcoded;
    state.mutex.unlock();

    try printBoth(output_writer, "\n═══════════════════════════════════════\n", .{});
    try printBoth(output_writer, "📊 Summary:\n", .{});
    try printBoth(output_writer, "   Total FLAC files found: {}\n", .{state.total_files});
    try printBoth(output_writer, "   Valid lossless FLAC: {}\n", .{state.valid_lossless});
    try printBoth(output_writer, "   Definitely transcoded: {}\n", .{state.definitely_transcoded});
    try printBoth(output_writer, "   Likely transcoded: {}\n", .{state.likely_transcoded});
    try printBoth(output_writer, "   Invalid/Corrupted: {}\n", .{state.invalid_flac});
    try printBoth(output_writer, "   Analysis time: {d:.2}s ({d:.1} files/sec)\n", .{ elapsed_s, @as(f64, @floatFromInt(state.total_files)) / elapsed_s });
    try printBoth(output_writer, "═══════════════════════════════════════\n", .{});

    // Print suspicious files details
    if (state.suspicious_files.items.len > 0) {
        try printBoth(output_writer, "\n⚠️  Suspicious/Transcoded Files:\n", .{});
        for (state.suspicious_files.items) |file| {
            const type_str = if (file.is_definitely) "DEFINITELY TRANSCODED" else "LIKELY TRANSCODED";
            try printBoth(output_writer, "\n   [{s}] {s}\n", .{ type_str, file.path });
            try printBoth(output_writer, "      Sample rate: {}Hz, Bit depth: {}bit, Channels: {}\n", .{ file.sample_rate, file.bits_per_sample, file.channels });
            try printBoth(output_writer, "      Overall Confidence: {d:.1}%\n\n", .{file.confidence * 100.0});

            // Detailed diagnostic breakdown
            try printBoth(output_writer, "      🔍 Diagnostic Details:\n", .{});

            // Spectral Analysis
            const expected_cutoff = @as(f64, @floatFromInt(file.sample_rate)) / 2.0;
            const cutoff_loss = expected_cutoff - file.cutoff;
            const cutoff_loss_pct = (cutoff_loss / expected_cutoff) * 100.0;
            const cutoff_status = if (cutoff_loss_pct > 10.0) "❌ FAIL" else if (cutoff_loss_pct > 5.0) "⚠️ WARN" else "✓ PASS";
            try printBoth(output_writer, "         • Spectral Analysis: {s}\n", .{cutoff_status});
            try printBoth(output_writer, "           - Frequency cutoff: {d:.1}kHz (expected: ~{d:.1}kHz)\n", .{ file.cutoff / 1000.0, expected_cutoff / 1000.0 });
            try printBoth(output_writer, "           - Missing high frequencies: {d:.1}kHz ({d:.1}%)\n", .{ cutoff_loss / 1000.0, cutoff_loss_pct });

            // Bit Depth Validation
            if (!file.bit_depth_valid) {
                try printBoth(output_writer, "         • Bit Depth Validation: ❌ FAIL\n", .{});
                try printBoth(output_writer, "           - Claims: {d}-bit, Actually: {d}-bit\n", .{ file.bits_per_sample, file.actual_bit_depth });
                try printBoth(output_writer, "           - Issue: Upsampled/padded lower bit depth audio\n", .{});
            } else {
                try printBoth(output_writer, "         • Bit Depth Validation: ✓ PASS\n", .{});
                try printBoth(output_writer, "           - Genuine {d}-bit audio detected\n", .{file.bits_per_sample});
            }

            // Histogram Analysis
            if (file.histogram_suspicious) {
                try printBoth(output_writer, "         • Histogram Analysis: ⚠️ SUSPICIOUS\n", .{});
                try printBoth(output_writer, "           - Suspicion score: {d:.1}%\n", .{file.histogram_score * 100.0});
                try printBoth(output_writer, "           - Issue: Non-uniform sample distribution (quantization patterns)\n", .{});
            } else {
                const histogram_msg = if (file.histogram_score > 0.0) "✓ PASS" else "⊘ NOT EVALUATED";
                try printBoth(output_writer, "         • Histogram Analysis: {s}\n", .{histogram_msg});
                if (file.histogram_score > 0.0) {
                    try printBoth(output_writer, "           - Sample distribution looks natural\n", .{});
                }
            }

            // Frequency Band Analysis
            const band_status = if (file.bands_suspicious) "⚠️ SUSPICIOUS" else "✓ PASS";
            try printBoth(output_writer, "         • Frequency Band Analysis: {s}\n", .{band_status});
            if (file.bands_suspicious) {
                try printBoth(output_writer, "           - Suspicion score: {d:.1}%\n", .{file.band_analysis.suspicious_score * 100.0});
                try printBoth(output_writer, "           - High band rolloff: {d:.1}% (energy drop from mid to high)\n", .{file.band_analysis.high_band_rolloff * 100.0});
                try printBoth(output_writer, "           - Issue: Excessive high frequency attenuation (lossy codec filtering)\n", .{});
            } else {
                try printBoth(output_writer, "           - Low band: {d:.4}, Mid band: {d:.4}, High band: {d:.4}\n", .{ file.band_analysis.low_band_energy, file.band_analysis.mid_band_energy, file.band_analysis.high_band_energy });
                try printBoth(output_writer, "           - High band rolloff: {d:.1}% (normal range)\n", .{file.band_analysis.high_band_rolloff * 100.0});
            }

            // Spectral Flatness Measurement
            const flatness_status = if (file.flatness_suspicious) "⚠️ SUSPICIOUS" else "✓ PASS";
            try printBoth(output_writer, "         • Spectral Flatness: {s}\n", .{flatness_status});
            if (file.spectral_flatness > 0.0) {
                try printBoth(output_writer, "           - Flatness value: {d:.4} ", .{file.spectral_flatness});
                if (file.flatness_suspicious) {
                    try printBoth(output_writer, "(low - structured spectrum)\n", .{});
                    try printBoth(output_writer, "           - Issue: Highly structured spectrum typical of lossy codec artifacts\n", .{});
                } else {
                    try printBoth(output_writer, "(normal - natural spectrum)\n", .{});
                }
            } else {
                try printBoth(output_writer, "           - Not calculated\n", .{});
            }
        }
        try printBoth(output_writer, "\n", .{});
    }

    try printBoth(output_writer, "\n💡 Note: Transcoding detection uses multiple analysis methods:\n", .{});
    try printBoth(output_writer, "   1. FFT Spectral Analysis - detects frequency cutoffs from lossy codecs\n", .{});
    try printBoth(output_writer, "   2. Bit Depth Validation - detects upsampled lower bit depth files\n", .{});
    try printBoth(output_writer, "   3. Histogram Analysis - detects quantization patterns in sample distribution\n", .{});
    try printBoth(output_writer, "   4. Frequency Band Analysis - detects energy distribution anomalies across bands\n", .{});
    try printBoth(output_writer, "   5. Spectral Flatness - measures spectrum structure (noise-like vs tone-like)\n", .{});

    // Write to result.txt
    try fs.cwd().writeFile(.{ .sub_path = "result.txt", .data = state.output_buffer.items });
    std.debug.print("\n✅ Results written to result.txt\n", .{});
}
