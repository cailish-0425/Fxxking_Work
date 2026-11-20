import AppKit
import SwiftUI

/// 记录内容实际尺寸：保护期间占位视图沿用最近一次的宽高，弹窗不会因为
/// 一次普通截图就先缩成 340 宽再弹回来。尺寸里不含任何金额。
private struct ProtectedContentSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next.width > 0, next.height > 0 else { return }
        value = next
    }
}

/// 占位视图的两种形态：
/// - `window`：主面板 / 设置窗口 / 引导窗，保留退出、结束加班等安全动作；
/// - `modal`：独立 sheet（请假、加班、工资变更），保护期间**一个可操作元素都不给**，
///   只留一句静态说明，不吃键盘焦点、不提供无障碍动作。
enum ScreenCapturePlaceholderStyle {
    case window
    case modal
}

/// 主面板和设置窗口的统一保护入口。
///
/// 职责边界（这次短采集修复后仍然不变）：
/// - 采集期间把内容**整体移出视图树**，不靠透明度/遮罩，也不保留任何可点击、
///   可聚焦、可无障碍访问的金额控件；`pending` 起就隐藏，持续采集继续阻断，
///   状态源故障继续 fail-closed。
/// - 展示形态由 `ScreenCaptureProtectionPolicy` 决定，占位视图只带"检查中/已阻断/
///   不可用"提示和退出等安全动作。
/// - 需要跨保护期保留的东西（理由会话、引导草稿）不放在这里，而是由保护层外的
///   状态对象持有（`PanelUIState` / `OnboardingDraftState`），这里绝不保留 live view。
struct ScreenCaptureGate<Content: View>: View {
    @EnvironmentObject private var monitor: ScreenCaptureMonitor
    private let content: Content
    private let showsSettingsButton: Bool
    private let contentWidth: CGFloat?
    private let placeholderStyle: ScreenCapturePlaceholderStyle

    @State private var lastContentSize: CGSize = .zero

    /// - Parameters:
    ///   - showsSettingsButton: 占位页是否给"打开设置"入口（引导窗里不给）。
    ///   - contentWidth: 已知内容宽度时直接指定，省掉第一帧的宽度跳变。
    ///   - placeholderStyle: 弹窗（sheet）内容用 `.modal`，不给任何可操作元素。
    init(
        showsSettingsButton: Bool = true,
        contentWidth: CGFloat? = nil,
        placeholderStyle: ScreenCapturePlaceholderStyle = .window,
        @ViewBuilder content: () -> Content
    ) {
        self.showsSettingsButton = showsSettingsButton
        self.contentWidth = contentWidth
        self.placeholderStyle = placeholderStyle
        self.content = content()
    }

    private var presentation: ScreenCapturePresentation {
        ScreenCaptureProtectionPolicy.presentation(for: monitor.state)
    }

    private var placeholderWidth: CGFloat? {
        let measured = contentWidth ?? lastContentSize.width
        guard measured > 0 else { return nil }
        return CGFloat(ScreenCaptureProtectionPolicy.placeholderWidth(contentWidth: Double(measured)))
    }

    private var placeholderMinHeight: CGFloat? {
        ScreenCaptureProtectionPolicy.placeholderMinHeight(lastContentHeight: Double(lastContentSize.height))
            .map { CGFloat($0) }
    }

    var body: some View {
        Group {
            switch presentation {
            case .content:
                content
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ProtectedContentSizeKey.self, value: proxy.size)
                        }
                    )
            case .checking:
                switch placeholderStyle {
                case .window:
                    ScreenCaptureCheckingView(width: placeholderWidth, minHeight: placeholderMinHeight)
                case .modal:
                    ScreenCaptureSheetPlaceholder(width: placeholderWidth, minHeight: placeholderMinHeight)
                }
            case .blocked:
                switch placeholderStyle {
                case .window:
                    ScreenCaptureBlockedView(
                        showsSettingsButton: showsSettingsButton,
                        width: placeholderWidth,
                        minHeight: placeholderMinHeight)
                case .modal:
                    ScreenCaptureSheetPlaceholder(width: placeholderWidth, minHeight: placeholderMinHeight)
                }
            case .unavailable:
                switch placeholderStyle {
                case .window:
                    ScreenCaptureUnavailableView(width: placeholderWidth, minHeight: placeholderMinHeight)
                case .modal:
                    ScreenCaptureSheetPlaceholder(width: placeholderWidth, minHeight: placeholderMinHeight)
                }
            }
        }
        .onPreferenceChange(ProtectedContentSizeKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            lastContentSize = size
        }
    }
}

