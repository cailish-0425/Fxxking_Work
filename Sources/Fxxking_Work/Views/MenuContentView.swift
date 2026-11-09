import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var holidays: HolidayService
    @EnvironmentObject private var ticker: EarningsTicker
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var overtime: OvertimeController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 弹窗可见时才按 0.1 秒刷新，关掉之后这个 TimelineView 就不再驱动了。
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let earnings = ticker.engine.snapshot(at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                if let report = ticker.awayReport {
                    awayCard(report)
                }
                header(earnings)
                Divider()
                overtimeZone(at: context.date)
                payrollZone(at: context.date)
                progressSection(earnings)
                factsSection(earnings)
                Divider()
                footer
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 340)
        }
    }

    // MARK: - 加班区

    /// 加班显式操作区：进行中逐秒显示加班工资/损失 + 结束按钮；否则一个开始入口。
    /// 只有正常工作日规定下班时刻之后才显示开始入口；休息日/假日也能显式开（标明休息日）。
    /// 不再用整块橙色卡片，改成首行对齐的普通区块，只在进行中保留一个橙色圆点作状态提示。
    @ViewBuilder
    private func overtimeZone(at now: Date) -> some View {
        let summary = ticker.engine.overtimeSummary(at: now)
        VStack(alignment: .leading, spacing: 5) {
            if let active = summary.active {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text(Loc.t("overtime.active"))
                        .font(.caption).bold()
                    Text(Formatters.duration(summary.activeSeconds))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    PrivacyAmount(surface: "overtime.active") {
                        Formatters.currency(summary.activeAmount, code: active.currencyCode)
                    }
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
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
                HStack(spacing: 8) {
                    Text(Loc.t("overtime.section"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        let kind = settings.config.overtimePayDefault
                        let mult = settings.config.overtimeMultiplier
                        overtime.start(at: now, kind: kind, multiplier: mult)
                    } label: {
                        Label(Loc.t("overtime.start"), systemImage: "play.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!OvertimeLedger.canStart(
                        at: now, config: settings.config,
                        workCalendar: ticker.engine.workCalendar, calendar: ticker.engine.calendar))
                }
            }

            // 本月正常/加班/合计拆列，仅实际记录加班；无偿单独计损失，不进合计。
            // 口径与 header 同模式（net 模式拆 net，gross 拆 gross），并逐项标实际口径，不无标注混列。
            let isNet = ticker.engine.isNetActive
            let normal = isNet ? ticker.engine.monthEarnedNetRegular(at: now) : ticker.engine.monthEarnedGross(at: now)
            let overtimePaid = isNet ? ticker.engine.monthOvertimeNet(at: now) : summary.monthPaid
            let modeSuffix = isNet ? Loc.t("overtime.breakdown.net") : Loc.t("overtime.breakdown.gross")
            if summary.monthPaid > 0 || summary.monthLoss > 0 || overtimePaid > 0 {
                breakdownRow(Loc.t("overtime.normal") + modeSuffix, normal)
                if overtimePaid > 0 {
                    breakdownRow(Loc.t("overtime.ot") + modeSuffix, overtimePaid)
                    breakdownRow(Loc.t("overtime.total") + modeSuffix, normal + overtimePaid)
                }
                if summary.monthLoss > 0 {
                    HStack {
                        Text(Loc.t("overtime.loss", Formatters.currency(summary.monthLoss, code: settings.config.currencyCode)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func breakdownRow(_ title: String, _ amount: Double) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            PrivacyAmount(surface: "overtime.breakdown.\(title)") {
                Formatters.currency(amount, code: settings.config.currencyCode)
            }
            .font(.caption2)
            .monospacedDigit()
        }
    }

    // MARK: - 摸鱼战报

    /// 摸鱼战报卡片：外层不再整卡按钮，改为独立关闭按钮 + 金额点击区，避免双层 Button 抢事件。
    private func awayCard(_ report: AwayReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cup.and.saucer.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(Loc.t("away.title"))
                    .font(.caption)
                    .bold()
                PrivacyAmount(surface: "away.amount") {
                    Loc.t(
                        "away.body",
                        Formatters.duration(report.paidSeconds),
                        Formatters.currency(report.amount, code: settings.config.currencyCode)
                    )
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                ticker.awayReport = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(Loc.t("away.dismiss"))
            .accessibilityLabel(Loc.t("away.dismiss"))
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Header

    /// 紧凑头部：今日状态 + 今日已赚 + 每秒单价 + 吐槽，全部左标签右金额对齐。
    private func header(_ earnings: Earnings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(earnings.status.isEarning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(earnings.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(
                    Formatters.clockTime(minutesFromMidnight: settings.config.startMinutes)
                        + " – "
                        + Formatters.clockTime(minutesFromMidnight: settings.config.endMinutes)
                )
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            }

            PrivacyAmount(surface: "menu.day") {
                Formatters.currency(earnings.dayEarned, code: settings.config.currencyCode)
            }
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .padding(.top, 2)

            PrivacyAmount(surface: "menu.perSecond") {
                Loc.t(
                    "menu.perSecond",
                    Formatters.currency(earnings.perSecond, code: settings.config.currencyCode, fractionDigits: 4)
                )
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if settings.config.snarkEnabled {
                Text(Snark.line(for: earnings))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 发薪日与账期区

    /// 小型展示：下个名义发薪日/剩余天数、本账期范围与已赚（正常/加班/合计/损失）。
    /// 仅启用自定义账期才显示；发薪日只作名义日历提示，不标已到账。
    /// 改为左标签右金额的普通区块，不再铺一层浅蓝底色。
    @ViewBuilder
    private func payrollZone(at now: Date) -> some View {
        if settings.config.payroll.enabled {
            let summary = ticker.engine.payrollSummary(at: now)
            VStack(alignment: .leading, spacing: 4) {
                if let remainingDays = summary.remainingDays {
                    HStack {
                        Text(Loc.t("payroll.nextPayday"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(
                            remainingDays == 0
                                ? Loc.t("payroll.today")
                                : Loc.t("payroll.inDays", remainingDays)
                        )
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                    }
                }
                if let range = summary.rangeDescription {
                    HStack {
                        Text(Loc.t("payroll.period"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(range)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if summary.totalGross > 0 {
                    HStack {
                        Text(summary.netMode ? Loc.t("payroll.earned.net") : Loc.t("payroll.earned"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        PrivacyAmount(surface: "payroll.earned") {
                            Formatters.currency(summary.totalGross, code: settings.config.currencyCode)
                        }
                        .font(.caption)
                        .monospacedDigit()
                    }
                }
                ForEach(summary.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Progress

    private func progressSection(_ earnings: Earnings) -> some View {
        VStack(spacing: 8) {
            ProgressRow(
                surface: "progress.today",
                title: Loc.t("menu.progress.today"),
                fraction: earnings.dayFraction,
                detail: "\(Formatters.currency(earnings.dayEarned, code: settings.config.currencyCode)) / \(Formatters.currency(earnings.dayTotal, code: settings.config.currencyCode))",
                tint: .green
            )
            ProgressRow(
                surface: "progress.month",
                title: Loc.t("menu.progress.month"),
                fraction: earnings.monthFraction,
                detail: "\(Formatters.currency(earnings.monthEarned, code: settings.config.currencyCode, fractionDigits: 0)) / \(Formatters.currency(earnings.monthTotal, code: settings.config.currencyCode, fractionDigits: 0))",
                tint: .blue
            )
            ProgressRow(
                surface: "progress.year",
                title: Loc.t("menu.progress.year"),
                fraction: earnings.yearFraction,
                detail: "\(Formatters.currency(earnings.yearEarned, code: settings.config.currencyCode, fractionDigits: 0)) / \(Formatters.currency(earnings.yearTotal, code: settings.config.currencyCode, fractionDigits: 0))",
                tint: .purple
            )
        }
    }

    // MARK: - Facts

    private func factsSection(_ earnings: Earnings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            factRow(Loc.t("menu.fact.remaining"), Formatters.duration(earnings.remainingSecondsToday))
            factRow(Loc.t("menu.fact.workdays"), Loc.t("menu.days", ticker.engine.workdaysThisMonth))
            if let next = nextHolidayText {
                factRow(Loc.t("menu.fact.nextHoliday"), next)
            }
            if case .failed(let message) = holidays.status {
                // 只在加载失败时才给重试入口。主动刷新假日是个极低频操作，
                // 常驻在弹窗里全是噪音，需要手动刷的场景在设置页里。
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Loc.t("menu.holidayError", message))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(Loc.t("menu.action.refresh")) { ticker.refreshHolidays(force: true) }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
            if case .unsupportedCountry = holidays.status {
                Text(Loc.t("menu.unsupportedCountry", CountryCatalog.name(for: settings.config.countryCode)))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .monospacedDigit()
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(Loc.t("menu.action.settings")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.link)

            Button(Loc.t("menu.action.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
        .font(.caption)
    }
}

struct ProgressRow: View {
    let surface: String
    let title: String
    let fraction: Double
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 金额和百分比尽量并到标题那一行，省下三行高度。但法语标题长、日元金额位数多，
            // 挤在一起会溢出，所以放不下时自动退回金额单独一行。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleText
                    Spacer(minLength: 4)
                    detailText
                    percentText
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleText
                        Spacer(minLength: 4)
                        percentText
                    }
                    detailText
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 2))
                }
            }
            .frame(height: 5)
        }
    }

    // 这三段都限死单行：Text 默认可以折行，那样 ViewThatFits 会认为水平方向永远放得下，
    // 一行那个方案就永远被选中，长金额直接顶破边界。
    private var titleText: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var detailText: some View {
        PrivacyAmount(surface: surface) { detail }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var percentText: some View {
        Text(Formatters.percent(fraction))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}
