// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! UTC timestamps in the one RFC 3339 form the store writes
//! (`YYYY-MM-DDTHH:MM:SSZ`), and durations such as `15m` or `1h30m`.

const std = @import("std");

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant).
fn daysFromCivil(y0: i64, m: u32, d: u32) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = @intCast((m + 9) % 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z0: i64) struct { y: i64, m: u32, d: u32 } {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .m = m, .d = d };
}

pub const Stamp = [20]u8;

pub fn format(secs: i64) Stamp {
    const days = @divFloor(secs, 86400);
    const sod: u64 = @intCast(secs - days * 86400);
    const c = civilFromDays(days);
    var out: Stamp = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(c.y)), c.m, c.d, sod / 3600, sod / 60 % 60, sod % 60,
    }) catch unreachable;
    return out;
}

pub fn parse(s: []const u8) error{BadTimestamp}!i64 {
    if (s.len != 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z')
        return error.BadTimestamp;
    const num = struct {
        fn f(x: []const u8) error{BadTimestamp}!u32 {
            for (x) |c| if (!std.ascii.isDigit(c)) return error.BadTimestamp;
            return std.fmt.parseInt(u32, x, 10) catch error.BadTimestamp;
        }
    }.f;
    const y = try num(s[0..4]);
    const mo = try num(s[5..7]);
    const d = try num(s[8..10]);
    const h = try num(s[11..13]);
    const mi = try num(s[14..16]);
    const se = try num(s[17..19]);
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or se > 59) return error.BadTimestamp;
    const days = daysFromCivil(y, mo, d);
    if (civilFromDays(days).d != d) return error.BadTimestamp; // e.g. 31 April
    return days * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60 + se;
}

/// `90s`, `15m`, `1h30m`: one or more <digits><s|m|h> parts, total > 0.
pub fn parseDuration(s: []const u8) error{BadDuration}!i64 {
    var total: i64 = 0;
    var i: usize = 0;
    if (s.len == 0) return error.BadDuration;
    while (i < s.len) {
        const st = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == st or i == s.len or i - st > 9) return error.BadDuration;
        const n = std.fmt.parseInt(i64, s[st..i], 10) catch return error.BadDuration;
        total += n * @as(i64, switch (s[i]) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            else => return error.BadDuration,
        });
        i += 1;
    }
    if (total <= 0) return error.BadDuration;
    return total;
}

test "round trip and refusals" {
    const t = try parse("2026-11-16T12:41:00Z");
    try std.testing.expectEqualStrings("2026-11-16T12:41:00Z", &format(t));
    try std.testing.expectEqual(@as(i64, 0), try parse("1970-01-01T00:00:00Z"));
    try std.testing.expectEqualStrings("2000-02-29T23:59:59Z", &format(try parse("2000-02-29T23:59:59Z")));
    try std.testing.expectError(error.BadTimestamp, parse("2026-04-31T00:00:00Z"));
    try std.testing.expectError(error.BadTimestamp, parse("2026-11-16T12:41:00+01:00"));
    try std.testing.expectEqual(@as(i64, 5400), try parseDuration("1h30m"));
    try std.testing.expectError(error.BadDuration, parseDuration("15"));
    try std.testing.expectError(error.BadDuration, parseDuration("0m"));
}
