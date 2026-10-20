import SwiftUI

/// Pull-request commands the main menu routes to the focused window: the board/list selection in the
/// main window, or the pull request shown in a PR window. A nil closure disables that menu item.
struct PRCommandTarget {
    /// Short description for menu titles, e.g. "#123" or "3 pull requests"; nil when nothing is selected.
    var subject: String?
    var open: (() -> Void)?
    var approve: (() -> Void)?
    var requestChanges: (() -> Void)?
    var comment: (() -> Void)?
    var merge: (() -> Void)?
    var labels: (() -> Void)?
    var refresh: (() -> Void)?
    var copyLink: (() -> Void)?
    var openOnWeb: (() -> Void)?
    var nextPR: (() -> Void)?
    var previousPR: (() -> Void)?
    // View menu (MainMenuCommands): workspace-level commands published by the main PR workspace.
    // Nil outside it; the menu then falls back to switching the main window to the PR workspace.
    /// View ▸ Board (⌘1).
    var showBoard: (() -> Void)?
    /// View ▸ List (⌘2).
    var showList: (() -> Void)?
    /// View ▸ Find (⌘F): focus the workspace filter field.
    var find: (() -> Void)?
    /// View ▸ Command Palette (⌘K).
    var showPalette: (() -> Void)?
    /// View ▸ Refresh (⌘R): refresh tracked repositories. `refresh` above stays the PR menu's per-PR refresh.
    var refreshWorkspace: (() -> Void)?
    /// Whether a workspace refresh is already running (the View menu item is then disabled).
    var isRefreshing = false
}

extension FocusedValues {
    /// Published with `.focusedSceneValue(\.prCommandTarget, …)` by the PR workspace and PR windows.
    @Entry var prCommandTarget: PRCommandTarget?
}
