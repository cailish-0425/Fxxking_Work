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
    @StateObject private var screenCapture: ScreenCaptureMonitor
    @StateObject private var paydayReminders: PaydayReminderService
    /// 面板交互状态（理由会话 / 明细展开）放在保护层之外：
    /// 屏幕采集期间内容整体移出视图树，这些状态不跟着销毁。
    @StateObject private var panel = PanelUIState()
    /// 设置窗口的页签与草稿同样放保护层外：短采集不会把页签弹回去、也不会丢未保存的工资变更。
    @StateObject private var settingsUI = SettingsUIState()
    /// 请假 / 加班编辑器里未保存的输入（只存内存，不落盘）：保护期间视图被移出视图树，
    /// 草稿留在这里，回到内容态后编辑器可以按原样重新打开。
    @StateObject private var drafts = EditingDraftStore()
    private let onboardingWindow: OnboardingWindowController

    init() {
        let settings = SettingsStore()
        let holidays = HolidayService()
        let ticker = EarningsTicker(settings: settings, holidays: holidays)
        let privacy = PrivacyController(enabled: settings.config.privacyModeEnabled)
        privacy.bind(to: settings)
        let overtime = OvertimeController(settings: settings) { ticker.engine }
        let updater = UpdaterService()
        let screenCapture = ScreenCaptureMonitor()
        let paydayReminders = PaydayReminderService(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _holidays = StateObject(wrappedValue: holidays)
        _ticker = StateObject(wrappedValue: ticker)
        _privacy = StateObject(wrappedValue: privacy)
        _overtime = StateObject(wrappedValue: overtime)
        _updater = StateObject(wrappedValue: updater)
        _screenCapture = StateObject(wrappedValue: screenCapture)
        _paydayReminders = StateObject(wrappedValue: paydayReminders)
        let onboardingWindow = OnboardingWindowController(
            settings: settings,
            screenCapture: screenCapture,
            overtime: overtime
        )
        self.onboardingWindow = onboardingWindow
        screenCapture.start()
        DispatchQueue.main.async {
            onboardingWindow.showIfNeeded()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ScreenCaptureGate {
                MenuContentView()
            }
                .environmentObject(settings)
                .environmentObject(holidays)
                .environmentObject(ticker)
                .environmentObject(privacy)
                .environmentObject(overtime)
                .environmentObject(screenCapture)
                .environmentObject(panel)
                .environmentObject(drafts)
                // DatePicker、日历这些系统控件自己排版，得把语言选择也交给它们。
                .environment(\.locale, Loc.locale)
                .preferredColorScheme(settings.config.appearance.colorScheme)
                .background(MenuBarPanelVisibility(
                    onClose: {
                        privacy.resetForLifecycle()
                        // 只有面板真正收起才复位交互状态；被保护层换掉时不能复位，
                        // 否则每次截图都会把"理由读到一半 / 明细展开"清空。
                        panel.resetForPanelClose()
                    }
                ))
                .onDisappear { privacy.resetForLifecycle() }
                .onChange(of: screenCapture.state) { _, state in
                    // `pending` 起就清除临时揭示：短采集也可能紧接持续共享，保护结束后
                    // 绝不能自动把之前揭示过的金额重新露出来，必须由用户重新点击。
                    let presentation = ScreenCaptureProtectionPolicy.presentation(for: state)
                    if ScreenCaptureProtectionPolicy.shouldResetReveal(onEntering: presentation) {
                        privacy.resetForLifecycle()
                    }
                    if presentation == .content {
                        panel.restoreAfterProtection()
                    }
                }
        } label: {
            // 用独立 Observable 视图：privacy 的 @Published 变化要立刻反映到标题，
            // 而不是等 ticker 下一秒推快照才顺带更新。
            MenuBarTitleView(
                config: settings.config,
                earnings: ticker.earnings,
                privacy: privacy,
                screenCapture: screenCapture
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            ScreenCaptureGate(showsSettingsButton: false) {
                SettingsView()
            }
                .environmentObject(settings)
                .environmentObject(holidays)
                .environmentObject(ticker)
                .environmentObject(privacy)
                .environmentObject(overtime)
                .environmentObject(updater)
                .environmentObject(screenCapture)
                .environmentObject(settingsUI)
                .environmentObject(drafts)
                .environment(\.locale, Loc.locale)
                .preferredColorScheme(settings.config.appearance.colorScheme)
                .onDisappear {
                    privacy.resetForLifecycle()
                    // 只有设置窗口真正关闭才丢弃页签与草稿。
                    settingsUI.resetForWindowClose()
                }
                .onChange(of: screenCapture.state) { _, state in
                    // 保护结束后把未提交的工资变更草稿和原页签接回来；
                    // 金额本身仍按保护前的揭示状态保持隐藏（不自动重显）。
                    let presentation = ScreenCaptureProtectionPolicy.presentation(for: state)
                    if ScreenCaptureProtectionPolicy.shouldResetReveal(onEntering: presentation) {
                        privacy.resetForLifecycle()
                    }
                    if presentation == .content {
                        settingsUI.restoreAfterProtection()
                    }
                }
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
    @ObservedObject var screenCapture: ScreenCaptureMonitor

    var body: some View {
        let protected = privacy.enabled || screenCapture.state.hidesAmounts
        let text = MenuBarLabel.text(
            config: config,
            earnings: earnings,
            privacyEnabled: protected,
            isRevealed: screenCapture.state == .inactive
                && (MenuBarLabel.surface(for: config.menuBarDisplay)
                    .map { privacy.isRevealed($0) } ?? false)
        )
        if config.showMenuBarIcon {
            Text("\(Image(systemName: "dollarsign.circle.fill")) \(text)")
        } else {
            Text(text)
        }
    }
}
