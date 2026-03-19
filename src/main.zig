const std = @import("std");
const battery = @import("battery.zig");
const smc = @import("smc.zig");
const ArgIterator = std.process.ArgIterator;

const Command = enum {
    status,
    watch,
    debug,
    raw_status,
    disable,
    enable,
    limit,
};

const usage_text =
    \\Usage:
    \\  zatt status
    \\  zatt watch
    \\  zatt debug
    \\  zatt raw-status
    \\  zatt disable [--wait]
    \\  zatt enable [--wait]
    \\  zatt limit <20-100>
    \\  zatt limit reset
    \\
;

pub fn main() void {
    const exit_code = run();
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

fn run() u8 {
    var args = std.process.args();
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse return usageError();

    return switch (parseCommand(command) orelse return usageError()) {
        .status => runReadOnlyCommand(&args, battery.status),
        .watch => runReadOnlyCommand(&args, battery.watch),
        .debug => runReadOnlyCommand(&args, battery.debug),
        .raw_status => runReadOnlyCommand(&args, battery.rawStatus),
        .disable => runBatteryWriteCommand(&args, "CH0B", battery.disable),
        .enable => runBatteryWriteCommand(&args, "CH0B", battery.enable),
        .limit => runLimitCommand(&args),
    };
}

fn parseCommand(command: []const u8) ?Command {
    if (std.mem.eql(u8, command, "status")) return .status;
    if (std.mem.eql(u8, command, "watch")) return .watch;
    if (std.mem.eql(u8, command, "debug")) return .debug;
    if (std.mem.eql(u8, command, "raw-status")) return .raw_status;
    if (std.mem.eql(u8, command, "disable")) return .disable;
    if (std.mem.eql(u8, command, "enable")) return .enable;
    if (std.mem.eql(u8, command, "limit")) return .limit;
    return null;
}

fn runReadOnlyCommand(args: *ArgIterator, comptime action: fn () battery.Error!void) u8 {
    if (args.next() != null) return usageError();
    return readOnlyCommand(action);
}

fn runBatteryWriteCommand(
    args: *ArgIterator,
    comptime key: []const u8,
    comptime action: fn (battery.WriteOptions) battery.Error!void,
) u8 {
    const options = parseWriteOptions(args) orelse return usageError();
    if (!isRoot()) return fail("Error: run with sudo\n", .{});
    return writeBatteryCommand(key, options, action);
}

fn runLimitCommand(args: *ArgIterator) u8 {
    const limit_arg = args.next() orelse return usageError();
    if (std.mem.eql(u8, limit_arg, "reset")) {
        if (args.next() != null) return usageError();
        if (!isRoot()) return fail("Error: run with sudo\n", .{});
        return writeSmcCommand("BCLM", battery.resetLimit);
    }

    if (args.next() != null) return usageError();

    const limit = std.fmt.parseInt(u8, limit_arg, 10) catch {
        return invalidLimitError();
    };
    if (limit < 20 or limit > 100) return invalidLimitError();
    if (!isRoot()) return fail("Error: run with sudo\n", .{});

    battery.setLimit(limit) catch |err| {
        return switch (err) {
            error.CannotOpen => fail("Error: cannot open SMC\n", .{}),
            else => fail("Error: SMC write failed for BCLM\n", .{}),
        };
    };
    return 0;
}

fn readOnlyCommand(comptime action: fn () battery.Error!void) u8 {
    action() catch |err| {
        return switch (err) {
            error.CannotOpen => fail("Error: cannot open SMC\n", .{}),
            else => fail("Error: cannot read battery status\n", .{}),
        };
    };
    return 0;
}

fn writeSmcCommand(comptime key: []const u8, comptime action: fn () smc.Error!void) u8 {
    action() catch |err| {
        return switch (err) {
            error.CannotOpen => fail("Error: cannot open SMC\n", .{}),
            error.NotPrivileged => fail("Error: run with sudo\n", .{}),
            else => fail("Error: SMC write failed for {s}\n", .{key}),
        };
    };
    return 0;
}

fn writeBatteryCommand(
    comptime key: []const u8,
    options: battery.WriteOptions,
    comptime action: fn (battery.WriteOptions) battery.Error!void,
) u8 {
    action(options) catch |err| {
        return switch (err) {
            error.CannotOpen => fail("Error: cannot open SMC\n", .{}),
            error.NotPrivileged => fail("Error: run with sudo\n", .{}),
            error.BatteryNotFound,
            error.InvalidCapacity,
            error.PowerSourceUnavailable,
            error.OutputFailed,
            => fail("Error: cannot verify battery status\n", .{}),
            else => fail("Error: SMC write failed for {s}\n", .{key}),
        };
    };
    return 0;
}

fn parseWriteOptions(args: *ArgIterator) ?battery.WriteOptions {
    var options = battery.WriteOptions{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wait")) {
            options.wait = true;
            continue;
        }
        return null;
    }

    return options;
}

fn invalidLimitError() u8 {
    return fail("Error: limit must be between 20 and 100\n", .{});
}

fn usageError() u8 {
    writeStderr(usage_text);
    return 1;
}

fn isRoot() bool {
    return std.posix.getuid() == 0;
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, args) catch "Error\n";
    writeStderr(message);
    return 1;
}

fn writeStderr(message: []const u8) void {
    std.fs.File.stderr().writeAll(message) catch {};
}

test "parseCommand recognizes supported commands" {
    try std.testing.expectEqual(Command.status, parseCommand("status").?);
    try std.testing.expectEqual(Command.watch, parseCommand("watch").?);
    try std.testing.expectEqual(Command.debug, parseCommand("debug").?);
    try std.testing.expectEqual(Command.raw_status, parseCommand("raw-status").?);
    try std.testing.expectEqual(Command.disable, parseCommand("disable").?);
    try std.testing.expectEqual(Command.enable, parseCommand("enable").?);
    try std.testing.expectEqual(Command.limit, parseCommand("limit").?);
}

test "parseCommand rejects unknown commands" {
    try std.testing.expect(parseCommand("raw_status") == null);
    try std.testing.expect(parseCommand("limits") == null);
    try std.testing.expect(parseCommand("") == null);
}
