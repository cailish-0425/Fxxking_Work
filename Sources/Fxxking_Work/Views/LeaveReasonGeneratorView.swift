import AppKit
import SwiftUI

// MARK: - 数据

/// 一条“请假理由”建议。
///
/// 视图只认 `id` 和已本地化的正文：理由的生成与本地化都在 Service 侧完成
/// （Lead 通过 `generate` 闭包注入 `localizedText`），这里不内置任何理由池，
/// 避免视图文件和 Service 各自维护一份文案。
struct LeaveReasonSuggestion: Identifiable, Equatable, Hashable {
    let id: String
    let text: String

    init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }
}

// MARK: - 视图

/// 请假理由生成器。
///
/// 交互：先播 1.2–1.6 秒“正在翻找借口”，再揭晓一句理由；揭晓后可“再编一个”“复制”。
/// 默认接线（只传 `generate`）只把结果复制到剪贴板，不提交请假记录、不自动改备注；
/// 可选的 `onUse` 仅在调用方显式提供、且用户主动点击时才使用。
///
/// 视图是纯 SwiftUI 内容，不自建窗口：宽度跟随父视图，只有父视图不给约束时
/// 才用 380 作为理想宽度。主面板把它当内嵌内容使用即可。
///
/// 接线只需要闭包，视图不依赖任何 Service 具体类型：
/// ```swift
/// LeaveReasonGeneratorView(
///     generate: { LeaveReasonSuggestion(id: reason.id, text: reason.localizedText) },
///     onUse: { text in leaveNote = text },
///     onDismiss: { showingReasonGenerator = false })
/// ```
/// 菜单栏入口文案直接用 `LeaveReasonGeneratorView.entryTitle`（= `leaveReason.ui.entry`）。
struct LeaveReasonGeneratorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 生成一条理由。视图不关心它来自模板池、随机组合还是远端服务。
    private let generate: () -> LeaveReasonSuggestion
    /// 把揭晓的理由交给调用方（通常是写进请假备注）。nil 时不显示入口。
    private let onUse: ((String) -> Void)?
    /// 关闭面板。nil 时只由外部控制显隐。
    private let onDismiss: (() -> Void)?
    /// 点“填入请假备注”后是否顺手关闭。Lead 想自己接管关闭就传 false。
    private let dismissAfterUse: Bool
    /// 恢复态：把上一次已揭晓的理由直接放回原位（屏幕采集保护打断面板时用）。
    private let restoresExistingResult: Bool

    @State private var suggestion: LeaveReasonSuggestion?
    @State private var attempt = 0
    @State private var copied = false
    @State private var breathing = false
    @State private var lastRevealedText: String?
    /// 结果区随文字大小档位一起放大；思考态和揭晓态共用同一高度，面板不跳。
    @ScaledMetric(relativeTo: .callout) private var resultAreaHeight: CGFloat = 136

    /// 菜单栏/面板里打开生成器的入口文案，与视图共用同一个 key，避免两处写死字符串。
    static var entryTitle: String { Loc.t("leaveReason.ui.entry") }

    /// - Parameter initialSuggestion: 上一次已经揭晓过的理由。传入时视图直接展示它、
    ///   不重播思考动画（保护层把内容换掉再换回来时用），并把它当成"上一句"参与去重；
    ///   点「再编一个」之后仍走正常生成流程。
    init(
        generate: @escaping () -> LeaveReasonSuggestion,
        onUse: ((String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        dismissAfterUse: Bool = true,
        initialSuggestion: LeaveReasonSuggestion? = nil
    ) {
        self.generate = generate
        self.onUse = onUse
        self.onDismiss = onDismiss
        self.dismissAfterUse = dismissAfterUse
        self.restoresExistingResult = initialSuggestion != nil
        _suggestion = State(initialValue: initialSuggestion)
        _lastRevealedText = State(initialValue: initialSuggestion?.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Loc.t("leaveReason.ui.title"))
                .font(.headline)
            card
            footer
            if onUse != nil {
                Text(Loc.t("leaveReason.ui.hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        // 父视图（主面板）决定实际宽度；独立 MenuBarExtra 不给约束时退回理想宽度。
        .frame(idealWidth: 380, maxWidth: .infinity, alignment: .leading)
        // 首次出现与每次“再编一个”都从思考态重新开始；关闭时 task 自动取消。
        // 恢复态（已有上一次结果）不重播思考，直接显示原句。
        .task(id: attempt) { await startIfNeeded() }
        // 复制反馈的自动复位：copied 变 true 时睡 1.6 秒再翻回 false。
        .task(id: copied) { await resetCopyBadge() }
    }

    // MARK: 内容卡片

    /// 固定高度的结果区：思考态、揭晓态、以及前后两次理由之间都不改变高度，
    /// 面板不会在等待结束或“再编一个”时跳动。空间优先留给文案，超长译文
    /// 在卡片内部滚动而不是截断或把面板撑高。
    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)

            if let suggestion {
                ScrollView(.vertical) {
                    Text(suggestion.text)
                        .font(.callout)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isStaticText)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .transition(.opacity)
            } else {
                thinking
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        .frame(height: resultAreaHeight)
    }

    private var thinking: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                // 减少动态效果时用静态符号，不播放旋转/呼吸动画，但保留可读提示。
                Image(systemName: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                breathingDots
            }
            Text(Loc.t("leaveReason.ui.thinking"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Loc.t("leaveReason.ui.thinking"))
    }

    private var breathingDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(breathing ? 1 : 0.55)
                    .opacity(breathing ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: breathing
                    )
            }
        }
        .onAppear { breathing = true }
        .accessibilityHidden(true)
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack(spacing: 10) {
            Button(Loc.t("leaveReason.ui.again")) { retry() }
                .disabled(suggestion == nil)
            Button(action: copyToPasteboard) {
                copyButtonLabel
            }
            .disabled(suggestion == nil)
            // 生成器的主动作就是复制；回车固定触发复制，不提交任何记录。
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(
                copied ? Loc.t("leaveReason.ui.copied") : Loc.t("leaveReason.ui.copy")
            )

            Spacer(minLength: 12)

            if onDismiss != nil {
                Button(Loc.t("leave.cancel")) { onDismiss?() }
                    .keyboardShortcut(.cancelAction)
            }
            if let onUse {
                Button(Loc.t("leaveReason.ui.fillNote")) { use(onUse) }
                    .buttonStyle(.borderedProminent)
                    .disabled(suggestion == nil)
            } else if let onDismiss {
                Button(Loc.t("leave.done")) { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
    }

    /// “复制”和“已复制”同时参与布局，按钮宽度始终取两者最大值：
    /// 复制反馈只换字，复制与再抽两个按钮的位置都不会跳。
    private var copyButtonLabel: some View {
        ZStack {
            Text(Loc.t("leaveReason.ui.copy"))
                .opacity(copied ? 0 : 1)
            Text(Loc.t("leaveReason.ui.copied"))
                .opacity(copied ? 1 : 0)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
    }

    // MARK: 行为

    /// 思考直接写完再揭晓；不做“逐字打字”，避免 1.5 秒里挤进两次动效。
    /// `.task(id: attempt)` 在重抽时取消上一轮，关闭面板时 SwiftUI 也会取消，
    /// 不会堆积多个生成任务；打开时传入的 attempt 会重新走一遍等待。
    @MainActor
    private func startIfNeeded() async {
        if attempt == 0, restoresExistingResult, suggestion != nil { return }
        await runThinking()
    }

    @MainActor
    private func runThinking() async {
        // 面板重新出现时可能还留着上一轮结果；先回到等待态再生成。
        clearResult()
        try? await Task.sleep(for: .milliseconds(Int.random(in: 1_200...1_600)))
        guard !Task.isCancelled else { return }
        let next = nextSuggestion()
        if reduceMotion {
            suggestion = next
        } else {
            withAnimation(.easeOut(duration: 0.35)) { suggestion = next }
        }
    }

    /// “再编一个”：立即清掉旧结果和“已复制”反馈，再启动下一轮等待。
    /// 生成中的按钮是 disabled，配合 `.task(id:)` 的取消语义，连点不会堆任务。
    @MainActor
    private func retry() {
        guard suggestion != nil else { return }
        clearResult(animated: true)
        attempt += 1
    }

    /// 清空结果态。重抽、重新打开、复制反馈复位都走这里，避免残留旧文案。
    @MainActor
    private func clearResult(animated: Bool = false) {
        copied = false
        guard suggestion != nil else { return }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { suggestion = nil }
        } else {
            suggestion = nil
        }
    }

    /// 生成器连续返回同一句时重抽几次，避免“再编一个”看起来没反应。
    /// 比较对象是上一轮真正揭晓的文案：等待期间 `suggestion` 已被清空，
    /// 不能拿它来判重。
    @MainActor
    private func nextSuggestion() -> LeaveReasonSuggestion {
        var candidate = generate()
        var tries = 0
        while candidate.text == lastRevealedText, tries < 5 {
            candidate = generate()
            tries += 1
        }
        lastRevealedText = candidate.text
        return candidate
    }

    @MainActor
    private func resetCopyBadge() async {
        guard copied else { return }
        try? await Task.sleep(for: .milliseconds(1_600))
        guard !Task.isCancelled else { return }
        copied = false
    }

    @MainActor
    private func copyToPasteboard() {
        guard let text = suggestion?.text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        copied = true
        AccessibilityNotification.Announcement(Loc.t("leaveReason.ui.copied")).post()
    }

    @MainActor
    private func use(_ action: (String) -> Void) {
        guard let text = suggestion?.text else { return }
        action(text)
        if dismissAfterUse { onDismiss?() }
    }
}
