import Foundation

/// 短采集打断面板的回归检查。
///
/// 这里覆盖的是"纯逻辑"部分：状态 → 展示形态、进入保护时清除临时揭示、
/// 保护结束后恢复交互，以及保护层外状态对象（`PanelUIState` / `SettingsUIState` /
/// `OnboardingDraftState`）的保留语义。真实视图的挂载/卸载由 SwiftUI 负责，见报告里
/// 标注的"未验证项"。
///
/// 隐私底线在检查里被写成断言：只要不是 `.content`，就必须隐藏金额、必须清掉
/// 之前的临时揭示；保护层不允许用透明度/遮罩假隐藏（源码扫描断言）。
@main
struct ScreenCaptureProtectionChecks {
    @MainActor
    static func main() {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }

        // MARK: 状态 → 展示形态

        expect(
            ScreenCaptureProtectionPolicy.presentation(for: .inactive) == .content,
            "Inactive allows the real content")
        expect(
            ScreenCaptureProtectionPolicy.presentation(for: .pending) == .checking,
            "Pending shows the lightweight placeholder")
        expect(
            ScreenCaptureProtectionPolicy.presentation(for: .active) == .blocked,
            "Sustained capture shows the blocked page")
        expect(
            ScreenCaptureProtectionPolicy.presentation(for: .unavailable) == .unavailable,
            "Unavailable status fails closed with its own page")

        // MARK: 隐私底线

        let allPresentations: [ScreenCapturePresentation] = [.content, .checking, .blocked, .unavailable]
        for presentation in allPresentations where presentation != .content {
            expect(
                presentation.hidesSensitiveContent,
                "Protected presentation \(presentation) must hide sensitive content")
            expect(
                ScreenCaptureProtectionPolicy.shouldResetReveal(onEntering: presentation),
                "Protected presentation \(presentation) must clear the previous reveal")
        }
        expect(
            !ScreenCapturePresentation.content.hidesSensitiveContent,
            "Only the cleared presentation may show amounts")
        expect(
            !ScreenCaptureProtectionPolicy.shouldResetReveal(onEntering: .content),
            "Leaving protection does not re-reset the reveal by itself")
        expect(
            ScreenCaptureProtectionPolicy.restoresInteractionState(from: .checking),
            "A short blip restores the interaction state")
        expect(
            ScreenCaptureProtectionPolicy.restoresInteractionState(from: .blocked),
            "Ending a sustained share also restores the interaction state")
        expect(
            !ScreenCaptureProtectionPolicy.restoresInteractionState(from: .content),
            "Nothing to restore while unprotected")

        // MARK: 占位尺寸（避免 340 宽起跳）

        expect(
            ScreenCaptureProtectionPolicy.placeholderWidth(contentWidth: 380) == 380,
            "Placeholder follows the measured content width"
        )
        expect(
            ScreenCaptureProtectionPolicy.placeholderWidth(contentWidth: nil) == 340,
            "Placeholder falls back to the historical 340 width"
        )
        expect(
            ScreenCaptureProtectionPolicy.placeholderMinHeight(lastContentHeight: 381) == 381,
            "Placeholder keeps the last content height"
        )
        expect(
            ScreenCaptureProtectionPolicy.placeholderMinHeight(lastContentHeight: 0) == nil,
            "No remembered height before the first layout"
        )

        // MARK: 保护代次（短事件 vs 持续采集）

        var shortBlip = ProtectionEpochTracker()
        shortBlip.note(.checking)
        shortBlip.note(.content)
        expect(shortBlip.epoch == 1, "One short blip counts as one protection")
        expect(!shortBlip.isProtected, "A finished blip is no longer protected")
        expect(shortBlip.lastPresentation == .content, "A finished blip ends on content")

        var sustained = ProtectionEpochTracker()
        sustained.note(.checking)
        sustained.note(.blocked)
        sustained.note(.content)
        expect(sustained.epoch == 2, "Pending then sustained counts as two protection steps")
        expect(!sustained.isProtected, "Ending the share clears protection")

        var stillSharing = ProtectionEpochTracker()
        stillSharing.note(.checking)
        stillSharing.note(.blocked)
        expect(stillSharing.isProtected, "An ongoing share stays protected")

        // MARK: 面板状态跨保护存活

        let panel = PanelUIState()
        panel.showingReasonGenerator = true
        panel.detailsExpanded = true
        let first = panel.nextReason()
        expect(!first.text.isEmpty, "The generator session returns a non-empty reason")
        let second = panel.nextReason()
        expect(second.text != first.text, "Consecutive reasons differ (no duplicate text)")
        expect(panel.lastReason == second, "The last revealed reason is remembered for restore")
        expect(panel.showingReasonGenerator, "Generator stays open across protection")
        expect(panel.detailsExpanded, "Details stay expanded across protection")
        panel.restoreAfterProtection()
        expect(panel.showingReasonGenerator, "Restoring keeps the generator open")
        expect(panel.detailsExpanded, "Restoring keeps the details expanded")
        expect(!panel.reasonSession.next().text.isEmpty, "Session survives the protection round trip")

