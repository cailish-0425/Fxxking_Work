import Combine
import Foundation

/// 请假控制器：把「单日新增/更新/删除/撤销」与「历史范围补录」统一落到
/// `Configuration.leaveEntries`（每日期一条，whole-day 与 half-day 共用 dayKey）。
/// 结果一次性整体写回 `SettingsStore.config.leaveEntries`（触发持久化与引擎重建），
/// 日期统一归一化为 startOfDay，避免 UI 传入带时刻的日期造成跨日脏数据。
///
/// 工作日判定完全委托给 `WorkCalendar`：周末、官方假日、无手动调休的节假日
/// 都会由 `isWorkday` 判为休息日；手动调休上班日（`config.makeupWorkdays`）与
/// 数据源调休日则判为工作日而保留。控制器不重复实现这套规则，只负责范围枚举。
@MainActor
final class LeaveController: ObservableObject {
    /// 范围补录/预览的预计毛额影响与受影响日期。纯展示口径，不参与引擎结算。
    struct LeavePreview: Equatable {
        /// 会被写入的日期（"yyyy-MM-dd" dayKey，已排序、去重）。
        var affectedDates: [String]
        /// affectedDates 中的工作日数；毛额影响只在这些日期上产生。
        var workdayCount: Int
        /// 预计毛额影响（元）= Σ 每日 日薪 × (1 − 请假条应发比例)。基于当前日薪。
        var grossImpact: Double
    }

    /// 校验/冲突错误（UI 与 Checks 共用同一份校验器，避免「列表改了但引擎算不出」）。
    enum LeaveControllerError: Error, Equatable {
        /// payRatioBp 超出 0…10000。
        case invalidPayRatio
        /// endDate 早于 startDate。
        case invalidDateRange
        /// 单日新增时该日期已有请假（每日期一条）。
        case duplicateDate
        /// 更新/删除的目标 id 不存在。
        case missing
        /// applyOnlyWorkdays 且范围内没有工作日。
        case noWorkdays
    }

    @Published private(set) var canUndo = false

    private let settings: SettingsStore
    /// 由调用方（App 装配）提供当前 `WorkCalendar`，控制器不持有假日数据源，
    /// 也不依赖 EarningsEngine，保证范围补录可独立于税后口径测试。
    private let workCalendar: () -> WorkCalendar

    /// 最近一次增删改/补录之前的快照，用于精确撤销。
    private var undoSnapshot: [LeaveEntry]?

    init(settings: SettingsStore, workCalendar: @escaping () -> WorkCalendar) {
        self.settings = settings
        self.workCalendar = workCalendar
    }

    var entries: [LeaveEntry] { LeaveLedger(entries: settings.config.leaveEntries).entries }

    // MARK: - 单日新增 / 更新 / 删除 / 撤销

    /// 单日新增。该日期已存在请假时返回 `.duplicateDate`（保持每日期一条）。
    /// `payRatioBp` 缺省时取 `kind` 的默认比例；未来日期允许。
    @discardableResult
    func add(
        on date: Date,
        kind: LeaveKind,
        portion: LeavePortion,
        payRatioBp: Int? = nil,
        note: String = ""
    ) -> LeaveControllerError? {
        let wc = workCalendar()
        let dayKey = wc.dayKey(wc.calendar.startOfDay(for: date))
        let ratio = payRatioBp ?? kind.defaultPayRatioBp
        guard (0...10_000).contains(ratio) else { return .invalidPayRatio }

        let old = settings.config.leaveEntries
        var store = LeaveLedger(entries: old)
        guard store.entry(on: dayKey) == nil else { return .duplicateDate }
        _ = store.upsert(LeaveEntry(dayKey: dayKey, kind: kind, portion: portion,
                                    payRatioBp: ratio, note: note))
        commit(store, snapshot: old)
        return nil
    }

    /// 更新既有请假：kind/portion/note 缺省保持原值；改了 kind 却没显式给
    /// `payRatioBp` 时，跟随新 kind 的默认比例（把事假改成病假默认回到 60%）。
    @discardableResult
    func update(
        id: UUID,
        kind: LeaveKind? = nil,
        portion: LeavePortion? = nil,
        payRatioBp: Int? = nil,
        note: String? = nil
    ) -> LeaveControllerError? {
        let old = settings.config.leaveEntries
        var store = LeaveLedger(entries: old)
        guard let index = store.entries.firstIndex(where: { $0.id == id }) else { return .missing }
        let existing = store.entries[index]

        let newKind = kind ?? existing.kind
        let newRatio: Int
        if let ratio = payRatioBp {
            newRatio = ratio
        } else if kind != nil {
            newRatio = newKind.defaultPayRatioBp
        } else {
            newRatio = existing.payRatioBp
        }
        guard (0...10_000).contains(newRatio) else { return .invalidPayRatio }

        var updated = existing
        updated.kind = newKind
        updated.portion = portion ?? existing.portion
        updated.payRatioBp = newRatio
        updated.note = note ?? existing.note
        store.entries[index] = updated
        commit(store, snapshot: old)
        return nil
    }

    /// 删除；撤销载荷在 controller 内维护最近一次。
    @discardableResult
    func delete(id: UUID) -> LeaveControllerError? {
        let old = settings.config.leaveEntries
        var store = LeaveLedger(entries: old)
        guard store.entries.contains(where: { $0.id == id }) else { return .missing }
        store.remove(id: id)
        commit(store, snapshot: old)
        return nil
    }

