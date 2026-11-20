import Combine
import Foundation

/// 监听账期和语言设置，滚动维护未来一年的发薪日前一天提醒。
@MainActor
final class PaydayReminderService: ObservableObject {
    private struct Signature: Equatable {
        var payroll: PayrollSettings
        var language: AppLanguage
    }

    private static let notificationPrefix = "payroll-reminder-"

    private let settings: SettingsStore
    private var cancellable: AnyCancellable?

    init(settings: SettingsStore) {
        self.settings = settings
        cancellable = settings.$config
            .map { Signature(payroll: $0.payroll, language: $0.language) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh(now: Date = Date()) {
        let payroll = settings.config.payroll
        guard payroll.enabled,
              payroll.reminderEnabled,
              let calendar = payroll.calendar
        else {
            AwayNotifier.shared.cancelScheduledNotifications(prefix: Self.notificationPrefix)
            return
        }

        let reminderDates = PayrollReminderSchedule.reminderDates(
            now: now, payroll: calendar, calendar: calendar.calendar)
        AwayNotifier.shared.prepare { [weak self] in
            guard let self else { return }
            self.schedule(reminderDates)
        }
    }

    private func schedule(_ dates: [Date]) {
        let notifications = dates.map { date in
            let formatter = DateFormatter()
            formatter.calendar = .current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return AwayNotifier.ScheduledNotification(
                identifier: Self.notificationPrefix + formatter.string(from: date),
                title: Loc.t("payroll.reminder.title"),
                body: Loc.t("payroll.reminder.body"),
                date: date
            )
        }
        AwayNotifier.shared.replaceScheduledNotifications(
            prefix: Self.notificationPrefix,
            notifications: notifications
        )
    }
}
