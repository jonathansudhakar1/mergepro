import AppKit
import Foundation
import MergeProCore
@testable import MergeProFixtures

/// Standalone model/storage regression. Does not invoke App.main or initialize NSApplication.
@main struct PreviousLookHarness {
    @MainActor static func main() async throws {
        guard ProcessInfo.processInfo.environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(UUID.init(uuidString:)) != nil,
              ProcessInfo.processInfo.environment["MERGEPRO_PHASE1_FIXTURES"] == nil,
              ProcessInfo.processInfo.environment["MERGEPRO_PR_FIXTURE_COUNT"] == nil,
              NSApp == nil else { throw CocoaError(.fileReadNoPermission) }
        let storage=SetupStorage()
        let initial=try await storage.prWorkspace()
        guard initial.lastLookAt == nil else { throw CocoaError(.fileReadNoPermission) }
        let first=PRWorkspaceModel(storage:storage)
        await first.load()
        guard let firstLook=first.state.lastLookAt else { throw CocoaError(.coderReadCorrupt) }
        // Wait for the model's existing debounce. No selection/filter/preference or store.save.
        try await Task.sleep(for:.milliseconds(400))
        let reopenedStorage=SetupStorage()
        let persisted=try await reopenedStorage.prWorkspace()
        let reopened=PRWorkspaceModel(storage:reopenedStorage)
        await reopened.load()
        guard persisted.lastLookAt == firstLook,reopened.previousLookCutoff == firstLook,NSApp == nil else {
            print("FAIL native model load -> no user mutation -> reopened storage/model: persisted look \(String(describing:persisted.lastLookAt)); first look \(firstLook); reopened cutoff \(reopened.previousLookCutoff); NSApplication initialized \(NSApp != nil)")
            exit(1)
        }
        print("PASS actual PRWorkspaceModel/SetupStorage load -> no user mutation -> reopened storage/model retains prior look; NSApplication absent; no accounts/network/credentials")
    }
}