    /// 撤销最近一次增删改/补录，精确还原为该次操作前的记录。
    func undo() {
        guard let snapshot = undoSnapshot else { return }
        settings.config.leaveEntries = LeaveLedger(entries: snapshot).entries
        undoSnapshot = nil
        canUndo = false
    }

    // MARK: - 历史范围补录

    /// 预览范围补录会写入哪些日期、工作日数、预计毛额影响。纯计算，不改状态。
    /// `applyOnlyWorkdays == true` 时跳过周末/假日等非工作日（手动调休日保留）。
    func previewBackfill(
        start: Date,
        end: Date,
        kind: LeaveKind,
        portion: LeavePortion,
        payRatioBp: Int? = nil,
        note: String = "",
        applyOnlyWorkdays: Bool
    ) -> Result<LeavePreview, LeaveControllerError> {
        let ratio = payRatioBp ?? kind.defaultPayRatioBp
        guard (0...10_000).contains(ratio) else { return .failure(.invalidPayRatio) }

        let wc = workCalendar()
        guard wc.calendar.startOfDay(for: end) >= wc.calendar.startOfDay(for: start) else {
            return .failure(.invalidDateRange)
        }
        let dates = affectedDates(from: start, to: end, workdaysOnly: applyOnlyWorkdays, wc: wc)
        let candidate = LeaveEntry(dayKey: "", kind: kind, portion: portion,
                                   payRatioBp: ratio, note: note)
        return .success(project(dates: dates, candidate: candidate, wc: wc))
    }

    /// 应用范围补录（原子写回 leaveEntries）。已存在的日期原地更新（保留 id）。
    @discardableResult
    func applyBackfill(
        start: Date,
        end: Date,
        kind: LeaveKind,
        portion: LeavePortion,
        payRatioBp: Int? = nil,
        note: String = "",
        applyOnlyWorkdays: Bool
    ) -> LeaveControllerError? {
        let ratio = payRatioBp ?? kind.defaultPayRatioBp
        guard (0...10_000).contains(ratio) else { return .invalidPayRatio }

        let wc = workCalendar()
        guard wc.calendar.startOfDay(for: end) >= wc.calendar.startOfDay(for: start) else {
            return .invalidDateRange
        }
        let dates = affectedDates(from: start, to: end, workdaysOnly: applyOnlyWorkdays, wc: wc)
        if applyOnlyWorkdays && dates.isEmpty { return .noWorkdays }

        let old = settings.config.leaveEntries
        var store = LeaveLedger(entries: old)
        for date in dates {
            let dayKey = wc.dayKey(date)
            let entry = LeaveEntry(dayKey: dayKey, kind: kind, portion: portion,
                                   payRatioBp: ratio, note: note)
            if let index = store.entries.firstIndex(where: { $0.dayKey == dayKey }) {
                var replaced = entry
                replaced.id = store.entries[index].id
                store.entries[index] = replaced
            } else {
                _ = store.upsert(entry)
            }
        }
        commit(store, snapshot: old)
        return nil
    }

    /// 某一天若置为 `entry`（相对满勤）的毛额影响，基于当前日薪，纯展示估计。
    func grossImpact(of entry: LeaveEntry, on date: Date) -> Double {
        let wc = workCalendar()
        guard wc.isWorkday(date) else { return 0 }
        return dailyPay(on: date, wc: wc) * (1 - entry.payableFraction)
    }

    // MARK: - 内部实现

    /// 把受影响的日期折算成预览：dayKey 列表 + 工作日数 + 毛额影响。
    private func project(dates: [Date], candidate: LeaveEntry, wc: WorkCalendar) -> LeavePreview {
        var keys: [String] = []
        var workdays = 0
        var impact = 0.0
        for date in dates {
            keys.append(wc.dayKey(date))
            if wc.isWorkday(date) {
                workdays += 1
                impact += dailyPay(on: date, wc: wc) * (1 - candidate.payableFraction)
            }
        }
        return LeavePreview(affectedDates: keys, workdayCount: workdays, grossImpact: impact)
    }

    /// [start, end]（闭区间，startOfDay 归一化）逐日枚举；workdaysOnly 时只留工作日。
    private func affectedDates(
        from start: Date,
        to end: Date,
        workdaysOnly: Bool,
        wc: WorkCalendar
    ) -> [Date] {
        let cal = wc.calendar
        var cursor = cal.startOfDay(for: start)
        let stop = cal.startOfDay(for: end)
        var result: [Date] = []
        while cursor <= stop {
            if !workdaysOnly || wc.isWorkday(cursor) {
                result.append(cursor)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// 当前日薪 = 当前月薪 / 该月工作日数。基于 config 当前工资，不含工资历史分段。
    private func dailyPay(on date: Date, wc: WorkCalendar) -> Double {
        let count = wc.workdaysInMonth(containing: date)
        return count > 0 ? settings.config.monthlyPay / Double(count) : 0
    }

    private func commit(_ store: LeaveLedger, snapshot: [LeaveEntry]) {
        settings.config.leaveEntries = LeaveLedger(entries: store.entries).entries
        undoSnapshot = snapshot
        canUndo = true
    }
}
