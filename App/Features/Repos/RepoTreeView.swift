import AppKit
import SwiftUI
import MergeProCore

struct RepoTreeView:View {
    @Bindable var model:ReposModel
    var body:some View {
        OutlineView(accessibilityID:"repoCatalogTree",roots:model.tree.visibleRoots.map(node),selection:model.tree.selection?.stableString,expanded:Set(model.tree.effectiveExpansion.map(\.stableString)),scrollAnchor:model.tree.scrollAnchor?.stableString,selected:{ value in
            let node=model.tree.allNodes.first { $0.id.stableString==value };model.tree.selection=node?.id
            if let repository=node?.repository { model.select(repository.key) };model.saveTree()
        },expansion:{ id,open in
            guard model.tree.search.isEmpty,let node=model.tree.allNodes.first(where:{ $0.id.stableString==id }) else { return }
            if open { model.tree.expanded.insert(node.id) } else { model.tree.expanded.remove(node.id) };model.saveTree()
        },scrolled:{ id in
            model.tree.scrollAnchor=model.tree.allNodes.first { $0.id.stableString==id }?.id;model.saveTree()
        },contextActions:{ id in
            guard let repository=model.tree.allNodes.first(where:{ $0.id.stableString==id })?.repository else { return [] }
            return [OutlineContextAction(title:repository.pinned ? "Unpin Repository" : "Pin Repository",perform:{ Task { await model.pin(repository) } }),OutlineContextAction(title:"Copy Repository Name",perform:{ NSPasteboard.general.clearContents();NSPasteboard.general.setString(repository.repository.name,forType:.string) }),OutlineContextAction(title:"Open on GitHub",perform:{ ExternalLinkPolicy.open(repository.webURL) })]
        },displayed:{ id in if let repository=model.tree.allNodes.first(where:{ $0.id.stableString==id })?.repository { Task { await model.enrich(repository) } } })
    }
    private func node(_ value:RepoTreeNode) -> NativeOutlineNode {
        NativeOutlineNode(id:value.id.stableString,title:value.title,subtitle:value.repository.map { $0.accountLogin+($0.repository.isPrivate ? " · Private" : "")+" · "+ProviderStateText.checks($0.defaultCI).text+" · "+ReposView.openPRText($0.openPRs)+" · ★ "+String($0.stars)+($0.latestRelease.map { " · "+$0 } ?? "")+($0.pushedAt.map { " · "+$0.formatted(date:.numeric,time:.omitted) } ?? "") } ?? (value.count==0 ? "No accessible repositories" : String(value.count)),symbol:value.repository == nil ? (value.id.group == "pins" ? "pin.fill" : value.id.ownerID.isEmpty ? "person.crop.circle" : "building.2") : "shippingbox",children:value.children.map(node),expandable:!value.children.isEmpty)
    }
}
