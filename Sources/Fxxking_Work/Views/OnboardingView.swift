import SwiftUI

/// 首次启动引导窗口。
///
/// 设计约定（与「升级用户不弹引导」「取消不写配置」配套）：
/// - 本视图持有一份 `Configuration` 的工作副本（`@State`），**不直接写** `SettingsStore`。
/// - 只有点「完成」时才通过 `onFinish` 把最终副本交回调用方；点「跳过」或直接关窗都不会
///   写回任何配置（工作副本随视图一起销毁）。
/// - `onFinish` / `onSkip` 里是否落盘、是否标记 `onboardingCompleted`、升级用户如何判定，
///   全部由 App 入口（Lead）决定，本视图不碰持久化。
///
/// 注意：`Configuration` 是模块内部类型，因此本视图的 `init` 只能是 internal；
/// 同属一个 executable target 的 `Fxxking_WorkApp.swift` 可以直接构造。
/// 若将来要把本视图挪进独立 library，需要同时把 `Configuration` 提为 public。
public struct OnboardingView: View {
    /// 供 App 入口接窗时统一取用的推荐尺寸。
    public static let preferredSize = CGSize(width: 640, height: 520)

    /// 工作副本：所有编辑只落在内存里。
    @State private var draft: Configuration
    @State private var step: Int
    /// 只在第一次进入「隐私」这一步时把默认值改成开启，之后尊重用户的手动开关。
    @State private var appliedPrivacyDefault: Bool
    /// 保护层外的草稿快照。屏幕采集会把本视图移出视图树再换回来，
    /// 没有这份快照，用户填过的金额和当前步骤会一起丢。
    private let state: OnboardingDraftState

    private let onFinish: (Configuration) -> Void
    private let onSkip: () -> Void

    private static let totalSteps = 4
    /// 周一 … 周日，和设置页的展示顺序一致。Calendar 的 weekday 取值 1 = 周日。
    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    /// - Parameters:
    ///   - draft: 从当前配置复制出的工作副本（建议传 `settings.config` 的值，而非绑定）。
    ///   - onFinish: 用户点「完成」，携带最终工作副本；由调用方落盘并标记引导已完成。
    ///   - onSkip: 用户点「跳过」，不携带配置；由调用方决定是否标记引导已完成。
    @MainActor
    init(
        state: OnboardingDraftState,
        onFinish: @escaping (Configuration) -> Void,
        onSkip: @escaping () -> Void
    ) {
        _draft = State(initialValue: state.draft)
        _step = State(initialValue: state.step)
        _appliedPrivacyDefault = State(initialValue: state.appliedPrivacyDefault)
        self.state = state
        self.onFinish = onFinish
        self.onSkip = onSkip
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        // 每次编辑都同步到保护层外的快照（纯内存，不落盘），保护结束后按快照重建。
        .onChange(of: draft) { _, newValue in
            state.update(draft: newValue)
        }
        .onChange(of: appliedPrivacyDefault) { _, newValue in
            state.appliedPrivacyDefault = newValue
        }
        .onChange(of: step) { _, newValue in
            state.update(step: newValue)
            guard newValue == 2, !appliedPrivacyDefault else { return }
            appliedPrivacyDefault = true
            draft.privacyModeEnabled = true
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(Loc.t("onboarding.title"))
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 12)
                Text(Loc.t("onboarding.step", step + 1, Self.totalSteps))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(step + 1), total: Double(Self.totalSteps))
                .progressViewStyle(.linear)
            Text(Loc.t("onboarding.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - 内容

    @ViewBuilder
    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stepTitle)
                    .font(.headline)
                Text(stepDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch step {
            case 0: salaryStep
            case 1: scheduleStep
            case 2: privacyStep
            default: summaryStep
            }
        }
    }

    private var stepTitle: String {
        switch step {
        case 0: return Loc.t("onboarding.step.salary.title")
        case 1: return Loc.t("onboarding.step.schedule.title")
        case 2: return Loc.t("onboarding.step.privacy.title")
        default: return Loc.t("onboarding.step.summary.title")
        }
    }

