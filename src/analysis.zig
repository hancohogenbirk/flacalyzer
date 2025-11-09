const std = @import("std");
const mem = std.mem;
const math = std.math;
const types = @import("types.zig");

const Complex = types.Complex;
const BandAnalysisResult = types.BandAnalysisResult;

/// Perform Fast Fourier Transform (Cooley-Tukey algorithm)
pub fn fft(allocator: mem.Allocator, input: []const f64, output: []Complex) !void {
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

/// Analyze sample value distribution to detect lossy compression artifacts
pub fn analyzeHistogram(samples: []const f64, bits_per_sample: u32) struct { bool, f64 } {
    _ = bits_per_sample; // Reserved for future use
    if (samples.len < 10000) return .{ false, 0.0 };

    // Create a simplified histogram by binning sample values
    const num_bins: usize = 256;
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
    var gap_lengths = [_]u32{0} ** 32;
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

    // Look for periodic patterns in gap lengths
    var max_gap_pattern: u32 = 0;
    for (gap_lengths) |pattern_count| {
        if (pattern_count > max_gap_pattern) {
            max_gap_pattern = pattern_count;
        }
    }

    if (max_gap_pattern > 5) {
        comb_score = @as(f64, @floatFromInt(max_gap_pattern)) / 10.0;
    }

    // Score calculation
    var suspicion_score: f64 = 0.0;
    if (gappiness > 0.50) suspicion_score += 0.3;
    if (gappiness > 0.60) suspicion_score += 0.2;
    if (coefficient_of_variation > 2.5) suspicion_score += 0.2;
    if (comb_score > 0.5) suspicion_score += 0.3;

    const is_suspicious = suspicion_score > 0.7;
    return .{ is_suspicious, suspicion_score };
}

/// Analyze bit depth validity by checking least significant bits
pub fn analyzeBitDepth(samples: []const f64, claimed_bits: u32) struct { bool, u32 } {
    if (samples.len == 0) return .{ true, claimed_bits };
    if (claimed_bits <= 16) return .{ true, claimed_bits };

    // For 24-bit audio, check if lower 8 bits are actually used
    var used_lower_bits: u32 = 0;
    var samples_checked: u32 = 0;
    const check_limit: usize = @min(samples.len, 50000);

    for (samples[0..check_limit]) |sample| {
        const int_sample = @as(i32, @intFromFloat(sample));
        const lower_8_bits = @abs(int_sample) & 0xFF;

        if (lower_8_bits != 0) {
            used_lower_bits += 1;
        }
        samples_checked += 1;
    }

    const usage_ratio = @as(f64, @floatFromInt(used_lower_bits)) / @as(f64, @floatFromInt(samples_checked));

    // If less than 1% of samples use the lower 8 bits, it's likely upscaled 16-bit
    if (usage_ratio < 0.01) {
        return .{ false, 16 };
    }

    // Check for 20-bit or other intermediate depths
    if (usage_ratio < 0.10 and claimed_bits == 24) {
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
            return .{ false, 20 };
        }
    }

    return .{ true, claimed_bits };
}

/// Analyze frequency bands to detect lossy codec patterns
pub fn analyzeFrequencyBands(magnitude: []const f64, sample_rate: u32) BandAnalysisResult {
    const nyquist = @as(f64, @floatFromInt(sample_rate)) / 2.0;
    const num_bins = magnitude.len;
    const hz_per_bin = nyquist / @as(f64, @floatFromInt(num_bins));

    // Define band boundaries proportionally to sample rate for proper scaling
    // This ensures the bands scale correctly for all sample rates (44.1, 48, 96, 192 kHz)
    // Low: 0 - ~11% of Nyquist (bass frequencies)
    // Mid: ~11% - ~68% of Nyquist (midrange where lossy codecs typically cut)
    // High: ~68% - 100% of Nyquist (treble, most affected by lossy encoding)
    const low_cutoff = nyquist * 0.227; // ~11% of sample rate (5kHz @ 44.1kHz, 10.9kHz @ 96kHz)
    const mid_cutoff = nyquist * 0.68;  // ~34% of sample rate (15kHz @ 44.1kHz, 32.6kHz @ 96kHz)

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

    // Calculate high band rolloff
    const high_band_rolloff = if (mid_avg > 0.0)
        1.0 - (high_avg / mid_avg)
    else
        0.0;

    // Suspicion scoring
    var suspicion_score: f64 = 0.0;
    if (high_band_rolloff > 0.85) suspicion_score += 0.4;
    if (high_band_rolloff > 0.95) suspicion_score += 0.3;

    const total_energy = low_band_energy + mid_band_energy + high_band_energy;
    const high_ratio = if (total_energy > 0.0) high_band_energy / total_energy else 0.0;

    if (high_ratio < 0.05) suspicion_score += 0.2;
    if (high_ratio < 0.02) suspicion_score += 0.2;

    return BandAnalysisResult{
        .low_band_energy = low_avg,
        .mid_band_energy = mid_avg,
        .high_band_energy = high_avg,
        .high_band_rolloff = high_band_rolloff,
        .suspicious_score = suspicion_score,
    };
}

/// Calculate spectral flatness (Wiener entropy)
pub fn calculateSpectralFlatness(magnitude: []const f64) struct { f64, bool } {
    if (magnitude.len == 0) return .{ 0.0, false };

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
    const is_suspicious = flatness < 0.03;

    return .{ flatness, is_suspicious };
}

/// Perform complete spectral analysis on audio samples
pub fn analyzeSpectrum(
    allocator: mem.Allocator,
    samples: []const f64,
    sample_rate: u32,
) !struct { f64, types.TranscodingConfidence, f64, BandAnalysisResult, f64 } {
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

    const confidence = types.TranscodingConfidence.fromAnalysis(cutoff_frequency, sample_rate, energy_dropoff);

    // Calculate confidence value
    const cutoff_ratio = cutoff_frequency / nyquist;
    var conf_val: f64 = 0.0;
    if (cutoff_ratio < 0.85) conf_val += 0.3;
    if (cutoff_ratio < 0.75) conf_val += 0.3;
    if (energy_dropoff > 0.7) conf_val += 0.4;

    return .{ cutoff_frequency, confidence, conf_val, band_result, spectral_flatness };
}

