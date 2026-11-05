import Foundation

/// "yyyy-MM-dd" 形式的日期键。用 Calendar 直接算，不碰 DateFormatter，
/// 这样既没有共享可变状态，也省掉了格式化器的开销。
struct DayKeyCoder: Sendable {
    let calendar: Calendar

    static let current = DayKeyCoder(calendar: .current)
    static let utc: DayKeyCoder = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return DayKeyCoder(calendar: calendar)
    }()

    func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func date(from key: String) -> Date? {
        let numbers = key.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        var parts = DateComponents()
        parts.year = numbers[0]
        parts.month = numbers[1]
        parts.day = numbers[2]
        return calendar.date(from: parts)
    }
}

/// 所有数字都走系统格式化并显式带上 locale：小数点、千分位、货币符号位置、
/// 12/24 小时制在各地区都不一样，手写格式串一定会在某个市场出洋相。
enum Formatters {
    static func currency(_ value: Double, code: String, fractionDigits: Int = 2) -> String {
        value.formatted(
            .currency(code: code)
                .precision(.fractionLength(fractionDigits))
                .locale(Loc.locale)
        )
    }

    static func percent(_ fraction: Double, fractionDigits: Int = 2) -> String {
        fraction.formatted(
            .percent
                .precision(.fractionLength(fractionDigits))
                .locale(Loc.locale)
        )
    }

    /// 时长交给 Duration 格式化，各语言的单位写法和语序 Apple 已经做好了。
    /// 为零的单位会被省略，所以 24 分 10 秒不会显示成 "0 小时 24 分 10 秒"。
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(Int64(max(seconds, 0).rounded())).formatted(
            .units(
                allowed: [.hours, .minutes, .seconds],
                width: .abbreviated,
                zeroValueUnits: .hide
            )
            .locale(Loc.locale)
        )
    }

    /// 上下班时间点。用日期格式化而不是 "%02d:%02d"，美国用户才会看到 9:00 AM。
    static func clockTime(minutesFromMidnight minutes: Int) -> String {
        let calendar = Loc.calendar
        var parts = DateComponents()
        parts.year = 2001
        parts.month = 1
        parts.day = 1
        parts.hour = (minutes / 60) % 24
        parts.minute = minutes % 60
        guard let date = calendar.date(from: parts) else {
            return String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
        }
        return date.formatted(.dateTime.hour().minute().locale(Loc.locale))
    }
}
