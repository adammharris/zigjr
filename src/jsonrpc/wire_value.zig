// Zig JR
// A Zig based JSON-RPC 2.0 library.
// Copyright (C) 2025 William W. Wong. All rights reserved.
// (williamw520@gmail.com)
//
// MIT License.  See the LICENSE file.
//

//! The envelope's JSON, read without `std.json`'s generic number path.
//!
//! `std.json.Value.jsonParse`, and `innerParse` on any struct with an
//! integer field, read a number through `std.fmt.parseFloat` when its
//! lexeme is not plainly an integer, which links the float parser (about
//! 100 KB of wasm) into every program that reads a message. This fork's
//! users carry no floats in their messages, so every message here is read
//! by a walk over the tokens: an integer lexeme is an `.integer`, and any
//! other number is kept as its text, `.number_string`, for the caller to
//! parse if it wants one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ParseOptions = std.json.ParseOptions;
const Value = std.json.Value;

/// Deeper than this is refused (`error.SyntaxError`), so a hostile message
/// cannot exhaust the stack.
pub const max_depth = 128;

/// Read one JSON value from `source`.
pub fn parseValue(alloc: Allocator, source: anytype, options: ParseOptions) !Value {
    return parseDepth(alloc, source, options, 0);
}

fn parseDepth(alloc: Allocator, source: anytype, options: ParseOptions, depth: usize) !Value {
    if (depth > max_depth) return error.SyntaxError;
    const max = options.max_value_len orelse std.json.default_max_value_len;
    return switch (try source.nextAllocMax(alloc, allocation(options), max)) {
        .null => .null,
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .number, .allocated_number => |n| number(n),
        .string, .allocated_string => |s| .{ .string = s },
        .array_begin => blk: {
            var items: std.json.Array = .init(alloc);
            while (try source.peekNextTokenType() != .array_end) {
                try items.append(try parseDepth(alloc, source, options, depth + 1));
            }
            _ = try source.next();
            break :blk .{ .array = items };
        },
        .object_begin => blk: {
            var map: std.json.ObjectMap = .empty;
            while (try nextKey(alloc, source, options)) |key| {
                try map.put(alloc, key, try parseDepth(alloc, source, options, depth + 1));
            }
            break :blk .{ .object = map };
        },
        else => error.UnexpectedToken,
    };
}

/// An integer lexeme as an integer; anything else (a fraction, an
/// exponent, an integer too large for `i64`) as its text.
pub fn number(lexeme: []const u8) Value {
    return if (std.fmt.parseInt(i64, lexeme, 10)) |i| .{ .integer = i } else |_| .{ .number_string = lexeme };
}

/// The next key of an object whose `{` has been read, or null at its `}`.
pub fn nextKey(alloc: Allocator, source: anytype, options: ParseOptions) !?[]const u8 {
    const max = options.max_value_len orelse std.json.default_max_value_len;
    return switch (try source.nextAllocMax(alloc, allocation(options), max)) {
        .object_end => null,
        .string, .allocated_string => |k| k,
        else => error.UnexpectedToken,
    };
}

/// Expect `{`.
pub fn beginObject(source: anytype) !void {
    if (try source.next() != .object_begin) return error.UnexpectedToken;
}

/// A field this reader does not know: skipped, or refused when the options
/// say unknown fields are an error.
pub fn unknownField(source: anytype, options: ParseOptions) !void {
    if (!options.ignore_unknown_fields) return error.UnknownField;
    try source.skipValue();
}

/// A string field.
pub fn string(alloc: Allocator, source: anytype, options: ParseOptions) ![]const u8 {
    return switch (try parseValue(alloc, source, options)) {
        .string => |s| s,
        else => error.UnexpectedToken,
    };
}

/// An integer field; a number that is not an `i64` is `error.Overflow`.
pub fn integer(comptime T: type, alloc: Allocator, source: anytype, options: ParseOptions) !T {
    return switch (try parseValue(alloc, source, options)) {
        .integer => |i| std.math.cast(T, i) orelse error.Overflow,
        .number_string => error.Overflow,
        else => error.UnexpectedToken,
    };
}

fn allocation(options: ParseOptions) std.json.AllocWhen {
    return options.allocate orelse .alloc_if_needed;
}

test "parseValue: integers are integers, other numbers stay text, depth is bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(Probe, a, "{\"a\":[1,-2,3.5,1e3,99999999999999999999],\"b\":\"x\"}", .{});
    const items = v.value.object.get("a").?.array.items;
    try std.testing.expectEqual(@as(i64, 1), items[0].integer);
    try std.testing.expectEqual(@as(i64, -2), items[1].integer);
    try std.testing.expectEqualStrings("3.5", items[2].number_string);
    try std.testing.expectEqualStrings("1e3", items[3].number_string);
    try std.testing.expectEqualStrings("99999999999999999999", items[4].number_string);
    try std.testing.expectEqualStrings("x", v.value.object.get("b").?.string);

    const deep = comptime blk: {
        var buf: [2 * (max_depth + 2)]u8 = undefined;
        @memset(buf[0 .. max_depth + 2], '[');
        @memset(buf[max_depth + 2 ..], ']');
        break :blk buf;
    };
    try std.testing.expectError(error.SyntaxError, std.json.parseFromSliceLeaky(Probe, a, &deep, .{}));
}

/// A value read through `parseValue`, for the test.
const Probe = struct {
    value: Value,
    pub fn jsonParse(alloc: Allocator, source: anytype, options: ParseOptions) !Probe {
        return .{ .value = try parseValue(alloc, source, options) };
    }
};
