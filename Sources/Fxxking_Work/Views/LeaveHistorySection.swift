import SwiftUI

/// 设置页「假日」分区里的请假记录区：补录区间、单日编辑/删除、撤销、影响汇总。
///
/// 分区结构与现有假日分区一致（`Section` + header + footer），直接放进 `Form` 即可：
/// ```
/// LeaveHistorySection()
/// ```
/// 数据同样落 `settings.config.leaveEntries`；`EarningsTicker` 会因为配置变化自动重建。
struct LeaveHistorySection: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ticker: EarningsTicker
    @EnvironmentObject private var screenCapture: ScreenCaptureMonitor
    /// 未保存输入放在保护层外的草稿存储里：屏幕共享把设置内容整体移出视图树时，
    /// 这两个 sheet 连同 `@State` 一起消失，但草稿留着，回到内容态后自动重新打开。
    @EnvironmentObject private var drafts: EditingDraftStore

    @State private var showingRangeEditor = false
    @State private var editingEntry: LeaveEntry?
    @State private var undoSnapshot: [LeaveEntry]?
    @State private var message: String?

    private var calendar: Calendar { Loc.calendar }

    private var entries: [LeaveEntry] {
        settings.config.leaveEntries.sorted { $0.dayKey > $1.dayKey }
    }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Button(Loc.t("leave.backfill")) { showingRangeEditor = true }
                    .buttonStyle(.link)
                Spacer()
                if undoSnapshot != nil {
                    Button(Loc.t("leave.undo")) { undo() }
                        .buttonStyle(.link)
                }
            }

            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if entries.isEmpty {
                Text(Loc.t("leave.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
                summary
            }
        } header: {
            Text(Loc.t("leave.history"))
        } footer: {
            Text(Loc.t("leave.hint"))
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 两个补录/编辑弹窗都包一层保护：sheet 是独立窗口，保护期间哪怕只显示一帧，
        // 也不能是请假备注、计薪比例这些内容。`.modal` 形态里没有任何可操作元素。
        .sheet(isPresented: $showingRangeEditor) {
            ScreenCaptureGate(showsSettingsButton: false, placeholderStyle: .modal) {
                LeaveRangeEditorView(
                    draft: drafts.leaveRange.begin("range", seed: .seed()),
                    apply: { draft in apply(draft) },
                    onCancel: { showingRangeEditor = false },
                    onSaved: { showingRangeEditor = false }
                )
                .environmentObject(settings)
                .environmentObject(ticker)
                .environmentObject(drafts)
            }
            .environmentObject(screenCapture)
        }
        .sheet(item: $editingEntry) { entry in
            ScreenCaptureGate(showsSettingsButton: false, placeholderStyle: .modal) {
                LeaveEditorView(
                    entry: entry,
                    dayKey: entry.dayKey,
                    draft: drafts.leaveDay.begin(entry.id.uuidString, seed: .seed(entry: entry)),
                    save: { candidate in persist(candidate) },
                    delete: { id in remove(id) },
                    onCancel: { editingEntry = nil },
                    onSaved: { editingEntry = nil }
                )
                .environmentObject(settings)
                .environmentObject(ticker)
                .environmentObject(drafts)
            }
            .environmentObject(screenCapture)
        }
        // 保护层换内容时会重新挂载本视图（`@State` 归零），回到内容态的第一帧把
        // 没结束的编辑按草稿重新打开。没有任何草稿时什么都不做。
        .onAppear { restoreOpenEditors() }
    }

    // MARK: - 保护结束后的恢复

    /// 只在保护结束、视图重新出现时跑；草稿被用户取消/保存过就已经清空，这里什么都不做。
    private func restoreOpenEditors() {
        if drafts.leaveRange.isOpen {
            showingRangeEditor = true
        }
        if let draft = drafts.leaveDay.draft,
           let entry = settings.config.leaveEntries.first(where: { $0.dayKey == draft.dayKey }) {
            editingEntry = entry
        }
    }

    // MARK: - 行

    private func row(_ entry: LeaveEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.dayKey)
                        .font(.caption)
                        .monospacedDigit()
                    Text(LeaveLabels.kind(entry.kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(LeaveLabels.portion(entry.portion))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(Loc.t("leave.row.ratio", LeaveLabels.ratio(entry.payRatioBp)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(rowImpact(entry))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !entry.note.isEmpty {
                        Text(entry.note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Button {
                editingEntry = entry
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Loc.t("leave.edit"))
            Button {
                remove(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Loc.t("leave.delete"))
        }
    }

    /// 单条记录的影响：这一天的应发比例与折算金额。
    private func rowImpact(_ entry: LeaveEntry) -> String {
        let loss = LeaveImpact.loss(of: entry, engine: ticker.engine, config: settings.config)
        guard loss > 0 else { return Loc.t("leave.row.noImpact") }
        let currency = Formatters.currency(
            loss, code: settings.config.currencyCode, fractionDigits: 0)
        return Loc.t("leave.row.loss", currency)
    }

    // MARK: - 汇总

    /// 本年汇总：天数、预计少计金额、涉及的账期数量。
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                Loc.t(
                    "leave.summary.days",
                    totalFraction.formatted(
                        .number.precision(.fractionLength(0...1)).locale(Loc.locale))
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(
                Loc.t(
                    "leave.summary.loss",
                    Formatters.currency(
                        totalLoss, code: settings.config.currencyCode, fractionDigits: 0))
            )
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let periodText {
                Text(periodText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    /// 只统计本年（按本地日历年），避免把跨年旧账混进「本年」。
    private var yearEntries: [LeaveEntry] {
        let prefix = String(calendar.component(.year, from: Date()))
        return entries.filter { $0.dayKey.hasPrefix(prefix) }
    }

    private var totalFraction: Double {
        yearEntries.reduce(0) { $0 + $1.leaveFraction }
    }

    private var totalLoss: Double {
        yearEntries.reduce(0) {
            $0 + LeaveImpact.loss(of: $1, engine: ticker.engine, config: settings.config)
        }
    }

    /// 账期提示只在开启账期时给；不同账期按「账期起始日」去重后报个数和最晚一个。
    private var periodText: String? {
        guard settings.config.payroll.enabled,
            let payroll = settings.config.payroll.calendar,
            !yearEntries.isEmpty
        else { return nil }
        var periods: Set<Date> = []
        var latest: PayrollPeriod?
        for entry in yearEntries {
            guard let day = DayKeyCoder.current.date(from: entry.dayKey) else { continue }
            let period = payroll.period(containing: day)
            if latest == nil || period.endExclusive > (latest?.endExclusive ?? .distantPast) {
                latest = period
            }
            periods.insert(period.start)
        }
        guard let latest else { return nil }
        let lastKey = DayKeyCoder.current.key(
            for: calendar.date(byAdding: .day, value: -1, to: latest.endExclusive) ?? latest.settlementDate)
        return Loc.t(
            "leave.summary.periods",
            periods.count,
            DayKeyCoder.current.key(for: latest.start),
            lastKey
        )
    }

    // MARK: - 落账

    /// 单日新增/编辑。返回 nil 表示成功，交给编辑器显示错误。
    private func persist(_ candidate: LeaveEntry) -> LeaveLedgerError? {
        var ledger = LeaveLedger(entries: settings.config.leaveEntries)
        switch ledger.upsert(candidate) {
        case .failure(let failure):
            return failure
        case .success:
            snapshot()
            settings.config.leaveEntries = ledger.entries
            message = nil
            return nil
        }
    }

    private func remove(_ id: UUID) {
        var ledger = LeaveLedger(entries: settings.config.leaveEntries)
        guard ledger.entries.contains(where: { $0.id == id }) else { return }
        snapshot()
        ledger.remove(id: id)
        settings.config.leaveEntries = ledger.entries
        message = Loc.t("leave.deleted")
    }

    /// 区间补录：逐日写入，已存在的日期和非工作日按结果分别计数，不静默覆盖。
    private func apply(_ draft: LeaveRangeDraft) -> LeaveRangeResult {
        var ledger = LeaveLedger(entries: settings.config.leaveEntries)
        var result = LeaveRangeResult()
        let startDay = calendar.startOfDay(for: draft.start)
        let endDay = calendar.startOfDay(for: draft.end)
        var day = startDay
        var guardCount = 0
        while day <= endDay && guardCount < 400 {
            guardCount += 1
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? endDay }
            let key = DayKeyCoder.current.key(for: day)
            if ledger.entry(on: key) != nil {
                result.skippedExisting += 1
                continue
            }
            if draft.workdaysOnly && !ticker.engine.workCalendar.isWorkday(day) {
                result.skippedNonWorkday += 1
                continue
            }
            let entry = LeaveEntry(
                dayKey: key,
                kind: draft.kind,
                portion: draft.portion,
                payRatioBp: draft.payRatioBp,
                note: draft.note
            )
            if case .failure = ledger.upsert(entry) {
                result.skippedExisting += 1
                continue
            }
            result.added += 1
        }
        if result.added > 0 {
            snapshot()
            settings.config.leaveEntries = ledger.entries
        }
        message = nil
        return result
    }

    // MARK: - 撤销

    private func snapshot() {
        undoSnapshot = settings.config.leaveEntries
    }

    private func undo() {
        guard let undoSnapshot else { return }
        settings.config.leaveEntries = undoSnapshot
        self.undoSnapshot = nil
        message = Loc.t("leave.undo.done")
    }
}
