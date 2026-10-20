import AppKit
import SwiftUI
import MergeProCore

extension Color {
    /// A GitHub label color (`rrggbb`, optional `#`); nil when it is not a valid six-digit hex.
    init?(labelHex: String?) {
        guard let hex = labelHex.flatMap(RepositoryLabel.normalizedColor), let value = Int(hex, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

/// GitHub's label swatches, so new labels look at home next to existing ones.
enum LabelPalette {
    static let swatches = ["b60205", "d93f0b", "fbca04", "0e8a16", "006b75", "1d76db", "0052cc", "5319e7",
                           "e99695", "f9d0c4", "fef2c0", "c2e0c6", "bfdadc", "c5def5", "bfd4f2", "d4c5f9"]
    static func random(excluding current: String? = nil) -> String {
        swatches.filter { $0 != current }.randomElement() ?? "ededed"
    }
    /// Lowercase `rrggbb` for a picked color, or nil when it has no sRGB representation.
    static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

/// A GitHub-style label: a capsule filled with the label color and contrast-picked text.
/// A missing or invalid color is shown as a neutral gray rather than guessed.
struct LabelChip: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// Grows with the text size instead of clipping it.
    @ScaledMetric(relativeTo: .caption2) private var minimumHeight: CGFloat = 18
    let name: String
    let hex: String?

    init(name: String, hex: String?) { self.name = name; self.hex = hex }

    private var normalized: String? { hex.flatMap(RepositoryLabel.normalizedColor) }

    private var fill: Color { Color(labelHex: normalized) ?? Color(nsColor: .quaternaryLabelColor).opacity(colorScheme == .dark ? 1 : 0.6) }

    /// Chosen against the fill and the text colours drawn here: at least 4.5:1, or the strongest of white and
    /// black when Increase Contrast asks for 7:1.
    private var chipText: RepositoryLabel.ChipText? {
        normalized.flatMap { RepositoryLabel.chipText(hex: $0, minimumContrast: contrast == .increased ? 7 : 4.5) }
    }

    private var textColor: Color {
        guard let chipText else { return .primary }
        return Color(.sRGB, white: chipText.gray)
    }

    /// Very light fills vanish on light backgrounds and very dark fills on dark ones; outline them.
    /// Increase Contrast outlines every chip.
    private var outline: Color {
        if contrast == .increased { return Color.primary.opacity(0.6) }
        guard normalized != nil else { return Color(nsColor: .separatorColor) }
        let dark = chipText?.isDark ?? false
        return colorScheme == .dark ? (dark ? .clear : Color.white.opacity(0.18)) : (dark ? Color.black.opacity(0.12) : .clear)
    }

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(textColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .frame(minHeight: minimumHeight)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(outline, lineWidth: 1).allowsHitTesting(false))
            .fixedSize(horizontal: false, vertical: true)
            .help(name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Label \(name)")
    }
}

/// Label chips in reading order, collapsing everything past `limit` into "+N".
struct LabelChipRow: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .caption2) private var minimumHeight: CGFloat = 18
    let labels: [String]
    let colors: [String: String]?
    let limit: Int

    init(labels: [String], colors: [String: String]?, limit: Int = 4) { self.labels = labels; self.colors = colors; self.limit = limit }

    private var shown: [String] { Array(labels.prefix(max(limit, 0))) }
    private var overflow: [String] { Array(labels.dropFirst(max(limit, 0))) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
                LabelChip(name: name, hex: Self.color(for: name, in: colors)).layoutPriority(1)
            }
            if !overflow.isEmpty {
                Text("+\(overflow.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(contrast == .increased ? .primary : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(minHeight: minimumHeight)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                    .fixedSize()
                    .help(overflow.joined(separator: ", "))
                    .accessibilityLabel("\(overflow.count) more labels: \(overflow.joined(separator: ", "))")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Inventory colors are keyed by label name; GitHub names are unique case-insensitively.
    static func color(for name: String, in colors: [String: String]?) -> String? {
        guard let colors else { return nil }
        if let exact = colors[name] { return exact }
        let key = name.lowercased()
        return colors.first { $0.key.lowercased() == key }?.value
    }
}
