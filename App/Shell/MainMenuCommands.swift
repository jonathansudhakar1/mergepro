import AppKit
import MergeProCore
import SwiftUI

extension KeyChord {
  var keyEquivalent: KeyEquivalent {
    switch key {
    case "return": .return
    case "escape": .escape
    case "space": .space
    case "up": .upArrow
    case "down": .downArrow
    default: KeyEquivalent(Character(key))
    }
  }
  var eventModifiers: EventModifiers {
    var result: EventModifiers = []
    if modifiers.contains(.command) { result.insert(.command) }
    if modifiers.contains(.option) { result.insert(.option) }
    if modifiers.contains(.control) { result.insert(.control) }
    if modifiers.contains(.shift) { result.insert(.shift) }
    return result
  }
  var shortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }
}

/// The app's menus. Pull Request items act on the focused window's `PRCommandTarget` (the board/list focus in
/// the main window, or a PR window's pull request) and are disabled when it offers no such command. View items
/// use the PR workspace's commands when it publishes them and otherwise bring the main window to that view.
/// Every chord comes from `KeyboardShortcutCatalog`, which the Keyboard Shortcuts window lists.
struct MainMenuCommands: Commands {
  let setup: SetupModel
  @FocusedValue(\.prCommandTarget) private var target
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open MergePro") { showMain() }
        .keyboardShortcut(KeyboardShortcutCatalog.openMain.shortcut)
    }
    CommandGroup(before: .toolbar) {
      Button("Board") {
        if let showBoard = target?.showBoard { showBoard() } else { show(mode: .board) }
      }.keyboardShortcut(KeyboardShortcutCatalog.board.shortcut)
      Button("List") {
        if let showList = target?.showList { showList() } else { show(mode: .list) }
      }.keyboardShortcut(KeyboardShortcutCatalog.list.shortcut)
      Divider()
      Button("Find") { target?.find?() }
        .keyboardShortcut(KeyboardShortcutCatalog.find.shortcut)
        .disabled(target?.find == nil)
      Button("Command Palette") {
        if let showPalette = target?.showPalette { showPalette() } else { setup.prs.palettePresented = true; showMain() }
      }.keyboardShortcut(KeyboardShortcutCatalog.palette.shortcut)
      Button("Refresh") {
        if let refresh = target?.refreshWorkspace ?? target?.refresh { refresh() }
        else if !setup.isRefreshing { Task { await setup.refreshActivity() } }
      }
      .keyboardShortcut(KeyboardShortcutCatalog.refresh.shortcut)
      .disabled(target?.isRefreshing == true)
      Divider()
    }
    CommandMenu("Go") {
      let go = KeyboardShortcutCatalog.go
      Button("Pull Requests") { open(.pullRequests) }.keyboardShortcut(go[0].shortcut)
      Button("Actions") { setup.showActions(); showMain() }.keyboardShortcut(go[1].shortcut)
      Button("Repositories") { open(.repos) }.keyboardShortcut(go[2].shortcut)
      Button("Local") { setup.localCheckout = nil; open(.local) }.keyboardShortcut(go[3].shortcut)
      Button("Activity Inbox") { open(.activity) }.keyboardShortcut(go[4].shortcut)
      Button("Setup") { open(.setup) }.keyboardShortcut(go[5].shortcut)
    }
    CommandMenu("Pull Request") {
      if let subject = target?.subject { Text(subject) }
      item("Open", target?.open, KeyboardShortcutCatalog.openPR)
      Divider()
      item("Approve…", target?.approve, KeyboardShortcutCatalog.approve)
      item("Request Changes…", target?.requestChanges)
      item("Comment…", target?.comment)
      item("Merge…", target?.merge)
      item("Labels…", target?.labels, KeyboardShortcutCatalog.labels)
      Divider()
      item("Copy Link", target?.copyLink, KeyboardShortcutCatalog.copyLink)
      item("Open on GitHub", target?.openOnWeb, KeyboardShortcutCatalog.openOnWeb)
      item("Refresh Pull Request", target?.refresh)
      Divider()
      item("Next Pull Request", target?.nextPR, KeyboardShortcutCatalog.nextPR)
      item("Previous Pull Request", target?.previousPR, KeyboardShortcutCatalog.previousPR)
    }
    CommandGroup(replacing: .help) {
      Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsHelp.windowID) }
        .keyboardShortcut(KeyboardShortcutCatalog.shortcutsHelp.shortcut)
    }
  }

  private func item(_ title: String, _ action: (() -> Void)?, _ chord: KeyChord? = nil) -> some View {
    Button(title) { action?() }
      .keyboardShortcut(chord?.shortcut)
      .disabled(action == nil)
  }
  private func showMain() {
    openWindow(id: "main")
    NSApplication.shared.activate()
  }
  private func open(_ destination: SetupModel.Destination) {
    setup.destination = destination
    showMain()
  }
  private func show(mode: PRViewConfiguration.Mode) {
    setup.prs.state.current.mode = mode
    open(.pullRequests)
  }
}
