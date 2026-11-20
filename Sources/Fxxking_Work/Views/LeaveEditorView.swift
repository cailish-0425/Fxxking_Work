import SwiftUI

// MARK: - 文案

/// 请假相关的枚举文案与错误文案。
///
/// 故意用 `enum` 上的静态方法而不是 `extension LeaveKind { var label }`：
/// 这类扩展更适合放进 `Support/DisplayNames.swift`，由 Lead 统一维护；
/// 这里要是也声明一份同名扩展，将来接入 `LeaveController` 时会撞成重复声明。
enum LeaveLabels {
    static func kind(_ kind: LeaveKind) -> String {
        switch kind {
        case .personal: return Loc.t("leave.kind.personal")
        case .sick: return Loc.t("leave.kind.sick")
        case .annual: return Loc.t("leave.kind.annual")
        case .compensatory: return Loc.t("leave.kind.compensatory")
        case .marriage: return Loc.t("leave.kind.marriage")
        case .bereavement: return Loc.t("leave.kind.bereavement")
        case .maternity: return Loc.t("leave.kind.maternity")
        case .paternity: return Loc.t("leave.kind.paternity")
        case .other: return Loc.t("leave.kind.other")
        }
    }

    static func portion(_ portion: LeavePortion) -> String {
        switch portion {
        case .fullDay: return Loc.t("leave.portion.fullDay")
        case .morning: return Loc.t("leave.portion.morning")
        case .afternoon: return Loc.t("leave.portion.afternoon")
        }
    }

    static func pay(_ option: LeavePayOption) -> String {
        switch option {
        case .unpaid: return Loc.t("leave.pay.unpaid")
        case .full: return Loc.t("leave.pay.full")
        case .custom: return Loc.t("leave.pay.custom")
        }
    }

    static func error(_ error: LeaveLedgerError) -> String {
        switch error {
        case .duplicateDate: return Loc.t("leave.error.duplicate")
        case .invalidPayRatio: return Loc.t("leave.error.ratio")
        }
    }

    /// 0…10000 基点 → "60%"。百分比交给系统格式化，各语言的写法不用自己拼。
    static func ratio(_ basisPoints: Int) -> String {
        Formatters.percent(Double(basisPoints) / 10_000, fractionDigits: 0)
    }
}

// MARK: - 计薪口径

/// 界面上只暴露三档，底层仍然是 `LeaveEntry.payRatioBp` 一个值。
// MARK: - 影响估算

/// 请假金额影响都是「税前毛额口径」的估算，和主面板的日薪同一套算法：
/// 当日生效月薪 ÷ 当月工作日数 = 日薪。
enum LeaveImpact {
    static func dailyGross(on day: Date, engine: EarningsEngine, config: Configuration) -> Double {
        guard config.paidSecondsPerDay > 0 else { return 0 }
        return engine.hourlyGrossRate(on: day) * config.paidSecondsPerDay / 3600
    }

    /// 这一天因为请假少计的金额（0 表示全额计薪，请假不影响工资）。
    static func loss(of entry: LeaveEntry, engine: EarningsEngine, config: Configuration) -> Double {
        guard let day = DayKeyCoder.current.date(from: entry.dayKey) else { return 0 }
        return dailyGross(on: day, engine: engine, config: config) * (1 - entry.payableFraction)
    }
}

// MARK: - 单日编辑器

