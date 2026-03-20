const std = @import("std");
const smc = @import("smc.zig");
const c = smc.c;

const menu_bar_note = "menu bar icon can lag by 1-2 min after a real battery current change";
const fast_observation_interval_ms: u32 = 250;
const fast_observation_max_wait_ms: u32 = 750;
const wait_observation_interval_ms: u32 = 1000;
const wait_observation_max_wait_ms: u32 = 120_000;
const watch_refresh_ns = std.time.ns_per_s;
const charge_bar_width: usize = 10;
const max_percent: i64 = 100;
const apple_silicon_charge_limit: u8 = 80;
const charge_limit_reset_value: u8 = 100;
const direct_charge_limit_blocked_macos_major: u32 = 15;
const max_product_version_len: usize = 32;
const overview_buffer_size = 2048;
const debug_buffer_size = 4096;
const raw_status_buffer_size = 8192;
const verification_buffer_size = 1024;

pub const Error = smc.Error || error{
    BatteryNotFound,
    ChargeLimitBlockedByMacOS,
    ChargeLimitUnsupported,
    InvalidCapacity,
    OutputFailed,
    PowerSourceUnavailable,
};

pub const WriteOptions = struct {
    wait: bool = false,
};

const PowerSourceInfo = struct {
    current_capacity: i64,
    max_capacity: i64,
    percent: u8,
    is_charging: bool,
    plugged_in: bool,
    power_source_state: [32]u8 = [_]u8{0} ** 32,
    power_source_state_len: usize = 0,
    cycles: ?u32,
    health: [64]u8 = [_]u8{0} ** 64,
    health_len: usize = 0,
};

const RegistryInfo = struct {
    current_capacity: ?i64,
    max_capacity: ?i64,
    cycle_count: ?i64,
    charging_current: ?i64,
    charger_inhibit_reason: ?i64,
    not_charging_reason: ?i64,
    is_charging: ?bool,
    fully_charged: ?bool,
    external_connected: ?bool,
    external_charge_capable: ?bool,
};

const ChargingInhibitProbe = struct {
    key_name: []const u8,
    bytes: [4]u8 = [_]u8{0} ** 4,
    byte_len: usize,
    inhibited: bool,
};

const ChargingSnapshot = struct {
    key_name: []const u8,
    inhibited: bool,
    charging_now: bool,
    charging_current: ?i64,
    fully_charged: bool,
    percent: u8,
    plugged_in: bool,
};

const BatteryState = struct {
    power: PowerSourceInfo,
    registry: RegistryInfo,
    charging_inhibit: ChargingInhibitProbe,
    charge_limit: ?ChargeLimitProbe,
    actual_charging: bool,
};

const ChargeLimitProbe = struct {
    key_name: []const u8,
    raw_value: u8,
    interpreted_limit: u8,
};

const VerificationAction = enum {
    disable,
    enable,
};

const ObservationPlan = struct {
    interval_ms: u32,
    max_wait_ms: u32,
};

const WriteObservation = struct {
    snapshot: ChargingSnapshot,
    elapsed_ms: u32,
    settled: bool,
};

pub fn disable(options: WriteOptions) Error!void {
    var session = try smc.Session.open();
    defer session.close();
    try writeChargingInhibit(&session, true);
    const observation = try observeChargingTransition(&session, .disable, options);
    try printVerificationResult(.disable, observation, options.wait);
}

pub fn enable(options: WriteOptions) Error!void {
    var session = try smc.Session.open();
    defer session.close();
    try writeChargingInhibit(&session, false);
    const observation = try observeChargingTransition(&session, .enable, options);
    try printVerificationResult(.enable, observation, options.wait);
}

pub fn setLimit(limit: u8) Error!void {
    if (isDirectChargeLimitBlockedByMacOS()) return error.ChargeLimitBlockedByMacOS;
    var session = try smc.Session.open();
    defer session.close();
    try writeChargeLimit(&session, limit);
}

pub fn resetLimit() Error!void {
    try setLimit(charge_limit_reset_value);
}

pub fn status() Error!void {
    var session = try smc.Session.open();
    defer session.close();
    const state = try readBatteryState(&session);
    try printBatteryOverview("Battery Status", state);
}

