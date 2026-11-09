import Foundation

/// 税后估算的纯函数核心。一次算出 12 个月的逐月净额，支持累计预扣、13/14 薪合并计税、
/// 地区参考参数校验。不联网、不改任何状态、无 SwiftUI 依赖。
enum NetPayCalculator {
    /// 单项社保个人缴费明细（分）。
    struct SocialDetail: Equatable {
        var pension: Money = .zero
        var medical: Money = .zero
        var medicalFixed: Money = .zero
        var unemployment: Money = .zero
        var housingFund: Money = .zero

        var total: Money { pension + medical + medicalFixed + unemployment + housingFund }
    }

    /// 单月结果。
    struct MonthlyNet: Equatable {
        var month: Int                      // 1…12
        var gross: Money = .zero            // 当月毛额（含 13/14 薪若落在本月）
        var social: SocialDetail = .init()  // 个人缴费明细
        var socialTotal: Money { social.total }
        var taxable: Money = .zero          // 当月应纳税所得额
        var cumulativeTaxable: Money = .zero
        var tax: Money = .zero              // 当月预扣（>=0，不产生负税/退税）
        var net: Money = .zero              // 到手现金 = gross - socialTotal - tax
    }

    struct Result: Equatable {
        var available: Bool = false
        /// 阻塞性问题：存在时 available == false，months 为空，UI 不得显示净额。
        var blocked: [String] = []
        /// 非阻塞提示：仍可计算，但需用户知悉（如自定义模式、超出参考上下限等）。
        var warnings: [String] = []
        var months: [MonthlyNet] = []
        var yearGross: Money = .zero
        var yearSocial: Money = .zero
        var yearTax: Money = .zero
        var yearNet: Money = .zero
        /// 解析后的社保（有效基数/比例/固定额/状态/issue），UI 可直接展示，不复制算法。
        var resolved: ResolvedSocial = .init()
    }

    // MARK: - 统一解析契约（compute 与 UI 共用）

    enum BaseState: Equatable {
        case automatic
        case manual
        case disabled
    }

    struct ResolvedItem: Equatable {
        var state: BaseState = .automatic
        var base: Money = .zero     // 有效基数（disabled 为 0）
        var rateBp: Int = 0         // 有效比例（基点）
        var amount: Money = .zero   // 缴费额 = base × rate（医疗固定额即固定额本身）
    }

    struct ResolvedSocial: Equatable {
        var pension: ResolvedItem = .init()
        var medical: ResolvedItem = .init()
        var medicalFixed: ResolvedItem = .init()
        var unemployment: ResolvedItem = .init()
        var housingFund: ResolvedItem = .init()
        /// 阻塞性错误（参考地区手填超限、非法比例/负基数/溢出等），compute 会并入 Result.blocked。
        var blocked: [String] = []
        /// 非阻塞提示（自定义模式假设、未收录地区等），compute 会并入 Result.warnings。
        var issues: [String] = []

        var total: Money {
            pension.amount + medical.amount + medicalFixed.amount
                + unemployment.amount + housingFund.amount
        }
    }

    /// 是否适用税后估算：仅中国大陆单位职工 + 人民币。
    static func applies(countryCode: String, currencyCode: String) -> Bool {
        countryCode.uppercased() == "CN" && currencyCode.uppercased() == "CNY"
    }

