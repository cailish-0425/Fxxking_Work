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

/// 界面外观：跟随系统 / 浅色 / 深色。纯 Foundation 类型，模型层不依赖 SwiftUI。
enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

/// 税前 / 税后。税前是默认，税后仅中国大陆单位职工（CN + CNY）。
enum PayMode: String, Codable, CaseIterable, Identifiable {
    case gross
    case net

    var id: String { rawValue }
}

/// 单项社保/公积金缴费基数的三种状态，把「未填」「显式不缴」「手填值」分开。
/// - `.auto`：未填，随月薪自动在参考上下限内取值（随工资更新）。
/// - `.disabled`：用户显式不参与该项缴费。
/// - `.manual(Money)`：手填值，持久化优先，不被地区切换或自动推导覆盖。
enum SocialBase: Equatable, Hashable {
    case auto
    case disabled
    case manual(Money)

    var isManual: Bool { if case .manual = self { return true }; return false }
}

extension SocialBase: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // 宽松：旧配置可能是裸数字（视为手填基数）。
        if let cents = try? c.decode(Int64.self) {
            self = .manual(Money(cents: cents))
            return
        }
        if let s = try? c.decode(String.self) {
            switch s {
            case "disabled": self = .disabled
            default: self = .auto
            }
            return
        }
        self = .auto
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .disabled: try c.encode("disabled")
        case .manual(let m): try c.encode(m.cents)
        }
    }
}

/// 社保个人缴费参数。养老/医疗/失业/公积金各自独立基数与比例；
/// 医保可带固定额（如北京大额医疗互助 3 元/月）。
/// 基数为 `.auto` 时按参考上下限从月薪自动取值；`.disabled` 不参与；`.manual` 手填覆盖。
struct SocialInsurance: Codable, Equatable {
    var pension: SocialBase = .auto
    var pensionRateBp: Int = 800          // 个人养老 8%
    var medical: SocialBase = .auto
    var medicalRateBp: Int = 200          // 个人医保 2%
    /// 医保固定额：`.auto` 取地区参考（北京 3 / 上海 0），`.manual` 手填覆盖，`.disabled` 为 0。
    var medicalFixed: SocialBase = .auto
    var unemployment: SocialBase = .auto
    var unemploymentRateBp: Int = 50      // 个人失业 0.5%
    var housingFund: SocialBase = .auto
    var housingFundRateBp: Int = 500      // 公积金个人比例，参考默认 5%，用户可改
}

/// 税后预测参数。地区 preset 仅作参考，选择地区不覆盖手填值，点「应用参考」才替换；
/// 恢复默认才清手填值。
struct TaxProfile: Codable, Equatable {
    /// 参考地区标识：beijing / shanghai / custom（其他城市手填城市名）。初始参考北京。
    var region: String = "beijing"
    var cityName: String = ""
    /// 任职起月 1…12，默认 1；之前的月份无收入。
    var employmentStartMonth: Int = 1
    /// 专项附加扣除（每月，分）。
    var monthlySpecialDeduction: Money = .zero
    /// 其他依法扣除（每月，分）。
    var monthlyOtherDeduction: Money = .zero
    /// 13/14 薪额外工资发放月份（1…12），默认 12；发放月份并入当月工资薪金计税。
    var bonusMonth: Int = 12
    var social: SocialInsurance = .init()
}

extension Money {
    static let zero = Money(cents: 0)
}

/// 发薪日与账期设置。`enabled == false` 或字段缺省时保持自然月口径。
struct PayrollSettings: Codable, Equatable {
    /// 是否启用自定义账期/发薪日（关闭 = 自然月，不显示账期汇总）。
    var enabled: Bool = false
    /// 账期截止日 1…31。
    var cutoffDay: Int = 25
    /// 名义发薪日 1…31。
    var paydayDay: Int = 10
    /// 发薪在结算月当月还是次月。
    var offset: PaydayOffset = .nextMonth

    /// 由当前设置构造 PayrollCalendar；disabled 时返回 nil（调用方回退自然月口径）。
    var calendar: PayrollCalendar? {
        guard enabled else { return nil }
        return try? PayrollCalendar(cutoffDay: cutoffDay, paydayDay: paydayDay, offset: offset)
    }
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
    /// 界面外观，旧配置缺字段时宽松回退到跟随系统。
    var appearance: AppAppearance = .system
    /// 只影响界面文字，货币和日期格式仍然跟随系统地区。
    var language: AppLanguage = .system
    /// 税前 / 税后。缺字段回退税前，旧配置零行为变化。
    var payMode: PayMode = .gross
    /// 税后预测参数，仅 net 模式生效。
    var tax: TaxProfile = .init()
    /// 隐私模式：开启时所有金额默认掩码，点击眼睛临时查看。默认关以兼容旧配置。
    var privacyModeEnabled: Bool = false
    /// 账期与发薪日设置。旧配置缺字段 → 保持自然月口径（账期 = 自然月，无自定义发薪日）。
    var payroll: PayrollSettings = .init()
    /// 工资变更历史。空数组 = 全程用当前 salaryAmount（旧配置兼容，无日期基线）。
    var salaryHistory: [SalaryVersion] = []
    /// 首次新增工资变更时冻结的旧工资基线；nil 表示尚未冻结（无历史）。
    var salaryBaseline: SalaryBaseline? = nil
    /// 加班设置：默认有偿/无偿、默认倍率（有偿 1/2/3）。旧配置缺字段回退默认。
    var overtimePayDefault: OvertimePayKind = .paid
    var overtimeMultiplier: Int = 1
    /// 加班台账（持久化，重启恢复；进行中的段一并保留）。
    var overtimeSessions: [OvertimeSession] = []

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
        appearance = (try? c.decode(AppAppearance.self, forKey: .appearance)) ?? appearance
        language = (try? c.decode(AppLanguage.self, forKey: .language)) ?? language
        payMode = (try? c.decode(PayMode.self, forKey: .payMode)) ?? payMode
        privacyModeEnabled = (try? c.decode(Bool.self, forKey: .privacyModeEnabled)) ?? privacyModeEnabled
        payroll = (try? c.decode(PayrollSettings.self, forKey: .payroll)) ?? payroll
        salaryHistory = (try? c.decode([SalaryVersion].self, forKey: .salaryHistory)) ?? salaryHistory
        salaryBaseline = (try? c.decode(SalaryBaseline.self, forKey: .salaryBaseline)) ?? salaryBaseline
        overtimePayDefault = (try? c.decode(OvertimePayKind.self, forKey: .overtimePayDefault)) ?? overtimePayDefault
        overtimeMultiplier = (try? c.decode(Int.self, forKey: .overtimeMultiplier)) ?? overtimeMultiplier
        overtimeSessions = (try? c.decode([OvertimeSession].self, forKey: .overtimeSessions)) ?? overtimeSessions
        tax = (try? c.decode(TaxProfile.self, forKey: .tax)) ?? tax
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
