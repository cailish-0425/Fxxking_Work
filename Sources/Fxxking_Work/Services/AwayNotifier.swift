import Foundation
@preconcurrency import UserNotifications

/// 解锁后发一条系统通知。
///
/// 授权被拒、系统开着专注模式、或者应用没有正常的 bundle 标识时都会静默失败——
/// 这是有意的，面板里那张卡片才是兜底，通知只是锦上添花，不该因为发不出去就打扰用户。
@MainActor
final class AwayNotifier: NSObject {
    static let shared = AwayNotifier()

    private var authorized = false
    private var didRequest = false
    private var readyCallbacks: [@MainActor () -> Void] = []

    /// 没有 bundle 标识时 UNUserNotificationCenter.current() 会直接崩，命令行跑断言时就是这种情况。
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func prepare(onReady: (@MainActor () -> Void)? = nil) {
        guard isAvailable else {
            onReady?()
            return
        }
        if authorized {
            onReady?()
            return
        }
        if let onReady {
            readyCallbacks.append(onReady)
        }
        guard !didRequest else { return }
        didRequest = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorized = granted
                let callbacks = self.readyCallbacks
                self.readyCallbacks.removeAll()
                callbacks.forEach { $0() }
            }
        }
    }

    func post(title: String, body: String) {
        guard isAvailable, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    struct ScheduledNotification {
        var identifier: String
        var title: String
        var body: String
        var date: Date
    }

    /// 用新一组通知完整替换某个前缀下的旧通知，避免设置变化后残留重复提醒。
    func replaceScheduledNotifications(prefix: String, notifications: [ScheduledNotification]) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
            Task { @MainActor [weak self] in
                guard let self, self.authorized else { return }
                for item in notifications {
                    let content = UNMutableNotificationContent()
                    content.title = item.title
                    content.body = item.body
                    let components = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: item.date
                    )
                    let request = UNNotificationRequest(
                        identifier: item.identifier,
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    )
                    try? await center.add(request)
                }
            }
        }
    }

    func cancelScheduledNotifications(prefix: String) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            guard !stale.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
    }
}

extension AwayNotifier: UNUserNotificationCenterDelegate {
    /// 菜单栏应用没有常规的前台状态，不实现这个回调的话横幅可能不显示。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
