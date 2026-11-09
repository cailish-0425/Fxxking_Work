import Foundation

/// 加班段的有偿/无偿类型。有偿加入工资与税基；无偿只统计「赔了多少」，绝不进入工资/税基。
enum OvertimePayKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case paid
    case unpaid

    var id: String { rawValue }
}

/// 一段加班记录。开始那一刻锁定当时有效的正常税前时薪、倍率与币种，
/// 之后改工资设置/工资历史不重价既有段；跨午夜按实际发生日拆到各月/年，仍是一段可编辑记录。
struct OvertimeSession: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// 开始时刻（用户显式点「开始加班」）。
    var start: Date
    /// 结束时刻；nil 表示进行中（实时逐秒累计）。
    var end: Date?
    /// 有偿 / 无偿。
    var kind: OvertimePayKind
    /// 倍率：有偿 1/2/3；无偿固定按 1 倍统计损失（此字段对无偿无效）。
    var multiplier: Int
    /// 开始时锁定的正常税前时薪（元/小时），历史基准，后改工资不重价。
    var baseHourlyGross: Double
    /// 锁定的币种快照。
    var currencyCode: String

    var isActive: Bool { end == nil }

    /// 已结束段的总时长（秒）；进行中段由调用方传 now 计算。
    func elapsedSeconds(at now: Date) -> Double {
        let stop = end ?? now
        return max(stop.timeIntervalSince(start), 0)
    }
}

/// 加班汇总（与税基/工资口径分离）：有偿按 基准×倍率×秒，无偿按 基准×1×秒。
struct OvertimeSummary: Equatable {
    var dayPaid: Double = 0
    var monthPaid: Double = 0
    var yearPaid: Double = 0
    var dayLoss: Double = 0
    var monthLoss: Double = 0
    var yearLoss: Double = 0
    /// 进行中的段；nil 表示当前没有正在计的加班。
    var active: OvertimeSession?
    /// 进行中段的实时金额（有偿 = 加班工资毛额；无偿 = 损失）。
    var activeAmount: Double = 0
    /// 进行中段的实时秒数（已剪掉正常计薪时段，逐秒一致）。
    var activeSeconds: Double = 0
}

/// 加班变更的撤销载荷（补录/纠错/删除的最近一次操作，一步精确还原）。
enum OvertimeUndo: Equatable {
    case added(OvertimeSession)
    case edited(from: OvertimeSession, to: OvertimeSession)
    case deleted(OvertimeSession)
}

/// 加班记账的错误原因（UI 用同一份校验器，避免「列表改了但引擎算不出」的脏状态）。
enum OvertimeLedgerError: Error, Equatable {
    case alreadyActive
    case notActive
    case endBeforeStart
    case futureEnd
    case overlap
    case missing
}

/// 加班台账。所有增删改/撤销/开始结束都走这里，UI 不各自拼 `sessions` 数组。
/// 拆分与汇总为纯函数，跨午夜按发生日拆到各月/年；工作日落在正常计薪时段里的部分剪掉避免双算。
struct OvertimeLedger {
    var sessions: [OvertimeSession]
    var undo: OvertimeUndo?

    init(sessions: [OvertimeSession]) {
        self.sessions = sessions.sorted { $0.start < $1.start }
    }

    var active: OvertimeSession? { sessions.first(where: { $0.isActive }) }
    var hasActive: Bool { active != nil }

    // MARK: - 开始 / 结束（幂等）

