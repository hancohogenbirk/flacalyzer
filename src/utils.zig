const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const parallel = @import("parallel.zig");

const WorkQueue = parallel.WorkQueue;

/// Check if a file is a FLAC file based on extension
pub fn isFlacFile(path: []const u8) bool {
    if (path.len < 5) return false;
    const ext = path[path.len - 5 ..];
    return mem.eql(u8, ext, ".flac") or mem.eql(u8, ext, ".FLAC");
}

/// Count total FLAC files in a directory (recursive)
pub fn countFlacFiles(allocator: mem.Allocator, path: []const u8) u32 {
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

/// Collect FLAC file paths into work queue (recursive)
pub fn collectFlacFiles(allocator: mem.Allocator, path: []const u8, queue: *WorkQueue) !void {
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const expect = testing.expect;

test "isFlacFile: recognizes lowercase .flac extension" {
    try expect(isFlacFile("song.flac"));
    try expect(isFlacFile("path/to/music.flac"));
    try expect(isFlacFile("/absolute/path/audio.flac"));
}

test "isFlacFile: recognizes uppercase .FLAC extension" {
    try expect(isFlacFile("SONG.FLAC"));
    try expect(isFlacFile("path/to/MUSIC.FLAC"));
}

test "isFlacFile: rejects non-FLAC files" {
    try expect(!isFlacFile("song.mp3"));
    try expect(!isFlacFile("audio.wav"));
    try expect(!isFlacFile("music.ogg"));
    try expect(!isFlacFile("file.txt"));
    try expect(!isFlacFile("noextension"));
}

test "isFlacFile: handles edge cases" {
    try expect(!isFlacFile(""));
    try expect(!isFlacFile("flac"));
    try expect(!isFlacFile(".fla"));
    try expect(!isFlacFile("test.flac.bak"));
}

test "isFlacFile: minimum length requirements" {
    try expect(!isFlacFile("a.fl")); // Too short
    try expect(isFlacFile("a.flac")); // Exactly minimum length
}