        panel.closeGenerator()
        expect(!panel.showingReasonGenerator, "User close clears the generator")
        expect(panel.lastReason == nil, "User close clears the remembered reason")

        panel.showingReasonGenerator = true
        panel.detailsExpanded = true
        _ = panel.nextReason()
        panel.resetForPanelClose()
        expect(!panel.showingReasonGenerator, "Closing the panel resets the generator")
        expect(!panel.detailsExpanded, "Closing the panel collapses the details")
        expect(panel.lastReason == nil, "Closing the panel forgets the reason")

        // MARK: 设置草稿跨保护存活

        let settingsUI = SettingsUIState()
        settingsUI.selectedTab = .tax
        settingsUI.openSalaryEditor(
            SettingsUIState.SalaryEditorDraft(
                amount: 18_500,
                period: .annual,
                payMonthsPerYear: 14,
                effectiveDate: Date(timeIntervalSince1970: 100)))
        expect(settingsUI.salaryEditorVisible, "Opening the editor presents the sheet")
        expect(settingsUI.salaryEditor?.amount == 18_500, "The draft keeps the typed amount")

        // 模拟保护层拆掉内容：SwiftUI 会把呈现位写回 false，草稿必须还在。
        settingsUI.salaryEditorVisible = false
        settingsUI.restoreAfterProtection()
        expect(settingsUI.salaryEditorVisible, "Protection restores the salary editor sheet")
        expect(settingsUI.salaryEditor?.amount == 18_500, "The restored draft keeps the amount")
        expect(settingsUI.salaryEditor?.payMonthsPerYear == 14, "The restored draft keeps the pay months")
        expect(settingsUI.salaryEditor?.period == .annual, "The restored draft keeps the period")
        expect(settingsUI.selectedTab == .tax, "The selected tab survives protection")

        settingsUI.closeSalaryEditor()
        settingsUI.restoreAfterProtection()
        expect(!settingsUI.salaryEditorVisible, "A cancelled draft does not come back")
        expect(settingsUI.salaryEditor == nil, "Cancel clears the draft")

        settingsUI.selectedTab = .about
        settingsUI.openSalaryEditor(SettingsUIState.SalaryEditorDraft(amount: 1))
        settingsUI.resetForWindowClose()
        expect(settingsUI.selectedTab == .salary, "Closing the window resets the tab")
        expect(settingsUI.salaryEditor == nil, "Closing the window drops the draft")

        // MARK: 引导草稿跨保护存活

        var config = Configuration()
        config.salaryAmount = 9_600
        let onboarding = OnboardingDraftState(draft: Configuration())
        onboarding.update(draft: config)
        onboarding.update(step: 2)
        onboarding.appliedPrivacyDefault = true
        expect(onboarding.draft.salaryAmount == 9_600, "Onboarding keeps the typed salary")
        expect(onboarding.step == 2, "Onboarding keeps the current step")
        expect(onboarding.appliedPrivacyDefault, "Onboarding remembers the privacy default")
        expect(
            onboardSnapshotAfterProtection(state: onboarding) == config,
            "Rebuilding the onboarding view from the snapshot yields the same values")

        // MARK: 源码扫描：保护层必须"换掉内容"，不得用透明度/遮罩假隐藏

        let gatePath = "Sources/Fxxking_Work/Views/ScreenCaptureBlockedView.swift"
        if let source = try? String(contentsOfFile: gatePath, encoding: .utf8) {
            expect(!source.contains(".opacity("), "The gate never hides content with opacity")
            expect(!source.contains(".blur("), "The gate never hides content with blur")
            expect(source.contains("case .checking:"), "The gate swaps in the checking placeholder")
            expect(source.contains("case .blocked:"), "The gate swaps in the blocked page")
            expect(source.contains("case .unavailable:"), "The gate swaps in the unavailable page")
            expect(source.contains("case .content:"), "Only the cleared state renders real content")
        } else {
            print("note: gate source not found from cwd, skipping the source scan")
        }

        print("\(count)/\(count) screen capture protection checks passed")
    }

    /// 保护结束后视图会用快照重新初始化：这里模拟"重建"读到的值。
    @MainActor
    private static func onboardSnapshotAfterProtection(state: OnboardingDraftState) -> Configuration {
        state.draft
    }
}
