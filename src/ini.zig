const std = @import("std");
const io = std.io;
const mem = std.mem;
const meta = std.meta;
const builtin = std.builtin;

const testing = std.testing;

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
    UnexpectedData,
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

const Self = @This();

config: ParserConfig,

alloc: mem.Allocator,

buffer: []u8,
stream: io.FixedBufferStream([]u8),
bytes_read: usize = 0,
token_pos: usize = 0,
missedAKey: bool = false,
current_section: []u8,

fn processValue(self: *Self, expected_type: type, value_bytes: []const u8) IniParseError!expected_type {
    const type_info: builtin.Type = @typeInfo(expected_type);
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
        .Optional => {
            return try self.processValue(type_info.Optional.child, value_bytes);
        },
        .Enum => {
            return std.meta.stringToEnum(expected_type, value_bytes) orelse {
                return IniParseError.InvalidValue;
            };
        },
        else => {
            return IniParseError.UnsupportedType;
        },
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
                        return IniParseError.UnexpectedEOF;
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
            if (self.current_section.len == 0) {
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
            std.debug.assert(self.buffer[section_end] == ']');

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
            if (mem.eql(u8, self.current_section, subbest_section_name)) {
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
    return self.processValue(expected_type, value_bytes);
}

// Parse a file and return a struct
// T: type of the struct to return
// reader: reader to read the file. Must implement GenericReader
fn parseWithDefaultValuesInternal(
    self: *Self,
    T: type,
    instance: T,
    reader: anytype,
) IniParseError!T {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .Struct => {},
        .Optional => {
            const result = try self.parseWithDefaultValuesInternal(type_info.Optional.child, instance, reader);
            return @as(T, result);
        },
        else => {
            return IniParseError.InvalidType;
        },
    }

    var result: T = instance;

    inline for (type_info.Struct.fields) |field| {
        const field_type = field.type;
        const field_key = field.name;
        if (field_key.len > self.config.max_line_size) {
            return IniParseError.LineTooLong;
        }

        // recurse into sub-structs
        const field_type_info = @typeInfo(field_type);
        switch (field_type_info) {
            .Struct => {
                self.current_section.len = field_key.len;
                @memcpy(self.current_section, field_key);
                reader.skipUntilDelimiterOrEof('\n') catch return IniParseError.InternalParseError;
                const sub_instance = try self.parseWithDefaultValuesInternal(field_type, @field(instance, field_key), reader);
                @field(result, field_key) = sub_instance;
                continue;
            },
            .Optional => {
                const child_type_info = @typeInfo(field_type_info.Optional.child);
                switch (child_type_info) {
                    .Struct => {
                        self.current_section.len = field_key.len;
                        @memcpy(self.current_section, field_key);
                        reader.skipUntilDelimiterOrEof('\n') catch return IniParseError.InternalParseError;
                        const sub_instance = self.parseWithDefaultValuesInternal(
                            field_type_info.Optional.child,
                            @field(instance, field_key) orelse undefined,
                            reader,
                        ) catch |err| blk: {
                            switch (err) {
                                IniParseError.UnexpectedEOF => {
                                    @field(result, field_key) = null;
                                    break :blk @field(instance, field_key);
                                },
                                else => {
                                    return err;
                                },
                            }
                        };
                        @field(result, field_key) = sub_instance;
                        continue;
                    },
                    else => {},
                }
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
pub fn parseWithDefaultValues(
    alloc: mem.Allocator,
    T: type,
    instance: T,
    reader: anytype,
    config: ParserConfig,
) IniParseError!T {
    var buffer: [config.max_line_size]u8 = undefined;
    const stream = io.fixedBufferStream(&buffer);
    var current_section: [config.max_line_size]u8 = undefined;
    var self = Self{
        .alloc = alloc,
        .config = config,
        .buffer = &buffer,
        .stream = stream,
        .current_section = &current_section,
    };

    const result = try self.parseWithDefaultValuesInternal(T, instance, reader);

    _ = self.nextToken(reader, "check", u8) catch |err| {
        switch (err) {
            IniParseError.KeyNotFound => {
                return IniParseError.UnexpectedData;
            },
            IniParseError.UnexpectedEOF => {
                return result;
            },
            else => {
                return err;
            },
        }
    };
    // reset streams and buffers
    self.stream.reset();
    self.token_pos = 0;
    self.bytes_read = 0;
    self.missedAKey = false;

    return IniParseError.UnexpectedData;
}

// You are responsible for freeing all arrays or pointers returned by this function
pub fn parse(
    alloc: mem.Allocator,
    T: type,
    reader: anytype,
    config: ParserConfig,
) IniParseError!T {
    return parseWithDefaultValues(alloc, T, undefined, reader, config);
}
