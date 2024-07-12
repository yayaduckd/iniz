const std = @import("std");

const p = @import("ini.zig");

pub fn main() !void {
    const Parser = p.Parser;

    const HTTPConfig = struct {
        port: u16,
        host: []const u8,
    };

    const DatabaseConfig = struct {
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

    // ini file in question

    // # Config for the HTTP Server
    // name = DuckDrop
    // [HTTP]
    // port = 8080
    // host = 0.0.0.0

    // [Database]
    // # DB Info
    // host = localhost
    // port = 5432
    // database = zig

    // # User Info
    // user = postgres
    // password = zigisfun

    const ini_file = try std.fs.cwd().openFile("src/WebServer.ini", .{});
    const reader = ini_file.reader();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const result = try Parser.parse(WebConfig, allocator, reader);

    const writer = std.io.getStdOut().writer();
    try std.json.stringify(result, .{ .whitespace = .indent_4 }, writer);
}