    private var stepDetail: String {
        switch step {
        case 0: return Loc.t("onboarding.step.salary.detail")
        case 1: return Loc.t("onboarding.step.schedule.detail")
        case 2: return Loc.t("onboarding.step.privacy.detail")
        default: return Loc.t("onboarding.step.summary.detail")
        }
    }

    // MARK: - 第 1 步：工资与支付周期

    private var salaryStep: some View {
        VStack(spacing: 16) {
            OnboardingCard(title: Loc.t("salary.section.income"), footer: Loc.t("salary.payMonths.hint")) {
                OnboardingRow(title: Loc.t("salary.payMode")) {
                    Picker("", selection: $draft.payMode) {
                        ForEach(PayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(Loc.t("salary.payMode"))
                }
                OnboardingRow(title: Loc.t("salary.amount")) {
                    HStack(spacing: 6) {
                        TextField("", value: $draft.salaryAmount, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel(Loc.t("salary.amount"))
                        Text(draft.currencyCode)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                OnboardingRow(title: Loc.t("salary.period")) {
                    Picker("", selection: $draft.salaryPeriod) {
                        ForEach(SalaryPeriod.allCases) { period in
                            Text(period.label).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(Loc.t("salary.period"))
                }
                OnboardingRow(title: Loc.t("onboarding.payMonths")) {
                    Picker("", selection: $draft.payMonthsPerYear) {
                        ForEach(12...20, id: \.self) { months in
                            Text("\(months)").tag(months)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Loc.t("onboarding.payMonths"))
                }
                if draft.salaryAmount <= 0 {
                    Text(Loc.t("onboarding.error.salaryRequired"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            OnboardingCard(title: Loc.t("salary.section.region")) {
                OnboardingRow(title: Loc.t("salary.country")) {
                    Picker("", selection: $draft.countryCode) {
                        ForEach(CountryCatalog.allCountries()) { country in
                            Text("\(country.name) (\(country.code))").tag(country.code)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Loc.t("salary.country"))
                }
                OnboardingRow(title: Loc.t("salary.currency")) {
                    Picker("", selection: $draft.currencyCode) {
                        ForEach(CountryCatalog.allCurrencies()) { currency in
                            Text(currency.display).tag(currency.code)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Loc.t("salary.currency"))
                }
            }

            OnboardingCard(
                title: Loc.t("payroll.section"),
                footer: draft.payroll.enabled ? Loc.t("payroll.example") : nil
            ) {
                Toggle(Loc.t("payroll.enabled"), isOn: $draft.payroll.enabled)
                if draft.payroll.enabled {
                    Stepper(
                        Loc.t("payroll.cutoffDay", draft.payroll.cutoffDay),
                        value: $draft.payroll.cutoffDay, in: 1...31)
                    Stepper(
                        Loc.t("payroll.paydayDay", draft.payroll.paydayDay),
                        value: $draft.payroll.paydayDay, in: 1...31)
                    OnboardingRow(title: Loc.t("payroll.offset")) {
                        Picker("", selection: $draft.payroll.offset) {
                            Text(Loc.t("payroll.offset.sameMonth")).tag(PaydayOffset.sameMonth)
                            Text(Loc.t("payroll.offset.nextMonth")).tag(PaydayOffset.nextMonth)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel(Loc.t("payroll.offset"))
                    }
                }
            }
        }
        .onChange(of: draft.countryCode) { _, newValue in
            if let currency = CountryCatalog.defaultCurrency(for: newValue) {
                draft.currencyCode = currency
            }
        }
    }

    // MARK: - 第 2 步：工作时间与午休

    private var scheduleStep: some View {
        VStack(spacing: 16) {
            OnboardingCard(title: Loc.t("schedule.section.weekdays")) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 90), spacing: 10), count: 4),
                    spacing: 10
                ) {
                    ForEach(weekdayOrder, id: \.self) { weekday in
                        Toggle(isOn: workdayBinding(weekday)) {
                            Text(weekdaySymbol(weekday))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }

            OnboardingCard(title: Loc.t("schedule.section.hours")) {
                OnboardingRow(title: Loc.t("schedule.start")) {
                    DatePicker(
                        "", selection: timeBinding($draft.startMinutes),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .accessibilityLabel(Loc.t("schedule.start"))
                }
                OnboardingRow(title: Loc.t("schedule.end")) {
                    DatePicker(
                        "", selection: timeBinding($draft.endMinutes),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .accessibilityLabel(Loc.t("schedule.end"))
                }
                if draft.endMinutes <= draft.startMinutes {
                    Text(Loc.t("schedule.invalidRange"))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(Loc.t("schedule.breakToggle"), isOn: $draft.breakEnabled)
                if draft.breakEnabled {
                    OnboardingRow(title: Loc.t("schedule.breakStart")) {
                        DatePicker(
                            "", selection: timeBinding($draft.breakStartMinutes),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .accessibilityLabel(Loc.t("schedule.breakStart"))
                    }
                    OnboardingRow(title: Loc.t("schedule.breakEnd")) {
                        DatePicker(
                            "", selection: timeBinding($draft.breakEndMinutes),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .accessibilityLabel(Loc.t("schedule.breakEnd"))
                    }
                    if !breakRangeIsValid {
                        Text(Loc.t("onboarding.error.breakRange"))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent(Loc.t("schedule.paidPerDay"), value: paidTimeText)
            }
        }
    }

    // MARK: - 第 3 步：隐私与节假日

    private var privacyStep: some View {
        VStack(spacing: 16) {
            OnboardingCard(title: Loc.t("privacy.section")) {
                Toggle(Loc.t("privacy.toggle"), isOn: $draft.privacyModeEnabled)
                Text(Loc.t("privacy.toggle.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Loc.t("onboarding.privacy.defaultNote"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingCard(
                title: Loc.t("settings.tab.holidays"),
                footer: Loc.t("holidays.footer", GitHubHolidaysSource.attribution)
            ) {
                Toggle(Loc.t("holidays.autoToggle"), isOn: $draft.useAutoHolidays)
                Toggle(Loc.t("holidays.includeRegional"), isOn: $draft.includeRegionalHolidays)
                    .disabled(!draft.useAutoHolidays)
                Toggle(Loc.t("holidays.autoMakeup"), isOn: $draft.useAutoMakeupWorkdays)
                    .disabled(!draft.useAutoHolidays)
                Text(Loc.t("onboarding.holidays.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 第 4 步：汇总

    private var summaryStep: some View {
        OnboardingCard(title: Loc.t("onboarding.step.summary.title")) {
            OnboardingSummaryRow(
                title: Loc.t("onboarding.summary.salary"),
                value: salarySummaryText)
            OnboardingSummaryRow(
                title: Loc.t("salary.payMode"),
                value: draft.payMode.label)
            OnboardingSummaryRow(
                title: Loc.t("onboarding.summary.payroll"),
                value: payrollSummaryText)
            OnboardingSummaryRow(
                title: Loc.t("onboarding.summary.schedule"),
                value: scheduleSummaryText)
            OnboardingSummaryRow(
                title: Loc.t("privacy.section"),
                value: draft.privacyModeEnabled
                    ? Loc.t("onboarding.summary.on")
                    : Loc.t("onboarding.summary.off"))
            OnboardingSummaryRow(
                title: Loc.t("settings.tab.holidays"),
                value: draft.useAutoHolidays
                    ? Loc.t("onboarding.summary.holidays.auto")
                    : Loc.t("onboarding.summary.holidays.manual"))
            Divider()
            Text(Loc.t("onboarding.summary.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 12) {
            Button(Loc.t("onboarding.action.skip")) { onSkip() }
                .buttonStyle(.link)
            Spacer(minLength: 12)
            if step > 0 {
                Button(Loc.t("onboarding.action.back")) {
                    withAnimation(.easeInOut(duration: 0.15)) { step -= 1 }
                }
            }
            if step < Self.totalSteps - 1 {
                Button(Loc.t("onboarding.action.next")) {
                    withAnimation(.easeInOut(duration: 0.15)) { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
            } else {
                Button(Loc.t("onboarding.action.finish")) { onFinish(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - 校验

    /// 当前步骤能否前进 / 完成。第 1 步要求工资为正；第 2 步要求作息与午休区间有效。
    private var canAdvance: Bool {
        switch step {
        case 0: return draft.salaryAmount > 0
        case 1: return scheduleIsValid
        default: return true
        }
    }

    private var scheduleIsValid: Bool {
        guard draft.endMinutes > draft.startMinutes else { return false }
        guard draft.breakEnabled else { return true }
        return breakRangeIsValid
    }

    private var breakRangeIsValid: Bool {
        let start = min(draft.breakStartMinutes, draft.breakEndMinutes)
        let end = max(draft.breakStartMinutes, draft.breakEndMinutes)
        return end > start
            && start >= draft.startMinutes
            && end <= draft.endMinutes
    }

    // MARK: - 汇总文案

    private var salarySummaryText: String {
        let amount = Formatters.currency(draft.salaryAmount, code: draft.currencyCode)
        let months = Loc.t("onboarding.summary.months", draft.payMonthsPerYear)
        return "\(draft.salaryPeriod.label) \(amount) · \(months)"
    }

    private var payrollSummaryText: String {
        guard draft.payroll.enabled else {
            return Loc.t("onboarding.summary.naturalMonth")
        }
        let cutoff = Loc.t("payroll.cutoffDay", draft.payroll.cutoffDay)
        let payday = Loc.t("payroll.paydayDay", draft.payroll.paydayDay)
        return "\(cutoff) · \(payday) · \(payrollOffsetLabel)"
    }

    private var payrollOffsetLabel: String {
        switch draft.payroll.offset {
        case .sameMonth: return Loc.t("payroll.offset.sameMonth")
        case .nextMonth: return Loc.t("payroll.offset.nextMonth")
        }
    }

    private var scheduleSummaryText: String {
        let start = Formatters.clockTime(minutesFromMidnight: draft.startMinutes)
        let end = Formatters.clockTime(minutesFromMidnight: draft.endMinutes)
        let hours = "\(start)–\(end)"
        let breakText: String
        if draft.breakEnabled {
            let breakStart = Formatters.clockTime(minutesFromMidnight: draft.breakStartMinutes)
            let breakEnd = Formatters.clockTime(minutesFromMidnight: draft.breakEndMinutes)
            breakText = Loc.t("onboarding.summary.break", breakStart, breakEnd)
        } else {
            breakText = Loc.t("onboarding.summary.noBreak")
        }
        let paid = Loc.t("schedule.paidPerDay") + " " + paidTimeText
        return "\(hours) · \(breakText) · \(paid)"
    }

    private var paidTimeText: String {
        Formatters.duration(Double(draft.paidMinutesPerDay) * 60)
    }

    // MARK: - 绑定与辅助

    private func weekdaySymbol(_ weekday: Int) -> String {
        let symbols = Loc.calendar.weekdaySymbols
        return symbols[(weekday - 1) % symbols.count]
    }

    private func workdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { draft.workdays.contains(weekday) },
            set: { isOn in
                if isOn {
                    draft.workdays.insert(weekday)
                } else {
                    draft.workdays.remove(weekday)
                }
            }
        )
    }

    /// DatePicker 只认 Date，这里把「距零点多少分钟」换算成当天的一个时间点。
    private func timeBinding(_ source: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                let midnight = Calendar.current.startOfDay(for: Date())
                return Calendar.current.date(byAdding: .minute, value: source.wrappedValue, to: midnight)
                    ?? midnight
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                source.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

// MARK: - 展示组件

/// 引导页的分组卡片：标题 + 内容 + 可选脚注，沿用设置页「标签在左、控件在右」的观感。
private struct OnboardingCard<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}

/// 与 `SettingsRow` 同款：标签靠左单行，控件在右侧同宽，避免不同步骤间控件左右跳。
/// 宽度取 220，比设置页略宽，给「账期截止日：25」这类带数字的标签留余量。
private struct OnboardingRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            content
                .frame(width: 220, alignment: .trailing)
        }
    }
}

/// 汇总行：标签次要色、值右对齐且允许多行，长文案不会被截断。
private struct OnboardingSummaryRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
