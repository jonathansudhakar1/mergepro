import SwiftUI
import MergeProCore

/// The main window. Each app target's entry point supplies its launch behavior and `chrome`: the shipped app
/// passes `EmptyModifier()`, the fixture app its measurement chrome.
struct MainWindowScene<Chrome: ViewModifier & Sendable>: Scene {
    let setup: SetupModel
    var launchBehavior: SceneLaunchBehavior = .presented
    let chrome: Chrome
    var body: some Scene {
        Window("MergePro", id: "main") {
            AppShell(model:setup, chrome:chrome)
                .background { WindowFrameMemory(role: "main", minimumSize: DesignTokens.minimumWindowSize) }
                .environment(setup)
                .environment(\.codeSurfaceInstrumentation, setup.codeSurfaceInstrumentation)
                .task { await setup.load() }
        }
        .defaultLaunchBehavior(launchBehavior)
        .defaultSize(DesignTokens.initialWindowSize)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands { MainMenuCommands(setup: setup) }
    }
}

/// Pull request windows, Settings and Keyboard Shortcuts, after the main window in every app target.
struct SecondaryScenes: Scene {
    let setup: SetupModel
    var body: some Scene {
        WindowGroup("Pull Request",id:"pr-detail",for:ProviderKey.self) { key in
            if let current = key.wrappedValue {
                // In-place next/previous/stack navigation writes back, so reopening that PR focuses this window.
                PRDetailRoute(key:current,workspace:setup.prs,navigated:{ key.wrappedValue = $0 }).environment(setup)
                    .environment(\.codeSurfaceInstrumentation, setup.codeSurfaceInstrumentation)
                    .background { WindowFrameMemory(role: "pr-detail", minimumSize: CGSize(width: 900, height: 540)) }
            }
        }
        .defaultSize(width:1280,height:840)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            MergeProSettings(model:setup)
        }

        Window("Keyboard Shortcuts", id: KeyboardShortcutsHelp.windowID) {
            KeyboardShortcutsView(setup: setup)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
