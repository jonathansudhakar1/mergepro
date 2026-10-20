import Foundation
import GRDB

public enum NotificationThreadIntent:String,Codable,Sendable { case read,done }
public enum NotificationThreadFailure:Error,LocalizedError,Sendable {
    case unavailable,accountChanged,unsupported,operationInProgress,invalidResponse
    public var errorDescription:String? {
        switch self {
        case .unavailable:"Only a genuine GitHub notification thread can be synchronized."
        case .accountChanged:"Select this notification's account before changing GitHub."
        case .unsupported:"GitHub notifications are unavailable for this host or token capability. Open the GitHub inbox."
        case .operationInProgress:"A notification change needs reconciliation before another command."
        case .invalidResponse:"GitHub returned incomplete notification evidence. The result remains unknown."
        }
    }
}
public struct NotificationThreadCommand:Codable,Sendable,Equatable {
    public let account:AccountScope
    public let threadID:String
    public let eventKey:String
    public let repositoryID:String
    public let intent:NotificationThreadIntent
    public init(event:ChangeEvent,intent:NotificationThreadIntent) throws {
        let prefix="notification-thread:"
        guard event.object.objectID.hasPrefix(prefix) else { throw NotificationThreadFailure.unavailable }
        let id=String(event.object.objectID.dropFirst(prefix.count))
        guard !id.isEmpty,id.utf8.allSatisfy({ (48...57).contains($0) }),id.contains(where:{ $0 != "0" }) else { throw NotificationThreadFailure.unavailable }
        account=event.object.account;threadID=id;eventKey=event.key;repositoryID=event.object.repositoryID;self.intent=intent
    }
}
public struct NotificationThreadOperation:Codable,Sendable,Equatable,Identifiable {
    public enum State:String,Codable,Sendable { case prepared,sending,uncertain,confirmed,rejected }
    public let id:UUID
    public let command:NotificationThreadCommand
    public var state:State = .prepared
    public var response:Data?
    public var message:String?
    public init(command:NotificationThreadCommand) { id=UUID();self.command=command }
}

extension DatabaseStore {
    public func releaseUnsentNotificationThread(_ id:UUID) throws {
        guard var operation=try notificationThreadOperation(id),operation.state == .prepared else { throw NotificationThreadFailure.operationInProgress }
        operation.state = .rejected;operation.message="Unsent command released explicitly; GitHub was unchanged."
        try updateNotificationThread(operation,expected:.prepared)
    }
    public func notificationThreadOperations(account:AccountScope? = nil) throws -> [NotificationThreadOperation] {
        try database.read { db in
            let values: [Data]
            if let account { values=try Data.fetchAll(db,sql:"SELECT json FROM notificationThreadOperations WHERE host=? AND accountID=? ORDER BY rowid",arguments:[account.host,account.accountID]) }
            else { values=try Data.fetchAll(db,sql:"SELECT json FROM notificationThreadOperations ORDER BY rowid") }
            return try values.map { try JSONDecoder().decode(NotificationThreadOperation.self,from:$0) }
        }
    }
    public func notificationThreadOperation(_ id:UUID) throws -> NotificationThreadOperation? {
        try database.read { db in try Self.threadOperation(id,in:db) }
    }
    private static func threadOperation(_ id:UUID,in db:Database) throws -> NotificationThreadOperation? {
        try Data.fetchOne(db,sql:"SELECT json FROM notificationThreadOperations WHERE id=?",arguments:[id.uuidString]).map { try JSONDecoder().decode(NotificationThreadOperation.self,from:$0) }
    }
    func prepareNotificationThread(_ operation:NotificationThreadOperation) throws {
        try database.write { db in
            let c=operation.command
            guard let json=try Data.fetchOne(db,sql:"SELECT json FROM changeEvents WHERE eventKey=?",arguments:[c.eventKey]),
                  let event=try? JSONDecoder().decode(ChangeEvent.self,from:json),
                  try NotificationThreadCommand(event:event,intent:c.intent) == c else { throw NotificationThreadFailure.unavailable }
            guard try !Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM notificationThreadOperations WHERE host=? AND accountID=? AND threadID=? AND state IN ('prepared','sending','uncertain'))",arguments:[c.account.host,c.account.accountID,c.threadID])! else { throw NotificationThreadFailure.operationInProgress }
            try db.execute(sql:"INSERT INTO notificationThreadOperations(id,host,accountID,threadID,state,json) VALUES (?,?,?,?,?,?)",arguments:[operation.id.uuidString,c.account.host,c.account.accountID,c.threadID,operation.state.rawValue,try JSONEncoder().encode(operation)])
        }
    }
    func updateNotificationThread(_ operation:NotificationThreadOperation,expected:NotificationThreadOperation.State) throws {
        try database.write { db in
            guard let old=try Self.threadOperation(operation.id,in:db),old.command == operation.command else { throw NotificationThreadFailure.unavailable }
            if old == operation { return }
            guard old.state == expected,![.confirmed,.rejected].contains(old.state) else { throw NotificationThreadFailure.operationInProgress }
            // Retention of a terminal command starts when it closes; unresolved rows are never pruned.
            let closedAt:Double? = [.confirmed,.rejected].contains(operation.state) ? Date().timeIntervalSince1970 : nil
            try db.execute(sql:"UPDATE notificationThreadOperations SET state=?,json=?,closedAt=? WHERE id=?",arguments:[operation.state.rawValue,try JSONEncoder().encode(operation),closedAt,operation.id.uuidString])
            if operation.state == .confirmed {
                try db.execute(sql:"UPDATE changeEvents SET acknowledged=1 WHERE eventKey=? AND host=? AND accountID=?",arguments:[operation.command.eventKey,operation.command.account.host,operation.command.account.accountID])
            }
        }
    }
    /// Terminal (confirmed/rejected) commands closed before `cutoff`. Prepared, sending and uncertain
    /// commands are kept for as long as the account exists.
    func pruneTerminalNotificationThreads(closedBefore cutoff:Date) throws -> Int {
        try database.write { db in
            try db.execute(sql:"DELETE FROM notificationThreadOperations WHERE state IN ('confirmed','rejected') AND closedAt < ?",arguments:[cutoff.timeIntervalSince1970])
            return db.changesCount
        }
    }
}
