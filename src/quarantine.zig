const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const types = @import("types.zig");

const SuspiciousFile = types.SuspiciousFile;

pub const QuarantineThreshold = enum {
    high, // Only "DEFINITELY transcoded"
    all, // Both "LIKELY" and "DEFINITELY"
};

pub const QuarantineConfig = struct {
    enabled: bool,
    target_dir: []const u8,
    threshold: QuarantineThreshold,
};

pub const QuarantineResult = struct {
    allocator: mem.Allocator,
    moved_count: u32,
    skipped_count: u32,
    failed_count: u32,
    moved_files: std.ArrayList([]const u8),
    skipped_files: std.ArrayList([]const u8),
    failed_files: std.ArrayList([]const u8),

    pub fn init(allocator: mem.Allocator) QuarantineResult {
        return .{
            .allocator = allocator,
            .moved_count = 0,
            .skipped_count = 0,
            .failed_count = 0,
            .moved_files = .empty,
            .skipped_files = .empty,
            .failed_files = .empty,
        };
    }

    pub fn deinit(self: *QuarantineResult) void {
        for (self.moved_files.items) |file| {
            self.allocator.free(file);
        }
        self.moved_files.deinit(self.allocator);

        for (self.skipped_files.items) |file| {
            self.allocator.free(file);
        }
        self.skipped_files.deinit(self.allocator);

        for (self.failed_files.items) |file| {
            self.allocator.free(file);
        }
        self.failed_files.deinit(self.allocator);
    }
};

/// Check if a file should be quarantined based on threshold
fn shouldQuarantine(is_definitely: bool, threshold: QuarantineThreshold) bool {
    return switch (threshold) {
        .high => is_definitely, // Only definitely transcoded
        .all => true, // All suspicious files (both likely and definitely)
    };
}

/// Get relative path by stripping base path
fn getRelativePath(original_path: []const u8, base_path: []const u8) []const u8 {
    // Handle trailing slashes in base_path
    var normalized_base = base_path;
    while (normalized_base.len > 0 and normalized_base[normalized_base.len - 1] == '/') {
        normalized_base = normalized_base[0 .. normalized_base.len - 1];
    }

    // Check if original path starts with base
    if (mem.startsWith(u8, original_path, normalized_base)) {
        var relative = original_path[normalized_base.len..];
        // Skip leading slashes
        while (relative.len > 0 and relative[0] == '/') {
            relative = relative[1..];
        }
        return relative;
    }

    // If no match, return just the filename (flat structure)
    return fs.path.basename(original_path);
}

/// Move a single file to quarantine directory
fn moveFileToQuarantine(
    allocator: mem.Allocator,
    original_path: []const u8,
    base_search_path: []const u8,
    quarantine_base: []const u8,
) ![]const u8 {
    // Get relative path from search directory
    const relative_path = getRelativePath(original_path, base_search_path);

    // Get directory part of relative path
    const relative_dir = fs.path.dirname(relative_path) orelse "";

    // Build quarantine directory path
    const quarantine_dir = if (relative_dir.len > 0)
        try fs.path.join(allocator, &[_][]const u8{ quarantine_base, relative_dir })
    else
        try allocator.dupe(u8, quarantine_base);
    defer allocator.free(quarantine_dir);

    // Get filename
    const filename = fs.path.basename(original_path);

    // Build full quarantine path
    const quarantine_path = try fs.path.join(allocator, &[_][]const u8{ quarantine_dir, filename });

    // Create directory structure (recursive)
    fs.cwd().makePath(quarantine_dir) catch |err| {
        std.debug.print("Failed to create directory {s}: {}\n", .{ quarantine_dir, err });
        return err;
    };

    // Check if file already exists
    if (fs.cwd().access(quarantine_path, .{})) {
        // File exists, skip
        return error.FileExists;
    } else |_| {
        // File doesn't exist, proceed with move
    }

    // Move file (rename)
    fs.cwd().rename(original_path, quarantine_path) catch |err| {
        std.debug.print("Failed to move {s} to {s}: {}\n", .{ original_path, quarantine_path, err });
        return err;
    };

    return quarantine_path;
}

/// Quarantine suspicious files based on configuration
pub fn quarantineFiles(
    allocator: mem.Allocator,
    suspicious_files: []const SuspiciousFile,
    base_search_path: []const u8,
    config: QuarantineConfig,
) !QuarantineResult {
    var result = QuarantineResult.init(allocator);

    if (!config.enabled) {
        return result;
    }

    // Create quarantine base directory if it doesn't exist
    fs.cwd().makePath(config.target_dir) catch |err| {
        std.debug.print("Failed to create quarantine base directory {s}: {}\n", .{ config.target_dir, err });
        return err;
    };

    for (suspicious_files) |file| {
        // Check if file meets threshold
        if (!shouldQuarantine(file.is_definitely, config.threshold)) {
            continue;
        }

        // Attempt to move file
        const quarantine_path = moveFileToQuarantine(
            allocator,
            file.path,
            base_search_path,
            config.target_dir,
        ) catch |err| {
            if (err == error.FileExists) {
                // File already exists in quarantine, skip
                result.skipped_count += 1;
                const path_copy = try result.allocator.dupe(u8, file.path);
                try result.skipped_files.append(result.allocator, path_copy);
            } else {
                // Other error, record as failed
                result.failed_count += 1;
                const path_copy = try result.allocator.dupe(u8, file.path);
                try result.failed_files.append(result.allocator, path_copy);
            }
            continue;
        };

        // Successfully moved (or would move in dry-run)
        result.moved_count += 1;
        try result.moved_files.append(result.allocator, quarantine_path);
    }

    return result;
}
