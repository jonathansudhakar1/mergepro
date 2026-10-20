import MergeProCore
import SwiftUI

/// One status as glyph + text (✓ passing, ✗ failing, ◷ pending, ? unknown) for checks, review, mergeability and
/// merge verification. Colour stays on the glyph; the text uses the primary/secondary style for contrast.
struct PRStatusLabel: View {
  let value: PRStatusValue
  var textStyle: HierarchicalShapeStyle = .secondary
  static func symbol(_ tone: PRStatusTone) -> String {
    switch tone {
    case .passing: "checkmark.circle.fill"
    case .failing: "xmark.circle.fill"
    case .pending: "clock"
    case .unknown: "questionmark.circle"
    }
  }
  static func color(_ tone: PRStatusTone) -> Color {
    switch tone {
    case .passing: .green
    case .failing: .red
    case .pending: .orange
    case .unknown: .secondary
    }
  }
  var body: some View {
    Label {
      Text(value.text).foregroundStyle(textStyle).lineLimit(1)
    } icon: {
      Image(systemName: Self.symbol(value.tone)).foregroundStyle(Self.color(value.tone)).accessibilityHidden(true)
    }
    .labelStyle(PRStatusLabelStyle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(value.text)
  }
}

/// Re-renders `content` with the current time whenever the age of a merge-evidence read can change its wording
/// ("just now" becomes "1 min. ago", and so on; `PRStatusSummary.nextAgeChange`), so the text and the VoiceOver label
/// read from it stay true. Without a read time it renders once.
struct PRVerificationAge<Content: View>: View {
  let verifiedAt: Date?
  @ViewBuilder let content: (Date) -> Content
  var body: some View {
    if let verifiedAt {
      TimelineView(VerificationAgeSchedule(verifiedAt: verifiedAt)) { context in
        // The schedule's date is the mark being shown; never earlier than the clock.
        content(max(context.date, Date()))
      }
    } else {
      content(Date())
    }
  }
}

/// Now, then each moment the age wording of a read at `verifiedAt` can change.
private struct VerificationAgeSchedule: TimelineSchedule {
  let verifiedAt: Date
  func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
    var next: Date? = startDate
    let verifiedAt = verifiedAt
    return AnyIterator {
      guard let current = next else { return nil }
      next = PRStatusSummary.nextAgeChange(after: current, verifiedAt: verifiedAt)
      return current
    }
  }
}

/// The table's merge column (`PRStatusSummary.mergeColumn`) from the eligibility cards and menus use, with its age
/// rendered from the read time.
struct PRMergeColumnLabel: View {
  let eligibility: MergeEligibility
  let mergeable: String?
  var body: some View {
    PRVerificationAge(verifiedAt: eligibility.verifiedAt) { now in
      PRStatusLabel(value: PRStatusSummary.mergeColumn(eligibility, mergeable: mergeable, now: now))
    }
  }
}

private struct PRStatusLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      configuration.icon.imageScale(.small)
      configuration.title
    }
  }
}

/// "Checks failing" on cards and list rows; activating it opens the failing checks.
struct PRChecksFailingBadge: View {
  let number: Int
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Label {
        Text("Checks failing").foregroundStyle(.primary)
      } icon: {
        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
      }
      .labelStyle(PRStatusLabelStyle())
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(Color.red.opacity(0.10), in: Capsule())
    }
    .buttonStyle(.plain)
    .help("Open the failing checks")
    .accessibilityLabel("Checks failing")
    .accessibilityHint("Opens the pull request's checks")
    .accessibilityIdentifier("checksFailing-\(number)")
  }
}
