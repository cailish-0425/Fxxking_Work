import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            TabView {
                SalaryTab()
                    .tabItem { Label(Loc.t("settings.tab.salary"), systemImage: "creditcard") }
                ScheduleTab()
                    .tabItem { Label(Loc.t("settings.tab.schedule"), systemImage: "clock") }
                HolidayTab()
                    .tabItem { Label(Loc.t("settings.tab.holidays"), systemImage: "calendar") }
                DisplayTab()
                    .tabItem { Label(Loc.t("settings.tab.display"), systemImage: "menubar.rectangle") }
                AboutTab()
                    .tabItem { Label(Loc.t("settings.tab.about"), systemImage: "info.circle") }
            }

            Divider()
            signature
        }
        .frame(width: 500, height: 460)
    }

    /// 统一底部署名：所有页签最底部都可见维护者 handle。
    private var signature: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("@cailish-0425")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 版本说明

private struct AboutTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent(Loc.t("about.name"), value: "Fxxking Work")
                LabeledContent(Loc.t("about.version"), value: versionText)
                LabeledContent(Loc.t("about.maintainer"), value: "@cailish-0425")
            } header: {
                Text(Loc.t("about.section.app"))
            }

            Section {
                Text(Loc.t("about.summary"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(Loc.t("about.section.changes"))
            }

            Section {
                Link(Loc.t("about.github"), destination: githubURL)
            } header: {
                Text(Loc.t("about.section.links"))
            }
        }
        .formStyle(.grouped)
    }

    /// 版本 / 构建号，从实际 Bundle 读取；缺失时回退占位符。
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return build.isEmpty || build == version ? version : "\(version) (\(build))"
    }

    private var githubURL: URL {
        URL(string: "https://github.com/cailish-0425/Fxxking_Work") ?? URL(string: "https://github.com")!
    }
}

// MARK: - 薪资

