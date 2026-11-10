import AppKit
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
    private let lockMonitor = ScreenLockMonitor()
    private var automaticEndTask: Task<Void, Never>?
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    init(settings: SettingsStore, engine: @escaping () -> EarningsEngine) {
        self.settings = settings
        self.engine = engine
        self.active = ledger.active

        lockMonitor.onPause = { [weak self] date in
            self?.handleScreenPause(at: date)
        }
        lockMonitor.onResume = { [weak self] date in
            self?.handleScreenResume(at: date)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pauseForApplicationExit() }
        }
        maintain(at: Date())
    }

    deinit {
        automaticEndTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private var ledger: OvertimeLedger { OvertimeLedger(sessions: settings.config.overtimeSessions) }

    private func write(_ newLedger: OvertimeLedger) {
        settings.config.overtimeSessions = newLedger.sessions.sorted { $0.start < $1.start }
        active = newLedger.active
        scheduleAutomaticEnd()
    }

    /// 开始一段加班（幂等）。倍率/有偿类型默认取设置，开始时刻锁税前时薪基准。
    @discardableResult
    func start(at: Date, kind: OvertimePayKind, multiplier: Int) -> OvertimeLedgerError? {
        var store = ledger
        let currentEngine = engine()
        guard OvertimeLedger.canStart(at: at, config: settings.config,
                                      workCalendar: currentEngine.workCalendar, calendar: currentEngine.calendar) else {
            return .overlap
        }
        let base = currentEngine.hourlyGrossRate(on: at)
        let r = store.start(at: at, kind: kind, multiplier: multiplier,
                            baseHourlyGross: base, currencyCode: settings.config.currencyCode)
        switch r {
        case .success(let session):
            if lockMonitor.isPaused {
                _ = store.pause(id: session.id, at: at)
            }
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
            lastUndo = store.undo
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
            lastUndo = store.undo
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

    // MARK: - 自动结束与锁屏/熄屏暂停

    /// 恢复持久化的活动段时，补做已经到点的自动结束，或补记当前熄屏暂停。
    func maintain(at now: Date) {
        guard let session = ledger.active else {
            scheduleAutomaticEnd()
            return
        }
        let deadline = OvertimeSession.automaticEnd(after: session.start, calendar: .current)
        if now >= deadline {
            var store = ledger
            _ = store.stop(id: session.id, at: deadline)
            write(store)
            return
        }
        var store = ledger
        var changed = false
        if lockMonitor.isPaused, session.pauses.last?.end == nil {
            _ = store.pause(id: session.id, at: min(now, deadline))
            changed = true
        } else if !lockMonitor.isPaused, session.pauses.last?.end == nil {
            _ = store.resume(id: session.id, at: now)
            changed = true
        }
        if changed {
            write(store)
        } else {
            scheduleAutomaticEnd()
        }
    }

    private func handleScreenPause(at date: Date) {
        maintain(at: date)
    }

    private func handleScreenResume(at date: Date) {
        guard let session = ledger.active else { return }
        var store = ledger
        _ = store.resume(id: session.id, at: date)
        write(store)
    }

    /// 正常退出应用时把活动段标记为暂停；下次启动若已解锁/亮屏，从启动时刻继续。
    private func pauseForApplicationExit() {
        guard let session = ledger.active else { return }
        var store = ledger
        _ = store.pause(id: session.id, at: Date())
        write(store)
    }

    private func scheduleAutomaticEnd() {
        automaticEndTask?.cancel()
        automaticEndTask = nil
        guard let session = active else { return }

        let deadline = OvertimeSession.automaticEnd(after: session.start, calendar: .current)
        let delay = max(deadline.timeIntervalSinceNow, 0.1)
        automaticEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.maintain(at: Date())
        }
    }
}
