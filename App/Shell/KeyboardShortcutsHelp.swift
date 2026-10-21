import MergeProCore
import SwiftUI

/// Opens the Keyboard Shortcuts window. The app shell installs `show` (it can open windows) so AppKit key
/// handlers such as the board's "?" key can use it.
@MainActor enum KeyboardShortcutsHelp {
  static let windowID = "keyboard-shortcuts"
  static var show: () -> Void = {}
}

/// Every shortcut in one list (Help ▸ Keyboard Shortcuts, ⌘/ or "?" on the board), read from the same catalogue
/// the menus use. Escape closes it.
struct KeyboardShortcutsView: View {
  let setup: SetupModel
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    let global = setup.prs.state.globalShortcuts ?? PRGlobalShortcuts()
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ForEach(KeyboardShortcutCatalog.sections) { section in
          group(section.title, rows: section.entries.map { ($0.keys, $0.title) })
        }
        group("System-wide (change in Settings)", rows: [
          (global.palette.chord?.display ?? "Off", "Command palette from any app"),
          (global.menuBar.chord?.display ?? "Off", "Show the menu bar popover"),
        ])
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 640)
    .background {
      Button("Close") { dismissWindow(id: KeyboardShortcutsHelp.windowID) }
        .keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true)
    }
    .accessibilityIdentifier("keyboardShortcuts")
  }

  private func group(_ title: String, rows: [(keys: String, title: String)]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline).accessibilityAddTraits(.isHeader)
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            Text(row.keys)
              .font(.body.monospaced().weight(.medium))
              .padding(.horizontal, 6).padding(.vertical, 1)
              .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
              // Each section is its own grid; a shared width keeps the key column aligned across sections.
              .frame(minWidth: 96, alignment: .trailing)
              .gridColumnAlignment(.trailing)
            Text(row.title)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(row.title): \(row.keys)")
        }
      }
    }
  }
}
