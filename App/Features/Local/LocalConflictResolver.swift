import SwiftUI
import MergeProCore

/// This view owns its editor buffer. Closing or reloading never writes a working file.
struct LocalConflictResolver: View {
    let directory: URL
    let path: String
    let folderStore: SecurityScopedFolderStore
    let runner: any GitRunner
    let onResolved: () -> Void
    let onOpenEditor: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var document: LocalGitConflictDocument?
    @State private var parsed = LocalTextConflictDocument(text: "")
    @State private var result = ""
    @State private var deletion = false
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var requiresReload = false
    @State private var loadGeneration = UUID()

    var body: some View {
        VStack(spacing: DesignTokens.standardSpacing) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolve conflict").font(.title2.bold())
                    Text(path).font(DesignTokens.codeFont).textSelection(.enabled)
                }
                Spacer()
                Button("Open in Editor", action: onOpenEditor)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            if let error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                }.padding(12).workspacePanel()
            }
            if loading {
                ProgressView("Reading conflict stages…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document {
                if case .conflicts(let operation, _) = document.snapshot.operation, operation == "rebase" {
                    Text("During rebase, Current (stage 2) is the history being rebased onto. Incoming (stage 3) is the commit being replayed.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                VSplitView {
                    HSplitView {
                        sidePane("Base · stage 1", side: document.base)
                        sidePane("Current · stage 2", side: document.current)
                        sidePane("Incoming · stage 3", side: document.incoming)
                    }.frame(minHeight: 160, idealHeight: 220)
                    HSplitView {
                        blockChoices.frame(minWidth: 230, idealWidth: 280, maxWidth: 440)
                        VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                            HStack {
                                Text("Result").font(.headline)
                                Spacer()
                                if deletion { Label("Delete file", systemImage: "trash").foregroundStyle(.orange) }
                                else if LocalTextConflictDocument.containsMarkers(result) { Text("Conflict markers remain").foregroundStyle(.orange) }
                                else { Text("Ready to mark resolved").foregroundStyle(.secondary) }
                            }
                            if deletion {
                                ContentUnavailableView("Resolve as deletion", systemImage: "trash", description: Text("Save and Mark Resolved will remove this path and stage its deletion."))
                            } else {
                                TextEditor(text: $result).font(DesignTokens.codeFont)
                                    .accessibilityLabel("Editable conflict result")
                                    .disabled(saving || requiresReload)
                                    .onChange(of: result) { _, value in parsed = LocalTextConflictDocument(text: value) }
                            }
                        }.padding(12).workspacePanel().frame(minWidth: 350, minHeight: 220)
                    }
                }
                HStack {
                    Button("Use Current") { use(document.current) }.disabled(saving || requiresReload)
                    Button("Use Incoming") { use(document.incoming) }.disabled(saving || requiresReload)
                    Toggle("Resolve as deletion", isOn: $deletion).toggleStyle(.checkbox).disabled(saving || requiresReload)
                    Spacer()
                    Button(requiresReload ? "Reload Repository State" : "Reload") { Task { await load(preserveBuffer: true) } }.disabled(saving)
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView().controlSize(.small) }
                        Text("Save and Mark Resolved")
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: [.command])
                    .disabled(saving || requiresReload || (!deletion && LocalTextConflictDocument.containsMarkers(result)))
                }
            } else {
                ContentUnavailableView("Use an editor or Terminal", systemImage: "doc.badge.gearshape", description: Text("This file cannot be safely resolved as text here. Open it externally, then refresh Local."))
            }
        }
        .padding(DesignTokens.sectionSpacing)
        .background { WorkspaceCanvas() }
        .frame(minWidth: 980, idealWidth: 1200, minHeight: 680, idealHeight: 800)
        .task(id: directory.path + "\0" + path) { await load(preserveBuffer: false) }
        .onDisappear { loadGeneration = UUID() }
    }

    private func sidePane(_ title: String, side: LocalGitConflictSide?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
            Text(title).font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(side?.text ?? "Deleted / no index stage")
                    .font(DesignTokens.codeFont).foregroundStyle(side == nil ? .secondary : .primary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
            }.accessibilityLabel(title)
        }.padding(12).workspacePanel().frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
    }
    private var blockChoices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.standardSpacing) {
                Text("Conflict blocks").font(.headline)
                if parsed.blocks.isEmpty {
                    Text("Choose a whole side or edit the result. Missing sides represent deletion.").foregroundStyle(.secondary)
                }
                ForEach(parsed.blocks) { block in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Block \(block.id + 1)").font(.subheadline.bold())
                        Text(block.current).font(.system(.caption, design: .monospaced)).lineLimit(4).foregroundStyle(.secondary)
                        Text(block.incoming).font(.system(.caption, design: .monospaced)).lineLimit(4).foregroundStyle(.secondary)
                        HStack {
                            ForEach(LocalTextConflictChoice.allCases, id: \.self) { choice in
                                Button(choice.rawValue.capitalized) { choose(choice, block: block) }
                                    .controlSize(.small)
                                    .accessibilityLabel("Use \(choice.rawValue) for conflict block \(block.id + 1)")
                            }
                        }
                    }.padding(12).workspacePanel()
                }
                Text("Block choices replace only that block in the current result. Other manual edits are retained.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }.disabled(saving || requiresReload)
    }
    private func choose(_ choice: LocalTextConflictChoice, block: LocalTextConflictBlock) {
        // Parse the current editor buffer so replacing a block cannot erase manual edits elsewhere.
        let live = LocalTextConflictDocument(text: result)
        guard let matching = live.blocks.first(where: { $0.id == block.id && $0.current == block.current && $0.incoming == block.incoming }) else { return }
        result = live.resolving([matching.id: choice]); deletion = false
        parsed = LocalTextConflictDocument(text: result)
    }
    private func use(_ side: LocalGitConflictSide?) { result = side?.text ?? ""; deletion = side == nil; parsed = LocalTextConflictDocument(text: result) }
    @MainActor private func load(preserveBuffer: Bool) async {
        let token = UUID(); loadGeneration = token
        loading = true; error = nil
        let selectedDirectory = directory, selectedPath = path
        do {
            let value = try await folderStore.withAllAccess { roots in
                try await LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true).conflictDocument(path: selectedPath, directory: selectedDirectory)
            }
            try Task.checkCancellation()
            guard loadGeneration == token, directory == selectedDirectory, path == selectedPath else { return }
            document = value; requiresReload = false
            if !preserveBuffer { result = value.workingText ?? ""; deletion = value.workingText == nil }
            parsed = LocalTextConflictDocument(text: result)
        } catch is CancellationError { return }
        catch {
            guard loadGeneration == token, directory == selectedDirectory, path == selectedPath else { return }
            self.error = Self.message(error); if !preserveBuffer { document = nil }
        }
        loading = false
    }
    @MainActor private func save() async {
        guard let document, !saving else { return }
        saving = true; error = nil; defer { saving = false }
        let resolution: LocalGitConflictResolution = deletion ? .delete : .text(result)
        let selectedDirectory = directory
        do {
            _ = try await folderStore.withAllAccess { roots in
                try await LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true).resolveConflict(document: document, resolution: resolution, directory: selectedDirectory)
            }
            onResolved(); dismiss()
        } catch { self.error = Self.message(error); requiresReload = true }
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? LocalGitConflictError { return error.localizedDescription }
        if let error = error as? LocalGitMutationError { return error.localizedDescription }
        if let error = error as? LocalGitError { return error.localizedDescription }
        if error is CancellationError { return "Cancelled. Refresh repository state before retrying." }
        return "The conflict could not be read or saved. Open the repository in an editor or Terminal, then refresh."
    }
}
