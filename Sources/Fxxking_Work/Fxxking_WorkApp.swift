import SwiftUI

@main
struct Fxxking_WorkApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var holidays: HolidayService
    @StateObject private var ticker: EarningsTicker

    init() {
        let settings = SettingsStore()
        let holidays = HolidayService()
        let ticker = EarningsTicker(settings: settings, holidays: holidays)
        _settings = StateObject(wrappedValue: settings)
        _holidays = StateObject(wrappedValue: holidays)
        _ticker = StateObject(wrappedValue: ticker)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(settings)
                .environmentObject(holidays)
                .environmentObject(ticker)
                // DatePicker、日历这些系统控件自己排版，得把语言选择也交给它们。
                .environment(\.locale, Loc.locale)
        } label: {
            let text = MenuBarLabel.text(config: settings.config, earnings: ticker.earnings)
            if settings.config.showMenuBarIcon {
                Text("\(Image(systemName: "dollarsign.circle.fill")) \(text)")
            } else {
                Text(text)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(holidays)
                .environmentObject(ticker)
                .environment(\.locale, Loc.locale)
        }
    }
}

enum MenuBarLabel {
    static func text(config: Configuration, earnings: Earnings) -> String {
        switch config.menuBarDisplay {
        case .todayAmount:
            return Formatters.currency(earnings.dayEarned, code: config.currencyCode)
        case .todayPercent:
            return Formatters.percent(earnings.dayFraction, fractionDigits: 1)
        case .monthAmount:
            return Formatters.currency(earnings.monthEarned, code: config.currencyCode, fractionDigits: 0)
        case .monthPercent:
            return Formatters.percent(earnings.monthFraction, fractionDigits: 1)
        case .yearPercent:
            return Formatters.percent(earnings.yearFraction, fractionDigits: 1)
        }
    }
}
