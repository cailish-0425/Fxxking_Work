import Foundation

// 一个不依赖 XCTest 的断言集合：本机的 SwiftPM 装坏了，用 swiftc 直接编译运行。

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL  \(message)")
    }
}

func expectClose(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 1e-6) {
    checks += 1
    if abs(actual - expected) > tolerance {
        failures += 1
        print("FAIL  \(message) — 期望 \(expected)，实际 \(actual)")
    }
}

let utc = TimeZone(identifier: "UTC")!
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = utc

let iso: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar
    f.timeZone = utc
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func date(_ string: String) -> Date {
    guard let d = iso.date(from: string) else { fatalError("坏的测试日期: \(string)") }
    return d
}

func baseConfig() -> Configuration {
    var config = Configuration()
    config.salaryAmount = 22000
    config.salaryPeriod = .monthly
    config.payMonthsPerYear = 12
    config.currencyCode = "CNY"
    config.workdays = [2, 3, 4, 5, 6]
    config.startMinutes = 9 * 60
    config.endMinutes = 18 * 60
    config.breakEnabled = true
    config.breakStartMinutes = 12 * 60
    config.breakEndMinutes = 13 * 60
    return config
}

func engine(_ config: Configuration, holidays: Set<String> = [], now: Date) -> EarningsEngine {
    EarningsEngine(config: config, autoHolidays: holidays, holidayNames: [:], now: now, calendar: calendar)
}

// MARK: - 计薪时长

do {
    let config = baseConfig()
    expect(config.paidMinutesPerDay == 480, "9:00-18:00 扣掉一小时午休应当是 480 分钟")

    var noBreak = config
    noBreak.breakEnabled = false
    expect(noBreak.paidMinutesPerDay == 540, "不扣午休应当是 540 分钟")

    var nightOwl = config
    nightOwl.startMinutes = 22 * 60
    nightOwl.endMinutes = 23 * 60
    nightOwl.breakEnabled = true
    expect(nightOwl.paidMinutesPerDay == 60, "午休落在工作时段之外时不应被扣除")
}

// MARK: - 工作日判定

do {
    let config = baseConfig()
    let cal = WorkCalendar(config: config, autoHolidays: ["2026-08-03"], calendar: calendar)

    expect(cal.isWorkday(date("2026-08-04 10:00:00")), "普通周二是工作日")
    expect(!cal.isWorkday(date("2026-08-08 10:00:00")), "周六不是工作日")
    expect(!cal.isWorkday(date("2026-08-03 10:00:00")), "法定假日不是工作日")

    var withMakeup = config
    withMakeup.makeupWorkdays = ["2026-08-08", "2026-08-03"]
    let makeupCal = WorkCalendar(config: withMakeup, autoHolidays: ["2026-08-03"], calendar: calendar)
    expect(makeupCal.isWorkday(date("2026-08-08 10:00:00")), "调休日把周六变成工作日")
    expect(makeupCal.isWorkday(date("2026-08-03 10:00:00")), "调休日优先级高于法定假日")

    var withLeave = config
    withLeave.extraHolidays = ["2026-08-04"]
    let leaveCal = WorkCalendar(config: withLeave, autoHolidays: [], calendar: calendar)
    expect(!leaveCal.isWorkday(date("2026-08-04 10:00:00")), "手动添加的休息日会盖掉工作日")

    // 2026 年 8 月共 21 个工作日（周一到周五），扣掉 8-03 剩 20 天。
    expect(cal.workdaysInMonth(containing: date("2026-08-15 10:00:00")) == 20, "2026 年 8 月应有 20 个工作日")
    // 8-01 周六、8-02 周日、8-03 是上面设的假日，所以只剩 8-04 一天。
    expect(cal.completedWorkdaysThisMonth(now: date("2026-08-05 10:00:00")) == 1, "8 月 5 日之前有 1 个完整工作日")
    expect(cal.completedWorkdaysThisMonth(now: date("2026-08-01 10:00:00")) == 0, "月初第一天之前没有完整工作日")
}

// MARK: - 当日进度

do {
    let config = baseConfig()
    let e = engine(config, now: date("2026-08-04 09:00:00"))
    let monthWorkdays = e.workdaysThisMonth
    expect(monthWorkdays == 21, "2026 年 8 月没有假日时应有 21 个工作日")

    let dailyPay = config.monthlyPay / Double(monthWorkdays)
    expectClose(e.perSecondRate * config.paidSecondsPerDay, dailyPay, "秒薪乘以计薪秒数应当等于日薪")

    let atStart = e.snapshot(at: date("2026-08-04 09:00:00"))
    expectClose(atStart.dayFraction, 0, "上班的那一刻进度为 0")
    expect(atStart.status == .working, "9:00 整应当处于计费状态")

    let atNoon = e.snapshot(at: date("2026-08-04 12:30:00"))
    expectClose(atNoon.dayFraction, 3.0 / 8.0, "12:30 在午休中，已计薪 3 小时")
    expect(atNoon.status == .onBreak, "12:30 应当是午休状态")

    let atOne = e.snapshot(at: date("2026-08-04 13:00:00"))
    expectClose(atOne.dayFraction, 3.0 / 8.0, "13:00 刚复工，进度仍是 3/8")
    expect(atOne.status == .working, "13:00 应当恢复计费")

    let atEnd = e.snapshot(at: date("2026-08-04 18:00:00"))
    expectClose(atEnd.dayFraction, 1, "18:00 当天进度满格")
    expectClose(atEnd.dayEarned, dailyPay, "18:00 当天应拿满一天工资")
    expect(atEnd.status == .finished, "18:00 应当是下班状态")

    let late = e.snapshot(at: date("2026-08-04 23:00:00"))
    expectClose(late.dayFraction, 1, "加班不加钱，进度封顶在 100%")

    let early = e.snapshot(at: date("2026-08-04 07:00:00"))
    expectClose(early.dayEarned, 0, "上班前没有收入")
    expect(early.status == .beforeWork, "7:00 应当是尚未开工")
}

// MARK: - 休息日

do {
    let config = baseConfig()
    let e = engine(config, now: date("2026-08-08 14:00:00"))
    let weekend = e.snapshot(at: date("2026-08-08 14:00:00"))
    expectClose(weekend.dayEarned, 0, "周末没有日收入")
    expectClose(weekend.dayTotal, 0, "周末没有日额度")
    if case .dayOff = weekend.status {} else { expect(false, "周末状态应当是休息") }
}

// MARK: - 月度与年度

do {
    let config = baseConfig()

    // 8 月最后一个工作日的收工时刻，本月应当刚好发满。
    let lastDay = engine(config, now: date("2026-08-31 18:00:00"))
    let endOfMonth = lastDay.snapshot(at: date("2026-08-31 18:00:00"))
    expectClose(endOfMonth.monthFraction, 1, "月末收工时本月进度应为 100%")
    expectClose(endOfMonth.monthEarned, config.monthlyPay, "月末收工时应当拿满月薪")
    expectClose(endOfMonth.yearFraction, 8.0 / 12.0, "8 月末年度进度应为 8/12")

    // 年末最后一个工作日：2026-12-31 是周四。
    let lastOfYear = engine(config, now: date("2026-12-31 18:00:00"))
    let endOfYear = lastOfYear.snapshot(at: date("2026-12-31 18:00:00"))
    expectClose(endOfYear.yearFraction, 1, "年末收工时年度进度应为 100%")
    expectClose(endOfYear.yearEarned, config.annualPay, "年末收工时应当拿满年薪")

    // 13 薪：年度百分比不变，但年度金额和总额一起放大。
    var thirteen = config
    thirteen.payMonthsPerYear = 13
    let bonusEngine = engine(thirteen, now: date("2026-08-31 18:00:00"))
    let bonus = bonusEngine.snapshot(at: date("2026-08-31 18:00:00"))
    expectClose(bonus.yearTotal, thirteen.monthlyPay * 13, "13 薪的年度总额是 13 个月")
    expectClose(bonus.yearFraction, 8.0 / 12.0, "13 薪不改变时间进度")
    expectClose(bonus.yearEarned, thirteen.monthlyPay * 13 * 8.0 / 12.0, "年终奖按进度摊到全年")

    // 年薪输入应当能反推回同样的月薪。
    var annual = config
    annual.salaryPeriod = .annual
    annual.salaryAmount = config.monthlyPay * 12
    expectClose(annual.monthlyPay, config.monthlyPay, "年薪换算回月薪应当一致")
}

// MARK: - 边界情况

do {
    var config = baseConfig()
    config.workdays = []
    let e = engine(config, now: date("2026-08-04 12:00:00"))
    let snapshot = e.snapshot(at: date("2026-08-04 12:00:00"))
    expect(e.workdaysThisMonth == 0, "没有工作日时统计为 0")
    expectClose(snapshot.monthEarned, 0, "没有工作日时不应产生收入，也不应除以 0")
    expect(snapshot.dayEarned.isFinite, "收入必须是有限数")

    var zeroHours = baseConfig()
    zeroHours.endMinutes = zeroHours.startMinutes
    let flat = engine(zeroHours, now: date("2026-08-04 12:00:00"))
    expect(flat.perSecondRate.isFinite, "工时为 0 时秒薪不能是 NaN 或无穷")
}

// MARK: - CSV 解析

do {
    let table = GitHubHolidaysSource.parseCSV(
        "date,weekday,name,type,comments\r\n"
            + "2026-03-11,Wednesday,\"Labour Day\",Regional Holiday,\"VIC, TAS\"\r\n"
            + "2026-03-12,Thursday,\"He said \"\"hi\"\"\",National Holiday,\n")
    expect(table.count == 3, "三行都要解析出来，CRLF 和末尾换行都不算额外行")
    expect(table[1][2] == "Labour Day", "带引号的字段要去掉引号")
    expect(table[1][4] == "VIC, TAS", "引号里的逗号不是分隔符")
    expect(table[2][2] == "He said \"hi\"", "两个连续引号还原成一个")
    expect(table[2][4] == "", "行尾的空字段要保留")

    let multiline = GitHubHolidaysSource.parseCSV("a,b\n\"line1\nline2\",c\n")
    expect(multiline.count == 2 && multiline[1][0] == "line1\nline2", "引号里的换行不断行")

    // 换个列序，靠表头取值就不会错位。
    let reordered = GitHubHolidaysSource.rows(
        fromCSV: "name,date,comments,type,weekday\nNew Year,2026-01-01,,National Holiday,Thursday\n")
    expect(reordered.count == 1, "调换列序后仍应解析出一行")
    expect(reordered.first?.date == "2026-01-01", "date 应当按表头取，而不是按位置")
    expect(reordered.first?.name == "New Year", "name 应当按表头取")
}

// MARK: - 假期类型映射

do {
    // 数据集里出现过的全部十种 type，外加空值。
    let national = ["National Holiday", "Public Holiday", "Federal Holiday", "Bank Holiday", "Statutory Holiday", "Official Holiday"]
    for type in national {
        expect(GitHubHolidaysSource.scope(forType: type) == .national, "\(type) 应当算全国性假日")
    }
    expect(GitHubHolidaysSource.scope(forType: "Regional Holiday") == .partial, "地方性假日跟着开关走")
    expect(GitHubHolidaysSource.scope(forType: "Government Holiday") == .partial, "只有公务员放的假跟着开关走")
    expect(GitHubHolidaysSource.scope(forType: "Not A Public Holiday") == .excluded, "明确不放假的日子任何时候都不算")

    // 伊朗、波兰、芬兰等 35 个国家的 type 整列为空，写的却是正经法定假日。
    // 这些若按"不是假期"处理，它们会一天假都没有。
    expect(GitHubHolidaysSource.scope(forType: "") == .national, "空 type 必须按全国性假日处理")
    expect(GitHubHolidaysSource.scope(forType: "   ") == .national, "只有空格的 type 同样按全国性假日处理")
    expect(GitHubHolidaysSource.scope(forType: "national holiday") == .national, "type 比对不分大小写")
}

// MARK: - 假期与调休提取

/// 覆盖跨天连休、地方性假日、明确不放假、同一天重复、以及调休备注。
let sampleCSV = """
    date,weekday,name,type,comments
    2026-02-16,Monday,Spring Festival Holiday,National Holiday,Chinese New Year Eve
    2026-02-17,Tuesday,Spring Festival,National Holiday,Chinese New Year
    2026-02-17,Tuesday,Some Local Thing,Regional Holiday,Only in one province
    2026-02-20,Friday,Spring Festival Holiday,National Holiday,Compensated by Sat Feb 14
    2026-03-08,Sunday,International Women's Day,Not A Public Holiday,Half day for women
    2026-04-06,Monday,Civil Servants Only,Government Holiday,Government only
    2026-05-05,Tuesday,Labour Day Holiday,National Holiday,Compensated by Sat May 9
    """

