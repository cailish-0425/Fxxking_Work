import SwiftUI

/// 菜单栏主面板：一张「工资小票」。
///
/// 首屏顺序固定为：今日金额/状态及常用操作 → 发薪倒计时/账期 → 进度与可展开的工资明细 → 页脚。
/// 计时仍然只由这个 `TimelineView` 驱动（0.1 秒一帧，面板收起即停），不额外起定时器。
///
/// 本次改版只动展示与入口，计薪口径、隐私揭示、屏幕共享遮罩全部沿用原逻辑：
/// - 所有金额仍然包在 `PrivacyAmount` 里，`surface` 名字一个没改。
/// - 「编个理由」在主面板内就地切换成同一个 `LeaveReasonGeneratorView`，不新增窗口、
///   不绕过 `ScreenCaptureGate`，生成器本身也从不展示任何工资数字。
struct MenuContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var holidays: HolidayService
    @EnvironmentObject private var ticker: EarningsTicker
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var overtime: OvertimeController
    /// 交互状态（理由会话、是否展开明细）由保护层外的 `PanelUIState` 持有：
    /// 屏幕采集把内容整体移出视图树时这些状态不销毁，短采集结束后原样接回来。
    @EnvironmentObject private var panel: PanelUIState
    /// 今日请假弹窗里未保存的输入：保护层把面板换掉后仍然在，重新打开接着填。
    @EnvironmentObject private var drafts: EditingDraftStore
    @EnvironmentObject private var screenCapture: ScreenCaptureMonitor
    @Environment(\.openSettings) private var openSettings

    @State private var showingLeaveEditor = false

    var body: some View {
        // 外面再包一层稳定容器：`.sheet` 不要挂在 TimelineView 的内容闭包里，
        // 否则每次 0.1 秒重算都会把同一个 sheet 重新描述一遍。
        VStack(spacing: 0) {
            content
        }
        // 请假弹窗是独立窗口：包一层保护，共享期间哪怕只显示一帧也不会露出计薪比例。
        .sheet(isPresented: $showingLeaveEditor) {
            ScreenCaptureGate(showsSettingsButton: false, contentWidth: 340, placeholderStyle: .modal) {
                TodayLeavePanelView(
                    draft: drafts.todayLeaveDay.begin(todayLeaveKey, seed: todayLeaveSeed),
                    onDismiss: { showingLeaveEditor = false }
                )
                .environmentObject(settings)
                .environmentObject(ticker)
                .environmentObject(drafts)
            }
            .environmentObject(screenCapture)
        }
        // 保护层把面板换掉时 `.sheet` 会跟着消失；回到内容态的第一帧，若草稿还在
        // （用户没点保存/取消）就把弹窗按草稿重新打开。没有草稿时什么都不做。
        .onAppear {
            if drafts.todayLeaveDay.isOpen { showingLeaveEditor = true }
        }
        // 注意：这里没有 `.onDisappear` 复位。面板被屏幕保护层换掉时同样会触发
        // `onDisappear`，一并清空就等于"每次截图都丢理由"。真正的面板收起复位由
        // App 的 `MenuBarPanelVisibility(onClose:)` 调 `PanelUIState.resetForPanelClose()`。
    }

    // MARK: - 今日请假草稿

    private var todayLeaveKey: String {
        DayKeyCoder.current.key(for: Calendar.current.startOfDay(for: Date()))
    }

    private var todayLeaveSeed: LeaveDayEditorDraft {
        let day = Calendar.current.startOfDay(for: Date())
        let existing = LeaveLedger(entries: settings.config.leaveEntries).entry(on: todayLeaveKey)
        return LeaveDayEditorDraft.seed(day: day, existing: existing)
    }

    @ViewBuilder
    private var content: some View {
        if panel.showingReasonGenerator {
            // 同一个生成器界面，进入即开始思考（自身 `.task` 负责），
            // 只提供「再编一个 / 复制 / 关闭」，不写请假记录、不碰工资。
            // 被屏幕保护层中断过的话，`initialSuggestion` 会把同一句理由接回来，
            // 不重新抽签、也不重播思考动画。
            LeaveReasonGeneratorView(
                generate: {
                    let reason = panel.nextReason()
                    return LeaveReasonSuggestion(id: reason.id, text: reason.text)
                },
                onDismiss: { panel.closeGenerator() },
                initialSuggestion: panel.lastReason.map {
                    LeaveReasonSuggestion(id: $0.id, text: $0.text)
                }
            )
            .frame(width: PanelMetrics.width)
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                receipt(at: context.date)
            }
        }
    }

    // MARK: - 小票

    private func receipt(at now: Date) -> some View {
        let earnings = ticker.engine.snapshot(at: now)
        return VStack(alignment: .leading, spacing: 10) {
            // 摸鱼战报是一次性提示，放在最上面，看完手动关掉。
            if let report = ticker.awayReport {
                awayNotice(report)
            }
            todayBlock(earnings, at: now)
            overtimeRow(at: now)
            if settings.config.payroll.enabled {
                Divider()
                paydayBlock(at: now)
            }
            Divider()
            progressBlock(earnings)
            detailsBlock(earnings, at: now)
            Divider()
            footer
        }
        .padding(.horizontal, PanelMetrics.contentPadding)
        .padding(.vertical, 14)
        .frame(width: PanelMetrics.width)
    }

    // MARK: - 今日

    private func todayBlock(_ earnings: Earnings, at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(earnings.status.isEarning ? Color.green : Color.secondary.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(earnings.status.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(scheduleText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(Loc.t("menu.progress.today"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            PrivacyAmount(surface: "menu.day") {
                Formatters.currency(earnings.dayEarned, code: settings.config.currencyCode)
            }
            .font(.system(size: 32, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .minimumScaleFactor(0.6)
            .lineLimit(1)

            PrivacyAmount(surface: "menu.perSecond") {
                Loc.t(
                    "menu.perSecond",
                    Formatters.currency(
                        earnings.perSecond, code: settings.config.currencyCode, fractionDigits: 4)
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            actionRow(earnings)

            if settings.config.snarkEnabled {
                Text(Snark.line(for: earnings))
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scheduleText: String {
        Formatters.clockTime(minutesFromMidnight: settings.config.startMinutes)
            + " – "
            + Formatters.clockTime(minutesFromMidnight: settings.config.endMinutes)
    }

    /// 今日两个并排入口：记请假 / 编个理由。
    ///
    /// 两个独立 `Button`，命中区各自撑满一半宽度（`contentShape` + `maxWidth: .infinity`），
    /// 各带自己的 VoiceOver 名称与提示，不会出现点一个触发两个的问题。
    private func actionRow(_ earnings: Earnings) -> some View {
        let leaveTitle =
            earnings.leaveEntry == nil ? Loc.t("leave.today.action") : Loc.t("leave.edit")
        return HStack(spacing: 8) {
            Button {
                showingLeaveEditor = true
            } label: {
                actionLabel(
                    leaveTitle,
                    systemImage: earnings.leaveEntry == nil
                        ? "calendar.badge.plus" : "calendar.badge.checkmark")
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .help(leaveTitle)
            .accessibilityLabel(leaveTitle)
            .accessibilityHint(Loc.t("leave.today.title"))

            Button {
                panel.showingReasonGenerator = true
            } label: {
                actionLabel(Loc.t("leaveReason.ui.entry"), systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .help(Loc.t("leaveReason.ui.entry"))
            .accessibilityLabel(Loc.t("leaveReason.ui.entry"))
            .accessibilityHint(Loc.t("leaveReason.ui.hint"))
        }
        .padding(.top, 4)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(title)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 22)
        .contentShape(Rectangle())
    }

    // MARK: - 加班

    /// 加班行：进行中显示橙色圆点 + 时长 + 逐秒金额 + 停止；否则一个开始入口。
    /// 只有正常工作日规定下班时刻之后才能显式开（休息日/假日也能开，提示里会说明）。
    /// 本月正常/加班/合计的拆分挪进「工资明细」，首屏不再常驻三行数字。
    @ViewBuilder
    private func overtimeRow(at now: Date) -> some View {
        let summary = ticker.engine.overtimeSummary(at: now)
        if let active = summary.active {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(Loc.t("overtime.active"))
                    .font(.caption.weight(.semibold))
                Text(Formatters.duration(summary.activeSeconds))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                PrivacyAmount(surface: "overtime.active") {
                    Formatters.currency(summary.activeAmount, code: active.currencyCode)
                }
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                Button {
                    overtime.stop(at: now)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help(Loc.t("overtime.stop"))
                .accessibilityLabel(Loc.t("overtime.stop"))
            }
        } else {
            let canStartOvertime = OvertimeLedger.canStart(
                at: now, config: settings.config,
                workCalendar: ticker.engine.workCalendar, calendar: ticker.engine.calendar)
            let startHelp =
                canStartOvertime
                ? Loc.t("overtime.start")
                : Loc.t(
                    "overtime.start.afterTime",
                    Formatters.clockTime(minutesFromMidnight: settings.config.endMinutes))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(Loc.t("overtime.section"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        let kind = settings.config.overtimePayDefault
                        let mult = settings.config.overtimeMultiplier
                        overtime.start(at: now, kind: kind, multiplier: mult)
                    } label: {
                        Label(Loc.t("overtime.start"), systemImage: "play.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canStartOvertime)
                    .help(startHelp)
                    .accessibilityHint(startHelp)
                }
                if !canStartOvertime {
                    Text(startHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - 发薪日与账期

    /// 发薪倒计时放成第二块的主角：剩余天数用大字，账期范围/本账期已赚退到普通行。
    /// 发薪日只是名义日历提示，这里不标「已到账」。
    @ViewBuilder
    private func paydayBlock(at now: Date) -> some View {
        let summary = ticker.engine.payrollSummary(at: now)
        VStack(alignment: .leading, spacing: 6) {
            PanelSectionHeader(title: Loc.t("payroll.section"))
            if let remainingDays = summary.remainingDays {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Loc.t("payroll.nextPayday"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(
                        remainingDays == 0
                            ? Loc.t("payroll.today")
                            : Loc.t("payroll.inDays", remainingDays)
                    )
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                }
            }
            if let range = summary.rangeDescription {
                PanelRow(Loc.t("payroll.period")) {
                    Text(range)
                }
            }
            if summary.totalGross > 0 {
                PanelRow(Loc.t("payroll.earned")) {
                    PrivacyAmount(surface: "payroll.earned") {
                        Formatters.currency(summary.totalGross, code: settings.config.currencyCode)
                    }
                }
            }
            ForEach(summary.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 进度

    private func progressBlock(_ earnings: Earnings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelProgressRow(
                surface: "progress.today",
                title: Loc.t("menu.progress.today"),
                fraction: earnings.dayFraction,
                detail:
                    "\(Formatters.currency(earnings.dayEarned, code: settings.config.currencyCode)) / \(Formatters.currency(earnings.dayTotal, code: settings.config.currencyCode))"
            )
            PanelProgressRow(
                surface: "progress.month",
                title: Loc.t("menu.progress.month"),
                fraction: earnings.monthFraction,
                detail:
                    "\(Formatters.currency(earnings.monthEarned, code: settings.config.currencyCode, fractionDigits: 0)) / \(Formatters.currency(earnings.monthTotal, code: settings.config.currencyCode, fractionDigits: 0))"
            )
            PanelProgressRow(
                surface: "progress.year",
                title: Loc.t("menu.progress.year"),
                fraction: earnings.yearFraction,
                detail:
                    "\(Formatters.currency(earnings.yearEarned, code: settings.config.currencyCode, fractionDigits: 0)) / \(Formatters.currency(earnings.yearTotal, code: settings.config.currencyCode, fractionDigits: 0))"
            )
        }
    }

    // MARK: - 工资明细（可展开）

    /// 明细区默认收起，展开后是工资拆分 + 今日剩余/工作日/下个假期 + 假日数据状态。
    ///
    /// 标题优先用 `menu.details`；词条还没进 `Localizable.strings` 时回退到
    /// `menu.progress.month`（「本月」），避免界面直接显示 key。
    private var detailsTitle: String {
        let key = "menu.details"
        let text = Loc.t(key)
        return text == key ? Loc.t("menu.progress.month") : text
    }

    private func detailsBlock(_ earnings: Earnings, at now: Date) -> some View {
        DisclosureGroup(isExpanded: $panel.detailsExpanded) {
            detailsContent(earnings, at: now)
                .padding(.top, 8)
        } label: {
            Label(detailsTitle, systemImage: "list.bullet.rectangle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
    }

    private func detailsContent(_ earnings: Earnings, at now: Date) -> some View {
        let summary = ticker.engine.overtimeSummary(at: now)
        let isNet = ticker.engine.isNetActive
        let normal =
            isNet
            ? ticker.engine.monthEarnedNetRegular(at: now)
            : ticker.engine.monthEarnedGross(at: now)
        let overtimePaid = isNet ? ticker.engine.monthOvertimeNet(at: now) : summary.monthPaid
        let hasOvertime = summary.monthPaid > 0 || summary.monthLoss > 0 || overtimePaid > 0
        return VStack(alignment: .leading, spacing: 6) {
            if hasOvertime {
                // 数值跟随设置里的税前/税后口径，主面板不重复展示口径标签。
                breakdownRow(Loc.t("overtime.normal"), normal)
                if overtimePaid > 0 {
                    breakdownRow(Loc.t("overtime.ot"), overtimePaid)
                }
                breakdownRow(Loc.t("overtime.total"), normal + overtimePaid)
                if summary.monthLoss > 0 {
                    // 无偿加班只是参考倒扣，不计入上面的工资合计。
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PrivacyAmount(surface: "overtime.loss") {
                            Loc.t(
                                "overtime.loss",
                                Formatters.currency(
                                    summary.monthLoss, code: settings.config.currencyCode))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                Divider()
                    .padding(.vertical, 2)
            }
            factRow(Loc.t("menu.fact.remaining"), Formatters.duration(earnings.remainingSecondsToday))
            factRow(Loc.t("menu.fact.workdays"), Loc.t("menu.days", ticker.engine.workdaysThisMonth))
            if let next = nextHolidayText {
                factRow(Loc.t("menu.fact.nextHoliday"), next)
            }
            if case .failed(let message) = holidays.status {
                // 只在加载失败时给重试入口：手动刷假日是极低频操作，常驻全是噪音。
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Loc.t("menu.holidayError", message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(Loc.t("menu.action.refresh")) { ticker.refreshHolidays(force: true) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityLabel(Loc.t("menu.action.refresh"))
                }
            }
            if case .unsupportedCountry = holidays.status {
                Text(Loc.t("menu.unsupportedCountry", CountryCatalog.name(for: settings.config.countryCode))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func breakdownRow(_ title: String, _ amount: Double) -> some View {
        PanelRow(title) {
            PrivacyAmount(surface: "overtime.breakdown.\(title)") {
                Formatters.currency(amount, code: settings.config.currencyCode)
            }
        }
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        PanelRow(title) {
            Text(value)
        }
    }

    private var nextHolidayText: String? {
        let todayKey = DayKeyCoder.current.key(for: Date())
        guard let next = holidays.upcoming(from: todayKey, limit: 1).first,
            let date = DayKeyCoder.current.date(from: next.date)
        else { return nil }
        let days =
            Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: Date()),
                to: Calendar.current.startOfDay(for: date)
            ).day ?? 0
        let suffix = days <= 0 ? Loc.t("menu.holiday.today") : Loc.t("menu.holiday.inDays", days)
        return Loc.t("menu.holiday.entry", next.localName, suffix)
    }

    // MARK: - 摸鱼战报

    /// 一次性提示：中性底色 + 独立关闭按钮，不再整卡做成按钮、也不再借橙色。
    private func awayNotice(_ report: AwayReport) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cup.and.saucer")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(Loc.t("away.title"))
                    .font(.caption.weight(.semibold))
                PrivacyAmount(surface: "away.amount") {
                    Loc.t(
                        "away.body",
                        Formatters.duration(report.paidSeconds),
                        Formatters.currency(report.amount, code: settings.config.currencyCode)
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                ticker.awayReport = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Loc.t("away.dismiss"))
            .accessibilityLabel(Loc.t("away.dismiss"))
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(Loc.t("menu.action.settings")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.link)
            .accessibilityLabel(Loc.t("menu.action.settings"))

            Button(Loc.t("menu.action.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
            .accessibilityLabel(Loc.t("menu.action.quit"))
        }
        .font(.caption)
    }
}
