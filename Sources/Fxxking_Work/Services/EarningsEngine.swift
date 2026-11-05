import Foundation

/// 今天为什么不上班。存原因而不是存翻译好的句子，算钱逻辑就不必知道界面是什么语言，
/// 用户中途切换语言时状态也会跟着变。
enum DayOffReason: Equatable, Sendable {
    /// 假日名直接来自数据源，本身已经是当地语言，不进翻译表。
    case holiday(name: String)
    case restDay
    case noSchedule
}

enum WorkStatus: Equatable {
    case dayOff(DayOffReason)
    case beforeWork
    case working
    case onBreak
    case finished

    var isEarning: Bool { self == .working }
}

struct Earnings {
    var status: WorkStatus = .beforeWork
    var perSecond: Double = 0
    var dayEarned: Double = 0
    var dayTotal: Double = 0
    var dayFraction: Double = 0
    var monthEarned: Double = 0
    var monthTotal: Double = 0
    var monthFraction: Double = 0
    var yearEarned: Double = 0
    var yearTotal: Double = 0
    var yearFraction: Double = 0
    /// 今天还剩多少计薪秒数，午休不算。
    var remainingSecondsToday: Double = 0
    var elapsedSecondsToday: Double = 0
}

/// 离开工位那段时间公司照付的钱。
struct AwayReport: Equatable {
    var start: Date
    var end: Date
    /// 离开的总时长，午休和下班时间也算在内。
    var awaySeconds: Double
    /// 其中真正计薪的部分。午休时锁屏这个值就是 0。
    var paidSeconds: Double
    var amount: Double

    /// 锁屏几十秒就弹一次提示太吵，攒够一分钟计薪时间才值得说。
    static let minimumPaidSeconds: Double = 60

    var isWorthShowing: Bool { paidSeconds >= Self.minimumPaidSeconds }
}

/// 按天预计算一次工作日统计，之后每次取快照都是纯算术，可以每秒刷新而不心疼 CPU。
struct EarningsEngine {
    let config: Configuration
    let calendar: Calendar
    let workCalendar: WorkCalendar
    let dayKey: String

    private let isWorkdayToday: Bool
    private let todayHolidayName: String?
    private let monthWorkdays: Int
    private let completedWorkdays: Int
    private let monthIndex: Int
    private let dailyPay: Double
    private let paidSecondsPerDay: Double

    init(
        config: Configuration,
        autoHolidays: Set<String>,
        autoMakeupWorkdays: Set<String> = [],
        holidayNames: [String: PublicHoliday],
        now: Date,
        calendar: Calendar = .current
    ) {
        self.config = config
        self.calendar = calendar
        self.workCalendar = WorkCalendar(
            config: config,
            autoHolidays: autoHolidays,
            autoMakeupWorkdays: autoMakeupWorkdays,
            calendar: calendar
        )
        self.dayKey = workCalendar.dayKey(now)

        isWorkdayToday = workCalendar.isWorkday(now)
        todayHolidayName = workCalendar.isHoliday(now) ? holidayNames[dayKey]?.localName : nil
        monthWorkdays = workCalendar.workdaysInMonth(containing: now)
        completedWorkdays = workCalendar.completedWorkdaysThisMonth(now: now)
        monthIndex = calendar.component(.month, from: now)
        dailyPay = monthWorkdays > 0 ? config.monthlyPay / Double(monthWorkdays) : 0
        paidSecondsPerDay = config.paidSecondsPerDay
    }

    var perSecondRate: Double {
        paidSecondsPerDay > 0 ? dailyPay / paidSecondsPerDay : 0
    }

    var workdaysThisMonth: Int { monthWorkdays }

