import CoreGraphics
import Foundation

/// 监听屏幕锁定与解锁，解锁时把这段离开的起止时刻交给上层。
///
/// macOS 没有公开的锁屏事件接口，`com.apple.screenIsLocked` 和 `com.apple.screenIsUnlocked`
/// 这两个分布式通知是长期稳定的事实标准。沙盒应用收不到分布式通知，本应用没开沙盒所以能收到。
///
/// 通知只在事件发生的那一刻投递，应用如果是在屏幕已经锁着的时候启动的就什么都收不到，
/// 所以初始化时再用 CGSession 查一次当前状态兜底。
@MainActor
final class ScreenLockMonitor {
    /// 解锁时回调，两个参数分别是锁屏开始和结束的时刻。
    var onUnlock: ((Date, Date) -> Void)?

    private var lockedAt: Date?
    private let center = DistributedNotificationCenter.default()

    init() {
        observe("com.apple.screenIsLocked") { [weak self] in self?.lock(at: Date()) }
        observe("com.apple.screenIsUnlocked") { [weak self] in self?.unlock(at: Date()) }

        // 启动时屏幕就是锁着的，说明用户还没回来。锁屏的真实时刻已经无从得知，
        // 从现在开始算是偏保守的选择，宁可少报也不要凭空多报。
        if Self.screenIsLocked { lock(at: Date()) }
    }

    /// 监听器与应用同生命周期，不做注销。
    private func observe(_ name: String, _ handler: @escaping @MainActor @Sendable () -> Void) {
        center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private func lock(at date: Date) {
        // 已经在锁屏状态里就别用新时刻覆盖，否则连续两次锁定通知会把时长清零。
        guard lockedAt == nil else { return }
        lockedAt = date
    }

    private func unlock(at date: Date) {
        guard let start = lockedAt else { return }
        lockedAt = nil
        guard date > start else { return }
        onUnlock?(start, date)
    }

    /// 只有锁屏时字典里才会出现 CGSSessionScreenIsLocked 这个键。
    static var screenIsLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
