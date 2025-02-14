const std = @import("std");

const p = @import("ini.zig");

pub fn main() !void {
    const HTTPConfig = struct {
        port: ?u16,
        host: []const u8,
    };

    const DatabaseType = enum {
        postgres,
        mysql,
    };

    const DatabaseConfig = struct {
        type: DatabaseType,
        host: []const u8,
        port: u16,
        database: []const u8,
        user: []const u8,
        password: []const u8,
    };

    const WebConfig = struct {
        name: []const u8,
        HTTP: HTTPConfig,
        Database: DatabaseConfig,
    };
    const init = WebConfig{
        .name = "dropped duck",
        .HTTP = HTTPConfig{
            .port = 0,
            .host = "0",
        },
        .Database = DatabaseConfig{
            .type = DatabaseType.mysql,
            .host = "localhost",
            .port = 5432,
            .database = "zig",
            .user = "mlemmer",
            .password = "zigisfun",
        },
    };

    const ini_file = try std.fs.cwd().openFile("src/WebServer.ini", .{});
    const reader = ini_file.reader();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const result: WebConfig = try p.parseWithDefaultValues(allocator, WebConfig, init, reader, .{});

    const writer = std.io.getStdOut().writer();
    try std.json.stringify(result, .{ .whitespace = .indent_4 }, writer);
    try writer.writeByte('\n');
}
