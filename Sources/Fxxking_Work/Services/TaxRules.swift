import Foundation

/// 税后估算所需的国家级规则常量，纯 Foundation、无网络、无 SwiftUI。
///
/// 数值来源见根目录《税前税后调研.md》；此文件只承载「本轮已核验」的固定规则，
/// 地区差异（北京/上海基数上下限、医疗固定额）在 `TaxRegionPreset` 里。
enum TaxRules {
    /// 每月减除费用（元），任职月份每月 5000。
    static let monthlyBasicDeduction = Money.yuan(5_000)

    /// 综合所得七级超额累进：上界（元，含）、税率（基点，100=1%）、速算扣除数（元）。
    /// 上界为 nil 表示无上界（45% 档）。
    static let brackets: [(upperYuan: Int64?, rateBp: Int, quickDeductionYuan: Int64)] = [
        (36_000, 300, 0),
        (144_000, 1_000, 2_520),
        (300_000, 2_000, 16_920),
        (420_000, 2_500, 31_920),
        (660_000, 3_000, 52_920),
        (960_000, 3_500, 85_920),
        (nil, 4_500, 181_920),
    ]

    /// 累计应纳税所得额（分）→ 累计应缴税额（分）。累计额按税档直接套速算扣除数。
    static func cumulativeTax(on cumulativeTaxable: Money) -> Money {
        guard cumulativeTaxable.cents > 0 else { return .zero }
        for bracket in brackets {
            if let upper = bracket.upperYuan {
                if cumulativeTaxable.cents <= upper * 100 {
                    return cumulativeTaxable.applyingRate(bp: bracket.rateBp)
                        - Money.yuan(Int(bracket.quickDeductionYuan))
                }
            } else {
                return cumulativeTaxable.applyingRate(bp: bracket.rateBp)
                    - Money.yuan(Int(bracket.quickDeductionYuan))
            }
        }
        return .zero
    }
}

/// 已核验地区参考参数。选择地区不覆盖手填值；点「应用参考参数」才替换。
struct TaxRegionPreset: Codable, Equatable {
    let id: String          // "beijing" / "shanghai"
    let name: String
    /// 社保基数上下限（养老/医疗/失业共用口径，元）。
    let socialBaseMinYuan: Int64
    let socialBaseMaxYuan: Int64
    /// 公积金基数上下限（元）。
    let fundBaseMinYuan: Int64
    let fundBaseMaxYuan: Int64
    /// 个人比例（基点）：养老 800 / 医疗 200 / 失业 50。
    let pensionRateBp: Int
    let medicalRateBp: Int
    let unemploymentRateBp: Int
    /// 医疗固定额（元/月）：北京 3，上海 0。
    let medicalFixedYuan: Int64
    /// 公积金个人比例范围（基点），供 UI 选择：北京 500…1200，上海 500…700。
    let fundRateMinBp: Int
    let fundRateMaxBp: Int
    /// 政策来源与核查时间，供界面「关于此参考」展示。
    let sourceURLs: [String]
    let effectiveDate: String
    let checkedAt: String

    /// 由参考参数生成的默认社保（基数 `.auto` 随月薪按上下限取值；比例取参考值）。
    var socialDefaults: SocialInsurance {
        SocialInsurance(
            pension: .auto,
            pensionRateBp: pensionRateBp,
            medical: .auto,
            medicalRateBp: medicalRateBp,
            medicalFixed: .auto,
            unemployment: .auto,
            unemploymentRateBp: unemploymentRateBp,
            housingFund: .auto,
            housingFundRateBp: fundRateMinBp
        )
    }

    static let beijing = TaxRegionPreset(
        id: "beijing", name: "北京",
        socialBaseMinYuan: 7_270, socialBaseMaxYuan: 36_348,
        fundBaseMinYuan: 2_540, fundBaseMaxYuan: 36_348,
        pensionRateBp: 800, medicalRateBp: 200, unemploymentRateBp: 50,
        medicalFixedYuan: 3,
        fundRateMinBp: 500, fundRateMaxBp: 1_200,
        sourceURLs: [
            "https://rsj.beijing.gov.cn/xxgk/2024zcjd/202608/t20260821_4831476.html",
            "https://www.bjfsh.gov.cn/zsk/zcwd/202608/t20260818_40116625.shtml",
            "https://banshi.beijing.gov.cn/zcjd/202608/t20260831_428685.html",
        ],
        effectiveDate: "2026-07-01", checkedAt: "2026-11-05"
    )

    static let shanghai = TaxRegionPreset(
        id: "shanghai", name: "上海",
        socialBaseMinYuan: 7_546, socialBaseMaxYuan: 37_731,
        fundBaseMinYuan: 2_740, fundBaseMaxYuan: 37_731,
        pensionRateBp: 800, medicalRateBp: 200, unemploymentRateBp: 50,
        medicalFixedYuan: 0,
        fundRateMinBp: 500, fundRateMaxBp: 700,
        sourceURLs: [
            "https://rsj.sh.gov.cn/tdjjf_17554/20260824/t0035_1443297.html",
            "https://www.shanghai.gov.cn/nw17239/20251211/6a00e933de0347acbc172518d6bbab79.html",
            "https://www.shanghai.gov.cn/gwk/affairs/content/0064%40f3d788ec72e9404ebcbf3d27fda98435",
        ],
        effectiveDate: "2026-07-01", checkedAt: "2026-11-05"
    )

    /// 已知参考地区清单（不含 custom）。
    static let all: [TaxRegionPreset] = [.beijing, .shanghai]
}
