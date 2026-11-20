import Foundation

/// 屏幕保护打断请假 / 加班编辑时的草稿回归检查。
///
/// 覆盖三件事（都是纯逻辑，不挂 SwiftUI 视图）：
/// 1. **输入恢复**：保护层把编辑器移出视图树后，用同一 key 重新打开能拿回上一次的输入；
/// 2. **取消不恢复**：点「取消 / 保存 / 删除 / 完成」清掉草稿，重新打开回到种子值；
/// 3. **不落盘**：草稿只在内存里，写入配置只发生在用户点保存那一次（源码扫描 + 语义断言）。
///
/// 另外用源码扫描盯住"独立 sheet 也包保护层"，否则共享期间 sheet 可能露出金额。
@main
struct EditingDraftChecks {
    @MainActor
    static func main() {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }

        let day = Calendar.current.startOfDay(for: Date())
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let todayKey = DayKeyCoder.current.key(for: day)

        // MARK: 单日草稿的种子

        let emptySeed = LeaveDayEditorDraft.seed(day: day, existing: nil)
        expect(emptySeed.kind == .personal, "An empty day starts from the personal leave kind")
        expect(emptySeed.portion == .fullDay, "An empty day starts as a full day")
        expect(emptySeed.note.isEmpty, "An empty day starts with no note")
        expect(emptySeed.dayKey == todayKey, "The seed keeps the day it was opened for")
        expect(
            emptySeed.resolvedBasisPoints == LeaveKind.personal.defaultPayRatioBp,
            "An empty day uses the kind default pay ratio")

        let existingEntry = LeaveEntry(
            id: UUID(), dayKey: todayKey, kind: .sick, portion: .morning,
            payRatioBp: 6_000, note: "看牙")
        let filledSeed = LeaveDayEditorDraft.seed(entry: existingEntry)
        expect(filledSeed.dayKey == todayKey, "Editing an existing record keeps its day")
        expect(filledSeed.kind == .sick, "Editing prefills the existing kind")
        expect(filledSeed.portion == .morning, "Editing prefills the existing portion")
        expect(filledSeed.note == "看牙", "Editing prefills the existing note")
        expect(filledSeed.payOption == .custom, "A mid ratio prefills the custom pay option")
        expect(filledSeed.resolvedBasisPoints == 6_000, "Prefilled ratio is the stored ratio")

        // 计薪比例口径：固定档覆盖输入，自定义档夹在 0...10000。
        var ratioDraft = filledSeed
        ratioDraft.payOption = .unpaid
        ratioDraft.customBasisPoints = 8_000
        expect(ratioDraft.resolvedBasisPoints == 0, "The unpaid option wins over typed ratio")
        ratioDraft.payOption = .full
        expect(ratioDraft.resolvedBasisPoints == 10_000, "The full option is 100%")
        ratioDraft.payOption = .custom
        ratioDraft.customBasisPoints = -100
        expect(ratioDraft.resolvedBasisPoints == 0, "Custom ratios clamp at 0")
        ratioDraft.customBasisPoints = 20_000
        expect(ratioDraft.resolvedBasisPoints == 10_000, "Custom ratios clamp at 100%")

        // MARK: 区间草稿

        let rangeSeed = LeaveRangeEditorDraft.seed(start: day, end: day)
        expect(rangeSeed.isSingleDay, "Same start and end is a single day")
        expect(rangeSeed.portion == .fullDay, "Range seed starts as a full day")
        expect(rangeSeed.workdaysOnly, "Range seed applies to workdays only")
        expect(rangeSeed.hasValidRange, "Same-day range is valid")
        expect(rangeSeed.effectivePortion == .fullDay, "Single day honours the picked portion")

        var halfRange = rangeSeed
        halfRange.portion = .morning
        expect(halfRange.effectivePortion == .morning, "A single-day range keeps half day")
        halfRange.end = nextDay
        expect(!halfRange.isSingleDay, "A cross-day range spans more than one day")
        expect(halfRange.effectivePortion == .fullDay, "A cross-day range is forced to full day")
        halfRange.end = day.addingTimeInterval(-86_400)
        expect(!halfRange.hasValidRange, "Ending before the start is rejected")

        // MARK: 加班草稿

        let freshOvertime = OvertimeEditorDraft.seed(session: nil, now: day)
        expect(freshOvertime.kind == .paid, "A new overtime segment defaults to paid")
        expect(freshOvertime.multiplier == 1, "A new overtime segment defaults to ×1")
        expect(freshOvertime.baseIsAuto, "A new segment derives its base hourly rate")
        expect(freshOvertime.end == day.addingTimeInterval(3_600), "A new segment is one hour long")

        let storedSession = OvertimeSession(
            start: day, end: day.addingTimeInterval(7_200), kind: .paid, multiplier: 2,
            baseHourlyGross: 120, currencyCode: "CNY")
        let editingOvertime = OvertimeEditorDraft.seed(session: storedSession)
        expect(editingOvertime.start == storedSession.start, "Editing keeps the recorded start")
        expect(editingOvertime.multiplier == 2, "Editing keeps the recorded multiplier")
        expect(editingOvertime.baseHourlyGross == 120, "Editing locks the recorded hourly rate")
        expect(!editingOvertime.baseIsAuto, "Editing an existing segment never re-prices it")

        // MARK: 草稿槽：恢复 / 取消 / 过期

        let slot = DraftSlot<String, LeaveDayEditorDraft>()
        let opened = slot.begin("day", seed: emptySeed)
        expect(slot.isOpen, "Opening the editor fills the slot")
        expect(opened == emptySeed, "Opening returns the seed on first use")