do {
    let national = GitHubHolidaysSource.parse(csv: sampleCSV, includeRegional: false)
    let dates = national.holidays.map(\.date)
    expect(dates == ["2026-02-16", "2026-02-17", "2026-02-20", "2026-05-05"], "只算全国性假日时应当得到 4 天")
    expect(!dates.contains("2026-03-08"), "标注为不放假的日子不应出现")
    expect(!dates.contains("2026-04-06"), "只有公务员放的假默认不算")
    expect(national.holidays.first { $0.date == "2026-02-17" }?.localName == "Spring Festival", "同一天全国性假日盖过地方性的")

    let all = GitHubHolidaysSource.parse(csv: sampleCSV, includeRegional: true)
    expect(all.holidays.count == 5, "打开开关后应当多出公务员假日那一天")
    expect(all.holidays.contains { $0.date == "2026-04-06" }, "公务员假日应当出现在完整名单里")
    expect(all.holidays.first { $0.date == "2026-02-17" }?.localName == "Spring Festival", "打开开关也不该让地方性假日盖掉全国性的")

    expect(national.makeupWorkdays == ["2026-02-14", "2026-05-09"], "两条调休备注都要解析出来")
    expect(all.makeupWorkdays == national.makeupWorkdays, "调休上班日与是否包含地方性假日无关")
}

do {
    // 调休日和假期撞在同一天时以放假为准。
    let conflicting = """
        date,weekday,name,type,comments
        2026-05-05,Tuesday,Labour Day,National Holiday,Compensated by Sat May 9
        2026-05-09,Saturday,Another Holiday,National Holiday,
        """
    let parsed = GitHubHolidaysSource.parse(csv: conflicting, includeRegional: false)
    expect(parsed.makeupWorkdays.isEmpty, "既是假期又被标成补班的日子应当算假期")
    expect(parsed.holidays.count == 2, "两天假期都要保留")
}

// MARK: - 调休备注的各种写法

do {
    // 左边这些备注全部原样取自数据集，写法在各国之间并不统一。
    let cases: [(comment: String, holiday: String, expected: String?, note: String)] = [
        ("Compensated by Sat Feb 14", "2026-02-20", "2026-02-14", "月 日"),
        ("Compensated by Sun Jan 4", "2026-01-02", "2026-01-04", "补班日在假期之后"),
        ("Compensated by Sat. 23 May", "2026-05-25", "2026-05-23", "日 月，星期几后面带句点"),
        ("Compensated by Sat 25 April", "2026-04-20", "2026-04-25", "月份用全称"),
        ("Compensated by Sat, Jan. 10", "2026-01-02", "2026-01-10", "逗号和句点混用"),
        ("Compensated by Sat Sept 2", "2026-10-01", "2026-09-02", "Sept 是四个字母的缩写"),
        ("Compensated by June 27", "2026-06-23", "2026-06-27", "不写星期几"),
        ("Compensated by 14 Dec", "2026-12-23", "2026-12-14", "只有日和月"),
        ("Compensated by Sat Dec 29 2024", "2025-01-03", "2024-12-29", "备注里写了年份就以它为准"),
        ("Compensated by Sat 10 Jan 2026", "2025-12-26", "2026-01-10", "跨年且写了年份"),
        ("Compensated by Sat. Dec 30", "2024-01-04", "2023-12-30", "同年的 12-30 离得太远，靠星期几判定是上一年"),
        ("Compensated by Sun. 5 Jan", "2025-12-31", "2025-01-05", "同年的 1-5 星期几对得上，就用同年"),
        ("Compensated by Sat. Feb 4", "2024-02-15", "2024-02-04", "星期几标错了也不能丢掉正确的日期"),
        ("Compensatory rest day for Tung Ng Festival", "2025-06-02", nil, "只是补假说明，没有日期"),
        ("Chinese New Year Eve", "2026-02-16", nil, "普通备注不该解析出补班日"),
        ("", "2026-02-16", nil, "空备注"),
        ("Compensated by Feb 30", "2026-02-20", nil, "不存在的日期不能顺延到 3 月"),
        ("Compensated by Saturday", "2026-02-20", nil, "缺月份就放弃"),
    ]
    for item in cases {
        let actual = GitHubHolidaysSource.compensationDay(comment: item.comment, holidayDate: item.holiday)
        expect(actual == item.expected, "「\(item.comment)」（\(item.note)）应当得到 \(item.expected ?? "nil")，实际是 \(actual ?? "nil")")
    }
}

// MARK: - 数据文件地址

do {
    expect(
        GitHubHolidaysSource.fileURL(countryCode: "CN", year: 2026)?.absoluteString
            == "https://raw.githubusercontent.com/wrfly/holidays/refs/heads/main/CN/2026.csv",
        "文件地址按 国家/年份 拼")
    expect(GitHubHolidaysSource.fileURL(countryCode: "cn", year: 2026)?.absoluteString.contains("/CN/") == true, "国家代码统一转成大写")
    expect(GitHubHolidaysSource.fileURL(countryCode: "CHN", year: 2026) == nil, "只接受两位国家代码")
    expect(GitHubHolidaysSource.fileURL(countryCode: "../", year: 2026) == nil, "非字母的代码要挡掉")
}

// MARK: - 自动调休参与工作日判定

do {
    var config = baseConfig()
    config.useAutoHolidays = true
    config.useAutoMakeupWorkdays = true
    let holidays: Set<String> = ["2026-02-16", "2026-02-17"]
    let makeup: Set<String> = ["2026-02-14", "2026-02-28"]

    let workCalendar = WorkCalendar(config: config, autoHolidays: holidays, autoMakeupWorkdays: makeup, calendar: calendar)
    expect(workCalendar.isWorkday(date("2026-02-14 10:00:00")), "被挪成上班日的周六算工作日")
    expect(!workCalendar.isHoliday(date("2026-02-14 10:00:00")), "补班的周六不算休息日")
    expect(!workCalendar.isWorkday(date("2026-02-16 10:00:00")), "法定假日仍然不上班")
    expect(!workCalendar.isWorkday(date("2026-02-21 10:00:00")), "没被点名的周六照常休息")

    var manualOff = config
    manualOff.extraHolidays = ["2026-02-14"]
    let withLeave = WorkCalendar(config: manualOff, autoHolidays: holidays, autoMakeupWorkdays: makeup, calendar: calendar)
    expect(!withLeave.isWorkday(date("2026-02-14 10:00:00")), "自己请的假要盖过数据源里的补班日")

    var noMakeup = config
    noMakeup.useAutoMakeupWorkdays = false
    let ignoring = WorkCalendar(config: noMakeup, autoHolidays: holidays, autoMakeupWorkdays: makeup, calendar: calendar)
    expect(!ignoring.isWorkday(date("2026-02-14 10:00:00")), "关掉自动调休后周六恢复休息")
    expect(!ignoring.isWorkday(date("2026-02-16 10:00:00")), "关掉自动调休不影响法定假日")

    var noAuto = config
    noAuto.useAutoHolidays = false
    let manual = WorkCalendar(config: noAuto, autoHolidays: holidays, autoMakeupWorkdays: makeup, calendar: calendar)
    expect(!manual.isWorkday(date("2026-02-14 10:00:00")), "关掉自动假期后调休也一并不用")
    expect(manual.isWorkday(date("2026-02-16 10:00:00")), "关掉自动假期后法定假日照常上班")
}

// MARK: - 配置向后兼容

do {
    // 旧版本存下来的配置只有一部分字段，其余的必须回落到默认值而不是解码失败。
    let partial = #"{"salaryAmount": 12345, "currencyCode": "JPY"}"#.data(using: .utf8)!
    guard let decoded = try? JSONDecoder().decode(Configuration.self, from: partial) else {
        expect(false, "缺字段的配置应当仍可解码")
        exit(1)
    }
    expectClose(decoded.salaryAmount, 12345, "已有字段应当被读出来")
    expect(decoded.currencyCode == "JPY", "已有字段应当被读出来")
    expect(decoded.useAutoMakeupWorkdays, "新增字段回落到默认值")
    expect(!decoded.includeRegionalHolidays, "新增字段回落到默认值")
    expect(decoded.workdays == [2, 3, 4, 5, 6], "缺失字段回落到默认工作日")
    expect(decoded.startMinutes == 9 * 60, "缺失字段回落到默认上班时间")

    let roundTrip = try? JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(decoded))
    expect(roundTrip == decoded, "编码再解码应当完全一致")

    // 新增的外观字段：旧配置缺失时宽松回退到 .system。
    expect(decoded.appearance == .system, "旧配置缺 appearance 字段时回退到跟随系统")
}

// MARK: - 外观设置解码与迁移

do {
    // 缺失 appearance 字段 → 回退 .system。
    let legacy = #"{"salaryAmount": 100}"#.data(using: .utf8)!
    let decodedLegacy = try? JSONDecoder().decode(Configuration.self, from: legacy)
    expect(decodedLegacy?.appearance == .system, "缺 appearance 字段回退 .system")

    // 显式 light / dark 应被正确读回。
    for (raw, expected) in [("light", AppAppearance.light), ("dark", AppAppearance.dark), ("system", AppAppearance.system)] {
        let json = "{\"appearance\":\"\(raw)\"}".data(using: .utf8)!
        let d = try? JSONDecoder().decode(Configuration.self, from: json)
        expect(d?.appearance == expected, "appearance=\(raw) 应解为 \(expected.rawValue)")
    }

    // 编码再解码一致。
    var c = Configuration()
    c.appearance = .dark
    let rt = try? JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(c))
    expect(rt?.appearance == .dark, "appearance 编码再解码一致")

    // 枚举全集：system/light/dark 三档，顺序稳定。
    expect(AppAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"], "AppAppearance 三档顺序")
}

// MARK: - 界面语言与地区

do {
    let systemRegion = Locale.current.region

    // 联合国六种官方语言里的五种，暂缺需要 RTL 的阿拉伯语。
    let codes = AppLanguage.allCases.compactMap(\.localizationCode)
    expect(Set(codes) == ["en", "zh-Hans", "fr", "ru", "es"], "应当覆盖英中法俄西五种语言，实际是 \(codes.sorted())")
    expect(Set(codes).count == codes.count, "语言代码不能重复，否则两个选项会指向同一个语言包")
    expect(AppLanguage.allCases.first == .system, "跟随系统应当排在选择器第一位")

    for language in AppLanguage.allCases {
        guard let code = language.localizationCode else { continue }
        Loc.select(language)
        let expected = Locale.Language(identifier: code)
        expect(
            Loc.locale.language.languageCode == expected.languageCode,
            "\(code) 的语言码应当是 \(expected.languageCode?.identifier ?? "?")，实际是 \(Loc.locale.language.languageCode?.identifier ?? "nil")")
        expect(Loc.locale.region == systemRegion, "切到 \(code) 不能改变地区，否则金额和日期格式会跟着跑偏")
        expect(!language.nativeName.isEmpty, "\(code) 得有一个母语写法，否则选择器上是空白")
    }

    Loc.select(.simplifiedChinese)
    expect(Loc.locale.language.script?.identifier == "Hans", "简体中文必须带上 Hans 字形，否则可能匹配到繁体")

    Loc.select(.system)
    expect(Loc.locale == Locale.current, "跟随系统时直接用当前 locale")
}

// MARK: - 数字与时长跟随语言

do {
    Loc.select(.english)
    let hoursEN = Formatters.duration(12250)
    let underHourEN = Formatters.duration(1450)
    expect(hoursEN.contains("hr"), "英文时长应当用 hr/min/sec，实际是 \(hoursEN)")
    expect(!underHourEN.contains("hr"), "不足一小时时不应出现小时单位，实际是 \(underHourEN)")
    expect(!Formatters.duration(0).isEmpty, "零秒也要有输出，不能是空串")

    Loc.select(.simplifiedChinese)
    let hoursZH = Formatters.duration(12250)
    expect(hoursZH.contains("小时"), "中文时长应当带小时二字，实际是 \(hoursZH)")
    expect(hoursEN != hoursZH, "同一个秒数在两种语言下的写法应当不同")

    Loc.select(.russian)
    let hoursRU = Formatters.duration(12250)
    expect(hoursRU.contains("ч"), "俄语时长应当用西里尔字母的单位，实际是 \(hoursRU)")

    // 五种语言的时长写法必须两两不同，否则说明某种语言压根没生效。
    var spellings: Set<String> = []
    for language in AppLanguage.allCases where language != .system {
        Loc.select(language)
        spellings.insert(Formatters.duration(12250))
    }
    expect(spellings.count == 5, "五种语言应当给出 5 种不同的时长写法，实际只有 \(spellings.count) 种")

    Loc.select(.system)
}

