import Foundation

/// Routing for the PR workspace's single-key shortcuts (j/k/x/t/a/r/c/m/Return and ?). The app classifies the
/// window's first responder; this decides whether the key is the workspace's.
public enum PRKeyboardScope {
  public enum Focus: Sendable, Equatable {
    /// An editable text field or text view.
    case editableText
    /// Controls that consume typed characters themselves: date pickers, the app's file and repository trees.
    case exempt
    /// The PR list ("prList").
    case prList
    /// Any other list or table (the sidebar, a repository list), which keeps type-to-select.
    case otherList
    /// Other content inside the PR workspace, such as the board.
    case workspace
    /// Nothing specific: the window itself or a container that encloses the whole workspace.
    case container
    /// Something outside the workspace that is not a list, such as a toolbar or another pane's control.
    case elsewhere
  }
  public struct Modifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)
  }
  /// The key the workspace handles, or nil to leave the event to the focused view. `characters` are the event's
  /// characters ignoring modifiers and are never case-folded, so Shift+J is not "j". In the main window only the
  /// board or PR list takes keys; an embedded workspace (repository tab) keeps its original rule, where only other
  /// lists, editors and exempt controls keep their keys.
  public static func key(characters: String?, modifiers: Modifiers, focus: Focus, embedded: Bool) -> String? {
    switch focus {
    case .editableText, .exempt, .otherList: return nil
    case .elsewhere: guard embedded else { return nil }
    case .prList, .workspace, .container: break
    }
    guard let characters, !characters.isEmpty else { return nil }
    // "?" is typed with Shift on most layouts; it opens the keyboard shortcut list.
    if characters == "?" { return modifiers.subtracting(.shift).isEmpty ? characters : nil }
    return modifiers.isEmpty ? characters : nil
  }
}

/// A key and its modifiers, displayed in macOS order (⌃⌥⇧⌘). `key` is a single character or one of
/// "return", "escape", "space", "up", "down".
public struct KeyChord: Hashable, Sendable {
  public enum Modifier: Int, CaseIterable, Comparable, Sendable {
    case control, option, shift, command
    public static func < (a: Modifier, b: Modifier) -> Bool { a.rawValue < b.rawValue }
    var symbol: String {
      switch self {
      case .control: "⌃"
      case .option: "⌥"
      case .shift: "⇧"
      case .command: "⌘"
      }
    }
  }
  public let key: String
  public let modifiers: Set<Modifier>
  public init(_ key: String, _ modifiers: Set<Modifier> = []) { self.key = key; self.modifiers = modifiers }
  public var display: String {
    let name: String =
      switch key {
      case "return": "Return"
      case "escape": "Esc"
      case "space": "Space"
      case "up": "↑"
      case "down": "↓"
      default: key.uppercased()
      }
    return modifiers.sorted().map(\.symbol).joined() + name
  }
}

extension PRGlobalShortcut {
  /// The registered chord, or nil when this global shortcut is disabled.
  public var chord: KeyChord? {
    guard enabled else { return nil }
    var modifiers: Set<KeyChord.Modifier> = []
    if control { modifiers.insert(.control) }
    if option { modifiers.insert(.option) }
    if shift { modifiers.insert(.shift) }
    if command { modifiers.insert(.command) }
    return KeyChord(key.lowercased(), modifiers)
  }
}

/// Every keyboard shortcut, for the main menu and the Keyboard Shortcuts window. Menu chords avoid the PR
/// window's own shortcuts and standard macOS chords (tested).
public enum KeyboardShortcutCatalog {
  public enum Scope: Sendable, Equatable {
    /// Main-menu key equivalents, available in every window.
    case menu
    /// Single keys while the board or PR list has focus.
    case board
    /// Keys in a pull request window.
    case prWindow
    /// Keys while the activity inbox list has focus.
    case inbox
    /// Keys inside the command palette or label picker.
    case popup
  }
  public struct Entry: Identifiable, Sendable {
    public let title: String
    /// Nil when the shortcut is shown as free text (for example "Space or Return").
    public let chord: KeyChord?
    public let keys: String
    public let scope: Scope
    public var id: String { title + "|" + keys }
    init(_ title: String, _ chord: KeyChord, _ scope: Scope) { self.title = title; self.chord = chord; keys = chord.display; self.scope = scope }
    init(_ title: String, keys: String, _ scope: Scope) { self.title = title; chord = nil; self.keys = keys; self.scope = scope }
  }
  public struct Section: Identifiable, Sendable {
    public let title: String
    public let entries: [Entry]
    public var id: String { title }
  }

