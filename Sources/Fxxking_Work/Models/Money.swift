import Foundation

/// 以「分」为单位的整数金额，杜绝浮点误差；税率与比例一律用整数基点。
/// 只在展示边界转回 Double，算钱过程全程整数。
struct Money: Codable, Hashable, Comparable, Sendable {
    var cents: Int64

    init(cents: Int64) { self.cents = cents }

    /// 从元（Double）构造，四舍五入到分。
    init(yuan: Double) { self.cents = Int64((yuan * 100).rounded()) }

    /// 从元构造，字面量友好写法。
    static func yuan(_ value: Double) -> Money { Money(yuan: value) }

    /// 从元构造，整数元。
    static func yuan(_ value: Int) -> Money { Money(cents: Int64(value) * 100) }

    var doubleYuan: Double { Double(cents) / 100 }

    // MARK: - 运算

    static func + (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents + rhs.cents) }
    static func - (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents - rhs.cents) }
    static func * (lhs: Money, rhs: Int) -> Money { Money(cents: lhs.cents * Int64(rhs)) }
    static func * (lhs: Int, rhs: Money) -> Money { rhs * lhs }

    static func < (lhs: Money, rhs: Money) -> Bool { lhs.cents < rhs.cents }

    /// 金额 × 基点比例（800 = 8%），四舍五入到分。
    func applyingRate(bp: Int) -> Money {
        Money(cents: (cents * Int64(bp) + 5_000) / 10_000)
    }
}