        var typed = opened
        typed.note = "下午请假半天"
        typed.portion = .morning
        slot.update(typed)
        // 模拟保护：视图被移出视图树（草稿在槽里），随后用同一 key 重新打开。
        let afterProtection = slot.begin("day", seed: emptySeed)
        expect(afterProtection.note == "下午请假半天", "Typed note survives a protection interruption")
        expect(afterProtection.portion == .morning, "Typed portion survives a protection interruption")
        expect(!slot.begin("other", seed: emptySeed).note.isEmpty == false,
               "A different target starts from a fresh seed")

        slot.close()
        expect(!slot.isOpen, "Closing the editor clears the state")
        let afterCancel = slot.begin("day", seed: emptySeed)
        expect(afterCancel.note.isEmpty, "Cancelling drops the draft, reopening is a fresh seed")
        expect(afterCancel == emptySeed, "Cancelling restores the seed exactly")

        let stale = DraftSlot<String, LeaveDayEditorDraft>()
        stale.begin("day", seed: emptySeed, now: day)
        stale.update(typed, now: day)
        let reopenedLate = stale.begin(
            "day", seed: emptySeed, now: day.addingTimeInterval(EditingDraftPolicy.maxAge + 60))
        expect(reopenedLate.note.isEmpty, "A draft older than maxAge is dropped")

        let store = EditingDraftStore()
        store.todayLeaveDay.begin("today", seed: emptySeed)
        store.leaveDay.begin("entry", seed: filledSeed)
        store.leaveRange.begin("range", seed: rangeSeed)
        store.overtimeSession.begin("session", seed: editingOvertime)
        expect(store.todayLeaveDay.isOpen, "Store keeps the today draft open")
        store.closeAll()
        expect(!store.todayLeaveDay.isOpen && !store.leaveDay.isOpen
                && !store.leaveRange.isOpen && !store.overtimeSession.isOpen,
               "closeAll clears every editor draft")

        // MARK: 源码扫描：sheet 也受保护 + 只在内存里

        func source(_ path: String) -> String? {
            try? String(contentsOfFile: path, encoding: .utf8)
        }

        let draftsPath = "Sources/Fxxking_Work/Support/EditingDrafts.swift"
        if let draftsSource = source(draftsPath) {
            expect(!draftsSource.contains("settings.config"),
                   "The draft store never writes into the configuration")
            expect(!draftsSource.contains("UserDefaults"),
                   "Drafts are never persisted into defaults")
            expect(draftsSource.contains("func close()"),
                   "The draft store has an explicit close path")
        } else {
            print("note: draft source not found from cwd, skipping part of the source scan")
        }

        let sheetSites = [
            ("Sources/Fxxking_Work/Views/MenuContentView.swift", 1),
            ("Sources/Fxxking_Work/Views/LeaveHistorySection.swift", 2),
            ("Sources/Fxxking_Work/Views/SettingsView.swift", 3),
        ]
        var modalGateCount = 0
        for (path, expected) in sheetSites {
            guard let text = source(path) else { continue }
            expect(text.contains("placeholderStyle: .modal"),
                   "\(path) protects its sheets with the inert placeholder")
            modalGateCount += text.components(separatedBy: "placeholderStyle: .modal").count - 1
            expect(text.components(separatedBy: "ScreenCaptureGate").count - 1 >= expected,
                   "\(path) wraps its sheets in ScreenCaptureGate")
        }
        expect(modalGateCount >= 6, "Every editor sheet uses the inert placeholder")

        let gatePath = "Sources/Fxxking_Work/Views/ScreenCaptureBlockedView.swift"
        if let gateSource = source(gatePath) {
            expect(gateSource.contains("case modal"), "The gate knows the inert modal style")
            expect(gateSource.contains("ScreenCaptureSheetPlaceholder"),
                   "The gate renders the inert sheet placeholder")
            let inertSlice = gateSource.components(separatedBy: "struct ScreenCaptureSheetPlaceholder")
            if inertSlice.count > 1 {
                // 只扫占位视图本体，确认它既没有按钮也没有命中测试/焦点入口。
                let body = inertSlice[1].components(separatedBy: "struct ScreenCaptureBlockedView")[0]
                expect(!body.contains("Button("), "The sheet placeholder has no buttons at all")
                expect(body.contains(".allowsHitTesting(false)"),
                       "The sheet placeholder refuses pointer interaction")
                expect(!body.contains("TextField"),
                       "The sheet placeholder accepts no keyboard input")
                expect(!body.contains("PrivacyAmount"),
                       "The sheet placeholder never renders an amount")
            }
        }

        let stringsDirectory = "Resources"
        let locales = ["en", "zh-Hans", "ja", "ko", "es", "fr", "ru"]
        for locale in locales {
            let path = "\(stringsDirectory)/\(locale).lproj/Localizable.strings"
            guard let strings = source(path) else {
                expect(false, "Missing strings file for \(locale)")
                continue
            }
            expect(strings.contains("\"screenCapture.sheetProtected\""),
                   "\(locale) has the sheet protection string")
        }

        // 编辑器每次改动都写回草稿，取消/保存时清掉。
        let editorSites = [
            "Sources/Fxxking_Work/Views/TodayLeavePanelView.swift",
            "Sources/Fxxking_Work/Views/LeaveEditorView.swift",
            "Sources/Fxxking_Work/Views/SettingsView.swift",
        ]
        for path in editorSites {
            guard let text = source(path) else { continue }
            expect(text.contains(".onChange(of: draft)"),
                   "\(path) writes every edit back into the draft outside the protection layer")
        }

        print("\(count)/\(count) editing draft checks passed")
    }
}
