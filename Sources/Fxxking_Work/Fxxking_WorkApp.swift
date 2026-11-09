import SwiftUI

@main
struct Fxxking_WorkApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var holidays: HolidayService
    @StateObject private var ticker: EarningsTicker
    @StateObject private var privacy: PrivacyController
    @StateObject private var overtime: OvertimeController

    init() {
        let settings = SettingsStore()
        let holidays = HolidayService()
        let ticker = EarningsTicker(settings: settings, holidays: holidays)
        let privacy = PrivacyController(enabled: settings.config.privacyModeEnabled)
        privacy.bind(to: settings)
        let overtime = OvertimeController(settings: settings) { ticker.engine }
        _settings = StateObject(wrappedValue: settings)
        _holidays = StateObject(wrappedValue: holidays)
        _ticker = StateObject(wrappedValue: ticker)
        _privacy = StateObject(wrappedValue: privacy)
        _overtime = StateObject(wrappedValue: overtime)
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
                .onDisappear { privacy.resetForLifecycle() }
        } label: {
            let text = MenuBarLabel.text(config: settings.config, earnings: ticker.earnings, privacy: privacy)
            let suffix = MenuBarLabel.modeSuffix(config: settings.config, engine: ticker.engine)
            if settings.config.showMenuBarIcon {
                Text("\(Image(systemName: "dollarsign.circle.fill")) \(text)\(suffix)")
            } else {
                Text("\(text)\(suffix)")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(holidays)
                .environmentObject(ticker)
                .environmentObject(privacy)
                .environmentObject(overtime)
                .environment(\.locale, Loc.locale)
                .preferredColorScheme(settings.config.appearance.colorScheme)
                .onDisappear { privacy.resetForLifecycle() }
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

enum MenuBarLabel {
    @MainActor
    static func text(config: Configuration, earnings: Earnings, privacy: PrivacyController) -> String {
        let raw: String
        switch config.menuBarDisplay {
        case .todayAmount:
            raw = Formatters.currency(earnings.dayEarned, code: config.currencyCode)
        case .todayPercent:
            raw = Formatters.percent(earnings.dayFraction, fractionDigits: 1)
        case .monthAmount:
            raw = Formatters.currency(earnings.monthEarned, code: config.currencyCode, fractionDigits: 0)
        case .monthPercent:
            raw = Formatters.percent(earnings.monthFraction, fractionDigits: 1)
        case .yearPercent:
            raw = Formatters.percent(earnings.yearFraction, fractionDigits: 1)
        }
        // 隐私模式：菜单栏标题在打开面板前就能看见，金额必须掩码。
        // 菜单栏无点击揭示交互，开启隐私即恒定掩码金额（百分比/进度非金额不掩）。
        let isAmount = config.menuBarDisplay == .todayAmount
            || config.menuBarDisplay == .monthAmount
        if privacy.enabled, isAmount {
            return "••••"
        }
        return raw
    }

    /// 税后口径标识：net 生效标「税后」；请求 net 但被阻塞（显示的是税前）标「税前」，避免静默回退。
    static func modeSuffix(config: Configuration, engine: EarningsEngine) -> String {
        guard config.payMode == .net else { return "" }
        return engine.isNetActive ? Loc.t("menu.mode.net") : Loc.t("menu.mode.gross")
    }
}
