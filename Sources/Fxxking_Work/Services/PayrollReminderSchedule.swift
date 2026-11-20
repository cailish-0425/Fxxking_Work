import Foundation

/// 从账期规则生成未来的“发薪日前一天 20:00”提醒日期。
enum PayrollReminderSchedule {
    static let reminderHour = 20
    static let defaultLimit = 12

    static func reminderDates(
        now: Date,
        payroll: PayrollCalendar,
        calendar: Calendar = .current,
        limit: Int = defaultLimit
    ) -> [Date] {
        guard limit > 0 else { return [] }
        var anchor = now
        var result: [Date] = []
        var attempts = 0

        while result.count < limit, attempts < limit + 1 {
            attempts += 1
            let payday = payroll.nextPayday(onOrAfter: anchor)
            guard let reminderDay = calendar.date(byAdding: .day, value: -1, to: payday),
                  let reminder = calendar.date(
                    bySettingHour: reminderHour, minute: 0, second: 0, of: reminderDay),
                  let nextAnchor = calendar.date(byAdding: .day, value: 1, to: payday)
            else { break }

            if reminder > now {
                result.append(reminder)
            }
            anchor = nextAnchor
        }
        return result
    }
}
