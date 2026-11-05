import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private static let storageKey = "configuration.v1"

    @Published var config: Configuration {
        didSet {
            guard config != oldValue else { return }
            if config.language != oldValue.language {
                Loc.select(config.language)
            }
            persist()
        }
    }

    private let defaults: UserDefaults

    /// 改名历史里用过的旧域，按从新到旧排列。bundle id 依次经历过
    /// `dev.wrfly.ilovemyjob` → `dev.cailish-0425.ilovemyjob` → `dev.cailish-0425.Fxxking-Work`。
    /// 每次改 id 后 `UserDefaults.standard` 指向新域，用户以前存的配置还躺在旧域里。
    private static let legacySuiteNames = ["dev.cailish-0425.ilovemyjob", "dev.wrfly.ilovemyjob"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode(Configuration.self, from: data)
        {
            config = decoded
        } else if let migrated = Self.loadLegacyConfiguration() {
            // 新域里还没有本应用配置时，才从旧域回退读一次并迁进新域。
            // 不删不覆盖旧域，用户切回旧版本仍能读到原来的配置。
            config = migrated
            persist()
        } else {
            var initial = Configuration()
            initial.countryCode = Locale.current.region?.identifier ?? "US"
            initial.currencyCode = CountryCatalog.defaultCurrency(for: initial.countryCode) ?? "USD"
            config = initial
        }
        // didSet 在 init 期间不触发，语言得在这里补一次。
        Loc.select(config.language)
    }

    /// 仅当新域缺本应用配置时才回退到旧 bundle id 的域读一次，不删不覆盖旧域。
    private static func loadLegacyConfiguration() -> Configuration? {
        for suiteName in legacySuiteNames {
            guard let legacy = UserDefaults(suiteName: suiteName),
                let data = legacy.data(forKey: storageKey)
            else { continue }
            if let decoded = try? JSONDecoder().decode(Configuration.self, from: data) {
                return decoded
            }
        }
        return nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func resetToDefaults() {
        config = Configuration()
    }
}
