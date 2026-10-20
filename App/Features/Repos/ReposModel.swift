import Foundation
import Observation
import MergeProCore

@MainActor @Observable final class ReposModel {
    var service:RepositoryBrowserService?
    var entries:[RepoCatalogEntry]=[]
    var tree=RepoTreeStore(entries:[])
    var filter=RepoCatalogFilter()
    var treeMode=true
    var selected:RepositoryKey?
    var section="code"
    var refName=""
    var ref:ResolvedRepositoryRef?
    var branchPage:Int? = 1
    var tagPage:Int? = 1
    var branches:[RepositoryBranch]=[]
    var tags:[RepositoryTag]=[]
    var error:String?
    var accountProblems:[AccountScope:String]=[:]
    var busy=false
    var initialPath:String?
    var initialLine:Int?
    var generation=UUID()
    private var saveTask:Task<Void,Never>?
    private var enriching:Set<RepositoryKey>=[]
    /// Pagination results belong to the list they were requested for; a reset or repository change supersedes them.
    private var branchToken=UUID()
    private var tagToken=UUID()
    var repository:RepoCatalogEntry? { entries.first { $0.key==selected } }
    var visible:[RepoCatalogEntry] { filter.apply(entries) }
    func load(storage:SetupStorage,route:RepoNavigationRoute?) async {
        do {
            service=try await storage.repositoryBrowserService()
            guard let service else { return }
            entries=try await service.cachedCatalog();tree=RepoTreeStore(entries:entries,state:try await service.treeState(),owners:try await service.catalogOwners())
            selected=route?.repository ?? tree.allNodes.first { $0.id==tree.selection }?.repository?.key
            if let route { section=route.section ?? "code";refName=route.ref ?? "";initialPath=route.path;initialLine=route.line }
            await refresh()
        } catch { self.error=providerErrorMessage(error) }
    }
    func refresh() async {
        guard let service else { return };busy=true;defer { busy=false }
        do {
            let values=try await service.catalog();entries=values;tree.owners=try await service.catalogOwners();accountProblems=await service.catalogProblems
            var filtered=filter;filtered.search="";tree.refresh(filtered.apply(entries));tree.search=filter.search
            if let selected,!entries.contains(where:{ $0.key==selected }) { self.selected=nil;ref=nil }
        } catch {
            // A superseded refresh (a newer account change, or the page closed) reports nothing.
            guard !Task.isCancelled else { return }
            self.error=providerErrorMessage(error)
        }
    }
    func invalidateAccounts(_ accounts:Set<AccountScope>) {
        entries.removeAll { accounts.contains($0.key.account) };tree.owners.removeAll { accounts.contains($0.account) }
        if let selected,accounts.contains(selected.account) { self.selected=nil;ref=nil;generation=UUID() }
        var filtered=filter;filtered.search="";tree.refresh(filtered.apply(entries));tree.search=filter.search
    }
    /// A route to another repository or ref drops the previous resolved ref and ref lists so no view reads them against the new target.
    func route(_ route:RepoNavigationRoute) {
        let name=route.ref ?? ""
        if selected != route.repository { ref=nil;resetBranches();resetTags() } else if name != refName { ref=nil }
        selected=route.repository;section=route.section ?? "code";refName=name;initialPath=route.path;initialLine=route.line;generation=UUID()
    }
    func select(_ key:RepositoryKey) { guard selected != key else { return };selected=key;refName="";ref=nil;resetBranches();resetTags();initialPath=nil;initialLine=nil;generation=UUID() }
    func resetBranches() { branches=[];branchPage=1;branchToken=UUID() }
    private func resetTags() { tags=[];tagPage=1;tagToken=UUID() }
    func open() async {
        guard let service,let repository else { return };let captured=repository.key;let current=generation
        do {
            var restored=false
            if refName.isEmpty,let saved=await AppLog.value(AppLog.repositories,"Saved code browser state could not be read",fallback:nil,{ try await service.codeState(repository:repository.key) }),selected==captured,current==generation {
                refName=saved.refName ?? repository.defaultBranch;restored=saved.refName != nil
                if initialPath==nil { initialPath=saved.selection }
            }
            var name=refName.isEmpty ? repository.defaultBranch : refName
            let value:ResolvedRepositoryRef
            do { value=try await service.resolve(repository:repository,ref:name) }
            catch let failure as GitHubFailure where restored && name != repository.defaultBranch && (failure == .resourceDenied || failure == .invalidResponse) && !Task.isCancelled {
                // A restored branch is often deleted after merge; reopen the default branch instead of leaving the browser unresolved.
                name=repository.defaultBranch;value=try await service.resolve(repository:repository,ref:name)
            }
            guard selected==captured,current==generation,!Task.isCancelled else { return };ref=value;refName=name
            let overview=await AppLog.value(AppLog.repositories,"The repository overview could not be read",fallback:nil) { try await service.overview(repository) }
            guard selected==captured,current==generation,!Task.isCancelled else { return }
            if let overview,let index=entries.firstIndex(where:{ $0.key==captured }) { entries[index]=overview }
            // Ref changes reopen the browser; only the first page loads here so later pages stay an explicit request.
            if branchPage==1 { await moreBranches() };if tagPage==1 { await moreTags() }
        } catch { if !Task.isCancelled,selected==captured,current==generation { self.error=providerErrorMessage(error) } }
    }
    func changeRef(_ name:String) { refName=name;ref=nil;generation=UUID() }
    func moreBranches() async {
        guard let service,let repository,let page=branchPage else { return };let key=repository.key,token=branchToken
        do { let value=try await service.branches(repository:repository,page:page);guard selected==key,token==branchToken,branchPage==page,!Task.isCancelled else { return };branches += value.values.filter { branch in !branches.contains(where:{ $0.name==branch.name }) };branchPage=value.nextPage }
        catch { if selected==key,token==branchToken,!Task.isCancelled { self.error=providerErrorMessage(error) } }
    }
    func moreTags() async {
        guard let service,let repository,let page=tagPage else { return };let key=repository.key,token=tagToken
        do { let value=try await service.tags(repository:repository,page:page);guard selected==key,token==tagToken,tagPage==page,!Task.isCancelled else { return };tags += value.values.filter { tag in !tags.contains(where:{ $0.name==tag.name }) };tagPage=value.nextPage }
        catch { if selected==key,token==tagToken,!Task.isCancelled { self.error=providerErrorMessage(error) } }
    }
    func enrich(_ repository:RepoCatalogEntry) async {
        guard let service,repository.openPRs==nil,!enriching.contains(repository.key) else { return }
        enriching.insert(repository.key);defer { enriching.remove(repository.key) }
        do {
            let overview=try await service.overview(repository)
            guard !Task.isCancelled,let index=entries.firstIndex(where:{ $0.key==repository.key }) else { return }
            entries[index]=overview;var filtered=filter;filtered.search="";tree.refresh(filtered.apply(entries));tree.search=filter.search
        } catch { if !Task.isCancelled { accountProblems[repository.key.account]=providerErrorMessage(error) } }
    }
    func saveTree() { guard let service else { return };let state=tree.persistence;saveTask?.cancel();saveTask=Task { do { try await Task.sleep(for:.milliseconds(180));try await service.saveTreeState(state) } catch { if !Task.isCancelled { self.error=providerErrorMessage(error) } } } }
    func pin(_ repository:RepoCatalogEntry) async {
        guard let service else { return }
        do { try await service.setPinned(repository,pinned:!repository.pinned);if let index=entries.firstIndex(where:{ $0.key==repository.key }) { entries[index].pinned.toggle() };var filtered=filter;filtered.search="";tree.refresh(filtered.apply(entries));tree.search=filter.search }
        catch { self.error=providerErrorMessage(error) }
    }
}

