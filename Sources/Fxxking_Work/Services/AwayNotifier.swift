import Foundation
import UserNotifications

/// 解锁后发一条系统通知。
///
/// 授权被拒、系统开着专注模式、或者应用没有正常的 bundle 标识时都会静默失败——
/// 这是有意的，面板里那张卡片才是兜底，通知只是锦上添花，不该因为发不出去就打扰用户。
@MainActor
final class AwayNotifier: NSObject {
    static let shared = AwayNotifier()

    private var authorized = false
    private var didRequest = false

    /// 没有 bundle 标识时 UNUserNotificationCenter.current() 会直接崩，命令行跑断言时就是这种情况。
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func prepare() {
        guard isAvailable, !didRequest else { return }
        didRequest = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
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