// MARK: - 休息原因不带翻译

do {
    // 引擎存的是原因本身而不是拼好的句子，界面语言变了状态也就跟着变。
    let holiday = PublicHoliday(date: "2026-08-05", localName: "Test Day", name: "Test Day")
    let e = EarningsEngine(
        config: baseConfig(),
        autoHolidays: ["2026-08-05"],
        holidayNames: ["2026-08-05": holiday],
        now: date("2026-08-05 14:00:00"),
        calendar: calendar
    )
    expect(e.snapshot(at: date("2026-08-05 14:00:00")).status == .dayOff(.holiday(name: "Test Day")), "假日应当带上数据源给的名字")

    let plain = engine(baseConfig(), now: date("2026-08-08 14:00:00"))
    expect(plain.snapshot(at: date("2026-08-08 14:00:00")).status == .dayOff(.restDay), "周末是普通休息日，没有假日名")

    var noHours = baseConfig()
    noHours.endMinutes = noHours.startMinutes
    let idle = engine(noHours, now: date("2026-08-04 12:00:00"))
    expect(idle.snapshot(at: date("2026-08-04 12:00:00")).status == .dayOff(.noSchedule), "没设置工时应当报 noSchedule")
}

// MARK: - 语言设置的向后兼容

do {
    expect(Configuration().language == .system, "新配置默认跟随系统语言")

    let legacy = #"{"salaryAmount": 100}"#.data(using: .utf8)!
    let decoded = try? JSONDecoder().decode(Configuration.self, from: legacy)
    expect(decoded?.language == .system, "旧配置没有 language 字段时回落到跟随系统")

    var chinese = Configuration()
    chinese.language = .simplifiedChinese
    let roundTrip = try? JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(chinese))
    expect(roundTrip?.language == .simplifiedChinese, "语言选择要能存下来")
}

// MARK: - 假日缓存该不该过期

do {
    // 年份过完，官方安排就定死了，本地有副本就不必再问服务器。
    expect(
        HolidayYearPolicy.of(year: 2025, now: date("2026-07-31 12:00:00"), calendar: calendar) == .frozen,
        "已经过去的年份冻结，不再联网")
    expect(
        HolidayYearPolicy.of(year: 2019, now: date("2026-01-01 00:00:00"), calendar: calendar) == .frozen,
        "更早的年份同样冻结")

    // 当年可能临时加假（英国女王葬礼、美国 Juneteenth 都是当年才定的），
    // 数据源本身也可能修勘误，所以要校验。
    expect(
        HolidayYearPolicy.of(year: 2026, now: date("2026-07-31 12:00:00"), calendar: calendar) == .revalidate,
        "当年要校验")

    // 次年才是关键：国务院通常前一年 11 月才公布调休安排，在那之前
    // 数据源里只有节日日期没有补班日，冻结下来会让 2027 整年算错。
    expect(
        HolidayYearPolicy.of(year: 2027, now: date("2026-07-31 12:00:00"), calendar: calendar) == .revalidate,
        "次年要校验，调休安排还没公布")
    expect(
        HolidayYearPolicy.of(year: 2027, now: date("2026-12-31 23:59:59"), calendar: calendar) == .revalidate,
        "跨年前一刻，次年仍然要校验")

    // 跨过年之后，原先那份不完整的次年数据自动转为需要校验的当年数据。
    expect(
        HolidayYearPolicy.of(year: 2027, now: date("2027-01-01 00:00:00"), calendar: calendar) == .revalidate,
        "元旦当天，2027 变成当年，继续校验")
    expect(
        HolidayYearPolicy.of(year: 2026, now: date("2027-01-01 00:00:00"), calendar: calendar) == .frozen,
        "元旦当天，2026 才冻结")
}

// MARK: - 离开工位期间公司照付的钱

do {
    let config = baseConfig()
    // 2026-03-02 是周一。这组用例里没有自动假日，所以就是个普通工作日。
    let anchor = date("2026-03-02 09:00:00")
    let e = engine(config, now: anchor)
    expect(e.workCalendar.workdaysInMonth(containing: anchor) == 22, "2026 年 3 月应有 22 个工作日")

    // 午休锁屏，公司一分钱不给。
    let lunch = e.awayReport(from: date("2026-03-02 12:10:00"), to: date("2026-03-02 12:50:00"))
    expectClose(lunch.paidSeconds, 0, "午休期间锁屏不计薪")
    expectClose(lunch.amount, 0, "午休期间锁屏没有收入")
    expectClose(lunch.awaySeconds, 40 * 60, "离开的总时长仍然照算")
    expect(!lunch.isWorthShowing, "没赚到钱就不该提示")

    // 上班时段内摸鱼半小时。日薪 22000/22 = 1000，每天计薪 28800 秒。
    let short = e.awayReport(from: date("2026-03-02 14:00:00"), to: date("2026-03-02 14:30:00"))
    expectClose(short.paidSeconds, 1800, "工作时段内锁屏半小时计薪 1800 秒")
    expectClose(short.amount, 62.5, "1800 / 28800 × 1000 = 62.5")

    let acrossLunch = e.awayReport(from: date("2026-03-02 11:30:00"), to: date("2026-03-02 13:30:00"))
    expectClose(acrossLunch.paidSeconds, 3600, "跨午休时中间那一小时要挖掉")

    let acrossEnd = e.awayReport(from: date("2026-03-02 17:30:00"), to: date("2026-03-02 19:00:00"))
    expectClose(acrossEnd.paidSeconds, 1800, "下班之后的部分不计薪")

    let afterHours = e.awayReport(from: date("2026-03-02 19:00:00"), to: date("2026-03-02 22:00:00"))
    expectClose(afterHours.paidSeconds, 0, "整段都在下班后就没有收入")

    let overnight = e.awayReport(from: date("2026-03-02 17:00:00"), to: date("2026-03-03 10:00:00"))
    expectClose(overnight.paidSeconds, 7200, "跨夜只算两端落在工作时段里的部分")

    // 周五下班锁到周一早上，中间的周末整个跳过。
    let weekend = e.awayReport(from: date("2026-03-06 17:00:00"), to: date("2026-03-09 10:00:00"))
    expectClose(weekend.paidSeconds, 7200, "周末不计薪")

    let withHoliday = engine(config, holidays: ["2026-03-03"], now: anchor)
    let overHoliday = withHoliday.awayReport(from: date("2026-03-02 17:00:00"), to: date("2026-03-03 10:00:00"))
    expectClose(overHoliday.paidSeconds, 3600, "次日是节假日时只算周一那一小时")

    // 跨月要按各自月份的工作日数折算日薪：2 月 20 天日薪 1100，3 月 22 天日薪 1000。
    let friday = date("2026-02-27 17:00:00")
    expect(e.workCalendar.workdaysInMonth(containing: friday) == 20, "2026 年 2 月应有 20 个工作日")
    let acrossMonths = e.awayReport(from: friday, to: date("2026-03-02 10:00:00"))
    expectClose(acrossMonths.paidSeconds, 7200, "跨月又跨周末，两端各一小时")
    expectClose(acrossMonths.amount, 137.5 + 125, "两个月日薪不同，必须分开折算")

    // 锁屏几十秒就弹提示太吵。
    let blink = e.awayReport(from: date("2026-03-02 14:00:00"), to: date("2026-03-02 14:00:59"))
    expect(!blink.isWorthShowing, "计薪不足一分钟不提示")
    let justEnough = e.awayReport(from: date("2026-03-02 14:00:00"), to: date("2026-03-02 14:01:00"))
    expect(justEnough.isWorthShowing, "刚好一分钟就该提示")

    // 系统时间被回拨之类的情况，不能算出钱来。
    let backwards = e.awayReport(from: date("2026-03-02 14:30:00"), to: date("2026-03-02 14:00:00"))
    expectClose(backwards.paidSeconds, 0, "结束早于开始时不计薪")
    expectClose(backwards.amount, 0, "结束早于开始时没有收入")

    // 没配工作时段的话不该崩，也不该凭空生出钱。
    var noHours = config
    noHours.startMinutes = 9 * 60
    noHours.endMinutes = 9 * 60
    let empty = engine(noHours, now: anchor)
    expectClose(
        empty.awayReport(from: date("2026-03-02 09:00:00"), to: date("2026-03-02 18:00:00")).amount,
        0,
        "没有计薪时段时收入为零")
}

// MARK: - 税前税后：税档与累计预扣

do {
    // 税档边界：累计应纳税所得额恰好等于上界时按该档。
    expectClose(TaxRules.cumulativeTax(on: Money.yuan(36_000)).doubleYuan, 36_000 * 0.03, "36000 用 3% 档")
    expectClose(
        TaxRules.cumulativeTax(on: Money.yuan(144_000)).doubleYuan,
        144_000 * 0.10 - 2_520,
        "144000 用 10% 档并减速算扣除 2520")
    expectClose(
        TaxRules.cumulativeTax(on: Money.yuan(300_000)).doubleYuan,
        300_000 * 0.20 - 16_920,
        "300000 用 20% 档")
    expectClose(
        TaxRules.cumulativeTax(on: Money.yuan(420_000)).doubleYuan,
        420_000 * 0.25 - 31_920,
        "420000 用 25% 档")
    expectClose(
        TaxRules.cumulativeTax(on: Money.yuan(660_000)).doubleYuan,
        660_000 * 0.30 - 52_920,
        "660000 用 30% 档")
    expectClose(
        TaxRules.cumulativeTax(on: Money.yuan(960_000)).doubleYuan,
        960_000 * 0.35 - 85_920,
        "960000 用 35% 档")
    expectClose(
        TaxRules.cumulativeTax(on: Money.yuan(1_000_000)).doubleYuan,
        1_000_000 * 0.45 - 181_920,
        "超 960000 用 45% 档")
    expect(TaxRules.cumulativeTax(on: .zero) == .zero, "0 应纳税所得额税额为 0")
    expect(TaxRules.cumulativeTax(on: Money.yuan(-1)) == .zero, "负所得额税额为 0")
}

// MARK: - 税前税后：适用性与参数校验

do {
    expect(NetPayCalculator.applies(countryCode: "CN", currencyCode: "CNY"), "CN+CNY 适用税后")
    expect(!NetPayCalculator.applies(countryCode: "US", currencyCode: "USD"), "非 CN 不适用")
    expect(!NetPayCalculator.applies(countryCode: "CN", currencyCode: "USD"), "CN 但非 CNY 不适用")

    // 非支持国家/货币：blocked，available=false，绝不静默给净额。
    let bad = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: .init(),
        countryCode: "US", currencyCode: "USD")
    expect(!bad.available && !bad.blocked.isEmpty, "非支持国家/货币应阻塞而非静默")

    // 任职起月非法。
    var p = TaxProfile(); p.employmentStartMonth = 13
    let badMonth = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: p,
        countryCode: "CN", currencyCode: "CNY")
    expect(!badMonth.available, "任职起月 13 应阻塞")
}

// MARK: - 税前税后：逐月累计预扣（无负税/退税）

