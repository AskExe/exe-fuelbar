import Foundation
import Testing
@testable import ExeWatcherMenubar

@Suite("Update checker")
@MainActor
struct UpdateCheckerTests {
    @Test("local override shows the update button even when no newer version is known")
    func localOverrideShowsUpdateButton() {
        UserDefaults.standard.removeObject(forKey: "UpdateChecker.forceUpdateButton")
        let checker = UpdateChecker()
        checker.latestVersion = nil
        #expect(checker.updateAvailable == false)
        #expect(checker.shouldShowUpdateButton == false)

        UserDefaults.standard.set(true, forKey: "UpdateChecker.forceUpdateButton")
        defer { UserDefaults.standard.removeObject(forKey: "UpdateChecker.forceUpdateButton") }

        #expect(checker.updateAvailable == false)
        #expect(checker.shouldShowUpdateButton == true)
    }
}
