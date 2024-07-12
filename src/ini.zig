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
    KeyNotFound,
};

pub const ParserConfig = struct {
    // How long a line of the ini file can be before it's considered too long
    // and causes an error.
    comptime max_line_size: usize = 1024,

    // If true, the parser will error if a key is missing from the ini file.
    // Otherwise, it will be ignored and left undefined or as the given default value.
    error_on_missing_key: bool = true,
};

pub const Parser = struct {
    const Self = @This();

    config: ParserConfig,

    alloc: mem.Allocator,

    buffer: []u8,
    stream: io.FixedBufferStream([]u8),
    bytes_read: usize = 0,
    token_pos: usize = 0,
    missedAKey: bool = false,
    current_section: ?[]const u8 = null,

    pub fn init(alloc: mem.Allocator, config: ParserConfig) !Self {
        const buffer = try alloc.alloc(u8, config.max_line_size);
        return initWithBuffer(alloc, buffer, config);
    }

    pub fn initWithBuffer(alloc: mem.Allocator, buffer: []u8, config: ParserConfig) Self {
        const stream = io.fixedBufferStream(buffer);
        return Self{
            .alloc = alloc,
            .config = config,
            .buffer = buffer,
            .stream = stream,
        };
    }

    fn deinit(self: Self) void {
        self.alloc.free(self.buffer);
        if (self.current_section) |sec| {
            self.alloc.free(sec);
        }
    }

    fn nextToken(
        self: *Self,
        reader: anytype,
        expected_key: []const u8,
        expected_type: type,
    ) IniParseError!expected_type {

        // assert that the key is correct
        std.debug.assert(expected_key.len > 0);

        // var stream: io.FixedBufferStream([]u8) = io.fixedBufferStream(self.buffer);
        // const writer = stream.writer();

        // seek to next line
        while (true) {
            self.token_pos = 0;
            if (self.missedAKey) {
                self.missedAKey = false;
            } else {
                reader.streamUntilDelimiter(self.stream.writer(), '\n', self.config.max_line_size) catch |err| {
                    switch (err) {
                        error.StreamTooLong => {
                            return IniParseError.LineTooLong;
                        },
                        error.EndOfStream => {
                            // we reached the end of the file
                        },
                        else => {
                            return IniParseError.InvalidFile;
                        },
                    }
                };
                self.bytes_read = self.stream.getPos() catch return IniParseError.InternalParseError;
                self.stream.reset();
            }

            if (self.bytes_read == 0) {
                continue;
            }

            // seek to next token
            while (self.token_pos < self.bytes_read and self.buffer[self.token_pos] == ' ') {
                self.token_pos += 1;
            }

            if (self.token_pos == self.bytes_read) {
                continue; // empty line
            }
            // check if it's a header

            // section format: [TopLevel.section.subsection]
            if (self.buffer[self.token_pos] == '[') {
                if (self.current_section == null) {
                    return IniParseError.InvalidSection;
                }
                // find ']' and last .
                var section_end: usize = self.token_pos + 1;
                var last_dot: ?usize = null;
                while (section_end < self.bytes_read and self.buffer[section_end] != ']') {
                    if (self.buffer[section_end] == '.') {
                        last_dot = section_end;
                    }
                    section_end += 1;
                }
                if (section_end == self.bytes_read) {
                    return IniParseError.InvalidSection;
                }

                const subbest_section_name = blk: {
                    if (last_dot) |pos| {
                        // only take the name of the most specific subsection
                        break :blk self.buffer[pos + 1 .. section_end];
                    } else {
                        // take the name of the section
                        break :blk self.buffer[self.token_pos + 1 .. section_end];
                    }
                };

                // check if the section is the current section
                if (mem.eql(u8, self.current_section.?, subbest_section_name)) {
                    continue;
                } else {
                    if (self.config.error_on_missing_key) {
                        return IniParseError.InvalidSection;
                    } else {
                        return IniParseError.KeyNotFound;
                    }
                }

                continue;
            }

            // check if it's a comment
            if (self.buffer[self.token_pos] == ';' or self.buffer[self.token_pos] == '#') {
                continue;
            }

            break;
        }
        // we are at the start of the token
        // assert that the key is correct
        if (!mem.eql(u8, self.buffer[self.token_pos .. self.token_pos + expected_key.len], expected_key)) {
            std.log.warn("Expected key: {s}, got: {s}", .{ expected_key, self.buffer[self.token_pos .. self.token_pos + expected_key.len] });
            return IniParseError.KeyNotFound;
        }
        self.token_pos += expected_key.len;

        // seek to next token
        while (self.token_pos < self.bytes_read and self.buffer[self.token_pos] == ' ') {
            self.token_pos += 1;
        }
        if (self.token_pos == self.bytes_read) {
            return IniParseError.InvalidLine;
        }
        // check if the token is an equal sign
        if (self.buffer[self.token_pos] != '=') {
            return IniParseError.InvalidLine;
        }

        self.token_pos += 1;

        // seek to next token
        while (self.token_pos < self.bytes_read and self.buffer[self.token_pos] == ' ') {
            self.token_pos += 1;
        }
        if (self.token_pos == self.bytes_read) {
            return IniParseError.InvalidLine;
        }

        var i: usize = self.bytes_read - 1;

        // find last non-whitespace char
        while (i > self.token_pos and self.buffer[i] == ' ') {
            i -= 1;
        }

        const value_len = i - self.token_pos + 1;

        if (value_len == 0) {
            return IniParseError.InvalidValue;
        }

        const value_bytes = self.buffer[self.token_pos .. self.token_pos + value_len];

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
                        return self.alloc.dupe(type_info.Pointer.child, value_bytes) catch {
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
        self: *Self,
        T: type,
        instance: T,
        reader: anytype,
    ) IniParseError!T {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .Struct => {},
            else => {
                return IniParseError.InvalidType;
            },
        }

        var result: T = instance;

        inline for (type_info.Struct.fields) |field| {
            const field_type = field.type;
            const field_key = field.name;

            // recurse into sub-structs
            const field_type_info = @typeInfo(field_type);
            switch (field_type_info) {
                .Struct => {
                    if (self.current_section) |sec| {
                        self.alloc.free(sec);
                    }
                    self.current_section = self.alloc.dupe(u8, field_key) catch {
                        return IniParseError.InternalParseError;
                    };
                    const sub_instance = try self.parseWithDefaultValues(field_type, @field(instance, field_key), reader);
                    @field(result, field_key) = sub_instance;
                    continue;
                },
                else => {},
            }

            const field_value = self.nextToken(reader, field_key, field_type) catch |err| blk: {
                switch (err) {
                    IniParseError.KeyNotFound => {
                        if (self.config.error_on_missing_key) {
                            return err;
                        } else {
                            self.missedAKey = true;
                            self.token_pos = 0;
                            break :blk @field(instance, field_key);
                        }
                    },
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
        self: *Self,
        T: type,
        reader: anytype,
    ) IniParseError!T {
        return self.parseWithDefaultValues(T, undefined, reader);
    }
};

// Tests
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

    const init = WebConfig{ .name = "dropped duck", .HTTP = HTTPConfig{
        .port = 9999,
        .host = "0",
    }, .Database = DatabaseConfig{
        .host = "c",
        .port = 1111,
        .database = "b",
        .user = "a",
    } };

    // const result: WebConfig = try Parser.parse(WebConfig, alloc, reader, .{ .error_on_missing_key = false });
    const p = try Parser.init(alloc, .{});
    const result: WebConfig = try p.parseWithDefaultValues(WebConfig, init, reader);

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
        \\ [Top]
        \\ b = 10
        \\ [Top.a]
        \\ [Top.a.b]
        \\ [Top.a.b.c]
        \\ number = 20
        \\ [Top.a.b.c.d]
        \\ e = hello
    ;

    var stream = io.fixedBufferStream(ini_string);
    const reader = stream.reader();

    const p = try Parser.init(testing.allocator, .{});
    const result = try p.parse(TopStruct, reader);

    try testing.expect(result.b == 10);
    try testing.expect(result.a.b.c.number == 20);
    try testing.expect(mem.eql(u8, result.a.b.c.d.e, "hello"));

    testing.allocator.free(result.a.b.c.d.e);
}
