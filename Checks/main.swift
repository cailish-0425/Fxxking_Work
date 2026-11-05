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

// MARK: - 功德累积与等级

do {
    // 1 计薪秒 = 1 功德。
    expectClose(MeritBalance.earned(fromPaidSeconds: 1800), 1800, "计薪 1800 秒应当得 1800 功德")

    var balance = MeritBalance()
    expectClose(balance.total, 0, "初始功德为 0")
    expect(balance.rank == .novice, "0 功德应当是沙弥")

    balance.earn(fromPaidSeconds: 1800)
    expectClose(balance.total, 1800, "累积一次后功德应当为 1800")

    // 负的计薪秒数（时间回拨）不该倒扣功德。
    balance.earn(fromPaidSeconds: -600)
    expectClose(balance.total, 1800, "负的计薪秒数不应减少功德")
}

do {
    // 等级边界：沙弥 0–9999 / 罗汉 10000–99999 / 扫地僧 ≥100000。
    expect(MeritRank.rank(totalMerit: 0) == .novice, "0 是沙弥")
    expect(MeritRank.rank(totalMerit: 9999) == .novice, "9999 仍是沙弥")
    expect(MeritRank.rank(totalMerit: 10000) == .arhat, "10000 升罗汉")
    expect(MeritRank.rank(totalMerit: 99999) == .arhat, "99999 仍是罗汉")
    expect(MeritRank.rank(totalMerit: 100000) == .sweepingMonk, "100000 升扫地僧")

    // 阈值切换点前后各一侧。
    expect(MeritRank.rank(totalMerit: 9999.9) == .novice, "9999.9 仍是沙弥")
    expect(MeritRank.rank(totalMerit: 99999.9) == .arhat, "99999.9 仍是罗汉")

    // 负值回落到最低档，不越界。
    expect(MeritRank.rank(totalMerit: -1) == .novice, "负功德按沙弥处理")

    // 等级单调递增，阈值按 沙弥 < 罗汉 < 扫地僧 排列。
    let thresholds = MeritRank.allCases.map(\.threshold)
    expect(thresholds == thresholds.sorted(), "等级阈值应当从小到大排列")

    // 每个阈值边界上的功德恰好归入对应的等级。
    for rank in MeritRank.allCases {
        expect(MeritRank.rank(totalMerit: rank.threshold) == rank, "阈值 \(rank.threshold) 恰好达到 \(rank.rawValue)")
    }

    // 累积后的余额等级要跟着变。
    var b = MeritBalance()
    b.earn(fromPaidSeconds: 10000)
    expect(b.rank == .arhat, "累积到 10000 功德应当是罗汉")
    b.earn(fromPaidSeconds: 90000)
    expect(b.rank == .sweepingMonk, "累积到 100000 功德应当是扫地僧")
}

print("\n\(checks - failures)/\(checks) 项检查通过")
if failures > 0 {
    print("\(failures) 项失败")
    exit(1)
}
print("全部通过")
