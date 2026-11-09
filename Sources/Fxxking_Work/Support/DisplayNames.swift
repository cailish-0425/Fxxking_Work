// 所有给用户看的枚举文案集中在这里，模型和算钱逻辑因此不必知道当前是什么语言。

import Foundation

extension SalaryPeriod {
    var label: String {
        switch self {
        case .monthly: return Loc.t("salary.period.monthly")
        case .annual: return Loc.t("salary.period.annual")
        }
    }
}
extension MenuBarDisplay {
    var label: String {
        switch self {
        case .todayAmount: return Loc.t("display.menuBar.todayAmount")
        case .todayPercent: return Loc.t("display.menuBar.todayPercent")
        case .monthAmount: return Loc.t("display.menuBar.monthAmount")
        case .monthPercent: return Loc.t("display.menuBar.monthPercent")
        case .yearPercent: return Loc.t("display.menuBar.yearPercent")
        }
    }
}
extension AppAppearance {
    var label: String {
        switch self {
        case .system: return Loc.t("appearance.system")
        case .light: return Loc.t("appearance.light")
        case .dark: return Loc.t("appearance.dark")
        }
    }
}
extension PayMode {
    var label: String {
        switch self {
        case .gross: return Loc.t("salary.payMode.gross")
        case .net: return Loc.t("salary.payMode.net")
        }
    }
}
extension SalaryVersion {
    /// 历史列表里展示口径：月薪 / 年薪。
    var periodLabel: String {
        switch period {
        case .monthly: return Loc.t("salary.period.monthly")
        case .annual: return Loc.t("salary.period.annual")
        }
    }
}
extension OvertimePayKind {
    var label: String {
        switch self {
        case .paid: return Loc.t("overtime.kind.paid")
        case .unpaid: return Loc.t("overtime.kind.unpaid")
        }
    }
}
extension OvertimeLedgerError {
    var label: String {
        switch self {
        case .alreadyActive: return Loc.t("overtime.error.alreadyActive")
        case .notActive: return Loc.t("overtime.error.notActive")
        case .endBeforeStart: return Loc.t("overtime.error.endBeforeStart")
        case .futureEnd: return Loc.t("overtime.error.future")
        case .overlap: return Loc.t("overtime.error.overlap")
        case .missing: return Loc.t("overtime.error.missing")
        }
    }
}
extension DayOffReason {
    var label: String {
        switch self {
        // 假日名来自数据源，已经是当地语言，只补一个包装句。
        case .holiday(let name): return Loc.t("status.dayOff.holiday", name)
        case .restDay: return Loc.t("status.dayOff.rest")
        case .noSchedule: return Loc.t("status.dayOff.noSchedule")
        }
    }
}
extension WorkStatus {
    var label: String {
        switch self {
        case .dayOff(let reason): return reason.label
        case .beforeWork: return Loc.t("status.beforeWork")
        case .working: return Loc.t("status.working")
        case .onBreak: return Loc.t("status.onBreak")
        case .finished: return Loc.t("status.finished")
        }
    }
}
/// 挖苦文案。这是应用的性格所在，翻译时按语气重写而不是逐字对译。
enum Snark {
    static func line(for earnings: Earnings) -> String {
        switch earnings.status {
        case .dayOff:
            return Loc.t("snark.dayOff")
        case .beforeWork:
            return Loc.t("snark.beforeWork")
        case .onBreak:
            return Loc.t("snark.onBreak")
        case .finished:
            return Loc.t("snark.finished")
        case .working:
            switch earnings.dayFraction {
            case ..<0.25: return Loc.t("snark.working.q1")
            case ..<0.5: return Loc.t("snark.working.q2")
            case ..<0.75: return Loc.t("snark.working.q3")
            default: return Loc.t("snark.working.q4")
            }
        }
    }
}
