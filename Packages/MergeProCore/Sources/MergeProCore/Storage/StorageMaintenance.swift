import Foundation
import GRDB

/// Bounded local history. Runs at most once a day, at background priority, a little after the payload
/// cache opens (never on the launch path). Unresolved write-ledger rows and unacknowledged events are
/// never pruned; account removal and credential purges handle everything else that is account-scoped.
enum StorageMaintenance {
    static let interval: TimeInterval = 86_400
    /// Acknowledged inbox events, by when they occurred.
    static let acknowledgedEventRetention: TimeInterval = 30 * 86_400
    /// Closed poll cycles with their failures and notification attempts.
    static let pollHistoryRetention: TimeInterval = 14 * 86_400
    /// Confirmed, posted-outdated and rejected write operations and notification commands.
    static let terminalOperationRetention: TimeInterval = 30 * 86_400
    static let launchDelay: Duration = .seconds(30)
    /// Rows per write transaction, so pollers never wait long behind a first large prune.
    static let batch = 2_000

    static func schedule(_ database: DatabaseStore) {
        Task.detached(priority: .background) { [weak database] in
            try? await Task.sleep(for: launchDelay)
            do { _ = try database?.runStorageMaintenanceIfDue(now: Date()) }
            catch { Log.storage.error("Storage maintenance failed: \(Log.kind(error), privacy: .public)") }
        }
    }
}

struct StorageMaintenanceReport: Equatable, Sendable {
    var events = 0
    var cycles = 0
    var failures = 0
    var attempts = 0
    var reviewOperations = 0
    var notificationOperations = 0
}

extension DatabaseStore {
    /// Runs maintenance unless it already ran within the last day. Returns whether it ran.
    @discardableResult func runStorageMaintenanceIfDue(now: Date) throws -> Bool {
        let last = try database.read { try Double.fetchOne($0, sql: "SELECT lastRun FROM storageMaintenance WHERE id = 1") }
        if let last, (0..<StorageMaintenance.interval).contains(now.timeIntervalSince1970 - last) { return false }
        try runStorageMaintenance(now: now)
        return true
    }

    @discardableResult func runStorageMaintenance(now: Date) throws -> StorageMaintenanceReport {
        var report = StorageMaintenanceReport()
        report.events = try pruneAcknowledgedEvents(occurredBefore: now.addingTimeInterval(-StorageMaintenance.acknowledgedEventRetention))
        let history = now.addingTimeInterval(-StorageMaintenance.pollHistoryRetention).timeIntervalSince1970
        let closedCycles = "SELECT id FROM pollCycles WHERE status <> 'open' AND COALESCE(closedAt, startedAt) < ?"
        report.failures = try batched("DELETE FROM pollFailures WHERE rowid IN (SELECT rowid FROM pollFailures WHERE cycleID IN (\(closedCycles)) LIMIT \(StorageMaintenance.batch))", [history])
        report.attempts = try batched("DELETE FROM notificationAttempts WHERE rowid IN (SELECT rowid FROM notificationAttempts WHERE cycleID IN (\(closedCycles)) LIMIT \(StorageMaintenance.batch))", [history])
        // A cycle still named by a retained inbox event stays (the event's foreign key).
        report.cycles = try batched("""
            DELETE FROM pollCycles WHERE id IN (\(closedCycles)
                AND NOT EXISTS (SELECT 1 FROM changeEvents e WHERE e.cycleID = pollCycles.id) LIMIT \(StorageMaintenance.batch))
            """, [history])
        let terminal = now.addingTimeInterval(-StorageMaintenance.terminalOperationRetention)
        report.reviewOperations = try DraftReviewStore(database: self).pruneTerminalOperations(createdBefore: terminal)
        report.notificationOperations = try pruneTerminalNotificationThreads(closedBefore: terminal)
        try database.write { db in
            try db.execute(sql: "INSERT INTO storageMaintenance VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET lastRun = excluded.lastRun",
                           arguments: [now.timeIntervalSince1970])
        }
        // Pruned rows (and any purge whose checkpoint was busy) leave no frames behind in the WAL.
        scrubWriteAheadLog()
        return report
    }

    /// Repeats one bounded DELETE, one write transaction per batch, until a batch removes fewer rows.
    private func batched(_ sql: String, _ arguments: StatementArguments) throws -> Int {
        var total = 0
        while true {
            let removed = try database.write { db in try db.execute(sql: sql, arguments: arguments); return db.changesCount }
            total += removed
            if removed < StorageMaintenance.batch { return total }
        }
    }

    /// Acknowledged events that occurred before `cutoff`, except one an unresolved notification command
    /// still names. Each repository's pruned horizon is recorded in `changeEventRetention`, whose trigger
    /// ignores a later insert of an event at or before it, so a feed page still listing a pruned thread
    /// cannot bring it back as unread or notify again.
    private func pruneAcknowledgedEvents(occurredBefore cutoff: Date) throws -> Int {
        let commandEventKey = "CASE WHEN json_valid(CAST(o.json AS TEXT)) THEN json_extract(CAST(o.json AS TEXT),'$.command.eventKey') END"
        let select = """
            SELECT eventKey, host, accountID, repositoryID, occurredAt FROM changeEvents
            WHERE acknowledged=1 AND occurredAt < ? AND NOT EXISTS (SELECT 1 FROM notificationThreadOperations o
                WHERE o.host = changeEvents.host AND o.accountID = changeEvents.accountID
                AND o.state IN ('prepared','sending','uncertain') AND \(commandEventKey) = changeEvents.eventKey)
            LIMIT \(StorageMaintenance.batch)
            """
        var total = 0
        while true {
            let removed = try database.write { db in
                let rows = try Row.fetchAll(db, sql: select, arguments: [cutoff.timeIntervalSinceReferenceDate])
                var horizons: [[String]: Double] = [:]
                for row in rows {
                    let scope = [row["host"] as String, row["accountID"] as String, row["repositoryID"] as String]
                    horizons[scope] = max(horizons[scope] ?? -.infinity, row["occurredAt"] as Double)
                    try db.execute(sql: "DELETE FROM changeEvents WHERE eventKey = ?", arguments: [row["eventKey"] as String])
                }
                for (scope, horizon) in horizons {
                    try db.execute(sql: """
                        INSERT INTO changeEventRetention VALUES (?, ?, ?, ?)
                        ON CONFLICT(host, accountID, repositoryID) DO UPDATE SET prunedThrough = max(prunedThrough, excluded.prunedThrough)
                        """, arguments: [scope[0], scope[1], scope[2], horizon])
                }
                return rows.count
            }
            total += removed
            if removed < StorageMaintenance.batch { return total }
        }
    }
}
