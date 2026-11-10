import AppKit
import Combine
import Foundation

/// 隐私模式的会话级状态：统一管理金额的「默认掩码 / 点击临时显示」。
///
/// - 开关 `enabled` 来自持久化配置（Configuration.privacyModeEnabled）。
/// - 临时揭示是整块面板的统一状态：点击任意金额会一次露出全部金额，再点任意金额统一收起；
///   不持久化，关面板/窗口、切换其他 app、超时、重启后自动回到隐藏。
/// - 真实 ticker 全程继续运行，揭示态展示的是实时 snapshot，不冻结、不重算、不伪造。
@MainActor
final class PrivacyController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isRevealed = false

    private var settings: SettingsStore?
    private var cancellables = Set<AnyCancellable>()
    private var autoHideTask: Task<Void, Never>?
    nonisolated(unsafe) private var appDeactivateObserver: NSObjectProtocol?
    private static let autoHideSeconds: Double = 30

    init(enabled: Bool = false) {
        self.enabled = enabled
        // 切换其他 app / 面板关闭导致的失活：真正按 app 生命周期清除临时揭示（onDisappear 不等于失活）。
        appDeactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetForLifecycle() }
        }
    }

    deinit {
        if let observer = appDeactivateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func bind(to settings: SettingsStore) {
        guard self.settings == nil else { return }
        self.settings = settings
        self.enabled = settings.config.privacyModeEnabled
        settings.$config
            .map(\.privacyModeEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newValue in
                guard let self else { return }
                self.enabled = newValue
                if !newValue { self.isRevealed = false }
            }
            .store(in: &cancellables)
    }

    func isRevealed(_ surface: String) -> Bool {
        enabled && isRevealed
    }

    /// 点击任意一处金额：整块面板统一显示；再次点击任意一处统一隐藏。
    func toggle(_ surface: String) {
        guard enabled else { return }
        isRevealed.toggle()
        if isRevealed {
            scheduleAutoHide()
        } else {
            cancelAutoHide()
        }
    }

    /// 输入类金额：点一处后整块面板统一揭示，之后由超时/离开/失活隐藏。
    func reveal(_ surface: String) {
        guard enabled else { return }
        isRevealed = true
        scheduleAutoHide()
    }

    /// 生命周期回调：面板/窗口真正消失或 app 失活时清除全部临时揭示。
    func resetForLifecycle() {
        isRevealed = false
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoHideSeconds))
            guard let self, !Task.isCancelled else { return }
            self.isRevealed = false
        }
    }
}