  // Pull Request menu
  public static let openPR = KeyChord("o", [.command])
  public static let approve = KeyChord("a", [.shift, .command])
  public static let labels = KeyChord("l", [.shift, .command])
  public static let copyLink = KeyChord("c", [.option, .command])
  public static let openOnWeb = KeyChord("o", [.shift, .command])
  public static let nextPR = KeyChord("down", [.option, .command])
  public static let previousPR = KeyChord("up", [.option, .command])
  // View menu
  public static let board = KeyChord("1", [.command])
  public static let list = KeyChord("2", [.command])
  public static let find = KeyChord("f", [.command])
  public static let palette = KeyChord("k", [.command])
  public static let refresh = KeyChord("r", [.command])
  // Go menu, in sidebar order: Pull Requests, Actions, Repositories, Local, Activity Inbox, Setup.
  public static let go = (1...6).map { KeyChord(String($0), [.option, .command]) }
  // Pull request window sections, in tab order: Overview, Conversation, Files changed, Commits, Checks, Deployments.
  public static let prWindowTabs = (1...6).map { KeyChord(String($0), [.control, .command]) }
  // File and Help
  public static let openMain = KeyChord("m", [.shift, .command])
  public static let shortcutsHelp = KeyChord("/", [.command])

  public static let sections: [Section] = [
    Section(title: "Pull Request menu", entries: [
      Entry("Open", openPR, .menu), Entry("Approve…", approve, .menu), Entry("Labels…", labels, .menu),
      Entry("Copy Link", copyLink, .menu), Entry("Open on GitHub", openOnWeb, .menu),
      Entry("Next Pull Request", nextPR, .menu), Entry("Previous Pull Request", previousPR, .menu),
    ]),
    Section(title: "View menu", entries: [
      Entry("Board", board, .menu), Entry("List", list, .menu), Entry("Find", find, .menu),
      Entry("Command Palette", palette, .menu), Entry("Refresh", refresh, .menu),
    ]),
    Section(title: "Go menu", entries: zip(["Pull Requests", "Actions", "Repositories", "Local", "Activity Inbox", "Setup"], go).map {
      Entry($0.0, $0.1, .menu)
    }),
    Section(title: "App", entries: [Entry("Open MergePro", openMain, .menu), Entry("Keyboard Shortcuts", shortcutsHelp, .menu)]),
    Section(title: "Board and list (when the board or list has focus)", entries: [
      Entry("Next pull request", KeyChord("j"), .board), Entry("Previous pull request", KeyChord("k"), .board),
      Entry("Select or deselect", KeyChord("x"), .board), Entry("Change time scope", KeyChord("t"), .board),
      Entry("Approve…", KeyChord("a"), .board), Entry("Request changes…", KeyChord("r"), .board),
      Entry("Comment…", KeyChord("c"), .board), Entry("Merge…", KeyChord("m"), .board),
      Entry("Open pull request", KeyChord("return"), .board), Entry("Keyboard shortcuts", KeyChord("?"), .board),
    ]),
    Section(title: "Pull request window", entries: [
      Entry("Jump to file", KeyChord("p", [.command]), .prWindow), Entry("Next unviewed file", KeyChord("n"), .prWindow),
      Entry("Previous change", KeyChord("[", [.option]), .prWindow), Entry("Next change", KeyChord("]", [.option]), .prWindow),
      Entry("Next comment", KeyChord("]", [.option, .shift]), .prWindow),
    ] + zip(["Overview", "Conversation", "Files changed", "Commits", "Checks", "Deployments"], prWindowTabs).map { Entry($0.0, $0.1, .prWindow) }
      + [Entry("Keyboard shortcuts (outside text fields)", KeyChord("?"), .prWindow)]),
    Section(title: "Activity inbox (when the list has focus)", entries: [
      Entry("Next item", KeyChord("j"), .inbox), Entry("Previous item", KeyChord("k"), .inbox),
      Entry("Done (mark read in MergePro)", KeyChord("e"), .inbox), Entry("Open pull request", KeyChord("return"), .inbox),
    ]),
    Section(title: "Command palette and label picker", entries: [
      Entry("Move highlight", keys: "↑ ↓", .popup), Entry("Open highlighted result", KeyChord("return"), .popup),
      Entry("Toggle highlighted label", keys: "Space or Return", .popup),
      Entry("Apply label changes", KeyChord("return", [.command]), .popup), Entry("Close", KeyChord("escape"), .popup),
    ]),
  ]
}
