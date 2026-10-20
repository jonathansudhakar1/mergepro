import AppKit
import MergeProCore
import SwiftUI

/// One local monitor attached to the workspace's own window; no global capture or logging.
/// Single keys go to the workspace only while the board or its list has focus (`PRKeyboardScope`); the sidebar
/// and other lists keep type-to-select, and Shift is a modifier. "?" opens the keyboard shortcut list.
struct PRKeyboardMonitor: NSViewRepresentable {
  /// A workspace embedded in a repository tab shares its window with the repository list and other tables;
  /// those keep their own keys, and only the PR list (or the board) takes PR shortcuts.
  var embedded = false
  /// Accessibility identifier of the list that takes the keys.
  var listIdentifier = "prList"
  let action: (String) -> Bool
  func makeNSView(context: Context) -> KeyboardView {
    KeyboardView(embedded: embedded, listIdentifier: listIdentifier, action: action)
  }
  func updateNSView(_ view: KeyboardView, context: Context) {
    view.embedded = embedded
    view.listIdentifier = listIdentifier
    view.action = action
  }
  @MainActor final class KeyboardView: NSView {
    var embedded: Bool
    var listIdentifier: String
    var action: (String) -> Bool
    fileprivate var monitor: Any?
    init(embedded: Bool, listIdentifier: String, action: @escaping (String) -> Bool) {
      self.embedded = embedded
      self.listIdentifier = listIdentifier
      self.action = action
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    /// Embedded, the view spans the workspace to locate it; clicks always pass through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }
        if event.type == .leftMouseDown {
          self.claimFocus(for: event, in: window)
          return event
        }
        guard window.isKeyWindow else { return event }
        var modifiers: PRKeyboardScope.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard
          let key = PRKeyboardScope.key(
            characters: event.charactersIgnoringModifiers, modifiers: modifiers,
            focus: self.focus(of: window.firstResponder, in: window), embedded: self.embedded)
        else { return event }
        if self.action(key) { return nil }
        if key == "?" {
          KeyboardShortcutsHelp.show()
          return nil
        }
        return event
      }
    }
    /// What has keyboard focus, relative to this workspace.
    private func focus(of responder: NSResponder?, in window: NSWindow) -> PRKeyboardScope.Focus {
      guard let responder, responder !== window else { return .container }
      if let text = responder as? NSTextView, text.isEditable { return .editableText }
      if let field = responder as? NSTextField, field.isEditable { return .editableText }
      // Date pickers take typed digits and AM/PM letters; repository/file trees use type-to-select.
      // The PR table and sidebar are outline views too, so only the app's own trees are exempt.
      if responder is NSDatePicker || responder is MenuOutlineView { return .exempt }
      guard let view = responder as? NSView else { return .container }
      if let table = view as? NSTableView { return isPRList(table) ? .prList : .otherList }
      // A view that encloses the whole workspace (such as the window's hosting view) means nothing specific
      // is focused; a click on the board leaves focus there.
      if isDescendant(of: view) { return .container }
      return contains(view) ? .workspace : .elsewhere
    }
    /// The PR list is the table identified "prList" (when SwiftUI exposes it to AppKit) or, since SwiftUI tables
    /// usually report no identifier there, the table inside this workspace. The repository list beside it and the
    /// sidebar (a source list in another split-view column) are not.
    private func isPRList(_ table: NSTableView) -> Bool {
      if table.accessibilityIdentifier() == listIdentifier { return true }
      if !embedded && table.style == .sourceList { return false }
      return contains(table)
    }
    /// Whether `view` lies in this workspace: embedded, inside this view's bounds (it spans the workspace);
    /// otherwise inside the split-view column that holds the workspace, or anywhere when there is no split view.
    private func contains(_ view: NSView) -> Bool {
      if embedded {
        let scroll: NSView = (view as? NSTableView)?.enclosingScrollView ?? view
        let frame = scroll.convert(scroll.bounds, to: self)
        return !bounds.isEmpty && bounds.contains(NSPoint(x: frame.midX, y: frame.midY))
      }
      guard let column = workspaceColumn() else { return true }
      return view.isDescendant(of: column)
    }
    /// The arranged subview of the nearest enclosing split view (the detail column of the main window).
    private func workspaceColumn() -> NSView? {
      var child: NSView = self
      while let parent = child.superview {
        if parent is NSSplitView { return child }
        child = parent
      }
      return nil
    }
    /// A click in the workspace moves keyboard focus out of the sidebar (or another pane), as clicking content
    /// does in Finder or Mail. Board cards don't take first responder themselves, so without this the sidebar
    /// would keep focus and its type-to-select would swallow j/k after clicking a card. Controls under the click
    /// that accept focus (the filter field, the PR list) still take it when AppKit handles the click.
    private func claimFocus(for event: NSEvent, in window: NSWindow) {
      guard let responder = window.firstResponder as? NSView, !isDescendant(of: responder) else { return }
      if let region: NSView = embedded ? self : workspaceColumn() {
        guard region.bounds.contains(region.convert(event.locationInWindow, from: nil)), !contains(responder) else { return }
      } else {
        // No split view to tell the panes apart: only the sidebar (a source list) gives up focus, and only to a
        // click outside it.
        guard let table = responder as? NSTableView, table.style == .sourceList else { return }
        let area: NSView = table.enclosingScrollView ?? table
        guard !area.bounds.contains(area.convert(event.locationInWindow, from: nil)) else { return }
      }
      // The field editor belongs to the text field being edited; judge that field instead.
      if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView, contains(field) { return }
      window.makeFirstResponder(nil)
    }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) {
      if let monitor = view.monitor {
        NSEvent.removeMonitor(monitor)
        view.monitor = nil
      }
    }
  }
  static func dismantleNSView(_ view: KeyboardView, coordinator: ()) {
    if let monitor = view.monitor {
      NSEvent.removeMonitor(monitor)
      view.monitor = nil
    }
  }
}
