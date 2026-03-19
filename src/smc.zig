const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.target.os.tag != .macos or builtin.target.cpu.arch != .aarch64) {
        @compileError("zatt supports macOS on arm64 only");
    }
}

pub const c = @cImport({
    @cInclude("IOKit/IOKitLib.h");
    @cInclude("IOKit/ps/IOPowerSources.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

pub const Error = error{
    CannotOpen,
    CallFailed,
    InvalidResponse,
    KeyNotFound,
    NotPrivileged,
};

const smc_selector: u32 = 2;
const smc_result_success: u8 = 0;
const smc_result_key_not_found: u8 = 132;
const smc_cmd_get_key_info_candidates = [_]u8{ 1, 9 };
const smc_cmd_read_key: u8 = 5;
const smc_cmd_write_key: u8 = 6;

const SMCVersion = extern struct {
    major: u8 = 0,
    minor: u8 = 0,
    build: u8 = 0,
    reserved: u8 = 0,
    release: u16 = 0,
};

const SMCPLimitData = extern struct {
    version: u16 = 0,
    length: u16 = 0,
    cpuPLimit: u32 = 0,
    gpuPLimit: u32 = 0,
    memPLimit: u32 = 0,
};

pub const SMCKeyInfoData = extern struct {
    dataSize: u32 = 0,
    dataType: u32 = 0,
    dataAttributes: u8 = 0,
};

pub const SMCKeyData = extern struct {
    key: u32 = 0,

    // These opaque blocks are part of the AppleSMC user-client ABI and keep
    // the struct at the 80-byte size expected by IOConnectCallStructMethod.
    vers: SMCVersion = .{},
    pLimitData: SMCPLimitData = .{},

    keyInfo: SMCKeyInfoData = .{},
    result: u8 = 0,
    status: u8 = 0,
    data8: u8 = 0,
    data32: u32 = 0,
    bytes: [32]u8 = [_]u8{0} ** 32,
};

comptime {
    if (@sizeOf(SMCKeyInfoData) != 12) {
        @compileError("SMCKeyInfoData must be 12 bytes");
    }
    if (@sizeOf(SMCKeyData) != 80) {
        @compileError("SMCKeyData must be 80 bytes");
    }
    if (@offsetOf(SMCKeyData, "keyInfo") != 28) {
        @compileError("SMCKeyData.keyInfo offset mismatch");
    }
    if (@offsetOf(SMCKeyData, "bytes") != 48) {
        @compileError("SMCKeyData.bytes offset mismatch");
    }
}

pub const Session = struct {
    connection: c.io_connect_t,

    pub const KeyValue = struct {
        size: u32,
        bytes: [32]u8,
    };

    pub fn open() Error!Session {
        const matching = c.IOServiceMatching("AppleSMC") orelse return error.CannotOpen;
        const service = c.IOServiceGetMatchingService(c.kIOMainPortDefault, matching);
        if (service == 0) return error.CannotOpen;
        defer _ = c.IOObjectRelease(service);

        var connection: c.io_connect_t = 0;
        const result = c.IOServiceOpen(service, c.mach_task_self_, 0, &connection);
        if (result != c.kIOReturnSuccess) return error.CannotOpen;

        return .{ .connection = connection };
    }

    pub fn close(self: *Session) void {
        if (self.connection != 0) {
            _ = c.IOServiceClose(self.connection);
            self.connection = 0;
        }
    }

    pub fn read(self: *Session, comptime key_name: []const u8) Error!KeyValue {
        const key = smcKey(key_name);
        const key_info = try self.getKeyInfo(key);
        if (key_info.dataSize < 1 or key_info.dataSize > 32) {
            return error.InvalidResponse;
        }

        var input = SMCKeyData{
            .key = key,
            .keyInfo = key_info,
            .data8 = smc_cmd_read_key,
        };
        var output = std.mem.zeroes(SMCKeyData);
        try self.call(&input, &output);

        return .{
            .size = key_info.dataSize,
            .bytes = output.bytes,
        };
    }

    pub fn readU8(self: *Session, comptime key_name: []const u8) Error!u8 {
        const value = try self.read(key_name);
        return value.bytes[0];
    }

    pub fn write(self: *Session, comptime key_name: []const u8, data: []const u8) Error!void {
        const key = smcKey(key_name);
        const key_info = try self.getKeyInfo(key);
        if (key_info.dataSize < 1 or key_info.dataSize > 32) {
            return error.InvalidResponse;
        }
        if (data.len == 0 or data.len > key_info.dataSize) {
            return error.InvalidResponse;
        }

        var input = SMCKeyData{
            .key = key,
            .keyInfo = key_info,
            .data8 = smc_cmd_write_key,
        };
        std.mem.copyForwards(u8, input.bytes[0..data.len], data);

        var output = std.mem.zeroes(SMCKeyData);
        try self.call(&input, &output);
    }

    pub fn writeU8(self: *Session, comptime key_name: []const u8, value: u8) Error!void {
        const data = [_]u8{value};
        try self.write(key_name, &data);
    }

    fn getKeyInfo(self: *Session, key: u32) Error!SMCKeyInfoData {
        var last_error: Error = error.InvalidResponse;

        for (smc_cmd_get_key_info_candidates) |command| {
            var input = SMCKeyData{
                .key = key,
                .data8 = command,
            };
            var output = std.mem.zeroes(SMCKeyData);

            self.call(&input, &output) catch |err| {
                switch (err) {
                    error.CallFailed, error.InvalidResponse, error.KeyNotFound => {
                        last_error = err;
                        continue;
                    },
                    else => return err,
                }
            };

            if (output.keyInfo.dataSize >= 1 and output.keyInfo.dataSize <= 32) {
                return output.keyInfo;
            }

            last_error = error.InvalidResponse;
        }

        return last_error;
    }

    fn call(self: *Session, input: *const SMCKeyData, output: *SMCKeyData) Error!void {
        var output_size: usize = @sizeOf(SMCKeyData);
        const result = c.IOConnectCallStructMethod(
            self.connection,
            smc_selector,
            input,
            @sizeOf(SMCKeyData),
            output,
            &output_size,
        );

        if (result == c.kIOReturnNotPrivileged) return error.NotPrivileged;
        if (result != c.kIOReturnSuccess or output_size != @sizeOf(SMCKeyData)) {
            return error.CallFailed;
        }

        switch (output.result) {
            smc_result_success => {},
            smc_result_key_not_found => return error.KeyNotFound,
            else => return error.CallFailed,
        }
    }
};

fn smcKey(comptime key_name: []const u8) u32 {
    if (key_name.len != 4) {
        @compileError("SMC keys must be exactly four characters");
    }

    return (@as(u32, key_name[0]) << 24) |
        (@as(u32, key_name[1]) << 16) |
        (@as(u32, key_name[2]) << 8) |
        @as(u32, key_name[3]);
}

test "smcKey encodes four character keys in big-endian order" {
    try std.testing.expectEqual(@as(u32, 0x43483042), smcKey("CH0B"));
    try std.testing.expectEqual(@as(u32, 0x42434c4d), smcKey("BCLM"));
}
