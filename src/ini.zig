const std = @import("std");
const io = std.io;
const mem = std.mem;
const meta = std.meta;
const builtin = std.builtin;

const testing = std.testing;

pub const IniParseError = error{
    /// The type you want to parse into is not supported. It must be either a struct or an optional struct.
    InvalidType,
    /// The type of the FIELD you want to parse into is not supported.
    UnsupportedType,
    /// The line in the ini file is too long. Increase max_line_size in the config argument.
    LineTooLong,
    /// The section has invalid syntax or other issues.
    InvalidSection,
    /// The key has invalid syntax or other issues.
    InvalidKey,
    /// The value has invalid syntax, cannot be parsed into the destination type, or other issues.
    InvalidValue,
    /// The line of the ini file has invalid syntax or other issues.
    InvalidLine,
    /// Something about the file is invalid or unexpected.
    InvalidFile,
    /// Something unexpected went wrong with a standard library function.
    InternalParseError,
    /// The file ended unexpectedly.
    UnexpectedEOF,
    /// The file has unexpected data somewhere.
    UnexpectedData,
    /// The key was not found in the file.
    KeyNotFound,
};

pub const ParserConfig = struct {
    /// How long a line of the ini file can be before it's considered too long
    /// and causes an error.
    comptime max_line_size: usize = 1024,

    /// If true, the parser will error if an expected key is missing from the ini file.
    /// Otherwise, it will be ignored and left undefined or as the given default value.
    ///
    /// If a struct field is optional, it will never error if the key is missing (instead
    /// it will be left as null or the default value if it's set).
    ///
    /// Be careful: setting this to false can lead to an undefined value ending up in the
    /// destination struct.
    error_on_missing_key: bool = true,
};

const Self = @This();

config: ParserConfig,
has_default_values: bool,

alloc: mem.Allocator,

buffer: []u8,
stream: io.FixedBufferStream([]u8),
bytes_read: usize = 0,
token_pos: usize = 0,
missed_a_key: bool = false,
current_section: []u8,

// This function is used to parse the value of a key in the ini file.
fn processValue(self: *Self, expected_type: type, value_bytes: []const u8) IniParseError!expected_type {
    const type_info: builtin.Type = @typeInfo(expected_type);
    switch (type_info) {
        .Int => {
            // parse it!
            return std.fmt.parseInt(expected_type, value_bytes, 10) catch {
                return IniParseError.InvalidValue;
            };
        },
        .Float => {
            return std.fmt.parseFloat(expected_type, value_bytes) catch {
                return IniParseError.InvalidValue;
            };
        },
        .Bool => {
            if (mem.eql(u8, value_bytes, "true")) {
                return true;
            } else if (mem.eql(u8, value_bytes, "false")) {
                return false;
            } else {
                return IniParseError.InvalidValue;
            }
        },
        .Pointer => {
            switch (type_info.Pointer.size) {
                .Slice => {
                    // Remember to free this
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
            return meta.stringToEnum(expected_type, value_bytes) orelse {
                return IniParseError.InvalidValue;
            };
        },
        else => {
            return IniParseError.UnsupportedType;
        },
    }
}

fn findNextTokenPos(self: *Self, reader: anytype) IniParseError!bool {
    self.token_pos = 0;
    if (self.missed_a_key) {
        self.missed_a_key = false;
    } else {
        reader.streamUntilDelimiter(self.stream.writer(), '\n', self.config.max_line_size) catch |err| {
            switch (err) {
                error.StreamTooLong => {
                    // The line is too long. Increase max_line_size in the config argument.
                    return IniParseError.LineTooLong;
                },
                error.EndOfStream => {
                    // we reached the end of the file
                    return IniParseError.UnexpectedEOF;
                },
                else => {
                    // Something really unexpected happened
                    return IniParseError.InvalidFile;
                },
            }
        };
        self.bytes_read = self.stream.getPos() catch return IniParseError.InternalParseError;
        self.stream.reset();
    }

    if (self.bytes_read == 0) {
        return false;
    }

    // seek to next token
    while (self.token_pos < self.bytes_read and self.buffer[self.token_pos] == ' ') {
        self.token_pos += 1;
    }

    if (self.token_pos == self.bytes_read) {
        return false; // empty line
    }

    // check if it's a comment
    if (self.buffer[self.token_pos] == ';' or self.buffer[self.token_pos] == '#') {
        return false;
    }
    return true;
}

fn nextToken(
    self: *Self,
    reader: anytype,
    expected_key: []const u8,
    expected_type: type,
) IniParseError!expected_type {

    // assert that the key is correct
    std.debug.assert(expected_key.len > 0);

    // seek to next line
    while (true) {
        // if (self.missed_a_key) {
        //     self.missed_a_key = false;
        // } else {
        const found = try self.findNextTokenPos(reader);
        if (!found) {
            continue;
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
            if (self.buffer[section_end] != ']') {
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
            // }
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
            // if the type is optional, we need to parse the child type
            // if the child type is not a struct, itll just return invalidtype anyw
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
            // increase max_line_size in the config argument
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
                    if (self.config.error_on_missing_key and !(field_type_info == .Optional)) {
                        return err;
                    } else {
                        self.missed_a_key = true;
                        self.token_pos = 0;
                        if (self.has_default_values) {
                            // set it to what's arleady set
                            break :blk @field(instance, field_key);
                        }
                        if (field_type_info == .Optional) {
                            // only if no default is set
                            // and the field is optional, set it to null
                            break :blk null;
                        }
                        // this is almost def undefined
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

fn runParser(
    alloc: mem.Allocator,
    T: type,
    instance: T,
    reader: anytype,
    config: ParserConfig,
    has_default_values: bool,
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
        .has_default_values = has_default_values,
    };

    const result = try self.parseWithDefaultValuesInternal(T, instance, reader);

    const otherKeyFound = self.findNextTokenPos(reader) catch |err| blk: {
        switch (err) {
            IniParseError.UnexpectedEOF => {
                break :blk false;
            },
            else => {
                return IniParseError.UnexpectedData;
            },
        }
    };

    if (!otherKeyFound) {
        return result;
    } else {
        return IniParseError.UnexpectedData;
    }
}

/// You are responsible for freeing all arrays or pointers returned by this function
/// `alloc`: the allocator to use for allocating memory
/// `T`: the type of the struct to parse
/// `instance`: the instance of the struct to parse into
/// `reader`: the reader to read the ini file from
/// `config`: the configuration for the parser - see `ParserConfig`
pub fn parseWithDefaultValues(
    alloc: mem.Allocator,
    T: type,
    instance: T,
    reader: anytype,
    config: ParserConfig,
) IniParseError!T {
    return runParser(alloc, T, instance, reader, config, true);
}

/// You are responsible for freeing all arrays or pointers returned by this function
/// `alloc`: the allocator to use for allocating memory
/// `T`: the type of the struct to parse
/// `reader`: the reader to read the ini file from
/// `config`: the configuration for the parser - see `ParserConfig`
pub fn parse(
    alloc: mem.Allocator,
    T: type,
    reader: anytype,
    config: ParserConfig,
) IniParseError!T {
    return runParser(alloc, T, undefined, reader, config, false);
}
