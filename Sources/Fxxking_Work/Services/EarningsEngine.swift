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

/// 本账期汇总：下个名义发薪日/剩余天数/账期范围/真实已赚（正常/加班/合计/无偿损失）。
/// 只展示，不把发薪日当天当已到账，不发账期归属改动税/社保。
struct PayrollSummary: Equatable {
    var period: PayrollPeriod?
    var rangeDescription: String?
    var nextPayday: Date?
    var remainingDays: Int?
    var notes: [String] = []
    var regularGross: Double = 0
    var overtimePaid: Double = 0
    var totalGross: Double = 0
    var loss: Double = 0
    /// 税后口径：regularGross/overtimePaid/totalGross 已是净额；loss 仍为税前基准。
    var netMode: Bool = false
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

    /// 工资时间线：日期 → 生效月薪毛额（历史分段 + 冻结基线 + 当前工资）。
    private let schedule: SalarySchedule

    /// 税前模式的预计算总量（按逐日生效工资分段，引擎存续期内不变）。
    private var monthTotalGross: Double = 0       // 当月全部工作日的毛额合计（分段）
    private var yearRegularGross: Double = 0      // 全年 12 个月的正常毛额合计（分段）
    private var bonusExtra: Double = 0            // 13/14 薪额外部分（按年末生效月薪 × 额外月数）
    private var yearTotalGross: Double = 0        // 全年总额 = 正常毛额 + 额外薪月
    private var monthEarnedGross: Double = 0      // 当月已完整过去的工作日毛额（不含今天）
    private var yearRegularEarnedGross: Double = 0// 全年已完整过去的工作日毛额（不含今天）

    /// 税后模式的逐月净额；nil 表示税前或税后不可用（blocked）。
    /// - `netBaseMonths`：仅正常工资（不含任何加班）的逐月净额，供正常秒薪/日薪/away 使用，绝不混入加班。
    /// - `netMonths`：正常 + 已结束有偿加班的逐月净额（进行中段在 snapshot 里作临时预测重算，不冻结进缓存）。
    private var netBaseMonths: [NetPayCalculator.MonthlyNet]?
    private var netMonths: [NetPayCalculator.MonthlyNet]?
    /// 逐月正常毛额（工资历史分段后的每月值，1 月 = index 0）。
    private var regularGrossPerMonth: [Money] = []
    /// 已结束的有偿加班毛额按归属月拆（进行中段不含）。
    private var otFinalByMonth: [Double] = Array(repeating: 0, count: 12)
    /// 引擎锚定年份，用于税后逐月口径与加班归属。
    private var yearIndex: Int = 0
    /// 税后是否适用但被参数阻塞（供 UI 显示，不静默回退）。
    var netBlocked: [String] = []
    var netWarnings: [String] = []

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
        self.schedule = SalarySchedule(config: config, calendar: calendar)

        isWorkdayToday = workCalendar.isWorkday(now)
        todayHolidayName = workCalendar.isHoliday(now) ? holidayNames[dayKey]?.localName : nil
        monthWorkdays = workCalendar.workdaysInMonth(containing: now)
        completedWorkdays = workCalendar.completedWorkdaysThisMonth(now: now)
        monthIndex = calendar.component(.month, from: now)
        paidSecondsPerDay = config.paidSecondsPerDay

        // 逐日生效工资下的当日日薪。
        dailyPay = monthWorkdays > 0 ? schedule.monthlyGross(on: now) / Double(monthWorkdays) : 0

        // 全年/当月的正常毛额与已赚毛额：按逐日生效工资分段求和（中途涨薪不整月重算）。
        let today = calendar.startOfDay(for: now)
        if let monthInterval = calendar.dateInterval(of: .month, for: now) {
            monthTotalGross = grossTotal(in: monthInterval)
            monthEarnedGross = grossEarned(in: monthInterval, upTo: today)
        } else {
            monthTotalGross = 0
            monthEarnedGross = 0
        }
        if let yearInterval = calendar.dateInterval(of: .year, for: now) {
            yearRegularGross = grossTotal(in: yearInterval)
            yearRegularEarnedGross = grossEarned(in: yearInterval, upTo: today)
        } else {
            yearRegularGross = 0
            yearRegularEarnedGross = 0
        }

