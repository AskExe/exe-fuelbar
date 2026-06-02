import Foundation
import Testing
@testable import ExeWatcherMenubar

@Suite("Update checker")
@MainActor
struct UpdateCheckerTests {
    @Test("debug override does not surface update button when no update exists")
    func debugOverrideDoesNotShowButton() {
        UserDefaults.standard.removeObject(forKey: "UpdateChecker.forceUpdateButton")
        let checker = UpdateChecker()
        checker.latestVersion = nil
        #expect(checker.updateAvailable == false)
        #expect(checker.shouldShowUpdateButton == false)

        // Debug override alone must NOT surface the button in production
        UserDefaults.standard.set(true, forKey: "UpdateChecker.forceUpdateButton")
        defer { UserDefaults.standard.removeObject(forKey: "UpdateChecker.forceUpdateButton") }

        #expect(checker.shouldShowUpdateButton == false,
                "Debug override should not show the button when no update exists")
    }

    @Test("same version is not an update")
    func sameVersionNotUpdate() {
        let checker = UpdateChecker()
        checker.latestVersion = checker.currentVersion
        #expect(checker.updateAvailable == false)
        #expect(checker.shouldShowUpdateButton == false)
    }
}
