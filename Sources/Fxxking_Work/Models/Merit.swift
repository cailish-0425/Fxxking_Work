import Foundation

// 功德等级只描述"是什么"，给用户看的名字统一放在 Support/DisplayNames.swift（和 SalaryPeriod 同一个规矩）。
// 阈值暂定可回滚：沙弥 0–9999 / 罗汉 10000–99999 / 扫地僧 ≥100000。
enum MeritRank: String, Codable, CaseIterable, Identifiable {
    case novice        // 沙弥
    case arhat         // 罗汉
    case sweepingMonk  // 扫地僧

    var id: String { rawValue }

    /// 达到这一级所需的最低功德，阈值闭区间。
    var threshold: Double {
        switch self {
        case .novice: return 0
        case .arhat: return 10_000
        case .sweepingMonk: return 100_000
        }
    }

    /// 总功德对应的等级。纯函数，负值归最低档。
    static func rank(totalMerit: Double) -> MeritRank {
        let total = max(totalMerit, 0)
        if total >= MeritRank.sweepingMonk.threshold { return .sweepingMonk }
        if total >= MeritRank.arhat.threshold { return .arhat }
        return .novice
    }
}

/// 功德余额，纯值类型。规则暂定可回滚：1 计薪秒 = 1 功德。
struct MeritBalance: Equatable {
    /// 计薪秒数换成功德的汇率。之后想改倍数只动这一处。
    static let meritPerPaidSecond = 1.0

    var total: Double = 0

    var rank: MeritRank { MeritRank.rank(totalMerit: total) }

    /// 计薪秒数换成功德。秒数来自快照的 elapsedSecondsToday（Double），
    /// 功德保留小数，等级只看整数阈值。
    static func earned(fromPaidSeconds seconds: Double) -> Double {
        max(seconds, 0) * meritPerPaidSecond
    }

    /// 累积功德。扣减（兑换）留待下一步，这里只做非负保护。
    mutating func earn(fromPaidSeconds seconds: Double) {
        total = max(total, 0) + Self.earned(fromPaidSeconds: seconds)
    }
}
