import Foundation

@main
struct LeaveControllerChecks {
    @MainActor static func main() throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }
        func expectClose(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 1e-6) {
            count += 1
            precondition(abs(actual - expected) <= tolerance, "\(message) — expected \(expected), got \(actual)")
        }
        func expectSuccess(
            _ result: Result<LeaveController.LeavePreview, LeaveController.LeaveControllerError>,
            _ message: String
        ) -> LeaveController.LeavePreview {
            count += 1
            guard case .success(let value) = result else {
                preconditionFailure("\(message) — expected success, got \(result)")
            }
            return value
        }
        func expectError(
            _ result: Result<LeaveController.LeavePreview, LeaveController.LeaveControllerError>,
            _ expected: LeaveController.LeaveControllerError,
            _ message: String
        ) {
            count += 1
            guard case .failure(let err) = result, err == expected else {
                preconditionFailure("\(message) — expected \(expected), got \(result)")
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        func date(_ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }

        // MARK: 单日新增/更新/删除/撤销（无假日的干净工作日历）
        let suiteA = "FxxkingWork.LeaveChecks.Single.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suiteA)!
        defer { defaultsA.removePersistentDomain(forName: suiteA) }
        var configA = Configuration()
        configA.salaryAmount = 10000
        configA.workdays = [2, 3, 4, 5, 6]
        configA.useAutoHolidays = true
        configA.useAutoMakeupWorkdays = true
        defaultsA.set(try JSONEncoder().encode(configA), forKey: "configuration.v1")
        let settingsA = SettingsStore(defaults: defaultsA)
        let controllerA = LeaveController(settings: settingsA) {
            WorkCalendar(config: settingsA.config, autoHolidays: [], autoMakeupWorkdays: [],
                         calendar: calendar)
        }
        let wcA = WorkCalendar(config: settingsA.config, autoHolidays: [], autoMakeupWorkdays: [],
                               calendar: calendar)
        let novWorkdaysA = wcA.workdaysInMonth(containing: date(16))
        expect(novWorkdaysA == 21, "Nov 2026 Mon-Fri fixture is 21 workdays")
        let dailyPayA = 10000.0 / Double(novWorkdaysA)

        // 无请假回归：空列表，工作日按满勤应发。
        expect(controllerA.entries.isEmpty, "Fresh controller has no leave entries")
        expectClose(wcA.payableFraction(on: date(16)), 1.0, "No-leave day pays 100%")

        // 全天事假 0%
        expect(controllerA.add(on: date(16), kind: .personal, portion: .fullDay) == nil,
               "Full-day personal leave adds")
        let personal16 = controllerA.entries.first { $0.dayKey == "2026-11-16" }!
        expect(personal16.payRatioBp == 0, "Personal leave defaults to 0 bp")
        expectClose(personal16.payableFraction, 0.0, "Personal full-day payable fraction is 0")
        expectClose(controllerA.grossImpact(of: personal16, on: date(16)), dailyPayA,
                    "Personal full-day gross impact is one day's pay")

        // 病假 60%
        expect(controllerA.add(on: date(17), kind: .sick, portion: .fullDay, note: "flu") == nil,
               "Sick leave adds")
        let sick17 = controllerA.entries.first { $0.dayKey == "2026-11-17" }!
        expect(sick17.payRatioBp == 6_000, "Sick leave defaults to 6000 bp")
        expectClose(sick17.payableFraction, 0.6, "Sick full-day payable fraction is 0.6")
        expectClose(controllerA.grossImpact(of: sick17, on: date(17)), dailyPayA * 0.4,
                    "Sick full-day gross impact is 40% of a day")

        // 年假 100%
        expect(controllerA.add(on: date(19), kind: .annual, portion: .fullDay) == nil,
               "Annual leave adds")
        let annual19 = controllerA.entries.first { $0.dayKey == "2026-11-19" }!
        expect(annual19.payRatioBp == 10_000, "Annual leave defaults to 10000 bp")
        expectClose(annual19.payableFraction, 1.0, "Annual full-day payable fraction is 1")
        expectClose(controllerA.grossImpact(of: annual19, on: date(19)), 0.0,
                    "Annual full-day gross impact is 0")

        // 上午半天
        expect(controllerA.add(on: date(20), kind: .personal, portion: .morning) == nil,
               "Morning half-day leave adds")
        let morning20 = controllerA.entries.first { $0.dayKey == "2026-11-20" }!
        expect(morning20.portion == .morning, "Morning portion is stored")
        expectClose(morning20.leaveFraction, 0.5, "Morning leave fraction is 0.5")
        expectClose(morning20.payableFraction, 0.5, "Morning personal payable fraction is 0.5")
        expectClose(controllerA.grossImpact(of: morning20, on: date(20)), dailyPayA * 0.5,
                    "Morning personal gross impact is half a day")

        // 冲突与校验
        expect(controllerA.add(on: date(16), kind: .personal, portion: .fullDay) == .duplicateDate,
               "Second leave on same date is rejected")
        expect(controllerA.add(on: date(23), kind: .personal, portion: .fullDay, payRatioBp: 15_000)
               == .invalidPayRatio, "Out-of-range pay ratio is rejected")
        expect(controllerA.update(id: UUID(), kind: .annual) == .missing, "Update of missing id is rejected")

        // 更新：改 kind 未显式给比例 → 跟随新 kind 默认；note 保持。
        expect(controllerA.update(id: sick17.id, kind: .annual) == nil, "Update kind succeeds")
        let updated17 = controllerA.entries.first { $0.dayKey == "2026-11-17" }!
        expect(updated17.kind == .annual && updated17.payRatioBp == 10_000,
               "Kind change resets pay ratio to new kind default")
        expect(updated17.portion == .fullDay && updated17.note == "flu",
               "Update keeps portion and note when omitted")

        // 删除 + 撤销
        let beforeDelete = settingsA.config.leaveEntries
        expect(controllerA.delete(id: personal16.id) == nil, "Delete succeeds")
        expect(controllerA.entries.first { $0.dayKey == "2026-11-16" } == nil, "Deleted date is gone")
        expect(controllerA.canUndo, "Delete exposes undo")
        controllerA.undo()
        expect(settingsA.config.leaveEntries == beforeDelete, "Undo restores exact records")
        expect(!controllerA.canUndo, "Undo is single use")

        // MARK: 历史范围补录（跳过周末/假日，保留调休工作日）
        let suiteB = "FxxkingWork.LeaveChecks.Range.\(UUID().uuidString)"
        let defaultsB = UserDefaults(suiteName: suiteB)!
        defer { defaultsB.removePersistentDomain(forName: suiteB) }
        var configB = Configuration()
        configB.salaryAmount = 10000
        configB.workdays = [2, 3, 4, 5, 6]
        configB.useAutoHolidays = true
        configB.useAutoMakeupWorkdays = true
        configB.makeupWorkdays = ["2026-11-22"] // 手动调休：周日上班
        defaultsB.set(try JSONEncoder().encode(configB), forKey: "configuration.v1")
        let settingsB = SettingsStore(defaults: defaultsB)
        let autoHolidaysB: Set<String> = ["2026-11-18"]     // 官方假日：周三
        let autoMakeupB: Set<String> = ["2026-11-21"]       // 数据源调休：周六上班
        let controllerB = LeaveController(settings: settingsB) {
            WorkCalendar(config: settingsB.config, autoHolidays: autoHolidaysB,
                         autoMakeupWorkdays: autoMakeupB, calendar: calendar)
        }
        let wcB = WorkCalendar(config: settingsB.config, autoHolidays: autoHolidaysB,
                               autoMakeupWorkdays: autoMakeupB, calendar: calendar)
        let novWorkdaysB = wcB.workdaysInMonth(containing: date(16))
        expect(novWorkdaysB == 22, "Nov 2026 with holiday + two makeup days is 22 workdays")
        let dailyPayB = 10000.0 / Double(novWorkdaysB)

        // 仅工作日：跳过 11-18 假日，保留 11-21/11-22 调休。
        let preview = expectSuccess(
            controllerB.previewBackfill(start: date(16), end: date(22), kind: .personal,
                                        portion: .fullDay, payRatioBp: 0, applyOnlyWorkdays: true),
            "Range preview succeeds"
        )
        expect(preview.affectedDates == ["2026-11-16", "2026-11-17", "2026-11-19",
                                         "2026-11-20", "2026-11-21", "2026-11-22"],
               "Workday-only preview skips holiday and keeps makeup days")
        expect(preview.workdayCount == 6, "Workday-only preview counts 6 workdays")
        expectClose(preview.grossImpact, 6 * dailyPayB,
                    "Range gross impact is 6 days at current daily pay")

        expect(controllerB.applyBackfill(start: date(16), end: date(22), kind: .personal,
                                         portion: .fullDay, payRatioBp: 0, applyOnlyWorkdays: true) == nil,
               "Range backfill applies")
        expect(controllerB.entries.count == 6, "Range backfill writes one entry per workday")
        expect(controllerB.entries.allSatisfy { $0.kind == .personal && $0.payRatioBp == 0 },
               "Range backfill writes personal 0 bp entries")

        // 关闭仅工作日：范围覆盖全部 7 天，但工作日数仍为 6。
        let previewAll = expectSuccess(
            controllerB.previewBackfill(start: date(16), end: date(22), kind: .annual,
                                        portion: .fullDay, applyOnlyWorkdays: false),
            "All-days preview succeeds"
        )
        expect(previewAll.affectedDates.count == 7, "All-days preview covers every date in range")
        expect(previewAll.workdayCount == 6, "All-days preview still counts 6 workdays")
        expectClose(previewAll.grossImpact, 0.0, "Annual backfill has zero gross impact")

        // 原地替换保留 id：同一天再次补录，更新内容而不是重复插入。
        let id16 = controllerB.entries.first { $0.dayKey == "2026-11-16" }!.id
        expect(controllerB.applyBackfill(start: date(16), end: date(16), kind: .annual,
                                         portion: .fullDay, note: "replaced", applyOnlyWorkdays: true) == nil,
               "Single-day backfill replaces in place")
        let replaced16 = controllerB.entries.first { $0.dayKey == "2026-11-16" }!
        expect(replaced16.id == id16 && replaced16.kind == .annual && replaced16.payRatioBp == 10_000,
               "Backfill keeps existing id and applies new kind")
        expect(replaced16.note == "replaced", "Backfill applies note")
        controllerB.undo()
        expect(controllerB.entries.first { $0.dayKey == "2026-11-16" }!.kind == .personal,
               "Backfill undo restores replaced entry")

        // 校验：日期倒序、无工作日。
        expectError(controllerB.previewBackfill(start: date(22), end: date(16), kind: .personal,
                                                portion: .fullDay, applyOnlyWorkdays: true),
                    .invalidDateRange, "Reversed range is rejected in preview")
        expect(controllerB.applyBackfill(start: date(22), end: date(16), kind: .personal,
                                         portion: .fullDay, applyOnlyWorkdays: true) == .invalidDateRange,
               "Reversed range is rejected in apply")
        expect(controllerA.applyBackfill(start: date(21), end: date(22), kind: .personal,
                                         portion: .fullDay, applyOnlyWorkdays: true) == .noWorkdays,
               "Workday-only backfill over pure weekend has no workdays")

        print("\(count)/\(count) leave controller checks passed")
    }
}
