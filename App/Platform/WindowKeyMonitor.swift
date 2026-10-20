import AppKit
import SwiftUI

/// Key-down events of this view's own window (a sheet or popover), before the focused control sees them.
/// `handler` returns true to consume the event. Text being composed with an input method is never intercepted,
/// so Return and the arrows keep committing and choosing candidates.
struct WindowKeyMonitor: NSViewRepresentable {
  let handler: (NSEvent) -> Bool
  func makeNSView(context: Context) -> MonitorView { MonitorView(handler: handler) }
  func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler }
  static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

  @MainActor final class MonitorView: NSView {
    var handler: (NSEvent) -> Bool
    private var monitor: Any?
    init(handler: @escaping (NSEvent) -> Bool) {
      self.handler = handler
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, let window = self.window, window.isKeyWindow, event.window === window else { return event }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        return self.handler(event) ? nil : event
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

extension NSEvent {
  /// Command, Option, Control and Shift; arrow and function-key flags are not modifiers here.
  var editingModifiers: NSEvent.ModifierFlags { modifierFlags.intersection([.command, .option, .control, .shift]) }
}
