import SwiftUI
import MergeProCore

// App/Fixtures is compiled only by the MergeProFixtures target (project.yml), whose xcconfig defines both flags.
#if !(DEBUG && MERGEPRO_FIXTURES)
#error("App/Fixtures belongs to the MergeProFixtures target only.")
#endif

/// The separate offline fixture app: the shipped scenes with fixture dependencies, launch behavior and chrome.
@main
struct MergeProFixturesApp: App {
    @NSApplicationDelegateAdaptor(PRFixtureAppDelegate.self) private var fixtureDelegate
    @State private var setup = SetupModel(dependencies:.forThisApp())
    var body: some Scene {
        MainWindowScene(setup:setup, launchBehavior:LocalSandboxVerification.enabled ? .suppressed : .presented,
                        chrome:ShellFixtureChrome(model:setup))
            .defaultWindowPlacement { _,context in
                let display = context.defaultDisplay.visibleRect
                let size = CGSize(width:min(1280,display.width-40),height:min(800,display.height-40))
                return WindowPlacement(CGPoint(x:display.midX-size.width/2,y:display.midY-size.height/2),size:size)
            }
        SecondaryScenes(setup:setup)
    }
}

extension AppDependencies {
    /// This target's dependencies; `SetupStorage()` uses them too (the offline QA harnesses).
    static func forThisApp() -> AppDependencies { .fixtures() }

    /// Offline only: a fixture credential store, scripted transports and a store named by the mandatory
    /// `MERGEPRO_UI_TEST_NAMESPACE` (without it, every store access fails).
    static func fixtures(environment: [String:String] = ProcessInfo.processInfo.environment) -> AppDependencies {
        let namespace = environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(UUID.init(uuidString:))?.uuidString
        let runtime = FixtureRuntime()
        let transport: any GitHubTransport
        if Phase23Fixtures.enabled { transport = Phase23FixtureTransport() }
        else if PRPhase1Fixtures.enabled { transport = runtime.phase1Transport }
        else { transport = PRFixtureOfflineTransport() }
        return AppDependencies(
            storageDirectoryName:namespace.map { "MergeProUIFixtures/" + $0 },
            credentials:PRFixtureCredentialStore(), transport:transport, signInTransport:PRFixtureOfflineTransport(),
            // Fixture rows change outside the poller, so cycles fetch nothing and report unknown changes.
            pollFetchers:[],
            mergeAdapter:{ database -> any MergeAdapter in PRPhase1Fixtures.enabled ? GitHubMergeAdapter() : PRMergeFixtureAdapter(database:database) },
            clock:{ Date() }, makeNotificationSink:{ SystemNotificationSink(isEnabled:$0) },
            // Fixture transports script their provider reads, and detail verification measures cold opens.
            speculativeDetailReads:false, reportsCycleChanges:false,
            globalHotkeysUnavailable:"Global shortcuts disabled in fixtures.", fixtures:runtime)
    }
}

/// Settings only the fixture seeds write.
extension SettingsKey {
    static let prFixtureSeeded = SettingsKey(rawValue:"prFixtureSeeded")
    static let mergeFixtureSeeded = SettingsKey(rawValue:"mergeFixtureSeeded")
    static let phase1Seeded = SettingsKey(rawValue:"phase1Seeded")
    static let phase23Seeded = SettingsKey(rawValue:"phase23Seeded")
}