    /// 统一解析：把 TaxProfile 里 auto/手动/不参与 三态，解析为有效基数/比例/缴费额与状态。
    /// gross=0 时 auto 基数取 0（不被最低基数抬高）。手填值保留；
    /// 参考地区手填越上下限 → blocked（可切换自定义估算）；custom 在合法范围估算并给假设提示。
    static func resolve(profile: TaxProfile, grossMonthly: Money) -> ResolvedSocial {
        var r = ResolvedSocial()
        let social = profile.social
        let preset = TaxRegionPreset.all.first(where: { $0.id == profile.region })
        if preset == nil, !profile.region.isEmpty, profile.region != "custom" {
            r.issues.append("地区「\(profile.region)」未在参考清单中，按自定义参数估算，请确认缴费资格")
        }
        if profile.region == "custom" || (preset == nil && !profile.region.isEmpty) {
            r.issues.append("自定义模式：缴费基数、比例与扣除资格请按实际工资单确认，本结果不视为官方核定")
        }

        func baseState(_ b: SocialBase) -> BaseState {
            switch b {
            case .auto: return .automatic
            case .disabled: return .disabled
            case .manual: return .manual
            }
        }

        func item(
            _ base: SocialBase, rateBp: Int, name: String,
            minYuan: Int64?, maxYuan: Int64?
        ) -> ResolvedItem {
            var it = ResolvedItem(state: baseState(base), rateBp: rateBp)
            switch base {
            case .disabled:
                it.base = .zero
                it.amount = .zero
            case .manual(let m):
                // 手填值保留（含 0）；负值/非法金额在此层拦截，不 clamp、不覆盖。
                guard m.cents >= 0 else {
                    r.blocked.append("\(name)手填基数不能为负")
                    return it
                }
                it.base = m
                it.amount = it.base.applyingRate(bp: rateBp)
                // 参考地区手填越上下限：阻塞并说明（可选自定义），保留原输入不覆盖。
                if let preset {
                    let yuan = it.base.cents / 100
                    if let minYuan, yuan < minYuan {
                        r.blocked.append(
                            "\(name)基数 \(it.base.doubleYuan) 元低于 \(preset.name)参考下限 \(minYuan) 元；如需按此估算请切换为自定义地区")
                    }
                    if let maxYuan, yuan > maxYuan {
                        r.blocked.append(
                            "\(name)基数 \(it.base.doubleYuan) 元超出 \(preset.name)参考上限 \(maxYuan) 元；如需按此估算请切换为自定义地区")
                    }
                }
            case .auto:
                // gross=0 或负时 auto 基数为 0，缴费为 0，不抬到最低基数。
                guard grossMonthly.cents > 0 else {
                    it.base = .zero
                    it.amount = .zero
                    return it
                }
                var cents = grossMonthly.cents
                if let minYuan { cents = max(cents, minYuan * 100) }
                if let maxYuan { cents = min(cents, maxYuan * 100) }
                it.base = Money(cents: cents)
                it.amount = it.base.applyingRate(bp: rateBp)
            }
            return it
        }

        r.pension = item(social.pension, rateBp: social.pensionRateBp, name: "养老",
                         minYuan: preset?.socialBaseMinYuan, maxYuan: preset?.socialBaseMaxYuan)
        r.medical = item(social.medical, rateBp: social.medicalRateBp, name: "医疗",
                         minYuan: preset?.socialBaseMinYuan, maxYuan: preset?.socialBaseMaxYuan)
        r.unemployment = item(social.unemployment, rateBp: social.unemploymentRateBp, name: "失业",
                              minYuan: preset?.socialBaseMinYuan, maxYuan: preset?.socialBaseMaxYuan)
        r.housingFund = item(social.housingFund, rateBp: social.housingFundRateBp, name: "公积金",
                             minYuan: preset?.fundBaseMinYuan, maxYuan: preset?.fundBaseMaxYuan)

        // 医疗固定额：独立 auto/手动/不参与，不被基数状态吞掉。
        // 零工资时 auto 固定额也为 0（与 auto 基数同规则，不凭空产生缴费）。
        var fixed = ResolvedItem(state: baseState(social.medicalFixed))
        switch social.medicalFixed {
        case .disabled:
            fixed.base = .zero; fixed.amount = .zero
        case .manual(let m):
            guard m.cents >= 0 else {
                r.blocked.append("医疗固定额不能为负")
                break
            }
            fixed.base = m
            fixed.amount = m
        case .auto:
            let v = grossMonthly.cents > 0 ? Money.yuan(Int(preset?.medicalFixedYuan ?? 0)) : .zero
            fixed.base = v; fixed.amount = v
        }
        r.medicalFixed = fixed

        // 比例范围校验：仅对参与缴费（非 disabled）的项生效，disabled 的隐藏残留值不误报。
        let rateItems: [(SocialBase, Int, String)] = [
            (social.pension, social.pensionRateBp, "养老"),
            (social.medical, social.medicalRateBp, "医疗"),
            (social.unemployment, social.unemploymentRateBp, "失业"),
            (social.housingFund, social.housingFundRateBp, "公积金"),
        ]
        for (base, bp, name) in rateItems where base != .disabled {
            if bp < 0 || bp > 10_000 {
                r.blocked.append("\(name)个人比例须在 0–100% 之间")
            }
        }
        // 公积金比例：参考地区范围内校验，超范围按自定义处理并提示，不得按地区官方正常计算。
        if let preset, social.housingFund != .disabled {
            let bp = social.housingFundRateBp
            if bp < preset.fundRateMinBp || bp > preset.fundRateMaxBp {
                r.blocked.append(
                    "公积金个人比例 \(Double(bp) / 100)% 超出 \(preset.name)参考范围 \(Double(preset.fundRateMinBp) / 100)%–\(Double(preset.fundRateMaxBp) / 100)%；如需按此估算请切换为自定义地区")
            }
        }
        return r
    }

