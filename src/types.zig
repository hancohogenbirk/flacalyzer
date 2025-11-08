const std = @import("std");
const mem = std.mem;

// C bindings for libFLAC
pub const c = @cImport({
    @cInclude("FLAC/stream_decoder.h");
    @cInclude("FLAC/metadata.h");
    @cInclude("math.h");
});

/// Result of frequency band energy analysis
pub const BandAnalysisResult = struct {
    low_band_energy: f64, // 0-5 kHz
    mid_band_energy: f64, // 5-15 kHz
    high_band_energy: f64, // 15 kHz - Nyquist
    high_band_rolloff: f64, // How much energy drops off in high band
    suspicious_score: f64, // Overall suspiciousness (0-1)
};

/// Confidence level for transcoding detection
pub const TranscodingConfidence = enum {
    not_transcoded,
    likely_transcoded,
    definitely_transcoded,

    pub fn fromAnalysis(cutoff_hz: f64, sample_rate: u32, energy_dropoff: f64) TranscodingConfidence {
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

/// Complete analysis result for a FLAC file
pub const FlacAnalysis = struct {
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

    pub fn init(path: []const u8) FlacAnalysis {
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

/// Suspicious file information for reporting
pub const SuspiciousFile = struct {
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

/// Context for FLAC decoder callbacks
pub const DecoderContext = struct {
    sample_rate: u32 = 0,
    bits_per_sample: u32 = 0,
    channels: u32 = 0,
    total_samples: u64 = 0,
    has_error: bool = false,
    samples: std.ArrayList(f64),
    samples_to_collect: u32 = 100_000,
    blocks_to_skip: u32 = 5,

    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) DecoderContext {
        return DecoderContext{
            .allocator = allocator,
            .samples = .empty,
        };
    }

    pub fn deinit(self: *DecoderContext) void {
        self.samples.deinit(self.allocator);
    }
};

/// Complex number for FFT calculations
pub const Complex = struct {
    real: f64,
    imag: f64,

    pub fn init(r: f64, i: f64) Complex {
        return Complex{ .real = r, .imag = i };
    }

    pub fn add(self: Complex, other: Complex) Complex {
        return Complex.init(self.real + other.real, self.imag + other.imag);
    }

    pub fn sub(self: Complex, other: Complex) Complex {
        return Complex.init(self.real - other.real, self.imag - other.imag);
    }

    pub fn mul(self: Complex, other: Complex) Complex {
        return Complex.init(
            self.real * other.real - self.imag * other.imag,
            self.real * other.imag + self.imag * other.real,
        );
    }

    pub fn magnitude(self: Complex) f64 {
        return @sqrt(self.real * self.real + self.imag * self.imag);
    }
};

