import SwiftUI
import MergeProCore

struct WorktreesView: View {
    let repository: LocalRepository?
    @Binding var selected: LocalWorktreeID?
    var open: (LocalWorktree, Bool) -> Void
    var edit: (LocalWorktree) -> Void
    var body: some View {
        List(selection: $selected) {
            ForEach(repository?.worktrees ?? []) { tree in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { heading(tree); Spacer(); controls(tree) }
                    VStack(alignment: .leading, spacing: 10) { heading(tree); controls(tree) }
                }.padding(.vertical, 10).tag(tree.id)
            }
        }.listStyle(.inset).scrollContentBackground(.hidden).accessibilityIdentifier("localWorktrees")
    }
    private func heading(_ tree: LocalWorktree) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tree.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? (tree.isBare ? "Bare repository" : "Detached HEAD"), systemImage: "arrow.triangle.branch").font(.headline)
            Text(tree.directory.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { if let head = tree.head { Text(head.prefix(8)).font(.caption.monospaced()).foregroundStyle(.secondary) }; if tree.isLocked { WorkspaceStatusBadge(text: tree.lockReason ?? "Locked", symbol: "lock", tint: .orange) }; if tree.isPrunable { WorkspaceStatusBadge(text: "Prunable", tint: .orange) } }
        }
    }
    private func controls(_ tree: LocalWorktree) -> some View {
        HStack { Button("Finder") { open(tree, false) }; Button("Terminal") { open(tree, true) }; Button("Editor") { edit(tree) } }.disabled(tree.isBare)
    }
}
