import SwiftUI

/// 主面板「请假」入口弹出的小面板：只处理今天这一天的请假。
///
/// 数据直接落 `settings.config.leaveEntries`（与设置页共用同一份记录），
/// 写完后 `EarningsTicker` 会因为 `settings.$config` 变化而重建引擎，不需要额外通知。
///
/// 未保存的输入不在本视图的多个 `@State` 里，而是**整份**放在 `EditingDraftStore`：
/// 屏幕共享保护会把本视图整体移出视图树（隐私要求，不能退回遮罩），
/// 视图销毁时草稿仍然在，重新打开（`draft:` 由调用方从 store 取）就能接着填。
/// 只有「保存 / 删除 / 取消」或草稿过期才清掉草稿，保护打断本身不清。
struct TodayLeavePanelView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ticker: EarningsTicker
    @EnvironmentObject private var drafts: EditingDraftStore

    /// 判定「今天」用的时间点，由面板传入，保证与面板显示的日期一致。
    let now: Date
    let onDismiss: () -> Void

    @State private var draft: LeaveDayEditorDraft
    @State private var errorMessage: String?

    init(
        now: Date = Date(),
        draft: LeaveDayEditorDraft? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.now = now
        self.onDismiss = onDismiss
        let day = Calendar.current.startOfDay(for: now)
        _draft = State(initialValue: draft ?? LeaveDayEditorDraft.seed(day: day, existing: nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !isWorkday {
                Text(Loc.t("leave.today.nonWorkday"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(Loc.t("leave.kind"), selection: $draft.kind) {
                ForEach(LeaveKind.allCases) { kind in
                    Text(LeaveLabels.kind(kind)).tag(kind)
                }
            }
            .onChange(of: draft.kind) { _, newKind in adoptDefaultRatio(for: newKind) }

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
                if existing != nil {
                    Button(Loc.t("leave.delete"), role: .destructive) { removeToday() }
                }
                Spacer()
                Button(Loc.t("leave.cancel")) { cancel() }
                Button(Loc.t("leave.save")) { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        // 每次改动都写回草稿：保护层换掉视图之前，最新输入已经在保护层外了。
        .onChange(of: draft) { _, newDraft in drafts.todayLeaveDay.update(newDraft) }
        .onAppear { drafts.todayLeaveDay.update(draft) }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(existing == nil ? Loc.t("leave.today.title") : Loc.t("leave.edit"))
                .font(.headline)
            Text(todayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let existing {
                Text(
                    Loc.t(
                        "leave.today.current",
                        LeaveLabels.kind(existing.kind),
                        LeaveLabels.portion(existing.portion),
                        LeaveLabels.ratio(existing.payRatioBp)
                    )
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var todayLabel: String {
        let formatter = Date.FormatStyle.dateTime.month().day().weekday(.wide)
        return today.formatted(formatter.locale(Loc.locale))
    }

    // MARK: - 读写

    private var today: Date {
        Calendar.current.startOfDay(for: now)
    }

    private var todayKey: String {
        DayKeyCoder.current.key(for: today)
    }

    /// 当天已有记录：只用于标题、「当前」文案和删除入口，不覆盖草稿。
    private var existing: LeaveEntry? {
        LeaveLedger(entries: settings.config.leaveEntries).entry(on: todayKey)
    }

    private var isWorkday: Bool {
        ticker.engine.workCalendar.isWorkday(today)
    }

    private func cancel() {
        drafts.todayLeaveDay.close()
        onDismiss()
    }

    private func submit() {
        let entry = LeaveEntry(
            id: existing?.id ?? UUID(),
            dayKey: todayKey,
            kind: draft.kind,
            portion: draft.portion,
            payRatioBp: draft.resolvedBasisPoints,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var ledger = LeaveLedger(entries: settings.config.leaveEntries)
        switch ledger.upsert(entry) {
        case .failure(let failure):
            errorMessage = LeaveLabels.error(failure)
        case .success:
            settings.config.leaveEntries = ledger.entries
            errorMessage = nil
            cancel()
        }
    }

    private func removeToday() {
        guard let existing else { return cancel() }
        var ledger = LeaveLedger(entries: settings.config.leaveEntries)
        ledger.remove(id: existing.id)
        settings.config.leaveEntries = ledger.entries
        cancel()
    }

    private func adoptDefaultRatio(for newKind: LeaveKind) {
        let defaultRatio = newKind.defaultPayRatioBp
        switch LeavePayOption.option(for: defaultRatio) {
        case .unpaid:
            draft.payOption = .unpaid
        case .full:
            draft.payOption = .full
        case .custom:
            draft.payOption = .custom
            draft.customBasisPoints = defaultRatio
        }
    }

    /// 保存后今天还剩多少计薪比例：全天不计薪 = 0%，半天 60% = 80%。
    private var impactDescription: String {
        let entry = LeaveEntry(
            id: existing?.id ?? UUID(),
            dayKey: todayKey,
            kind: draft.kind,
            portion: draft.portion,
            payRatioBp: draft.resolvedBasisPoints,
            note: draft.note
        )
        let loss = LeaveImpact.loss(of: entry, engine: ticker.engine, config: settings.config)
        let currency = Formatters.currency(
            loss, code: settings.config.currencyCode, fractionDigits: 0)
        return Loc.t(
            "leave.today.preview",
            LeaveLabels.portion(entry.portion),
            LeaveLabels.ratio(entry.payRatioBp),
            Formatters.percent(entry.payableFraction, fractionDigits: 0),
            currency
        )
    }
}
