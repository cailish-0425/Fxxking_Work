import Foundation

@main
struct SettingsStateChecks {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }

        let freshSuite = "FxxkingWork.SettingsChecks.Fresh.\(UUID().uuidString)"
        let freshDefaults = UserDefaults(suiteName: freshSuite)!
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        let fresh = SettingsStore(defaults: freshDefaults, migrateLegacy: false)
        expect(fresh.needsOnboarding, "没有本地配置的新安装应进入首次引导")
        expect(fresh.config.privacyModeEnabled, "新安装默认开启隐私模式")

        fresh.completeOnboarding()
        let reread = SettingsStore(defaults: freshDefaults, migrateLegacy: false)
        expect(!reread.needsOnboarding, "完成引导后应持久化 onboardingCompleted")

        let legacySuite = "FxxkingWork.SettingsChecks.Legacy.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        let legacyJSON = #"{"salaryAmount":10000,"countryCode":"CN","currencyCode":"CNY"}"#
        legacyDefaults.set(Data(legacyJSON.utf8), forKey: "configuration.v1")
        let upgraded = SettingsStore(defaults: legacyDefaults)
        expect(!upgraded.needsOnboarding, "旧配置缺少 onboardingCompleted 时应视为升级用户")
        expect(upgraded.config.salaryAmount == 10000, "旧配置工资应保持")

        print("\(checks)/\(checks) settings state checks passed")
    }
}