    /// 计算全年 12 个月净额预测。
    static func compute(
        grossMonthly: Money,
        payMonthsPerYear: Int,
        profile: TaxProfile,
        countryCode: String,
        currencyCode: String
    ) -> Result {
        var result = Result()

        guard applies(countryCode: countryCode, currencyCode: currencyCode) else {
            result.blocked.append("税后仅支持中国大陆单位职工且货币为 CNY")
            return result
        }

        // —— 参数校验（阻塞项）——
        if grossMonthly.cents < 0 {
            result.blocked.append("月薪不能为负")
        }
        if grossMonthly.cents > 1_000_000_000_00 {
            result.blocked.append("月薪金额异常，超出可计算范围")
        }
        if !(1...12).contains(profile.employmentStartMonth) {
            result.blocked.append("任职起月须在 1–12 之间")
        }
        if !(1...12).contains(profile.bonusMonth) {
            result.blocked.append("13/14 薪发放月份须在 1–12 之间")
        }
        if profile.monthlySpecialDeduction.cents < 0 {
            result.blocked.append("专项附加扣除不能为负")
        }
        if profile.monthlyOtherDeduction.cents < 0 {
            result.blocked.append("其他扣除不能为负")
        }

        let resolved = resolve(profile: profile, grossMonthly: grossMonthly)
        result.resolved = resolved
        result.blocked.append(contentsOf: resolved.blocked)
        result.warnings.append(contentsOf: resolved.issues)

        let socialTotal = resolved.total
        if socialTotal.cents > grossMonthly.cents {
            result.blocked.append("当月个人缴费合计 \(socialTotal.doubleYuan) 元超过月薪毛额 \(grossMonthly.doubleYuan) 元")
        }

        if !result.blocked.isEmpty {
            return result
        }

        // —— 逐月累计预扣 ——
        let bonusMonths = max(payMonthsPerYear - 12, 0)
        var cumulativeTaxable = Money.zero
        var cumulativeWithheld = Money.zero
        var months: [MonthlyNet] = []

        for m in 1...12 {
            var entry = MonthlyNet(month: m)
            guard m >= profile.employmentStartMonth else {
                months.append(entry)
                continue
            }
            var gross = grossMonthly
            if m == profile.bonusMonth, bonusMonths > 0 {
                gross = gross + grossMonthly * bonusMonths
            }
            entry.gross = gross
            entry.social = SocialDetail(
                pension: resolved.pension.amount,
                medical: resolved.medical.amount,
                medicalFixed: resolved.medicalFixed.amount,
                unemployment: resolved.unemployment.amount,
                housingFund: resolved.housingFund.amount
            )
            let deductible = socialTotal + profile.monthlySpecialDeduction + profile.monthlyOtherDeduction
            entry.taxable = gross - deductible - TaxRules.monthlyBasicDeduction
            if entry.taxable.cents < 0 { entry.taxable = .zero }

            cumulativeTaxable = cumulativeTaxable + entry.taxable
            entry.cumulativeTaxable = cumulativeTaxable

            let cumulativeTax = TaxRules.cumulativeTax(on: cumulativeTaxable)
            var tax = cumulativeTax - cumulativeWithheld
            if tax.cents < 0 { tax = .zero }
            entry.tax = tax
            cumulativeWithheld = cumulativeWithheld + tax

            entry.net = gross - socialTotal - tax
            months.append(entry)
        }

        result.available = true
        result.months = months
        for m in months {
            result.yearGross = result.yearGross + m.gross
            result.yearSocial = result.yearSocial + m.socialTotal
            result.yearTax = result.yearTax + m.tax
            result.yearNet = result.yearNet + m.net
        }
        return result
    }

    /// 某月的月净额（供 EarningsEngine 取当月值），不可算时返回 nil。
    static func monthNet(_ months: [MonthlyNet], for month: Int) -> Money? {
        guard (1...12).contains(month), let m = months.first(where: { $0.month == month }) else { return nil }
        return m.gross.cents > 0 ? m.net : nil
    }

