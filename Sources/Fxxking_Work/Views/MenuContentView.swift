import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var holidays: HolidayService
    @EnvironmentObject private var ticker: EarningsTicker
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 弹窗可见时才按 0.1 秒刷新，关掉之后这个 TimelineView 就不再驱动了。
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let earnings = ticker.engine.snapshot(at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                if let report = ticker.awayReport {
                    awayCard(report)
                }
                header(earnings)
                Divider()
                meritZone
                Divider()
                progressSection(earnings)
                Divider()
                factsSection(earnings)
                Divider()
                footer
            }
            .padding(16)
            .frame(width: 340)
        }
    }

    // MARK: - 摸鱼战报

    /// 系统通知可能被专注模式拦下或者压根没授权，这张卡片是兜底。
    ///
    /// 整张卡片都是关闭按钮。原先只有右上角那个叉能点，命中区不到 14pt 见方，
    /// 对一个"看完就该消失"的提示来说没必要要求这种精度。叉留着当可关闭的记号，
    /// 但它只是画上去的，真正接管点击的是外面这个按钮。
    private func awayCard(_ report: AwayReport) -> some View {
        Button {
            ticker.awayReport = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cup.and.saucer.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Loc.t("away.title"))
                        .font(.caption)
                        .bold()
                    Text(
                        Loc.t(
                            "away.body",
                            Formatters.duration(report.paidSeconds),
                            Formatters.currency(report.amount, code: settings.config.currencyCode)
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            // 背景色只有一成不透明度，不铺满命中区的话，文字之间的空隙点不动。
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(Loc.t("away.dismiss"))
        .accessibilityLabel(Loc.t("away.title"))
        .accessibilityHint(Loc.t("away.dismiss"))
    }

    // MARK: - Header

    private func header(_ earnings: Earnings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(earnings.status.isEarning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(earnings.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    Formatters.clockTime(minutesFromMidnight: settings.config.startMinutes)
                        + " – "
                        + Formatters.clockTime(minutesFromMidnight: settings.config.endMinutes)
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            HStack(alignment: .center, spacing: 8) {
                Text(Formatters.currency(earnings.dayEarned, code: settings.config.currencyCode))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Spacer(minLength: 0)

                MuyuView(earning: earnings.status.isEarning)
            }

            Text(
                Loc.t(
                    "menu.perSecond",
                    Formatters.currency(earnings.perSecond, code: settings.config.currencyCode, fractionDigits: 4)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if settings.config.snarkEnabled {
                Text(Snark.line(for: earnings))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
    }

    // MARK: - 功德区

    /// 功德区 UI 骨架。数据先用 `MeritSnapshot.mock` 占位；
    /// Claude Code 的 `MeritStore` 就绪后，从这里换成真实快照。
    private var meritZone: some View {
        MeritPanel(snapshot: .mock)
    }

    // MARK: - Progress

    private func progressSection(_ earnings: Earnings) -> some View {
        VStack(spacing: 10) {
            ProgressRow(
                title: Loc.t("menu.progress.today"),
                fraction: earnings.dayFraction,
                detail:
                    "\(Formatters.currency(earnings.dayEarned, code: settings.config.currencyCode)) / \(Formatters.currency(earnings.dayTotal, code: settings.config.currencyCode))",
                tint: .green
            )
            ProgressRow(
                title: Loc.t("menu.progress.month"),
                fraction: earnings.monthFraction,
                detail:
                    "\(Formatters.currency(earnings.monthEarned, code: settings.config.currencyCode, fractionDigits: 0)) / \(Formatters.currency(earnings.monthTotal, code: settings.config.currencyCode, fractionDigits: 0))",
                tint: .blue
            )
            ProgressRow(
                title: Loc.t("menu.progress.year"),
                fraction: earnings.yearFraction,
                detail:
                    "\(Formatters.currency(earnings.yearEarned, code: settings.config.currencyCode, fractionDigits: 0)) / \(Formatters.currency(earnings.yearTotal, code: settings.config.currencyCode, fractionDigits: 0))",
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

/// 不紧不慢地敲木鱼，每 0.8 秒一记。
///
/// 自己驱动一个 `TimelineView(.animation)` 而不是复用外层那 0.1 秒的节奏：落槌只有三分之一秒，
/// 10 帧每秒的话整个下落过程只剩三帧，看起来是瞬移不是敲。
/// 这个 TimelineView 只在弹窗可见时才跑，关掉就停。
private struct MuyuView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 一记敲击的周期。抬槌与落槌铺满整个周期，中间不留空档，动作才不显得赶。
    private static let period = 0.8
    /// 周期内敲中的时刻，也就是落槌耗时。
    private static let strike = 0.34
    /// 举槌时槌头高出接触点多少。
    private static let raised: CGFloat = 11
    /// 内部画布。所有部件的坐标都按这个尺寸算，最后整体缩放。
    private static let canvas = CGSize(width: 68, height: 76)

    /// 此刻是否在计薪。不在就停手——午休、下班、假日都没在赚钱，木鱼没道理自己响。
    let earning: Bool

    /// 鼠标是否停在木鱼上。停着的时候槌子在指针手里，画面里的自动敲击让位。
    @State private var hovering = false
    /// 最近一次手动敲击的时刻。
    @State private var lastStrike: Date?
    /// 是否往光标栈里压过木槌。push 和 pop 必须配对，弄丢了木槌光标会赖在屏幕上。
    @State private var pushedCursor = false

    var body: some View {
        Group {
            // 手动敲随时奉陪；自动敲只在计薪时进行，系统关了动效则一直不动。
            if hovering || (earning && !reduceMotion) {
                // 30 帧足够表现敲击，不必跟着 120Hz 屏白跑。
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    pose(at: context.date)
                }
            } else {
                // 停手时定格在举槌的姿势，槌子悬着，不做任何运动。
                scene(sinceStrike: nil, lift: Self.raised)
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .scaleEffect(muyuZoom)
        .frame(width: Self.canvas.width * muyuZoom, height: Self.canvas.height * muyuZoom)
        .contentShape(Rectangle())
        .onTapGesture { lastStrike = Date() }
        .onHover(perform: hover)
        .onDisappear(perform: releaseCursor)
        .accessibilityHidden(true)
    }

    /// 悬停时只回应真正的点击，离开后回到自动敲击。
    private func pose(at date: Date) -> some View {
        if hovering {
            return scene(sinceStrike: lastStrike.map(date.timeIntervalSince), lift: 0)
        }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        // 循环里任何时刻都能算出"距上一记多久"，跨周期时要回溯到上一圈那记。
        let since = phase >= Self.strike ? phase - Self.strike : phase + Self.period - Self.strike
        return scene(sinceStrike: since, lift: malletLift(phase: phase))
    }

    /// 各部件直接给中心坐标，比一层层 offset 好推算落点。
    ///
    /// 落槌点选在背部斜坡横向 60% 处：那儿的轮廓顶端离素材上沿只有 1.7pt，
    /// 既是传统上真正敲击的部位，又避开了尾部盘绕的花纹，还省下抬槌需要的净空。
    private func scene(sinceStrike: Double?, lift: CGFloat) -> some View {
        ZStack {
            fish(sinceStrike: sinceStrike).position(x: 34, y: 52.6)
            ripples(sinceStrike: sinceStrike).position(x: 11, y: 38)
            // 悬停时槌子换到了指针上，画面里这根就得让开，否则等于有两根槌。
            MuyuMallet()
                .position(x: 38.4, y: 20)
                .offset(y: -lift)
                .opacity(hovering ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    // MARK: - 光标接管

    private func hover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            guard !pushedCursor, let cursor = MalletCursor.shared else { return }
            cursor.push()
            pushedCursor = true
        } else {
            releaseCursor()
        }
    }

    /// 弹窗要是在指针停在木鱼上的时候关掉，`onHover(false)` 不保证会来，
    /// 那次 push 就没人还，木槌光标会一直跟着鼠标跑。所以消失时再兜一次底。
    private func releaseCursor() {
        guard pushedCursor else { return }
        NSCursor.pop()
        pushedCursor = false
    }

    // MARK: - 各个零件

    /// 团鱼形木鱼连木鱼座。敲中的一瞬间压扁一下再弹回，用衰减的余弦模拟。
    ///
    /// 昂首缩尾的轮廓、横开的鱼口、盘绕的尾，这些特征用矢量图形拼到 44pt 见方都会糊成一坨，
    /// 所以本体走图片素材；木槌要独立升降，仍然是矢量画的。
    ///
    /// 用 `NSImage(named:)` 而不是 `Image("Muyu")`：后者只认资源目录（asset catalog），
    /// 这个 bundle 是构建脚本手工拼的，素材是散装 PNG，得走 AppKit 那条查找路径。
    /// AppKit 会按名字缓存，所以每帧调一次只是一次字典查询。
    private func fish(sinceStrike: Double?) -> some View {
        let thump = thump(sinceStrike: sinceStrike)
        return Image(nsImage: NSImage(named: "Muyu") ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: 44, height: 46.8)
            .scaleEffect(x: 1 + 0.03 * thump, y: 1 - 0.04 * thump, anchor: .bottom)
            // 悬停时轻轻涨一点，告诉用户这东西能点。
            .scaleEffect(hovering ? 1.04 : 1, anchor: .bottom)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// 敲响之后荡开的两道声波。
    private func ripples(sinceStrike: Double?) -> some View {
        // 声波在下一记落槌之前散干净，免得两记叠在一起。
        let life = 0.42
        let since = sinceStrike ?? .infinity
        let alive = since >= 0 && since < life
        let progress = alive ? since / life : 0
        return ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .trim(from: 0.56, to: 0.70)
                    .stroke(
                        Color(red: 0.85, green: 0.68, blue: 0.31),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 20 + CGFloat(i) * 11, height: 20 + CGFloat(i) * 11)
            }
        }
        .opacity(alive ? (1 - progress) * 0.7 : 0)
        .scaleEffect(1 + progress * 0.5)
    }

    // MARK: - 时间曲线

    /// 槌头高出接触点多少。首尾都停在最高处，所以循环处接得上、看不出跳帧。
    private func malletLift(phase: Double) -> CGFloat {
        if phase < Self.strike {
            // 余弦缓入：起手慢，快碰到木鱼时才提速。比平方曲线柔和，是"敲"不是"砸"。
            return Self.raised * cos(phase / Self.strike * .pi / 2)
        }
        // 抬回占满周期剩下的部分，不留静止时间。
        let t = (phase - Self.strike) / (Self.period - Self.strike)
        return Self.raised * sin(t * .pi / 2)
    }

    /// 敲中瞬间为 1，随后衰减振荡回 0。手动敲和自动敲共用这条曲线。
    private func thump(sinceStrike: Double?) -> Double {
        guard let since = sinceStrike, since >= 0, since < 0.3 else { return 0 }
        return exp(-since * 11) * cos(since * 30)
    }

}

/// 木鱼整体的放大倍率。
///
/// 内部所有坐标都按 68x76 的画布算好再统一缩放，所以调大小只用动这一个数，
/// 落槌点、抬槌高度、声波位置之间的相对关系不会散。木槌光标也跟着它走。
private let muyuZoom: CGFloat = 1.35

/// 木槌与声波的配色，跟素材里的木色对齐。
private enum Palette {
    static let gold = Color(red: 0.85, green: 0.69, blue: 0.36)
    static let handleLit = Color(red: 0.78, green: 0.58, blue: 0.34)
    static let handleDark = Color(red: 0.55, green: 0.36, blue: 0.18)
    static let headLit = Color(red: 0.72, green: 0.49, blue: 0.26)
    static let headDark = Color(red: 0.38, green: 0.21, blue: 0.08)
}

/// 木槌，棰头橄榄形。界面里那根和光标里那根是同一个视图，只是倍率不同。
///
/// 柄稍稍右倾：笔直的细杆加正圆的头看着像温度计，斜一点才像有只手在上头握着。
/// 倾斜以槌头底端为轴，所以敲击点不会跟着偏，光标热点也能直接取底端中点。
private struct MuyuMallet: View {
    var scale: CGFloat = 1

    /// 未旋转时的尺寸，光标那边要靠它算画布和热点。
    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: 15 * scale, height: 23 * scale)
    }

    var body: some View {
        VStack(spacing: -2 * scale) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Palette.handleLit, Palette.handleDark],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 5 * scale, height: 14 * scale)
            // 橄榄形：横着的椭圆，比正圆更像棰头。
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Palette.headLit, Palette.headDark],
                        center: UnitPoint(x: 0.32, y: 0.28),
                        startRadius: 0,
                        endRadius: 14 * scale
                    )
                )
                .frame(width: 15 * scale, height: 11 * scale)
        }
        .rotationEffect(.degrees(13), anchor: .bottom)
        .shadow(color: .black.opacity(0.2), radius: 1.5 * scale, y: scale)
    }
}

/// 鼠标停在木鱼上时，指针换成一把木槌。
///
/// 光标图是把界面里那根木槌离屏渲染出来的，不再单独维护一张素材，
/// 手里这根和自动敲击那根也就永远长得一样。只渲染一次，之后一直复用。
@MainActor
private enum MalletCursor {
    /// 跟着木鱼一起放大，再多给一成——指针尺寸下太小就认不出是木槌。
    private static let scale = muyuZoom * 1.1
    /// 画布左右要容下倾斜后甩出去的柄尖；底下再留一点，
    /// 槌头绕底端中点转过之后最低处会掉出去零点几个点，加上阴影就会被裁掉一道边。
    private static let canvas = CGSize(width: 23 * scale, height: 27 * scale)
    /// 热点取槌头底端中点，指哪儿敲哪儿。NSCursor 的热点原点在左上角。
    private static let hotSpot = NSPoint(x: canvas.width / 2, y: 25.7 * scale)

    static let shared: NSCursor? = {
        let renderer = ImageRenderer(
            content: MuyuMallet(scale: scale)
                .frame(width: canvas.width, height: hotSpot.y, alignment: .bottom)
                .padding(.bottom, canvas.height - hotSpot.y)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        // ImageRenderer 给出的尺寸按像素算，不改回点数的话 Retina 上光标会大一倍。
        image.size = canvas
        return NSCursor(image: image, hotSpot: hotSpot)
    }()
}

struct ProgressRow: View {
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
                        .fill(tint.gradient)
                        .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 2))
                }
            }
            .frame(height: 6)
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
        Text(detail)
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
