import Foundation

/// 一次带生效日期的工资变更。生效日当天 00:00 起按新工资计薪；
/// 之前的日期仍按更早版本（或无日期基线）计薪，中途涨薪不重算过去。
struct SalaryVersion: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// 生效日期 "yyyy-MM-dd"（含）。
    var effectiveDate: String
    var amount: Double
    var period: SalaryPeriod
    var payMonthsPerYear: Int

    /// 该版本折算出的月薪毛额（年薪先 ÷ payMonthsPerYear）。
    var monthlyGross: Double {
        let months = Double(max(payMonthsPerYear, 1))
        switch period {
        case .monthly: return max(amount, 0)
        case .annual: return max(amount, 0) / months
        }
    }
}

/// 新增 / 编辑的本地一致性校验错误。UI 用同一个校验器，避免「加了一行但引擎算不出」的脏状态。
enum SalaryHistoryValidationError: Equatable {
    case amount
    case months
    case date
    case missing
}

/// 工资变更历史。空数组 = 全程使用当前 Configuration 的工资（旧配置兼容，无日期基线）。
struct SalaryHistory: Codable, Equatable {
    var versions: [SalaryVersion] = []

    /// 按生效日期升序。
    var sorted: [SalaryVersion] { versions.sorted { $0.effectiveDate < $1.effectiveDate } }

    /// 生效应届日期合法、金额非负、薪月数在 12–20。
    static func validationError(amount: Double, payMonthsPerYear: Int, effectiveDate: String, calendar: Calendar) -> SalaryHistoryValidationError? {
        guard amount.isFinite, amount >= 0 else { return .amount }
        guard (12...20).contains(payMonthsPerYear) else { return .months }
        // 严格校验生效日期：yyyy-MM-dd，月份 1–12、日期 1–31，且能无损往返（拒绝 2026-13-40、2/30 之类）。
        let parts = effectiveDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .date }
        let (year, month, day) = (parts[0], parts[1], parts[2])
        guard (1...12).contains(month), (1...31).contains(day) else { return .date }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let date = calendar.date(from: comps) else { return .date }
        let round = calendar.dateComponents([.year, .month, .day], from: date)
        guard round.year == year, round.month == month, round.day == day else { return .date }
        return nil
    }
}

/// 单条变更的撤销载荷：删除或编辑前的快照，供一步撤销精确还原。
struct SalaryVersionSnapshot: Codable, Equatable {
    var index: Int
    var version: SalaryVersion
}

/// 变更历史的撤销载荷：删除一条、编辑一条，或删除到只剩基线（首次变更被删光）。
enum SalaryHistoryUndo: Equatable {
    case deleted(SalaryVersionSnapshot)
    case edited(from: SalaryVersionSnapshot, to: SalaryVersion)
    /// 删除到空历史：同时携带被删的最后一条与收回的基线，撤销时两者都精确还原。
    case cleared(version: SalaryVersionSnapshot, baseline: SalaryBaseline?)
}

/// 变更历史的编辑命令。所有增删改都走这里，UI 只负责拿命令结果去提示影响范围，
/// 不各自拼装 `versions` 数组，杜绝「列表改了但排序/基线/撤销不同步」。
struct SalaryHistoryStore {
    private(set) var versions: [SalaryVersion]
    private(set) var baseline: SalaryBaseline?
    /// 撤销载荷；新增成功后置 nil（一次新操作覆盖旧撤销）。
    var undo: SalaryHistoryUndo?

    init(versions: [SalaryVersion], baseline: SalaryBaseline?) {
        self.versions = versions
        self.baseline = baseline
    }

    /// 首次新增时冻结当前工资为基线，避免之后改当前工资把生效日前历史重写。
    mutating func ensureBaseline(current: Configuration) {
        guard baseline == nil, versions.isEmpty else { return }
        baseline = SalaryBaseline(
            amount: current.salaryAmount,
            period: current.salaryPeriod,
            payMonthsPerYear: current.payMonthsPerYear)
    }

    /// 新增一条变更（保持按生效日期升序），成功返回 nil，失败返回校验错误。
    mutating func add(
        _ version: SalaryVersion,
        current: Configuration,
        calendar: Calendar
    ) -> SalaryHistoryValidationError? {
        if let error = SalaryHistory.validationError(
            amount: version.amount,
            payMonthsPerYear: version.payMonthsPerYear,
            effectiveDate: version.effectiveDate,
            calendar: calendar) {
            return error
        }
        ensureBaseline(current: current)
        versions.append(version)
        versions.sort { $0.effectiveDate < $1.effectiveDate }
        undo = nil
        return nil
    }

