import Foundation

/// Feature collaborator; all credentials, write admission and rate accounting use existing owners.
public struct NotificationThreadCoordinator:Sendable {
    private let database:DatabaseStore
    private let session:GitHubAccountSession
    private let budget:RateBudget
    private let clientID:String
    private let activeAccount:@Sendable () async throws -> AccountScope?
    public init(database:DatabaseStore,session:GitHubAccountSession,budget:RateBudget,clientID:String,activeAccount:@escaping @Sendable () async throws -> AccountScope?) {
        self.database=database;self.session=session;self.budget=budget;self.clientID=clientID;self.activeAccount=activeAccount
    }
    public func perform(_ command:NotificationThreadCommand) async throws -> NotificationThreadOperation {
        guard try await activeAccount() == command.account else { throw NotificationThreadFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:command.account,clientID:clientID)
        try capability(command,ticket.credential)
        var operation=NotificationThreadOperation(command:command)
        try database.prepareNotificationThread(operation)
        do {
            _ = try await read(command,ticket:ticket)
            let prepared=operation
            let writer=await session.featureWriteClient(account:command.account,budget:budget) {
                guard try await activeAccount() == command.account else { throw NotificationThreadFailure.accountChanged }
                guard try await session.withCurrentWriteOperation(ticket,body:{ db in
                    var sending=prepared;sending.state = .sending
                    try db.updateNotificationThread(sending,expected:.prepared)
                }) else { throw NotificationThreadFailure.accountChanged }
            }
            let response=try await writer.mutate(path:path(command),method:command.intent == .read ? "PATCH" : "DELETE",body:nil,token:ticket.credential.accessToken,acceptedStatuses:command.intent == .read ? [304] : [])
            operation=try database.notificationThreadOperation(operation.id) ?? operation
            let expected=operation.state
            operation.response=response.data.count <= 8_000_000 ? response.data : nil
            let confirmed=response.status == (command.intent == .read ? 205 : 204)
            operation.state=confirmed ? .confirmed : .uncertain
            operation.message=confirmed ? "Provider-confirmed \(command.intent.rawValue)" : "Provider response did not confirm the requested notification state."
            let receipt=operation
            guard try await session.withCurrentOperation(ticket,body:{ db in try db.updateNotificationThread(receipt,expected:expected) }) else { throw NotificationThreadFailure.accountChanged }
            if !confirmed { return try await reconcile(operation.id) }
            return operation
        } catch {
            await session.featureFailed(error,operation:ticket)
            guard var saved=try database.notificationThreadOperation(operation.id) else { throw error }
            guard [.prepared,.sending,.uncertain].contains(saved.state) else { return saved }
            let expected=saved.state
            // Only a denial from the actual mutation is definitely unsent/rejected.
            // Reconciliation read failures below never erase possible prior dispatch.
            let denied:Bool
            switch error as? GitHubFailure {
            case .invalidAuthentication,.scopeRequired,.organizationRestricted,.resourceDenied,.rateLimited:denied=true
            default:denied=false
            }
            saved.state = expected == .prepared || denied ? .rejected : .uncertain
            saved.message=error.localizedDescription
            try database.updateNotificationThread(saved,expected:expected)
            if saved.state == .rejected { throw error }
            return saved
        }
    }
    /// Reconciliation reads under the captured account; it never repeats PATCH or DELETE.
    public func reconcile(_ id:UUID) async throws -> NotificationThreadOperation {
        guard var operation=try database.notificationThreadOperation(id) else { throw NotificationThreadFailure.unavailable }
        guard [.sending,.uncertain].contains(operation.state) else { return operation }
        let expected=operation.state
        do {
            let ticket=try await session.authenticatedOperation(for:operation.command.account,clientID:clientID)
            do {
                try capability(operation.command,ticket.credential)
                let thread=try await read(operation.command,ticket:ticket)
                // GET exposes unread, but no documented Done flag. Missing/404 is also
                // not proof of Done: deleted, inaccessible and unsupported are ambiguous.
                operation.state = operation.command.intent == .read && !thread.unread ? .confirmed : .uncertain
                operation.message=operation.state == .confirmed ? "Provider-confirmed read" : "Done/read outcome remains uncertain; no mutation was repeated."
                let result=operation
                guard try await session.withCurrentOperation(ticket,body:{ db in try db.updateNotificationThread(result,expected:expected) }) else { throw NotificationThreadFailure.accountChanged }
                return result
            } catch { await session.featureFailed(error,operation:ticket);throw error }
        } catch {
            if let current=try database.notificationThreadOperation(id),![.sending,.uncertain].contains(current.state) { return current }
            operation.state = .uncertain;operation.message="Read reconciliation unavailable: "+error.localizedDescription
            try database.updateNotificationThread(operation,expected:expected)
            return operation
        }
    }
    private func capability(_ command:NotificationThreadCommand,_ credential:GitHubCredential) throws {
        guard command.account.host == "github.com",!credential.scopes.isDisjoint(with:["repo","notifications"]),
              !["github_pat_","ghu_","ghs_"].contains(where:credential.accessToken.hasPrefix) else { throw NotificationThreadFailure.unsupported }
    }
    private func path(_ command:NotificationThreadCommand) -> String { "notifications/threads/"+command.threadID }
    private struct Thread:Decodable {
        let id:String
        let unread:Bool
        let repository:RepositoryIdentity
        struct RepositoryIdentity:Decodable { let id:Int64 }
    }
    /// User-initiated: preflight and reconciliation reads are interactive, so background polling's
    /// reserve and queue never block marking a notification read or done.
    private func read(_ command:NotificationThreadCommand,ticket:AccountOperation) async throws -> Thread {
        let client=await session.interactiveReadClient(account:command.account,budget:budget)
        let response=try await client.get(client.origin.appendingPathComponent(path(command)),token:ticket.credential.accessToken)
        guard response.status == 200,response.data.count <= 8_000_000 else { throw NotificationThreadFailure.invalidResponse }
        let thread=try JSONDecoder().decode(Thread.self,from:response.data)
        guard thread.id == command.threadID,String(thread.repository.id) == command.repositoryID,
              try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw NotificationThreadFailure.invalidResponse }
        return thread
    }
}
