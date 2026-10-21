import AppKit
import MergeProCore
import SwiftUI

/// An owned window observer, rather than a global window lookup. Geometry is stored per
/// window role and display; sheet placement remains AppKit's responsibility. The first window of a
/// role restores its remembered frame; a further window while one is visible keeps only the remembered
/// size and cascades from the frontmost window of that role, so windows never open exactly on top of each other.
struct WindowFrameMemory: NSViewRepresentable {
    let role: String
    var defaultSize: CGSize? = nil
    var minimumSize = CGSize(width: 800, height: 540)
    var sheet = false

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.configuration = self
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) { view.configuration = self }

    @MainActor final class ObserverView: NSView {
        var configuration: WindowFrameMemory?
        private weak var observed: NSWindow?
        private var observations: [NSObjectProtocol] = []
        private var restoring = false
        private var saveTask: Task<Void, Never>?
        private struct Geometry: Codable { let frame: CGRect }
        /// Windows this observer type manages, by role; weak so closed windows drop out.
        private static let roles = NSMapTable<NSWindow, NSString>.weakToStrongObjects()

        isolated deinit {
            saveTask?.cancel()
            for observer in observations { NotificationCenter.default.removeObserver(observer) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observed else { return }
            saveTask?.cancel()
            for observer in observations { NotificationCenter.default.removeObserver(observer) }
            observations = []
            observed = window
            guard let window, let configuration else { return }
            if !configuration.sheet { Self.roles.setObject(configuration.role as NSString, forKey: window) }
            // SwiftUI finishes installing its hosting view before we restore content size.
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, self.observed === window else { return }
                self.restore(window, configuration: configuration)
            }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification, NSWindow.willCloseNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    let closing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if closing { self.save() }
                        else { self.scheduleSave() }
                    }
                })
            }
        }
        private func key(for screen: NSScreen, role: String) -> String {
            let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return "windowGeometry.\(role).\(display?.stringValue ?? "default")"
        }
        private func restore(_ window: NSWindow, configuration: WindowFrameMemory) {
            guard let screen = window.screen ?? NSScreen.main, !window.styleMask.contains(.fullScreen) else { return }
            restoring = true
            defer { restoring = false }
            let saved = (UserDefaults.standard.data(forKey: key(for: screen, role: configuration.role))
                ?? UserDefaults.standard.data(forKey:"windowGeometry.\(configuration.role).last"))
                .flatMap { try? JSONDecoder().decode(Geometry.self, from: $0) }
            if configuration.sheet { window.styleMask.insert(.resizable) }
            if configuration.sheet {
                let size = saved.map { window.contentRect(forFrameRect: $0.frame).size } ?? configuration.defaultSize
                if let size {
                    let maximum = CGSize(width: max(300, screen.visibleFrame.width - 40), height: max(300, screen.visibleFrame.height - 80))
                    window.setContentSize(CGSize(width: min(size.width, maximum.width), height: min(size.height, maximum.height)))
                }
            } else {
                let others = visibleFrames(role: configuration.role, excluding: window, on: screen)
                if !others.isEmpty {
                    let size = saved?.frame.size ?? window.frame.size
                    window.setFrame(WindowFrameRestoration.cascade(size: size, after: others, inside: screen.visibleFrame, minimum: configuration.minimumSize), display: true)
                } else if let saved {
                    window.setFrame(WindowFrameRestoration.fit(saved.frame, inside: screen.visibleFrame, minimum: configuration.minimumSize), display: true)
                }
            }
        }
        /// Visible windows of `role` on `screen`, back to front (frontmost last).
        private func visibleFrames(role: String, excluding window: NSWindow, on screen: NSScreen) -> [CGRect] {
            NSApp.orderedWindows.reversed().filter { other in
                other !== window && other.isVisible && !other.isMiniaturized && other.screen == screen && Self.roles.object(forKey: other) as String? == role
            }.map(\.frame)
        }
        private func scheduleSave() {
            guard !restoring else { return }
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                self?.save()
            }
        }
        private func save() {
            guard !restoring, let window = observed, let screen = window.screen, let configuration,
                  !window.styleMask.contains(.fullScreen), window.isVisible, !window.isMiniaturized,
                  window.frame.width > 0, window.frame.height > 0 else { return }
            if let data = try? JSONEncoder.stable.encode(Geometry(frame: window.frame)) {
                UserDefaults.standard.set(data, forKey: key(for: screen, role: configuration.role))
                UserDefaults.standard.set(data, forKey:"windowGeometry.\(configuration.role).last")
            }
        }
    }
}
