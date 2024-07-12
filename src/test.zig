const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const io = std.io;

const p = @import("ini.zig");

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

// Tests
test "web config test" {
    // try testing.expect(add(3, 7) == 10);

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
    const webconfig_ini_file = std.fs.cwd().openFile("src/WebServer.ini", .{}) catch unreachable;
    const webconfig_reader = webconfig_ini_file.reader();

    const alloc = testing.allocator;

    const initial = WebConfig{ .name = "dropped duck", .HTTP = HTTPConfig{
        .port = 9999,
        .host = "0",
    }, .Database = DatabaseConfig{
        .host = "c",
        .port = 1111,
        .database = "b",
        .user = "a",
        .password = "d",
    } };

    const result: WebConfig = try p.parseWithDefaultValues(alloc, WebConfig, initial, webconfig_reader, .{});

    try testing.expect(mem.eql(u8, result.name, "DuckDrop"));
    try testing.expect(result.HTTP.port == 8080);
    try testing.expect(mem.eql(u8, result.HTTP.host, "0.0.0.0"));
    try testing.expect(mem.eql(u8, result.Database.host, "localhost"));
    try testing.expect(result.Database.port == 5432);
    try testing.expect(mem.eql(u8, result.Database.database, "zig"));
    try testing.expect(mem.eql(u8, result.Database.user, "postgres"));
    try testing.expect(mem.eql(u8, result.Database.password, "zigisfun"));

    alloc.free(result.Database.password);
    alloc.free(result.Database.user);
    alloc.free(result.Database.database);
    alloc.free(result.Database.host);
    alloc.free(result.HTTP.host);
    alloc.free(result.name);
}

test "deeply nested struct test" {
    const StructD = struct {
        e: []const u8,
    };

    const StructC = struct {
        number: u32,
        d: StructD,
    };

    const StructB = struct {
        c: StructC,
    };

    const StructA = struct {
        b: StructB,
    };

    const TopStruct = struct {
        b: u32,
        a: StructA,
    };

    const ini_string =
        \\ b = 10
        \\ [a]
        \\ [a.b]
        \\ [a.b.c]
        \\ number = 20
        \\ [a.b.c.d]
        \\ e = hello
        \\
    ;

    var stream = io.fixedBufferStream(ini_string);
    const reader = stream.reader();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try p.parse(a, TopStruct, reader, .{});

    try testing.expect(result.b == 10);
    try testing.expect(result.a.b.c.number == 20);
    try testing.expect(mem.eql(u8, result.a.b.c.d.e, "hello"));
}

test "missing fields" {
    const ini_string =
        \\ # Config for the HTTP Server
        \\ name = DuckDrop
        \\ [HTTP]
        \\ port = 8080
        \\ host = 0.0.0.0
        \\ [Database]
        \\ # DB Info
        // \\ host = localhost // missing!
        \\ port = 5432
        \\ database = zig
        \\ # User Info
        \\ user = postgres
        \\ password = zigisfun
        \\
    ;

    var stream = io.fixedBufferStream(ini_string);
    var reader = stream.reader();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = p.parse(a, WebConfig, reader, .{});
    try testing.expectError(p.IniParseError.KeyNotFound, result);

    // now try the permissive mode
    stream = io.fixedBufferStream(ini_string);
    reader = stream.reader();
    const result2 = try p.parse(a, WebConfig, reader, .{ .error_on_missing_key = false });
    try testing.expect(mem.eql(u8, result2.name, "DuckDrop"));
}

test "too many fields" {
    const ini_string =
        \\ # Config for the HTTP Server
        \\ name = DuckDrop
        \\ [HTTP]
        \\ port = 8080
        \\ host = 0.0.0.0
        \\ [Database]
        \\ # DB Info
        \\ host = localhost
        \\ port = 5432
        \\ database = zig
        \\ # User Info
        \\ user = postgres
        \\ password = zigisfun
        \\ extra = 123
        \\
    ;

    var stream = io.fixedBufferStream(ini_string);
    var reader = stream.reader();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = p.parse(a, WebConfig, reader, .{});
    try testing.expectError(p.IniParseError.UnexpectedData, result);

    // now try the permissive mode
    stream = io.fixedBufferStream(ini_string);
    reader = stream.reader();
    const result2 = p.parse(a, WebConfig, reader, .{ .error_on_missing_key = false });
    try testing.expectError(p.IniParseError.UnexpectedData, result2); // still fails
}
