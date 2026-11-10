import SwiftUI

/// 隐私金额显示组件：无眼睛图标，点击任意金额区域统一显示整块面板，再点统一隐藏。
/// 隐藏态用无边框、可键盘访问的按钮承载「••••」，AX 说「点击显示金额」且不含原值。
struct PrivacyAmount: View {
    @EnvironmentObject private var privacy: PrivacyController
    let surface: String
    let content: () -> String

    var body: some View {
        if !privacy.enabled {
            // 隐私关闭：普通金额照常显示，无隐藏操作、不误导 AX。
            Text(content())
        } else if privacy.isRevealed(surface) {
            // 揭示态：点击金额区域或键盘激活同样 toggle 收起。
            Button {
                privacy.toggle(surface)
            } label: {
                Text(content())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc.t("privacy.hide"))
        } else {
            Button {
                privacy.toggle(surface)
            } label: {
                Text("••••")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc.t("privacy.reveal"))
            .accessibilityHint(Loc.t("privacy.reveal"))
        }
    }
}

/// 隐私金额输入组件：点掩码才变成编辑器，否则显示掩码占位（点击进入编辑态并临时揭示）。
struct PrivacyAmountField: View {
    @EnvironmentObject private var privacy: PrivacyController
    let surface: String
    let label: String
    @Binding var yuan: Double

    var body: some View {
        if !privacy.enabled || privacy.isRevealed(surface) {
            // 隐私关闭直接显示编辑器；开启且已揭示才变编辑器。点击光标不会收起，编辑保持可用。
            TextField(label, value: $yuan, format: .number)
                .multilineTextAlignment(.trailing)
        } else {
            Button {
                privacy.reveal(surface)
            } label: {
                HStack {
                    Spacer()
                    Text("••••")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc.t("privacy.reveal"))
        }
    }
}
