import Foundation

/// 屏幕采集保护层的展示形态。
///
/// 与 SwiftUI 无关，方便在无 GUI 的回归检查里直接跑：`ScreenCaptureGate` 只做映射，
/// 真正的隐私判定（什么时候必须隐藏金额、什么时候可以恢复交互）都留在这里。
enum ScreenCapturePresentation: Equatable {
    /// 没有采集、状态可信：正常展示金额与交互。
    case content
    /// 刚检测到采集事件（或刚启动还在恢复状态）：金额与敏感字段先隐藏，
    /// 但采集可能一闪而过（普通截图），所以只给一个轻量占位。
    case checking
    /// 采集持续超过 `activationDelay`：按持续共享处理，展示阻断提示。
    case blocked
    /// 日志状态源故障：fail-closed，金额继续隐藏并给出重试入口。
    case unavailable

    var hidesSensitiveContent: Bool { self != .content }
}

/// 保护层策略：把监控状态折算成展示形态，并给出"保护结束后如何恢复交互"的规则。
///
/// 这次修复的核心问题：短采集事件（截图、瞬时共享）会让保护层把主面板、设置、
/// 引导的内容整体移出视图树，重新挂载后 `@State` 草稿与理由会话全部丢失。
/// 策略层只负责判定"何时保护、何时可以恢复"，状态所有权由各视图外层的
/// `PanelUIState` / `OnboardingDraftState` 持有，因此保护期间不保留任何 live view。
enum ScreenCaptureProtectionPolicy {
    static func presentation(for state: ScreenCaptureProtectionState) -> ScreenCapturePresentation {
        switch state {
        case .inactive: return .content
        case .pending: return .checking
        case .active: return .blocked
        case .unavailable: return .unavailable
        }
    }

    /// 进入保护时必须清除"此前已揭示金额"的会话状态。
    ///
    /// 包括 `.checking`：短采集也可能持续（或紧接着升级为持续共享），结束后绝不能
    /// 自动把之前揭示过的金额重新露出来，必须由用户重新点击揭示。
    static func shouldResetReveal(onEntering presentation: ScreenCapturePresentation) -> Bool {
        presentation.hidesSensitiveContent
    }

    /// 保护结束（回到 `.content`）时是否需要把用户原本打开的编辑器/会话接回去。
    static func restoresInteractionState(from previous: ScreenCapturePresentation) -> Bool {
        previous.hidesSensitiveContent
    }

    /// 占位视图宽度：跟内容同宽，避免 menu bar 弹窗在保护期间横向跳动。
    static func placeholderWidth(contentWidth: Double?, fallback: Double = 340) -> Double {
        contentWidth ?? fallback
    }

    /// 占位视图高度：沿用上一次内容的实际高度，采集一闪而过时面板不塌陷。
    /// 只记住高度属于尺寸信息，不含金额，也不参与任何可访问性输出。
    static func placeholderMinHeight(lastContentHeight: Double?) -> Double? {
        guard let lastContentHeight, lastContentHeight > 0 else { return nil }
        return lastContentHeight
    }
}

/// 保护代次：每进入一次保护 +1，用于回归检查里验证"短事件 → 恢复"的次序。
struct ProtectionEpochTracker: Equatable {
    private(set) var epoch = 0
    private(set) var lastPresentation: ScreenCapturePresentation = .content

    mutating func note(_ presentation: ScreenCapturePresentation) {
        if presentation.hidesSensitiveContent {
            epoch += 1
        }
        lastPresentation = presentation
    }

    var isProtected: Bool { lastPresentation.hidesSensitiveContent }
}