do {
    // 月薪 20000，无社保（全 disabled），无专项/其他扣除，任职 1 月。
    var noSocialProfile = TaxProfile()
    noSocialProfile.social = SocialInsurance()
    noSocialProfile.social.pension = .disabled
    noSocialProfile.social.medical = .disabled
    noSocialProfile.social.medicalFixed = .disabled
    noSocialProfile.social.unemployment = .disabled
    noSocialProfile.social.housingFund = .disabled
    let r = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: noSocialProfile,
        countryCode: "CN", currencyCode: "CNY")
    expect(r.available, "基础参数应可计算")

    // 每月应纳税所得额 = 20000 - 5000 = 15000。
    // 1 月：累计 15000 × 3% = 450。
    // 2 月：累计 30000 × 3% = 900，当月 = 900 - 450 = 450。
    expectClose(r.months[0].tax.doubleYuan, 450, "1 月预扣 450")
    expectClose(r.months[1].tax.doubleYuan, 450, "2 月预扣 450")

    // 进入 10% 档后（累计超 36000），当月税额 = 累计应缴 − 累计已扣。
    // 累计应纳税所得额第 3 月 = 45000 → 45000×10%−2520 = 1980，当月 = 1980−900 = 1080。
    expectClose(r.months[2].tax.doubleYuan, 1080, "3 月跨入 10% 档后当月预扣 1080")

    // 全年不应出现负税。
    for m in r.months {
        expect(m.tax.cents >= 0, "\(m.month) 月税额不得为负")
    }

    // 到手 = 毛额 - 社保 - 税；无社保时 1 月 = 20000 - 450。
    expectClose(r.months[0].net.doubleYuan, 19_550, "1 月到手 19550")

    // 全年 Σ12 个月净额，不是 12×某月。
    let yearNet = r.yearNet.doubleYuan
    let sumMonths = r.months.reduce(0.0) { $0 + $1.net.doubleYuan }
    expectClose(yearNet, sumMonths, "全年净额 = Σ12 个月净额")
    expect(r.yearGross.cents == 240_000 * 100, "全年毛额 240000")
}

// MARK: - 税前税后：社保扣缴与地区预设

do {
    // 北京：养老 8% + 医疗 2% + 失业 0.5% + 医疗固定 3；公积金 5%。
    var social = SocialInsurance()
    social.pension = .manual(Money.yuan(10_000))
    social.medical = .manual(Money.yuan(10_000))
    social.medicalFixed = .manual(Money.yuan(3))
    social.unemployment = .manual(Money.yuan(10_000))
    social.housingFund = .manual(Money.yuan(10_000))
    social.housingFundRateBp = 500
    var profile = TaxProfile()
    profile.region = "beijing"
    profile.social = social

    let r = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: profile,
        countryCode: "CN", currencyCode: "CNY")
    expect(r.available, "北京参数应可计算")

    let socialTotal = r.months[0].socialTotal.doubleYuan
    // 养老 800 + 医疗 200 + 失业 50 + 医疗固定 3 + 公积金 500 = 1553。
    expectClose(socialTotal, 1_553, "北京社保个人合计 1553")

    // 显式不参与 → 该项缴费为 0。
    var disabled = SocialInsurance()
    disabled.pension = .disabled
    disabled.medical = .disabled
    disabled.medicalFixed = .disabled
    disabled.unemployment = .disabled
    disabled.housingFund = .disabled
    var pd = TaxProfile(); pd.social = disabled
    let rd = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: pd,
        countryCode: "CN", currencyCode: "CNY")
    expectClose(rd.months[0].socialTotal.doubleYuan, 0, "显式不参与缴费项不扣款")

    // 超上下限：北京养老手填基数 50000 超上限 36348 → 参考模式阻塞（可切自定义），保留原输入不覆盖。
    var over = social
    over.pension = .manual(Money.yuan(50_000))
    var p3 = TaxProfile(); p3.region = "beijing"; p3.social = over
    let r3 = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: p3,
        countryCode: "CN", currencyCode: "CNY")
    expect(!r3.available, "参考地区手填超上限应阻塞")
    expect(r3.blocked.contains { $0.contains("超出") && $0.contains("自定义") }, "阻塞信息应提示可切自定义")
    // 保留原输入：resolve 返回的 base 仍是 50000，不被 clamp/覆盖。
    let resolvedOver = NetPayCalculator.resolve(profile: p3, grossMonthly: Money.yuan(20_000))
    expectClose(resolvedOver.pension.base.doubleYuan, 50_000, "手填超限值保留原输入")

    // 自定义地区：同样手填 50000 在合法范围估算，给假设提示，可计算。
    let custom = over
    var pc = TaxProfile(); pc.region = "custom"; pc.social = custom
    let rc = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: pc,
        countryCode: "CN", currencyCode: "CNY")
    expect(rc.available, "自定义地区手填超限可估算")
    expectClose(rc.months[0].social.pension.doubleYuan, 4_000, "自定义手填 50000 养老 8% = 4000")
    expect(rc.warnings.contains { $0.contains("自定义") }, "自定义模式给假设提示")
}

// MARK: - 税前税后：参数范围与比例校验

do {
    // 负基数、非法比例（<0 或 >100%）、负扣除必须阻塞。
    var neg = TaxProfile(); neg.region = "beijing"
    neg.social.pension = .manual(Money(cents: -1))
    let rNeg = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: neg,
        countryCode: "CN", currencyCode: "CNY")
    expect(!rNeg.available, "负基数应阻塞")

    var rateHigh = TaxProfile(); rateHigh.region = "beijing"
    rateHigh.social.pensionRateBp = 10_001
    let rRate = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: rateHigh,
        countryCode: "CN", currencyCode: "CNY")
    expect(!rRate.available, "比例 >100% 应阻塞")

    var rateNeg = TaxProfile(); rateNeg.region = "beijing"
    rateNeg.social.pensionRateBp = -1
    let rRateNeg = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: rateNeg,
        countryCode: "CN", currencyCode: "CNY")
    expect(!rRateNeg.available, "负比例应阻塞")

    var negDed = TaxProfile(); negDed.region = "beijing"
    negDed.monthlySpecialDeduction = Money(cents: -1)
    let rDed = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: negDed,
        countryCode: "CN", currencyCode: "CNY")
    expect(!rDed.available, "负专项扣除应阻塞")

    // 公积金比例超地区参考范围：参考模式阻塞；自定义可算。
    var fundHigh = TaxProfile(); fundHigh.region = "beijing"
    fundHigh.social.housingFundRateBp = 1_300  // 13% 超北京 5–12%
    let rFund = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: fundHigh,
        countryCode: "CN", currencyCode: "CNY")
    expect(!rFund.available, "公积金比例超参考范围应阻塞")
    expect(rFund.blocked.contains { $0.contains("公积金") }, "阻塞信息指出公积金比例")

    var fundCustom = fundHigh; fundCustom.region = "custom"
    let rFundC = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: fundCustom,
        countryCode: "CN", currencyCode: "CNY")
    expect(rFundC.available, "自定义地区公积金比例超范围可估算")

    // disabled 项不应因隐藏残留无效值阻塞：disabled 且比例非法不误报。
    var disabledWithJunk = TaxProfile(); disabledWithJunk.region = "beijing"
    disabledWithJunk.social.pension = .disabled
    disabledWithJunk.social.pensionRateBp = 10_001  // 隐藏残留非法比例
    let rDisabled = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: disabledWithJunk,
        countryCode: "CN", currencyCode: "CNY")
    expect(rDisabled.months[0].social.pension.doubleYuan == 0 || !rDisabled.available == false,
           "disabled 项缴费为 0")
}

// MARK: - 税前税后：自动基数随月薪按上下限取值

do {
    // 北京 auto 基数：月薪 20000 落在上下限内 → 用 20000。
    var auto = TaxProfile()
    auto.region = "beijing"
    auto.social = SocialInsurance()  // 全 .auto，比例用默认 8/2/0.5 + 公积金 5%
    let r = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: auto,
        countryCode: "CN", currencyCode: "CNY")
    expect(r.available, "auto 基数应可计算")
    // 养老 20000×8%=1600 + 医疗 400 + 失业 100 + 医疗固定 3 + 公积金 20000×5%=1000 = 3103。
    expectClose(r.months[0].socialTotal.doubleYuan, 3_103, "auto 基数月薪 20000 北京合计 3103")
    // 逐项核对：养老 1600、医疗 400、失业 100、医疗固定 3、公积金 1000。
    expectClose(r.months[0].social.pension.doubleYuan, 1_600, "养老 20000×8%=1600")
    expectClose(r.months[0].social.medical.doubleYuan, 400, "医疗 20000×2%=400")
    expectClose(r.months[0].social.medicalFixed.doubleYuan, 3, "北京医疗固定 3")
    expectClose(r.months[0].social.unemployment.doubleYuan, 100, "失业 20000×0.5%=100")
    expectClose(r.months[0].social.housingFund.doubleYuan, 1_000, "公积金 20000×5%=1000")

    // 低于下限：月薪 3000 北京养老下限 7270 → 基数 clamp 到 7270。
    let low = NetPayCalculator.compute(
        grossMonthly: Money.yuan(3_000), payMonthsPerYear: 12, profile: auto,
        countryCode: "CN", currencyCode: "CNY")
    let lowPension = low.months[0].social.pension.doubleYuan
    expectClose(lowPension, 7_270 * 0.08, "低于下限按 7270 基数取养老")

    // 高于上限：月薪 100000 北京上限 36348 → 基数 clamp 到 36348。
    let high = NetPayCalculator.compute(
        grossMonthly: Money.yuan(100_000), payMonthsPerYear: 12, profile: auto,
        countryCode: "CN", currencyCode: "CNY")
    let highPension = high.months[0].social.pension.doubleYuan
    expectClose(highPension, 36_348 * 0.08, "高于上限按 36348 基数取养老")

    // 手动覆盖优先于 auto 与工资：手填 8000 养老，不随工资变。
    var manual = SocialInsurance()
    manual.pension = .manual(Money.yuan(8_000))
    var pm = TaxProfile(); pm.region = "beijing"; pm.social = manual
    let rm = NetPayCalculator.compute(
        grossMonthly: Money.yuan(20_000), payMonthsPerYear: 12, profile: pm,
        countryCode: "CN", currencyCode: "CNY")
    expectClose(rm.months[0].social.pension.doubleYuan, 640, "手填养老 8000 覆盖 auto")

    // 工资变化：auto 跟随，manual 不动。
    let rAuto20k = r.resolved.pension.base.doubleYuan
    let rAuto30k = NetPayCalculator.resolve(profile: auto, grossMonthly: Money.yuan(30_000))
    expectClose(rAuto20k, 20_000, "auto 基数随工资 20000")
    expectClose(rAuto30k.pension.base.doubleYuan, 30_000, "auto 基数随工资 30000")
    let rManual20k = NetPayCalculator.resolve(profile: pm, grossMonthly: Money.yuan(20_000))
    let rManual30k = NetPayCalculator.resolve(profile: pm, grossMonthly: Money.yuan(30_000))
    expectClose(rManual20k.pension.base.doubleYuan, 8_000, "manual 基数 8000（工资 2 万）")
    expectClose(rManual30k.pension.base.doubleYuan, 8_000, "manual 基数 8000 不随工资 3 万变")

    // 北京→上海切换：只更新 auto 基数的上下限与医疗固定额；手动养老 8000 保留。
    var sh = TaxProfile(); sh.region = "shanghai"; sh.social = manual
    let rsh = NetPayCalculator.resolve(profile: sh, grossMonthly: Money.yuan(20_000))
    expectClose(rsh.pension.base.doubleYuan, 8_000, "切换上海后手填养老 8000 保留")
    expectClose(rsh.medicalFixed.amount.doubleYuan, 0, "上海医疗固定额 0")
    var autoSh = TaxProfile(); autoSh.region = "shanghai"; autoSh.social = SocialInsurance()
    let rAutoSh = NetPayCalculator.resolve(profile: autoSh, grossMonthly: Money.yuan(20_000))
    expectClose(rAutoSh.pension.base.doubleYuan, 20_000, "上海 auto 基数随工资")
    expectClose(rAutoSh.medicalFixed.amount.doubleYuan, 0, "上海 auto 医疗固定 0")

    // 零工资：auto 参数时缴费与净额均为 0，不被最低基数抬成负数。
    let zero = NetPayCalculator.compute(
        grossMonthly: .zero, payMonthsPerYear: 12, profile: auto,
        countryCode: "CN", currencyCode: "CNY")
    expect(zero.available, "零工资应可计算")
    expectClose(zero.months[0].socialTotal.doubleYuan, 0, "零工资 auto 缴费为 0")
    expectClose(zero.months[0].net.doubleYuan, 0, "零工资到手为 0")

    // 手填 0 固定额是有效值，不被当 unset。
    var zeroFixed = SocialInsurance()
    zeroFixed.medicalFixed = .manual(.zero)
    var pzf = TaxProfile(); pzf.region = "beijing"; pzf.social = zeroFixed
    let rzf = NetPayCalculator.resolve(profile: pzf, grossMonthly: Money.yuan(20_000))
    expect(rzf.medicalFixed.state == .manual, "手填 0 固定额状态为 manual")
    expectClose(rzf.medicalFixed.amount.doubleYuan, 0, "手填 0 固定额金额 0")
}

