const std = @import("std");
const io = std.io;
const mem = std.mem;
const meta = std.meta;
const builtin = std.builtin;

const testing = std.testing;

const MAX_LINE_SIZE = 1024;

pub const IniParseError = error{
    InvalidType,
    UnsupportedType,
    LineTooLong,
    InvalidSection,
    InvalidKey,
    InvalidValue,
    InvalidLine,
    InvalidFile,
    InternalParseError,
    UnexpectedEOF,
};

pub const Parser = struct {
    fn nextToken(
        alloc: mem.Allocator,
        reader: anytype,
        expected_key: []const u8,
        expected_type: type,
    ) IniParseError!expected_type {

        // assert that the key is correct
        std.debug.assert(expected_key.len > 0);

        var buffer: [MAX_LINE_SIZE]u8 = undefined;
        var stream = io.fixedBufferStream(&buffer);
        const writer = stream.writer();

        var bytes_read: usize = 0;
        var token_pos: usize = 0;
        // seek to next line
        while (true) {
            token_pos = 0;
            const r = reader;
            r.streamUntilDelimiter(writer, '\n', MAX_LINE_SIZE) catch |err| {
                switch (err) {
                    error.StreamTooLong => {
                        return IniParseError.LineTooLong;
                    },
                    error.EndOfStream => {
                        return IniParseError.UnexpectedEOF;
                    },
                    else => {
                        return IniParseError.InvalidFile;
                    },
                }
            };

            bytes_read = stream.getPos() catch return IniParseError.InternalParseError;
            stream.reset();

            if (bytes_read == 0) {
                continue;
            }

            // seek to next token
            while (token_pos < bytes_read and buffer[token_pos] == ' ') {
                token_pos += 1;
            }

            if (token_pos == bytes_read) {
                continue; // empty line
            }
            // check if it's a header

            if (buffer[token_pos] == '[') {
                // skip i think
                continue;
            }

            // check if it's a comment
            if (buffer[token_pos] == ';' or buffer[token_pos] == '#') {
                continue;
            }
            break;
        }

        // we are at the start of the token

        // assert that the key is correct
        if (!mem.eql(u8, buffer[token_pos .. token_pos + expected_key.len], expected_key)) {
            std.log.debug("Expected key: {s}, Actual key: {s}\n", .{ expected_key, buffer[token_pos .. token_pos + expected_key.len] });
            return IniParseError.InvalidKey;
        }

        token_pos += expected_key.len;

        // seek to next token
        while (token_pos < bytes_read and buffer[token_pos] == ' ') {
            token_pos += 1;
        }
        if (token_pos == bytes_read) {
            return IniParseError.InvalidLine;
        }
        // check if the token is an equal sign
        if (buffer[token_pos] != '=') {
            return IniParseError.InvalidLine;
        }

        token_pos += 1;

        // seek to next token
        while (token_pos < bytes_read and buffer[token_pos] == ' ') {
            token_pos += 1;
        }
        if (token_pos == bytes_read) {
            return IniParseError.InvalidLine;
        }

        var i: usize = bytes_read - 1;

        // find last non-whitespace char
        while (i > token_pos and buffer[i] == ' ') {
            i -= 1;
        }

        const value_len = i - token_pos + 1;

        if (value_len == 0) {
            return IniParseError.InvalidValue;
        }

        const value_bytes = buffer[token_pos .. token_pos + value_len];

        const type_info = @typeInfo(expected_type);

        switch (type_info) {
            .Int => {
                // parse it!
                return std.fmt.parseInt(expected_type, value_bytes, 10) catch {
                    return IniParseError.InvalidValue;
                };
            },
            .Pointer => {
                switch (type_info.Pointer.size) {
                    .Slice => {
                        return alloc.dupe(type_info.Pointer.child, value_bytes) catch {
                            return IniParseError.InternalParseError;
                        };
                    },
                    else => {
                        return IniParseError.UnsupportedType;
                    },
                }
            },
            else => {
                return IniParseError.UnsupportedType;
            },
        }
    }

    // Parse a file and return a struct
    // T: type of the struct to return
    // reader: reader to read the file. Must implement GenericReader
    pub fn parseWithDefaultValues(
        T: type,
        instance: T,
        alloc: mem.Allocator,
        reader: anytype,
    ) IniParseError!T {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .Struct => {},
            else => {
                return IniParseError.InvalidType;
            },
        }

        // var r = reader;

        var result: T = instance;

        inline for (type_info.Struct.fields) |field| {
            const field_type = field.type;
            const field_key = field.name;

            // recurse into sub-structs
            const field_type_info = @typeInfo(field_type);
            switch (field_type_info) {
                .Struct => {
                    const sub_instance = try parseWithDefaultValues(field_type, undefined, alloc, reader);
                    @field(result, field_key) = sub_instance;
                    continue;
                },
                else => {},
            }

            const field_value = nextToken(alloc, reader, field_key, field_type) catch |err| {
                switch (err) {
                    else => {
                        return err;
                    },
                }
            };

            @field(result, field_key) = field_value;
        }
        return result;
    }

    // You are responsible for freeing all arrays or pointers returned by this function
    pub fn parse(
        T: type,
        alloc: mem.Allocator,
        reader: anytype,
    ) IniParseError!T {
        return parseWithDefaultValues(T, undefined, alloc, reader);
    }
};

test "web config test" {
    // try testing.expect(add(3, 7) == 10);

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

    const alloc = testing.allocator;

    const result: WebConfig = try Parser.parse(WebConfig, alloc, reader);

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
