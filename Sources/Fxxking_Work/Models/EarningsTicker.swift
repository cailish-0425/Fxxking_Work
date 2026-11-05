import Combine
import Foundation

/// 持有计算引擎，每秒推一次快照给菜单栏标题；引擎只在配置、假日或日期变化时重建。
@MainActor
final class EarningsTicker: ObservableObject {
    @Published private(set) var earnings = Earnings()
    @Published private(set) var engine: EarningsEngine
    /// 刚解锁时这段离开期间挣到的钱，用户关掉卡片就清空。
    @Published var awayReport: AwayReport?

    private let settings: SettingsStore
    private let holidays: HolidayService
    private let lockMonitor = ScreenLockMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var tickTask: Task<Void, Never>?

    init(settings: SettingsStore, holidays: HolidayService) {
        self.settings = settings
        self.holidays = holidays
        self.engine = EarningsEngine(
            config: settings.config,
            autoHolidays: holidays.holidayDates,
            autoMakeupWorkdays: holidays.makeupWorkdays,
            holidayNames: holidays.holidays,
            now: Date()
        )

        settings.$config
            .combineLatest(holidays.$dataset)
            .receive(on: RunLoop.main)
            .sink { [weak self] config, dataset in
                self?.rebuild(config: config, dataset: dataset)
                // @Published 会立即回放，所以这里同时覆盖了启动时和用户中途打开开关两种情况。
                if config.awayAlertEnabled { AwayNotifier.shared.prepare() }
            }
            .store(in: &cancellables)

        // @Published 会立即回放当前值，所以这条订阅同时负责启动时的首次加载。
        settings.$config
            .map { "\($0.countryCode)|\($0.includeRegionalHolidays)" }
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshHolidays() }
            .store(in: &cancellables)

        lockMonitor.onUnlock = { [weak self] start, end in
            self?.reportTimeAway(from: start, to: end)
        }

        startTimer()
        tick()
    }

    deinit {
        tickTask?.cancel()
    }

    func refreshHolidays(force: Bool = false) {
        let year = Calendar.current.component(.year, from: Date())
        let config = settings.config
        let request = HolidayService.Request(
            countryCode: config.countryCode,
            includeRegional: config.includeRegionalHolidays,
            years: [year, year + 1]
        )
        Task { await holidays.load(request, force: force) }
    }

    /// 锁屏跨天时引擎里的"今天"已经过期，先让 tick 重建再算，
    /// 否则卡片旁边的进度条还停在昨天。
    private func reportTimeAway(from start: Date, to end: Date) {
        tick()
        guard settings.config.awayAlertEnabled else { return }
        let report = engine.awayReport(from: start, to: end)
        guard report.isWorthShowing else { return }

        awayReport = report
        let amount = Formatters.currency(report.amount, code: settings.config.currencyCode)
        AwayNotifier.shared.post(
            title: Loc.t("away.title"),
            body: Loc.t("away.body", Formatters.duration(report.paidSeconds), amount)
        )
    }

    /// 用 Task 循环而不是 Timer：它不受运行循环模式影响，菜单弹出时也照跳。
    private func startTimer() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        if engine.dayKey != engine.workCalendar.dayKey(now) {
            rebuild(config: settings.config, dataset: holidays.dataset, now: now)
            return
        }
        earnings = engine.snapshot(at: now)
    }

    private func rebuild(config: Configuration, dataset: HolidayService.Dataset, now: Date = Date()) {
        engine = EarningsEngine(
            config: config,
            autoHolidays: Set(dataset.holidays.keys),
            autoMakeupWorkdays: dataset.makeupWorkdays,
            holidayNames: dataset.holidays,
            now: now
        )
        earnings = engine.snapshot(at: now)
    }
}
