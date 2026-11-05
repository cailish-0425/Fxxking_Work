/// github.com/wrfly/holidays 的 CSV 数据集，225 个国家 / 地区、2024–2027 年，每年一个文件。
///
/// 一行长这样：
/// `2026-02-20,Friday,Spring Festival Holiday,National Holiday,Compensated by Sat Feb 14`
///
/// 除了假期本身，`comments` 里的 "Compensated by …" 还给出了调休上班日，
/// 中国、俄罗斯、越南这些会挪工作日的国家因此不必再手工录入。
import Foundation

enum GitHubHolidaysSource {
    static let attribution = "github.com/wrfly/holidays"

    /// 数据集目前的覆盖范围。请求超出这个范围的年份会 404，调用方按"这一年没有数据"处理即可。
    static let availableYears = 2024...2027

    static func fileURL(countryCode: String, year: Int) -> URL? {
        let code = countryCode.uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return URL(string: "https://raw.githubusercontent.com/wrfly/holidays/refs/heads/main/\(code)/\(year).csv")
    }

    // MARK: - 假期类型

    /// 一条记录对谁生效。数据集里 `type` 共有十种取值，另外还有空值。
    enum Scope {
        /// 全国放假。
        case national
        /// 只有部分地区或只有公务员放假，跟着"包含地方性假日"开关走。
        case partial
        /// 数据集明确标注了不放假，任何情况下都不算。
        case excluded
    }

    /// 空 `type` 占了两千多行、涉及 35 个国家（伊朗、波兰、芬兰、希腊……），
    /// 而那些行写的是 New Year's Day、Christmas Day 这类正经法定假日。
    /// 所以未知和空值一律按全国性假日处理，否则这些国家会一天假都没有。
    static func scope(forType type: String) -> Scope {
        switch type.trimmingCharacters(in: .whitespaces).lowercased() {
        case "not a public holiday":
            return .excluded
        case "regional holiday", "government holiday":
            return .partial
        default:
            return .national
        }
    }

    // MARK: - 解析

    struct Parsed: Equatable {
        var holidays: [PublicHoliday] = []
        /// 被挪成上班日的周末，"yyyy-MM-dd"。
        var makeupWorkdays: Set<String> = []
    }

    static func parse(csv text: String, includeRegional: Bool) -> Parsed {
        var byDate: [String: (holiday: PublicHoliday, national: Bool)] = [:]
        var makeup: Set<String> = []

        for row in rows(fromCSV: text) {
            guard isDayKey(row.date) else { continue }

            // 调休上班日和放不放假是两件事：即便某条记录因为是地方性假日而被跳过，
            // 它带的补班信息仍然有效，所以先收这一份。
            if let day = compensationDay(comment: row.comments, holidayDate: row.date) {
                makeup.insert(day)
            }

            let scope = scope(forType: row.type)
            guard scope != .excluded else { continue }
            let national = scope == .national
            guard includeRegional || national else { continue }

            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            // 同一天可能出现多条：保留先出现的，但全国性的可以顶掉地方性的。
            if let existing = byDate[row.date], existing.national || !national { continue }
            byDate[row.date] = (PublicHoliday(date: row.date, localName: name, name: name), national)
        }

        // 放假和补班撞在同一天时以放假为准，避免把假期算成工作日。
        makeup.subtract(byDate.keys)

        return Parsed(
            holidays: byDate.values.map(\.holiday).sorted { $0.date < $1.date },
            makeupWorkdays: makeup
        )
    }

    // MARK: - 行

    struct Row: Equatable {
        var date = ""
        var weekday = ""
        var name = ""
        var type = ""
        var comments = ""
    }

