import SwiftUI

/// Shared hierarchy for workspaces; controls remain separate native accessibility elements.
struct WorkspaceSectionHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: Color
    let actions: Actions

    init(title: String, subtitle: String, symbol: String, tint: Color = DesignTokens.cobalt,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { heading; Spacer(minLength: 12); actions }
            VStack(alignment: .leading, spacing: 14) {
                heading
                HStack { actions; Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var heading: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 27, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .layoutPriority(1)
        }
    }
}

struct WorkspaceStatusBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true) }
            // Small tinted text on a tinted fill falls below 4.5:1 (cobalt on white is about 4.3:1), so the text is
            // the tint mixed halfway toward the primary label color, or primary itself with Increase Contrast.
            Text(text).foregroundStyle(contrast == .increased ? Color.primary : tint.mix(with: .primary, by: 0.5))
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 1).allowsHitTesting(false))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct WorkspaceNotice: View {
    enum Severity {
        case info, success, warning, error
        /// Spoken before the message, since the icon and tint are hidden from VoiceOver.
        var spokenPrefix: String? {
            switch self {
            case .info: nil
            case .success: "Success"
            case .warning: "Warning"
            case .error: "Error"
            }
        }
    }
    let message: String
    var symbol = "info.circle"
    var tint: Color = .secondary
    /// Inferred from the symbol and tint when nil.
    var severity: Severity? = nil

    private var resolvedSeverity: Severity {
        if let severity { return severity }
        if tint == .red || symbol.hasPrefix("xmark") { return .error }
        if tint == .orange || symbol.hasPrefix("exclamationmark") { return .warning }
        if tint == .green || symbol.hasPrefix("checkmark") { return .success }
        return .info
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint).padding(.top, 1).accessibilityHidden(true)
            Text(message).font(.callout).textSelection(.enabled)
                .accessibilityLabel(resolvedSeverity.spokenPrefix.map { "\($0): \(message)" } ?? message)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
    }
}
