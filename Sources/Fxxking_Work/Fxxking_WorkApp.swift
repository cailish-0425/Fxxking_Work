import AppKit
import SwiftUI

@main
struct Fxxking_WorkApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var holidays: HolidayService
    @StateObject private var ticker: EarningsTicker
    @StateObject private var privacy: PrivacyController
    @StateObject private var overtime: OvertimeController
    @StateObject private var updater: UpdaterService

    init() {
        let settings = SettingsStore()
        let holidays = HolidayService()
        let ticker = EarningsTicker(settings: settings, holidays: holidays)
        let privacy = PrivacyController(enabled: settings.config.privacyModeEnabled)
        privacy.bind(to: settings)
        let overtime = OvertimeController(settings: settings) { ticker.engine }
        let updater = UpdaterService()
        _settings = StateObject(wrappedValue: settings)
        _holidays = StateObject(wrappedValue: holidays)
        _ticker = StateObject(wrappedValue: ticker)
        _privacy = StateObject(wrappedValue: privacy)
        _overtime = StateObject(wrappedValue: overtime)
        _updater = StateObject(wrappedValue: updater)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(settings)
                .environmentObject(holidays)
                .environmentObject(ticker)
                .environmentObject(privacy)
                .environmentObject(overtime)
                // DatePicker、日历这些系统控件自己排版，得把语言选择也交给它们。
                .environment(\.locale, Loc.locale)
                .preferredColorScheme(settings.config.appearance.colorScheme)
                .background(MenuBarPanelVisibility(
                    onClose: { privacy.resetForLifecycle() }
                ))
                .onDisappear { privacy.resetForLifecycle() }
        } label: {
            // 用独立 Observable 视图：privacy 的 @Published 变化要立刻反映到标题，
            // 而不是等 ticker 下一秒推快照才顺带更新。
            MenuBarTitleView(config: settings.config, earnings: ticker.earnings, privacy: privacy)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(holidays)
                .environmentObject(ticker)
                .environmentObject(privacy)
                .environmentObject(overtime)
                .environmentObject(updater)
                .environment(\.locale, Loc.locale)
                .preferredColorScheme(settings.config.appearance.colorScheme)
                .onDisappear { privacy.resetForLifecycle() }
        }
    }
}

/// 菜单栏标题视图。
///
/// `MenuBarExtra` 的 label 里直接读 `privacy.isRevealed(...)` 是不够的：label 不是
/// `PrivacyController` 的观察者，揭示状态变了不会触发重绘，标题要等到 ticker 下一轮
/// 每秒刷新才更新（甚至在 ticker 不推进时永远不变）。这里把 privacy 作为
/// `@ObservedObject`，让统一揭示状态的变化直接驱动标题重建。
private struct MenuBarTitleView: View {
    let config: Configuration
    let earnings: Earnings
    @ObservedObject var privacy: PrivacyController

    var body: some View {
        let text = MenuBarLabel.text(
            config: config,
            earnings: earnings,
            privacyEnabled: privacy.enabled,
            isRevealed: MenuBarLabel.surface(for: config.menuBarDisplay)
                .map { privacy.isRevealed($0) } ?? false
        )
        if config.showMenuBarIcon {
            Text("\(Image(systemName: "dollarsign.circle.fill")) \(text)")
        } else {
            Text(text)
        }
    }
}

/// 把配置里的外观选择映射成 SwiftUI 的配色偏好，模型层本身不依赖 SwiftUI。
private extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