    /// 按表头名取列，这样将来数据集调整列顺序或者补列都不会解析错位。
    static func rows(fromCSV text: String) -> [Row] {
        let table = parseCSV(text)
        guard let header = table.first else { return [] }

        let index = Dictionary(
            header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func field(_ fields: [String], _ column: String) -> String {
            guard let position = index[column], position < fields.count else { return "" }
            return fields[position]
        }

        return table.dropFirst().compactMap { fields in
            guard fields.contains(where: { !$0.isEmpty }) else { return nil }
            return Row(
                date: field(fields, "date").trimmingCharacters(in: .whitespaces),
                weekday: field(fields, "weekday"),
                name: field(fields, "name"),
                type: field(fields, "type"),
                comments: field(fields, "comments")
            )
        }
    }

    /// RFC 4180：字段可以用双引号包起来，里面允许出现逗号、换行和 `""` 转义的引号。
    /// 数据集里 82 个文件确实用到了，例如澳大利亚的 `"VIC, TAS"`。
    static func parseCSV(_ text: String) -> [[String]] {
        var table: [[String]] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            fields.append(field)
            field = ""
        }
        func endLine() {
            endField()
            table.append(fields)
            fields = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            quoted = false
                            pending = next
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                quoted = true
            case ",":
                endField()
            // Swift 把 "\r\n" 当成一个 Character，所以三种换行各列一次就够，不用前瞻。
            case "\n", "\r\n", "\r":
                endLine()
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !fields.isEmpty { endLine() }

        return table
    }

    // MARK: - 调休上班日

    private static let monthPrefixes = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]
    private static let weekdayPrefixes = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// 从 "Compensated by Sat Feb 14" 这类备注里解出被挪成上班日的那一天。
    ///
    /// 各国的写法完全不统一，数据集里出现过至少这些形式：
    /// `Sat. Dec 30`、`Sat Dec 29 2024`、`Sat. 23 May`、`Sat 25 April`、`Aug 3`、
    /// `14 Dec`、`June 27`、`Sat Sept 2`、`Sat, Jan. 10`。
    /// 所以不套固定格式，而是把 token 拆开各认各的。
    ///
    /// 备注里通常不写年份，而补班日可以落在假期的上一年（阿塞拜疆 2024-01-04 的假
    /// 由 2023-12-30 补班）。默认就取假期同一年，只有当同年的那一天离假期超过半年时，
    /// 才认为这是一处跨年引用，改用星期几到相邻年份里挑。
    ///
    /// 星期几只能这样用，不能拿来做硬校验：中国 2024 年写的是 "Sat. Feb 4"，
    /// 而 2 月 4 日其实是周日——日期是对的，星期几标错了。
    static func compensationDay(comment: String, holidayDate: String) -> String? {
        let lowered = comment.lowercased()
        // 澳门的 "Compensatory rest day for …" 不带日期，必须排除在外。
        guard let range = lowered.range(of: "compensated by") else { return nil }

        var day: Int?
        var month: Int?
        var year: Int?
        var weekday: Int?

        for token in lowered[range.upperBound...].split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let number = Int(token) {
                if token.count == 4, number >= 1900, number <= 2999 {
                    year = year ?? number
                } else if number >= 1, number <= 31 {
                    day = day ?? number
                }
            } else if token.count >= 3 {
                let prefix = String(token.prefix(3))
                if let position = monthPrefixes.firstIndex(of: prefix) {
                    month = month ?? position + 1
                } else if let position = weekdayPrefixes.firstIndex(of: prefix) {
                    // Calendar 的 weekday 是 1 = 周日。
                    weekday = weekday ?? position + 1
                }
            }
        }

        guard let day, let month else { return nil }
        guard let holiday = DayKeyCoder.utc.date(from: holidayDate) else { return nil }
        let holidayYear = DayKeyCoder.utc.calendar.component(.year, from: holiday)

        if let year {
            return validDate(year: year, month: month, day: day).map(DayKeyCoder.utc.key(for:))
        }
        guard let sameYear = validDate(year: holidayYear, month: month, day: day) else { return nil }

        let halfYear: TimeInterval = 180 * 24 * 3600
        guard abs(sameYear.timeIntervalSince(holiday)) > halfYear else {
            return DayKeyCoder.utc.key(for: sameYear)
        }

        let candidates =
            [sameYear]
            + [holidayYear - 1, holidayYear + 1].compactMap { validDate(year: $0, month: month, day: day) }
        let weekdayMatch = weekday.flatMap { target in
            candidates.first { DayKeyCoder.utc.calendar.component(.weekday, from: $0) == target }
        }
        let nearest = candidates.min { abs($0.timeIntervalSince(holiday)) < abs($1.timeIntervalSince(holiday)) }

        return (weekdayMatch ?? nearest).map(DayKeyCoder.utc.key(for:))
    }

    /// 挡掉 2 月 30 日这类会被 Calendar 顺延到下个月的日期。
    private static func validDate(year: Int, month: Int, day: Int) -> Date? {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        guard let date = DayKeyCoder.utc.calendar.date(from: parts) else { return nil }
        let check = DayKeyCoder.utc.calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }

    private static func isDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