pub fn debug() Error!void {
    var session = try smc.Session.open();
    defer session.close();
    const state = try readBatteryState(&session);

    var buffer: [debug_buffer_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    writer.writeAll("══════════════════════════════\n") catch unreachable;
    writer.writeAll("  Charging Diagnostics\n") catch unreachable;
    writer.writeAll("══════════════════════════════\n") catch unreachable;
    writer.print("  SMC inhibit:   {s} via {s} = ", .{
        if (state.charging_inhibit.inhibited) "enabled" else "disabled",
        state.charging_inhibit.key_name,
    }) catch unreachable;
    writeHexBytes(writer, state.charging_inhibit.bytes[0..state.charging_inhibit.byte_len]);
    writer.writeAll("\n") catch unreachable;

    if (state.charge_limit) |limit| {
        writer.print("  Charge limit:  {d}% via {s} = 0x{x:0>2}\n", .{
            limit.interpreted_limit,
            limit.key_name,
            limit.raw_value,
        }) catch unreachable;
    } else {
        writer.writeAll("  Charge limit:  unavailable on this Mac\n") catch unreachable;
    }

    const charging_current = state.registry.charging_current;
    const pack_state = packStateLabel(state.actual_charging, charging_current);

    writer.print("  Pack state:    {s}\n", .{pack_state}) catch unreachable;
    writer.print("  Actual charging: {s}\n", .{actualChargingLabel(state.charging_inhibit.inhibited, state.actual_charging)}) catch unreachable;
    writer.print("  Charge current:{s}", .{if (charging_current != null) " " else " unavailable\n"}) catch unreachable;
    if (charging_current) |current| {
        writer.print("{d} mA\n", .{current}) catch unreachable;
    }
    writer.print("  Fully charged: {s}\n", .{yesNo(stateIsFullyCharged(state))}) catch unreachable;
    writer.print("  Plugged in:    {s}\n", .{yesNo(stateIsPluggedIn(state))}) catch unreachable;

    writer.writeAll("  Verdict:       ") catch unreachable;
    writer.writeAll(debugVerdict(
        state.actual_charging,
        stateIsFullyCharged(state),
        state.power.percent,
        state.charging_inhibit.inhibited,
    )) catch unreachable;
    writer.writeAll("\n") catch unreachable;

    writer.print("  Menu bar note: {s}\n", .{menu_bar_note}) catch unreachable;
    if (stateIsFullyCharged(state)) {
        writer.writeAll("  Test note:     at 100% this does not prove inhibit works; discharge below 95% and rerun\n") catch unreachable;
    }

    writer.writeAll("══════════════════════════════\n") catch unreachable;
    std.fs.File.stdout().writeAll(stream.getWritten()) catch return error.OutputFailed;
}

pub fn watch() Error!void {
    while (true) {
        var session = try smc.Session.open();
        defer session.close();

        const state = try readBatteryState(&session);

        var buffer: [overview_buffer_size]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        const writer = stream.writer();

        writer.writeAll("\x1b[2J\x1b[H") catch unreachable;
        writer.writeAll("══════════════════════════════\n") catch unreachable;
        writer.writeAll("  Battery Watch\n") catch unreachable;
        writer.writeAll("══════════════════════════════\n") catch unreachable;

        writeBatteryOverviewBody(writer, state);

        writer.writeAll("  Refresh:       every 1s\n") catch unreachable;
        writer.writeAll("  Exit:          Ctrl-C\n") catch unreachable;
        writer.writeAll("══════════════════════════════\n") catch unreachable;

        std.fs.File.stdout().writeAll(stream.getWritten()) catch return error.OutputFailed;
        std.Thread.sleep(watch_refresh_ns);
    }
}

pub fn rawStatus() Error!void {
    var session = try smc.Session.open();
    defer session.close();

    const state = try readBatteryState(&session);

    var buffer: [raw_status_buffer_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    writer.writeAll("══════════════════════════════\n") catch unreachable;
    writer.writeAll("  Raw Battery Status\n") catch unreachable;
    writer.writeAll("══════════════════════════════\n") catch unreachable;

    writer.writeAll("  IOPS\n") catch unreachable;
    writer.print("    CurrentCapacity:    {d}\n", .{state.power.current_capacity}) catch unreachable;
    writer.print("    MaxCapacity:        {d}\n", .{state.power.max_capacity}) catch unreachable;
    writer.print("    Percent:            {d}\n", .{state.power.percent}) catch unreachable;
    writer.print("    IsCharging:         {s}\n", .{yesNo(state.power.is_charging)}) catch unreachable;
    writer.print("    PowerSourceState:   {s}\n", .{powerStateSlice(&state.power)}) catch unreachable;
    writer.print("    Health:             {s}\n", .{healthSlice(&state.power)}) catch unreachable;
    if (state.power.cycles) |cycles| {
        writer.print("    CycleCount:         {d}\n", .{cycles}) catch unreachable;
    } else {
        writer.writeAll("    CycleCount:         unavailable\n") catch unreachable;
    }

    writer.writeAll("  AppleSmartBattery\n") catch unreachable;
    writeMaybeInt(writer, "    CurrentCapacity", state.registry.current_capacity);
    writeMaybeInt(writer, "    MaxCapacity", state.registry.max_capacity);
    writeMaybeInt(writer, "    CycleCount", state.registry.cycle_count);
    writeMaybeBool(writer, "    IsCharging", state.registry.is_charging);
    writeMaybeBool(writer, "    FullyCharged", state.registry.fully_charged);
    writeMaybeBool(writer, "    ExternalConnected", state.registry.external_connected);
    writeMaybeBool(writer, "    ExternalChargeCapable", state.registry.external_charge_capable);
    writeMaybeInt(writer, "    ChargingCurrent", state.registry.charging_current);
    writeMaybeInt(writer, "    ChargerInhibitReason", state.registry.charger_inhibit_reason);
    writeMaybeInt(writer, "    NotChargingReason", state.registry.not_charging_reason);

    writer.writeAll("  SMC\n") catch unreachable;
    writeSmcProbe(writer, &session, "CH0B");
    writeSmcProbe(writer, &session, "CH0C");
    writeSmcProbe(writer, &session, "CHTE");
    writeSmcProbe(writer, &session, "BCLM");
    writeSmcProbe(writer, &session, "CHWA");

    writer.writeAll("══════════════════════════════\n") catch unreachable;
    std.fs.File.stdout().writeAll(stream.getWritten()) catch return error.OutputFailed;
}

fn readBatteryState(session: *smc.Session) Error!BatteryState {
    const power = try readPowerSourceInfo();
    const registry = readBatteryRegistryInfo();
    const charging_inhibit = try probeChargingInhibit(session);
    const charge_limit = probeChargeLimit(session) catch |err| switch (err) {
        error.KeyNotFound => null,
        else => return err,
    };

    return .{
        .power = power,
        .registry = registry,
        .charging_inhibit = charging_inhibit,
        .charge_limit = charge_limit,
        .actual_charging = effectiveIsCharging(
            registry.is_charging orelse power.is_charging,
            registry.charging_current,
        ),
    };
}

fn printBatteryOverview(title: []const u8, state: BatteryState) Error!void {
    var buffer: [overview_buffer_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    writer.writeAll("══════════════════════════════\n") catch unreachable;
    writer.print("  {s}\n", .{title}) catch unreachable;
    writer.writeAll("══════════════════════════════\n") catch unreachable;
    writeBatteryOverviewBody(writer, state);
    writer.writeAll("══════════════════════════════\n") catch unreachable;

    std.fs.File.stdout().writeAll(stream.getWritten()) catch return error.OutputFailed;
}

fn writeBatteryOverviewBody(writer: anytype, state: BatteryState) void {
    const filled = chargeBarSegments(state.power.percent);
    writer.writeAll("  Charge:           ") catch unreachable;
    for (0..charge_bar_width) |index| {
        writer.writeAll(if (index < filled) "█" else "░") catch unreachable;
    }
    writer.print(" {d}%\n", .{state.power.percent}) catch unreachable;

    writer.print("  Actual charging:  {s}\n", .{
        actualChargingLabel(state.charging_inhibit.inhibited, state.actual_charging),
    }) catch unreachable;
    writer.print("  Charge current:{s}", .{
        if (state.registry.charging_current != null) "   " else "   unavailable\n",
    }) catch unreachable;
    if (state.registry.charging_current) |current| {
        writer.print("{d} mA\n", .{current}) catch unreachable;
    }
    writer.print("  SMC inhibit:      {s}\n", .{
        if (state.charging_inhibit.inhibited) "enabled" else "disabled",
    }) catch unreachable;
    writer.print("  Plugged in:       {s}\n", .{yesNo(stateIsPluggedIn(state))}) catch unreachable;
    writer.print("  Health:           {s}\n", .{healthSlice(&state.power)}) catch unreachable;

    if (state.power.cycles) |cycles| {
        writer.print("  Cycles:           {d}\n", .{cycles}) catch unreachable;
    } else {
        writer.writeAll("  Cycles:           Unknown\n") catch unreachable;
    }

    if (state.charge_limit) |charge_limit| {
        if (charge_limit.interpreted_limit == 100) {
            writer.writeAll("  Limit:            none\n") catch unreachable;
        } else {
            writer.print("  Limit:            {d}%\n", .{charge_limit.interpreted_limit}) catch unreachable;
        }
    } else {
        writer.writeAll("  Limit:            none\n") catch unreachable;
    }

    writer.print("  Menu bar note:    {s}\n", .{menu_bar_note}) catch unreachable;
}

fn readPowerSourceInfo() Error!PowerSourceInfo {
    const snapshot = c.IOPSCopyPowerSourcesInfo();
    if (snapshot == null) return error.PowerSourceUnavailable;
    defer c.CFRelease(snapshot);

    const sources = c.IOPSCopyPowerSourcesList(snapshot);
    if (sources == null) return error.PowerSourceUnavailable;
    defer c.CFRelease(sources);

    if (c.CFArrayGetCount(sources) == 0) return error.BatteryNotFound;

    const source = c.CFArrayGetValueAtIndex(sources, 0);
    const description = c.IOPSGetPowerSourceDescription(snapshot, source);
    if (description == null) return error.PowerSourceUnavailable;

    const current_capacity = dictGetInt(description, "Current Capacity") orelse return error.InvalidCapacity;
    const max_capacity = dictGetInt(description, "Max Capacity") orelse return error.InvalidCapacity;
    if (current_capacity < 0 or max_capacity <= 0) return error.InvalidCapacity;

    var info = PowerSourceInfo{
        .current_capacity = current_capacity,
        .max_capacity = max_capacity,
        .percent = percentage(current_capacity, max_capacity),
        .is_charging = dictGetBool(description, "Is Charging") orelse false,
        .plugged_in = false,
        .cycles = null,
    };

    if (dictGetString(description, "Power Source State", &info.power_source_state)) |state| {
        info.power_source_state_len = state.len;
        info.plugged_in = std.mem.eql(u8, state, "AC Power");
    }

    if (dictGetString(description, "BatteryHealth", &info.health)) |health| {
        info.health_len = health.len;
    } else {
        std.mem.copyForwards(u8, info.health[0.."Unknown".len], "Unknown");
        info.health_len = "Unknown".len;
    }

    if (dictGetInt(description, "Cycle Count") orelse readBatteryRegistryInt("CycleCount")) |cycles| {
        if (cycles >= 0) {
            info.cycles = @intCast(cycles);
        }
    }

    return info;
}

fn healthSlice(info: *const PowerSourceInfo) []const u8 {
    return info.health[0..info.health_len];
}

fn powerStateSlice(info: *const PowerSourceInfo) []const u8 {
    return info.power_source_state[0..info.power_source_state_len];
}

fn percentage(current_capacity: i64, max_capacity: i64) u8 {
    const numerator = current_capacity * max_percent + @divTrunc(max_capacity, 2);
    const rounded = @min(max_percent, @divTrunc(numerator, max_capacity));
    return @intCast(rounded);
}

fn chargeBarSegments(percent: u8) usize {
    if (percent == 0) return 0;
    return @min(charge_bar_width, @divTrunc(@as(usize, percent) + (charge_bar_width - 1), charge_bar_width));
}

fn actualChargingLabel(inhibited: bool, is_charging: bool) []const u8 {
    if (inhibited) return "no (inhibited)";
    return if (is_charging) "yes" else "no";
}

fn probeChargingInhibit(session: *smc.Session) smc.Error!ChargingInhibitProbe {
    const legacy = session.read("CH0B") catch |err| switch (err) {
        error.KeyNotFound => null,
        else => return err,
    };
    if (legacy) |value| {
        return .{
            .key_name = "CH0B",
            .bytes = .{ value.bytes[0], 0, 0, 0 },
            .byte_len = 1,
            .inhibited = value.bytes[0] != 0,
        };
    }

    const fallback = session.read("CH0C") catch |err| switch (err) {
        error.KeyNotFound => null,
        else => return err,
    };
    if (fallback) |value| {
        return .{
            .key_name = "CH0C",
            .bytes = .{ value.bytes[0], 0, 0, 0 },
            .byte_len = 1,
            .inhibited = value.bytes[0] != 0,
        };
    }

    const tahoe = try session.read("CHTE");
    return .{
        .key_name = "CHTE",
        .bytes = .{ tahoe.bytes[0], tahoe.bytes[1], tahoe.bytes[2], tahoe.bytes[3] },
        .byte_len = @min(@as(usize, 4), @as(usize, tahoe.size)),
        .inhibited = tahoe.bytes[0] != 0,
    };
}

fn writeChargingInhibit(session: *smc.Session, inhibited: bool) smc.Error!void {
    session.writeU8("CH0B", if (inhibited) 1 else 0) catch |err| switch (err) {
        error.KeyNotFound => return writeChargingInhibitFallback(session, inhibited),
        else => return err,
    };
}

fn writeChargingInhibitFallback(session: *smc.Session, inhibited: bool) smc.Error!void {
    const tahoe_bytes = if (inhibited)
        [_]u8{ 1, 0, 0, 0 }
    else
        [_]u8{ 0, 0, 0, 0 };

    session.write("CHTE", &tahoe_bytes) catch |err| switch (err) {
        error.KeyNotFound => try session.writeU8("CH0C", if (inhibited) 2 else 0),
        else => return err,
    };
}

fn observeChargingTransition(
    session: *smc.Session,
    action: VerificationAction,
    options: WriteOptions,
) Error!WriteObservation {
    const plan = observationPlan(options.wait);

    var elapsed_ms: u32 = 0;
    var snapshot = try captureChargingSnapshot(session);
    var settled = verificationSatisfied(action, snapshot);

    while (!settled and elapsed_ms < plan.max_wait_ms) {
        std.Thread.sleep(@as(u64, plan.interval_ms) * std.time.ns_per_ms);
        elapsed_ms += plan.interval_ms;
        snapshot = try captureChargingSnapshot(session);
        settled = verificationSatisfied(action, snapshot);
    }

    return .{
        .snapshot = snapshot,
        .elapsed_ms = elapsed_ms,
        .settled = settled,
    };
}

fn observationPlan(wait: bool) ObservationPlan {
    return if (wait)
        .{
            .interval_ms = wait_observation_interval_ms,
            .max_wait_ms = wait_observation_max_wait_ms,
        }
    else
        .{
            .interval_ms = fast_observation_interval_ms,
            .max_wait_ms = fast_observation_max_wait_ms,
        };
}

fn captureChargingSnapshot(session: *smc.Session) Error!ChargingSnapshot {
    const state = try readBatteryState(session);

    return .{
        .key_name = state.charging_inhibit.key_name,
        .inhibited = state.charging_inhibit.inhibited,
        .charging_now = state.actual_charging,
        .charging_current = state.registry.charging_current,
        .fully_charged = stateIsFullyCharged(state),
        .percent = state.power.percent,
        .plugged_in = stateIsPluggedIn(state),
    };
}

fn verificationSatisfied(action: VerificationAction, snapshot: ChargingSnapshot) bool {
    return switch (action) {
        .disable => snapshot.inhibited and !snapshot.charging_now,
        .enable => !snapshot.inhibited and (!shouldExpectCharging(snapshot) or snapshot.charging_now),
    };
}

fn shouldExpectCharging(snapshot: ChargingSnapshot) bool {
    return snapshot.plugged_in and !snapshot.fully_charged and snapshot.percent < 100;
}

fn verificationResult(action: VerificationAction, snapshot: ChargingSnapshot, settled: bool) []const u8 {
    return switch (action) {
        .disable => if (!snapshot.inhibited)
            "SMC write returned, but charging inhibit is not reflected yet"
        else if (snapshot.charging_now)
            "SMC inhibit is enabled, but battery current is still flowing"
        else if (settled)
            "battery current stopped and charging inhibit is active"
        else
            "battery current stopped, but verification did not fully settle",
        .enable => if (snapshot.inhibited)
            "SMC write returned, but charging inhibit is still enabled"
        else if (!snapshot.plugged_in)
            "inhibit cleared; AC power is not connected"
        else if (snapshot.fully_charged or snapshot.percent == 100)
            "inhibit cleared; battery is full, so current may stay at 0 mA"
        else if (snapshot.charging_now)
            "battery current resumed"
        else if (settled)
            "inhibit cleared, but charging is not expected right now"
        else
            "inhibit cleared, but battery current has not resumed yet",
    };
}

fn printVerificationResult(
    action: VerificationAction,
    observation: WriteObservation,
    waited_for_settle: bool,
) Error!void {
    var buffer: [verification_buffer_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();
    const snapshot = observation.snapshot;

    writer.writeAll("══════════════════════════════\n") catch unreachable;
    writer.print("  Charging {s} Result\n", .{
        if (action == .enable) "Enable" else "Disable",
    }) catch unreachable;
    writer.writeAll("══════════════════════════════\n") catch unreachable;
    writer.print("  SMC inhibit:   {s} via {s}\n", .{
        if (snapshot.inhibited) "enabled" else "disabled",
        snapshot.key_name,
    }) catch unreachable;
    writer.print("  Plugged in:    {s}\n", .{yesNo(snapshot.plugged_in)}) catch unreachable;
    writer.print("  Actual charging: {s}\n", .{actualChargingLabel(snapshot.inhibited, snapshot.charging_now)}) catch unreachable;
    if (snapshot.charging_current) |current| {
        writer.print("  Charge current:{d: >5} mA\n", .{current}) catch unreachable;
    } else {
        writer.writeAll("  Charge current: unavailable\n") catch unreachable;
    }
    writer.print("  Observed:      {d}.{d:0>1}s\n", .{
        observation.elapsed_ms / 1000,
        (observation.elapsed_ms % 1000) / 100,
    }) catch unreachable;
    writer.print("  Result:        {s}\n", .{
        verificationResult(action, snapshot, observation.settled),
    }) catch unreachable;
    writer.print("  Menu bar note: {s}\n", .{menu_bar_note}) catch unreachable;
    if (!waited_for_settle and !observation.settled) {
        writer.writeAll("  Hint:          use --wait or `zatt watch` for live confirmation\n") catch unreachable;
    }
    writer.writeAll("══════════════════════════════\n") catch unreachable;

    std.fs.File.stdout().writeAll(stream.getWritten()) catch return error.OutputFailed;
}

fn probeChargeLimit(session: *smc.Session) smc.Error!ChargeLimitProbe {
    const direct = session.readU8("BCLM") catch |err| switch (err) {
        error.KeyNotFound => null,
        else => return err,
    };
    if (direct) |value| {
        return .{
            .key_name = "BCLM",
            .raw_value = value,
            .interpreted_limit = value,
        };
    }

    const fallback = try session.readU8("CHWA");
    return .{
        .key_name = "CHWA",
        .raw_value = fallback,
        .interpreted_limit = interpretChargeLimitFallback(fallback),
    };
}

fn writeChargeLimit(session: *smc.Session, limit: u8) Error!void {
    session.writeU8("BCLM", limit) catch |bclm_err| {
        switch (bclm_err) {
            error.KeyNotFound, error.CallFailed, error.InvalidResponse => {},
            else => return bclm_err,
        }

        const fallback_value = chargeLimitFallbackValue(limit) orelse {
            return switch (bclm_err) {
                error.KeyNotFound => error.ChargeLimitUnsupported,
                else => bclm_err,
            };
        };

        session.writeU8("CHWA", fallback_value) catch |chwa_err| {
            return switch (chwa_err) {
                error.KeyNotFound => switch (bclm_err) {
                    error.KeyNotFound => error.ChargeLimitUnsupported,
                    else => bclm_err,
                },
                else => chwa_err,
            };
        };
    };
}

fn chargeLimitFallbackValue(limit: u8) ?u8 {
    return switch (limit) {
        apple_silicon_charge_limit => 1,
        charge_limit_reset_value => 0,
        else => null,
    };
}

fn isDirectChargeLimitBlockedByMacOS() bool {
    const major = currentMacOsMajorVersion() orelse return false;
    return major >= direct_charge_limit_blocked_macos_major;
}

fn currentMacOsMajorVersion() ?u32 {
    var buffer = [_]u8{0} ** max_product_version_len;
    var len: usize = buffer.len;
    std.posix.sysctlbynameZ("kern.osproductversion", buffer[0..].ptr, &len, null, 0) catch return null;
    const version = std.mem.sliceTo(buffer[0..@min(len, buffer.len)], 0);
    return parseProductVersionMajor(version);
}

fn parseProductVersionMajor(version: []const u8) ?u32 {
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = parts.next() orelse return null;
    return std.fmt.parseInt(u32, major, 10) catch null;
}

fn dictGetInt(dict: c.CFDictionaryRef, key_name: [*:0]const u8) ?i64 {
    const value = dictGetValue(dict, key_name) orelse return null;
    var result: i64 = 0;
    const number: c.CFNumberRef = @ptrCast(@alignCast(value));
    if (c.CFNumberGetValue(number, c.kCFNumberSInt64Type, &result) == 0) return null;
    return result;
}

fn dictGetBool(dict: c.CFDictionaryRef, key_name: [*:0]const u8) ?bool {
    const value = dictGetValue(dict, key_name) orelse return null;
    const boolean: c.CFBooleanRef = @ptrCast(@alignCast(value));
    return c.CFBooleanGetValue(boolean) != 0;
}

fn dictGetString(dict: c.CFDictionaryRef, key_name: [*:0]const u8, buffer: []u8) ?[]const u8 {
    const value = dictGetValue(dict, key_name) orelse return null;
    const string: c.CFStringRef = @ptrCast(@alignCast(value));
    if (buffer.len == 0) return null;
    if (c.CFStringGetCString(string, buffer.ptr, @intCast(buffer.len), c.kCFStringEncodingUTF8) == 0) return null;
    return std.mem.sliceTo(buffer, 0);
}

fn dictGetValue(dict: c.CFDictionaryRef, key_name: [*:0]const u8) ?*const anyopaque {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_name, c.kCFStringEncodingUTF8);
    if (key == null) return null;
    defer c.CFRelease(key);

    return c.CFDictionaryGetValue(dict, key);
}

fn readBatteryRegistryInfo() RegistryInfo {
    return .{
        .current_capacity = readBatteryRegistryInt("CurrentCapacity"),
        .max_capacity = readBatteryRegistryInt("MaxCapacity"),
        .cycle_count = readBatteryRegistryInt("CycleCount"),
        .charging_current = readBatteryRegistryInt("ChargingCurrent") orelse readBatteryRegistryNestedInt("ChargerData", "ChargingCurrent"),
        .charger_inhibit_reason = readBatteryRegistryInt("ChargerInhibitReason") orelse readBatteryRegistryNestedInt("ChargerData", "ChargerInhibitReason"),
        .not_charging_reason = readBatteryRegistryInt("NotChargingReason") orelse readBatteryRegistryNestedInt("ChargerData", "NotChargingReason"),
        .is_charging = readBatteryRegistryBool("IsCharging"),
        .fully_charged = readBatteryRegistryBool("FullyCharged"),
        .external_connected = readBatteryRegistryBool("ExternalConnected"),
        .external_charge_capable = readBatteryRegistryBool("ExternalChargeCapable"),
    };
}

fn readBatteryRegistryInt(property_name: [*:0]const u8) ?i64 {
    const value = readBatteryRegistryProperty(property_name) orelse return null;
    defer c.CFRelease(value);

    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return null;

    var result: i64 = 0;
    const number: c.CFNumberRef = @ptrCast(@alignCast(value));
    if (c.CFNumberGetValue(number, c.kCFNumberSInt64Type, &result) == 0) return null;
    return result;
}

fn readBatteryRegistryBool(property_name: [*:0]const u8) ?bool {
    const value = readBatteryRegistryProperty(property_name) orelse return null;
    defer c.CFRelease(value);

    if (c.CFGetTypeID(value) != c.CFBooleanGetTypeID()) return null;
    const boolean: c.CFBooleanRef = @ptrCast(@alignCast(value));
    return c.CFBooleanGetValue(boolean) != 0;
}

fn readBatteryRegistryNestedInt(group_name: [*:0]const u8, property_name: [*:0]const u8) ?i64 {
    const value = readBatteryRegistryProperty(group_name) orelse return null;
    defer c.CFRelease(value);

    if (c.CFGetTypeID(value) != c.CFDictionaryGetTypeID()) return null;
    const dict: c.CFDictionaryRef = @ptrCast(@alignCast(value));
    return dictGetInt(dict, property_name);
}

fn readBatteryRegistryProperty(property_name: [*:0]const u8) ?c.CFTypeRef {
    const matching = c.IOServiceMatching("AppleSmartBattery") orelse return null;
    const service = c.IOServiceGetMatchingService(c.kIOMainPortDefault, matching);
    if (service == 0) return null;
    defer _ = c.IOObjectRelease(service);

    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, property_name, c.kCFStringEncodingUTF8);
    if (key == null) return null;
    defer c.CFRelease(key);

    const value = c.IORegistryEntryCreateCFProperty(service, key, c.kCFAllocatorDefault, 0);
    if (value == null) return null;
    return value;
}

fn writeMaybeInt(writer: anytype, label: []const u8, value: ?i64) void {
    if (value) |number| {
        writer.print("{s}: {d}\n", .{ label, number }) catch unreachable;
    } else {
        writer.print("{s}: unavailable\n", .{label}) catch unreachable;
    }
}

fn writeMaybeBool(writer: anytype, label: []const u8, value: ?bool) void {
    if (value) |boolean| {
        writer.print("{s}: {s}\n", .{ label, yesNo(boolean) }) catch unreachable;
    } else {
        writer.print("{s}: unavailable\n", .{label}) catch unreachable;
    }
}

fn writeSmcProbe(writer: anytype, session: *smc.Session, comptime key_name: []const u8) void {
    const result = session.read(key_name) catch |err| switch (err) {
        error.KeyNotFound => {
            writer.print("    {s}: not found\n", .{key_name}) catch unreachable;
            return;
        },
        else => {
            writer.print("    {s}: error ({s})\n", .{ key_name, @errorName(err) }) catch unreachable;
            return;
        },
    };

    writer.print("    {s}: ", .{key_name}) catch unreachable;
    writeHexBytes(writer, result.bytes[0..@as(usize, result.size)]);
    writer.writeAll("\n") catch unreachable;
}

fn writeHexBytes(writer: anytype, bytes: []const u8) void {
    for (bytes, 0..) |byte, index| {
        if (index != 0) {
            writer.writeAll(" ") catch unreachable;
        }
        writer.print("0x{x:0>2}", .{byte}) catch unreachable;
    }
}

fn packStateLabel(is_charging: bool, charging_current: ?i64) []const u8 {
    if (is_charging) return "charging";
    if (charging_current) |current| {
        if (current > 0) return "charging";
        if (current < 0) return "discharging";
        return "idle";
    }
    return "not charging";
}

fn debugVerdict(charging_now: bool, fully_charged: bool, percent: u8, inhibited: bool) []const u8 {
    if (charging_now) return "battery is actively charging";
    if (fully_charged or percent == 100) return "battery is on external power but not taking charge";
    if (inhibited) return "charging appears inhibited and current is not flowing into the pack";
    return "battery is not charging, but SMC inhibit is not enabled";
}

fn effectiveIsCharging(is_charging: bool, charging_current: ?i64) bool {
    if (is_charging) return true;
    if (charging_current) |current| {
        return current > 0;
    }
    return false;
}

fn interpretChargeLimitFallback(raw_value: u8) u8 {
    return if (raw_value == 1) 80 else 100;
}

fn stateIsFullyCharged(state: BatteryState) bool {
    return state.registry.fully_charged orelse (state.power.percent == 100);
}

fn stateIsPluggedIn(state: BatteryState) bool {
    return state.registry.external_connected orelse state.power.plugged_in;
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn testSnapshot(
    inhibited: bool,
    charging_now: bool,
    fully_charged: bool,
    percent: u8,
    plugged_in: bool,
) ChargingSnapshot {
    return .{
        .key_name = "CHTE",
        .inhibited = inhibited,
        .charging_now = charging_now,
        .charging_current = if (charging_now) 1500 else 0,
        .fully_charged = fully_charged,
        .percent = percent,
        .plugged_in = plugged_in,
    };
}

test "percentage rounds and caps at 100" {
    try std.testing.expectEqual(@as(u8, 74), percentage(74, 100));
    try std.testing.expectEqual(@as(u8, 67), percentage(2, 3));
    try std.testing.expectEqual(@as(u8, 100), percentage(101, 100));
}

test "charge bar segments round up to percentage buckets" {
    try std.testing.expectEqual(@as(usize, 0), chargeBarSegments(0));
    try std.testing.expectEqual(@as(usize, 1), chargeBarSegments(1));
    try std.testing.expectEqual(@as(usize, 8), chargeBarSegments(74));
    try std.testing.expectEqual(@as(usize, 10), chargeBarSegments(100));
}

test "actual charging label prioritizes inhibit state" {
    try std.testing.expectEqualStrings("no (inhibited)", actualChargingLabel(true, true));
    try std.testing.expectEqualStrings("yes", actualChargingLabel(false, true));
    try std.testing.expectEqualStrings("no", actualChargingLabel(false, false));
}

test "pack state label reflects charging current and fallback state" {
    try std.testing.expectEqualStrings("charging", packStateLabel(true, null));
    try std.testing.expectEqualStrings("charging", packStateLabel(false, 500));
    try std.testing.expectEqualStrings("discharging", packStateLabel(false, -500));
    try std.testing.expectEqualStrings("idle", packStateLabel(false, 0));
    try std.testing.expectEqualStrings("not charging", packStateLabel(false, null));
}

test "effective charging detection uses charging current as fallback" {
    try std.testing.expect(effectiveIsCharging(true, null));
    try std.testing.expect(effectiveIsCharging(false, 10));
    try std.testing.expect(!effectiveIsCharging(false, 0));
    try std.testing.expect(!effectiveIsCharging(false, -10));
    try std.testing.expect(!effectiveIsCharging(false, null));
}

test "debug verdict explains the dominant charging state" {
    try std.testing.expectEqualStrings(
        "battery is actively charging",
        debugVerdict(true, false, 80, true),
    );
    try std.testing.expectEqualStrings(
        "battery is on external power but not taking charge",
        debugVerdict(false, true, 100, true),
    );
    try std.testing.expectEqualStrings(
        "charging appears inhibited and current is not flowing into the pack",
        debugVerdict(false, false, 80, true),
    );
    try std.testing.expectEqualStrings(
        "battery is not charging, but SMC inhibit is not enabled",
        debugVerdict(false, false, 80, false),
    );
}

test "charge limit fallback interprets Apple Silicon values" {
    try std.testing.expectEqual(@as(u8, 80), interpretChargeLimitFallback(1));
    try std.testing.expectEqual(@as(u8, 100), interpretChargeLimitFallback(0));
    try std.testing.expectEqual(@as(u8, 100), interpretChargeLimitFallback(2));
}

test "charge limit fallback values only exist for Apple Silicon supported limits" {
    try std.testing.expectEqual(@as(?u8, 1), chargeLimitFallbackValue(80));
    try std.testing.expectEqual(@as(?u8, 0), chargeLimitFallbackValue(100));
    try std.testing.expectEqual(@as(?u8, null), chargeLimitFallbackValue(60));
}

test "parseProductVersionMajor handles current macOS version formats" {
    try std.testing.expectEqual(@as(?u32, 13), parseProductVersionMajor("13.6.7"));
    try std.testing.expectEqual(@as(?u32, 15), parseProductVersionMajor("15.0"));
    try std.testing.expectEqual(@as(?u32, 26), parseProductVersionMajor("26.3.1"));
    try std.testing.expectEqual(@as(?u32, null), parseProductVersionMajor("not-a-version"));
}

test "enable verification waits for charging only when it should" {
    const unplugged = testSnapshot(false, false, false, 80, false);
    try std.testing.expect(verificationSatisfied(.enable, unplugged));

    const plugged_idle = testSnapshot(false, false, false, 80, true);
    try std.testing.expect(!verificationSatisfied(.enable, plugged_idle));
}

test "disable verification waits for inhibit and charging to stop" {
    try std.testing.expect(!verificationSatisfied(.disable, testSnapshot(false, true, false, 80, true)));
    try std.testing.expect(!verificationSatisfied(.disable, testSnapshot(true, true, false, 80, true)));
    try std.testing.expect(verificationSatisfied(.disable, testSnapshot(true, false, false, 80, true)));
}

test "shouldExpectCharging only when plugged in and below full" {
    try std.testing.expect(shouldExpectCharging(testSnapshot(false, false, false, 80, true)));
    try std.testing.expect(!shouldExpectCharging(testSnapshot(false, false, false, 80, false)));
    try std.testing.expect(!shouldExpectCharging(testSnapshot(false, false, true, 80, true)));
    try std.testing.expect(!shouldExpectCharging(testSnapshot(false, false, false, 100, true)));
}

test "verification results explain post-write battery state" {
    try std.testing.expectEqualStrings(
        "battery current resumed",
        verificationResult(.enable, testSnapshot(false, true, false, 80, true), true),
    );
    try std.testing.expectEqualStrings(
        "inhibit cleared; AC power is not connected",
        verificationResult(.enable, testSnapshot(false, false, false, 80, false), true),
    );
    try std.testing.expectEqualStrings(
        "battery current stopped and charging inhibit is active",
        verificationResult(.disable, testSnapshot(true, false, false, 80, true), true),
    );
}

test "verification results cover lagging and full battery cases" {
    try std.testing.expectEqualStrings(
        "SMC write returned, but charging inhibit is not reflected yet",
        verificationResult(.disable, testSnapshot(false, false, false, 80, true), false),
    );
    try std.testing.expectEqualStrings(
        "SMC inhibit is enabled, but battery current is still flowing",
        verificationResult(.disable, testSnapshot(true, true, false, 80, true), false),
    );
    try std.testing.expectEqualStrings(
        "inhibit cleared; battery is full, so current may stay at 0 mA",
        verificationResult(.enable, testSnapshot(false, false, true, 100, true), true),
    );
    try std.testing.expectEqualStrings(
        "SMC write returned, but charging inhibit is still enabled",
        verificationResult(.enable, testSnapshot(true, false, false, 80, true), false),
    );
}

test "battery state helpers fall back to power source values" {
    const base_power = PowerSourceInfo{
        .current_capacity = 80,
        .max_capacity = 100,
        .percent = 80,
        .is_charging = false,
        .plugged_in = true,
        .cycles = null,
    };
    const base_registry = RegistryInfo{
        .current_capacity = null,
        .max_capacity = null,
        .cycle_count = null,
        .charging_current = null,
        .charger_inhibit_reason = null,
        .not_charging_reason = null,
        .is_charging = null,
        .fully_charged = null,
        .external_connected = null,
        .external_charge_capable = null,
    };
    const base_inhibit = ChargingInhibitProbe{
        .key_name = "CHTE",
        .byte_len = 1,
        .inhibited = false,
    };

    var state = BatteryState{
        .power = base_power,
        .registry = base_registry,
        .charging_inhibit = base_inhibit,
        .charge_limit = null,
        .actual_charging = false,
    };
    try std.testing.expect(stateIsPluggedIn(state));
    try std.testing.expect(!stateIsFullyCharged(state));

    state.registry.external_connected = false;
    try std.testing.expect(!stateIsPluggedIn(state));

    state.registry.fully_charged = true;
    try std.testing.expect(stateIsFullyCharged(state));
}

test "observation plan keeps default writes fast and wait mode long-lived" {
    const quick = observationPlan(false);
    try std.testing.expectEqual(fast_observation_interval_ms, quick.interval_ms);
    try std.testing.expectEqual(fast_observation_max_wait_ms, quick.max_wait_ms);

    const wait = observationPlan(true);
    try std.testing.expectEqual(wait_observation_interval_ms, wait.interval_ms);
    try std.testing.expectEqual(wait_observation_max_wait_ms, wait.max_wait_ms);
}