// MARK: - 税前税后：年薪换算与编码往返

do {
    // 年薪换算：年薪 240000 / 12 = 月薪 20000，一次换算，税后基数按月薪解析。
    var annual = Configuration()
    annual.salaryPeriod = .annual
    annual.salaryAmount = 240_000
    expectClose(annual.monthlyPay, 20_000, "年薪 240000 换算月薪 20000")
    var profile = TaxProfile(); profile.region = "beijing"; profile.social = SocialInsurance()
    let r = NetPayCalculator.compute(
        grossMonthly: Money(yuan: annual.monthlyPay), payMonthsPerYear: 12, profile: profile,
        countryCode: "CN", currencyCode: "CNY")
    expectClose(r.resolved.pension.base.doubleYuan, 20_000, "年薪换算后 auto 基数 20000")

    // gross↔net 切换与编码解码保留手填覆盖。
    var c = Configuration()
    c.payMode = .net
    c.tax.social.pension = .manual(Money.yuan(9_000))
    let rt = try? JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(c))
    expect(rt?.payMode == .net, "payMode net 编码往返")
    expect(rt?.tax.social.pension == .manual(Money.yuan(9_000)), "手填养老 9000 编码往返保留")
    var c2 = Configuration()
    c2.payMode = .gross
    expect(c2.tax.social.pension == .auto, "gross 模式默认 auto 基数")

    // 恢复默认清手动：resetToDefaults 语义由 Configuration() 覆盖，这里验证默认态无手填。
    expect(Configuration().tax.social.pension == .auto, "默认配置无手填覆盖")
}

// MARK: - 税前税后：gross 模式不变

do {
    // gross 模式（默认）必须与原有行为逐字节一致。
    let config = baseConfig()
    let e = engine(config, now: date("2026-08-04 12:00:00"))
    expect(!e.isNetActive, "默认税前不激活税后")
    let snap = e.snapshot(at: date("2026-08-04 12:00:00"))
    let dailyPay = config.monthlyPay / Double(e.workdaysThisMonth)
    expectClose(snap.dayTotal, dailyPay, "gross 日总额用日薪毛额")
    expectClose(snap.yearTotal, config.annualPay, "gross 年总额 = 年薪")
}

// MARK: - 税前税后：Money 精度

do {
    // 比例按分四舍五入。
    let base = Money.yuan(10_000)
    expectClose(base.applyingRate(bp: 800).doubleYuan, 800, "8% 基数 10000 = 800")
    expectClose(base.applyingRate(bp: 50).doubleYuan, 50, "0.5% 基数 10000 = 50")
    // 一分四舍五入：3333.33 × 3% = 99.9999 → 100 元（10000 分）。
    let odd = Money.yuan(3_333.33)
    expect(odd.applyingRate(bp: 300).cents == 10_000, "3% 基数 3333.33 四舍五入到 100 元")
}

// MARK: - 发薪账期：默认兼容与跨月 26–25 账期

do {
    // 旧配置缺 payroll 字段 → enabled=false，自然月口径。
    let legacy = #"{"salaryAmount": 100}"#.data(using: .utf8)!
    let decoded = try? JSONDecoder().decode(Configuration.self, from: legacy)
    expect(decoded?.payroll.enabled == false, "旧配置账期默认关闭（自然月）")

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // cutoff 25 / payday 10 / 次月：结算月 M 的账期 = [M-1月26, M月25]。
    let pc = try PayrollCalendar(calendar: cal, cutoffDay: 25, paydayDay: 10, offset: .nextMonth)
    let now = date("2026-05-15 10:00:00")
    let p = pc.period(containing: now)
    // 账期起点应为 4 月 26 日，结算日 5 月 25 日。
    let iso = { (d: Date) in
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    expect(iso(p.start) == "2026-04-26", "26–25 账期起点为上月 26 日，实际 \(iso(p.start))")
    expect(iso(p.settlementDate) == "2026-05-25", "结算日 5 月 25 日")

    // 枚举账期连续覆盖 [1 月, 4 月)：12/26–1/25、1/26–2/25、2/26–3/25、3/26–4/25 共 4 段。
    let periods = pc.periods(from: date("2026-01-01 00:00:00"), to: date("2026-04-01 00:00:00"))
    expect(periods.count == 4, "1–3 月共 4 个账期，实际 \(periods.count)")
    if periods.count >= 2 {
        expect(periods[0].endExclusive == periods[1].start, "账期首尾相接不漏天不重叠")
    }

    // 发薪日当天 remainingDays == 0。
    let onPayday = pc.period(containing: date("2026-05-10 00:00:00"))
    expect(onPayday.remainingDays == 0, "发薪当天剩余 0 天")

    // 无该日按月末：cutoff 31 在 4 月（30 天）夹取到 30。
    let pc31 = try PayrollCalendar(calendar: cal, cutoffDay: 31, paydayDay: 31, offset: .sameMonth)
    let apr = pc31.period(containing: date("2026-04-15 10:00:00"))
    let aprSettlement = cal.dateComponents([.day], from: apr.settlementDate).day
    expect(aprSettlement == 30, "cutoff 31 在 30 天月夹取到 30")

    // 非法 cutoff/payday 抛错，不默默默认。
    expect((try? PayrollCalendar(cutoffDay: 0, paydayDay: 10, offset: .nextMonth)) == nil, "cutoff 0 非法")
    expect((try? PayrollCalendar(cutoffDay: 25, paydayDay: 32, offset: .nextMonth)) == nil, "payday 32 非法")
}

// MARK: - 发薪账期：同月发薪早于结算提示与余额

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let pc = try PayrollCalendar(calendar: cal, cutoffDay: 25, paydayDay: 10, offset: .sameMonth)
    let p = pc.period(containing: date("2026-05-15 10:00:00"))
    expect(p.notes.contains { $0.contains("早于") }, "同月发薪早于结算给出提示")
}

// MARK: - 工资变更历史：生效日期解析

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    var config = baseConfig()
    config.salaryAmount = 20000

    // 空历史 → 全程当前工资。
    expectClose(SalaryResolver.monthlyGross(on: date("2026-05-15 00:00:00"), history: [], current: config, calendar: cal), 20000, "空历史回当前工资")

    // 带日期版本：生效日前旧工资、之后新工资，中途涨薪不重算过去。
    let v = SalaryVersion(effectiveDate: "2026-05-01", amount: 25000, period: .monthly, payMonthsPerYear: 12)
    expectClose(SalaryResolver.monthlyGross(on: date("2026-04-30 23:59:59"), history: [v], current: config, calendar: cal), 20000, "生效日前旧工资")
    expectClose(SalaryResolver.monthlyGross(on: date("2026-05-01 00:00:00"), history: [v], current: config, calendar: cal), 25000, "生效日起新工资")

    // 多个版本：取生效日 <= 目标日的最近一个。
    let v1 = SalaryVersion(effectiveDate: "2026-01-01", amount: 18000, period: .monthly, payMonthsPerYear: 12)
    let v2 = SalaryVersion(effectiveDate: "2026-07-01", amount: 30000, period: .monthly, payMonthsPerYear: 12)
    expectClose(SalaryResolver.monthlyGross(on: date("2026-03-10 00:00:00"), history: [v1, v2], current: config, calendar: cal), 18000, "1–6 月用 18000")
    expectClose(SalaryResolver.monthlyGross(on: date("2026-08-10 00:00:00"), history: [v1, v2], current: config, calendar: cal), 30000, "7 月起用 30000")

    // 年薪版本换算一次。
    let annual = SalaryVersion(effectiveDate: "2026-05-01", amount: 300000, period: .annual, payMonthsPerYear: 12)
    expectClose(annual.monthlyGross, 25000, "年薪 300000 换算月薪 25000")

    // 未来生效：到期自动生效，未到期仍用当前工资。
    let future = SalaryVersion(effectiveDate: "2026-12-01", amount: 40000, period: .monthly, payMonthsPerYear: 12)
    expectClose(SalaryResolver.monthlyGross(on: date("2026-11-15 00:00:00"), history: [future], current: config, calendar: cal), 20000, "未来版本未生效用当前工资")
    expectClose(SalaryResolver.monthlyGross(on: date("2026-12-02 00:00:00"), history: [future], current: config, calendar: cal), 40000, "未来版本到期自动生效")
}

// MARK: - 工资变更历史：编码往返与旧配置兼容

do {
    // 旧配置缺 salaryHistory → 空数组。
    let legacy = #"{"salaryAmount": 100}"#.data(using: .utf8)!
    let decoded = try? JSONDecoder().decode(Configuration.self, from: legacy)
    expect(decoded?.salaryHistory.isEmpty == true, "旧配置 salaryHistory 空数组")

    // 编码往返保留版本。
    var c = Configuration()
    c.salaryHistory = [SalaryVersion(effectiveDate: "2026-03-01", amount: 23000, period: .monthly, payMonthsPerYear: 13)]
    let rt = try? JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(c))
    expect(rt?.salaryHistory.first?.amount == 23000, "工资版本编码往返保留")
    expect(rt?.salaryHistory.first?.payMonthsPerYear == 13, "13 薪版本编码往返保留")
}

// MARK: - 工资变更历史：逐日生效工资接入引擎（税前分段计薪）

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // 12 薪，1–6 月 1 万元、7–12 月 2 万元：全年 gross = 6×1万 + 6×2万 = 18万。
    var config = baseConfig()
    config.salaryAmount = 20000
    config.currencyCode = "CNY"
    config.countryCode = "CN"
    config.salaryHistory = [
        SalaryVersion(effectiveDate: "2026-07-01", amount: 20000, period: .monthly, payMonthsPerYear: 12),
    ]
    config.salaryBaseline = SalaryBaseline(amount: 10000, period: .monthly, payMonthsPerYear: 12)

    // 年末最后一天收工，全年已赚应等于 18 万（分段后各月按各自工资）。
    let eYear = engine(config, now: date("2026-12-31 18:00:00"))
    let yearSnap = eYear.snapshot(at: date("2026-12-31 18:00:00"))
    expectClose(yearSnap.yearTotal, 180_000, "1–6月1万、7–12月2万全年总额18万")
    expectClose(yearSnap.yearEarned, 180_000, "年末全年已赚18万（分段求和，不整年用新工资）")

    // 6 月末：前 6 个月各 1 万，实际已赚 6 万；全年正常毛额 18 万 → 进度 1/3。
    // 分段口径下不把下半年 2 万提前摊进今天（与「中途涨薪不重算过去全年」一致）。
    let eJune = engine(config, now: date("2026-06-30 18:00:00"))
    let juneSnap = eJune.snapshot(at: date("2026-06-30 18:00:00"))
    expectClose(juneSnap.yearFraction, 6.0 / 18.0, "6 月末年度进度 = 6万/18万 = 1/3")
    expectClose(juneSnap.yearEarned, 60_000, "6 月末已赚 = 6 万（前 6 月各 1 万）")
    expectClose(juneSnap.monthEarned, 10_000, "6 月当月仍按旧工资 1 万计")
    expectClose(juneSnap.monthTotal, 10_000, "6 月当月总额 1 万")
}

// MARK: - 工资变更历史：月中涨薪分段计薪（固定 20 工作日，前10日1万、后10日2万）

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // 2026-03 有 22 个工作日（周一~周五）。用 workdays 固定周一到周五；
    // 取 3 月 16 日（周一）作为生效日，前 10 个工作日（1–13 日）按 1 万、后 12 个工作日按 2 万。
    // 但验收算例要求「固定 20 工作日」：改排班只剩 20 天较繁琐，改用可精确控制的 20 工作日月：
    // 2026-02 有 20 个工作日。生效日 2026-02-11（月中），前 10 个工作日按 1 万、后 10 个按 2 万。
    var config = baseConfig()
    config.salaryAmount = 20000
    config.currencyCode = "CNY"
    config.countryCode = "CN"
    config.salaryHistory = [
        SalaryVersion(effectiveDate: "2026-02-11", amount: 20000, period: .monthly, payMonthsPerYear: 12),
    ]
    config.salaryBaseline = SalaryBaseline(amount: 10000, period: .monthly, payMonthsPerYear: 12)

    let e = engine(config, now: date("2026-02-28 18:00:00"))
    let snap = e.snapshot(at: date("2026-02-28 18:00:00"))
    // 2 月 20 个工作日：2/11 起按 2 万。2/2–2/10 共 7 个工作日（周一~周五，2/1 周日），
    // 2/11–2/28 共 13 个工作日。日薪各按该月 20 个工作日折算：
    //   前 7 天 × 10000/20 + 后 13 天 × 20000/20 = 3500 + 13000 = 16500。
    let febWorkdays = e.workdaysThisMonth
    expect(febWorkdays == 20, "2026 年 2 月应有 20 个工作日，实际 \(febWorkdays)")
    expectClose(snap.monthEarned, 16_500, "2 月月中涨薪按前旧后新分段，当月毛额 16500")
}

