import Foundation

@main
struct OvertimeControllerChecks {
    @MainActor static func main() throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }
        let suite = "FxxkingWork.ControllerChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = Configuration()
        config.salaryAmount = 10000
        config.useAutoHolidays = false
        defaults.set(try JSONEncoder().encode(config), forKey: "configuration.v1")
        let settings = SettingsStore(defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        let controller = OvertimeController(settings: settings) {
            EarningsEngine(config: settings.config, autoHolidays: [], holidayNames: [:],
                           now: date(9, 20), calendar: calendar)
        }
        expect(controller.start(at: date(9, 13), kind: .paid, multiplier: 2) != nil,
               "Normal working time must reject explicit start")
        expect(settings.config.overtimeSessions.isEmpty, "Rejected start must not persist a session")
        expect(controller.start(at: date(9, 18), kind: .paid, multiplier: 2) == nil, "Shift end permits start")
        expect(controller.start(at: date(9, 19), kind: .paid, multiplier: 2) == .alreadyActive, "Repeated start is rejected")
        expect(controller.stop(at: date(9, 20)) == nil, "Stop succeeds")
        let original = settings.config.overtimeSessions
        let backfill = OvertimeSession(start: date(8, 10), end: date(8, 12), kind: .paid,
                                       multiplier: 2, baseHourlyGross: 62.5, currencyCode: "CNY")
        expect(controller.addBackfill(backfill, now: date(9, 20)) == nil, "Backfill succeeds")
        expect(controller.canUndo, "Backfill exposes undo")
        controller.undo()
        expect(settings.config.overtimeSessions == original, "Backfill undo restores exact records")
        expect(!controller.canUndo, "Undo is single use")
        var edited = original[0]
        edited.kind = .unpaid
        expect(controller.edit(id: edited.id, to: edited, now: date(9, 20)) == nil, "Edit succeeds")
        expect(controller.canUndo, "Edit exposes undo")
        controller.undo()
        expect(settings.config.overtimeSessions == original, "Edit undo restores exact pay kind and snapshot")
        expect(controller.delete(id: original[0].id) == nil, "Delete succeeds")
        expect(controller.canUndo, "Delete exposes undo")
        controller.undo()
        expect(settings.config.overtimeSessions == original, "Delete undo restores exact records")

        let autoSuite = "FxxkingWork.AutoEndChecks.\(UUID().uuidString)"
        let autoDefaults = UserDefaults(suiteName: autoSuite)!
        defer { autoDefaults.removePersistentDomain(forName: autoSuite) }
        let currentCalendar = Calendar.current
        let day = currentCalendar.startOfDay(for: Date())
        let start = currentCalendar.date(byAdding: .minute, value: 30, to: day)!
        let deadline = currentCalendar.date(bySettingHour: 2, minute: 0, second: 0, of: day)!
        var autoConfig = Configuration()
        autoConfig.overtimeSessions = [
            OvertimeSession(
                start: start,
                end: nil,
                kind: .paid,
                multiplier: 1,
                baseHourlyGross: 100,
                currencyCode: "CNY"
            )
        ]
        autoDefaults.set(try JSONEncoder().encode(autoConfig), forKey: "configuration.v1")
        let autoSettings = SettingsStore(defaults: autoDefaults)
        let autoController = OvertimeController(settings: autoSettings) {
            EarningsEngine(
                config: autoSettings.config,
                autoHolidays: [],
                holidayNames: [:],
                now: start,
                calendar: currentCalendar
            )
        }
        autoController.maintain(at: deadline.addingTimeInterval(60))
        expect(autoController.active == nil, "Active overtime auto-finishes at 2:00 AM")
        expect(
            autoSettings.config.overtimeSessions.first?.end == deadline,
            "Persisted overtime end is capped at 2:00 AM"
        )

        print("\(count)/\(count) controller checks passed")
    }
}