        // 13/14 薪：额外月数按年末生效的月薪折算一次，避免每次涨薪都重复加一份 13 薪。
        let extraMonths = max(config.payMonthsPerYear - 12, 0)
        if extraMonths > 0 {
            let year = calendar.component(.year, from: now)
            let yearEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? now
            bonusExtra = schedule.monthlyGross(on: yearEnd) * Double(extraMonths)
        } else {
            bonusExtra = 0
        }
        yearTotalGross = yearRegularGross + bonusExtra

        // 税后：只在用户显式选择 net 时才计算，gross 路径零变化。
        if config.payMode == .net {
            // 逐月正常毛额按工资历史分段后的每月值，再累计预扣，不再用今天工资重复推 12 月。
            yearIndex = calendar.component(.year, from: now)
            var grossPerMonth: [Money] = []
            for month in 1...12 {
                grossPerMonth.append(Money(yuan: monthRegularGross(month: month, year: yearIndex)))
            }
            regularGrossPerMonth = grossPerMonth

            // 额外薪基准：与税前 bonusExtra 同源，取「年末正常月薪」（工资历史/基线/当前工资统一入口），
            // 不含任何加班；税后累计预扣时传给 compute 作 bonusBaseMonthly，避免把 12 月加班毛额误当年终奖重复。
            let extraMonths = max(config.payMonthsPerYear - 12, 0)
            let bonusBaseMonthly: Money? = extraMonths > 0
                ? Money(yuan: schedule.monthlyGross(on: calendar.date(from: DateComponents(year: yearIndex, month: 12, day: 31)) ?? now))
                : nil
            // 社保 auto 基数按「各月正常工资」逐月取值（工资历史分段），不随有偿加班抬高、不随今日月薪统一。
            // grossPerMonth 本身即各月正常毛额（monthRegularGross 分段），作为 socialBasePerMonth 传入。
            let socialBasePerMonth: [Money]? = grossPerMonth

            // 已结束的有偿加班毛额按归属月拆（进行中段不含，见 snapshot 里的临时预测）。
            otFinalByMonth = finishedOTByMonth(at: now)

            // 仅正常工资的逐月净额（社保基数/扣除按各月正常工资解析，与加班基准口径分开）。
            netBaseMonths = Self.computeNet(
                grossPerMonth: grossPerMonth, otByMonth: nil,
                payMonthsPerYear: config.payMonthsPerYear, profile: config.tax,
                countryCode: config.countryCode, currencyCode: config.currencyCode,
                bonusBaseMonthly: bonusBaseMonthly, socialBasePerMonth: socialBasePerMonth)
            // 正常 + 已结束有偿加班毛额合并后重新累计预扣，得到最终月/年净额。
            netMonths = Self.computeNet(
                grossPerMonth: grossPerMonth, otByMonth: otFinalByMonth,
                payMonthsPerYear: config.payMonthsPerYear, profile: config.tax,
                countryCode: config.countryCode, currencyCode: config.currencyCode,
                bonusBaseMonthly: bonusBaseMonthly, socialBasePerMonth: socialBasePerMonth)

            // 阻塞/提示口径：与最终计算同口径（合并已结束加班毛额后 compute，socialBase 用各月正常工资），
            // 避免 netBlocked 漏掉因 OT 抬毛额才出现的参数错误（如某月缴费超毛额）。
            let final = Self.computeResult(
                grossPerMonth: Self.mergedGross(grossPerMonth, otByMonth: otFinalByMonth), otByMonth: nil,
                payMonthsPerYear: config.payMonthsPerYear, profile: config.tax,
                countryCode: config.countryCode, currencyCode: config.currencyCode,
                bonusBaseMonthly: bonusBaseMonthly, socialBasePerMonth: socialBasePerMonth)
            netBlocked = final.blocked
            netWarnings = final.warnings
        } else {
            yearIndex = calendar.component(.year, from: now)
            regularGrossPerMonth = []
            otFinalByMonth = Array(repeating: 0, count: 12)
            netMonths = nil
            netBaseMonths = nil
            netBlocked = []
            netWarnings = []
        }
    }

    /// 统一税后计算：正常逐月毛额 + 可选有偿加班逐月毛额 → 逐月净额。
    /// otByMonth 为 nil 表示「仅正常」；非 nil 表示正常+加班合并后重新累计预扣。
    /// 额外薪基准统一传「年末正常月薪」，社保 auto 基数统一传「各月正常工资月薪」，与税前口径同源。
    private static func computeNet(
        grossPerMonth: [Money],
        otByMonth: [Double]?,
        payMonthsPerYear: Int,
        profile: TaxProfile,
        countryCode: String,
        currencyCode: String,
        bonusBaseMonthly: Money? = nil,
        socialBasePerMonth: [Money]? = nil
    ) -> [NetPayCalculator.MonthlyNet]? {
        let result = computeResult(
            grossPerMonth: mergedGross(grossPerMonth, otByMonth: otByMonth), otByMonth: nil,
            payMonthsPerYear: payMonthsPerYear, profile: profile,
            countryCode: countryCode, currencyCode: currencyCode,
            bonusBaseMonthly: bonusBaseMonthly, socialBasePerMonth: socialBasePerMonth)
        return result.available ? result.months : nil
    }

    /// 把有偿加班毛额并入对应月（仅并入，不重复加）；otByMonth 为 nil 时原样返回。
    private static func mergedGross(_ grossPerMonth: [Money], otByMonth: [Double]?) -> [Money] {
        guard let otByMonth else { return grossPerMonth }
        var gross = grossPerMonth
        for month in 1...12 {
            let extra = otByMonth[month - 1]
            if extra > 0 { gross[month - 1] = gross[month - 1] + Money(yuan: extra) }
        }
        return gross
    }

    private static func computeResult(
        grossPerMonth: [Money],
        otByMonth: [Double]?,
        payMonthsPerYear: Int,
        profile: TaxProfile,
        countryCode: String,
        currencyCode: String,
        bonusBaseMonthly: Money? = nil,
        socialBasePerMonth: [Money]? = nil
    ) -> NetPayCalculator.Result {
        // grossPerMonth 已由调用方合并好加班毛额（computeNet 走 mergedGross；netBlocked 走 mergedGross(otFinalByMonth)）。
        _ = otByMonth
        return NetPayCalculator.compute(
            grossPerMonth: grossPerMonth,
            payMonthsPerYear: payMonthsPerYear,
            profile: profile,
            countryCode: countryCode,
            currencyCode: currencyCode,
            bonusBaseMonthly: bonusBaseMonthly,
            socialBasePerMonth: socialBasePerMonth)
    }

    var perSecondRate: Double {
        paidSecondsPerDay > 0 ? dailyPay / paidSecondsPerDay : 0
    }

    var workdaysThisMonth: Int { monthWorkdays }

    /// 税后是否生效（net 模式且参数完整）。
    var isNetActive: Bool { netMonths != nil }

    /// 当月净额（分），供外部读取口径；无净额时为 nil（含已结束加班，进行中段另算）。
    var monthNetCents: Int64? {
        guard let netMonths else { return nil }
        return NetPayCalculator.monthNet(netMonths, for: monthIndex)?.cents
    }

    /// 税后「仅正常工资」的当月净额（分），不含任何加班；供外部口径，不混加班。
    var monthNetBaseCents: Int64? {
        guard let netBaseMonths else { return nil }
        return NetPayCalculator.monthNet(netBaseMonths, for: monthIndex)?.cents
    }

    /// 某月税后净额（分，index 0 = 1 月）。含已结束加班，进行中段未计入缓存。
    func netCents(forMonth month: Int) -> Int64? {
        guard let netMonths else { return nil }
        return NetPayCalculator.monthNet(netMonths, for: month)?.cents
    }

    /// 某时刻含「已结束 + 进行中已发生」加班后的最终逐月净额；无活跃 paid 段时复用缓存 netMonths。
    private func finalMonths(at now: Date) -> [NetPayCalculator.MonthlyNet]? {
        guard netBaseMonths != nil else { return nil }
        let active = activeOTGrossByMonth(at: now)
        let hasActive = active.contains { $0 > 0 }
        if !hasActive { return netMonths }
        var combined = otFinalByMonth
        for m in 0..<12 { combined[m] += active[m] }
        let extraMonths = max(config.payMonthsPerYear - 12, 0)
        let bonusBaseMonthly: Money? = extraMonths > 0
            ? Money(yuan: schedule.monthlyGross(on: calendar.date(from: DateComponents(year: yearIndex, month: 12, day: 31)) ?? now))
            : nil
        return Self.computeNet(
            grossPerMonth: regularGrossPerMonth, otByMonth: combined,
            payMonthsPerYear: config.payMonthsPerYear, profile: config.tax,
            countryCode: config.countryCode, currencyCode: config.currencyCode,
            bonusBaseMonthly: bonusBaseMonthly, socialBasePerMonth: regularGrossPerMonth)
    }

    /// 某月「仅正常」净额（元），供正常秒薪/日薪/away 使用（不混加班）。
    private func baseMonthNetYuan(forMonth month: Int) -> Double {
        guard let netBaseMonths else { return 0 }
        return NetPayCalculator.monthNet(netBaseMonths, for: month)?.doubleYuan ?? 0
    }

    func snapshot(at now: Date) -> Earnings {
        var result = Earnings()
        // 税后模式：本月净额、全年 Σ 净额；税前模式走原逻辑（netBaseMonths == nil）。
        if netBaseMonths != nil {
            // 仅正常工资的逐月净额 → 正常秒薪/日薪/away，绝不把加班摊进普通日。
            let baseMonthNetYuan = baseMonthNetYuan(forMonth: monthIndex)
            // 含已结束 + 进行中已发生加班后的最终逐月净额 → 月/年总额与合计口径。
            let finalMonths = finalMonths(at: now)
            let finalNet = finalMonths.flatMap { NetPayCalculator.monthNet($0, for: monthIndex) }
            let monthNetYuan = finalNet?.doubleYuan ?? baseMonthNetYuan
            let yearNetYuan = (finalMonths ?? []).reduce(Money.zero) { $0 + $1.net }.doubleYuan

            // 正常（regular）口径：秒薪与日总额都用「仅正常」月净额，加班另按实际发生段归属。
            result.perSecond = (monthWorkdays > 0 && paidSecondsPerDay > 0)
                ? (baseMonthNetYuan / Double(monthWorkdays)) / paidSecondsPerDay : 0
            result.monthTotal = monthNetYuan
            result.yearTotal = yearNetYuan

            let nowMinutes = minutesSinceMidnight(now)
            let paidElapsedMinutes = elapsedPaidMinutes(upTo: nowMinutes)
            let paidTotalMinutes = Double(config.paidMinutesPerDay)
            let baseDayNet = monthWorkdays > 0 ? baseMonthNetYuan / Double(monthWorkdays) : 0

            if isWorkdayToday {
                result.dayTotal = baseDayNet
                result.dayFraction = paidTotalMinutes > 0 ? min(paidElapsedMinutes / paidTotalMinutes, 1) : 0
                result.dayEarned = baseDayNet * result.dayFraction
                result.elapsedSecondsToday = paidElapsedMinutes * 60
                result.remainingSecondsToday = max(paidTotalMinutes - paidElapsedMinutes, 0) * 60
                result.status = status(at: nowMinutes)
            } else {
                result.status = .dayOff(todayHolidayName.map { .holiday(name: $0) } ?? .restDay)
            }

            // 当月正常已赚 = 已过去工作日正常净额 + 今天正常进度（均按「仅正常」口径）。
            let regularMonthEarned = Double(completedWorkdays) * baseDayNet + result.dayEarned
            // 当月加班净额 = 当月最终净额 − 当月仅正常净额（已发生部分，含进行中段的逐秒增量）。
            let monthOTNet = max(monthNetYuan - baseMonthNetYuan, 0)
            result.monthEarned = regularMonthEarned + monthOTNet
            result.monthFraction = result.monthTotal > 0 ? min(result.monthEarned / result.monthTotal, 1) : 0

            // 全年 = Σ 已完成月最终净额 + 本月已赚（不做 12×某月）；进行中段逐秒并入后仍与累计预扣精确一致。
            let completedMonthsNet = (finalMonths ?? []).prefix(monthIndex - 1).reduce(Money.zero) { $0 + $1.net }.doubleYuan
            let yearEarned = completedMonthsNet + result.monthEarned
            result.yearFraction = yearNetYuan > 0 ? min(yearEarned / yearNetYuan, 1) : 0
            result.yearEarned = yearEarned
            return result
        }

        result.perSecond = perSecondRate
        result.monthTotal = monthTotalGross
        result.yearTotal = yearTotalGross

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

        // 当月 = 已过去工作日毛额之和 + 今天的进度；中途涨薪按各日生效工资分段，不整月重算。
        result.monthEarned = monthEarnedGross + result.dayEarned
        result.monthFraction = result.monthTotal > 0 ? min(result.monthEarned / result.monthTotal, 1) : 0

        // 全年进度按正常 12 个月毛额口径（13/14 薪不进时间进度）：
        // 已过去工作日的实际毛额（分段，含今天进度）/ 全年正常毛额。
        // 工资整年均匀时等价于旧的时间占比口径；有历史涨薪时按各日生效工资累进，不把未来涨薪提前计进今天。
        result.yearFraction = yearRegularGross > 0
            ? min((yearRegularEarnedGross + result.dayEarned) / yearRegularGross, 1) : 0
        result.yearEarned = result.yearFraction * result.yearTotal

        return result
    }

    // MARK: - 逐日生效工资分段

    /// 某日生效的月薪毛额（工资历史 / 冻结基线 / 当前工资）。
    func monthlyGross(on date: Date) -> Double {
        schedule.monthlyGross(on: date)
    }

    /// 某日生效的正常税前时薪（元/小时）。加班开始时锁这个值作基准，后改工资/历史不重价。
    func hourlyGrossRate(on date: Date) -> Double {
        let count = workCalendar.workdaysInMonth(containing: date)
        guard count > 0, paidSecondsPerDay > 0 else { return 0 }
        let dailyPay = schedule.monthlyGross(on: date) / Double(count)
        return dailyPay / paidSecondsPerDay * 3600
    }

    /// 加班汇总（有偿/无偿拆到日/月/年，进行中段实时逐秒）。UI 与账期汇总共用这一口径。
    func overtimeSummary(at now: Date) -> OvertimeSummary {
        OvertimeLedger(sessions: config.overtimeSessions).summary(
            at: now, config: config, workCalendar: workCalendar, calendar: calendar)
    }

    /// 是否有进行中的加班段。
    func activeOvertime(at now: Date) -> OvertimeSession? {
        OvertimeLedger(sessions: config.overtimeSessions).active
    }

    /// 当月已赚正常毛额（含今天进度，税前），供加班卡拆分「正常/加班/合计」。
    func monthEarnedGross(at now: Date) -> Double {
        let nowMinutes = minutesSinceMidnight(now)
        let paidElapsedMinutes = elapsedPaidMinutes(upTo: nowMinutes)
        let paidTotalMinutes = Double(config.paidMinutesPerDay)
        let todayEarned: Double
        if isWorkdayToday, paidTotalMinutes > 0 {
            todayEarned = dailyPay * min(paidElapsedMinutes / paidTotalMinutes, 1)
        } else {
            todayEarned = 0
        }
        return monthEarnedGross + todayEarned
    }

    /// 当月已赚「仅正常」净额（含今天进度，税后，不混加班），供 net 模式加班卡拆正常列。
    func monthEarnedNetRegular(at now: Date) -> Double {
        guard netBaseMonths != nil else { return monthEarnedGross(at: now) }
        let baseMonthNetYuan = baseMonthNetYuan(forMonth: monthIndex)
        let baseDayNet = monthWorkdays > 0 ? baseMonthNetYuan / Double(monthWorkdays) : 0
        let nowMinutes = minutesSinceMidnight(now)
        let paidElapsedMinutes = elapsedPaidMinutes(upTo: nowMinutes)
        let paidTotalMinutes = Double(config.paidMinutesPerDay)
        let todayEarned: Double
        if isWorkdayToday, paidTotalMinutes > 0 {
            todayEarned = baseDayNet * min(paidElapsedMinutes / paidTotalMinutes, 1)
        } else {
            todayEarned = 0
        }
        return Double(completedWorkdays) * baseDayNet + todayEarned
    }

    /// 当月有偿加班净额（税后口径：当月最终净额 − 仅正常净额，含进行中段逐秒；gross 模式回退税前加班毛额）。
    func monthOvertimeNet(at now: Date) -> Double {
        guard netBaseMonths != nil else {
            return overtimeSummary(at: now).monthPaid
        }
        let finalMonths = finalMonths(at: now)
        let finalNet = finalMonths.flatMap { NetPayCalculator.monthNet($0, for: monthIndex) }
        let finalMonthNetYuan = finalNet?.doubleYuan ?? baseMonthNetYuan(forMonth: monthIndex)
        return max(finalMonthNetYuan - baseMonthNetYuan(forMonth: monthIndex), 0)
    }

    /// 本账期汇总：发薪日/剩余天数/账期范围 + 真实已赚（正常/加班/合计/损失）。
    /// 复用工资历史 + 排班 + 加班 ledger 的同一分配规则；账期只作展示范围，发薪日只作名义日历提示。
    func payrollSummary(at now: Date) -> PayrollSummary {
        var result = PayrollSummary()
        guard config.payroll.enabled else { return result }
        // 用引擎自己的日历构造账期（与 WorkCalendar 的 dayKey 同一时区），
        // 跨时区/测试下账期边界才与「今天」一致；不依赖 PayrollSettings.calendar 的 .current 默认。
        guard let payroll = try? PayrollCalendar(
            calendar: calendar,
            cutoffDay: config.payroll.cutoffDay,
            paydayDay: config.payroll.paydayDay,
            offset: config.payroll.offset
        ) else { return result }

        let period = payroll.period(containing: now)
        result.period = period
        result.rangeDescription = payroll.rangeDescription(for: period)
        result.nextPayday = period.nextPayday
        result.remainingDays = period.remainingDays
        result.notes = period.notes

        // 真实已赚 = period.start ..< min(now, end) 的正常毛额（跨月不能只用今日时薪乘天数）。
        let earnEnd = min(now, period.endExclusive)

        // 税后：按统一 NetPayCalculator 净额分配求跨月各段净额，正常与有偿拆分，无偿不扣合计。
        // 不写第二套税表：正常净额按计薪秒交集逐秒累进，有偿净额 = 当月最终净额 − 仅正常净额的增量。
        if netMonths != nil, netBaseMonths != nil {
            result.regularGross = netRegularEarned(in: DateInterval(start: period.start, end: earnEnd), upTo: earnEnd)
            let otIncrement = netOvertimeIncrementByMonth(at: now)
            result.overtimePaid = netOvertimeEarned(
                in: DateInterval(start: period.start, end: earnEnd), upTo: now, incrementByMonth: otIncrement)
            result.totalGross = result.regularGross + result.overtimePaid
            // 无偿损失仍按税前基准计（不进 net），单独展示。
            result.loss = grossOvertimeLoss(in: DateInterval(start: period.start, end: earnEnd), upTo: now)
            result.netMode = true
            return result
        }

        result.regularGross = grossEarned(in: DateInterval(start: period.start, end: earnEnd), upTo: earnEnd)

        // 有偿加班/无偿损失：落在账期范围内的部分（按发生日拆），复用加班 ledger 同一分配规则。
        let ledger = OvertimeLedger(sessions: config.overtimeSessions)
        let segs = ledger.segments(at: now, config: config, workCalendar: workCalendar, calendar: calendar)
        for seg in segs {
            guard seg.day >= period.start, seg.day < period.endExclusive else { continue }
            let hours = seg.seconds / 3600
            if seg.kind == .paid {
                result.overtimePaid += hours * seg.baseHourlyGross * Double(seg.multiplier)
            } else {
                result.loss += hours * seg.baseHourlyGross
            }
        }
        result.totalGross = result.regularGross + result.overtimePaid
        return result
    }

    /// 已结束的有偿加班毛额，按归属月拆成 12 个月（进行中的段排除在外，保证缓存只在无活跃 paid 段时有效）。
    private func finishedOTByMonth(at now: Date) -> [Double] {
        var result = [Double](repeating: 0, count: 12)
        for session in config.overtimeSessions where !session.isActive && session.kind == .paid {
            let end = session.end ?? now
            guard end > session.start else { continue }
            var day = calendar.startOfDay(for: session.start)
            while day < end {
                if workCalendar.isWorkday(day) {
                    let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? end
                    let from = max(session.start, day)
                    let to = min(end, dayEnd)
                    let seconds = OvertimeLedger.overtimeSeconds(
                        on: day, between: from, and: to, config: config, calendar: calendar)
                    if seconds > 0 {
                        let month = calendar.component(.month, from: day)
                        let year = calendar.component(.year, from: day)
                        if year == yearIndex {
                            result[month - 1] += seconds / 3600 * session.baseHourlyGross * Double(session.multiplier)
                        }
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return result
    }

    /// 税后：账期区间内正常工资的净额。完整过去工作日全计，今天只计已过去付薪秒，
    /// 午休/下班不多计，未来日/休息日 0；区间起点/终点中途同样按计薪时段交集截取；跨月各取相应月净额口径。
    private func netRegularEarned(in interval: DateInterval, upTo end: Date) -> Double {
        var total = 0.0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < end {
            if workCalendar.isWorkday(cursor) {
                total += netPaidAmount(on: cursor, between: interval.start, and: end)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return total
    }

    /// 某一天在 [between, and] 范围内、且落在正常计薪时段里的净额（按计薪秒逐秒累进）。
    /// 完整过去工作日：计薪秒满额 → 该月净日薪；今天：只计已过去付薪秒 → perSecond × 秒。
    private func netPaidAmount(on day: Date, between from: Date, and to: Date) -> Double {
        guard let netBaseMonths else { return 0 }
        let m = calendar.component(.month, from: day)
        guard let net = NetPayCalculator.monthNet(netBaseMonths, for: m) else { return 0 }
        let count = workCalendar.workdaysInMonth(containing: day)
        guard count > 0, config.paidSecondsPerDay > 0 else { return 0 }
        let netDaily = net.doubleYuan / Double(count)

        // 与正常计薪时段的交集秒数。
        let seconds = paidSeconds(on: day, between: from, and: to)
        guard seconds > 0 else { return 0 }
        return netDaily / config.paidSecondsPerDay * seconds
    }

    /// 税后：账期区间内有偿加班的净额（= 当月最终净额 − 当月仅正常净额的增量，按加班段税前毛额占比摊分）。
    /// 不把税前加班直接加 net；增量由统一累计预扣的月净额差值得出，天然含税。
    private func netOvertimeIncrementByMonth(at now: Date) -> [Int: Double] {
        guard let netBaseMonths else { return [:] }
        // 用 finalMonths(at:) 取「含进行中段临时预测」的最终净额，而非仅已结束段的 netMonths 缓存；
        // 无活跃段时 finalMonths 回退 netMonths，天然连续不重复（D3 修复）。
        guard let finalMonths = finalMonths(at: now) else { return [:] }
        var increments: [Int: Double] = [:]
        for month in 1...12 {
            guard let withOT = NetPayCalculator.monthNet(finalMonths, for: month)?.doubleYuan,
                let base = NetPayCalculator.monthNet(netBaseMonths, for: month)?.doubleYuan
            else { continue }
            let delta = withOT - base
            if delta > 0 { increments[month] = delta }
        }
        return increments
    }

    private func netOvertimeEarned(
        in interval: DateInterval, upTo now: Date, incrementByMonth: [Int: Double]
    ) -> Double {
        guard !incrementByMonth.isEmpty else { return 0 }
        let ledger = OvertimeLedger(sessions: config.overtimeSessions)
        let segs = ledger.segments(at: now, config: config, workCalendar: workCalendar, calendar: calendar)
        var total = 0.0
        for seg in segs where seg.kind == .paid {
            guard seg.day >= interval.start, seg.day < interval.end else { continue }
            guard let monthDelta = incrementByMonth[seg.month] else { continue }
            // 该月有偿加班毛额，用于按比例摊分月净额增量到本段。
            let monthOTGross = ledger.paidOvertimeGross(
                byMonth: seg.year, at: now, config: config, workCalendar: workCalendar, calendar: calendar)[seg.month - 1]
            guard monthOTGross > 0 else { continue }
            let segGross = seg.seconds / 3600 * seg.baseHourlyGross * Double(seg.multiplier)
            total += monthDelta * (segGross / monthOTGross)
        }
        return total
    }

    // MARK: - 进行中加班段的逐秒税后预测

    /// 是否有进行中的「有偿」加班段（这类段尚未计入 `netMonths` 缓存，需在 snapshot 里逐秒重算）。
    func hasActivePaidOvertime(at now: Date) -> Bool {
        config.overtimeSessions.contains { $0.isActive && $0.kind == .paid }
    }

    /// 进行中有偿加班段截至 now 的税前毛额，按归属月拆成 12 个月（index 0 = 1 月）。
    private func activeOTGrossByMonth(at now: Date) -> [Double] {
        var result = [Double](repeating: 0, count: 12)
        for session in config.overtimeSessions where session.isActive && session.kind == .paid {
            let ledger = OvertimeLedger(sessions: [session])
            for seg in ledger.segments(at: now, config: config, workCalendar: workCalendar, calendar: calendar)
            where seg.kind == .paid && seg.year == yearIndex {
                result[seg.month - 1] += seg.seconds / 3600 * seg.baseHourlyGross * Double(seg.multiplier)
            }
        }
        return result
    }

    /// 某月（1…12）在给定加班毛额下的最终净额（分），供逐秒预测取当月值；不可算时 nil。
    private func monthNetCents(forMonth month: Int, otByMonth: [Double]) -> Int64? {
        var gross = regularGrossPerMonth
        guard !gross.isEmpty else { return nil }
        for m in 1...12 {
            let extra = otByMonth[m - 1]
            if extra > 0 { gross[m - 1] = gross[m - 1] + Money(yuan: extra) }
        }
        guard let months = Self.computeNet(
            grossPerMonth: gross, otByMonth: otByMonth,
            payMonthsPerYear: config.payMonthsPerYear, profile: config.tax,
            countryCode: config.countryCode, currencyCode: config.currencyCode) else { return nil }
        return NetPayCalculator.monthNet(months, for: month)?.cents
    }

    /// 税后模式下无偿损失仍按税前基准计（不进税），落在账期区间的部分。
    private func grossOvertimeLoss(in interval: DateInterval, upTo now: Date) -> Double {
        let ledger = OvertimeLedger(sessions: config.overtimeSessions)
        let segs = ledger.segments(at: now, config: config, workCalendar: workCalendar, calendar: calendar)
        var total = 0.0
        for seg in segs {
            guard seg.kind == .unpaid, seg.day >= interval.start, seg.day < interval.end else { continue }
            total += seg.seconds / 3600 * seg.baseHourlyGross
        }
        return total
    }

    /// 某月（1…12）的正常毛额：按月内各工作日的生效月薪分段求和后折算。
    /// 整月同薪时退化为该月月薪；月中涨薪则按「前旧后新」加权。
    private func monthRegularGross(month: Int, year: Int) -> Double {
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
            let interval = calendar.dateInterval(of: .month, for: monthStart)
        else { return 0 }
        let count = workCalendar.workdayCount(in: interval)
        guard count > 0 else { return 0 }
        var sum = 0.0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            if workCalendar.isWorkday(cursor) {
                sum += schedule.monthlyGross(on: cursor)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return sum / Double(count)
    }

    /// 区间内全部工作日的日薪之和（日薪按各自日期的生效月薪 / 该月工作日数）。
    private func grossTotal(in interval: DateInterval) -> Double {
        var total = 0.0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            if workCalendar.isWorkday(cursor) { total += dailyPay(for: cursor) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return total
    }

    /// 区间内 `[start, today)` 已完整过去工作日的日薪之和（不含 today）。
    private func grossEarned(in interval: DateInterval, upTo today: Date) -> Double {
        var total = 0.0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < today {
            if workCalendar.isWorkday(cursor) { total += dailyPay(for: cursor) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return total
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

        // 税后模式：战报金额按「仅正常」净日薪重算，加班不摊进正常计薪时段（D1 修复）。
        if netBaseMonths != nil {
            var netAmount: Double = 0
            var cursor = calendar.startOfDay(for: start)
            for _ in 0..<Self.maxAwayDays {
                if cursor >= end { break }
                if workCalendar.isWorkday(cursor) {
                    let seconds = paidSeconds(on: cursor, between: start, and: end)
                    if seconds > 0 {
                        netAmount += seconds / config.paidSecondsPerDay * dailyNet(for: cursor)
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return AwayReport(start: start, end: end, awaySeconds: awaySeconds, paidSeconds: paid, amount: netAmount)
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

    /// 日薪取决于当月有几个工作日，以及那一天生效的月薪，所以不能用调用方那个月的值一路算到底。
    private func dailyPay(for day: Date) -> Double {
        let count = workCalendar.workdaysInMonth(containing: day)
        return count > 0 ? schedule.monthlyGross(on: day) / Double(count) : 0
    }

    /// 税后模式的某日净日薪：按那一天所在月的「仅正常」净额折算，跨月各按当月净额；加班不摊进正常计薪。
    private func dailyNet(for day: Date) -> Double {
        guard let netBaseMonths else { return dailyPay(for: day) }
        let m = calendar.component(.month, from: day)
        guard let net = NetPayCalculator.monthNet(netBaseMonths, for: m) else { return 0 }
        let count = workCalendar.workdaysInMonth(containing: day)
        return count > 0 ? net.doubleYuan / Double(count) : 0
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
