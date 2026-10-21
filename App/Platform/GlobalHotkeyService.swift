import AppKit
import Carbon
import MergeProCore
import SwiftUI

/// Registers only two exact configured chords. No event tap, general key capture or permission prompt.
@MainActor
final class GlobalHotkeyService {
  private var handler: EventHandlerRef?
  private var references: [EventHotKeyRef] = []
  private var actions: [UInt32: () -> Void] = [:]
  private let signature: OSType = 0x4D50_524F
  /// Why this app registers no shortcuts (the fixture app); nil registers them.
  private let unavailableReason: String?
  private static let keyCodes: [String: UInt32] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
  ]
  init(unavailableReason: String? = nil) { self.unavailableReason = unavailableReason }
  func configure(
    _ settings: PRGlobalShortcuts, palette: @escaping () -> Void, menuBar: @escaping () -> Void
  ) -> String {
    unregister()
    if let unavailableReason { return unavailableReason }
    actions = [1: palette, 2: menuBar]
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let result = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, pointer in
        guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard result == noErr else { return result }
        let id = identifier.id
        let owner = Unmanaged<GlobalHotkeyService>.fromOpaque(pointer).takeUnretainedValue()
        MainActor.assumeIsolated { owner.actions[id]?() }
        return noErr
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard result == noErr else { return "Global shortcut handler unavailable (\(result))." }
    var status: [String] = []
    for (id, name, chord) in [
      (UInt32(1), "Palette", settings.palette), (UInt32(2), "Menu bar", settings.menuBar),
    ] {
      guard chord.enabled else {
        status.append("\(name) disabled")
        continue
      }
      guard let code = Self.keyCodes[chord.key.lowercased()],
        chord.command || chord.control || chord.option
      else {
        status.append("\(name): choose a letter/digit and modifier")
        continue
      }
      // Preserve VoiceOver's Ctrl Option K keyboard help chord.
      if chord.key.lowercased() == "k", chord.control, chord.option, !chord.command {
        status.append("Palette chord conflicts with VoiceOver keyboard help")
        continue
      }
      let modifiers =
        (chord.command ? UInt32(cmdKey) : 0) | (chord.control ? UInt32(controlKey) : 0)
        | (chord.option ? UInt32(optionKey) : 0) | (chord.shift ? UInt32(shiftKey) : 0)
      var reference: EventHotKeyRef?
      let result = RegisterEventHotKey(
        code, modifiers, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(),
        0, &reference)
      if result == noErr, let reference {
        references.append(reference)
        status.append("\(name) registered")
      } else {
        status.append("\(name) conflict/unavailable (\(result))")
      }
    }
    return status.joined(separator: " · ")
  }
  func reconfigure(_ settings: PRGlobalShortcuts) -> String {
    let palette = actions[1] ?? {}
    let menu = actions[2] ?? {}
    return configure(settings, palette: palette, menuBar: menu)
  }
  private func unregister() {
    references.forEach { UnregisterEventHotKey($0) }
    references.removeAll()
    if let handler {
      RemoveEventHandler(handler)
      self.handler = nil
    }
    actions.removeAll()
  }
}

struct GlobalHotkeySettings: View {
  @Bindable var model: SetupModel
  @State private var shortcuts = PRGlobalShortcuts()
  /// One Settings form row per shortcut, with the registration status in the section footer.
  var body: some View {
    shortcut("Command palette", value: $shortcuts.palette)
    shortcut("Menu bar", value: $shortcuts.menuBar)
    HStack {
      Spacer()
      Button("Save global shortcuts") {
        model.prs.state.globalShortcuts = shortcuts
        model.globalHotkeyStatus = model.globalHotkeys.reconfigure(shortcuts)
      }
    }.onAppear { shortcuts = model.prs.state.globalShortcuts ?? PRGlobalShortcuts() }
  }
  private func shortcut(_ title: String, value: Binding<PRGlobalShortcut>) -> some View {
    LabeledContent(title) {
      HStack(spacing: 6) {
        // Modifier order matches macOS menus: ⌃⌥⇧⌘ then the key.
        HStack(spacing: 4) {
          modifier("⌃", name: "Control", isOn: value.control)
          modifier("⌥", name: "Option", isOn: value.option)
          modifier("⇧", name: "Shift", isOn: value.shift)
          modifier("⌘", name: "Command", isOn: value.command)
          TextField("Key", text: value.key).labelsHidden().textFieldStyle(.roundedBorder)
            .font(.body.monospaced()).multilineTextAlignment(.center).frame(width: 36)
            .accessibilityLabel("\(title) key")
        }.disabled(!value.enabled.wrappedValue)
        Toggle("\(title) enabled", isOn: value.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small).padding(.leading, 8)
      }
    }
  }
  private func modifier(_ symbol: String, name: String, isOn: Binding<Bool>) -> some View {
    ModifierKeyToggle(symbol: symbol, name: name, isOn: isOn)
  }
}

/// A modifier key that reads clearly as on (filled accent) or off (outlined), unlike `.button` toggles.
private struct ModifierKeyToggle: View {
  let symbol: String
  let name: String
  @Binding var isOn: Bool
  @Environment(\.isEnabled) private var isEnabled
  var body: some View {
    Button { isOn.toggle() } label: {
      Text(symbol).font(.body.weight(.semibold))
        .frame(width: 26, height: 22)
        .foregroundStyle(isOn ? Color.white : Color.secondary)
        .background(isOn ? DesignTokens.cobalt : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.5)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).opacity(isEnabled ? 1 : 0.4)
    .help(name).accessibilityLabel(name).accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
