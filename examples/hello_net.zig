// Zig JR
// A Zig based JSON-RPC 2.0 library.
// Copyright (C) 2025 William W. Wong. All rights reserved.
// (williamw520@gmail.com)
//
// MIT License.  See the LICENSE file.
//

const std = @import("std");
const Allocator = std.mem.Allocator;
const ParseOptions = std.json.ParseOptions;
const StringHashMap = std.hash_map.StringHashMap;

const zigjr = @import("zigjr");


// For --http, test with
//  curl localhost:35354 --request POST --json @data/hello.json
//  curl localhost:35354 --request POST --json @data/hello_name.json

// For --tcp, test with
//  nc64 localhost 35354 < data\hello.json
//  nc64 localhost 35354 < data\hello_name.json


pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var args = try CmdArgs.init(alloc, init.minimal.args);
    defer args.deinit();
    args.parse() catch { usage(); return; };

    const run_http = if (args.is_http) true else if (args.is_tcp) false
    else {
        usage();
        return;
    };

    const listen_address = try std.fmt.allocPrint(alloc, "0.0.0.0:{s}", .{args.port});
    defer alloc.free(listen_address);
    const local_address = try std.fmt.allocPrint(alloc, "127.0.0.1:{s}", .{args.port});
    defer alloc.free(local_address);
    std.debug.print("Server listening at port: {s}\n", .{args.port});

    var ctx = ServerCtx {
        .is_http = run_http,
        .listen_address = listen_address,
        .local_address = local_address,
        .end_server = std.atomic.Value(bool).init(false),
        .io = init.io,
    };

    const rpc_dispatcher = try createDispatcher(alloc, &ctx);
    defer {
        rpc_dispatcher.deinit();
        alloc.destroy(rpc_dispatcher);
    }
    const dispatcher = zigjr.RequestDispatcher.implBy(rpc_dispatcher);
    try runServer(&ctx, dispatcher);
}

const ServerCtx = struct {
    is_http: bool,
    listen_address: []const u8,
    local_address: []const u8,
    end_server: std.atomic.Value(bool),
    io: std.Io,
};

fn createDispatcher(alloc: Allocator, ctx: *ServerCtx) !*zigjr.RpcDispatcher {
    var rpc_dispatcher = try alloc.create(zigjr.RpcDispatcher);
    rpc_dispatcher.* = try zigjr.RpcDispatcher.init(alloc);
    
    try rpc_dispatcher.add("hello", hello);
    try rpc_dispatcher.add("hello-name", helloName);
    try rpc_dispatcher.add("hello-xtimes", helloXTimes);
    try rpc_dispatcher.add("substr", substr);
    try rpc_dispatcher.add("say", say);
    try rpc_dispatcher.add("opt-text", optionalText);
    try rpc_dispatcher.add("end-session", endSession);
    try rpc_dispatcher.addWithCtx("end-server", ctx, endServer);

    return rpc_dispatcher;
}

fn runServer(ctx: *ServerCtx, dispatcher: zigjr.RequestDispatcher) !void {
    const net_addr  = try std.Io.net.IpAddress.parseLiteral(ctx.listen_address);
    var server      = try net_addr.listen(ctx.io, .{ .reuse_address = true });
    defer server.deinit(ctx.io);

    while (true) {
        if (ctx.end_server.load(std.builtin.AtomicOrder.seq_cst))
            break;
        const connection = try server.accept(ctx.io);
        if (ctx.end_server.load(std.builtin.AtomicOrder.seq_cst))
            break;

        if (ctx.is_http) {
            _ = try std.Thread.spawn(.{}, httpWorker, .{ctx.io, dispatcher, connection});
        } else {
            _ = try std.Thread.spawn(.{}, netWorker, .{ctx.io, dispatcher, connection});
        }
    }
}

fn httpWorker(io: std.Io, dispatcher: zigjr.RequestDispatcher, connection: std.Io.net.Stream) void {
    std.debug.print("Start HTTP session.\n", .{});

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    runHttpSession(alloc, io, dispatcher, connection) catch |e| {
        std.debug.print("Error in HTTP session: {any}\n", .{e});
    };

    connection.close(io);
    std.debug.print("End HTTP session.\n", .{});
}

fn netWorker(io: std.Io, dispatcher: zigjr.RequestDispatcher, connection: std.Io.net.Stream) void {
    std.debug.print("Start session (netWorker).\n", .{});

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    runNetSession(alloc, io, dispatcher, connection) catch |e| {
        std.debug.print("Error in runSession: {any}\n", .{e});
    };

    connection.close(io);
    std.debug.print("End session (netWorker).\n", .{});
}

