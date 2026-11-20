import Foundation

/// 首次引导的未提交填写，所有权放在保护层之外（`OnboardingWindowController` 持有）。
///
/// `OnboardingView` 的字段仍用普通 `@State`（输入流畅、diff 小），但每次变化都同步回
/// 这里；保护层把内容换掉再换回来时，视图用这份快照重新初始化，用户填过的金额、
/// 作息、隐私选项和当前步骤都还在。引导的"完成才落盘"约定不变：这里只是内存快照。
@MainActor
final class OnboardingDraftState: ObservableObject {
    /// 当前工作副本（尚未写入 `SettingsStore`）。
    @Published var draft: Configuration
    /// 当前步骤，0...3。
    @Published var step: Int
    /// 是否已经为"隐私"步骤套用过默认开启，避免保护恢复后覆盖用户的手动开关。
    @Published var appliedPrivacyDefault: Bool

    init(
        draft: Configuration,
        step: Int = 0,
        appliedPrivacyDefault: Bool = false
    ) {
        self.draft = draft
        self.step = step
        self.appliedPrivacyDefault = appliedPrivacyDefault
    }

    /// 视图把最新编辑同步回来。
    func update(draft: Configuration) {
        guard self.draft != draft else { return }
        self.draft = draft
    }

    func update(step: Int) {
        guard self.step != step else { return }
        self.step = step
    }
}