    /// 工作日须等规定下班时刻；休息日/假日允许用户显式开始。
    static func canStart(at date: Date, config: Configuration, workCalendar: WorkCalendar, calendar: Calendar) -> Bool {
        guard workCalendar.isWorkday(date) else { return true }
        let day = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .minute, value: config.endMinutes, to: day) else { return false }
        return date >= end
    }


    /// 开始：已存在进行中的段则拒绝（幂等防重复）。
    mutating func start(
        at: Date, kind: OvertimePayKind, multiplier: Int,
        baseHourlyGross: Double, currencyCode: String
    ) -> Result<OvertimeSession, OvertimeLedgerError> {
        guard !hasActive else { return .failure(.alreadyActive) }
        let session = OvertimeSession(
            start: at, end: nil, kind: kind, multiplier: multiplier,
            baseHourlyGross: baseHourlyGross, currencyCode: currencyCode)
        sessions.append(session)
        sessions.sort { $0.start < $1.start }
        return .success(session)
    }

    /// 结束：幂等；end <= start（时间回拨）拒绝，不产生负/重复记录。
    mutating func stop(id: UUID, at: Date) -> Result<OvertimeSession, OvertimeLedgerError> {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].isActive else {
            return .failure(.notActive)
        }
        guard at > sessions[index].start else { return .failure(.endBeforeStart) }
        sessions[index].end = at
        return .success(sessions[index])
    }

    // MARK: - 补录 / 纠错 / 删除 / 撤销

    /// 补录：校验 结束>开始、非未来、不与既有加班或正常计薪时段重叠。
    mutating func addBackfill(
        _ session: OvertimeSession,
        now: Date,
        config: Configuration,
        workCalendar: WorkCalendar,
        calendar: Calendar
    ) -> Result<OvertimeSession, OvertimeLedgerError> {
        if let error = Self.validate(
            session, now: now, config: config, workCalendar: workCalendar, calendar: calendar) {
            return .failure(error)
        }
        guard !Self.overlapsExisting(session, now: now, in: sessions) else { return .failure(.overlap) }
        sessions.append(session)
        sessions.sort { $0.start < $1.start }
        undo = .added(session)
        return .success(session)
    }

    /// 纠错：改起止/付费类型/倍率；活动中的段先结束再编辑。保留旧版本进撤销栈，不偷用今日工资重价。
    mutating func edit(
        id: UUID, to newSession: OvertimeSession,
        now: Date, config: Configuration, workCalendar: WorkCalendar, calendar: Calendar
    ) -> Result<OvertimeSession, OvertimeLedgerError> {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return .failure(.missing) }
        let old = sessions[index]
        if let error = Self.validate(
            newSession, now: now, config: config, workCalendar: workCalendar, calendar: calendar) {
            return .failure(error)
        }
        guard !Self.overlapsExisting(newSession, now: now, in: sessions, excluding: id) else {
            return .failure(.overlap)
        }
        var edited = newSession
        edited.id = old.id
        sessions[index] = edited
        sessions.sort { $0.start < $1.start }
        undo = .edited(from: old, to: edited)
        return .success(edited)
    }

    /// 删除；撤销载荷保留最近一次。
    mutating func delete(id: UUID) -> Result<OvertimeSession, OvertimeLedgerError> {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return .failure(.missing) }
        let removed = sessions.remove(at: index)
        undo = .deleted(removed)
        return .success(removed)
    }

    /// 撤销最近一次补录/纠错/删除。
    mutating func undoLast() {
        guard let undo else { return }
        switch undo {
        case .added(let session):
            sessions.removeAll { $0.id == session.id }
        case .edited(let from, _):
            if let index = sessions.firstIndex(where: { $0.id == from.id }) {
                sessions[index] = from
                sessions.sort { $0.start < $1.start }
            }
        case .deleted(let session):
            sessions.append(session)
            sessions.sort { $0.start < $1.start }
        }
        self.undo = nil
    }

    // MARK: - 校验（补录/纠错共用）

    static func validate(
        _ session: OvertimeSession,
        now: Date,
        config: Configuration,
        workCalendar: WorkCalendar,
        calendar: Calendar,
        excluding: UUID? = nil
    ) -> OvertimeLedgerError? {
        let end = session.end ?? now
        guard end > session.start else { return .endBeforeStart }
        guard end <= now else { return .futureEnd }
        // 落在工作日正常计薪时段内 → 与正常工资重复计薪，拒绝。
        var day = calendar.startOfDay(for: session.start)
        while day < end {
            if workCalendar.isWorkday(day) {
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? end
                let from = max(session.start, day)
                let to = min(end, dayEnd)
                if to > from, overlapsPaidSchedule(from: from, to: to, on: day, config: config, calendar: calendar) {
                    return .overlap
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return nil
    }

    /// 补录/纠错是否与「既有加班段」重叠（排除某 id）。
    static func overlapsExisting(
        _ session: OvertimeSession, now: Date, in sessions: [OvertimeSession], excluding: UUID? = nil
    ) -> Bool {
        let start = session.start
        let end = session.end ?? now
        for other in sessions where other.id != excluding && other.id != session.id {
            let oStart = other.start
            let oEnd = other.end ?? now
            if start < oEnd && oStart < end { return true }
        }
        return false
    }

    // MARK: - 拆分与汇总（纯函数）

    /// 一段落在某一天里、并且不与正常计薪时段重叠的秒数。
    static func overtimeSeconds(
        on day: Date, between from: Date, and to: Date, config: Configuration, calendar: Calendar
    ) -> Double {
        var total = to.timeIntervalSince(from)
        for interval in config.paidIntervals {
            guard let lower = Self.date(on: day, minutes: interval.lowerBound, calendar: calendar),
                let upper = Self.date(on: day, minutes: interval.upperBound, calendar: calendar)
            else { continue }
            let overlap = min(to, upper).timeIntervalSince(max(from, lower))
            if overlap > 0 { total -= overlap }
        }
        return max(total, 0)
    }

    private static func overlapsPaidSchedule(
        from: Date, to: Date, on day: Date, config: Configuration, calendar: Calendar
    ) -> Bool {
        overtimeSeconds(on: day, between: from, and: to, config: config, calendar: calendar)
            < (to.timeIntervalSince(from) - 0.001)
    }

    private static func date(on day: Date, minutes: Int, calendar: Calendar) -> Date? {
        if minutes >= 24 * 60 {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    /// 跨午夜按发生日拆分；工作日剪掉正常计薪时段（上班/午休），休息日/假日整段计入（用户显式开启）。
    /// 进行中的段在开始后的下一个正常排班开始处截断，避免把次日的正常上班时段误计为加班（双算）。
    func segments(
        at now: Date, config: Configuration, workCalendar: WorkCalendar, calendar: Calendar
    ) -> [OvertimeLedger.DaySegment] {
        var result: [OvertimeLedger.DaySegment] = []
        for session in sessions {
            var stop = session.end ?? now
            if session.isActive {
                stop = Self.truncatedEnd(for: session, now: now, config: config, workCalendar: workCalendar, calendar: calendar)
            }
            guard stop > session.start else { continue }
            var day = calendar.startOfDay(for: session.start)
            while day < stop {
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? stop
                let from = max(session.start, day)
                let to = min(stop, dayEnd)
                var seconds = to.timeIntervalSince(from)
                if workCalendar.isWorkday(day) {
                    seconds = Self.overtimeSeconds(on: day, between: from, and: to, config: config, calendar: calendar)
                }
                guard seconds > 0 else { day = dayEnd; continue }
                result.append(
                    OvertimeLedger.DaySegment(
                        sessionID: session.id, day: day, seconds: seconds,
                        month: calendar.component(.month, from: day),
                        year: calendar.component(.year, from: day),
                        kind: session.kind, multiplier: session.multiplier,
                        baseHourlyGross: session.baseHourlyGross))
                day = dayEnd
            }
        }
        return result
    }

    /// 进行中段的截断终点：开始之后第一个「工作日 + 上班时刻」；在那之前照计，之后不再累加（等用户主动再开）。
    private static func truncatedEnd(
        for session: OvertimeSession, now: Date, config: Configuration,
        workCalendar: WorkCalendar, calendar: Calendar
    ) -> Date {
        var day = calendar.startOfDay(for: session.start)
        for _ in 0..<400 {
            if workCalendar.isWorkday(day) {
                if let startDate = date(on: day, minutes: config.startMinutes, calendar: calendar),
                    startDate > session.start {
                    return min(startDate, now)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return now
    }

    /// 汇总：有偿 = 基准×倍率×秒；无偿损失 = 基准×1×秒。进行中段实时逐秒（与汇总一致）。
    func summary(
        at now: Date, config: Configuration, workCalendar: WorkCalendar, calendar: Calendar
    ) -> OvertimeSummary {
        var s = OvertimeSummary()
        let segs = segments(at: now, config: config, workCalendar: workCalendar, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let nowMonth = calendar.component(.month, from: now)
        let nowYear = calendar.component(.year, from: now)
        for seg in segs {
            let hours = seg.seconds / 3600
            if seg.kind == .paid {
                let amount = hours * seg.baseHourlyGross * Double(seg.multiplier)
                if calendar.isDate(seg.day, inSameDayAs: today) { s.dayPaid += amount }
                if seg.month == nowMonth { s.monthPaid += amount }
                if seg.year == nowYear { s.yearPaid += amount }
            } else {
                let loss = hours * seg.baseHourlyGross
                if calendar.isDate(seg.day, inSameDayAs: today) { s.dayLoss += loss }
                if seg.month == nowMonth { s.monthLoss += loss }
                if seg.year == nowYear { s.yearLoss += loss }
            }
        }
        if let activeSession = active {
            s.active = activeSession
            let activeSegs = segs.filter { $0.sessionID == activeSession.id }
            s.activeSeconds = activeSegs.reduce(0) { $0 + $1.seconds }
            if activeSession.kind == .paid {
                s.activeAmount = activeSegs.reduce(0) { $0 + $1.seconds / 3600 * $1.baseHourlyGross * Double($1.multiplier) }
            } else {
                s.activeAmount = activeSegs.reduce(0) { $0 + $1.seconds / 3600 * $1.baseHourlyGross }
            }
        }
        return s
    }

    /// 有偿加班毛额（税前），按归属月拆成 12 个月（index 0 = 1 月）。用于税后累计预扣。
    func paidOvertimeGross(
        byMonth year: Int, at now: Date, config: Configuration, workCalendar: WorkCalendar, calendar: Calendar
    ) -> [Double] {
        var result = [Double](repeating: 0, count: 12)
        for seg in segments(at: now, config: config, workCalendar: workCalendar, calendar: calendar)
        where seg.kind == .paid && seg.year == year {
            result[seg.month - 1] += seg.seconds / 3600 * seg.baseHourlyGross * Double(seg.multiplier)
        }
        return result
    }

    // MARK: - 拆分单元

    struct DaySegment: Equatable {
        var sessionID: UUID
        var day: Date
        var seconds: Double
        var month: Int
        var year: Int
        var kind: OvertimePayKind
        var multiplier: Int
        var baseHourlyGross: Double
    }
}
