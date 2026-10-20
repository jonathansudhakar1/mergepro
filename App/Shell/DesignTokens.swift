import SwiftUI
import MergeProCore

enum DesignTokens {
    static let compactSpacing: CGFloat = 8
    static let standardSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
    static let sidebarMinimumWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 248
    static let sidebarMaximumWidth: CGFloat = 320
    static let initialWindowSize = CGSize(width: 1280, height: 800)
    static let minimumWindowSize = CGSize(width: 800, height: 600)

    static let cobalt = Color(red: 0.30, green: 0.43, blue: 0.96)
    static let violet = Color(red: 0.62, green: 0.39, blue: 0.93)
    static let cardRadius: CGFloat = 16

    static func columnColor(_ column: PRColumn) -> Color {
        switch column {
        case .draft: .secondary
        case .open: cobalt
        case .approved: .green
        case .merged: violet
        }
    }

    static func columnIcon(_ column: PRColumn) -> String {
        switch column {
        case .draft: "pencil.circle"
        case .open: "arrow.triangle.pull"
        case .approved: "checkmark.circle"
        case .merged: "arrow.triangle.merge"
        }
    }

    static let bodyFont: Font = .body
    static let captionFont: Font = .caption
    static let codeFont: Font = .system(.body, design: .monospaced)
}

/// A static wash behind the workspace, with an opaque accessibility fallback.
struct WorkspaceCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency && contrast != .increased {
                LinearGradient(
                    colors: [DesignTokens.cobalt.opacity(colorScheme == .dark ? 0.22 : 0.12),
                             DesignTokens.violet.opacity(colorScheme == .dark ? 0.12 : 0.06),
                             Color.clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(
                    colors: [DesignTokens.violet.opacity(colorScheme == .dark ? 0.14 : 0.08), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 700)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkspaceGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1).allowsHitTesting(false))
        } else {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

private struct WorkspacePanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: radius).fill(.regularMaterial)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1 : 0.35), lineWidth: 1).allowsHitTesting(false))
    }
}

extension View {
    func workspaceGlass(radius: CGFloat = 16) -> some View { modifier(WorkspaceGlass(radius: radius)) }
    func workspacePanel(radius: CGFloat = 16) -> some View { modifier(WorkspacePanel(radius: radius)) }
}
