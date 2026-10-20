import Foundation

public struct RepositorySizeBaseline:Sendable,Equatable {
    public let sampleCount:Int
    public let usualSize:Int?
    public static let minimumSamples=5
    public static let maximumSamples=50
    public static let windowDays=90
    public static func calculate(_ rows:[PullRequest],for current:PullRequest,now:Date = Date()) -> Self {
        let cutoff=now.addingTimeInterval(-Double(windowDays)*86400)
        let samples=rows.filter { pr in
            guard pr.key.repository == current.key.repository,pr.key != current.key,pr.state == .merged,let m=pr.metadata,!m.partial,
                  let merged=m.mergedAt,merged >= cutoff,merged <= now,let added=m.additions,let removed=m.deletions,
                  added >= 0,removed >= 0,added <= 100_000_000,removed <= 100_000_000 else { return false }
            return true
        }.sorted { ($0.metadata!.mergedAt!,$0.key.objectID) > ($1.metadata!.mergedAt!,$1.key.objectID) }.prefix(maximumSamples)
        let sizes=samples.compactMap { $0.metadata?.size }.sorted()
        guard sizes.count >= minimumSamples else { return .init(sampleCount:sizes.count,usualSize:nil) }
        let middle=sizes.count/2
        let median=sizes.count.isMultiple(of:2) ? (sizes[middle-1]+sizes[middle])/2 : sizes[middle]
        return .init(sampleCount:sizes.count,usualSize:median)
    }
    public var explanation:String {
        if let usualSize { return "Repository baseline: median \(usualSize) changed lines from \(sampleCount) cached merged PRs in the last \(Self.windowDays) days (up to \(Self.maximumSamples))." }
        return "Insufficient repository history: \(sampleCount) valid merged PRs in the last \(Self.windowDays) days; at least \(Self.minimumSamples) are required. Unknown sizes are excluded."
    }
}
