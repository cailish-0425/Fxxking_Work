import Foundation

// 这几个枚举只描述"是什么"，给用户看的名字统一放在 Support/DisplayNames.swift。

enum SalaryPeriod: String, Codable, CaseIterable, Identifiable {
    case monthly
    case annual

    var id: String { rawValue }
}

enum MenuBarDisplay: String, Codable, CaseIterable, Identifiable {
    case todayAmount
    case todayPercent
    case monthAmount
    case monthPercent
    case yearPercent

    var id: String { rawValue }
}

struct Configuration: Codable, Equatable {
    var salaryAmount: Double = 20000
    var salaryPeriod: SalaryPeriod = .monthly
    /// 一年发几个月工资，用来表达 13 薪 / 14 薪这类年终奖。
    var payMonthsPerYear: Int = 12
    var currencyCode: String = "CNY"
    var countryCode: String = "CN"
    /// Calendar 的 weekday 取值：1 = 周日 … 7 = 周六。
    var workdays: Set<Int> = [2, 3, 4, 5, 6]
    var startMinutes: Int = 9 * 60
    var endMinutes: Int = 18 * 60
    var breakEnabled: Bool = true
    var breakStartMinutes: Int = 12 * 60
    var breakEndMinutes: Int = 13 * 60
    var useAutoHolidays: Bool = true
    /// 印度、马来西亚这类国家的数据源里有大量只在某个邦生效的假日，默认不算。
    /// 只有公务员放假的日子也归在这里。
    var includeRegionalHolidays: Bool = false
    /// 自动采用数据源里的调休上班日。中国、俄罗斯、越南会把周末挪成工作日，
    /// 但也有公司照放假却不补班，所以留一个单独的开关。
    var useAutoMakeupWorkdays: Bool = true
    /// 额外的休息日，"yyyy-MM-dd"，用于年假和官方数据没覆盖的假期。
    var extraHolidays: Set<String> = []
    /// 调休上班日，"yyyy-MM-dd"，优先级高于周末和节假日。
    var makeupWorkdays: Set<String> = []
    var menuBarDisplay: MenuBarDisplay = .todayAmount
    var showMenuBarIcon: Bool = true
    var snarkEnabled: Bool = true
    /// 解锁后提示这段时间公司照付了多少钱。
    var awayAlertEnabled: Bool = true
    /// 只影响界面文字，货币和日期格式仍然跟随系统地区。
    var language: AppLanguage = .system

    init() {}

    /// 宽松解码：新增字段时旧的配置文件依然可读，缺失的键回退到默认值。
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        salaryAmount = (try? c.decode(Double.self, forKey: .salaryAmount)) ?? salaryAmount
        salaryPeriod = (try? c.decode(SalaryPeriod.self, forKey: .salaryPeriod)) ?? salaryPeriod
        payMonthsPerYear = (try? c.decode(Int.self, forKey: .payMonthsPerYear)) ?? payMonthsPerYear
        currencyCode = (try? c.decode(String.self, forKey: .currencyCode)) ?? currencyCode
        countryCode = (try? c.decode(String.self, forKey: .countryCode)) ?? countryCode
        workdays = (try? c.decode(Set<Int>.self, forKey: .workdays)) ?? workdays
        startMinutes = (try? c.decode(Int.self, forKey: .startMinutes)) ?? startMinutes
        endMinutes = (try? c.decode(Int.self, forKey: .endMinutes)) ?? endMinutes
        breakEnabled = (try? c.decode(Bool.self, forKey: .breakEnabled)) ?? breakEnabled
        breakStartMinutes = (try? c.decode(Int.self, forKey: .breakStartMinutes)) ?? breakStartMinutes
        breakEndMinutes = (try? c.decode(Int.self, forKey: .breakEndMinutes)) ?? breakEndMinutes
        useAutoHolidays = (try? c.decode(Bool.self, forKey: .useAutoHolidays)) ?? useAutoHolidays
        includeRegionalHolidays = (try? c.decode(Bool.self, forKey: .includeRegionalHolidays)) ?? includeRegionalHolidays
        useAutoMakeupWorkdays = (try? c.decode(Bool.self, forKey: .useAutoMakeupWorkdays)) ?? useAutoMakeupWorkdays
        extraHolidays = (try? c.decode(Set<String>.self, forKey: .extraHolidays)) ?? extraHolidays
        makeupWorkdays = (try? c.decode(Set<String>.self, forKey: .makeupWorkdays)) ?? makeupWorkdays
        menuBarDisplay = (try? c.decode(MenuBarDisplay.self, forKey: .menuBarDisplay)) ?? menuBarDisplay
        showMenuBarIcon = (try? c.decode(Bool.self, forKey: .showMenuBarIcon)) ?? showMenuBarIcon
        snarkEnabled = (try? c.decode(Bool.self, forKey: .snarkEnabled)) ?? snarkEnabled
        awayAlertEnabled = (try? c.decode(Bool.self, forKey: .awayAlertEnabled)) ?? awayAlertEnabled
        language = (try? c.decode(AppLanguage.self, forKey: .language)) ?? language
    }

    var monthlyPay: Double {
        let months = Double(max(payMonthsPerYear, 1))
        switch salaryPeriod {
        case .monthly: return max(salaryAmount, 0)
        case .annual: return max(salaryAmount, 0) / months
        }
    }

    var annualPay: Double {
        monthlyPay * Double(max(payMonthsPerYear, 1))
    }

    /// 一天里真正计薪的时段，已经把午休挖掉。
    var paidIntervals: [ClosedRange<Int>] {
        let start = min(startMinutes, endMinutes)
        let end = max(startMinutes, endMinutes)
        guard end > start else { return [] }
        guard breakEnabled else { return [start...end] }

        let bStart = max(min(breakStartMinutes, breakEndMinutes), start)
        let bEnd = min(max(breakStartMinutes, breakEndMinutes), end)
        guard bEnd > bStart else { return [start...end] }

        var result: [ClosedRange<Int>] = []
        if bStart > start { result.append(start...bStart) }
        if end > bEnd { result.append(bEnd...end) }
        return result.isEmpty ? [start...end] : result
    }

    var paidMinutesPerDay: Int {
        paidIntervals.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    var paidSecondsPerDay: Double {
        Double(paidMinutesPerDay) * 60
    }
}