/// 设置页复用的单日请假编辑器：新增 / 编辑 / 删除都走这里，撤销由调用方负责。
///
/// 传 `save` / `delete` 就用调用方的持久化（将来接入 `LeaveController` 时复用同一套 UI）；
/// 都不传则直接写 `settings.config.leaveEntries`，这样不依赖任何新服务层也能用。
/// `LeavePayOption` 与三份编辑器草稿定义在一起（`Support/EditingDrafts.swift`），
/// 因为草稿要在没有 SwiftUI 环境的检查里也能用。
struct LeaveEditorView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ticker: EarningsTicker
    @EnvironmentObject private var drafts: EditingDraftStore

    /// nil = 新增。
    let entry: LeaveEntry?
    /// 新增时的初始日期；编辑时以 `entry.dayKey` 为准。
    let dayKey: String
    let save: ((LeaveEntry) -> LeaveLedgerError?)?
    let delete: ((UUID) -> Void)?
    let onCancel: () -> Void
    let onSaved: () -> Void

    /// 未保存的输入整份放草稿：屏幕保护把本视图移出视图树时，草稿由
    /// `EditingDraftStore` 保留，重新打开时接着填。
    @State private var draft: LeaveDayEditorDraft
    @State private var errorMessage: String?

    init(
        entry: LeaveEntry?,
        dayKey: String,
        draft: LeaveDayEditorDraft? = nil,
        save: ((LeaveEntry) -> LeaveLedgerError?)? = nil,
        delete: ((UUID) -> Void)? = nil,
        onCancel: @escaping () -> Void = {},
        onSaved: @escaping () -> Void = {}
    ) {
        self.entry = entry
        self.dayKey = dayKey
        self.save = save
        self.delete = delete
        self.onCancel = onCancel
        self.onSaved = onSaved

        let resolvedKey = entry?.dayKey ?? dayKey
        let resolvedDay = DayKeyCoder.current.date(from: resolvedKey) ?? Date()
        _draft = State(
            initialValue: draft ?? LeaveDayEditorDraft.seed(day: resolvedDay, existing: entry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry == nil ? Loc.t("leave.add") : Loc.t("leave.edit"))
                .font(.headline)

            DatePicker(Loc.t("leave.date"), selection: $draft.day, displayedComponents: .date)

            Picker(Loc.t("leave.kind"), selection: $draft.kind) {
                ForEach(LeaveKind.allCases) { kind in
                    Text(LeaveLabels.kind(kind)).tag(kind)
                }
            }
            .onChange(of: draft.kind) { _, newKind in
                // 只有用户没动过计薪比例时才跟假种默认值走，避免覆盖手填的 60%。
                guard draft.payOption == .unpaid || draft.payOption == .full else { return }
                adoptDefaultRatio(for: newKind)
            }

            Picker(Loc.t("leave.portion"), selection: $draft.portion) {
                ForEach(LeavePortion.allCases) { portion in
                    Text(LeaveLabels.portion(portion)).tag(portion)
                }
            }
            .pickerStyle(.segmented)

            Picker(Loc.t("leave.pay"), selection: $draft.payOption) {
                ForEach(LeavePayOption.allCases) { option in
                    Text(LeaveLabels.pay(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if draft.payOption == .custom {
                Stepper(
                    Loc.t("leave.ratio.custom", LeaveLabels.ratio(draft.customBasisPoints)),
                    value: $draft.customBasisPoints, in: 0...10_000, step: 500
                )
            }

            TextField(Loc.t("leave.note"), text: $draft.note)
            Text(impactDescription)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let entry, let delete {
                    Button(Loc.t("leave.delete"), role: .destructive) {
                        delete(entry.id)
                        drafts.leaveDay.close()
                        onSaved()
                    }
                }
                Spacer()
                Button(Loc.t("leave.cancel")) {
                    drafts.leaveDay.close()
                    onCancel()
                }
                Button(Loc.t("leave.save")) { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        // 每次改动都写回草稿：保护层把本视图移出视图树之前，最新输入已经在保护层外了。
        .onChange(of: draft) { _, newDraft in drafts.leaveDay.update(newDraft) }
        .onAppear { drafts.leaveDay.update(draft) }
    }

    // MARK: - 提交

    private func submit() {
        let ledger = LeaveLedger(entries: settings.config.leaveEntries)
        let newKey = DayKeyCoder.current.key(for: draft.day)
        // 改日期撞到别人的记录：明确报冲突，而不是造出两条同一天、`entry(on:)` 只能取到第一条。
        if ledger.entries.contains(where: { $0.dayKey == newKey && $0.id != entry?.id }) {
            errorMessage = LeaveLabels.error(.duplicateDate)
            return
        }
        let candidate = LeaveEntry(
            id: entry?.id ?? UUID(),
            dayKey: newKey,
            kind: draft.kind,
            portion: draft.portion,
            payRatioBp: resolvedBasisPoints,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let save {
            if let failure = save(candidate) {
                errorMessage = LeaveLabels.error(failure)
                return
            }
        } else {
            var editable = ledger
            switch editable.upsert(candidate) {
            case .failure(let failure):
                errorMessage = LeaveLabels.error(failure)
                return
            case .success:
                settings.config.leaveEntries = editable.entries
            }
        }
        errorMessage = nil
        drafts.leaveDay.close()
        onSaved()
    }

    private var resolvedBasisPoints: Int {
        draft.resolvedBasisPoints
    }

    /// 改假种时，把「不计薪 / 100% 计薪」两档按假种默认值重新落地；
    /// 自定义档保持用户输入，半天的比例仍由 `payableFraction` 折半，不需要另存一个半天比例。
    private func adoptDefaultRatio(for newKind: LeaveKind) {
        let defaultRatio = newKind.defaultPayRatioBp
        switch LeavePayOption.option(for: defaultRatio) {
        case .unpaid:
            draft.payOption = .unpaid
        case .full:
            draft.payOption = .full
        case .custom:
            // 默认值落在中间（例如病假 60%）：直接切到自定义档并预填，用户想改就改。
            draft.payOption = .custom
            draft.customBasisPoints = defaultRatio
        }
    }

    private var impactDescription: String {
        let entry = previewEntry
        let loss = LeaveImpact.loss(of: entry, engine: ticker.engine, config: settings.config)
        let currency = Formatters.currency(
            loss, code: settings.config.currencyCode, fractionDigits: 0)
        return Loc.t(
            "leave.impact.preview",
            LeaveLabels.portion(entry.portion),
            LeaveLabels.ratio(entry.payRatioBp),
            currency
        )
    }

    private var previewEntry: LeaveEntry {
        LeaveEntry(
            id: entry?.id ?? UUID(),
            dayKey: DayKeyCoder.current.key(for: draft.day),
            kind: draft.kind,
            portion: draft.portion,
            payRatioBp: resolvedBasisPoints,
            note: draft.note
        )
    }
}

// MARK: - 区间补录草稿

/// 区间补录的输入。渲染与落账分开，落账逻辑留在 `LeaveHistorySection`。
struct LeaveRangeDraft {
    var start: Date
    var end: Date
    var kind: LeaveKind
    var portion: LeavePortion
    var payRatioBp: Int
    var note: String
    var workdaysOnly: Bool
}

/// 区间补录的落账结果，用来告诉用户到底写进去几天、跳过几天。
struct LeaveRangeResult: Equatable {
    var added: Int = 0
    var skippedExisting: Int = 0
    var skippedNonWorkday: Int = 0

    var total: Int { added + skippedExisting + skippedNonWorkday }
}

// MARK: - 区间补录编辑器

/// 设置页「请假记录」里的补录表单：起止日期 + 假种 + 计薪比例 + 只应用到工作日。
/// 半天只允许单日，所以起止跨天时自动锁到全天。
struct LeaveRangeEditorView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ticker: EarningsTicker
    @EnvironmentObject private var drafts: EditingDraftStore

    let apply: (LeaveRangeDraft) -> LeaveRangeResult
    let onCancel: () -> Void
    let onSaved: () -> Void

    /// 未保存输入同上：整份放草稿，保护打断后重新打开还能接着填。
    @State private var draft: LeaveRangeEditorDraft
    @State private var message: String?
    @State private var applied = false

    init(
        start: Date = Date(),
        end: Date = Date(),
        draft: LeaveRangeEditorDraft? = nil,
        apply: @escaping (LeaveRangeDraft) -> LeaveRangeResult,
        onCancel: @escaping () -> Void = {},
        onSaved: @escaping () -> Void = {}
    ) {
        self.apply = apply
        self.onCancel = onCancel
        self.onSaved = onSaved
        _draft = State(initialValue: draft ?? LeaveRangeEditorDraft.seed(start: start, end: end))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Loc.t("leave.backfill")).font(.headline)

            DatePicker(
                Loc.t("leave.start"), selection: $draft.start, displayedComponents: .date)
            DatePicker(Loc.t("leave.end"), selection: $draft.end, displayedComponents: .date)

            Picker(Loc.t("leave.kind"), selection: $draft.kind) {
                ForEach(LeaveKind.allCases) { kind in
                    Text(LeaveLabels.kind(kind)).tag(kind)
                }
            }

            Picker(Loc.t("leave.portion"), selection: $draft.portion) {
                ForEach(LeavePortion.allCases) { portion in
                    Text(LeaveLabels.portion(portion)).tag(portion)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!isSingleDay)
            if !isSingleDay {
                Text(Loc.t("leave.range.halfDayOnly"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(Loc.t("leave.pay"), selection: $draft.payOption) {
                ForEach(LeavePayOption.allCases) { option in
                    Text(LeaveLabels.pay(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if draft.payOption == .custom {
                Stepper(
                    Loc.t("leave.ratio.custom", LeaveLabels.ratio(draft.customBasisPoints)),
                    value: $draft.customBasisPoints, in: 0...10_000, step: 500
                )
            }

            Toggle(Loc.t("leave.range.workdaysOnly"), isOn: $draft.workdaysOnly)

            TextField(Loc.t("leave.note"), text: $draft.note)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(Loc.t("leave.cancel")) { cancel() }
                if applied {
                    Button(Loc.t("leave.done")) { cancel() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(Loc.t("leave.save")) { submit() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        // 每次改动都写回草稿（含"只应用工作日"这类开关）。
        .onChange(of: draft) { _, newDraft in drafts.leaveRange.update(newDraft) }
        .onAppear { drafts.leaveRange.update(draft) }
    }

    private var isSingleDay: Bool {
        draft.isSingleDay
    }

    /// 取消 / 完成都算用户结束这次编辑：草稿清掉，保护结束不会自己弹回来。
    private func cancel() {
        drafts.leaveRange.close()
        onCancel()
    }

    private func submit() {
        guard draft.hasValidRange else {
            message = Loc.t("leave.error.range")
            return
        }
        let commit = LeaveRangeDraft(
            start: draft.start,
            end: draft.end,
            kind: draft.kind,
            // 跨天时强制全天：半天只能落在单日上。
            portion: draft.effectivePortion,
            payRatioBp: draft.resolvedBasisPoints,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
            workdaysOnly: draft.workdaysOnly
        )
        let result = apply(commit)
        applied = result.added > 0
        message = Loc.t(
            "leave.range.applied",
            result.added,
            result.skippedExisting,
            result.skippedNonWorkday
        )
    }
}