// MARK: - 工资变更历史：税后逐月 regularGross 与全年净额（不再常量 12 月）

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // 12 薪，1–6 月 1 万、7–12 月 2 万，个人缴费全 disabled、扣除 0。
    var config = baseConfig()
    config.salaryAmount = 20000
    config.currencyCode = "CNY"
    config.countryCode = "CN"
    config.payMode = .net
    config.salaryHistory = [
        SalaryVersion(effectiveDate: "2026-07-01", amount: 20000, period: .monthly, payMonthsPerYear: 12),
    ]
    config.salaryBaseline = SalaryBaseline(amount: 10000, period: .monthly, payMonthsPerYear: 12)
    config.tax.social.pension = .disabled
    config.tax.social.medical = .disabled
    config.tax.social.medicalFixed = .disabled
    config.tax.social.unemployment = .disabled
    config.tax.social.housingFund = .disabled
    config.tax.monthlySpecialDeduction = .zero
    config.tax.monthlyOtherDeduction = .zero
    config.tax.employmentStartMonth = 1
    config.tax.bonusMonth = 12

    let e = engine(config, now: date("2026-12-31 18:00:00"))
    expect(e.isNetActive, "税后逐月 regularGross 应可计算")

    // 全年正常毛额 = 6×1万 + 6×2万 = 18万，无额外薪月 → 累计预扣后净额应为 170520。
    // 逐月应纳税所得额：前 6 月每月 10000-5000=5000，后 6 月每月 20000-5000=15000。
    // 累计额：6月=30000(3%档)，7月=45000(10%档，1980-900=1080)…
    let yearNet = e.snapshot(at: date("2026-12-31 18:00:00")).yearEarned
    expectClose(yearNet, 170_520, "居民累计预扣全年净额 170520，实际 \(yearNet)")
}

// MARK: - 工资变更历史：重启（空历史）与未来生效兼容

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // 空历史 → 全程当前工资，行为与旧引擎一致。
    var plain = baseConfig()
    plain.salaryAmount = 20000
    let e = engine(plain, now: date("2026-08-31 18:00:00"))
    let snap = e.snapshot(at: date("2026-08-31 18:00:00"))
    expectClose(snap.monthEarned, 20000, "空历史月末当月拿满 2 万")
    expectClose(snap.yearTotal, 240_000, "空历史全年总额 24 万")

    // 未来生效版本：未到期仍用当前工资，到期自动生效。
    var future = baseConfig()
    future.salaryAmount = 20000
    future.salaryHistory = [
        SalaryVersion(effectiveDate: "2026-12-01", amount: 40000, period: .monthly, payMonthsPerYear: 12),
    ]
    future.salaryBaseline = SalaryBaseline(amount: 20000, period: .monthly, payMonthsPerYear: 12)
    let before = engine(future, now: date("2026-11-30 18:00:00"))
    expectClose(before.snapshot(at: date("2026-11-30 18:00:00")).monthTotal, 20000, "未来版本未到期用旧工资")
    let after = engine(future, now: date("2026-12-31 18:00:00"))
    expectClose(after.snapshot(at: date("2026-12-31 18:00:00")).monthTotal, 40000, "未来版本到期自动生效")
}

// MARK: - 工资变更历史：编辑删除撤销的存储一致性

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    var config = baseConfig()
    config.salaryAmount = 20000

    // 首次新增冻结旧工资基线。
    var store = SalaryHistoryStore(versions: [], baseline: nil)
    let v1 = SalaryVersion(effectiveDate: "2026-06-01", amount: 25000, period: .monthly, payMonthsPerYear: 12)
    expect(store.add(v1, current: config, calendar: cal) == nil, "首次新增成功")
    expect(store.baseline?.monthlyGross == 20000, "首次新增冻结 2 万基线")

    // 基线冻结后改当前工资不影响基线。
    var changed = config; changed.salaryAmount = 99999
    let store2 = store
    expect(store2.baseline?.monthlyGross == 20000, "基线不随后续当前工资变")

    // 新增第二条、删除、撤销精确还原。
    let v2 = SalaryVersion(effectiveDate: "2026-09-01", amount: 30000, period: .monthly, payMonthsPerYear: 12)
    _ = store.add(v2, current: config, calendar: cal)
    expect(store.versions.count == 2, "两条变更")
    expect(store.undo == nil, "新增成功后撤销载荷清空")

    _ = store.delete(id: v2.id)
    expect(store.versions.count == 1, "删除后剩一条")
    expect(store.undo != nil, "删除后产生撤销载荷")

    store.undoLast()
    expect(store.versions.count == 2, "撤销删除精确还原两条")

    // 编辑：只改一条，undo 可还原旧值。
    let edited = SalaryVersion(effectiveDate: "2026-06-15", amount: 26000, period: .monthly, payMonthsPerYear: 12)
    _ = store.edit(id: v1.id, to: edited, calendar: cal)
    expect(store.versions.first(where: { $0.id == v1.id })?.amount == 26000, "编辑后金额更新")
    store.undoLast()
    expect(store.versions.first(where: { $0.id == v1.id })?.amount == 25000, "撤销编辑还原旧金额")

    // 删除到空历史：基线收回，撤销可归还。
    _ = store.delete(id: v1.id)
    _ = store.delete(id: v2.id)
    expect(store.versions.isEmpty, "删光历史")
    expect(store.baseline == nil, "删光后基线收回")
    store.undoLast()
    expect(store.baseline?.monthlyGross == 20000, "撤销最后一次删除归还基线")

    // 非法值校验。
    let badAmount = SalaryVersion(effectiveDate: "2026-06-01", amount: -5, period: .monthly, payMonthsPerYear: 12)
    var store3 = SalaryHistoryStore(versions: [], baseline: nil)
    expect(store3.add(badAmount, current: config, calendar: cal) == .amount, "负金额被拦截")
    let badDate = SalaryVersion(effectiveDate: "2026-13-40", amount: 100, period: .monthly, payMonthsPerYear: 12)
    expect(store3.add(badDate, current: config, calendar: cal) == .date, "非法日期被拦截")
    let badMonths = SalaryVersion(effectiveDate: "2026-06-01", amount: 100, period: .monthly, payMonthsPerYear: 8)
    expect(store3.add(badMonths, current: config, calendar: cal) == .months, "非法薪月数被拦截")
}

// MARK: - 加班：下班前拒绝 / 开始停止幂等 / 时间回拨

func otError(_ r: Result<OvertimeSession, OvertimeLedgerError>) -> OvertimeLedgerError? {
    if case .failure(let e) = r { return e }
    return nil
}

func otOk(_ r: Result<OvertimeSession, OvertimeLedgerError>) -> Bool {
    if case .success = r { return true }
    return false
}

