const std = @import("std");
const mem = std.mem;
const quarantine = @import("quarantine.zig");

/// Configuration parsed from command-line arguments
pub const Config = struct {
    search_path: []const u8,
    num_threads: u32,
    quarantine_config: quarantine.QuarantineConfig,
};

/// Parse command-line arguments and return configuration
pub fn parseArgs(allocator: mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var search_path: []const u8 = ".";
    var num_threads: u32 = 0; // 0 = auto-detect
    var quarantine_config = quarantine.QuarantineConfig{
        .enabled = false,
        .target_dir = "",
        .threshold = .all,
    };

    var threshold_set = false;
    var quarantine_dir: []const u8 = "";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (mem.eql(u8, arg, "--threads") or mem.eql(u8, arg, "-j")) {
            if (i + 1 < args.len) {
                num_threads = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    std.debug.print("Invalid thread count: {s}\n", .{args[i + 1]});
                    return error.InvalidArgument;
                };
                i += 1;
            }
        } else if (mem.eql(u8, arg, "--quarantine") or mem.eql(u8, arg, "-q")) {
            quarantine_config.enabled = true;
            // Check if next arg exists and is not a flag
            if (i + 1 < args.len and !mem.startsWith(u8, args[i + 1], "-")) {
                quarantine_dir = args[i + 1];
                i += 1;
            }
            // If no directory specified, will default to <search_path>/quarantine later
        } else if (mem.eql(u8, arg, "--threshold") or mem.eql(u8, arg, "-t")) {
            threshold_set = true;
            if (i + 1 < args.len) {
                if (mem.eql(u8, args[i + 1], "high")) {
                    quarantine_config.threshold = .high;
                } else if (mem.eql(u8, args[i + 1], "all")) {
                    quarantine_config.threshold = .all;
                } else {
                    std.debug.print("Invalid threshold: {s} (use 'high' or 'all')\n", .{args[i + 1]});
                    return error.InvalidArgument;
                }
                i += 1;
            }
        } else if (!mem.startsWith(u8, arg, "-")) {
            search_path = arg;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.debug.print("Use -h or --help for usage information\n", .{});
            return error.InvalidArgument;
        }
    }

    // Validate flag dependencies
    if (threshold_set and !quarantine_config.enabled) {
        std.debug.print("Error: --threshold/-t requires --quarantine/-q to be specified\n", .{});
        std.debug.print("Use -h or --help for usage information\n", .{});
        return error.InvalidArgument;
    }

    // Duplicate strings to avoid use-after-free when args is freed
    const search_path_copy = try allocator.dupe(u8, search_path);

    // If quarantine is enabled but no directory specified, default to <search_path>/quarantine
    const quarantine_dir_copy = if (quarantine_config.enabled) blk: {
        if (quarantine_dir.len == 0) {
            // Default to search_path/quarantine
            const fs = @import("std").fs;
            break :blk try fs.path.join(allocator, &[_][]const u8{ search_path, "quarantine" });
        } else {
            break :blk try allocator.dupe(u8, quarantine_dir);
        }
    } else "";

    quarantine_config.target_dir = quarantine_dir_copy;

    return Config{
        .search_path = search_path_copy,
        .num_threads = num_threads,
        .quarantine_config = quarantine_config,
    };
}

fn printHelp() void {
    std.debug.print(
        \\
        \\🎵 FLAC Lossless Analyzer - Detect transcoded FLAC files
        \\
        \\USAGE:
        \\    flacalyzer [OPTIONS] [PATH]
        \\
        \\OPTIONS:
        \\    -h, --help                     Display this help message and exit
        \\    -j, --threads <N>              Number of worker threads (default: auto-detect CPU count)
        \\    -q, --quarantine [DIR]         Move suspicious files to directory (default: <path>/quarantine)
        \\    -t, --threshold <LEVEL>        Quarantine threshold: 'all' (default) or 'high' (only definitely transcoded)
        \\
        \\ARGUMENTS:
        \\    PATH                           Directory to scan for FLAC files (default: current directory)
        \\
        \\EXAMPLES:
        \\    # Analyze current directory with auto-detected CPU cores
        \\    flacalyzer
        \\
        \\    # Analyze specific directory with 8 threads
        \\    flacalyzer /path/to/music -j 8
        \\
        \\    # Quarantine to default folder (creates /music/quarantine)
        \\    flacalyzer /music -q
        \\
        \\    # Quarantine to custom directory
        \\    flacalyzer /music -q ./suspicious
        \\
        \\    # Quarantine only definitely transcoded files
        \\    flacalyzer /music -q --threshold high
        \\
        \\DETECTION METHODS:
        \\    • FFT Spectral Analysis - frequency cutoffs from lossy codecs
        \\    • Bit Depth Validation - upsampled lower bit depth detection
        \\    • Histogram Analysis - quantization pattern detection
        \\    • Frequency Band Analysis - energy distribution anomalies
        \\    • Spectral Flatness - spectrum structure analysis
        \\
        \\For more information: https://github.com/hancohogenbirk/flacalyzer
        \\
    , .{});
}
