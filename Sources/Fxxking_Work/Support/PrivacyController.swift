import AppKit
import Combine
import Foundation

/// 隐私模式的会话级状态：统一管理金额的「默认掩码 / 点击临时显示」。
///
/// - 开关 `enabled` 来自持久化配置（Configuration.privacyModeEnabled）。
/// - 临时揭示按「表面 ID」记录，只揭示用户点击的那一处/分组，绝不全局一次性露出所有金额；
///   不持久化，关面板/窗口、切换其他 app、超时、重启后自动回到隐藏。
/// - 真实 ticker 全程继续运行，揭示态展示的是实时 snapshot，不冻结、不重算、不伪造。
@MainActor
final class PrivacyController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var revealedSurfaces: Set<String> = []

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
                if !newValue { self.revealedSurfaces.removeAll() }
            }
            .store(in: &cancellables)
    }

    func isRevealed(_ surface: String) -> Bool {
        enabled && revealedSurfaces.contains(surface)
    }

    /// 显示类金额：点击显示、再点隐藏。
    func toggle(_ surface: String) {
        guard enabled else { return }
        if revealedSurfaces.contains(surface) {
            revealedSurfaces.remove(surface)
            cancelAutoHideIfEmpty()
        } else {
            revealedSurfaces.insert(surface)
            scheduleAutoHide()
        }
    }

    /// 输入类金额：点掩码才变编辑器，之后由超时/离开/失活隐藏。
    func reveal(_ surface: String) {
        guard enabled else { return }
        revealedSurfaces.insert(surface)
        scheduleAutoHide()
    }

    /// 打开面板时揭示菜单栏当前显示的那一项金额。
    ///
    /// 幂等：已经揭示就不再重排计时，否则视图每次重建触发的 `onAppear` 都会把倒计时清零，
    /// 30 秒自动隐藏就永远不会到点。只有从「未揭示 → 揭示」才起表。
    func revealMenuBarAmount(_ display: MenuBarDisplay) {
        guard enabled, let surface = MenuBarLabel.surface(for: display) else { return }
        guard !revealedSurfaces.contains(surface) else { return }
        revealedSurfaces.insert(surface)
        scheduleAutoHide()
    }

    /// 生命周期回调：面板/窗口真正消失或 app 失活时清除全部临时揭示。
    func resetForLifecycle() {
        revealedSurfaces.removeAll()
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func cancelAutoHideIfEmpty() {
        if revealedSurfaces.isEmpty {
            autoHideTask?.cancel()
            autoHideTask = nil
        }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoHideSeconds))
            guard let self, !Task.isCancelled else { return }
            self.revealedSurfaces.removeAll()
        }
    }
}
