import Foundation

/// 主面板的交互状态，所有权放在保护层之外（App 里的 `@StateObject`）。
///
/// 为什么不在 `MenuContentView` 里：`ScreenCaptureGate` 在采集期间会把整个面板内容
/// 移出视图树，`@State` / `@StateObject` 随之销毁。普通截图也会触发一次 1 秒左右的
/// `pending`，用户看到的就是"理由读一半没了、工资明细自己收起来了"。
///
/// 把状态提到保护层之外后：保护期间依旧**不保留任何 live view**（金额与敏感字段
/// 完全不在视图树里，不存在透明度、遮罩或无障碍残留），保护结束再把原状态接回来。
@MainActor
final class PanelUIState: ObservableObject {
    /// 面板当前是否停留在「编个理由」。
    @Published var showingReasonGenerator = false
    /// 工资明细是否展开。
    @Published var detailsExpanded = false

    /// 上一次揭晓的理由：保护结束后用它把同一句理由接回来，而不是重新抽一句。
    private(set) var lastReason: PanelReasonState?
    /// 生成器会话（连续抽取不重复）也必须在保护期内存活。
    let reasonSession: LeaveReasonSession

    init() {
        self.reasonSession = LeaveReasonSession()
    }

    init(reasonSession: LeaveReasonSession) {
        self.reasonSession = reasonSession
    }

    /// 抽一条新理由并记住，供保护结束后原样接回。
    func nextReason() -> PanelReasonState {
        let reason = reasonSession.next()
        let snapshot = PanelReasonState(id: reason.id, text: reason.text)
        lastReason = snapshot
        return snapshot
    }

    /// 用户主动关掉生成器：下次打开要重新思考，不能直接揭晓上一次的旧理由。
    func closeGenerator() {
        showingReasonGenerator = false
        lastReason = nil
    }

    /// 保护结束：把用户原本打开的界面接回去。
    ///
    /// `showingReasonGenerator` / `detailsExpanded` / `lastReason` 本来就保存在这里，
    /// 保护层动不到它们，所以这里不需要重写任何字段。保留这个入口是为了让
    /// "保护结束必须显式恢复"在调用链上可见，并给后续需要补写字段的界面留位置。
    func restoreAfterProtection() {
    }

    /// 面板真正收起（不是被保护层换掉）才复位，下次打开回到工资单。
    func resetForPanelClose() {
        showingReasonGenerator = false
        detailsExpanded = false
        lastReason = nil
    }
}

/// 一条已揭晓理由的快照（id 用于"再编一个"去重，text 用于原样接回）。
struct PanelReasonState: Equatable {
    let id: String
    let text: String
}
