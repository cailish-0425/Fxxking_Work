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
                TaxTab()
                    .tabItem { Label(Loc.t("salary.tax.section"), systemImage: "percent") }
                AboutTab()
                    .tabItem { Label(Loc.t("settings.tab.about"), systemImage: "info.circle") }
            }

            Divider()
            signature
        }
        .frame(minWidth: 500, minHeight: 480)
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
    @EnvironmentObject private var privacy: PrivacyController

    @State private var showingEditor = false
    @State private var editingVersion: SalaryVersion?
    @State private var undo: SalaryHistoryUndo?
    @State private var showingOvertimeHistory = false
    /// 低频分组默认收起，主屏只留金额、模式、地区与换算结果。
    @State private var showingHistory = false
    @State private var showingOvertimeSettings = false

    var body: some View {
        Form {
            Section {
                Picker(Loc.t("salary.payMode"), selection: $settings.config.payMode) {
                    ForEach(PayMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                SettingsRow(title: Loc.t("salary.amount")) {
                    PrivacyAmountField(
                        surface: "salary.amount",
                        label: Loc.t("salary.amount"),
                        yuan: $settings.config.salaryAmount)
                        .multilineTextAlignment(.trailing)
                }
                SettingsRow(title: Loc.t("salary.period")) {
                    Picker("", selection: $settings.config.salaryPeriod) {
                        ForEach(SalaryPeriod.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    // 标签已由 SettingsRow 单独渲染，这里补回辅助名称，否则 AX 读不到「计薪周期」。
                    .accessibilityLabel(Loc.t("salary.period"))
                }
                Stepper(value: $settings.config.payMonthsPerYear, in: 12...20) {
                    Text(Loc.t("salary.payMonths", settings.config.payMonthsPerYear))
                }
            } header: {
                Text(Loc.t("salary.section.income"))
            } footer: {
                Text(Loc.t("salary.payMonths.hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                LabeledContent(Loc.t("salary.perDay")) {
                    PrivacyAmount(surface: "salary.perDay") {
                        Formatters.currency(
                            ticker.earnings.dayTotal > 0 ? ticker.earnings.dayTotal : dailyEstimate,
                            code: settings.config.currencyCode)
                    }
                }
                LabeledContent(Loc.t("salary.perHour")) {
                    PrivacyAmount(surface: "salary.perHour") {
                        Formatters.currency(ticker.engine.perSecondRate * 3600, code: settings.config.currencyCode)
                    }
                }
                LabeledContent(Loc.t("salary.perSecond")) {
                    PrivacyAmount(surface: "salary.perSecond") {
                        Formatters.currency(ticker.engine.perSecondRate, code: settings.config.currencyCode, fractionDigits: 4)
                    }
                }
            } header: {
                Text(Loc.t("salary.section.derived"))
            }

            salaryHistorySection

            overtimeSettingsSection

            payrollSection
        }
        .formStyle(.grouped)
        .onChange(of: settings.config.countryCode) { _, newValue in
            if let currency = CountryCatalog.defaultCurrency(for: newValue) {
                settings.config.currencyCode = currency
            }
        }
        .sheet(isPresented: $showingEditor) {
            SalaryVersionEditor(
                version: editingVersion,
                currencyCode: settings.config.currencyCode,
                onCancel: { showingEditor = false },
                onSave: { newVersion in
                    applyEdit(newVersion)
                    showingEditor = false
                }
            )
            .environmentObject(settings)
            .environmentObject(privacy)
        }
        .sheet(isPresented: $showingOvertimeHistory) {
            OvertimeHistoryView()
                .environmentObject(settings)
                .environmentObject(ticker)
                .environmentObject(privacy)
                .environmentObject(overtimeController)
        }
    }

    /// 加班控制器（从环境取，主面板与设置页共用同一台账）。
    @EnvironmentObject private var overtimeController: OvertimeController

    /// 发薪日与账期设置：开关常驻可见，参数在启用后才展开，示例只作说明；
    /// 不把示例发薪日当用户真实日期静默生效。
    private var payrollSection: some View {
        Section {
            Toggle(Loc.t("payroll.enabled"), isOn: $settings.config.payroll.enabled)
            if settings.config.payroll.enabled {
                Stepper(Loc.t("payroll.cutoffDay", settings.config.payroll.cutoffDay), value: $settings.config.payroll.cutoffDay, in: 1...31)
                Stepper(Loc.t("payroll.paydayDay", settings.config.payroll.paydayDay), value: $settings.config.payroll.paydayDay, in: 1...31)
                Picker(Loc.t("payroll.offset"), selection: $settings.config.payroll.offset) {
                    Text(Loc.t("payroll.offset.sameMonth")).tag(PaydayOffset.sameMonth)
                    Text(Loc.t("payroll.offset.nextMonth")).tag(PaydayOffset.nextMonth)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text(Loc.t("payroll.section"))
        } footer: {
            if settings.config.payroll.enabled {
                Text(Loc.t("payroll.example"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 加班设置分组：默认有偿/无偿、默认倍率，以及历史入口。低频，默认收起。
    private var overtimeSettingsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showingOvertimeSettings) {
                Picker(Loc.t("overtime.defaultKind"), selection: $settings.config.overtimePayDefault) {
                    ForEach(OvertimePayKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(Loc.t("overtime.multiplier"), selection: $settings.config.overtimeMultiplier) {
                    ForEach(1...3, id: \.self) { m in Text("×\(m)").tag(m) }
                }
                .pickerStyle(.segmented)
                Text(Loc.t("overtime.hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Loc.t("overtime.history")) { showingOvertimeHistory = true }
                    .buttonStyle(.link)
            } label: {
                Text(Loc.t("overtime.section"))
            }
        }
    }

    /// 所有增删改都落到这个 store，再回写 config；撤销载荷也在此维护，UI 不各自拼数组。
    private var historyStore: SalaryHistoryStore {
        SalaryHistoryStore(
            versions: settings.config.salaryHistory,
            baseline: settings.config.salaryBaseline)
    }

    /// 撤销最近一次增删改。
    private func applyUndo() {
        var store = historyStore
        store.undo = undo
        store.undoLast()
        settings.config.salaryHistory = store.versions
        settings.config.salaryBaseline = store.baseline
        undo = nil
    }

    /// 新增或编辑统一入口。
    private func applyEdit(_ version: SalaryVersion) {
        var store = historyStore
        store.undo = undo
        let error: SalaryHistoryValidationError?
        if editingVersion == nil {
            error = store.add(version, current: settings.config, calendar: .current)
        } else if let id = editingVersion?.id {
            error = store.edit(id: id, to: version, calendar: .current)
        } else {
            error = .missing
        }
        if error == nil {
            settings.config.salaryHistory = store.versions
            settings.config.salaryBaseline = store.baseline
            undo = store.undo
        }
    }

    private func deleteVersion(_ version: SalaryVersion) {
        var store = historyStore
        store.undo = undo
        if store.delete(id: version.id) == nil {
            settings.config.salaryHistory = store.versions
            settings.config.salaryBaseline = store.baseline
            undo = store.undo
        }
    }

    /// 工资变更历史（二级入口内容直接内联为简洁分组，不塞主面板）。低频，默认收起。
    @ViewBuilder
    private var salaryHistorySection: some View {
        Section {
            DisclosureGroup(isExpanded: $showingHistory) {
                if settings.config.salaryHistory.isEmpty {
                    Text(Loc.t("salary.history.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(settings.config.salaryHistory.sorted(by: { $0.effectiveDate < $1.effectiveDate })) { version in
                        historyRow(version)
                    }
                }
                Text(Loc.t("salary.history.hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                HStack(spacing: 6) {
                    Text(Loc.t("salary.history"))
                    if !settings.config.salaryHistory.isEmpty {
                        Text("\(settings.config.salaryHistory.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            // 新增与撤销始终直接可见：折叠只收历史列表，不把操作入口藏起来。
            HStack {
                Button(Loc.t("salary.history.add")) {
                    editingVersion = nil
                    showingEditor = true
                }
                .buttonStyle(.link)
                Spacer()
                if undo != nil {
                    Button(Loc.t("salary.history.undo")) { applyUndo() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func historyRow(_ version: SalaryVersion) -> some View {
        HStack(spacing: 6) {
            Text(version.effectiveDate)
                .font(.caption)
                .monospacedDigit()
            Text(version.periodLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            PrivacyAmount(surface: "salary.history.\(version.id.uuidString)") {
                Formatters.currency(version.amount, code: settings.config.currencyCode)
            }
            .font(.caption)
            .monospacedDigit()
            .frame(minWidth: 90, alignment: .trailing)
            if version.payMonthsPerYear > 12 {
                Text(Loc.t("salary.history.monthsShort", version.payMonthsPerYear))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Button {
                editingVersion = version
                showingEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button {
                deleteVersion(version)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var todayKey: String {
        DayKeyCoder.current.key(for: Date())
    }

    private var dailyEstimate: Double {
        let days = ticker.engine.workdaysThisMonth
        return days > 0 ? settings.config.monthlyPay / Double(days) : 0
    }
}

/// 加班历史二级页：列起止/时长/有偿无偿/倍率/加班工资或无偿损失；补录、纠错、删除、撤销。
private struct OvertimeHistoryView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ticker: EarningsTicker
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var overtime: OvertimeController

    @State private var showingBackfill = false
    @State private var editingSession: OvertimeSession?
    @State private var undoAvailable = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Loc.t("overtime.history")).font(.headline)
                Spacer()
                Button(Loc.t("overtime.backfill")) {
                    editingSession = nil
                    showingBackfill = true
                }
                .buttonStyle(.bordered)
                if undoAvailable {
                    Button(Loc.t("overtime.undo")) {
                        overtime.undo()
                        undoAvailable = overtime.canUndo
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.config.overtimeSessions.isEmpty {
                Text(Loc.t("overtime.history.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(settings.config.overtimeSessions.sorted(by: { $0.start < $1.start })) { session in
                            historyRow(session)
                        }
                    }
                }
            }

            Spacer()
            Button(Loc.t("salary.history.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 320)
        .onAppear { undoAvailable = overtime.canUndo }
        .sheet(isPresented: $showingBackfill) {
            OvertimeSessionEditor(
                session: editingSession,
                currencyCode: settings.config.currencyCode,
                save: { newSession in apply(newSession) },
                onCancel: { showingBackfill = false },
                onSaved: { showingBackfill = false }
            )
            .environmentObject(settings)
            .environmentObject(privacy)
            .environmentObject(ticker)
        }
    }

    private func dismiss() {
        NSApp.keyWindow?.close()
    }

    private func historyRow(_ session: OvertimeSession) -> some View {
        let stop = session.end ?? Date()
        return HStack(spacing: 6) {
            Text(timeRange(session, stop: stop))
                .font(.caption)
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(session.kind.label)
                .font(.caption2)
                .foregroundStyle(session.kind == .paid ? .primary : .secondary)
            if session.kind == .paid {
                Text("×\(session.multiplier)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // 基准是正常税前时薪，金额也是税前口径：显式标注，避免与税后到手混列。
                Text(Loc.t("salary.tax.gross"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            PrivacyAmount(surface: "overtime.history.\(session.id.uuidString)") {
                let hours = session.elapsedSeconds(at: Date()) / 3600
                let amount = session.kind == .paid
                    ? hours * session.baseHourlyGross * Double(session.multiplier)
                    : hours * session.baseHourlyGross
                return Formatters.currency(amount, code: session.currencyCode)
            }
            .font(.caption)
            .monospacedDigit()
            .frame(minWidth: 90, alignment: .trailing)
            Button {
                editingSession = session
                showingBackfill = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button {
                if let err = overtime.delete(id: session.id) {
                    errorMessage = err.label
                }
                undoAvailable = overtime.canUndo
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func timeRange(_ session: OvertimeSession, stop: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.locale = Loc.locale
        return "\(formatter.string(from: session.start)) – \(session.end != nil ? formatter.string(from: stop) : Loc.t("overtime.active"))"
    }

    /// 新增/纠错统一落账；失败返回错误（由编辑器显示，不关表单、不丢输入），成功才落账。
    @discardableResult
    private func apply(_ newSession: OvertimeSession) -> OvertimeLedgerError? {
        let err: OvertimeLedgerError?
        if editingSession == nil {
            err = overtime.addBackfill(newSession, now: Date())
        } else if let id = editingSession?.id {
            err = overtime.edit(id: id, to: newSession, now: Date())
        } else {
            err = .missing
        }
        undoAvailable = overtime.canUndo
        return err
    }
}

/// 加班段的新增/编辑表单。补录的开始日期改动会自动解析那时有效历史 gross 时薪（auto），
/// 用户手填后转 manual 覆盖（含 0）；编辑既有段保持其锁定快照，不因今天工资重价。
private struct OvertimeSessionEditor: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var ticker: EarningsTicker

    let session: OvertimeSession?
    let currencyCode: String
    let save: (OvertimeSession) -> OvertimeLedgerError?
    let onCancel: () -> Void
    let onSaved: () -> Void

    @State private var start: Date
    @State private var end: Date
    @State private var kind: OvertimePayKind
    @State private var multiplier: Int
    @State private var baseHourlyGross: Double
    /// true = 基准时薪随开始日期自动解析历史有效值；false = 用户手填（或既有段锁定快照）。
    @State private var baseIsAuto: Bool
    @State private var errorMessage: String?

    init(session: OvertimeSession?, currencyCode: String,
         save: @escaping (OvertimeSession) -> OvertimeLedgerError?,
         onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.session = session
        self.currencyCode = currencyCode
        self.save = save
        self.onCancel = onCancel
        self.onSaved = onSaved
        if let session {
            _start = State(initialValue: session.start)
            _end = State(initialValue: session.end ?? session.start.addingTimeInterval(3600))
            _kind = State(initialValue: session.kind)
            _multiplier = State(initialValue: session.multiplier)
            _baseHourlyGross = State(initialValue: session.baseHourlyGross)
            _baseIsAuto = State(initialValue: false) // 既有段：锁定快照，不随日期重价
        } else {
            let now = Date()
            _start = State(initialValue: now)
            _end = State(initialValue: now.addingTimeInterval(3600))
            _kind = State(initialValue: .paid)
            _multiplier = State(initialValue: 1)
            _baseHourlyGross = State(initialValue: 0)
            _baseIsAuto = State(initialValue: true) // 新补录：默认按历史有效时薪自动解析
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session == nil ? Loc.t("overtime.backfill") : Loc.t("overtime.edit")).font(.headline)
            DatePicker(Loc.t("overtime.start"), selection: $start)
            DatePicker(Loc.t("overtime.stop"), selection: $end)
            Picker(Loc.t("overtime.defaultKind"), selection: $kind) {
                ForEach(OvertimePayKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if kind == .paid {
                Picker(Loc.t("overtime.multiplier"), selection: $multiplier) {
                    ForEach(1...3, id: \.self) { m in Text("×\(m)").tag(m) }
                }
                .pickerStyle(.segmented)
            }
            PrivacyAmountField(surface: "overtime.editor.base", label: Loc.t("overtime.base"), yuan: baseBinding)
            if baseIsAuto {
                Text(Loc.t("overtime.base.auto"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(Loc.t("salary.history.cancel")) { onCancel() }
                Button(Loc.t("salary.history.save")) {
                    let newSession = OvertimeSession(
                        start: start, end: end, kind: kind, multiplier: multiplier,
                        baseHourlyGross: max(baseHourlyGross, 0), currencyCode: currencyCode)
                    if let err = save(newSession) {
                        errorMessage = err.label
                    } else {
                        onSaved()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { refreshBaseIfAuto() }
        .onChange(of: start) { _, _ in refreshBaseIfAuto() }
    }

    /// 基准时薪绑定：手填即转 manual（含 0，合法保留）。
    private var baseBinding: Binding<Double> {
        Binding(
            get: { baseHourlyGross },
            set: { newValue in
                baseIsAuto = false
                baseHourlyGross = newValue
            }
        )
    }

    /// auto 态随开始日期解析那时有效的正常税前时薪（历史工资/当前工资）。
    private func refreshBaseIfAuto() {
        guard baseIsAuto else { return }
        baseHourlyGross = ticker.engine.hourlyGrossRate(on: start)
    }
}

/// 工资变更的新增 / 编辑表单。金额、口径、薪月数、生效日期都可编辑；
/// 编辑已存在的变更时保留其原 id，历史其余日期不受影响。
private struct SalaryVersionEditor: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var privacy: PrivacyController

    let version: SalaryVersion?
    let currencyCode: String
    let onCancel: () -> Void
    let onSave: (SalaryVersion) -> Void

    @State private var amount: Double
    @State private var period: SalaryPeriod
    @State private var payMonths: Int
    @State private var effectiveDate: Date

    init(version: SalaryVersion?, currencyCode: String, onCancel: @escaping () -> Void, onSave: @escaping (SalaryVersion) -> Void) {
        self.version = version
        self.currencyCode = currencyCode
        self.onCancel = onCancel
        self.onSave = onSave
        let base = version ?? SalaryVersion(
            effectiveDate: DayKeyCoder.current.key(for: Date()),
            amount: 0,
            period: .monthly,
            payMonthsPerYear: 12)
        _amount = State(initialValue: base.amount)
        _period = State(initialValue: base.period)
        _payMonths = State(initialValue: base.payMonthsPerYear)
        let initialDate = DayKeyCoder.current.date(from: base.effectiveDate) ?? Date()
        _effectiveDate = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(version == nil ? Loc.t("salary.history.add") : Loc.t("salary.history.edit"))
                .font(.headline)

            PrivacyAmountField(surface: "salary.history.editor.amount", label: Loc.t("salary.history.amount"), yuan: $amount)
            Picker(Loc.t("salary.history.period"), selection: $period) {
                ForEach(SalaryPeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper(Loc.t("salary.payMonths", payMonths), value: $payMonths, in: 12...20)
            DatePicker(Loc.t("salary.history.effective"), selection: $effectiveDate, displayedComponents: .date)

            HStack {
                Spacer()
                Button(Loc.t("salary.history.cancel")) { onCancel() }
                Button(Loc.t("salary.history.save")) {
                    let key = DayKeyCoder.current.key(for: effectiveDate)
                    onSave(SalaryVersion(
                        effectiveDate: key,
                        amount: max(amount, 0),
                        period: period,
                        payMonthsPerYear: payMonths))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

// MARK: - 税后参数

private struct TaxTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ticker: EarningsTicker
    @EnvironmentObject private var privacy: PrivacyController

    /// 低频分组默认收起：社保/公积金基数与比例、扣除项与月份参数。
    @State private var showingTaxSocial = false
    @State private var showingTaxDeductions = false

    /// 用当前配置解析一次，取有效值与状态，供界面展示；不复制任何基数/税率算法。
    private var resolved: NetPayCalculator.ResolvedSocial {
        NetPayCalculator.resolve(
            profile: settings.config.tax,
            grossMonthly: Money(yuan: settings.config.monthlyPay))
    }

    private var result: NetPayCalculator.Result {
        NetPayCalculator.compute(
            grossMonthly: Money(yuan: settings.config.monthlyPay),
            payMonthsPerYear: settings.config.payMonthsPerYear,
            profile: settings.config.tax,
            countryCode: settings.config.countryCode,
            currencyCode: settings.config.currencyCode)
    }

    private var preset: TaxRegionPreset? {
        TaxRegionPreset.all.first(where: { $0.id == settings.config.tax.region })
    }

    var body: some View {
        Form {
            Section {
                Picker(Loc.t("salary.tax.region"), selection: $settings.config.tax.region) {
                    ForEach(TaxRegionPreset.all, id: \.id) { Text($0.name).tag($0.id) }
                    Text(Loc.t("salary.tax.region.custom")).tag("custom")
                }
                .onChange(of: settings.config.tax.region) { _, _ in
                    // 切换地区只更新 auto 字段与固定额默认，不重置 social、不覆盖手填。
                }
                if let preset {
                    LabeledContent(Loc.t("salary.tax.region.effective"), value: preset.effectiveDate)
                    LabeledContent(Loc.t("salary.tax.region.checked"), value: preset.checkedAt)
                    if let first = preset.sourceURLs.first {
                        Link(Loc.t("salary.tax.region.source"), destination: URL(string: first)!)
                    }
                }
            } header: {
                Text(Loc.t("salary.tax.region"))
            }

            // 结果先于低频参数出现：切到税后不必展开折叠组就能看到本月明细。
            detailSection

            if !result.blocked.isEmpty {
                Section {
                    ForEach(Array(result.blocked.enumerated()), id: \.offset) { i, message in
                        PrivacyAmount(surface: "tax.blocked.\(i)") { message }
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(Loc.t("salary.tax.blocked"))
                }
            }
            if !result.warnings.isEmpty {
                Section {
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { i, message in
                        PrivacyAmount(surface: "tax.warning.\(i)") { message }
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !NetPayCalculator.applies(
                countryCode: settings.config.countryCode,
                currencyCode: settings.config.currencyCode) {
                Section {
                    Text(Loc.t("salary.tax.notApplicable")).font(.caption).foregroundStyle(.orange)
                }
            }

            // 低频：社保/公积金基数与比例整组折叠，避免每项堆三行撑出屏幕。
            Section {
                DisclosureGroup(isExpanded: $showingTaxSocial) {
                    baseEditor(Loc.t("salary.tax.pension"), $settings.config.tax.social.pension,
                                rate: $settings.config.tax.social.pensionRateBp, resolved: resolved.pension,
                                ratePresets: [800], surface: "tax.pension")
                    baseEditor(Loc.t("salary.tax.medical"), $settings.config.tax.social.medical,
                                rate: $settings.config.tax.social.medicalRateBp, resolved: resolved.medical,
                                ratePresets: [200], surface: "tax.medical")
                    baseEditor(Loc.t("salary.tax.medicalFixed"), $settings.config.tax.social.medicalFixed,
                                rate: nil, resolved: resolved.medicalFixed, isFixed: true,
                                ratePresets: nil, surface: "tax.medicalFixed")
                    baseEditor(Loc.t("salary.tax.unemployment"), $settings.config.tax.social.unemployment,
                                rate: $settings.config.tax.social.unemploymentRateBp, resolved: resolved.unemployment,
                                ratePresets: [50], surface: "tax.unemployment")
                    baseEditor(Loc.t("salary.tax.housingFund"), $settings.config.tax.social.housingFund,
                                rate: $settings.config.tax.social.housingFundRateBp, resolved: resolved.housingFund,
                                ratePresets: housingFundPresets, surface: "tax.housingFund")
                } label: {
                    Text(Loc.t("salary.tax.social"))
                }
            }

            // 低频：扣除项与月份参数同组折叠。
            Section {
                DisclosureGroup(isExpanded: $showingTaxDeductions) {
                    SettingsRow(title: Loc.t("salary.tax.special")) {
                        PrivacyAmountField(surface: "tax.special",
                                           label: Loc.t("salary.tax.special"),
                                           yuan: yuanBinding($settings.config.tax.monthlySpecialDeduction))
                            .multilineTextAlignment(.trailing)
                    }
                    SettingsRow(title: Loc.t("salary.tax.other")) {
                        PrivacyAmountField(surface: "tax.other",
                                           label: Loc.t("salary.tax.other"),
                                           yuan: yuanBinding($settings.config.tax.monthlyOtherDeduction))
                            .multilineTextAlignment(.trailing)
                    }
                    Stepper(value: $settings.config.tax.employmentStartMonth, in: 1...12) {
                        Text("\(Loc.t("salary.tax.startMonth")) \(settings.config.tax.employmentStartMonth)")
                    }
                    Stepper(value: $settings.config.tax.bonusMonth, in: 1...12) {
                        Text("\(Loc.t("salary.tax.bonusMonth")) \(settings.config.tax.bonusMonth)")
                    }
                } label: {
                    Text(Loc.t("salary.tax.section"))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 公积金比例：参考地区常用档位（北京 5–12%，上海 5/6/7%）；custom 或非预设值则手填。
    private var housingFundPresets: [Int]? {
        guard let preset else { return nil }
        if preset.id == "beijing" { return Array(stride(from: 500, through: 1200, by: 100)) }
        if preset.id == "shanghai" { return [500, 600, 700] }
        return nil
    }

    @ViewBuilder
    private func baseEditor(
        _ title: String, _ base: Binding<SocialBase>, rate: Binding<Int>?,
        resolved: NetPayCalculator.ResolvedItem, isFixed: Bool = false,
        ratePresets: [Int]?, surface: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel(title) {
                Picker("", selection: baseModeBinding(base)) {
                    Text(Loc.t("salary.tax.auto")).tag(0)
                    Text(Loc.t("salary.tax.disabled")).tag(1)
                    Text(Loc.t("salary.tax.manual")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 行标签在 SettingsRow 里单独渲染，控件本身要补辅助名称，否则 AX 只剩「自动/不缴/手动」。
                .accessibilityLabel(title)
            }
            if case .manual = base.wrappedValue {
                // 手填输入框：固定额与基数用各自词条；金额编辑走隐私掩码（点掩码才变编辑器）。
                let fieldLabel = isFixed ? Loc.t("salary.tax.medicalFixed") : Loc.t("salary.tax.base")
                rowLabel(fieldLabel) {
                    PrivacyAmountField(surface: surface,
                                       label: fieldLabel,
                                       yuan: yuanBinding(manualBinding(base)))
                }
            }
            if let rate, let ratePresets, base.wrappedValue != .disabled {
                // 固定档位选择 + 自定义手输：档位直接选，非预设值显示「自定义」并保留原 bp 值。
                ratePicker(
                    label: Loc.t("salary.tax.rate"), rate: rate, presets: ratePresets,
                    surface: surface)
            } else if let rate, base.wrappedValue != .disabled {
                // 无预设档位（custom 地区）：直接数字输入。
                rateField(label: Loc.t("salary.tax.rate"), rate: rate, surface: surface)
            }
            // 有效值与状态（读 resolve，不复制算法）。含有效基数/缴费额，隐私下掩码，点该项显示。
            PrivacyAmount(surface: surface + ".resolved") {
                statusText(for: resolved)
            }
            .font(.caption2)
            .foregroundStyle(resolved.state == .disabled ? .tertiary : .secondary)
            .monospacedDigit()
        }
    }

    /// 统一一行：标签靠左、控件靠右同宽。长翻译不把控件挤走。
    private func rowLabel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        SettingsRow(title: title) { content() }
    }

    /// 比例档位 Picker + 自定义输入，去掉 0.01% 步进器。
    @ViewBuilder
    private func ratePicker(label: String, rate: Binding<Int>, presets: [Int], surface: String) -> some View {
        rowLabel(label) {
            Picker("", selection: rateBinding(rate, presets: presets)) {
                ForEach(presets, id: \.self) { bp in
                    Text(String(format: "%.2f%%", Double(bp) / 100)).tag(bp)
                }
                Text(Loc.t("salary.tax.manual")).tag(-1)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(label)
        }
        if !presets.contains(rate.wrappedValue) {
            rowLabel(Loc.t("salary.tax.manual")) {
                TextField("", value: bpPercentBinding(rate), format: .number)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(label)
            }
        }
    }

    @ViewBuilder
    private func rateField(label: String, rate: Binding<Int>, surface: String) -> some View {
        rowLabel(label) {
            TextField("", value: bpPercentBinding(rate), format: .number)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(label)
        }
    }

    /// 档位 Picker 绑定：非预设值选「自定义」，选择档位写回对应 bp；选自定义保持当前值。
    private func rateBinding(_ rate: Binding<Int>, presets: [Int]) -> Binding<Int> {
        Binding(
            get: { presets.contains(rate.wrappedValue) ? rate.wrappedValue : -1 },
            set: { newValue in
                if newValue != -1 { rate.wrappedValue = newValue }
            }
        )
    }

    /// 基点（bp）↔ 百分比（%）双向转换，供 TextField 直接输入百分数。
    private func bpPercentBinding(_ rate: Binding<Int>) -> Binding<Double> {
        Binding(
            get: { Double(rate.wrappedValue) / 100 },
            set: { rate.wrappedValue = Int(($0 * 100).rounded()) }
        )
    }

    /// 三态 Picker 的整数绑定，映射到 SocialBase。
    private func baseModeBinding(_ base: Binding<SocialBase>) -> Binding<Int> {
        Binding(
            get: {
                switch base.wrappedValue {
                case .auto: return 0
                case .disabled: return 1
                case .manual: return 2
                }
            },
            set: { newValue in
                switch newValue {
                case 1: base.wrappedValue = .disabled
                case 2: base.wrappedValue = .manual(base.wrappedValue.isManual ? manualValue(base.wrappedValue) : .zero)
                default: base.wrappedValue = .auto
                }
            }
        )
    }

    private func manualValue(_ base: SocialBase) -> Money {
        if case .manual(let m) = base { return m }
        return .zero
    }

    private func statusText(for item: NetPayCalculator.ResolvedItem) -> String {
        let state: String
        switch item.state {
        case .automatic: state = Loc.t("salary.tax.auto")
        case .manual: state = Loc.t("salary.tax.manual")
        case .disabled: state = Loc.t("salary.tax.disabled")
        }
        if item.state == .disabled {
            return state
        }
        let base = item.base.doubleYuan.formatted(.number.precision(.fractionLength(2)).locale(Loc.locale))
        let amount = item.amount.doubleYuan.formatted(.number.precision(.fractionLength(2)).locale(Loc.locale))
        return "\(state) · \(base) → \(amount)"
    }

    @ViewBuilder
    private var detailSection: some View {
        Section {
            if result.available, let month = result.months.first(where: { $0.gross.cents > 0 }) {
                LabeledContent(Loc.t("salary.tax.gross")) {
                    PrivacyAmount(surface: "tax.detail.gross") { yuan(month.gross.doubleYuan) }
                }
                LabeledContent(Loc.t("salary.tax.socialTotal")) {
                    PrivacyAmount(surface: "tax.detail.social") { yuan(month.socialTotal.doubleYuan) }
                }
                LabeledContent(Loc.t("salary.tax.tax")) {
                    PrivacyAmount(surface: "tax.detail.tax") { yuan(month.tax.doubleYuan) }
                }
                LabeledContent(Loc.t("salary.tax.net")) {
                    PrivacyAmount(surface: "tax.detail.net") { yuan(month.net.doubleYuan) }
                }
            } else {
                Text(Loc.t("salary.tax.blocked")).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(Loc.t("salary.tax.detail"))
        }

        Section {
            if result.available {
                LabeledContent(Loc.t("salary.tax.year")) {
                    PrivacyAmount(surface: "tax.detail.year") { yuan(result.yearNet.doubleYuan) }
                }
                Text(Loc.t("salary.tax.note")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func yuan(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(2)).locale(Loc.locale))
    }

    /// 把 Money（分）绑定成「元」的 TextField 绑定。
    private func yuanBinding(_ money: Binding<Money>) -> Binding<Double> {
        Binding(
            get: { money.wrappedValue.doubleYuan },
            set: { money.wrappedValue = Money(yuan: $0) }
        )
    }

    /// 手动基数的 Money 绑定。
    private func manualBinding(_ base: Binding<SocialBase>) -> Binding<Money> {
        Binding(
            get: {
                if case .manual(let m) = base.wrappedValue { return m }
                return .zero
            },
            set: { newValue in base.wrappedValue = .manual(newValue) }
        )
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
                    // 空标题 + labelsHidden 会让这个日期控件在 AX 里没有名字，用所在分组标题补上。
                    .accessibilityLabel(title)
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
                Toggle(Loc.t("privacy.toggle"), isOn: $settings.config.privacyModeEnabled)
                Text(Loc.t("privacy.toggle.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Loc.t("privacy.autoHide"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                Text(Loc.t("privacy.section"))
            }

            Section {
                Picker(Loc.t("display.theme"), selection: $settings.config.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
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

// MARK: - 排版常量

/// 全设置页右侧控件统一列宽：数值框、菜单选择、分段三态都用同一宽度，
/// 标签在左、控件在右，换 tab 也不左右跳。取 210pt 是让俄语「Не платится」这类长词
/// 在分段控件里也不被压缩，同时给左侧标签留出足够空间。
private let settingsControlWidth: CGFloat = 210

/// 设置行统一样式：标签靠左单行，控件在右侧同一列、同宽；长翻译轻微缩放不挤走控件。
private struct SettingsRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            content
                .frame(width: settingsControlWidth, alignment: .trailing)
        }
    }
}

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