    /// 逐月毛额版的 compute：工资历史分段后每个月毛额可能不同（月中/跨月涨薪），
    /// 累计预扣必须按「各月各自毛额」逐月累进，不能用今天工资重复推 12 月。
    /// 13/14 薪仍按既有口径：额外月数并入 bonusMonth 所在月的毛额。
    static func compute(
        grossPerMonth: [Money],
        payMonthsPerYear: Int,
        profile: TaxProfile,
        countryCode: String,
        currencyCode: String
    ) -> Result {
        guard grossPerMonth.count == 12 else {
            var r = Result()
            r.blocked.append("逐月毛额必须恰好 12 个月")
            return r
        }

        var result = Result()
        guard applies(countryCode: countryCode, currencyCode: currencyCode) else {
            result.blocked.append("税后仅支持中国大陆单位职工且货币为 CNY")
            return result
        }

        // —— 参数校验（阻塞项）——
        if grossPerMonth.contains(where: { $0.cents < 0 }) {
            result.blocked.append("月薪不能为负")
        }
        if grossPerMonth.contains(where: { $0.cents > 1_000_000_000_00 }) {
            result.blocked.append("月薪金额异常，超出可计算范围")
        }
        if !(1...12).contains(profile.employmentStartMonth) {
            result.blocked.append("任职起月须在 1–12 之间")
        }
        if !(1...12).contains(profile.bonusMonth) {
            result.blocked.append("13/14 薪发放月份须在 1–12 之间")
        }
        if profile.monthlySpecialDeduction.cents < 0 {
            result.blocked.append("专项附加扣除不能为负")
        }
        if profile.monthlyOtherDeduction.cents < 0 {
            result.blocked.append("其他扣除不能为负")
        }

        // 社保参数按「全年代表性月薪」解析一次（取 12 个月里的最大月毛额），
        // 基数上下限与比例参数是配置属性，不随每月毛额逐月变；auto 基数随月薪，
        // 但为保持「一次解析、逐月累进」的简单口径，按最大月薪解析后各月沿用。
        let resolved = resolve(profile: profile, grossMonthly: grossPerMonth.max() ?? .zero)
        result.resolved = resolved
        result.blocked.append(contentsOf: resolved.blocked)
        result.warnings.append(contentsOf: resolved.issues)

        let socialTotal = resolved.total
        for gross in grossPerMonth where socialTotal.cents > gross.cents && gross.cents > 0 {
            result.blocked.append(
                "当月个人缴费合计 \(socialTotal.doubleYuan) 元超过月薪毛额 \(gross.doubleYuan) 元")
        }

        if !result.blocked.isEmpty {
            return result
        }

        // —— 逐月累计预扣 ——
        let bonusMonths = max(payMonthsPerYear - 12, 0)
        var cumulativeTaxable = Money.zero
        var cumulativeWithheld = Money.zero
        var months: [MonthlyNet] = []

        for m in 1...12 {
            var entry = MonthlyNet(month: m)
            guard m >= profile.employmentStartMonth else {
                months.append(entry)
                continue
            }
            var gross = grossPerMonth[m - 1]
            if m == profile.bonusMonth, bonusMonths > 0 {
                // 13/14 薪额外部分：按全年最后一个月毛额折算一次，并入发放月。
                let base = grossPerMonth.last ?? .zero
                gross = gross + base * bonusMonths
            }
            entry.gross = gross
            entry.social = SocialDetail(
                pension: resolved.pension.amount,
                medical: resolved.medical.amount,
                medicalFixed: resolved.medicalFixed.amount,
                unemployment: resolved.unemployment.amount,
                housingFund: resolved.housingFund.amount
            )
            let deductible = socialTotal + profile.monthlySpecialDeduction + profile.monthlyOtherDeduction
            entry.taxable = gross - deductible - TaxRules.monthlyBasicDeduction
            if entry.taxable.cents < 0 { entry.taxable = .zero }

            cumulativeTaxable = cumulativeTaxable + entry.taxable
            entry.cumulativeTaxable = cumulativeTaxable

            let cumulativeTax = TaxRules.cumulativeTax(on: cumulativeTaxable)
            var tax = cumulativeTax - cumulativeWithheld
            if tax.cents < 0 { tax = .zero }
            entry.tax = tax
            cumulativeWithheld = cumulativeWithheld + tax

            entry.net = gross - socialTotal - tax
            months.append(entry)
        }

        result.available = true
        result.months = months
        for m in months {
            result.yearGross = result.yearGross + m.gross
            result.yearSocial = result.yearSocial + m.socialTotal
            result.yearTax = result.yearTax + m.tax
            result.yearNet = result.yearNet + m.net
        }
        return result
    }
}
