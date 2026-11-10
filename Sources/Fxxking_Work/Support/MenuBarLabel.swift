// 菜单栏标题的文案与隐私状态判定。
//
// 这里刻意不 import SwiftUI，也不依赖 PrivacyController：
// 菜单栏文案是纯函数，放进 Checks 的 swiftc 清单后可以直接断言，
// 不必为了测一次掩码状态去起一个 AppKit 环境。

import Foundation

enum MenuBarLabel {
    /// 菜单栏金额对应的隐私 surface。
    ///
    /// 与主面板共用同一组 surface ID，所以「点主面板今日金额」和「菜单栏显示今日金额」
    /// 揭示的是同一个语义项，不会各存一套状态。返回 nil 表示这一档显示的是百分比/进度，
    /// 不是金额，隐私模式不掩码。
    static func surface(for display: MenuBarDisplay) -> String? {
        switch display {
        case .todayAmount: return "menu.day"
        case .monthAmount: return "progress.month"
        case .todayPercent, .monthPercent, .yearPercent: return nil
        }
    }

    /// 未套隐私的原始文案。
    static func rawText(config: Configuration, earnings: Earnings) -> String {
        switch config.menuBarDisplay {
        case .todayAmount:
            return Formatters.currency(earnings.dayEarned, code: config.currencyCode)
        case .todayPercent:
            return Formatters.percent(earnings.dayFraction, fractionDigits: 1)
        case .monthAmount:
            return Formatters.currency(earnings.monthEarned, code: config.currencyCode, fractionDigits: 0)
        case .monthPercent:
            return Formatters.percent(earnings.monthFraction, fractionDigits: 1)
        case .yearPercent:
            return Formatters.percent(earnings.yearFraction, fractionDigits: 1)
        }
    }

    /// 菜单栏标题：隐私开启且当前档位是金额时，未揭示则显示掩码，已揭示则显示实时金额。
    ///
    /// 百分比与进度档位不受隐私影响，与是否揭示无关。
    static func text(
        config: Configuration, earnings: Earnings, privacyEnabled: Bool, isRevealed: Bool
    ) -> String {
        let raw = rawText(config: config, earnings: earnings)
        guard privacyEnabled, surface(for: config.menuBarDisplay) != nil else { return raw }
        // 揭示态读的是本次传入的实时快照，不冻结、不重算。
        return isRevealed ? raw : "••••"
    }

}