    /// 编辑既有版本：保留旧版本进撤销栈；只改这一条，历史其余日期不受影响。
    mutating func edit(
        id: UUID,
        to newVersion: SalaryVersion,
        calendar: Calendar
    ) -> SalaryHistoryValidationError? {
        guard versions.contains(where: { $0.id == id }) else { return .missing }
        guard let index = versions.firstIndex(where: { $0.id == id }) else { return .missing }
        if let error = SalaryHistory.validationError(
            amount: newVersion.amount,
            payMonthsPerYear: newVersion.payMonthsPerYear,
            effectiveDate: newVersion.effectiveDate,
            calendar: calendar) {
            return error
        }
        let old = versions[index]
        var edited = newVersion
        edited.id = old.id
        versions[index] = edited
        versions.sort { $0.effectiveDate < $1.effectiveDate }
        undo = .edited(from: SalaryVersionSnapshot(index: index, version: old), to: edited)
        return nil
    }

    /// 删除一条变更；若删到空历史，基线一并收回进撤销栈，界面回到「当前工资全程生效」。
    mutating func delete(id: UUID) -> SalaryHistoryValidationError? {
        guard let index = versions.firstIndex(where: { $0.id == id }) else { return .missing }
        let removed = versions.remove(at: index)
        if versions.isEmpty {
            let clearedBaseline = baseline
            baseline = nil
            undo = .cleared(version: SalaryVersionSnapshot(index: index, version: removed), baseline: clearedBaseline)
        } else {
            undo = .deleted(SalaryVersionSnapshot(index: index, version: removed))
        }
        return nil
    }

    /// 撤销最近一次增删改；新增的撤销是直接移除该版本（基线保留无妨）。
    mutating func undoLast() {
        guard let undo else { return }
        switch undo {
        case .deleted(let snapshot):
            versions.append(snapshot.version)
            versions.sort { $0.effectiveDate < $1.effectiveDate }
        case .edited(let from, _):
            if let index = versions.firstIndex(where: { $0.id == from.version.id }) {
                versions[index] = from.version
                versions.sort { $0.effectiveDate < $1.effectiveDate }
            }
        case .cleared(let snapshot, let clearedBaseline):
            versions.append(snapshot.version)
            versions.sort { $0.effectiveDate < $1.effectiveDate }
            baseline = clearedBaseline
        }
        self.undo = nil
    }
}

/// 首次新增工资变更前的「旧工资基线」，冻结住历史生效日之前的工资，
/// 避免之后修改当前工资把生效日前的历史重写。
struct SalaryBaseline: Codable, Equatable {
    var amount: Double
    var period: SalaryPeriod
    var payMonthsPerYear: Int

    var monthlyGross: Double {
        let months = Double(max(payMonthsPerYear, 1))
        switch period {
        case .monthly: return max(amount, 0)
        case .annual: return max(amount, 0) / months
        }
    }
}

/// 一条已解析的工资时间线：把「版本历史 + 冻结基线 + 当前工资」合成一个日期→月薪毛额的函数。
/// 引擎与设置界面共用，避免各自再写一遍生效规则。
struct SalarySchedule {
    let history: [SalaryVersion]
    let baseline: SalaryBaseline?
    /// 无历史、无基线时的兜底月薪（当前配置的月薪）。
    let currentMonthly: Double
    private let keyCoder: DayKeyCoder

    init(history: [SalaryVersion], baseline: SalaryBaseline?, currentMonthly: Double, calendar: Calendar) {
        self.history = history
        self.baseline = baseline
        self.currentMonthly = currentMonthly
        self.keyCoder = DayKeyCoder(calendar: calendar)
    }

    init(config: Configuration, calendar: Calendar) {
        self.init(
            history: config.salaryHistory,
            baseline: config.salaryBaseline,
            currentMonthly: config.monthlyPay,
            calendar: calendar)
    }

    /// 某日生效的月薪毛额：取生效日 <= 该日的最近版本；无则回退冻结基线 → 当前工资。
    func monthlyGross(on date: Date) -> Double {
        let key = keyCoder.key(for: date)
        if let version = history
            .filter({ $0.effectiveDate <= key })
            .max(by: { $0.effectiveDate < $1.effectiveDate }) {
            return version.monthlyGross
        }
        if let baseline { return baseline.monthlyGross }
        return currentMonthly
    }
}

/// 生效工资解析：给定日期，返回该日生效的月薪毛额。
/// 优先取生效日 <= 该日的最近版本；无则回退「冻结基线」（若有）→ 当前工资。
enum SalaryResolver {
    static func monthlyGross(
        on date: Date,
        history: [SalaryVersion],
        baseline: SalaryBaseline? = nil,
        current: Configuration,
        calendar: Calendar
    ) -> Double {
        SalarySchedule(
            history: history, baseline: baseline, currentMonthly: current.monthlyPay, calendar: calendar
        )
        .monthlyGross(on: date)
    }
}
