import AppKit
import SwiftUI

/// 首次启动引导使用独立原生窗口。菜单栏应用没有默认主窗口，直接把 SwiftUI
/// `Window` scene 无条件塞进 SceneBuilder 会让 Swift 6 的类型检查器崩溃，因此
/// 这里用 AppKit 管理窗口生命周期，内容仍是同一份 SwiftUI 引导页。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let screenCapture: ScreenCaptureMonitor
    private let overtime: OvertimeController
    private var window: NSWindow?
    /// 引导的未提交填写。窗口内容被屏幕采集保护层换掉时，靠这份内存快照恢复。
    private var draftState: OnboardingDraftState?

    init(
        settings: SettingsStore,
        screenCapture: ScreenCaptureMonitor,
        overtime: OvertimeController
    ) {
        self.settings = settings
        self.screenCapture = screenCapture
        self.overtime = overtime
        super.init()
    }

    func showIfNeeded() {
        guard settings.needsOnboarding, window == nil else { return }
        let initial = settings.config
        let draftState = OnboardingDraftState(draft: initial)
        self.draftState = draftState
        let onboarding = OnboardingView(
            state: draftState,
            onFinish: { [weak self] completed in
                self?.finish(completed)
            },
            onSkip: { [weak self] in
                self?.settings.completeOnboarding()
                self?.close()
            }
        )
        let view = ScreenCaptureGate(showsSettingsButton: false) {
            onboarding
        }
        .environmentObject(settings)
        .environmentObject(screenCapture)
        .environmentObject(overtime)
        .environment(\.locale, Loc.locale)
        .preferredColorScheme(initial.appearance.colorScheme)

        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.preferredSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Loc.t("onboarding.window")
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.level = .normal
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        draftState = nil
    }

    private func finish(_ completed: Configuration) {
        // 引导窗与菜单栏设置可以同时打开。以最新配置为底，只合并引导实际
        // 编辑的字段，避免用展示时的旧快照覆盖掉其他并发修改。
        var final = settings.config
        final.salaryAmount = completed.salaryAmount
        final.salaryPeriod = completed.salaryPeriod
        final.payMonthsPerYear = completed.payMonthsPerYear
        final.currencyCode = completed.currencyCode
        final.countryCode = completed.countryCode
        final.payMode = completed.payMode
        final.payroll.enabled = completed.payroll.enabled
        final.payroll.cutoffDay = completed.payroll.cutoffDay
        final.payroll.paydayDay = completed.payroll.paydayDay
        final.payroll.offset = completed.payroll.offset
        final.workdays = completed.workdays
        final.startMinutes = completed.startMinutes
        final.endMinutes = completed.endMinutes
        final.breakEnabled = completed.breakEnabled
        final.breakStartMinutes = completed.breakStartMinutes
        final.breakEndMinutes = completed.breakEndMinutes
        final.useAutoHolidays = completed.useAutoHolidays
        final.includeRegionalHolidays = completed.includeRegionalHolidays
        final.useAutoMakeupWorkdays = completed.useAutoMakeupWorkdays
        final.privacyModeEnabled = completed.privacyModeEnabled
        final.onboardingCompleted = true
        settings.config = final
        close()
    }
}

/// 把配置里的外观选择映射成 SwiftUI 的配色偏好，模型层本身不依赖 SwiftUI。
extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
