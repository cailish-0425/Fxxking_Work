import Foundation

/// 发薪日相对账期结算月的位置。
enum PaydayOffset: String, Codable, Sendable {
    /// 发薪在结算月当月。
    case sameMonth
    /// 发薪在结算月次月（常见「次月发上月工资」）。
    case nextMonth
}

/// 一个账期（半开区间 `[start, endExclusive)`）。
struct PayrollPeriod: Equatable, Sendable {
    /// 账期首日 00:00（含）。
    var start: Date
    /// 账期次日 00:00（不含；即下一账期的 start）。
    var endExclusive: Date
    /// 账期结算日 = 账期最后一日（截止日）。
    var settlementDate: Date
    /// 该账期按 offset 的名义发薪日（供汇总/展示：本账期工资哪一天发）。
    var nominalPayday: Date
    /// 不早于 now 的下一个名义发薪日（倒计时目标；today == 0 天）。倒计时 == 0 仅表示「今天是名义发薪日」，不代表已到账。
    var nextPayday: Date
    /// now → nextPayday 的自然天数（按 Calendar 日期计算，非秒数/86400）。
    var remainingDays: Int
    /// 规则提示（如「同月发薪早于结算」）。空表示无提示。
    var notes: [String]
}

enum PayrollRuleError: Error, Equatable {
    case invalidCutoffDay(Int)
    case invalidPaydayDay(Int)
}

/// 发薪日与账期计算模块（纯 Foundation、无 UI、不算钱、不读配置、不推导用户实际发薪日）。
///
/// 账期以「截止日 cutoffDay」锚定：结算月 M 的账期 = `[boundary(M-1), boundary(M))`，
/// 其中 `boundary(M)` = M 月截止日（无该日按月末夹取）的次日 00:00。相邻账期首尾相接、不漏天不重叠。
/// 日期运算全部走 `Calendar`，DST/闰年/跨月跨年安全，不用秒数除以 86400。
struct PayrollCalendar {
    let calendar: Calendar
    /// 账期截止日 1…31（无该日的月份按当月最后一日夹取）。
    let cutoffDay: Int
    /// 名义发薪日 1…31（无该日的月份按当月最后一日夹取）。
    let paydayDay: Int
    let offset: PaydayOffset

    init(calendar: Calendar = .current, cutoffDay: Int, paydayDay: Int, offset: PaydayOffset) throws {
        guard (1...31).contains(cutoffDay) else { throw PayrollRuleError.invalidCutoffDay(cutoffDay) }
        guard (1...31).contains(paydayDay) else { throw PayrollRuleError.invalidPaydayDay(paydayDay) }
        self.calendar = calendar
        self.cutoffDay = cutoffDay
        self.paydayDay = paydayDay
        self.offset = offset
    }

    // MARK: - 基础日期

    private func daysInMonth(containing date: Date) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    private func date(year: Int, month: Int, day: Int) -> Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return calendar.date(from: c)
    }

    /// 账期截止日（含），即结算日。
    private func cutoffDate(inMonthContaining date: Date) -> Date? {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let day = min(cutoffDay, daysInMonth(containing: date))
        return self.date(year: comps.year ?? 0, month: comps.month ?? 0, day: day)
    }

    /// 截止日次日 00:00（下一账期 start / 本账期 endExclusive）。
    private func boundary(inMonthContaining date: Date) -> Date? {
        guard let cut = cutoffDate(inMonthContaining: date) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: cut)
    }

    // MARK: - 发薪日

    /// 结算日之后（含）的「本账期」名义发薪日（按 offset）。
    private func nominalPayday(after settlement: Date) -> Date {
        var anchor = settlement
        if case .nextMonth = offset {
            anchor = calendar.date(byAdding: .month, value: 1, to: settlement) ?? settlement
        }
        let day = min(paydayDay, daysInMonth(containing: anchor))
        let comps = calendar.dateComponents([.year, .month], from: anchor)
        return date(year: comps.year ?? 0, month: comps.month ?? 0, day: day) ?? settlement
    }

    /// 不早于 now 的下一个名义发薪日（倒计时目标；按月推进，最多看两个月）。
    func nextPayday(onOrAfter now: Date) -> Date {
        let sod = calendar.startOfDay(for: now)
        var month = now
        for _ in 0..<2 {
            let comps = calendar.dateComponents([.year, .month], from: month)
            let day = min(paydayDay, daysInMonth(containing: month))
            if let candidate = date(year: comps.year ?? 0, month: comps.month ?? 0, day: day),
                calendar.startOfDay(for: candidate) >= sod
            {
                return candidate
            }
            month = calendar.date(byAdding: .month, value: 1, to: month) ?? month
        }
        return now
    }

    // MARK: - 账期

    /// 包含 now 的账期。
    func period(containing now: Date) -> PayrollPeriod {
        var anchor = now
        if let b = boundary(inMonthContaining: now), now >= b {
            anchor = calendar.date(byAdding: .month, value: 1, to: now) ?? now
        }
        let prevAnchor = calendar.date(byAdding: .month, value: -1, to: anchor) ?? anchor

        guard let end = boundary(inMonthContaining: anchor),
            let start = boundary(inMonthContaining: prevAnchor),
            let settlement = calendar.date(byAdding: .day, value: -1, to: end)
        else {
            return PayrollPeriod(
                start: now, endExclusive: now, settlementDate: now,
                nominalPayday: now, nextPayday: now, remainingDays: 0,
                notes: ["无法计算账期"])
        }

        let payday = nominalPayday(after: settlement)
        var notes: [String] = []
        if case .sameMonth = offset, payday < settlement {
            notes.append("同月发薪早于结算日，请确认雇主规则")
        }

        let next = nextPayday(onOrAfter: now)
        let remaining = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: next)
        ).day ?? 0

        return PayrollPeriod(
            start: start, endExclusive: end, settlementDate: settlement,
            nominalPayday: payday, nextPayday: next,
            remainingDays: max(remaining, 0), notes: notes)
    }

    /// 枚举与 `[from, to)` 有交集的所有账期（连续、不重叠、不漏天）。
    func periods(from: Date, to: Date) -> [PayrollPeriod] {
        guard from < to else { return [] }
        var result: [PayrollPeriod] = []
        var current = period(containing: from)
        while current.start < to {
            result.append(current)
            current = period(containing: current.endExclusive)
        }
        return result
    }

    /// 可理解日期范围（半开区间前闭后开；显示为 start ~ 结算日）。
    func rangeDescription(for period: PayrollPeriod) -> String {
        "\(iso(period.start)) ~ \(iso(period.settlementDate))"
    }

    private func iso(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
