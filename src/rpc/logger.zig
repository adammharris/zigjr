// Zig JR
// A Zig based JSON-RPC 2.0 library.
// Copyright (C) 2025 William W. Wong. All rights reserved.
// (williamw520@gmail.com)
//
// MIT License.  See the LICENSE file.
//

const std = @import("std");
const Allocator = std.mem.Allocator;


inline fn TPtr(T: type, opaque_ptr: *anyopaque) T {
    return @as(T, @ptrCast(@alignCast(opaque_ptr)));
}

/// Logger interface
pub const Logger = struct {
    impl:       *anyopaque,
    i_start:    *const fn(impl: *anyopaque, message: []const u8) void,
    i_log:      *const fn(impl: *anyopaque, source: [] const u8, operation: []const u8, message: []const u8) void,
    i_stop:     *const fn(impl: *anyopaque, message: []const u8) void,

    // The implementation must have these methods.
    pub fn start(self: @This(), message: []const u8) void {
        self.i_start(self.impl, message);
    }

    pub fn log(self: @This(), source: [] const u8, operation: []const u8, message: []const u8) void {
        self.i_log(self.impl, source, operation, message);
    }

    pub fn stop(self: @This(), message: []const u8) void {
        self.i_stop(self.impl, message);
    }

    // Interface is implemented by the 'impl_obj' object.
    pub fn implBy(impl_obj: anytype) Logger {
        const IT = @TypeOf(impl_obj);

        const Delegate = struct {
            fn start(impl: *anyopaque, message: []const u8) void {
                TPtr(IT, impl).start(message);
            }

            fn log(impl: *anyopaque, source: [] const u8, operation: []const u8, message: []const u8) void {
                TPtr(IT, impl).log(source, operation, message);
            }

            fn stop(impl: *anyopaque, message: []const u8) void {
                TPtr(IT, impl).stop(message);
            }
        };

        return .{
            .impl = impl_obj,
            .i_start = Delegate.start,
            .i_log = Delegate.log,
            .i_stop = Delegate.stop,
        };
    }

};


/// A nop logger that implements the Logger interface; can be passed to the stream options.logger.
pub const NopLogger = struct {
    pub fn start(_: @This(), _: []const u8) void {}
    pub fn log(_: @This(), _: []const u8, _: []const u8, _: []const u8) void {}
    pub fn stop(_: @This(), _: []const u8) void {}

    /// Return a Logger interface for this DbgLogger.
    pub fn asLogger(self: *NopLogger) Logger {
        return Logger.implBy(self);
    }
};

var nopLogger = NopLogger{};


/// A logger that prints to std.dbg, implemented the Logger interface.
pub const DbgLogger = struct {
    pub fn start(_: *DbgLogger, message: []const u8) void {
        std.debug.print("{s}\n", .{message});
    }

    pub fn log(_: *DbgLogger, source: []const u8, operation: []const u8, message: []const u8) void {
        std.debug.print("[{s}] {s} - {s}\n", .{source, operation, message});
    }

    pub fn stop(_: *DbgLogger, message: []const u8) void {
        std.debug.print("{s}\n", .{message});
    }

    /// Return a Logger interface for this DbgLogger.
    pub fn asLogger(self: *DbgLogger) Logger {
        return Logger.implBy(self);
    }
    
};


/// A logger that logs to file, implemented the Logger interface.
pub const FileLogger = struct {
    alloc: Allocator,
    count: usize = 0,
    file: std.Io.File,
    fwriter: std.Io.File.Writer,
    write_buf: []const u8,
    io: std.Io,

    /// Create a FileLogger to log to the file at 'file_path',
    pub fn init(alloc: Allocator, io: std.Io, file_path: []const u8) !FileLogger {
        const file = try fileOpenIf(io, file_path);
        const write_buf = try alloc.alloc(u8, 4096);    // buffer with the usual disk page size.
        var fwriter = file.writer(io, write_buf);
        try fwriter.seekTo(try file.length(io));        // seek to end for appending to file.
        return .{
            .alloc = alloc,
            .file = file,
            .fwriter = fwriter,
            .write_buf = write_buf,
            .io = io,
        };
    }

    pub fn deinit(self: *FileLogger, io: std.Io) void {
        self.file.close(io);
        self.alloc.free(self.write_buf);
    }

    pub fn start(self: *FileLogger, message: []const u8) void {
        const ts_sec = std.Io.Timestamp.now(self.io, .real).toSeconds();
        self.fwriter.interface.print("Timestamp {d} - {s}\n", .{ts_sec, message})
            catch |err| std.debug.print("Error while printing in start(). {any}\n", .{err});
        self.fwriter.interface.flush() 
            catch |err| std.debug.print("Error while flushing in log(). {any}\n", .{err});
    }

    pub fn log(self: *FileLogger, source: []const u8, operation: []const u8, message: []const u8) void {
        self.count += 1;
        self.fwriter.interface.print("{}: [{s}] {s} - {s}\n", .{self.count, source, operation, message})
            catch |err| std.debug.print("Error while printing in log(). {any}\n", .{err});
        self.fwriter.interface.flush() 
            catch |err| std.debug.print("Error while flushing in log(). {any}\n", .{err});
    }
    
    pub fn stop(self: *FileLogger, message: []const u8) void {
        const ts_sec = std.Io.Timestamp.now(self.io, .real).toSeconds();
        self.fwriter.interface.print("Timestamp {d} - {s}\n\n", .{ts_sec, message})
            catch |err| std.debug.print("Error while printing in stop(). {any}\n", .{err});
        self.fwriter.interface.flush()
            catch |err| std.debug.print("Error while flushing in stop(). {any}\n", .{err});
    }

    fn fileOpenIf(io: std.Io, file_path: []const u8) !std.Io.File {
        return std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .write_only }) catch |err| {
            if (err == error.FileNotFound) {
                return try std.Io.Dir.cwd().createFile(io, file_path, .{ .read = false });
            } else {
                return err;
            }
        };
    }

    /// Return a Logger interface for this FileLogger.
    pub fn asLogger(self: *FileLogger) Logger {
        return Logger.implBy(self);
    }

};


