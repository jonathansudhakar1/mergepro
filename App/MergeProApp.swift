import SwiftUI
import MergeProCore

/// The shipped app's entry point (excluded from the MergeProFixtures target, which has its own in App/Fixtures).
@main
struct MergeProApp: App {
    @State private var setup = SetupModel(dependencies:.forThisApp())
    var body: some Scene {
        // A unit-test host neither presents nor restores the main window, so it never loads setup, polls or installs
        // the menu bar item and its shortcuts behind the tests.
        MainWindowScene(setup:setup, launchBehavior:AppDependencies.isUnitTestHost ? .suppressed : .presented, chrome:EmptyModifier())
            .restorationBehavior(AppDependencies.isUnitTestHost ? .disabled : .automatic)
        SecondaryScenes(setup:setup)
    }
}

extension AppDependencies {
    /// This target's dependencies; `SetupStorage()` uses them too. MergeProAppTests run inside this app, which then
    /// uses `unitTestHost()`: never the real store, Keychain or network.
    static func forThisApp() -> AppDependencies { isUnitTestHost ? .unitTestHost() : SampleMode.isActive ? .sample() : .production() }

    /// XCTest loaded this process to host unit tests. UI tests launch the app without XCTest, so they keep `production()`.
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