    func snapshot(at now: Date) -> Earnings {
        var result = Earnings()
        result.perSecond = perSecondRate
        result.monthTotal = config.monthlyPay
        result.yearTotal = config.annualPay

        let nowMinutes = minutesSinceMidnight(now)
        let paidElapsedMinutes = elapsedPaidMinutes(upTo: nowMinutes)
        let paidTotalMinutes = Double(config.paidMinutesPerDay)

        if isWorkdayToday {
            result.dayTotal = dailyPay
            result.dayFraction = paidTotalMinutes > 0 ? min(paidElapsedMinutes / paidTotalMinutes, 1) : 0
            result.dayEarned = dailyPay * result.dayFraction
            result.elapsedSecondsToday = paidElapsedMinutes * 60
            result.remainingSecondsToday = max(paidTotalMinutes - paidElapsedMinutes, 0) * 60
            result.status = status(at: nowMinutes)
        } else {
            result.status = .dayOff(todayHolidayName.map { .holiday(name: $0) } ?? .restDay)
        }

        result.monthEarned = Double(completedWorkdays) * dailyPay + result.dayEarned
        result.monthFraction = result.monthTotal > 0 ? min(result.monthEarned / result.monthTotal, 1) : 0

        // 前面几个月按整月工资累计，加上本月的进度，就是全年进度。
        let yearBaseEarned = Double(monthIndex - 1) * config.monthlyPay + result.monthEarned
        let yearBaseTotal = config.monthlyPay * 12
        result.yearFraction = yearBaseTotal > 0 ? min(yearBaseEarned / yearBaseTotal, 1) : 0
        result.yearEarned = result.yearFraction * result.yearTotal

        return result
    }

    // MARK: - 离开工位期间

    /// 合盖睡一个月再打开这种事真会发生，给循环设个上限。
    private static let maxAwayDays = 400

    /// 算出 [start, end) 这段时间里公司照付了多少钱。跨午休、跨下班、跨周末和节假日
    /// 都会被排除掉；跨月时两个月各按自己的工作日数折算日薪。
    func awayReport(from start: Date, to end: Date) -> AwayReport {
        let awaySeconds = max(end.timeIntervalSince(start), 0)
        var paid: Double = 0
        var amount: Double = 0

        guard awaySeconds > 0, config.paidSecondsPerDay > 0 else {
            return AwayReport(start: start, end: end, awaySeconds: awaySeconds, paidSeconds: 0, amount: 0)
        }

        var day = calendar.startOfDay(for: start)
        for _ in 0..<Self.maxAwayDays {
            if day >= end { break }
            if workCalendar.isWorkday(day) {
                let seconds = paidSeconds(on: day, between: start, and: end)
                if seconds > 0 {
                    paid += seconds
                    amount += seconds / config.paidSecondsPerDay * dailyPay(for: day)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return AwayReport(start: start, end: end, awaySeconds: awaySeconds, paidSeconds: paid, amount: amount)
    }

    /// 某一天的计薪时段和 [start, end) 相交了多少秒。
    private func paidSeconds(on day: Date, between start: Date, and end: Date) -> Double {
        config.paidIntervals.reduce(0) { total, interval in
            guard let lower = date(on: day, minutesFromMidnight: interval.lowerBound),
                let upper = date(on: day, minutesFromMidnight: interval.upperBound)
            else { return total }
            let from = max(lower, start)
            let to = min(upper, end)
            return to > from ? total + to.timeIntervalSince(from) : total
        }
    }

    /// 日薪取决于当月有几个工作日，所以不能用调用方那个月的值一路算到底。
    private func dailyPay(for day: Date) -> Double {
        let count = workCalendar.workdaysInMonth(containing: day)
        return count > 0 ? config.monthlyPay / Double(count) : 0
    }

    /// 用挂钟时间而不是给零点加秒数，这样夏令时切换那天的上下班时间仍然对得上。
    private func date(on day: Date, minutesFromMidnight minutes: Int) -> Date? {
        guard minutes < 24 * 60 else {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    // MARK: - Helpers

    private func minutesSinceMidnight(_ date: Date) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = Double(parts.hour ?? 0)
        let minute = Double(parts.minute ?? 0)
        let second = Double(parts.second ?? 0)
        let nanos = Double(parts.nanosecond ?? 0) / 1_000_000_000
        return hour * 60 + minute + (second + nanos) / 60
    }

    private func elapsedPaidMinutes(upTo nowMinutes: Double) -> Double {
        config.paidIntervals.reduce(0) { total, interval in
            let lower = Double(interval.lowerBound)
            let upper = Double(interval.upperBound)
            return total + max(0, min(nowMinutes, upper) - lower)
        }
    }

    private func status(at nowMinutes: Double) -> WorkStatus {
        guard let first = config.paidIntervals.first, let last = config.paidIntervals.last else {
            return .dayOff(.noSchedule)
        }
        if nowMinutes < Double(first.lowerBound) { return .beforeWork }
        if nowMinutes >= Double(last.upperBound) { return .finished }
        let insidePaid = config.paidIntervals.contains { interval in
            nowMinutes >= Double(interval.lowerBound) && nowMinutes < Double(interval.upperBound)
        }
        return insidePaid ? .working : .onBreak
    }
}
