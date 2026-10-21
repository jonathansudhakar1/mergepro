import AppKit
import SwiftUI
import MergeProCore

/// Popover/sheet content for one PR's labels under the active action account. Toggling only edits
/// local selection; Apply sends ONE revision-independent label delta, and dismissing never writes.
/// An unconfirmed delta disables Apply until its provider result is read; nothing is resent.
struct PRLabelPicker: View {
    let pr: PullRequest
    let storage: SetupStorage
    let workspace: PRWorkspaceModel?
    var didWrite: () -> Void

    init(pr: PullRequest, storage: SetupStorage, workspace: PRWorkspaceModel?, didWrite: @escaping () -> Void = {}) {
        self.pr = pr; self.storage = storage; self.workspace = workspace; self.didWrite = didWrite
    }

    @Environment(\.dismiss) private var dismiss
    @State private var loadState = PRActionLoadState()
    @State private var actionPR: PullRequest?
    @State private var login = ""
    @State private var options: PRMetadataOptions?
    /// Descriptions, label management permission and labels past the first 100 come from the repository catalog.
    @State private var catalog: RepositoryLabelCatalog?
    @State private var catalogFresh = false
    /// Labels created from this picker, selected but not yet applied.
    @State private var created: [RepositoryLabel] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var newColor = LabelPalette.random()
    @State private var loading = false
    @State private var loadError: String?
    @State private var busy = false
    @State private var creating = false
    @State private var unresolved: [PRWriteOperation] = []
    @State private var pendingCreate: RepositoryLabelMutation?
    @State private var message: String?
    @State private var editingUnavailable = false
    @State private var hovered: String?
    /// Keyboard highlight: a label id, or "create" for the create row. Up/Down move it from the search field.
    @State private var highlighted: String?
    /// True after an arrow key, until the filter text changes: Space then toggles instead of typing a space.
    @State private var navigating = false
    @FocusState private var searchFocused: Bool

    /// The loaded identity must still be the active action account's cached row.
    private var available: Bool { loadState.key.map { key in workspace.map { $0.cached(key) != nil && $0.activeActionAccount == key.account } ?? true } ?? true }
    private var presented: Bool { loadState.canDisplay(actionPR?.key, available: available) && options != nil }
    private var current: [PRLabelRef] { options?.labels ?? [] }
    private var initialIDs: Set<String> { Set(current.map(\.id)) }
    private var canLabel: Bool { options?.canLabel == true }
    /// Label management needs triage or higher, the same role that may label a PR; the provider decides finally.
    private var canManage: Bool { catalog?.canManage ?? canLabel }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var allLabels: [PRLabelRef] {
        let extra = catalogFresh && options?.availableLabelsComplete == false ? (catalog?.labels ?? []).map { PRLabelRef(id: $0.id, name: $0.name) } : []
        var seen = Set<String>(), result: [PRLabelRef] = []
        for ref in current + (options?.availableLabels ?? []) + extra + created.map({ PRLabelRef(id: $0.id, name: $0.name) }) where seen.insert(ref.id).inserted { result.append(ref) }
        // Current labels first, then by name; order is fixed at load so rows do not jump while toggling.
        let initial = initialIDs
        return result.sorted { a, b in
            let ai = initial.contains(a.id), bi = initial.contains(b.id)
            return ai != bi ? ai : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    private var descriptions: [String: String] {
        var result: [String: String] = [:]
        for label in (catalog?.labels ?? []) + created { if let description = label.description { result[label.id] = description } }
        return result
    }
    private var colors: [String: String] {
        var result = options?.labelColors ?? [:]
        for label in (catalog?.labels ?? []) + created where result[label.name] == nil { result[label.name] = label.color }
        return result
    }
    private var visibleLabels: [PRLabelRef] {
        guard !query.isEmpty else { return allLabels }
        let descriptions = descriptions
        return allLabels.filter { $0.name.localizedCaseInsensitiveContains(query) || descriptions[$0.id]?.localizedCaseInsensitiveContains(query) == true }
    }
    private var exactMatch: Bool { allLabels.contains { $0.name.lowercased() == query.lowercased() } || catalog?.label(named: query) != nil }
    private var showCreate: Bool { presented && canManage && !query.isEmpty && !exactMatch && pendingCreate == nil }
    private var additions: [PRLabelRef] { allLabels.filter { selected.contains($0.id) && !initialIDs.contains($0.id) } }
    private var removals: [PRLabelRef] { current.filter { !selected.contains($0.id) } }
    private var canApply: Bool { presented && canLabel && unresolved.isEmpty && !busy && !creating && !(additions.isEmpty && removals.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if !available { unavailable }
                else if presented { list }
                else if loading { ProgressView("Reading labels…").controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 40) }
                else { failed }
            }
            notices
            Divider()
            footer
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
        .background { WindowKeyMonitor { handleKey($0) } }
        .onChange(of: search) { _, _ in
            navigating = false
            // Follow the filter: keep a still-visible highlight, otherwise the first label. The create row is only
            // ever highlighted with the arrow keys, so Return never creates a repository label by accident.
            let ids = visibleLabels.map(\.id)
            if highlighted.map({ !ids.contains($0) && !($0 == "create" && showCreate) }) ?? true { highlighted = ids.first }
        }
        .task { await load() }
        .onChange(of: available) { _, available in if !available { invalidate() } }
        .defaultFocus($searchFocused, true)
        .onAppear { searchFocused = true }
        .accessibilityIdentifier("labelPicker")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Labels", systemImage: "tag").font(.headline).foregroundStyle(DesignTokens.cobalt)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if loading || busy { ProgressView().controlSize(.small) }
            }
            if presented, let number = actionPR?.metadata?.number {
                Text("#\(number) · as \(login)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            TextField(canManage ? "Filter or create labels" : "Filter labels", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .disabled(!presented)
                .accessibilityIdentifier("labelPickerSearch")
                .accessibilityHint("Up and down arrows highlight a label; Return or Space toggles it; Command-Return applies.")
        }
        .padding(12)
    }

    private var list: some View {
        let rows = visibleLabels, descriptions = descriptions, colors = colors
        let estimated = rows.reduce(CGFloat(showCreate ? 32 : 0)) { $0 + (descriptions[$1.id] == nil ? 28 : 42) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showCreate { createRow.id("create") }
                    ForEach(rows, id: \.id) { ref in row(ref, description: descriptions[ref.id], hex: LabelChipRow.color(for: ref.name, in: colors)).id(ref.id) }
                    if rows.isEmpty && !showCreate {
                        Text(query.isEmpty ? "This repository has no labels." : "No labels match “\(query)”.")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }.padding(.vertical, 4)
            }
            .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
        }
        .frame(height: min(280, max(76, estimated + 8)))
    }

