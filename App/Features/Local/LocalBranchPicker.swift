import SwiftUI
import MergeProCore

struct LocalBranchPicker: View {
    let branches: [LocalGitBranch]
    let busy: Bool
    let onSelect: (LocalGitBranch) -> Void
    let onCreate: () -> Void
    @State private var presented = false
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private var current: LocalGitBranch? { branches.first(where: \.isCurrent) }
    private var filtered: [LocalGitBranch] {
        branches.filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.upstream?.localizedStandardContains(query) == true) }
            .sorted { lhs, rhs in lhs.isCurrent != rhs.isCurrent ? lhs.isCurrent : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                Text(current?.name ?? "Detached HEAD").lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .disabled(busy)
        .accessibilityLabel("Choose branch")
        .accessibilityValue(current?.name ?? "Detached HEAD")
        .accessibilityIdentifier("localBranchPicker")
        .help("Search local branches or create a branch")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search branches or upstream", text: $query)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Search branches")
                        .onSubmit { chooseSelection() }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear branch search")
                    }
                }.padding(14)
                Divider()
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query).frame(height: 160)
                } else {
                    ScrollViewReader { scroll in
                        List(selection: $selection) {
                            ForEach(filtered) { branch in
                                Button { choose(branch) } label: { branchRow(branch) }
                                    .buttonStyle(.plain).tag(branch.name).id(branch.name)
                                    .disabled(busy)
                                    .accessibilityLabel(branch.name)
                                    .accessibilityValue([branch.isCurrent ? "Current branch" : nil, branch.isProtected ? "Protected" : nil, branch.upstream].compactMap { $0 }.joined(separator: ", "))
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden)
                            .onChange(of: selection) { _, value in if let value { scroll.scrollTo(value) } }
                    }.frame(height: min(340, CGFloat(filtered.count) * 62 + 16))
                }
                Divider()
                Button("Create Branch…", systemImage: "plus") { presented = false; onCreate() }
                    .disabled(busy).padding(12).accessibilityIdentifier("localCreateBranch")
            }
            .frame(width: 360)
            .onAppear { query = ""; selection = current?.name; searchFocused = true }
            .onChange(of: query) { _, _ in selection = filtered.first?.name }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.return) { chooseSelection(); return .handled }
            .onKeyPress(.escape) { presented = false; return .handled }
        }
    }

    private func branchRow(_ branch: LocalGitBranch) -> some View {
        HStack(spacing: 10) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(branch.isCurrent ? DesignTokens.cobalt : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(branch.name).font(.callout.weight(branch.isCurrent ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    if branch.isProtected { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Protected branch") }
                }
                if let upstream = branch.upstream { Text(upstream).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 0)
            if branch.isCurrent { Text("Current").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
    }

    private func moveSelection(_ offset: Int) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex(where: { $0.name == selection }) ?? (offset > 0 ? -1 : filtered.count)
        selection = filtered[min(max(0, index + offset), filtered.count - 1)].name
    }
    private func chooseSelection() {
        if let branch = filtered.first(where: { $0.name == selection }) ?? filtered.first { choose(branch) }
    }
    private func choose(_ branch: LocalGitBranch) {
        guard !busy else { return }
        presented = false
        if !branch.isCurrent { onSelect(branch) }
    }
}