/// 占位视图共用的尺寸修饰：宽度跟随内容，最小高度沿用上一次内容高度。
private struct ProtectionPlaceholderFrame: ViewModifier {
    let width: CGFloat?
    let minHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(width: width ?? 340)
            .frame(minHeight: minHeight)
    }
}

private extension View {
    func protectionPlaceholderFrame(width: CGFloat?, minHeight: CGFloat?) -> some View {
        modifier(ProtectionPlaceholderFrame(width: width, minHeight: minHeight))
    }
}

/// 独立 sheet（请假、加班、工资变更）在保护期间的占位：没有金额、没有按钮、
/// 不接收键盘焦点，无障碍上只有一个静态说明元素。
///
/// 用它的原因：sheet 是独立窗口，即使宿主内容被移出视图树，系统也可能让它
/// 再显示一会儿；哪怕只显示一帧，也不能是工资、时薪或请假备注。
struct ScreenCaptureSheetPlaceholder: View {
    var width: CGFloat?
    var minHeight: CGFloat?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(Loc.t("screenCapture.sheetProtected"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .protectionPlaceholderFrame(width: width, minHeight: minHeight)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Loc.t("screenCapture.sheetProtected"))
    }
}

/// 系统正在录屏、直播或共享屏幕时替代金额界面，同时保留退出和加班控制。
struct ScreenCaptureBlockedView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var overtime: OvertimeController
    var showsSettingsButton = true
    var width: CGFloat?
    var minHeight: CGFloat?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(Loc.t("screenCapture.blocked.title"))
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(Loc.t("screenCapture.blocked.detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if overtime.active != nil {
                    Button(Loc.t("screenCapture.endOvertime")) {
                        _ = overtime.stop(at: Date())
                    }
                }
                if showsSettingsButton {
                    Button(Loc.t("screenCapture.openSettings")) {
                        openSettings()
                    }
                }
                Button(Loc.t("screenCapture.quit")) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 34)
        .protectionPlaceholderFrame(width: width, minHeight: minHeight)
        .accessibilityElement(children: .contain)
    }
}

/// 启动后的短暂状态恢复阶段也不展示金额，避免在首次日志查询完成前泄露。
///
/// 这一层同时承担"短采集事件"的占位：普通截图只让这里闪一下，采集结束后内容
/// （理由会话、展开的明细）从保护层外的状态对象原样接回来。
struct ScreenCaptureCheckingView: View {
    var width: CGFloat?
    var minHeight: CGFloat?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(Loc.t("screenCapture.checking"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(Loc.t("screenCapture.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.vertical, 34)
        .protectionPlaceholderFrame(width: width, minHeight: minHeight)
        .accessibilityElement(children: .contain)
    }
}

/// 日志状态源故障时采用 fail-closed：金额继续隐藏，并明确告诉用户如何重试。
struct ScreenCaptureUnavailableView: View {
    @EnvironmentObject private var monitor: ScreenCaptureMonitor
    var width: CGFloat?
    var minHeight: CGFloat?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(Loc.t("screenCapture.unavailable.title"))
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(Loc.t("screenCapture.unavailable.detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(Loc.t("screenCapture.retry")) {
                    monitor.retry()
                }
                Button(Loc.t("screenCapture.quit")) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 34)
        .protectionPlaceholderFrame(width: width, minHeight: minHeight)
        .accessibilityElement(children: .contain)
    }
}