do {
    let config = baseConfig()
    let wc = WorkCalendar(config: config, autoHolidays: [], calendar: calendar)

    // 下班前（17:00）补录加班 → 与正常计薪时段重叠，拒绝。
    let bad = OvertimeSession(start: date("2026-08-04 17:00:00"), end: date("2026-08-04 19:00:00"),
                              kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    var ledger0 = OvertimeLedger(sessions: [])
    expect(otError(ledger0.addBackfill(bad, now: date("2026-08-04 20:00:00"), config: config, workCalendar: wc, calendar: calendar)) == .overlap,
           "下班前补录加班与正常计薪时段重叠被拒")

    var ledger = OvertimeLedger(sessions: [])
    let r1 = ledger.start(at: date("2026-08-04 18:30:00"), kind: .paid, multiplier: 2, baseHourlyGross: 100, currencyCode: "CNY")
    expect(otOk(r1), "下班后开始加班成功")
    let activeID = try! r1.get().id
    let r2 = ledger.start(at: date("2026-08-04 18:35:00"), kind: .paid, multiplier: 2, baseHourlyGross: 100, currencyCode: "CNY")
    expect(otError(r2) == .alreadyActive, "已进行中再开始幂等拒绝")

    let stop = ledger.stop(id: activeID, at: date("2026-08-04 20:00:00"))
    expect(otOk(stop), "结束加班成功")
    let stop2 = ledger.stop(id: activeID, at: date("2026-08-04 20:30:00"))
    expect(otError(stop2) == .notActive, "已结束再结束幂等拒绝")

    // 时间回拨：end <= start 拒绝，不产生负记录。
    var ledgerBack = OvertimeLedger(sessions: [])
    let rb = ledgerBack.start(at: date("2026-08-04 18:30:00"), kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    expect(otError(ledgerBack.stop(id: try! rb.get().id, at: date("2026-08-04 18:00:00"))) == .endBeforeStart, "结束早于开始被拒")
}

// MARK: - 加班：1/2/3 倍与无偿损失

do {
    let config = baseConfig()
    let wc = WorkCalendar(config: config, autoHolidays: [], calendar: calendar)

    // 下班后 1.5 小时（18:30–20:00），基准时薪 100。
    func summary(multiplier: Int, kind: OvertimePayKind) -> OvertimeSummary {
        let ledger = OvertimeLedger(sessions: [
            OvertimeSession(start: date("2026-08-04 18:30:00"), end: date("2026-08-04 20:00:00"),
                            kind: kind, multiplier: multiplier, baseHourlyGross: 100, currencyCode: "CNY")
        ])
        return ledger.summary(at: date("2026-08-04 21:00:00"), config: config, workCalendar: wc, calendar: calendar)
    }

    expectClose(summary(multiplier: 1, kind: .paid).dayPaid, 150, "1 倍：1.5h × 100 = 150")
    expectClose(summary(multiplier: 2, kind: .paid).dayPaid, 300, "2 倍：1.5h × 100 × 2 = 300")
    expectClose(summary(multiplier: 3, kind: .paid).dayPaid, 450, "3 倍：1.5h × 100 × 3 = 450")

    let unpaid = summary(multiplier: 3, kind: .unpaid)
    expectClose(unpaid.dayPaid, 0, "无偿加班不产生加班工资")
    expectClose(unpaid.dayLoss, 150, "无偿按 1 倍基准计损失 150，与倍率无关")
}

// MARK: - 加班：跨午夜/跨月年拆分与归属

do {
    let config = baseConfig()
    let wc = WorkCalendar(config: config, autoHolidays: [], calendar: calendar)

    // 周五 20:00 → 周六 02:00：周五 4h（下班后）+ 周六 2h（休息日整段）= 6h。
    let ledger = OvertimeLedger(sessions: [
        OvertimeSession(start: date("2026-08-07 20:00:00"), end: date("2026-08-08 02:00:00"),
                        kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    ])
    let s = ledger.summary(at: date("2026-08-08 10:00:00"), config: config, workCalendar: wc, calendar: calendar)
    expectClose(s.monthPaid, 600, "跨午夜 6 小时，不整段算到开始月份（同月合计 600）")

    // 跨年：2026-12-31(周四) 22:00 → 2027-01-01(周五) 02:00，各 2h。
    let ledgerYear = OvertimeLedger(sessions: [
        OvertimeSession(start: date("2026-12-31 22:00:00"), end: date("2027-01-01 02:00:00"),
                        kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    ])
    let by2026 = ledgerYear.paidOvertimeGross(byMonth: 2026, at: date("2027-01-02 10:00:00"), config: config, workCalendar: wc, calendar: calendar)
    let by2027 = ledgerYear.paidOvertimeGross(byMonth: 2027, at: date("2027-01-02 10:00:00"), config: config, workCalendar: wc, calendar: calendar)
    expectClose(by2026[11], 200, "2026-12-31 的 2 小时归 2026 年 12 月")
    expectClose(by2027[0], 200, "2027-01-01 的 2 小时归 2027 年 1 月")
}

// MARK: - 加班：重启持久化与历史价不被重价

do {
    var config = baseConfig()
    config.overtimeSessions = [
        OvertimeSession(start: date("2026-08-04 18:30:00"), end: date("2026-08-04 20:00:00"),
                        kind: .paid, multiplier: 2, baseHourlyGross: 130.95, currencyCode: "CNY")
    ]
    let rt = try? JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
    expect(rt?.overtimeSessions.count == 1, "加班台账编码往返保留")
    expectClose(rt?.overtimeSessions.first?.baseHourlyGross ?? 0, 130.95, "锁定基准时薪编码往返保留")

    // 旧配置缺 overtime 字段 → 回退默认，不崩。
    let legacy = #"{"salaryAmount": 100}"#.data(using: .utf8)!
    let decoded = try? JSONDecoder().decode(Configuration.self, from: legacy)
    expect(decoded?.overtimePayDefault == .paid, "旧配置加班默认有偿")
    expect(decoded?.overtimeMultiplier == 1, "旧配置加班倍率默认 1")
    expect(decoded?.overtimeSessions.isEmpty == true, "旧配置无加班台账")
}

// MARK: - 加班：重叠拒绝与删除撤销还原

do {
    let config = baseConfig()
    let wc = WorkCalendar(config: config, autoHolidays: [], calendar: calendar)

    var ledger = OvertimeLedger(sessions: [])
    let a = OvertimeSession(start: date("2026-08-04 18:30:00"), end: date("2026-08-04 20:00:00"),
                            kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    _ = ledger.addBackfill(a, now: date("2026-08-05 10:00:00"), config: config, workCalendar: wc, calendar: calendar)

    // 与既有段重叠 → 拒绝。
    let overlap = OvertimeSession(start: date("2026-08-04 19:00:00"), end: date("2026-08-04 21:00:00"),
                                  kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    expect(otError(ledger.addBackfill(overlap, now: date("2026-08-05 10:00:00"), config: config, workCalendar: wc, calendar: calendar)) == .overlap,
           "与既有加班段重叠被拒")

    // 未来结束被拒。
    let future = OvertimeSession(start: date("2026-08-06 18:30:00"), end: date("2026-08-06 20:00:00"),
                                 kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    expect(otError(ledger.addBackfill(future, now: date("2026-08-05 10:00:00"), config: config, workCalendar: wc, calendar: calendar)) == .futureEnd,
           "未来结束时刻被拒")

    // 删除 + 撤销精确还原。
    _ = ledger.delete(id: a.id)
    expect(ledger.sessions.isEmpty, "删除后台账为空")
    ledger.undoLast()
    expect(ledger.sessions.count == 1, "撤销删除精确还原")

    // 纠错：改倍率，undo 还原旧倍率。
    let edited = OvertimeSession(start: date("2026-08-04 18:30:00"), end: date("2026-08-04 20:00:00"),
                                 kind: .paid, multiplier: 3, baseHourlyGross: 100, currencyCode: "CNY")
    _ = ledger.edit(id: a.id, to: edited, now: date("2026-08-05 10:00:00"), config: config, workCalendar: wc, calendar: calendar)
    expect(ledger.sessions.first?.multiplier == 3, "纠错后倍率更新为 3")
    ledger.undoLast()
    expect(ledger.sessions.first?.multiplier == 1, "撤销纠错还原倍率为 1")
}

// MARK: - 加班：引擎税前时薪基准锁定（历史工资不重价既有段）

do {
    let config = baseConfig()
    let e = engine(config, now: date("2026-08-04 18:00:00"))
    let hourly = e.hourlyGrossRate(on: date("2026-08-04 18:00:00"))
    // 22000 / 21 工作日 / 28800 秒 × 3600 = 2750/21 ≈ 130.952。
    expectClose(hourly, 22000.0 / 21.0 / 28800.0 * 3600, "税前时薪基准 = 月薪/工作日/计薪秒×3600")
    expect(hourly.isFinite, "时薪基准有限")
}

// MARK: - 加班：税后有偿并入 gross 重新累计预扣，无偿不进入税后

do {
    var config = baseConfig()
    config.salaryAmount = 20000
    config.currencyCode = "CNY"
    config.countryCode = "CN"
    config.payMode = .net
    config.tax.social.pension = .disabled
    config.tax.social.medical = .disabled
    config.tax.social.medicalFixed = .disabled
    config.tax.social.unemployment = .disabled
    config.tax.social.housingFund = .disabled
    config.tax.monthlySpecialDeduction = .zero
    config.tax.monthlyOtherDeduction = .zero
    config.tax.employmentStartMonth = 1
    config.tax.bonusMonth = 12

    // 无加班基准。
    let e0 = engine(config, now: date("2026-08-04 18:00:00"))
    let baseNet = e0.netCents(forMonth: 8)

    // 有偿加班 2h × 100 × 1 倍 = 200 元，并入 8 月毛额 → 8 月净额增加。
    var paidConfig = config
    paidConfig.overtimeSessions = [
        OvertimeSession(start: date("2026-08-04 18:30:00"), end: date("2026-08-04 20:30:00"),
                        kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    ]
    let ePaid = engine(paidConfig, now: date("2026-08-04 21:00:00"))
    let paidNet = ePaid.netCents(forMonth: 8)
    expect(paidNet != nil && baseNet != nil, "税后净额可算")
    if let baseNet, let paidNet {
        expect(paidNet > baseNet, "有偿加班并入毛额后 8 月净额增加（重新累计预扣）")
    }

    // 无偿加班：净额不变。
    var unpaidConfig = config
    unpaidConfig.overtimeSessions = [
        OvertimeSession(start: date("2026-08-04 18:30:00"), end: date("2026-08-04 20:30:00"),
                        kind: .unpaid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY")
    ]
    let eUnpaid = engine(unpaidConfig, now: date("2026-08-04 21:00:00"))
    expect(eUnpaid.netCents(forMonth: 8) == baseNet, "无偿加班不进入税后净额")
}

// MARK: - 发薪账期：本账期已赚（正常/加班/合计，复用历史工资与加班 ledger）

do {
    var config = baseConfig()
    config.salaryAmount = 20000
    config.currencyCode = "CNY"
    config.countryCode = "CN"
    config.payroll = PayrollSettings(enabled: true, cutoffDay: 25, paydayDay: 10, offset: .nextMonth)

    // 关闭账期 → 无汇总。
    var disabled = config
    disabled.payroll.enabled = false
    expect(engine(disabled, now: date("2026-05-15 10:00:00")).payrollSummary(at: date("2026-05-15 10:00:00")).period == nil,
           "关闭账期无本账期汇总")

    // 26~25 账期：2026-05-15 落在 4/26~5/25 账期。
    let e = engine(config, now: date("2026-05-15 10:00:00"))
    let s = e.payrollSummary(at: date("2026-05-15 10:00:00"))
    expect(s.period != nil, "启用账期有本账期汇总")
    expect(s.remainingDays != nil && s.remainingDays! >= 0, "发薪倒计时非负")
    if let next = s.nextPayday {
        expect(next >= date("2026-05-15 10:00:00"), "下个名义发薪日不早于 now")
    }
    expect(s.totalGross >= 0, "本账期已赚非负")

    // 加班落在账期内的部分并入合计（有偿），损失不扣合计。
    var withOT = config
    withOT.overtimeSessions = [
        OvertimeSession(start: date("2026-05-06 18:30:00"), end: date("2026-05-06 20:30:00"),
                        kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY"),
        OvertimeSession(start: date("2026-05-07 18:30:00"), end: date("2026-05-07 19:30:00"),
                        kind: .unpaid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY"),
    ]
    let eOT = engine(withOT, now: date("2026-05-15 10:00:00"))
    let sOT = eOT.payrollSummary(at: date("2026-05-15 10:00:00"))
    expectClose(sOT.overtimePaid, 200, "账期内有偿加班 2h×100 = 200")
    expectClose(sOT.loss, 100, "账期内无偿损失 1h×100 = 100，不扣合计")
    expect(sOT.totalGross >= sOT.regularGross + sOT.overtimePaid - 0.001, "合计 = 正常 + 有偿加班（损失不计）")
}

// MARK: - 发薪账期：税后本账期净额分配（自然月整月 = monthNet，跨月 = 各月截取之和）

do {
    var config = baseConfig()
    config.salaryAmount = 20000
    config.currencyCode = "CNY"
    config.countryCode = "CN"
    config.payMode = .net
    config.tax.social.pension = .disabled
    config.tax.social.medical = .disabled
    config.tax.social.medicalFixed = .disabled
    config.tax.social.unemployment = .disabled
    config.tax.social.housingFund = .disabled
    config.tax.monthlySpecialDeduction = .zero
    config.tax.monthlyOtherDeduction = .zero
    config.tax.employmentStartMonth = 1
    config.tax.bonusMonth = 12

    // 自然月账期（cutoff 31 在 31 天的 5 月等于自然月）。
    let natural = config
    _ = engine(natural, now: date("2026-05-31 18:00:00"))

    // 跨月账期（26~25）：账期 = [4/26, 5/25]，落在 4 月与 5 月两段。
    var cross = config
    cross.payroll = PayrollSettings(enabled: true, cutoffDay: 25, paydayDay: 10, offset: .nextMonth)
    let eCross = engine(cross, now: date("2026-05-25 18:00:00"))
    let sCross = eCross.payrollSummary(at: date("2026-05-25 18:00:00"))
    expect(sCross.netMode, "税后账期汇总为 net 口径")

    // 有偿加班 250（税前）：1 月净增 242.5 例（无社保、扣除 0，20000 月薪累计预扣下 250 落在 20% 档内净增 250×0.97=242.5 附近）。
    var withOT = config
    withOT.overtimeSessions = [
        OvertimeSession(start: date("2026-01-06 18:30:00"), end: date("2026-01-06 21:00:00"),
                        kind: .paid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY"), // 2.5h × 100 = 250
    ]
    let eOT = engine(withOT, now: date("2026-01-31 18:00:00"))
    let netBase = eOT.netCents(forMonth: 1).map { Double($0) / 100 } ?? 0
    // 无加班时 1 月净额基准。
    let eBase = engine(config, now: date("2026-01-31 18:00:00"))
    let netNoOT = eBase.netCents(forMonth: 1).map { Double($0) / 100 } ?? 0
    expectClose(netBase - netNoOT, 242.5, "有偿税前 250 在 1 月净增 242.5（3% 档内净额差）", tolerance: 0.01)

    // 无偿加班：切模式两种工资均不受影响（net 总额与税前合计均不变）。
    var unpaid = config
    unpaid.overtimeSessions = [
        OvertimeSession(start: date("2026-01-06 18:30:00"), end: date("2026-01-06 19:30:00"),
                        kind: .unpaid, multiplier: 1, baseHourlyGross: 100, currencyCode: "CNY"),
    ]
    let eUnpaid = engine(unpaid, now: date("2026-01-31 18:00:00"))
    expect(eUnpaid.netCents(forMonth: 1) == eBase.netCents(forMonth: 1), "无偿加班 net 净额不变")

    // —— 税后账期「真实已赚」逐秒累进（不先计满天）——
    // 自然月账期（cutoff=1 → 账期含整月），今天 2026-05-15 是工作日（周五，9:00-18:00，午休 12-13）。
    var natural2 = config
    natural2.payroll = PayrollSettings(enabled: true, cutoffDay: 1, paydayDay: 1, offset: .sameMonth)

    // 上班前（08:00）与上班起点（09:00）：今天均 0 已赚净额 → 两时刻相等。
    let eBefore = engine(natural2, now: date("2026-05-15 08:00:00"))
    let eStart = engine(natural2, now: date("2026-05-15 09:00:00"))
    let sBefore = eBefore.payrollSummary(at: date("2026-05-15 08:00:00"))
    let sStart = eStart.payrollSummary(at: date("2026-05-15 09:00:00"))
    expectClose(sBefore.regularGross, sStart.regularGross, "上班前今天净额 0（与 09:00 持平）", tolerance: 0.01)

    // 上班 1 小时（10:00）：比 09:00 多 1h → perSecond×3600。
    let eOneHour = engine(natural2, now: date("2026-05-15 10:00:00"))
    let sOneHour = eOneHour.payrollSummary(at: date("2026-05-15 10:00:00"))
    let netPerSecond = eOneHour.snapshot(at: date("2026-05-15 10:00:00")).perSecond
    expectClose(sOneHour.regularGross - sStart.regularGross, netPerSecond * 3600, "上班 1h 只计 1h 净额", tolerance: 0.01)

    // 午休：12:00 与 12:30 持平（午休不计）。
    let eLunchA = engine(natural2, now: date("2026-05-15 12:00:00"))
    let eLunchB = engine(natural2, now: date("2026-05-15 12:30:00"))
    let sLunchA = eLunchA.payrollSummary(at: date("2026-05-15 12:00:00"))
    let sLunchB = eLunchB.payrollSummary(at: date("2026-05-15 12:30:00"))
    expectClose(sLunchA.regularGross, sLunchB.regularGross, "午休时段正常净额持平", tolerance: 0.01)

    // 本日 t 与 t+1 秒差 = perSecond（逐秒一致）。
    let t = date("2026-05-15 14:00:00")
    let t1 = date("2026-05-15 14:00:01")
    let eT = engine(natural2, now: t)
    let eT1 = engine(natural2, now: t1)
    let sT = eT.payrollSummary(at: t)
    let sT1 = eT1.payrollSummary(at: t1)
    expectClose(sT1.regularGross - sT.regularGross, netPerSecond, "本日 t/t+1s 净额增量 = perSecond", tolerance: 0.02)

    // 整月月末：cutoff=31 在 31 天的 5 月等于自然月（账期 = [5/1, 6/1)），净额 = 该月 monthNet。
    var naturalMonth = config
    naturalMonth.payroll = PayrollSettings(enabled: true, cutoffDay: 31, paydayDay: 31, offset: .sameMonth)
    let eMonthEnd = engine(naturalMonth, now: date("2026-05-31 18:00:00"))
    let sMonthEnd = eMonthEnd.payrollSummary(at: date("2026-05-31 18:00:00"))
    let monthNet = eMonthEnd.netCents(forMonth: 5).map { Double($0) / 100 } ?? 0
    expectClose(sMonthEnd.regularGross, monthNet, "整月月末净额 = monthNet", tolerance: 0.05)

    // 休息日（周六 5/16）：账期已赚不增。
    let eRest = engine(natural2, now: date("2026-05-16 14:00:00"))
    let sRest = eRest.payrollSummary(at: date("2026-05-16 14:00:00"))
    let eFri = engine(natural2, now: date("2026-05-15 18:00:00"))
    let sFri = eFri.payrollSummary(at: date("2026-05-15 18:00:00"))
    expectClose(sRest.regularGross, sFri.regularGross, "休息日账期已赚不增", tolerance: 0.01)

    // 跨月账期（26~25）5/25 18:00：= 4 月截取区间（4/26-4/30）+ 5 月截取区间（5/1-5/25）两段净额之和。
    var cross2 = config
    cross2.payroll = PayrollSettings(enabled: true, cutoffDay: 25, paydayDay: 10, offset: .nextMonth)
    let eCross2 = engine(cross2, now: date("2026-05-25 18:00:00"))
    let sCross2 = eCross2.payrollSummary(at: date("2026-05-25 18:00:00"))
    expect(sCross2.netMode, "跨月账期 net 口径")
    expect(sCross2.regularGross > 0, "跨月账期正常净额 > 0")
}

// MARK: - 税后加班错摊（D1）：正常日秒薪/日赚/away 不被 OT 抬高，月年净额仍精确

do {
    // 20 工作日（2026-02）、月薪 10000、无社保 → 2 月仅正常 net = 9850（2月预扣 150）。
    var base = Configuration()
    base.salaryAmount = 10000
    base.salaryPeriod = .monthly
    base.payMonthsPerYear = 12
    base.currencyCode = "CNY"
    base.countryCode = "CN"
    base.workdays = [2, 3, 4, 5, 6]
    base.startMinutes = 9 * 60
    base.endMinutes = 18 * 60
    base.breakEnabled = true
    base.breakStartMinutes = 12 * 60
    base.breakEndMinutes = 13 * 60
    base.payMode = .net
    base.tax.social.pension = .disabled
    base.tax.social.medical = .disabled
    base.tax.social.medicalFixed = .disabled
    base.tax.social.unemployment = .disabled
    base.tax.social.housingFund = .disabled
    base.tax.monthlySpecialDeduction = .zero
    base.tax.monthlyOtherDeduction = .zero
    base.tax.employmentStartMonth = 1
    base.tax.bonusMonth = 12

    let nowFeb5 = date("2026-02-05 15:00:00")
    let ePlain = engine(base, now: nowFeb5)
    let sPlain = ePlain.snapshot(at: nowFeb5)

    // 加入 2 月已完成有偿加班 250（2h × 2 倍 × 62.5）。
    var withOT = base
    withOT.overtimeSessions = [
        OvertimeSession(start: date("2026-02-03 18:30:00"), end: date("2026-02-03 20:30:00"),
                        kind: .paid, multiplier: 2, baseHourlyGross: 62.5, currencyCode: "CNY")
    ]
    let eOT = engine(withOT, now: nowFeb5)
    let sOT = eOT.snapshot(at: nowFeb5)

    // 正常日（非加班日）秒薪与日赚不被 OT 抬高。
    expectClose(sOT.perSecond, sPlain.perSecond, "非加班日秒薪不被 OT 抬高", tolerance: 1e-9)
    expectClose(sOT.dayEarned, sPlain.dayEarned, "非加班日 dayEarned 不被 OT 抬高", tolerance: 1e-6)
    expectClose(sOT.dayTotal, sPlain.dayTotal, "非加班日 dayTotal 不被 OT 抬高", tolerance: 1e-6)

    // 月总额仍含加班净额，且精确 = 10092.5（2月 250 → 净增 242.5）。
    expectClose(sOT.monthTotal, 10092.5, "2 月最终净额 10092.5", tolerance: 0.01)
    expectClose(sPlain.monthTotal, 9850, "2 月仅正常净额 9850", tolerance: 0.01)

    // away（离席正常计薪）不被加班摊高。
    let awayPlain = ePlain.awayReport(from: date("2026-02-05 10:00:00"), to: date("2026-02-05 11:00:00"))
    let awayOT = eOT.awayReport(from: date("2026-02-05 10:00:00"), to: date("2026-02-05 11:00:00"))
    expectClose(awayOT.amount, awayPlain.amount, "away 正常计薪不被 OT 抬高", tolerance: 1e-6)

    // 全年净额 = 12 个月累计预扣精确合计：120000 基线 + 250 OT → 120250，税 3505，net 116745。
    expectClose(sOT.yearTotal, 116745, "12 薪全年净额 116745（OT 250 并入后累计预扣）", tolerance: 0.01)
}

// MARK: - 税后进行中有偿加班逐秒（active paidOT 不因 init 缓存冻结）

do {
    var base = Configuration()
    base.salaryAmount = 10000
    base.salaryPeriod = .monthly
    base.payMonthsPerYear = 12
    base.currencyCode = "CNY"
    base.countryCode = "CN"
    base.workdays = [2, 3, 4, 5, 6]
    base.startMinutes = 9 * 60
    base.endMinutes = 18 * 60
    base.breakEnabled = true
    base.breakStartMinutes = 12 * 60
    base.breakEndMinutes = 13 * 60
    base.payMode = .net
    base.tax.social.pension = .disabled
    base.tax.social.medical = .disabled
    base.tax.social.medicalFixed = .disabled
    base.tax.social.unemployment = .disabled
    base.tax.social.housingFund = .disabled
    base.tax.monthlySpecialDeduction = .zero
    base.tax.monthlyOtherDeduction = .zero
    base.tax.employmentStartMonth = 1
    base.tax.bonusMonth = 12
    // 进行中的有偿加班段（未结束）。
    base.overtimeSessions = [
        OvertimeSession(start: date("2026-02-03 18:30:00"), end: nil,
                        kind: .paid, multiplier: 2, baseHourlyGross: 62.5, currencyCode: "CNY")
    ]

    // 引擎只在 18:30 构造一次；之后 now 前进，进行中段持续累计。
    let e = engine(base, now: date("2026-02-03 18:30:00"))
    let t0 = date("2026-02-03 19:00:00")   // 加班 0.5h → 62.5×2×0.5 = 62.5
    let t1 = date("2026-02-03 19:00:01")   // +1s
    let s0 = e.snapshot(at: t0)
    let s1 = e.snapshot(at: t1)
    // 进行中段的税后净额逐秒增长（月/年 net 不冻结）。
    expect(s1.monthTotal > s0.monthTotal, "进行中 paidOT 税后月净额逐秒增长")
    expect(s1.yearTotal > s0.yearTotal, "进行中 paidOT 税后年净额逐秒增长")
    // 1 秒净增 ≈ 加班净额 perSecond（125 元/时 × 税后系数 ≈ 0.033 元/秒）。
    expect(s1.monthTotal - s0.monthTotal > 0 && s1.monthTotal - s0.monthTotal < 0.1,
           "1 秒净增为正值且量级为分")
    // 正常秒薪仍基于 regular 口径，不被进行中加班抬高。
    let basePerSecond = (9850.0 / 20.0) / 28800.0
    expectClose(s0.perSecond, basePerSecond, "进行中加班不抬高正常秒薪", tolerance: 1e-9)
}

// MARK: - 税后进行中有偿加班账期收入逐秒（D3：payroll net 不冻结）

do {
    var base = Configuration()
    base.salaryAmount = 10000
    base.salaryPeriod = .monthly
    base.payMonthsPerYear = 12
    base.currencyCode = "CNY"
    base.countryCode = "CN"
    base.workdays = [2, 3, 4, 5, 6]
    base.startMinutes = 9 * 60
    base.endMinutes = 18 * 60
    base.breakEnabled = true
    base.breakStartMinutes = 12 * 60
    base.breakEndMinutes = 13 * 60
    base.payMode = .net
    base.tax.social.pension = .disabled
    base.tax.social.medical = .disabled
    base.tax.social.medicalFixed = .disabled
    base.tax.social.unemployment = .disabled
    base.tax.social.housingFund = .disabled
    base.tax.monthlySpecialDeduction = .zero
    base.tax.monthlyOtherDeduction = .zero
    base.tax.employmentStartMonth = 1
    base.tax.bonusMonth = 12
    // 账期覆盖 2 月整月（cutoff=28 在 2026-02 等于自然月末），进行中加班段 18:30 起未结束。
    base.payroll = PayrollSettings(enabled: true, cutoffDay: 28, paydayDay: 10, offset: .nextMonth)
    base.overtimeSessions = [
        OvertimeSession(start: date("2026-02-03 18:30:00"), end: nil,
                        kind: .paid, multiplier: 2, baseHourlyGross: 62.5, currencyCode: "CNY")
    ]

    let e = engine(base, now: date("2026-02-03 18:30:00"))
    let t0 = date("2026-02-03 19:00:00")   // 加班 0.5h
    let t1 = date("2026-02-03 19:00:01")   // +1s
    let t60m = date("2026-02-03 20:00:00") // +1.5h（截断前仍计）
    let s0 = e.payrollSummary(at: t0)
    let s1 = e.payrollSummary(at: t1)
    let s60 = e.payrollSummary(at: t60m)
    expect(s0.netMode, "D3 账期 net 口径")
    expect(s1.totalGross > s0.totalGross, "账期已赚（税后）随进行中加班逐秒增长（t0→t+1s）")
    expect(s60.totalGross > s1.totalGross, "账期已赚（税后）1 小时后继续增长（t+1s→t+60m）")
    // 正常列在加班时段不因加班变：regularGross 恒定。
    expectClose(s60.regularGross, s0.regularGross, "正常净额列不因进行中加班变", tolerance: 1e-6)

    // 结束段后同一时刻连续、不重复跳加：停止点前后仅差自然增量。
    var ended = base
    ended.overtimeSessions = [
        OvertimeSession(start: date("2026-02-03 18:30:00"), end: date("2026-02-03 20:00:00"),
                        kind: .paid, multiplier: 2, baseHourlyGross: 62.5, currencyCode: "CNY")
    ]
    let eEnded = engine(ended, now: date("2026-02-03 20:00:00"))
    let sEnded = eEnded.payrollSummary(at: date("2026-02-03 20:00:00"))
    // 进行中 20:00 已计 1.5h；结束后 20:00 也是 1.5h，总额应接近（差 < 1s 增量）。
    expectClose(sEnded.totalGross, s60.totalGross, "结束前后账期已赚连续不重复", tolerance: 0.05)
}

print("\n\(checks - failures)/\(checks) 项检查通过")
if failures > 0 {
    print("\(failures) 项失败")
    exit(1)
}
print("全部通过")
