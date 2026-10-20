import Foundation

public struct PRStack:Codable,Sendable,Equatable,Identifiable {
    public enum Kind:String,Codable,Sendable { case native,inferred }
    public let id:String
    public let kind:Kind
    public let number:Int?
    public let layers:[PullRequest]
    public let warnings:[String]
    /// UI expansion belongs to one account and repository even when GitHub node IDs repeat
    /// in two connected accounts. The provider's `id` remains unchanged for write admission.
    public var presentationID:String {
        guard let key=layers.first?.key else { return id }
        return [key.host,key.accountID,key.repositoryID,id].map { Data($0.utf8).base64EncodedString() }.joined(separator:"|")
    }
    /// More than one parent or child branch: the inferred order is a guess, not a chain.
    public static let ambiguousChainWarning="Branch chain is ambiguous."
    /// An inferred stack whose branch topology is ambiguous (e.g. many main → deploy PRs). The board keeps each of
    /// its PRs as a separate card; the stack and its warning stay available for card annotations and the sidebar.
    public var isAmbiguousChain:Bool { kind == .inferred && warnings.contains(Self.ambiguousChainWarning) }
    public func observed(in rows:[PullRequest]) -> Self { observed { key in rows.first { $0.key == key } } }
    /// Indexed form of `observed(in:)` for large row sets (first row per key, as the array form).
    public func observed(in index:[ProviderKey:PullRequest]) -> Self { observed { index[$0] } }
    private func observed(_ lookup:(ProviderKey) -> PullRequest?) -> Self {
        var warnings=self.warnings
        let current=layers.map { old in lookup(old.key) ?? old }
        for (old,new) in zip(layers,current) where old.headRevision != new.headRevision { warnings.append("Layer #\(new.metadata?.number ?? 0) changed; refresh stack topology and review upper layers.") }
        if current.contains(where:{ $0.state == .closed }),!warnings.contains("Stack contains a closed, unmerged layer.") { warnings.append("Stack contains a closed, unmerged layer.") }
        if kind == .inferred,current.count>1 {
            for i in 1..<current.count where current[i].metadata?.baseBranch != current[i-1].metadata?.headBranch { warnings.append("A layer's base no longer matches its parent.") }
        }
        return .init(id:id,kind:kind,number:number,layers:current,warnings:warnings)
    }
    public var representative:PullRequest? { layers.first { $0.state != .merged } ?? layers.last }
    public func affected(upTo key:ProviderKey,action:MergeAction = .direct) throws -> [PullRequest] {
        guard warnings.isEmpty,let index=layers.firstIndex(where:{ $0.key == key }) else { throw PRWriteFailure.unavailable }
        if action == .removeQueue { return layers[index...].filter { $0.state == .open } }
        return layers[...index].filter { $0.state == .open }
    }
    /// State transitions are expected after merge; membership, order and revisions are not.
    public var revisionSignature:String { layers.map { "\($0.key.objectID):\($0.headRevision.rawValue):\($0.metadata?.baseBranch ?? "")" }.joined(separator:"|") }
    public var signature:String { layers.map { "\($0.key.objectID):\($0.headRevision.rawValue):\($0.state.rawValue):\($0.metadata?.baseBranch ?? "")" }.joined(separator:"|") }
    public var guardExplanation:String { kind == .native ? "GitHub guards the selected layer's head. Every listed layer is rechecked before sending, but GitHub does not provide a multi-head or topology guard." : "Separate bottom-up operations stop on the first incomplete or failed result. Inferred chains do not imply server restacking." }
}
/// Row-derived stacks: native stacks (freshest merge evidence first, observed against current rows), then
/// inferred chains over the remaining rows. Built once per row change; filter and view changes reuse it.
public struct PRStackProjection:Sendable {
    private struct NativeIdentity:Hashable { let id:String;let repository:RepositoryKey? }
    public let stacks:[PRStack]
    /// Card and detail lookups resolve the last stack listing a layer.
    private let owner:[ProviderKey:Int]
    /// Collapse resolves the first stack listing a layer (`StackGraph.visibleCards`).
    let firstOwner:[ProviderKey:Int]
    public init(rows:[PullRequest] = []) {
        var native:[PRStack]=[],identities:Set<NativeIdentity>=[]
        let sources=rows.filter { $0.metadata?.nativeStack != nil }.sorted { ($0.metadata?.mergeEvidence?.fetchedAt ?? .distantPast) > ($1.metadata?.mergeEvidence?.fetchedAt ?? .distantPast) }
        if !sources.isEmpty {
            let index=Dictionary(rows.map { ($0.key,$0) },uniquingKeysWith:{ first,_ in first })
            for row in sources { if let stack=row.metadata?.nativeStack,identities.insert(.init(id:stack.id,repository:stack.layers.first?.key.repository)).inserted { native.append(stack.observed(in:index)) } }
        }
        let keys=Set(native.flatMap { $0.layers.map(\.key) })
        stacks=native+StackGraph.inferred(keys.isEmpty ? rows : rows.filter { !keys.contains($0.key) })
        var owner:[ProviderKey:Int]=[:],first:[ProviderKey:Int]=[:]
        for (i,stack) in stacks.enumerated() { for layer in stack.layers { owner[layer.key]=i;if first[layer.key] == nil { first[layer.key]=i } } }
        self.owner=owner;firstOwner=first
    }
    public func stack(for key:ProviderKey) -> PRStack? { owner[key].map { stacks[$0] } }
}
public enum StackGraph {
    /// Collapsed cards retain visible layer identity; called once before lane assignment. Ambiguous inferred
    /// stacks never collapse: each of their PRs stays its own card (see `PRStack.isAmbiguousChain`).
    public static func visibleCards(_ visible:[PullRequest], stacks:[PRStack], expanded:Set<String> = [], separate:Bool = false) -> [PullRequest] {
        guard !separate else { return visible }
        var first:[ProviderKey:Int]=[:]
        for (i,stack) in stacks.enumerated() { for layer in stack.layers where first[layer.key] == nil { first[layer.key]=i } }
        return collapse(visible,stacks:stacks,owner:first,expanded:expanded)
    }
    /// Same as `visibleCards(_:stacks:)` with the projection's precomputed membership.
    public static func visibleCards(_ visible:[PullRequest], projection:PRStackProjection, expanded:Set<String> = [], separate:Bool = false) -> [PullRequest] {
        guard !separate else { return visible }
        return collapse(visible,stacks:projection.stacks,owner:projection.firstOwner,expanded:expanded)
    }
    private static func collapse(_ visible:[PullRequest],stacks:[PRStack],owner:[ProviderKey:Int],expanded:Set<String>) -> [PullRequest] {
        let visibleKeys=Set(visible.map(\.key))
        var representatives:[Int:PullRequest?]=[:],result:[PullRequest]=[],seen:Set<ProviderKey>=[]
        for pr in visible {
            if let index=owner[pr.key],!expanded.contains(stacks[index].presentationID),!expanded.contains(stacks[index].id),!stacks[index].isAmbiguousChain {
                // Each stack's visible representative is resolved once, not once per visible layer.
                let representative:PullRequest?
                if let cached=representatives[index] { representative=cached } else {
                    let layers=stacks[index].layers
                    representative=layers.first(where:{ visibleKeys.contains($0.key) && $0.state != .merged }) ?? layers.last(where:{ visibleKeys.contains($0.key) })
                    representatives[index]=representative
                }
                if let representative { if seen.insert(representative.key).inserted { result.append(representative) };continue }
            }
            if seen.insert(pr.key).inserted { result.append(pr) }
        }
        return result
    }
    public struct Entry:Sendable { public let position:Int;public let pr:PullRequest;public init(position:Int,pr:PullRequest) { self.position=position;self.pr=pr } }
    public static func native(id:String,number:Int,size:Int,entries:[Entry],complete:Bool,linear:Bool?) -> PRStack {
        let sorted=entries.sorted { $0.position < $1.position };var warnings:[String]=[]
        if !complete || size != entries.count || sorted.map(\.position) != Array(1...max(1,size)) || Set(entries.map { $0.pr.key }).count != size { warnings.append("Native stack membership or positions are incomplete or ambiguous.") }
        if Set(entries.map { $0.pr.key.repository }).count != 1 { warnings.append("Native stack repository identity is inconsistent.") }
        if linear != true { warnings.append("Fully linear native stack history is unverified.") }
        if entries.contains(where:{ $0.pr.state == .closed }) { warnings.append("Stack contains a closed, unmerged layer.") }
        return .init(id:id,kind:.native,number:number,layers:sorted.map(\.pr),warnings:warnings)
    }
    public static func inferred(_ rows:[PullRequest]) -> [PRStack] {
        var result:[PRStack]=[]
        for (_,prs) in Dictionary(grouping:rows,by:{ $0.key.repository }) { inferChains(prs,into:&result) }
        return result.sorted { $0.id < $1.id }
    }
    /// Near-linear in the repository's history. A PR's parents are the other same-repository PRs whose head is its
    /// base, but they are counted per branch instead of materialized per PR: a long-lived branch with k PRs from it
    /// (e.g. main → deploy) and n PRs into it would otherwise create n×k edges and quadratic topological rounds.
    private static func inferChains(_ prs:[PullRequest],into result:inout [PRStack]) {
        var unique:Set<ProviderKey>=[]
        let usable=prs.filter { !($0.metadata?.headBranch ?? "").isEmpty && !($0.metadata?.baseBranch ?? "").isEmpty && unique.insert($0.key).inserted }
        let count=usable.count
        guard count>1 else { return }
        var branchIDs:[String:Int]=[:]
        func intern(_ name:String) -> Int { if let id=branchIDs[name] { return id };let id=branchIDs.count;branchIDs[name]=id;return id }
        let head=usable.map { intern($0.metadata!.headBranch) },base=usable.map { intern($0.metadata!.baseBranch) }
        // A known fork head branch is not a branch of this repository.
        let parentable=usable.map { pr in pr.metadata?.headRepositoryID.map { $0 == pr.key.repositoryID } ?? true }
        var parentsOf=[[Int]](repeating:[],count:branchIDs.count),childrenOf=parentsOf
        for i in 0..<count { childrenOf[base[i]].append(i);if parentable[i] { parentsOf[head[i]].append(i) } }
        // A PR is never its own parent.
        func own(_ i:Int) -> Int { parentable[i] && head[i] == base[i] ? 1 : 0 }
        func parentCount(_ i:Int) -> Int { parentsOf[base[i]].count-own(i) }
        func childCount(_ i:Int) -> Int { parentable[i] ? childrenOf[head[i]].count-own(i) : 0 }
        var root=Array(0..<count),linked=[Bool](repeating:false,count:count)
        func find(_ i:Int) -> Int { var i=i;while root[i] != i { root[i]=root[root[i]];i=root[i] };return i }
        // Every child of a branch is adjacent to every parent heading it but itself, so a branch with any such
        // child joins all of its children with parents and all of its parents into one component.
        for branch in parentsOf.indices where !parentsOf[branch].isEmpty {
            let edged=childrenOf[branch].filter { parentCount($0)>0 }
            guard let anchor=edged.first else { continue }
            for i in edged+parentsOf[branch] { linked[i]=true;let a=find(anchor),b=find(i);if a != b { root[max(a,b)]=min(a,b) } }
        }
        var components:[Int:[Int]]=[:],order:[Int]=[]
        for i in 0..<count where linked[i] { let r=find(i);if components[r] == nil { order.append(r) };components[r,default:[]].append(i) }
        guard !order.isEmpty else { return }
        var rank=[Int](repeating:0,count:count)
        for (position,i) in (0..<count).sorted(by:{ usable[$0].key.objectID < usable[$1].key.objectID }).enumerated() { rank[i]=position }
        var remainingParents=parentsOf.map(\.count),removed=[Bool](repeating:false,count:count),touchedRound=[Int](repeating:-1,count:parentsOf.count),round=0
        for r in order {
            let members=components[r]!
            var warnings:[String]=[],ordered:[Int]=[],candidates=members,left=members.count
            if members.contains(where:{ parentCount($0)>1 || childCount($0)>1 }) { warnings.append(PRStack.ambiguousChainWarning) }
            // Bottom-up rounds: every remaining PR without a remaining parent, in objectID order. Only children of
            // branches whose remaining parent count fell to one or zero can become ready in the next round.
            while left>0 {
                let ready=candidates.filter { !removed[$0] && remainingParents[base[$0]]-own($0) == 0 }.sorted { rank[$0]<rank[$1] }
                guard !ready.isEmpty else { warnings.append("Branch chain contains a cycle.");ordered += members.filter { !removed[$0] }.sorted { rank[$0]<rank[$1] };break }
                ordered += ready;left -= ready.count;round += 1
                for i in ready { removed[i]=true }
                var touched:[Int]=[]
                for i in ready where parentable[i] { let b=head[i];remainingParents[b] -= 1;if remainingParents[b] <= 1,touchedRound[b] != round { touchedRound[b]=round;touched.append(b) } }
                candidates=touched.flatMap { childrenOf[$0] }
            }
            let layers=ordered.map { usable[$0] }
            if layers.contains(where:{ $0.metadata?.headRepositoryID != $0.key.repositoryID }) { warnings.append("Same-repository head-branch identity is unverified or belongs to a fork.") }
            if layers.contains(where:{ $0.state == .closed }) { warnings.append("Stack contains a closed, unmerged layer.") }
            result.append(.init(id:"inferred:"+(layers.first?.key.objectID ?? ""),kind:.inferred,number:nil,layers:layers,warnings:warnings))
        }
    }
}
