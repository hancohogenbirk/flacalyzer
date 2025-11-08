const std = @import("std");
const mem = std.mem;
const types = @import("types.zig");
const analysis = @import("analysis.zig");

const c = types.c;
const DecoderContext = types.DecoderContext;
const FlacAnalysis = types.FlacAnalysis;

/// Metadata callback for FLAC decoder
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

/// Write callback for FLAC decoder - collects audio samples
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

/// Error callback for FLAC decoder
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

/// Analyze a FLAC file for transcoding artifacts
pub fn analyzeFlac(allocator: mem.Allocator, path: []const u8) !FlacAnalysis {
    var result = FlacAnalysis.init(path);

    const decoder = c.FLAC__stream_decoder_new() orelse {
        result.error_msg = "Failed to create decoder";
        return result;
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
        result.error_msg = "Failed to initialize decoder";
        return result;
    }

    if (c.FLAC__stream_decoder_process_until_end_of_metadata(decoder) == 0) {
        result.error_msg = "Failed to process metadata";
        return result;
    }

    // Process audio data for spectral analysis
    _ = c.FLAC__stream_decoder_process_until_end_of_stream(decoder);

    if (ctx.has_error) {
        result.error_msg = "Decoder error during processing";
        return result;
    }

    result.is_valid_flac = true;
    result.sample_rate = ctx.sample_rate;
    result.bits_per_sample = ctx.bits_per_sample;
    result.channels = ctx.channels;
    result.total_samples = ctx.total_samples;

    // Perform spectral analysis
    if (ctx.samples.items.len > 0) {
        const spectrum_result = try analysis.analyzeSpectrum(allocator, ctx.samples.items, ctx.sample_rate);
        result.frequency_cutoff = spectrum_result[0];
        result.transcoding_confidence = spectrum_result[1];
        result.confidence_value = spectrum_result[2];
        result.band_analysis = spectrum_result[3];
        result.spectral_flatness = spectrum_result[4];

        // Perform bit depth validation
        const bit_depth_result = analysis.analyzeBitDepth(ctx.samples.items, ctx.bits_per_sample);
        result.bit_depth_valid = bit_depth_result[0];
        result.actual_bit_depth = bit_depth_result[1];

        // Perform histogram analysis
        const histogram_result = analysis.analyzeHistogram(ctx.samples.items, ctx.bits_per_sample);
        result.histogram_suspicious = histogram_result[0];
        result.histogram_score = histogram_result[1];

        // Check if band analysis is suspicious
        result.bands_suspicious = result.band_analysis.suspicious_score > 0.7;

        // Check if spectral flatness is suspicious
        result.flatness_suspicious = result.spectral_flatness < 0.03 and result.spectral_flatness > 0.0;

        // Use supporting evidence only when spectral analysis is already suspicious
        if (result.histogram_suspicious and result.transcoding_confidence != .not_transcoded) {
            result.confidence_value = @min(1.0, result.confidence_value + (result.histogram_score * 0.3));

            if (result.transcoding_confidence == .likely_transcoded and result.histogram_score > 0.8) {
                result.transcoding_confidence = .definitely_transcoded;
            }
        }

        // Band analysis as supporting evidence
        if (result.bands_suspicious and result.transcoding_confidence != .not_transcoded) {
            result.confidence_value = @min(1.0, result.confidence_value + (result.band_analysis.suspicious_score * 0.4));

            if (result.transcoding_confidence == .likely_transcoded and result.band_analysis.suspicious_score > 0.8) {
                result.transcoding_confidence = .definitely_transcoded;
            }
        }

        // Spectral flatness as supporting evidence
        if (result.flatness_suspicious and result.transcoding_confidence != .not_transcoded) {
            const flatness_contribution = (0.03 - result.spectral_flatness) / 0.03;
            result.confidence_value = @min(1.0, result.confidence_value + (flatness_contribution * 0.5));

            if (result.transcoding_confidence == .likely_transcoded and result.spectral_flatness < 0.015) {
                result.transcoding_confidence = .definitely_transcoded;
            }
        }
    }

    return result;
}