/// User-facing text for provider failures; raw enum cases and type names are never shown.
func providerErrorMessage(_ error:any Error) -> String {
    switch error {
    case let failure as RepositoryBrowserFailure:
        switch failure {
        case .invalidPath:return "This path is not available at the selected ref."
        case .invalidRef:return "The branch, tag, commit or name is invalid, or it changed since it was loaded. Refresh and try again."
        case .permissionDenied:return "The active account cannot make this change, or the repository identity changed."
        case .protectedBranch:return "Protected branches cannot be deleted here."
        case .defaultBranch:return "The default branch cannot be deleted."
        case .existingBranch:return "A branch with this name already exists."
        case .unknownWriteOutcome:return "GitHub did not confirm the outcome. Reconcile before trying again."
        case .missingRefs:return "GitHub could not compare these refs. Check both names and try again."
        case .assetTooLarge:return "This asset exceeds the supported download size. Download it on GitHub."
        case .invalidAsset:return "This asset is unavailable or its download link is invalid."
        case .reviewersNotRequested:return "The pull request exists, but reviewer requests could not be confirmed."
        }
    case let failure as GitHubFailure:
        switch failure {
        case .invalidAuthentication:return "GitHub rejected this account's authorization. Reconnect it in Setup."
        case .scopeRequired:return "This account needs additional GitHub permissions. Reconnect it in Setup."
        case .organizationRestricted:return "The organization restricts this app's access. Ask an organization owner to approve it."
        case .resourceDenied:return "GitHub could not find this resource, or the account cannot access it."
        case .rateLimited(let until):return "GitHub rate limited this account."+(until.map { " Retry after "+$0.formatted(date:.omitted,time:.shortened)+"." } ?? " Retry later.")
        case .unsafeURL:return "GitHub returned an unsafe link, so it was not followed."
        case .invalidResponse:return "GitHub returned an unexpected response. Refresh and try again."
        }
    case is CancellationError:return "The request stopped because its account or selection changed. Refresh to continue."
    default:
        if let message=(error as? LocalizedError)?.errorDescription { return message }
        let domain=(error as NSError).domain
        return [NSURLErrorDomain,NSCocoaErrorDomain,NSPOSIXErrorDomain].contains(domain) ? error.localizedDescription : "GitHub could not complete this request. Refresh, or check the account in Setup."
    }
}
