import Combine
import Foundation

/// 加班控制器：把 UI 的「开始/结束/补录/纠错/删除/撤销」统一落到 OvertimeLedger，
/// 结果写回 `SettingsStore.config.overtimeSessions`（触发持久化与引擎重建）。
/// 开始时锁定当时有效正常税前时薪（来自引擎），后改工资/历史不重价既有段。
@MainActor
final class OvertimeController: ObservableObject {
    @Published private(set) var active: OvertimeSession?

    private let settings: SettingsStore
    private let engine: () -> EarningsEngine

    init(settings: SettingsStore, engine: @escaping () -> EarningsEngine) {
        self.settings = settings
        self.engine = engine
    }

    private var ledger: OvertimeLedger { OvertimeLedger(sessions: settings.config.overtimeSessions) }

    private func write(_ newLedger: OvertimeLedger) {
        settings.config.overtimeSessions = newLedger.sessions.sorted { $0.start < $1.start }
        active = newLedger.active
    }

    /// 开始一段加班（幂等）。倍率/有偿类型默认取设置，开始时刻锁税前时薪基准。
    @discardableResult
    func start(at: Date, kind: OvertimePayKind, multiplier: Int) -> OvertimeLedgerError? {
        var store = ledger
        let base = engine().hourlyGrossRate(on: at)
        let r = store.start(at: at, kind: kind, multiplier: multiplier,
                            baseHourlyGross: base, currencyCode: settings.config.currencyCode)
        switch r {
        case .success:
            write(store)
            return nil
        case .failure(let e):
            return e
        }
    }

    /// 结束进行中的段（幂等）。
    @discardableResult
    func stop(at: Date) -> OvertimeLedgerError? {
        guard let id = ledger.active?.id else { return .notActive }
        var store = ledger
        let r = store.stop(id: id, at: at)
        switch r {
        case .success:
            write(store)
            return nil
        case .failure(let e):
            return e
        }
    }

    /// 补录（校验结束>开始、非未来、不重叠）。
    @discardableResult
    func addBackfill(_ session: OvertimeSession, now: Date) -> OvertimeLedgerError? {
        var store = ledger
        let engine = engine()
        let r = store.addBackfill(session, now: now, config: settings.config,
                                  workCalendar: engine.workCalendar, calendar: engine.calendar)
        switch r {
        case .success:
            write(store)
            return nil
        case .failure(let e):
            return e
        }
    }

    /// 纠错（活动中的段先结束再编辑）。
    @discardableResult
    func edit(id: UUID, to session: OvertimeSession, now: Date) -> OvertimeLedgerError? {
        var store = ledger
        let engine = engine()
        let r = store.edit(id: id, to: session, now: now, config: settings.config,
                           workCalendar: engine.workCalendar, calendar: engine.calendar)
        switch r {
        case .success:
            write(store)
            return nil
        case .failure(let e):
            return e
        }
    }

    /// 删除（撤销载荷在 controller 内维护最近一次）。
    @discardableResult
    func delete(id: UUID) -> OvertimeLedgerError? {
        var store = ledger
        store.undo = lastUndo
        let r = store.delete(id: id)
        switch r {
        case .success:
            lastUndo = store.undo
            write(store)
            return nil
        case .failure(let e):
            return e
        }
    }

    /// 撤销最近一次补录/纠错/删除。
    func undo() {
        var store = ledger
        store.undo = lastUndo
        store.undoLast()
        lastUndo = nil
        write(store)
    }

    var canUndo: Bool { lastUndo != nil }

    private var lastUndo: OvertimeUndo?
}