private struct SalaryTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ticker: EarningsTicker

    var body: some View {
        Form {
            Section {
                TextField(Loc.t("salary.amount"), value: $settings.config.salaryAmount, format: .number)
                    .multilineTextAlignment(.trailing)
                Picker(Loc.t("salary.period"), selection: $settings.config.salaryPeriod) {
                    ForEach(SalaryPeriod.allCases) { Text($0.label).tag($0) }
                }
                Stepper(
                    Loc.t("salary.payMonths", settings.config.payMonthsPerYear),
                    value: $settings.config.payMonthsPerYear,
                    in: 12...20
                )
                Text(Loc.t("salary.payMonths.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(Loc.t("salary.section.income"))
            }

            Section {
                Picker(Loc.t("salary.country"), selection: $settings.config.countryCode) {
                    ForEach(CountryCatalog.allCountries()) { country in
                        Text("\(country.name) (\(country.code))").tag(country.code)
                    }
                }
                Picker(Loc.t("salary.currency"), selection: $settings.config.currencyCode) {
                    ForEach(CountryCatalog.allCurrencies()) { currency in
                        Text(currency.display).tag(currency.code)
                    }
                }
            } header: {
                Text(Loc.t("salary.section.region"))
            }

            Section {
                LabeledContent(Loc.t("salary.workdaysThisMonth"), value: Loc.t("menu.days", ticker.engine.workdaysThisMonth))
                LabeledContent(
                    Loc.t("salary.perDay"),
                    value: Formatters.currency(
                        ticker.earnings.dayTotal > 0 ? ticker.earnings.dayTotal : dailyEstimate, code: settings.config.currencyCode))
                LabeledContent(
                    Loc.t("salary.perHour"),
                    value: Formatters.currency(ticker.engine.perSecondRate * 3600, code: settings.config.currencyCode))
                LabeledContent(
                    Loc.t("salary.perSecond"),
                    value: Formatters.currency(ticker.engine.perSecondRate, code: settings.config.currencyCode, fractionDigits: 4))
            } header: {
                Text(Loc.t("salary.section.derived"))
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.config.countryCode) { _, newValue in
            if let currency = CountryCatalog.defaultCurrency(for: newValue) {
                settings.config.currencyCode = currency
            }
        }
    }

    private var dailyEstimate: Double {
        let days = ticker.engine.workdaysThisMonth
        return days > 0 ? settings.config.monthlyPay / Double(days) : 0
    }
}

// MARK: - 工时

private struct ScheduleTab: View {
    @EnvironmentObject private var settings: SettingsStore

    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        Form {
            Section {
                ForEach(weekdayOrder, id: \.self) { weekday in
                    Toggle(weekdaySymbol(weekday), isOn: workdayBinding(weekday))
                }
            } header: {
                Text(Loc.t("schedule.section.weekdays"))
            }

            Section {
                DatePicker(
                    Loc.t("schedule.start"), selection: timeBinding($settings.config.startMinutes),
                    displayedComponents: .hourAndMinute)
                DatePicker(
                    Loc.t("schedule.end"), selection: timeBinding($settings.config.endMinutes),
                    displayedComponents: .hourAndMinute)
                Toggle(Loc.t("schedule.breakToggle"), isOn: $settings.config.breakEnabled)
                if settings.config.breakEnabled {
                    DatePicker(
                        Loc.t("schedule.breakStart"), selection: timeBinding($settings.config.breakStartMinutes),
                        displayedComponents: .hourAndMinute)
                    DatePicker(
                        Loc.t("schedule.breakEnd"), selection: timeBinding($settings.config.breakEndMinutes),
                        displayedComponents: .hourAndMinute)
                }
                LabeledContent(Loc.t("schedule.paidPerDay"), value: durationText)
            } header: {
                Text(Loc.t("schedule.section.hours"))
            }
        }
        .formStyle(.grouped)
    }

    private var durationText: String {
        Formatters.duration(Double(settings.config.paidMinutesPerDay) * 60)
    }

    private func weekdaySymbol(_ weekday: Int) -> String {
        let symbols = Loc.calendar.weekdaySymbols
        return symbols[(weekday - 1) % symbols.count]
    }

    private func workdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { settings.config.workdays.contains(weekday) },
            set: { isOn in
                if isOn {
                    settings.config.workdays.insert(weekday)
                } else {
                    settings.config.workdays.remove(weekday)
                }
            }
        )
    }
}

// MARK: - 假日

