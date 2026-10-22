import Foundation
import GRDB

public actor ActionsService {
    private let session:GitHubAccountSession
    private let budget:RateBudget
    private let database:DatabaseStore
    private let clientID:String
    private let activeAccount:@Sendable () async throws -> AccountScope?
    public init(session:GitHubAccountSession,budget:RateBudget,database:DatabaseStore,clientID:String,activeAccount:@escaping @Sendable () async throws -> AccountScope?) { self.session=session;self.budget=budget;self.database=database;self.clientID=clientID;self.activeAccount=activeAccount }
    private func provider(_ repository:Repository) async throws -> (AccountOperation,GitHubActionsProvider) {
        let ticket=try await session.authenticatedOperation(for:repository.key.account,clientID:clientID)
        return (ticket,GitHubActionsProvider(client:await session.interactiveReadClient(account:ticket.account,budget:budget),credential:ticket.credential))
    }
    private func current(_ ticket:AccountOperation) async throws { guard try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw ActionsFailure.accountChanged } }
    public func cachedCatalog(repository:RepositoryKey) async throws -> ActionsCatalog? { let ticket=try await session.authenticatedOperation(for:repository.account,clientID:clientID);let value=try ActionsStore(database:database).catalog(repository);try await current(ticket);return value }
    /// Cached catalogs of several repositories in one pass: one authorization check per account (not per
    /// repository) and each repository's own polled runs (not an account-wide snapshot decode per repository).
    /// Repositories of unavailable accounts, or without any cached Actions data, are absent.
    public func cachedCatalogs(repositories:[RepositoryKey]) async -> [RepositoryKey:ActionsCatalog] {
        var result:[RepositoryKey:ActionsCatalog]=[:]
        for (account,keys) in Dictionary(grouping:repositories,by:\.account) {
            let ticket:AccountOperation
            do { ticket=try await session.authenticatedOperation(for:account,clientID:clientID) } catch {
                Log.actions.debug("Cached Actions catalogs skipped for an unavailable account: \(Log.kind(error), privacy: .public)");continue
            }
            var values:[RepositoryKey:ActionsCatalog]=[:]
            for key in Set(keys) {
                do { if let catalog=try ActionsStore(database:database).catalog(key) { values[key]=catalog } }
                catch { Log.actions.error("Cached Actions catalog could not be read: \(Log.kind(error), privacy: .public)") }
            }
            guard (try? await current(ticket)) != nil else { Log.actions.debug("Cached Actions catalogs dropped: the account changed while reading");continue }
            result.merge(values) { _,new in new }
        }
        return result
    }
    public func catalog(repository:Repository) async throws -> ActionsCatalog {
        let (ticket,provider)=try await provider(repository)
        do {
            let runs=try await provider.recentRuns(repository:repository)
            var unavailable:[String:String]=[:]
            let listed=try await optionalRead("workflows",unavailable:&unavailable,fallback:[]) { try await provider.workflows(repository:repository) }
            let workflows=try await optionalRead("workflowInputs",unavailable:&unavailable,fallback:listed) { try await provider.dispatchCapabilities(repository:repository,workflows:listed) }
            let deployments=try await optionalRead("deployments",unavailable:&unavailable,fallback:[]) { try await provider.deployments(repository:repository) }
            let listedEnvironments=try await optionalRead("environments",unavailable:&unavailable,fallback:[]) { try await provider.environments(repository:repository) }
            let environments=listedEnvironments.map { environment in ActionsEnvironment(id:environment.id,name:environment.name,canApprove:environment.canApprove,production:environment.production || deployments.contains { $0.environment==environment.name && $0.production }) }
            let catalog=ActionsCatalog(repository:repository,runs:runs,workflows:workflows,deployments:deployments,environments:environments,unavailableSections:unavailable)
            let store=try ActionsStore(database:database)
            guard try await session.withCurrentOperation(ticket,body:{ _ in try store.save(catalog) }) else { throw ActionsFailure.accountChanged };return catalog
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func history(repository:Repository) async throws -> ActionsCatalog {
        let (ticket,provider)=try await provider(repository)
        do {
            let runs=try await provider.runs(repository:repository)
            let store=try ActionsStore(database:database),cached=try store.catalog(repository.key)
            let catalog=ActionsCatalog(repository:repository,runs:runs,workflows:cached?.workflows ?? [],deployments:cached?.deployments ?? [],environments:cached?.environments ?? [],unavailableSections:cached?.unavailableSections ?? [:])
            guard try await session.withCurrentOperation(ticket,body:{ _ in try store.save(catalog) }) else { throw ActionsFailure.accountChanged };return catalog
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func detail(run:WorkflowRun,onPrimary:(@MainActor @Sendable (ActionsRunDetail) async -> Void)? = nil) async throws -> ActionsRunDetail {
        let (ticket,provider)=try await provider(run.repository)
        do {
            let observed=try await provider.run(repository:run.repository,id:run.runID,attempt:run.attempt)
            guard observed.attempt==run.attempt else { throw ActionsFailure.staleRun }
            var unavailable:[String:String]=[:]
            let jobs=try await optionalRead("jobs",unavailable:&unavailable,fallback:[]) { try await provider.jobs(run:observed) }
            // Primary navigation need not wait for artifacts, annotations and environment policy.
            // Publish only after the same credential-generation guard as the final read.
            try Task.checkCancellation()
            try await current(ticket)
            if let onPrimary { await onPrimary(.init(run:observed,jobs:jobs,artifacts:[],annotations:[],pendingDeployments:[],unavailableSections:unavailable)) }
            try Task.checkCancellation()
            let artifacts=try await optionalRead("artifacts",unavailable:&unavailable,fallback:[]) { try await provider.artifacts(run:observed) }
            var annotations:[ActionsAnnotation]=[]
            for job in jobs { annotations += try await optionalRead("annotations",unavailable:&unavailable,fallback:[]) { try await provider.annotations(repository:run.repository,job:job) } }
            // Environment review is a property of the current attempt, never an old attempt.
            let latest=try await provider.run(repository:run.repository,id:run.runID)
            let deployments=try await optionalRead("deploymentPolicy",unavailable:&unavailable,fallback:[]) { try await provider.deployments(repository:run.repository) }
            let production=Set(deployments.filter(\.production).map { $0.environment.lowercased() }).union(try configuredProduction())
            let listedPending=latest.attempt==run.attempt ? try await optionalRead("pendingDeployments",unavailable:&unavailable,fallback:[]) { try await provider.pendingDeployments(run:observed) }:[]
            let pending=listedPending.map { environment in ActionsEnvironment(id:environment.id,name:environment.name,canApprove:environment.canApprove,production:environment.production || production.contains(environment.name.lowercased())) }
            try await current(ticket)
            return .init(run:observed,jobs:jobs,artifacts:artifacts,annotations:annotations,pendingDeployments:pending,unavailableSections:unavailable)
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func log(repository:Repository,jobID:Int64) async throws -> ActionsLogAvailability {
        let (ticket,provider)=try await provider(repository)
        do { let log=try await provider.log(repository:repository,jobID:jobID);try await current(ticket);return log } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func artifact(repository:Repository,artifact:ActionsArtifact) async throws -> Data {
        let (ticket,provider)=try await provider(repository)
        do { let data=try await provider.artifact(repository:repository,artifact:artifact);try await current(ticket);return data } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func refs(repository:Repository,matching query:String) async throws -> WorkflowRefMatches {
        let (ticket,provider)=try await provider(repository)
        do { let refs=try await provider.refs(repository:repository,matching:query);try await current(ticket);return refs } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    /// The repository's environments as dispatch admission will see them, for environment-typed inputs.
    public func environments(repository:Repository) async throws -> [ActionsEnvironment] {
        let (ticket,provider)=try await provider(repository)
        do { let values=try await provider.environments(repository:repository);try await current(ticket);return values } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func schema(repository:Repository,workflow:ActionsWorkflow,ref:String) async throws -> WorkflowInputSchema {
        let (ticket,provider)=try await provider(repository)
        do { let schema=try await provider.schema(repository:repository,workflow:workflow,ref:ref);try await current(ticket);return schema } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func presets(repository:RepositoryKey?=nil) async throws -> [WorkflowPreset] { let values=try ActionsStore(database:database).presets(repository);var allowed:[WorkflowPreset]=[];for account in Set(values.map { $0.repository.account }) { do { let ticket=try await session.authenticatedOperation(for:account,clientID:clientID);try await current(ticket);allowed += values.filter { $0.repository.account==account } } catch { if repository != nil { throw error } } };return allowed }
    public func savePreset(_ preset:WorkflowPreset) async throws {
        guard try await activeAccount()==preset.repository.account else { throw ActionsFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:preset.repository.account,clientID:clientID),store=try ActionsStore(database:database)
        guard try await session.withCurrentOperation(ticket,body:{ _ in try store.save(preset) }) else { throw ActionsFailure.accountChanged }
    }
    public func removePreset(_ id:UUID) throws { try ActionsStore(database:database).removePreset(id) }
    public func operations(repository:RepositoryKey?=nil) async throws -> [ActionsWriteOperation] { let values=try ActionsStore(database:database).operations(repository);var allowed:[ActionsWriteOperation]=[];for account in Set(values.map { $0.repository.key.account }) { do { let ticket=try await session.authenticatedOperation(for:account,clientID:clientID);try await current(ticket);allowed += values.filter { $0.repository.key.account==account } } catch { if repository != nil { throw error } } };return allowed }
    public func viewState(account:AccountScope) async throws -> ActionsViewState { let ticket=try await session.authenticatedOperation(for:account,clientID:clientID);let state=try ActionsStore(database:database).viewState(account);try await current(ticket);return state }
    public func saveViewState(_ state:ActionsViewState,account:AccountScope) async throws { let ticket=try await session.authenticatedOperation(for:account,clientID:clientID);let store=try ActionsStore(database:database);guard try await session.withCurrentOperation(ticket,body:{ _ in try store.saveViewState(state,account:account) }) else { throw ActionsFailure.accountChanged } }
    public func perform(repository:Repository,intent:ActionsIntent) async throws -> ActionsWriteOperation {
        guard try await activeAccount()==repository.key.account else { throw ActionsFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:repository.key.account,clientID:clientID)
        let store=try ActionsStore(database:database)
        for pending in try store.operations(repository.key) where pending.intent.lockIdentity==intent.lockIdentity && pending.state == .accepted { _=try await reconcile(pending.id) }
        var operation=ActionsWriteOperation(repository:repository,intent:intent)
        try store.prepare(operation)
        do {
            let reader=GitHubActionsProvider(client:await session.interactiveReadClient(account:ticket.account,budget:budget),credential:ticket.credential)
            try await admission(repository:repository,intent:intent,provider:reader)
            if case .dispatch=intent { operation.beforeRunIDs=try await reader.recentRuns(repository:repository).map(\.runID);try store.update(operation,from:.prepared) }
            let prepared=operation
            let writer=await session.preflightWriteClient(account:ticket.account,budget:budget,current:{ [session,activeAccount] in
                guard try await activeAccount()==ticket.account,try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw ActionsFailure.accountChanged }
            },beforeSend:{ [session,activeAccount] client in
                guard try await activeAccount()==ticket.account else { throw ActionsFailure.accountChanged }
                let fresh=GitHubActionsProvider(client:client,credential:ticket.credential)
                try await self.admission(repository:repository,intent:intent,provider:fresh)
                guard try await activeAccount()==ticket.account,try await session.withCurrentWriteOperation(ticket,body:{ _ in
                    var sent=prepared;sent.state = .sending
                    do { try store.update(sent,from:.prepared) } catch { throw ActionsFailure.persistenceBeforeSend }
                }) else { throw ActionsFailure.accountChanged }
            })
            let request=try mutation(repository:repository,intent:intent,provider:reader)
            let response=try await writer.mutate(path:request.path,method:"POST",body:request.body,token:ticket.credential.accessToken)
            guard [200,201,202,204].contains(response.status) else { throw GitHubFailure.invalidResponse }
            if case .deployment=intent,response.status != 200 { throw GitHubFailure.invalidResponse }
            operation=try store.operation(operation.id) ?? operation
            // Positive acceptance is durable; dispatch 204 has no run correlation, so never invent one.
            operation.state = .accepted;operation.message="GitHub accepted the request. Refreshing provider state."
            if case .deployment=intent { operation.state = .confirmed;operation.message="GitHub confirmed the deployment review." }
            try store.update(operation,from:.sending)
            return operation
        } catch {
            await session.featureFailed(error,operation:ticket)
            var saved=try store.operation(operation.id) ?? operation
            guard [.prepared,.sending].contains(saved.state) else { return saved }
            let expected=saved.state
            let denied:Bool
            switch error as? GitHubFailure { case .invalidAuthentication,.resourceDenied,.scopeRequired,.organizationRestricted,.rateLimited:denied=true;default:denied=error is ActionsFailure }
            saved.state = expected == .prepared || denied ? .rejected:.uncertain
            saved.message = saved.state == .uncertain ? "Provider outcome is unknown. Reconcile before trying again.":"The request was not admitted. Refresh permissions and inputs."
            try store.update(saved,from:expected)
            if saved.state == .rejected { throw error };return saved
        }
    }
    private func admission(repository:Repository,intent:ActionsIntent,provider:GitHubActionsProvider) async throws {
        guard try await activeAccount()==repository.key.account else { throw ActionsFailure.accountChanged }
        if case .deployment(let id,let attempt,let ids,_,let comment,let confirmed)=intent {
            guard !ids.isEmpty,!comment.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ActionsFailure.invalidInput("Deployment comment") }
            let run=try await provider.run(repository:repository,id:id)
            guard run.attempt==attempt,run.isActive else { throw ActionsFailure.staleRun }
            let pending=try await provider.pendingDeployments(run:run)
            guard ids.allSatisfy({ id in pending.contains { $0.id==id && $0.canApprove } }) else { throw ActionsFailure.permissionDenied }
            let deployments=try await provider.deployments(repository:repository)
            let production=Set(deployments.filter(\.production).map { $0.environment.lowercased() }).union(try configuredProduction())
            if pending.contains(where:{ ids.contains($0.id) && ($0.production || production.contains($0.name.lowercased())) }),!confirmed { throw ActionsFailure.productionConfirmationRequired };return
        }
        guard try await provider.canWrite(repository:repository) else { throw ActionsFailure.permissionDenied }
        switch intent {
        case .dispatch(let workflow,let expected,let inputs,let confirmed):
            let schema=try await provider.schema(repository:repository,workflow:workflow,ref:expected.ref)
            guard schema==expected else { throw ActionsFailure.staleSchema }
            let environments=try await provider.environments(repository:repository)
            _ = try schema.validate(inputs,environments:environments.map(\.name))
            let deployments=try await provider.deployments(repository:repository)
            let production=Set(deployments.filter(\.production).map { $0.environment.lowercased() }).union(try configuredProduction())
            if schema.requiresProductionConfirmation(values:inputs,productionEnvironments:production),!confirmed { throw ActionsFailure.productionConfirmationRequired }
        case .rerunAll(let id,let attempt),.rerunFailed(let id,let attempt):let run=try await provider.run(repository:repository,id:id);guard run.attempt==attempt,run.status=="completed" else { throw ActionsFailure.staleRun }
        case .cancel(let id,let attempt):let run=try await provider.run(repository:repository,id:id);guard run.attempt==attempt,run.isActive else { throw ActionsFailure.staleRun }
        case .approveFork(let id,let attempt):let run=try await provider.run(repository:repository,id:id);guard run.attempt==attempt,["action_required","waiting"].contains(run.status) || run.conclusion=="action_required" else { throw ActionsFailure.staleRun }
        case .deployment:break
        }
    }
    private func optionalRead<T:Sendable>(_ section:String,unavailable:inout [String:String],fallback:T,read:() async throws -> T) async throws -> T {
        do { return try await read() }
        catch {
            if Task.isCancelled || error is CancellationError || error as? GitHubFailure == .invalidAuthentication || error as? GitHubFailure == .unsafeURL || error as? ActionsFailure == .accountChanged { throw error }
            switch error as? GitHubFailure {
            case .resourceDenied,.scopeRequired,.organizationRestricted:unavailable[section]="Your account cannot read this section. Check repository permissions or organization access."
            case .rateLimited:unavailable[section]="This section could not refresh because GitHub limited requests."
            default:unavailable[section]="This section could not refresh. Retry after checking connectivity."
            }
            return fallback
        }
    }
    private func configuredProduction() throws -> Set<String> {
        Set((try database.applicationSetting(.productionEnvironments) ?? "").split(separator:",").map { $0.trimmingCharacters(in:.whitespaces).lowercased() })
    }
    private func mutation(repository:Repository,intent:ActionsIntent,provider:GitHubActionsProvider) throws -> (path:String,body:Data?) {
        let base=try provider.base(repository)
        switch intent {
        case .dispatch(let workflow,let schema,let inputs,_):
            // Environments were validated in both admission passes; serialization preserves type strings.
            let environments=inputs.values.compactMap { if case .environment(let name)=$0 { return name };return nil } + schema.defaults.values.compactMap { if case .environment(let name)=$0 { return name };return nil }
            let values=try schema.validate(inputs,environments:environments)
            return (base+"/actions/workflows/\(workflow.id)/dispatches",try JSONSerialization.data(withJSONObject:["ref":schema.ref,"inputs":values]))
        case .rerunAll(let id,_):return (base+"/actions/runs/\(id)/rerun",nil)
        case .rerunFailed(let id,_):return (base+"/actions/runs/\(id)/rerun-failed-jobs",nil)
        case .cancel(let id,_):return (base+"/actions/runs/\(id)/cancel",nil)
        case .approveFork(let id,_):return (base+"/actions/runs/\(id)/approve",nil)
        case .deployment(let id,_,let ids,let approve,let comment,_):return (base+"/actions/runs/\(id)/pending_deployments",try JSONSerialization.data(withJSONObject:["environment_ids":ids,"state":approve ? "approved":"rejected","comment":comment]))
        }
    }
    public func reconcile(_ id:UUID) async throws -> ActionsWriteOperation {
        let store=try ActionsStore(database:database)
        guard var operation=try store.operation(id) else { throw ActionsFailure.unavailable }
        guard [.sending,.uncertain,.accepted].contains(operation.state) else { return operation }
        guard try await activeAccount()==operation.repository.key.account else { throw ActionsFailure.accountChanged }
        let (ticket,provider)=try await provider(operation.repository)
        do {
            var confirmed=false
            switch operation.intent {
            case .dispatch:
                // A time/ref match alone cannot distinguish another client dispatch. Keep unknown receipts blocked.
                confirmed=false
            case .rerunAll(let id,let attempt),.rerunFailed(let id,let attempt):confirmed=try await provider.run(repository:operation.repository,id:id).attempt>attempt
            case .cancel(let id,let attempt):confirmed=try await provider.run(repository:operation.repository,id:id,attempt:attempt).conclusion=="cancelled"
            case .approveFork(let id,let attempt):let run=try await provider.run(repository:operation.repository,id:id,attempt:attempt);confirmed=run.status=="queued" || run.status=="in_progress" || run.status=="completed" && run.conclusion != "action_required"
            case .deployment:confirmed=false // Disappearance does not prove which reviewer approved or rejected it.
            }
            try await current(ticket)
            if confirmed { let previous=operation.state;operation.state = .confirmed;try store.update(operation,from:previous) }
            return operation
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
}
