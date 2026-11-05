import Foundation

struct CountryOption: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }
}

struct CurrencyOption: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    var display: String { "\(code) — \(name)" }
}

enum CountryCatalog {
    /// 从任意一个使用该地区的 locale 反推货币，省得手写两百多条映射表。
    private static let currencyCache: [String: String] = {
        var map: [String: String] = [:]
        for identifier in Locale.availableIdentifiers {
            let locale = Locale(identifier: identifier)
            guard let region = locale.region?.identifier,
                let currency = locale.currency?.identifier,
                map[region] == nil
            else { continue }
            map[region] = currency
        }
        return map
    }()

    static func defaultCurrency(for countryCode: String) -> String? {
        currencyCache[countryCode.uppercased()]
    }

    static func name(for countryCode: String) -> String {
        Loc.locale.localizedString(forRegionCode: countryCode) ?? countryCode
    }

    /// 国家名和货币名跟着界面语言走，切换语言后选择器里的两百多项也要跟着变。
    static func allCountries() -> [CountryOption] { lists.countries(for: Loc.locale) }

    static func allCurrencies() -> [CurrencyOption] { lists.currencies(for: Loc.locale) }

    private static let lists = Lists()

    /// 两百多条的本地化加排序不便宜，而语言很少变，按 locale 记住结果。
    private final class Lists: @unchecked Sendable {
        private let lock = NSLock()
        private var countries: [String: [CountryOption]] = [:]
        private var currencies: [String: [CurrencyOption]] = [:]

        func countries(for locale: Locale) -> [CountryOption] {
            let key = locale.identifier
            lock.lock()
            defer { lock.unlock() }
            if let cached = countries[key] { return cached }
            let built = Locale.Region.isoRegions
                .filter { $0.subRegions.isEmpty && $0.identifier.count == 2 }
                .map {
                    CountryOption(
                        code: $0.identifier,
                        name: locale.localizedString(forRegionCode: $0.identifier) ?? $0.identifier
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            countries[key] = built
            return built
        }

        func currencies(for locale: Locale) -> [CurrencyOption] {
            let key = locale.identifier
            lock.lock()
            defer { lock.unlock() }
            if let cached = currencies[key] { return cached }
            let built = Locale.commonISOCurrencyCodes
                .map { CurrencyOption(code: $0, name: locale.localizedString(forCurrencyCode: $0) ?? $0) }
                .sorted { $0.code < $1.code }
            currencies[key] = built
            return built
        }
    }
}