private struct HolidayTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var holidays: HolidayService
    @EnvironmentObject private var ticker: EarningsTicker

    @State private var newHoliday = Date()
    @State private var newMakeup = Date()

    var body: some View {
        Form {
            Section {
                Toggle(Loc.t("holidays.autoToggle"), isOn: $settings.config.useAutoHolidays)
                Toggle(Loc.t("holidays.includeRegional"), isOn: $settings.config.includeRegionalHolidays)
                    .disabled(!settings.config.useAutoHolidays)
                Toggle(Loc.t("holidays.autoMakeup"), isOn: $settings.config.useAutoMakeupWorkdays)
                    .disabled(!settings.config.useAutoHolidays)
                HStack {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(Loc.t("holidays.refresh")) { ticker.refreshHolidays(force: true) }
                }
                if !upcoming.isEmpty {
                    ForEach(upcoming) { holiday in
                        LabeledContent(holiday.date, value: holiday.localName)
                            .font(.caption)
                    }
                }
            } header: {
                Text(Loc.t("holidays.section.title", CountryCatalog.name(for: settings.config.countryCode)))
            } footer: {
                Text(Loc.t("holidays.footer", GitHubHolidaysSource.attribution))
                    .font(.caption2)
            }

            dateListSection(
                title: Loc.t("holidays.extra.title"),
                hint: Loc.t("holidays.extra.hint"),
                selection: $newHoliday,
                dates: $settings.config.extraHolidays
            )

            dateListSection(
                title: Loc.t("holidays.makeup.title"),
                hint: Loc.t("holidays.makeup.hint"),
                selection: $newMakeup,
                dates: $settings.config.makeupWorkdays,
                automatic: upcomingMakeup
            )
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch holidays.status {
        case .idle:
            return Loc.t("holidays.status.idle")
        case .loading:
            return Loc.t("holidays.status.loading")
        case .loaded(let fromCache):
            // 写成两条字面量而不是拼 key，提取工具才能看见它们。
            return fromCache
                ? Loc.t("holidays.status.loadedCached", holidays.holidays.count)
                : Loc.t("holidays.status.loaded", holidays.holidays.count)
        case .unsupportedCountry:
            return Loc.t("holidays.status.unsupported")
        case .failed(let message):
            return Loc.t("holidays.status.failed", message)
        }
    }

    private var upcoming: [PublicHoliday] {
        holidays.upcoming(from: DayKeyCoder.current.key(for: Date()), limit: 6)
    }

    /// 数据源推断出来的补班日，摆出来让用户能核对，而不是默默改了工作日。
    private var upcomingMakeup: [String] {
        guard settings.config.useAutoHolidays, settings.config.useAutoMakeupWorkdays else { return [] }
        let today = DayKeyCoder.current.key(for: Date())
        return holidays.makeupWorkdays
            .filter { $0 >= today && !settings.config.makeupWorkdays.contains($0) }
            .sorted()
            .prefix(6)
            .map { $0 }
    }

    private func dateListSection(
        title: String,
        hint: String,
        selection: Binding<Date>,
        dates: Binding<Set<String>>,
        automatic: [String] = []
    ) -> some View {
        Section {
            HStack {
                DatePicker("", selection: selection, displayedComponents: .date)
                    .labelsHidden()
                Button(Loc.t("holidays.add")) {
                    dates.wrappedValue.insert(DayKeyCoder.current.key(for: selection.wrappedValue))
                }
            }
            ForEach(automatic, id: \.self) { key in
                HStack {
                    Text(key).font(.caption).monospacedDigit()
                    Spacer()
                    Text(Loc.t("holidays.auto.tag")).font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            ForEach(dates.wrappedValue.sorted(), id: \.self) { key in
                HStack {
                    Text(key).font(.caption).monospacedDigit()
                    Spacer()
                    Button {
                        dates.wrappedValue.remove(key)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(hint).font(.caption2)
        }
    }
}

// MARK: - 显示

private struct DisplayTab: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Picker(Loc.t("display.menuBar"), selection: $settings.config.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.label).tag($0) }
                }
                Toggle(Loc.t("display.showIcon"), isOn: $settings.config.showMenuBarIcon)
                Toggle(Loc.t("display.showSnark"), isOn: $settings.config.snarkEnabled)
                Toggle(Loc.t("display.awayAlert"), isOn: $settings.config.awayAlertEnabled)
                Text(Loc.t("display.awayAlert.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(Loc.t("display.section.appearance"))
            }

            Section {
                Picker(Loc.t("display.language"), selection: $settings.config.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
            } header: {
                Text(Loc.t("display.section.language"))
            }

            Section {
                Toggle(Loc.t("display.launchAtLogin"), isOn: $launchAtLogin)
                if let launchError {
                    Text(launchError).font(.caption2).foregroundStyle(.orange)
                }
            } header: {
                Text(Loc.t("display.section.startup"))
            }

            Section {
                Button(Loc.t("display.reset"), role: .destructive) {
                    settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: launchAtLogin) { _, newValue in
            do {
                launchError = nil
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchError = Loc.t("display.launchError", error.localizedDescription)
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}

// MARK: - 时间绑定

/// DatePicker 只认 Date，这里把"距零点多少分钟"换算成当天的一个时间点。
private func timeBinding(_ source: Binding<Int>) -> Binding<Date> {
    Binding(
        get: {
            let midnight = Calendar.current.startOfDay(for: Date())
            return Calendar.current.date(byAdding: .minute, value: source.wrappedValue, to: midnight) ?? midnight
        },
        set: { newValue in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            source.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    )
}
