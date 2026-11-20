import SwiftUI

/// 主面板（工资小票）共用的排版常量与小组件。
///
/// 设计约束（与 Lead 定的方向一致）：
/// - 原生材质、系统字体，金额一律 `monospacedDigit()`，避免逐秒跳动时整行左右晃。
/// - 普通文字用 `.secondary`；`.tertiary` 只留给真正的次要备注，不当禁用态用。
/// - 绿色只表示「计薪」，橙色只表示「加班」，蓝色只表示「可交互」。
/// - 进度条只用一套克制的强调色，不做虹彩、渐变、卡片堆。
enum PanelMetrics {
    /// 主面板宽度。与理由生成器（380pt）一致，切换界面时弹窗不横向收缩。
    static let width: CGFloat = 380
    static let contentPadding: CGFloat = 16
    /// 进度条统一强调色：跟随系统强调色但压一点，避免抢金额的视觉权重。
    static let progressTint = Color.accentColor.opacity(0.8)
}

/// 面板内统一的「左标签 / 右数值」行。
///
/// 标签允许折行（法/俄/西语比中文长得多），数值优先占位并保持单行等宽。
struct PanelRow<Value: View>: View {
    let title: String
    let value: () -> Value

    init(_ title: String, @ViewBuilder value: @escaping () -> Value) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            value()
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
        }
    }
}

/// 区块小标题：`payroll.section`、明细这类分组名。
struct PanelSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 进度行：标题 / 金额明细 / 百分比 + 一条细进度条。
///
/// 金额会被 `PrivacyAmount` 包住，`surface` 沿用原有的隐私 key，不改揭示语义。
/// 三种进度共用同一个强调色（`PanelMetrics.progressTint`），不再绿/蓝/紫各来一条。
struct PanelProgressRow: View {
    let surface: String
    let title: String
    let fraction: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 法语标题长、日元金额位数多，一行挤不下就退回「标题+百分比 / 金额」两行。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleText
                    Spacer(minLength: 4)
                    detailText
                    percentText
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleText
                        Spacer(minLength: 4)
                        percentText
                    }
                    detailText
                }
            }
            bar
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(PanelMetrics.progressTint)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 3))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    // 三段都限死单行：Text 默认可折行，那样 ViewThatFits 会永远认为一行放得下。
    private var titleText: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var detailText: some View {
        PrivacyAmount(surface: surface) { detail }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var percentText: some View {
        Text(Formatters.percent(fraction))
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.primary)
            .lineLimit(1)
    }
}
