import Foundation

@main
struct PrivacyControllerChecks {
    @MainActor static func main() throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }

        let suite = "FxxkingWork.PrivacyControllerChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var config = Configuration()
        config.privacyModeEnabled = true
        defaults.set(try JSONEncoder().encode(config), forKey: "configuration.v1")

        let settings = SettingsStore(defaults: defaults)
        let privacy = PrivacyController(enabled: true)
        privacy.bind(to: settings)

        expect(!privacy.isRevealed("menu.day"), "Privacy starts masked")
        privacy.toggle("menu.day")
        expect(privacy.isRevealed("menu.day"), "One click reveals the clicked amount")
        expect(privacy.isRevealed("payroll.earned"), "One click also reveals payroll amount")
        expect(privacy.isRevealed("progress.today"), "One click also reveals progress amount")

        privacy.toggle("progress.month")
        expect(!privacy.isRevealed("menu.day"), "A second click anywhere hides all amounts")
        expect(!privacy.isRevealed("payroll.earned"), "Second click hides payroll amount")
        expect(!privacy.isRevealed("progress.today"), "Second click hides progress amount")

        privacy.reveal("overtime.active")
        expect(privacy.isRevealed("overtime.breakdown.paid"), "Reveal action is also panel-wide")

        privacy.resetForLifecycle()
        expect(!privacy.isRevealed("menu.day"), "Lifecycle reset hides all amounts")
        expect(!privacy.isRevealed("payroll.earned"), "Opening with a clean lifecycle starts fully masked")

        privacy.toggle("menu.day")
        expect(privacy.isRevealed("payroll.earned"), "The first user click reveals the whole panel")

        print("\(count)/\(count) privacy controller checks passed")
    }
}
