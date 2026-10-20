import SwiftUI
import MergeProCore

struct ConflictView: View {
    let state: GitOperationState
    let status: GitStatusSnapshot
    let directory: URL
    let busy: Bool
    var select: (String) -> Void
    var recover: (Bool) -> Void
    @State private var confirmAbort = false
    private var operation: String? {
        switch state { case .conflicts(let operation, _): operation; case .running(let name): name; default: nil }
    }
    var body: some View {
        if operation != nil || status.entries.contains(where: \.isUnmerged) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(operation.map { ProviderStateText.gitOperation($0) + " in progress" } ?? "Unresolved conflicts", systemImage: "arrow.triangle.merge").font(.headline)
                    Spacer()
                    if operation != nil {
                        Button("Continue") { recover(false) }.disabled(busy || status.entries.contains(where: \.isUnmerged))
                        Button("Abort…", role: .destructive) { confirmAbort = true }.disabled(busy)
                    }
                }
                Text(operation == nil ? "Open a conflict, edit or choose the result, then save and mark it resolved. Review and commit the resolved changes when ready." : "Open a conflict to choose changes from either side or edit the result, then save and mark it resolved. Continue after all conflicts are resolved. Git recovery state is read again after relaunch. Open in Terminal if a hook or signing helper cannot run here.").font(.callout).foregroundStyle(.secondary)
                let paths = status.entries.filter(\.isUnmerged).map(\.path)
                if !paths.isEmpty { ScrollView(.horizontal) { HStack { ForEach(paths, id: \.self) { path in Button(path) { select(path) } } } } }
            }.padding(14).workspacePanel(radius: 12).padding(.horizontal, 16).padding(.bottom, 12)
                .alert("Abort \(operation.map(ProviderStateText.gitOperation) ?? "operation")?", isPresented: $confirmAbort) {
                    Button("Cancel", role: .cancel) {}
                    Button("Abort \(operation.map(ProviderStateText.gitOperation) ?? "operation")", role: .destructive) { recover(true) }
                } message: { Text("Target: \(directory.path)\nBranch: \(status.branch ?? "detached HEAD")\nGit will stop this operation and discard its current conflict resolution changes. Review or copy any resolutions you need before aborting.") }
        }
    }
}
