# iniz - A fast, typed parser for .ini files

Look, JSON has its moments, but config files is not where it's at.

iniz aims to parse a dialect of .ini files into a Zig struct, making it straightforward to create
human-readable config files for Zig programs.


🦆

## Usage

Let's parse this standard config file for a web server:

```ini
# Config for the HTTP Server
name = DuckDrop
[HTTP]
port = 8080
host = 0.0.0.0

[Database]
# DB Info
host = localhost
port = 5432
database = zig

# User Info
user = postgres
password = zigisfun
```

Define your destination struct (the naming of fields must match the naming within the .ini file):

```zig
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
```

And parse the file:

```zig
const std = @import("std");
const p = @import("ini.zig");

const ini_file = try std.fs.cwd().openFile("src/WebServer.ini", .{});
const reader = ini_file.reader();

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const result: WebConfig = try p.parseWithDefaultValues(allocator, WebConfig, init, reader, .{});

// You can pretty-print the result as JSON to see the parsed values
const writer = std.io.getStdOut().writer();
try std.json.stringify(result, .{ .whitespace = .indent_4 }, writer);
try writer.writeByte('\n');

```

Just like that, you have a struct of type `WebConfig` with all the values from the .ini file. 🎉
