import Foundation

/// 判定某一天算不算工作日，并统计月/年的工作日数量。
struct WorkCalendar {
    let config: Configuration
    let autoHolidays: Set<String>
    /// 数据源给出的调休上班日，优先级低于用户手动填的任何一项。
    let autoMakeupWorkdays: Set<String>
    let calendar: Calendar

    /// 日期键必须和日历同一个时区，否则跨时区时"今天"会对不上。
    private let keyCoder: DayKeyCoder

    init(
        config: Configuration,
        autoHolidays: Set<String>,
        autoMakeupWorkdays: Set<String> = [],
        calendar: Calendar = .current
    ) {
        self.config = config
        self.autoHolidays = autoHolidays
        self.autoMakeupWorkdays = autoMakeupWorkdays
        self.calendar = calendar
        self.keyCoder = DayKeyCoder(calendar: calendar)
    }

    func dayKey(_ date: Date) -> String {
        keyCoder.key(for: date)
    }

    /// 手动填的调休上班日优先级最高，其次是手动补的假期，然后是官方假日，
    /// 再往后才轮到数据源自带的调休上班日和周末设置。
    func isWorkday(_ date: Date) -> Bool {
        let key = dayKey(date)
        if config.makeupWorkdays.contains(key) { return true }
        if config.extraHolidays.contains(key) { return false }
        if config.useAutoHolidays && autoHolidays.contains(key) { return false }
        if usesAutoMakeup && autoMakeupWorkdays.contains(key) { return true }
        return config.workdays.contains(calendar.component(.weekday, from: date))
    }

    func isHoliday(_ date: Date) -> Bool {
        let key = dayKey(date)
        if config.makeupWorkdays.contains(key) { return false }
        if config.extraHolidays.contains(key) { return true }
        if config.useAutoHolidays && autoHolidays.contains(key) { return true }
        return false
    }

    func leaveEntry(on date: Date) -> LeaveEntry? {
        LeaveLedger(entries: config.leaveEntries).entry(on: dayKey(date))
    }

    /// 请假后的实际工作时段。全天请假返回空；上午/下午假在午休处截半。
    func workingIntervals(on date: Date) -> [ClosedRange<Int>] {
        guard let leave = leaveEntry(on: date), leave.portion != .fullDay else {
            return leaveEntry(on: date)?.portion == .fullDay ? [] : config.paidIntervals
        }

        let split = halfDaySplit
        switch leave.portion {
        case .fullDay:
            return []
        case .morning:
            return config.paidIntervals.compactMap { interval in
                let lower = max(interval.lowerBound, split.end)
                return lower < interval.upperBound ? lower...interval.upperBound : nil
            }
        case .afternoon:
            return config.paidIntervals.compactMap { interval in
                let upper = min(interval.upperBound, split.start)
                return interval.lowerBound < upper ? interval.lowerBound...upper : nil
            }
        }
    }

    /// 当天相对正常日薪的应发比例。非工作日不调用这个值参与收入计算。
    func payableFraction(on date: Date) -> Double {
        leaveEntry(on: date)?.payableFraction ?? 1
    }

    func workFraction(on date: Date) -> Double {
        1 - (leaveEntry(on: date)?.leaveFraction ?? 0)
    }

    func paidSeconds(on date: Date) -> Double {
        workingIntervals(on: date).reduce(0) {
            $0 + Double($1.upperBound - $1.lowerBound) * 60
        }
    }

    private var halfDaySplit: (start: Int, end: Int) {
        if config.breakEnabled {
            let start = min(config.breakStartMinutes, config.breakEndMinutes)
            let end = max(config.breakStartMinutes, config.breakEndMinutes)
            if start > config.startMinutes, end < config.endMinutes {
                return (start, end)
            }
        }
        let midpoint = config.startMinutes + (config.endMinutes - config.startMinutes) / 2
        return (midpoint, midpoint)
    }

    /// 调休本质上是假期数据的一部分，关掉自动假期就一并不用。
    private var usesAutoMakeup: Bool {
        config.useAutoHolidays && config.useAutoMakeupWorkdays
    }

    func workdayCount(in interval: DateInterval) -> Int {
        var count = 0
        enumerateDays(in: interval) { if isWorkday($0) { count += 1 } }
        return count
    }

    /// 本月已经完整过去的工作日，不含今天。
    func completedWorkdaysThisMonth(now: Date) -> Int {
        guard let monthStart = startOfMonth(for: now) else { return 0 }
        let today = calendar.startOfDay(for: now)
        guard today > monthStart else { return 0 }
        return workdayCount(in: DateInterval(start: monthStart, end: today))
    }

    func workdaysInMonth(containing date: Date) -> Int {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return 0 }
        return workdayCount(in: interval)
    }

    func workdaysInYear(containing date: Date) -> Int {
        guard let interval = calendar.dateInterval(of: .year, for: date) else { return 0 }
        return workdayCount(in: interval)
    }

    /// 从明天开始找下一个休息日，用来回答"还要熬几天"。
    func nextDayOff(after date: Date, limit: Int = 400) -> Date? {
        var cursor = calendar.startOfDay(for: date)
        for _ in 0..<limit {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
            if !isWorkday(cursor) { return cursor }
        }
        return nil
    }

    private func startOfMonth(for date: Date) -> Date? {
        calendar.dateInterval(of: .month, for: date)?.start
    }

    /// 半开区间 [start, end)，按天步进。
    private func enumerateDays(in interval: DateInterval, _ body: (Date) -> Void) {
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            body(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { return }
            cursor = next
        }
    }
}