    private func row(_ ref: PRLabelRef, description: String?, hex: String?) -> some View {
        let isOn = selected.contains(ref.id), changed = isOn != initialIDs.contains(ref.id)
        return Button { toggle(ref) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(DesignTokens.cobalt)
                    .opacity(isOn ? 1 : 0).frame(width: 12).accessibilityHidden(true)
                Circle().fill(Color(labelHex: hex) ?? Color.secondary.opacity(0.35)).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.name).font(.callout).lineLimit(1).truncationMode(.tail)
                    if let description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if changed { Text(isOn ? "Add" : "Remove").font(.caption2.weight(.semibold)).foregroundStyle(isOn ? .green : .red) }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted == ref.id && canLabel ? DesignTokens.cobalt.opacity(0.14) : hovered == ref.id && canLabel ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .disabled(!canLabel || busy)
        .onHover { hovered = $0 ? ref.id : (hovered == ref.id ? nil : hovered) }
        .accessibilityLabel(ref.name + (description.map { ", " + $0 } ?? ""))
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("labelPickerRow-\(ref.name)")
    }

    private var createRow: some View {
        Button { Task { await create(query) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(DesignTokens.cobalt).frame(width: 12)
                Circle().fill(Color(labelHex: newColor) ?? .secondary).frame(width: 12, height: 12)
                Text(RepositoryLabel.validName(query) ? "Create label “\(query)”" : "Label names are 1–50 characters")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if creating { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.cobalt.opacity(highlighted == "create" ? 0.18 : hovered == "create" ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4).padding(.bottom, 2)
        .disabled(creating || busy || !RepositoryLabel.validName(query))
        .onHover { hovered = $0 ? "create" : (hovered == "create" ? nil : hovered) }
        .help("Creates the repository label and selects it. It is added to this pull request only when you apply.")
        .accessibilityIdentifier("labelPickerCreate")
    }

    @ViewBuilder private var notices: some View {
        let lines = noticeLines
        if !lines.isEmpty || !unresolved.isEmpty || pendingCreate != nil || editingUnavailable {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(unresolved) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(operation.state == .prepared ? "A label change was saved but not sent." : "GitHub has not confirmed a label change. Read its result before changing labels again.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        if operation.state == .prepared { Button("Release unsent command") { Task { await release(operation) } }.disabled(busy).accessibilityIdentifier("labelPickerRelease") }
                        else {
                            HStack(spacing: 8) {
                                Button("Read provider result") { Task { await reconcile(operation) } }.disabled(busy).accessibilityIdentifier("labelPickerReconcile")
                                // Label deltas are idempotent, so releasing an unreadable result can't duplicate anything.
                                if operation.canStopWaiting {
                                    Button("Stop waiting") { Task { await stopWaiting(operation) } }.disabled(busy)
                                        .help("Stop tracking this change and allow new label changes. Nothing is resent; check the labels on GitHub.")
                                        .accessibilityIdentifier("labelPickerStopWaiting")
                                }
                            }
                        }
                    }.controlSize(.small)
                }
                if let pendingCreate {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("GitHub did not confirm that “\(pendingCreate.name)” was created.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button("Read provider result") { Task { await reconcileCreate(pendingCreate) } }.disabled(creating).accessibilityIdentifier("labelPickerReconcileCreate")
                    }.controlSize(.small)
                }
                if editingUnavailable, let url = labelsURL {
                    HStack(spacing: 6) {
                        Text("GitHub doesn't allow creating labels from MergePro for this account.").font(.caption).foregroundStyle(.secondary)
                        Link("Edit on GitHub", destination: url).font(.caption)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
    private var noticeLines: [String] {
        var lines: [String] = []
        if presented, !canLabel { lines.append("\(login) can view these labels but can't change them on this pull request.") }
        if presented, options?.labelsComplete == false { lines.append("This pull request has more than 100 labels; only the first 100 are shown.") }
        if presented, options?.availableLabelsComplete == false, !(catalogFresh && catalog?.complete == true) { lines.append("This repository has more labels than MergePro could read, so some may be missing here.") }
        if let message { lines.append(message) }
        return lines
    }
    private var labelsURL: URL? {
        (actionPR ?? pr).metadata.flatMap { URL(string: "https://github.com/")?.appendingPathComponent($0.repositoryName).appendingPathComponent("labels") }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark").font(.title2).foregroundStyle(.secondary)
            Text("The active account changed. Labels are edited with the selected action account.").font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Try Again") { Task { await load() } }.accessibilityIdentifier("labelPickerReload")
        }.frame(maxWidth: .infinity).padding(20)
    }
    private var failed: some View {
        VStack(spacing: 10) {
            Text(loadError ?? "Labels are unavailable for the selected action account.").font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Try Again") { Task { await load() } }.accessibilityIdentifier("labelPickerReload")
        }.frame(maxWidth: .infinity).padding(20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !additions.isEmpty || !removals.isEmpty {
                HStack(spacing: 4) {
                    if !additions.isEmpty { Text("+\(additions.count)").foregroundStyle(.green) }
                    if !removals.isEmpty { Text("−\(removals.count)").foregroundStyle(.red) }
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(additions.count) to add, \(removals.count) to remove")
                .accessibilityIdentifier("labelPickerDelta")
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("labelPickerCancel")
            // ⌘Return, not Return: Return toggles the highlighted label, and applying stays a deliberate step.
            Button("Apply") { Task { await apply() } }
                .buttonStyle(.borderedProminent).tint(DesignTokens.cobalt)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Apply label changes (⌘Return)")
                .disabled(!canApply)
                .accessibilityIdentifier("labelPickerApply")
        }
        .controlSize(.small)
        .padding(12)
    }

    private func toggle(_ ref: PRLabelRef) {
        guard canLabel, !busy else { return }
        if !selected.insert(ref.id).inserted { selected.remove(ref.id) }
    }
    /// Arrow keys move the highlight, Return or Space toggles it (Space only after an arrow key or with an empty
    /// filter, so label names can contain spaces), and ⌘Return reaches the Apply button. Nothing here writes
    /// except Return on the create row, which only an arrow key can highlight.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard presented, event.editingModifiers.isEmpty else { return false }
        let ids = (showCreate ? ["create"] : []) + visibleLabels.map(\.id)
        switch event.specialKey {
        case .downArrow?, .upArrow?:
            guard !ids.isEmpty else { return true }
            let position = highlighted.flatMap { ids.firstIndex(of: $0) }
            let next = PRPaletteSearch.moveHighlight(position, by: event.specialKey == .downArrow ? 1 : -1, enabled: ids.map { _ in true }) ?? 0
            highlighted = ids[next]
            navigating = true
            announceHighlight()
            return true
        case .carriageReturn?, .enter?:
            activateHighlight()
            return true
        default:
            guard event.charactersIgnoringModifiers == " ", navigating || query.isEmpty, highlighted != nil else { return false }
            activateHighlight()
            return true
        }
    }
    private func activateHighlight() {
        guard let highlighted else { return }
        if highlighted == "create" {
            if showCreate, !creating, !busy, RepositoryLabel.validName(query) { Task { await create(query) } }
            return
        }
        guard let ref = allLabels.first(where: { $0.id == highlighted }) else { return }
        toggle(ref)
        announceHighlight()
    }
    private func announceHighlight() {
        guard let highlighted else { return }
        let text = highlighted == "create" ? "Create label \(query)"
            : allLabels.first { $0.id == highlighted }.map { $0.name + (selected.contains($0.id) ? ", selected" : ", not selected") }
        if let text { AccessibilityNotification.Announcement(text).post() }
    }
    private func invalidate() {
        loadState.invalidate(); actionPR = nil; options = nil; catalog = nil; catalogFresh = false; created = []; selected = []
        unresolved = []; pendingCreate = nil; busy = false; creating = false; loading = false; message = nil; editingUnavailable = false
    }

    private func load() async {
        let request = loadState.begin()
        loading = true; loadError = nil
        defer { if loadState.isCurrent(request) { loading = false } }
        do {
            let selectedPR = try await storage.actionPR(pr)
            loadState.select(selectedPR.key, request: request)
            guard loadState.accepts(selectedPR.key, request: request, available: available) else { return }
            let repository = selectedPR.key.repository
            let value = try await storage.labelOptions(selectedPR)
            let pending = try await storage.unresolvedLabelWrites(selectedPR.key)
            let name = (try? await storage.actionLogin(selectedPR.key)) ?? selectedPR.key.accountID
            let cached = try? await storage.cachedRepositoryLabels(repository)
            guard loadState.present(selectedPR.key, request: request, available: available) else { return }
            actionPR = selectedPR; login = name; options = value; unresolved = pending; catalog = cached; catalogFresh = false
            created = []; selected = Set(value.labels.map(\.id)); pendingCreate = nil
            if highlighted.map({ id in !allLabels.contains { $0.id == id } }) ?? true { highlighted = visibleLabels.first?.id }
            // A cached catalog supplies descriptions; a fresh one is read only when needed for labels past the first 100.
            if cached == nil || !value.availableLabelsComplete {
                let fresh = try? await storage.repositoryLabels(repository)
                loadState.publish(selectedPR.key, request: request, available: available) {
                    if let fresh { catalog = fresh; catalogFresh = true }
                }
            }
        } catch {
            if loadState.fail(request: request) { loading = false; loadError = error.localizedDescription }
        }
    }

    private func apply() async {
        guard canApply, let actionPR, let request = loadState.presentationRequest(for: actionPR.key, available: available) else { return }
        busy = true; message = nil
        defer { if loadState.isCurrent(request) { busy = false } }
        do {
            let command = try PRWriteCommand.labelChanges(actionPR: actionPR, add: additions, remove: removals)
            let result = try await storage.performWrite(command)
            if result.state == .confirmed {
                AccessibilityNotification.Announcement("GitHub confirmed the label changes.").post()
                await workspace?.reload()
                didWrite()
                if loadState.accepts(actionPR.key, request: request, available: available) { dismiss() }
            } else {
                loadState.publish(actionPR.key, request: request, available: available) {
                    unresolved = [result]
                    message = result.message
                    AccessibilityNotification.Announcement(result.message ?? "GitHub has not confirmed the label changes.").post()
                }
            }
        } catch {
            loadState.publish(actionPR.key, request: request, available: available) {
                message = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
        }
    }

    private func reconcile(_ operation: PRWriteOperation) async {
        guard let actionPR, let request = loadState.presentationRequest(for: actionPR.key, available: available) else { return }
        busy = true
        defer { if loadState.isCurrent(request) { busy = false } }
        do {
            let result = try await storage.reconcileWrite(operation.id)
            if result.state == .confirmed { await workspace?.reload(); didWrite() }
            guard loadState.accepts(actionPR.key, request: request, available: available) else { return }
            busy = false
            await load()
            message = switch result.state {
            case .confirmed: "GitHub confirms the label change applied."
            case .rejected: result.message ?? "The label change did not apply. Choose labels and apply again if needed."
            default: "GitHub's result is still unknown. Read it again shortly."
            }
        } catch {
            loadState.publish(actionPR.key, request: request, available: available) { message = error.localizedDescription }
        }
    }

    private func stopWaiting(_ operation: PRWriteOperation) async {
        guard let actionPR, let request = loadState.presentationRequest(for: actionPR.key, available: available) else { return }
        busy = true
        defer { if loadState.isCurrent(request) { busy = false } }
        do {
            _ = try await storage.writeCoordinator().abandonUncertain(operation.id)
            guard loadState.accepts(actionPR.key, request: request, available: available) else { return }
            busy = false
            await load()
            message = "Stopped waiting. Check this pull request's labels on GitHub before changing them again."
        } catch {
            loadState.publish(actionPR.key, request: request, available: available) { message = error.localizedDescription }
        }
    }

    private func release(_ operation: PRWriteOperation) async {
        guard let actionPR, let request = loadState.presentationRequest(for: actionPR.key, available: available) else { return }
        busy = true
        defer { if loadState.isCurrent(request) { busy = false } }
        do {
            try await storage.releaseUnsentWrite(operation.id)
            let pending = try await storage.unresolvedLabelWrites(actionPR.key)
            loadState.publish(actionPR.key, request: request, available: available) { unresolved = pending }
        } catch {
            loadState.publish(actionPR.key, request: request, available: available) { message = error.localizedDescription }
        }
    }

    /// Creates the repository label and selects it locally; the PR changes only on Apply.
    private func create(_ name: String) async {
        guard canManage, RepositoryLabel.validName(name), let actionPR, let request = loadState.presentationRequest(for: actionPR.key, available: available) else { return }
        let mutation = RepositoryLabelMutation.create(name: name, color: newColor, description: nil)
        creating = true; message = nil
        defer { if loadState.isCurrent(request) { creating = false } }
        do {
            var label = try await storage.applyRepositoryLabel(mutation, in: actionPR.key.repository)
            // An unreadable success receipt still means created; read the catalog for its identity.
            if label == nil { label = try? await storage.repositoryLabels(actionPR.key.repository).label(named: name) }
            loadState.publish(actionPR.key, request: request, available: available) { adopt(label, name: name) }
        } catch RepositoryLabelFailure.labelEditingUnavailable {
            loadState.publish(actionPR.key, request: request, available: available) { editingUnavailable = true }
        } catch RepositoryBrowserFailure.unknownWriteOutcome {
            loadState.publish(actionPR.key, request: request, available: available) { pendingCreate = mutation }
        } catch {
            loadState.publish(actionPR.key, request: request, available: available) { message = providerErrorMessage(error) }
        }
    }
    private func reconcileCreate(_ mutation: RepositoryLabelMutation) async {
        guard let actionPR, let request = loadState.presentationRequest(for: actionPR.key, available: available) else { return }
        creating = true
        defer { if loadState.isCurrent(request) { creating = false } }
        do {
            let result = try await storage.reconcileRepositoryLabel(mutation, in: actionPR.key.repository)
            let fresh = result == .applied ? try? await storage.repositoryLabels(actionPR.key.repository) : nil
            loadState.publish(actionPR.key, request: request, available: available) {
                pendingCreate = nil
                if result == .applied { if let fresh { catalog = fresh; catalogFresh = true };adopt(fresh?.label(named: mutation.name), name: mutation.name) }
                else { message = "“\(mutation.name)” was not created. You can create it again." }
            }
        } catch {
            loadState.publish(actionPR.key, request: request, available: available) { message = providerErrorMessage(error) }
        }
    }
    private func adopt(_ label: RepositoryLabel?, name: String) {
        guard let label else { message = "GitHub created “\(name)”, but MergePro couldn't read it back. Reopen labels to select it."; return }
        if !created.contains(where: { $0.id == label.id }) { created.append(label) }
        selected.insert(label.id); search = ""; newColor = LabelPalette.random()
    }
}