fn runHttpSession(alloc: Allocator, io: std.Io, dispatcher: zigjr.RequestDispatcher,
                  connection: std.Io.net.Stream) !void {
    var rbuf: [1024]u8  = undefined;
    var wbuf: [1024]u8  = undefined;
    var s_reader        = connection.reader(io, &rbuf);
    var s_writer        = connection.writer(io, &wbuf);
    const reader        = &s_reader.interface;
    const writer        = &s_writer.interface;
    var dbg_logger      = zigjr.DbgLogger{};
    var pipeline        = try zigjr.RequestPipeline.init(alloc, dispatcher, dbg_logger.asLogger());
    var frame           = zigjr.frame.FrameData.init(alloc);

    defer pipeline.deinit();
    defer frame.deinit();

    try zigjr.frame.readHttpLine(reader, &frame);
    std.debug.print("HTTP Line: {s} {s} {s}\n", .{ frame.http_method, frame.http_path, frame.http_version });
    const has_data = try zigjr.frame.readContentLengthFrame(reader, &frame);
    if (!has_data)
        return;

    const request_json = std.mem.trim(u8, frame.getContent(), " \t\n\r");
    // std.debug.print("content_length: {any}, request_json: |{s}|\n", .{ frame.content_length, request_json });

    const run_status = try pipeline.runRequest(request_json);
    if (run_status.hasReply()) {
        try zigjr.frame.writeHttpStatusLine(writer, "1.1", 200, "OK");  // HTTP/1.1 200 OK\r\n
        try zigjr.frame.writeContentLengthFrame(writer, pipeline.responseJson());
        try writer.flush();
    } else {
        std.debug.print("No response\n", .{});
    }
}

fn runNetSession(alloc: Allocator, io: std.Io, dispatcher: zigjr.RequestDispatcher,
                 connection: std.Io.net.Stream) !void {
    var rbuf: [1024]u8  = undefined;
    var wbuf: [1024]u8  = undefined;
    var s_reader        = connection.reader(io, &rbuf);
    var s_writer        = connection.writer(io, &wbuf);
    const reader        = &s_reader.interface;
    const writer        = &s_writer.interface;
    var dbg_logger      = zigjr.DbgLogger{};

    zigjr.stream.requestsByDelimiter(alloc, reader, writer, dispatcher, .{
        .logger = dbg_logger.asLogger()
    }) catch |e| {
        if (e == error.ReadFailed) return else return e;
    };
}

fn touchServer(io: std.Io, address: []const u8) !void {
    const net_addr  = try std.Io.net.IpAddress.parseLiteral(address);
    var stream      = try net_addr.connect(io, .{ .protocol = .tcp, .mode = .stream });
    defer stream.close(io);
}

// A handler with no parameter and returns a string.
fn hello() []const u8 {
    return "Hello world";
}

// A handler takes in a string parameter and returns a string with error.
// It also asks the library for an allocator, which is passed in automatically.
// Allocated memory is freed automatically, making memory usage simple.
fn helloName(dc: *zigjr.DispatchCtx, name: [] const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(dc.arena(), "Hello {s}", .{name});
}

// This one takes one more parameter. Note that i64 is JSON's integer type.
fn helloXTimes(dc: *zigjr.DispatchCtx, name: [] const u8, times: i64) ![]const u8 {
    const repeat: usize = if (0 < times and times < 100) @intCast(times) else 1;
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    for (0..repeat) |_| try buf.writer.print("Hello {s}! ", .{name});
    return buf.written();
}

fn substr(name: [] const u8, start: i64, len: i64) []const u8 {
    return name[@intCast(start) .. @intCast(len)];
}

// A handler takes in a string and has no return value, for RPC notification.
fn say(msg: [] const u8) void {
    std.debug.print("Message to say: {s}\n", .{msg});
}

fn optionalText(text: ?[] const u8) []const u8 {
    if (text)|txt| {
        return txt;
    } else {
        return "No text";
    }
}

fn endSession() zigjr.DispatchResult {
    return zigjr.DispatchResult.asEndStream();
}

fn endServer(ctx: *ServerCtx) zigjr.DispatchResult {
    // Set server termination flag.
    ctx.end_server.store(true, std.builtin.AtomicOrder.seq_cst);
    // Need to wake up server blocking at the .accept() call.
    touchServer(ctx.io, ctx.local_address) catch |e| {
        std.debug.print("Error in touching server at {s}. Error: {any}\n", .{ctx.local_address, e});
    };
    return zigjr.DispatchResult.asEndStream();
}


fn usage() void {
    std.debug.print(
        \\Usage:  hello_net [--http | --tcp] [--port N]
        \\
        \\  --http - runs the server over HTTP. JSON-RPC messages using Content-Length headers.
        \\  --tcp  - runs the server over plain TCP. JSON-RPC messages using LF delimiters.
        \\  --port N - set the listening port of the server.
        \\
        , .{});
}


const CmdArgs = struct {
    const Self = @This();

    arg_itr:    std.process.Args.Iterator,
    is_http:    bool = false,
    is_tcp:     bool = false,
    port:       []const u8 = "35354",

    fn init(alloc: Allocator, pargs: std.process.Args) !CmdArgs {
        var args = CmdArgs { .arg_itr = try pargs.iterateAllocator(alloc) };
        _ = args.arg_itr.next();
        return args;
    }

    fn deinit(self: *CmdArgs) void {
        self.arg_itr.deinit();
    }

    fn parse(self: *Self) !void {
        var argv = self.arg_itr;
        while (argv.next())|argz| {
            const arg = std.mem.sliceTo(argz, 0);
            if (std.mem.eql(u8, arg, "--http")) {
                self.is_http = true;
            } else if (std.mem.eql(u8, arg, "--tcp")) {
                self.is_tcp = true;
            } else if (std.mem.eql(u8, arg, "--port")) {
                if (argv.next())|argz1| {
                    self.port = std.mem.sliceTo(argz1, 0);
                }
            }
        }
    }

};


