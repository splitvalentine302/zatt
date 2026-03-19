const std = @import("std");
const battery = @import("battery.zig");
const smc = @import("smc.zig");

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

    if (std.mem.eql(u8, command, "status")) {
        if (args.next() != null) return usageError();
        return statusCommand();
    }

    if (std.mem.eql(u8, command, "debug")) {
        if (args.next() != null) return usageError();
        return readOnlyCommand(battery.debug);
    }

    if (std.mem.eql(u8, command, "watch")) {
        if (args.next() != null) return usageError();
        return readOnlyCommand(battery.watch);
    }

    if (std.mem.eql(u8, command, "raw-status")) {
        if (args.next() != null) return usageError();
        return readOnlyCommand(battery.rawStatus);
    }

    if (std.mem.eql(u8, command, "disable")) {
        const options = parseWriteOptions(&args) orelse return usageError();
        if (!isRoot()) return fail("Error: run with sudo\n", .{});
        return writeBatteryCommand("CH0B", options, battery.disable);
    }

    if (std.mem.eql(u8, command, "enable")) {
        const options = parseWriteOptions(&args) orelse return usageError();
        if (!isRoot()) return fail("Error: run with sudo\n", .{});
        return writeBatteryCommand("CH0B", options, battery.enable);
    }

    if (std.mem.eql(u8, command, "limit")) {
        const limit_arg = args.next() orelse return usageError();
        if (std.mem.eql(u8, limit_arg, "reset")) {
            if (args.next() != null) return usageError();
            if (!isRoot()) return fail("Error: run with sudo\n", .{});
            return writeSmcCommand("BCLM", battery.resetLimit);
        }

        if (args.next() != null) return usageError();

        const limit = std.fmt.parseInt(u8, limit_arg, 10) catch {
            return fail("Error: limit must be between 20 and 100\n", .{});
        };

        if (limit < 20 or limit > 100) {
            return fail("Error: limit must be between 20 and 100\n", .{});
        }

        if (!isRoot()) return fail("Error: run with sudo\n", .{});

        battery.setLimit(limit) catch |err| {
            return switch (err) {
                error.CannotOpen => fail("Error: cannot open SMC\n", .{}),
                else => fail("Error: SMC write failed for BCLM\n", .{}),
            };
        };
        return 0;
    }

    return usageError();
}

fn statusCommand() u8 {
    return readOnlyCommand(battery.status);
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

fn parseWriteOptions(args: anytype) ?battery.WriteOptions {
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
