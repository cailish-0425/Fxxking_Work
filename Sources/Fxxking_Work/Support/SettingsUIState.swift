import Foundation

/// 设置窗口的界面状态，所有权放在保护层之外（App 里的 `@StateObject`）。
///
/// 屏幕采集期间 `ScreenCaptureGate` 会把设置内容整体移出视图树（这是隐私要求，
/// 不保留 live view）。没有这份状态，任何一次普通截图都会把窗口弹回第一个页签、
/// 并把正在填写的"工资变更"草稿（金额/口径/薪月数/生效日期）一起丢掉。
@MainActor
final class SettingsUIState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case salary
        case schedule
        case holidays
        case display
        case tax
        case about

        var id: String { rawValue }
    }

    /// 当前页签：保护结束后回到原来的页签，而不是第一个。
    @Published var selectedTab: Tab = .salary

    /// 工资变更编辑器的未保存草稿。
    struct SalaryEditorDraft: Equatable, Identifiable {
        let id: UUID
        /// 编辑已存在的变更时保留原 id；新增为 nil。
        let versionID: UUID?
        var amount: Double
        var period: SalaryPeriod
        var payMonthsPerYear: Int
        var effectiveDate: Date

        var isNew: Bool { versionID == nil }

        init(
            id: UUID = UUID(),
            versionID: UUID? = nil,
            amount: Double = 0,
            period: SalaryPeriod = .monthly,
            payMonthsPerYear: Int = 12,
            effectiveDate: Date = Date()
        ) {
            self.id = id
            self.versionID = versionID
            self.amount = amount
            self.period = period
            self.payMonthsPerYear = payMonthsPerYear
            self.effectiveDate = effectiveDate
        }
    }

    @Published var salaryEditor: SalaryEditorDraft?
    /// sheet 的呈现位。保护层把内容换掉时 SwiftUI 会把这里写回 false，
    /// 所以草稿本身（上一行）必须独立保存。
    @Published var salaryEditorVisible = false

    func openSalaryEditor(_ draft: SalaryEditorDraft) {
        salaryEditor = draft
        salaryEditorVisible = true
    }

    /// 用户点取消 / 保存：草稿一起清掉，保护结束后不应再弹回来。
    func closeSalaryEditor() {
        salaryEditor = nil
        salaryEditorVisible = false
    }

    /// 保护结束：只要还有未提交的草稿就重新弹出来。
    ///
    /// 这里不依赖"进入保护时的呈现位"：保护层把内容换掉时 SwiftUI 会把
    /// `salaryEditorVisible` 写回 false，那个时刻先后顺序不可靠；草稿是否存在
    /// 才是稳定信号（只有用户取消/保存才清空）。
    func restoreAfterProtection() {
        guard salaryEditor != nil else { return }
        salaryEditorVisible = true
    }

    /// 设置窗口真正关闭才复位（不是被保护层换掉）。
    func resetForWindowClose() {
        selectedTab = .salary
        closeSalaryEditor()
    }
}
