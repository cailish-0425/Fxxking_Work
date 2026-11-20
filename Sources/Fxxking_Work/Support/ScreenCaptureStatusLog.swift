import Foundation

/// 屏幕保护在 UI 上的四种状态。除 inactive 外都不允许金额出现。
enum ScreenCaptureProtectionState: Equatable {
    /// 正在恢复/确认状态，金额先隐藏。
    case pending
    /// 当前没有屏幕采集。
    case inactive
    /// 已确认存在持续采集。
    case active
    /// 状态源不可用，按安全侧继续隐藏。
    case unavailable

    var hidesAmounts: Bool { self != .inactive }
    var blocksContent: Bool { self != .inactive }
}

/// WindowServer 的系统录屏/共享状态指示事件。
///
/// macOS 没有公开接口直接枚举其他进程正在运行的 ScreenCaptureKit 流；WindowServer
/// 在系统级采集指示器变化时会写入这两个稳定事件。这里只解析事件含义，不影响日志读取。
enum ScreenCaptureStatusLog {
    static let processName = "WindowServer"
    static let subsystem = "com.apple.SkyLight"
    static let category = "StatusIndicator"
    static let marker = "screen capture"

    static func change(from message: String) -> Bool? {
        let normalized = message.lowercased()
        guard normalized.contains(marker) else { return nil }
        if normalized.contains("\(marker) added") { return true }
        if normalized.contains("\(marker) removed") { return false }
        return nil
    }

    static func change(fromJSONLine line: String) -> Bool? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["eventMessage"] as? String
        else { return nil }
        return change(from: message)
    }

    static func latestState(
        from events: [(date: Date, message: String)],
        startingWith initial: Bool = false
    ) -> Bool {
        events.sorted { $0.date < $1.date }.reduce(initial) { state, event in
            change(from: event.message) ?? state
        }
    }
}
