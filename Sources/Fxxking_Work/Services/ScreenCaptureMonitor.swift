import AppKit
import Foundation
import OSLog

/// 常驻的屏幕采集保护：录屏、直播或屏幕共享期间，主面板和设置窗口不展示金额。
///
/// 这项保护与 `privacyModeEnabled` 无关，App 启动后始终运行。启动时先读一次本地
/// 日志恢复当前状态，随后用系统的持续日志流接收 WindowServer 的开始/结束事件。
@MainActor
final class ScreenCaptureMonitor: ObservableObject {
    /// 普通截图会短暂触发系统采集指示器；先进入 pending，持续满一秒才升级为 active。
    private static let activationDelay: Duration = .seconds(1)
    private static let initialWatchdog: Duration = .seconds(4)

    @Published private(set) var state: ScreenCaptureProtectionState = .pending

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.cailish-0425.Fxxking-Work",
        category: "ScreenCaptureMonitor"
    )
    private var monitoringTask: Task<Void, Never>?
    /// 直接持有日志流任务：`Task {}` 是非结构化任务，父任务取消不会传导给它，
    /// 必须在 stop() 里显式取消，否则 retry() 会叠出第二条 `/usr/bin/log stream`。
    private var liveTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    nonisolated(unsafe) private var streamProcess: Process?
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    private var sawLiveEvent = false

    func start() {
        guard monitoringTask == nil else { return }
        state = .pending
        observeApplicationTermination()

        monitoringTask = Task { [weak self] in
            guard let self else { return }
            let liveTask = Task { await self.consumeSystemEvents() }
            // stop() 可能在本任务真正开跑前就取消了 monitoringTask；此时不能再把
            // 已取消的旧任务写回属性，否则会覆盖 retry() 刚启动的新任务。
            if Task.isCancelled {
                liveTask.cancel()
            } else {
                self.liveTask = liveTask
            }
            let readTask = Task.detached(priority: .utility) {
                Self.readInitialState()
            }
            let watchdog = Task { [weak self] in
                try? await Task.sleep(for: Self.initialWatchdog)
                guard !Task.isCancelled, let self,
                      self.state == .pending, !self.sawLiveEvent
                else { return }
                self.logger.error("Screen capture status source timed out")
                self.state = .unavailable
            }

            let initial = await readTask.value
            watchdog.cancel()
            // 已被 stop() 取消时，读日志的 detached 任务仍会返回；不能拿旧结果覆盖状态。
            guard !Task.isCancelled else {
                liveTask.cancel()
                return
            }
            if !sawLiveEvent {
                if let initial {
                    state = initial ? .active : .inactive
                } else {
                    logger.error("Unable to read initial screen capture state")
                    state = .unavailable
                }
            }
            await liveTask.value
        }
    }

    func retry() {
        stop()
        sawLiveEvent = false
        state = .pending
        start()
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
        liveTask?.cancel()
        liveTask = nil
        activationTask?.cancel()
        activationTask = nil
        if let streamProcess, streamProcess.isRunning {
            streamProcess.terminate()
        }
        streamProcess = nil
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    deinit {
        monitoringTask?.cancel()
        liveTask?.cancel()
        activationTask?.cancel()
        streamProcess?.terminate()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private func observeApplicationTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 终止通知返回后进程会立即退出，这里必须同步杀子进程；再排 Task 就来不及了。
            self?.streamProcess?.terminate()
        }
    }

    nonisolated private static func readInitialState() -> Bool? {
        do {
            let store = try OSLogStore.local()
            let predicate = NSPredicate(
                format: "process == %@ AND subsystem == %@ AND category == %@",
                ScreenCaptureStatusLog.processName,
                ScreenCaptureStatusLog.subsystem,
                ScreenCaptureStatusLog.category
            )
            let position = store.position(timeIntervalSinceEnd: -24 * 3600)
            var events: [(date: Date, message: String)] = []
            for entry in try store.getEntries(at: position, matching: predicate) {
                if ScreenCaptureStatusLog.change(from: entry.composedMessage) != nil {
                    events.append((entry.date, entry.composedMessage))
                }
            }
            return ScreenCaptureStatusLog.latestState(from: events)
        } catch {
            return nil
        }
    }

    private func handleLiveEvent(active: Bool) {
        sawLiveEvent = true
        if active {
            guard state != .active else { return }
            state = .pending
            activationTask?.cancel()
            activationTask = Task { [weak self] in
                try? await Task.sleep(for: Self.activationDelay)
                guard !Task.isCancelled, let self else { return }
                self.state = .active
            }
        } else {
            activationTask?.cancel()
            activationTask = nil
            state = .inactive
        }
    }

    private func consumeSystemEvents() async {
        var consecutiveFailures = 0

        while !Task.isCancelled {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "stream",
                "--style", "ndjson",
                "--predicate",
                "process == \"\(ScreenCaptureStatusLog.processName)\""
                    + " AND subsystem == \"\(ScreenCaptureStatusLog.subsystem)\""
                    + " AND category == \"\(ScreenCaptureStatusLog.category)\"",
            ]
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                streamProcess = process
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard !Task.isCancelled else { break }
                    if let active = ScreenCaptureStatusLog.change(fromJSONLine: line) {
                        consecutiveFailures = 0
                        handleLiveEvent(active: active)
                    } else {
                        logger.notice("log stream: \(line, privacy: .public)")
                    }
                }
            } catch {
                logger.error(
                    "Screen capture log stream failed: \(String(describing: error), privacy: .public)"
                )
            }

            if process.isRunning {
                process.terminate()
            }
            // 只清理自己这条流：retry() 之后旧任务收尾时可能已经有新 Process，
            // 无条件置 nil 会让 stop() 失去对新进程的引用。
            if streamProcess === process {
                streamProcess = nil
            }
            guard !Task.isCancelled else { return }

            consecutiveFailures += 1
            // 状态源断了就按安全侧处理，不能让旧状态继续展示金额。
            state = .unavailable
            let delaySeconds = min(pow(2, Double(consecutiveFailures)), 30)
            try? await Task.sleep(for: .seconds(delaySeconds))
        }
    }
}
