import SwiftUI
import MergeProCore

struct SetupRepositoryScopeView: View {
    @Bindable var model:SetupModel
    let snapshot:LocalSnapshot
    let account:Account
    private var owners:[String] {
        var names = Dictionary(snapshot.repositories.map {
            let owner = RepositoryScopeConfiguration.owner(of:$0)
            return (owner.lowercased(),owner)
        },uniquingKeysWith:{ first,_ in first })
        if let value = snapshot.settings[.organizations],let organizations = try? JSONDecoder().decode([GitHubOrganization].self,from:Data(value.utf8)) {
            for organization in organizations { names[organization.login.lowercased()] = organization.login }
        }
        return names.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body:some View {
        let configuration = try? RepositoryScopeConfiguration(settings:snapshot.settings,repositories:snapshot.repositories)
        let groups = Dictionary(grouping:snapshot.repositories,by:{ RepositoryScopeConfiguration.owner(of:$0).lowercased() })
        ForEach(owners,id:\.self) { owner in
            SetupRepositoryOwnerView(model:model,account:account,owner:owner,repositories:groups[owner.lowercased()] ?? [],
                tracked:snapshot.trackedRepositories,pins:snapshot.pins,mode:configuration?.mode(for:owner) ?? .selectedRepositories)
                .disabled(snapshot.settings[.authorizationProblem] == "true")
        }
    }
}

private struct SetupRepositoryOwnerView: View {
    @Bindable var model:SetupModel
    let account:Account
    let owner:String
    let repositories:[Repository]
    let tracked:Set<RepositoryKey>
    let pins:Set<ProviderKey>
    let mode:RepositoryScopeMode
    @State private var query = ""
    @State private var page = 0
    @State private var expanded = false
    @State private var saving = false
    private var projection:RepositoryScopePage { RepositoryScopePage(repositories:repositories,query:query,page:page) }
    private var trackedCount:Int { repositories.filter { tracked.contains($0.key) }.count }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline) {
                Label(owner,systemImage:"building.2").font(.headline)
                Spacer()
                Text("\(trackedCount) tracked · \(repositories.count) known").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Track",selection:Binding(get:{ mode },set:{ selected in
                saving = true
                Task { await model.setRepositoryScope(selected,owner:owner,account:account.scope);saving = false }
            })) {
                Text("All accessible repositories").tag(RepositoryScopeMode.allAccessible)
                Text("Specific repositories").tag(RepositoryScopeMode.selectedRepositories)
            }.pickerStyle(.segmented).disabled(saving)
            Text(mode == .allAccessible
                 ? "All accessible repositories are included. Newly discovered repositories are tracked automatically."
                 : "Choose individual repositories below. Your selections stay saved across pages and discovery refreshes.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(mode == .selectedRepositories ? "Choose repositories" : "Browse repositories",isExpanded:$expanded) {
                VStack(alignment:.leading,spacing:10) {
                    if mode == .selectedRepositories, !repositories.isEmpty {
                        HStack {
                            Button("Select all known") { updateSelection(Set(repositories.map(\.key)),enabled:true) }
                            Button("Clear all known") { updateSelection(Set(repositories.map(\.key)),enabled:false) }
                        }.disabled(saving)
                    }
                    TextField("Search \(owner) repositories",text:$query).textFieldStyle(.roundedBorder)
                        .onChange(of:query) { _,_ in page = 0 }
                    let result = projection
                    if mode == .selectedRepositories, !result.repositories.isEmpty {
                        HStack {
                            Button("Select this page") { updatePage(result,enabled:true) }
                            Button("Clear this page") { updatePage(result,enabled:false) }
                            Spacer()
                            if saving { ProgressView().controlSize(.small) }
                        }.disabled(saving)
                    }
                    if result.repositories.isEmpty {
                        Text(query.isEmpty ? "No repositories are currently known for this owner." : "No repositories match this search.")
                            .foregroundStyle(.secondary)
                    }
                    if result.totalCount > 0 { pagination(result) }
                    ForEach(result.repositories,id:\.key) { repository in
                        repositoryRow(repository)
                    }
                    if result.totalCount > 0 { pagination(result) }
                }.padding(.top,8)
            }
            .onChange(of:mode) { _,new in if new == .selectedRepositories { expanded = true } }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).workspacePanel(radius:12)
    }
    private func pagination(_ result:RepositoryScopePage) -> some View {
        HStack {
            Text("\(result.page * RepositoryScopePage.pageSize + 1)–\(result.page * RepositoryScopePage.pageSize + result.repositories.count) of \(result.totalCount)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Previous") { page = result.page - 1 }.disabled(result.page == 0).help("Previous page in \(owner)")
            Text("Page \(result.page + 1) of \(result.pageCount)").font(.caption)
            Button("Next") { page = result.page + 1 }.disabled(result.page + 1 == result.pageCount).help("Next page in \(owner)")
        }
    }
    private func updatePage(_ result:RepositoryScopePage,enabled:Bool) {
        updateSelection(Set(result.repositories.map(\.key)),enabled:enabled)
    }
    private func updateSelection(_ keys:Set<RepositoryKey>,enabled:Bool) {
        saving = true
        Task { await model.setRepositorySelection(keys,enabled:enabled,owner:owner,account:account.scope);saving = false }
    }
    private func repositoryRow(_ repository:Repository) -> some View {
        HStack {
            Toggle(repository.name,isOn:Binding(get:{ tracked.contains(repository.key) },set:{ enabled in
                saving = true
                Task { await model.setRepositorySelection([repository.key],enabled:enabled,owner:owner,account:account.scope);saving = false }
            })).toggleStyle(.checkbox).disabled(mode == .allAccessible || saving)
            if repository.isPrivate { Image(systemName:"lock").foregroundStyle(.secondary).help("Private repository") }
            if !repository.capabilities.contains(.merge) { Text("Read only").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            let pin = ProviderKey(host:account.scope.host,accountID:account.scope.accountID,repositoryID:repository.key.repositoryID,objectID:"repository")
            Button { Task { await model.setPinned(repository,enabled:!pins.contains(pin)) } } label: {
                Image(systemName:pins.contains(pin) ? "pin.fill" : "pin")
            }.buttonStyle(.borderless).help(pins.contains(pin) ? "Unpin repository" : "Pin repository")
                .accessibilityLabel(pins.contains(pin) ? "Unpin \(repository.name)" : "Pin \(repository.name)")
        }
    }
}
