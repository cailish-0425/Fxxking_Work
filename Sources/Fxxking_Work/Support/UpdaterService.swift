import Combine
import Foundation
import Sparkle

/// Sparkle 更新器的薄封装。
///
/// 只做三件事：持有 `SPUStandardUpdaterController`、把 `canCheckForUpdates` 暴露给 SwiftUI、
/// 把「自动检查」开关转发给官方 updater。真正的检查、下载、签名校验、安装全部由 Sparkle
/// 自己完成，这里不重写任何更新逻辑，也不碰安装包。
///
/// 启动策略：`startingUpdater: false` + 在 `start()` 里显式启动。这样在 Info.plist 缺
/// `SUPublicEDKey` / `SUFeedURL` 时可以直接不启动，避免 Sparkle 自己弹「请联系开发者」的
/// 半残提示——构建脚本也要求明确失败，不允许发出一个配置不全的更新器。
@MainActor
final class UpdaterService: NSObject, ObservableObject {
    /// 「检查更新…」按钮是否可点。由 Sparkle 通过 KVO 驱动，检查期间自动变 false。
    @Published private(set) var canCheckForUpdates = false
    /// 自动检查开关。默认关；用户打开后写回 Sparkle 自己的持久化设置。
    @Published var automaticallyChecksForUpdates = false
    /// 配置不完整时的可读说明；非 nil 时不启动更新器，界面直接展示这一条。
    @Published private(set) var configurationIssue: String?

    private var controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// Info.plist 里必需的两个键，缺一不可。
    static let requiredInfoKeys = ["SUFeedURL", "SUPublicEDKey"]

    /// 配置来源。生产路径读 `Bundle.main`；测试/隔离 fixture 可以塞一份字典进来，
    /// 从而在不改真实 Info.plist 的前提下验证「缺键 → 不启动」这条分支。
    private let infoOverride: [String: Any]?

    override convenience init() {
        self.init(infoOverride: nil)
    }

    init(infoOverride: [String: Any]?) {
        self.infoOverride = infoOverride
        super.init()
        start()
    }

    /// 启动更新器；配置不全时只记录原因，不调用 Sparkle 的 startUpdater。
    func start() {
        guard !started else { return }
        if let missing = Self.missingInfoKeys(in: infoOverride ?? Bundle.main.infoDictionary) {
            configurationIssue = Loc.t("about.updater.unconfigured", missing)
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        started = true

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)

        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self, self.automaticallyChecksForUpdates != value else { return }
                self.automaticallyChecksForUpdates = value
            }
            .store(in: &cancellables)

        controller.startUpdater()
    }

    /// 用户点「检查更新…」。网络错误、没有更新、下载进度全部交给官方 UI。
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// 把开关写回 Sparkle；写之前先和当前值比对，避免自触发循环。
    func setAutomaticallyChecks(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        guard updater.automaticallyChecksForUpdates != enabled else { return }
        updater.automaticallyChecksForUpdates = enabled
    }

    /// 返回缺失的 Info.plist 键（逗号分隔），全部存在时返回 nil。
    ///
    /// 抽成接收字典的纯函数，便于在没有 AppKit 运行环境时直接断言。
    static func missingInfoKeys(in info: [String: Any]?) -> String? {
        let missing = requiredInfoKeys.filter {
            let value = info?[$0] as? String
            return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return missing.isEmpty ? nil : missing.joined(separator: ", ")
    }

}
