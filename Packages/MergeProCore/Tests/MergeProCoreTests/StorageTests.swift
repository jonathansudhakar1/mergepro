import Foundation
import XCTest
import GRDB
@testable import MergeProCore

final class StorageTests: XCTestCase {
    private func payloadContents(in directory: URL) throws -> [String] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
        var contents: [String] = []
        for case let file as URL in files where file.pathExtension == "payload" {
            contents.append(try String(contentsOf: file, encoding: .utf8))
        }
        return contents.sorted()
    }
    private func scope(_ id: String = "personal") -> AccountScope {
        AccountScope(host: "github.com", accountID: id)
    }
    private func key(_ id: String = "personal", object: String = "42") -> ProviderKey {
        ProviderKey(host: "github.com", accountID: id, repositoryID: "repo", objectID: object)
    }
    private func seed(_ store: DatabaseStore, id: String = "personal") throws {
        try store.saveAccount(Account(scope: scope(id), login: id, tokenReference: "keychain-\(id)"))
        try store.saveRepository(Repository(key: key(id).repository, name: "org/repo", isPrivate: true,
                                            capabilities: id == "personal" ? [.readPullRequests, .merge] : [.readPullRequests]))
    }
    private func pullRequest(_ id: String = "personal", title: String = "Fix") -> PullRequest {
        PullRequest(key: key(id), headRevision: RevisionID("sha-one"), title: title, state: .open, isDraft: false)
    }

    func testReauthorizationPurgesOnlyPrivatePayloadsAndRetainsSetupAndDrafts() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        try seed(store); try seed(store,id:"work")
        let cache = try CacheStore(directory:directory.appendingPathComponent("cache"), database:store)
        let personal = PayloadKey(object:key(), revision:RevisionID("sha"), kind:.diff)
        let work = PayloadKey(object:key("work"), revision:RevisionID("sha"), kind:.diff)
        try await cache.put(Data("private".utf8),for:personal)
        try await cache.put(Data("work".utf8),for:work)
        try store.setTracked(key().repository, tracked:true)
        try store.setPinned(key(),pinned:true)
        try store.saveDraft(Draft(id:UUID(), key:key(), revision:RevisionID("sha"), body:"keep unsent"))
        let before = try store.snapshot(for:scope())
        try await cache.invalidatePrivatePayloads(for:scope())
        let removed = try await cache.data(for:personal); XCTAssertNil(removed)
        let retained = try await cache.data(for:work); XCTAssertEqual(retained,Data("work".utf8))
        XCTAssertEqual(try store.snapshot(for:scope()),before)
        XCTAssertEqual(try payloadContents(in:directory.appendingPathComponent("cache")),["work"])
    }
    // Missing account fields in any SQL key would collide or expose the stronger permission.
    func testKeysDifferingOnlyByAccountPersistIndependently() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try DatabaseStore(path: path)
        try seed(store); try seed(store, id: "work")
        try store.savePullRequests([pullRequest(), pullRequest("work", title: "Work")])
        let personal = try store.snapshot(for: scope())
        let work = try store.snapshot(for: scope("work"))
        XCTAssertEqual(personal.pullRequests.map(\.title), ["Fix"])
        XCTAssertEqual(work.pullRequests.map(\.title), ["Work"])
        XCTAssertTrue(personal.repositories[0].capabilities.contains(.merge))
        XCTAssertFalse(work.repositories[0].capabilities.contains(.merge))
        let reopened = try DatabaseStore(path: path)
        XCTAssertEqual(try reopened.snapshot(for: scope("work")), work)
    }

    // A failing migration must roll back its DDL and data and retain the previous schema.
    func testMigrationFailureRollsBackSchemaAndData() throws {
        let directory = try makeTemporaryDirectory()
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("store.sqlite").path)
        var migrator = Migrations.migrator()
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO accounts (host, accountID, login, tokenReference) VALUES ('github.com', 'personal', 'before', NULL)")
        }
        let appliedBefore = try queue.read { try migrator.appliedMigrations($0) }
        enum Failure: Error { case expected }
        migrator.registerMigration("deliberately-failing") { db in
            try db.execute(sql: "CREATE TABLE temporaryMigrationData (value TEXT)")
            try db.execute(sql: "UPDATE accounts SET login = 'damaged'")
            throw Failure.expected
        }
        XCTAssertThrowsError(try migrator.migrate(queue))
        try queue.read { db in
            XCTAssertFalse(try db.tableExists("temporaryMigrationData"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT login FROM accounts"), "before")
            XCTAssertEqual(try migrator.appliedMigrations(db), appliedBefore)
        }
    }

    // Payload eviction must be global LRU, and a read must refresh recency.
    func testCacheEvictsLeastRecentlyUsedAcrossAccounts() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store); try seed(store, id: "work")
        let cache = try CacheStore(directory: directory.appendingPathComponent("payloads"), database: store, maximumBytes: 8)
        let first = PayloadKey(object: key(), revision: RevisionID("one"), kind: .diff)
        let second = PayloadKey(object: key("work"), revision: RevisionID("one"), kind: .diff)
        let third = PayloadKey(object: key(), revision: RevisionID("two"), kind: .diff)
        try await cache.put(Data("1111".utf8), for: first)
        try await cache.put(Data("2222".utf8), for: second)
        let firstData = try await cache.data(for: first)
        XCTAssertEqual(firstData, Data("1111".utf8))
        try await cache.put(Data("3333".utf8), for: third)
        let secondData = try await cache.data(for: second)
        let thirdData = try await cache.data(for: third)
        let usage = try await cache.diskUsage()
        XCTAssertNil(secondData)
        XCTAssertEqual(thirdData, Data("3333".utf8))
        XCTAssertLessThanOrEqual(usage, 8)
    }

    // Pinning protects metadata only; an oversized pinned payload cannot bypass the budget.
    func testEvictionPreservesDraftsSettingsPinsAndTrackedScope() async throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try DatabaseStore(path: path)
        try seed(store)
        let draft = Draft(key: key(), revision: RevisionID("one"), body: "Unsent private comment")
        try store.saveDraft(draft)
        try store.setTracked(key().repository, tracked: true)
        try store.setPinned(key(), pinned: true)
        try store.setSetting("squash", for: "mergeMethod", account: scope())
        let cache = try CacheStore(directory: directory.appendingPathComponent("payloads"), database: store, maximumBytes: 4)
        try await cache.put(Data("1111".utf8), for: PayloadKey(object: key(), revision: RevisionID("one"), kind: .diff))
        try await cache.put(Data("2222".utf8), for: PayloadKey(object: key(), revision: RevisionID("two"), kind: .diff))
        let reopened = try DatabaseStore(path: path)
        let snapshot = try reopened.snapshot(for: scope())
        XCTAssertEqual(snapshot.drafts, [draft])
        XCTAssertEqual(snapshot.settings, ["mergeMethod": "squash"])
        XCTAssertEqual(snapshot.pins, [key()])
        XCTAssertEqual(snapshot.trackedRepositories, [key().repository])
    }

    // Removal must purge credentials and private caches for exactly one account, retaining drafts.
    func testAccountRemovalPurgesOnlyItsCredentialAndPayloadsPreservingDraft() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store); try seed(store, id: "work")
        try store.savePullRequests([pullRequest(), pullRequest("work")])
        let draft = Draft(key: key(), revision: RevisionID("one"), body: "Never post this automatically")
        try store.saveDraft(draft)
        let cache = try CacheStore(directory: directory.appendingPathComponent("payloads"), database: store)
        let personal = PayloadKey(object: key(), revision: RevisionID("one"), kind: .blob)
        let work = PayloadKey(object: key("work"), revision: RevisionID("one"), kind: .blob)
        try await cache.put(Data("personal secret".utf8), for: personal)
        try await cache.put(Data("work secret".utf8), for: work)
        let credentialMarker = directory.appendingPathComponent("credential-deleted.txt")
        try await cache.removeAccount(scope()) { reference in
            try Data(reference.utf8).write(to: credentialMarker)
        }
        XCTAssertEqual(try String(contentsOf: credentialMarker, encoding: .utf8), "keychain-personal")
        XCTAssertEqual(try payloadContents(in: directory.appendingPathComponent("payloads")), ["work secret"])
        let removed = try store.snapshot(for: scope())
        XCTAssertNil(removed.account)
        XCTAssertTrue(removed.repositories.isEmpty)
        XCTAssertTrue(removed.pullRequests.isEmpty)
        XCTAssertEqual(removed.drafts, [draft])
        let personalData = try await cache.data(for: personal)
        let workData = try await cache.data(for: work)
        XCTAssertNil(personalData)
        XCTAssertEqual(workData, Data("work secret".utf8))
        XCTAssertEqual(try store.snapshot(for: scope("work")).pullRequests.count, 1)
    }

    // Mixed valid/invalid writes must not leave half a normalized response committed.
    func testPullRequestBatchRollsBackOnForeignAccount() throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store)
        XCTAssertThrowsError(try store.savePullRequests([pullRequest(), pullRequest("missing")]))
        XCTAssertTrue(try store.snapshot(for: scope()).pullRequests.isEmpty)
    }

    func testRevisionAddressedPayloadCannotBeOverwrittenOrExceedBudget() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store)
        let cache = try CacheStore(directory: directory.appendingPathComponent("payloads"), database: store, maximumBytes: 4)
        let payload = PayloadKey(object: key(), revision: RevisionID("immutable"), kind: .blob)
        try await cache.put(Data("1234".utf8), for: payload)
        do {
            try await cache.put(Data("5678".utf8), for: payload)
            XCTFail("Immutable revision was overwritten")
        } catch { XCTAssertEqual(error as? StorageError, .revisionConflict) }
        do {
            try await cache.put(Data("oversized".utf8), for: PayloadKey(object: key(), revision: RevisionID("big"), kind: .blob))
            XCTFail("Oversized payload was stored")
        } catch { XCTAssertEqual(error as? StorageError, .payloadExceedsBudget) }
        let original = try await cache.data(for: payload)
        XCTAssertEqual(original, Data("1234".utf8))
    }

    func testReopenPrunesOrphanPayloadsAndEnforcesReducedBudget() async throws {
        let directory = try makeTemporaryDirectory()
        let cacheDirectory = directory.appendingPathComponent("payloads")
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try DatabaseStore(path: path)
        try seed(store)
        let first = PayloadKey(object: key(), revision: RevisionID("one"), kind: .log)
        let second = PayloadKey(object: key(), revision: RevisionID("two"), kind: .log)
        let cache = try CacheStore(directory: cacheDirectory, database: store, maximumBytes: 8)
        try await cache.put(Data("1111".utf8), for: first)
        try await cache.put(Data("2222".utf8), for: second)
        let orphan = cacheDirectory.appendingPathComponent("orphan.payload")
        try Data("orphan".utf8).write(to: orphan)
        let interruptedWrite = cacheDirectory.appendingPathComponent("interrupted.pending")
        try Data("partial write".utf8).write(to: interruptedWrite)
        // A process killed mid-write leaves no clean marker; only then does reopening scan the folder.
        try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(CacheStore.cleanMarkerName))
        let reopened = try CacheStore(directory: cacheDirectory, database: DatabaseStore(path: path), maximumBytes: 4)
        // Reconciliation is deferred off the open, but always precedes the first payload operation.
        let firstData = try await reopened.data(for: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedWrite.path))
        let secondData = try await reopened.data(for: second)
        XCTAssertNil(firstData)
        XCTAssertEqual(secondData, Data("2222".utf8))
        let usage = try await reopened.diskUsage()
        XCTAssertEqual(usage, 4)
    }

    func testCredentialDeletionFailureDoesNotReportAccountRemoved() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store)
        let cache = try CacheStore(directory: directory.appendingPathComponent("payloads"), database: store)
        enum CredentialFailure: Error { case denied }
        do {
            try await cache.removeAccount(scope()) { _ in throw CredentialFailure.denied }
            XCTFail("Credential failure was swallowed")
        } catch { XCTAssertTrue(error is CredentialFailure) }
        XCTAssertNotNil(try store.snapshot(for: scope()).account)
    }

    func testRemovedAccountCannotPopulatePayloadCache() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store)
        let cache = try CacheStore(directory: directory.appendingPathComponent("payloads"), database: store)
        try await cache.removeAccount(scope()) { _ in }
        do {
            try await cache.put(Data("secret".utf8), for: PayloadKey(object: key(), revision: RevisionID("one"), kind: .blob))
            XCTFail("Removed account stored private payload")
        } catch { XCTAssertEqual(error as? StorageError, .accountMissing(scope())) }
        let usage = try await cache.diskUsage()
        XCTAssertEqual(usage, 0)
    }


    func testBackgroundObservationEmitsCommittedTrackedScope() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store)
        var iterator = store.snapshots(for: scope()).makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.trackedRepositories, [])
        try store.setTracked(key().repository, tracked: true)
        let changed = try await iterator.next()
        XCTAssertEqual(changed?.trackedRepositories, [key().repository])
    }

    func testDraftIdentifierCannotBeReassignedAcrossAccounts() throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store); try seed(store, id: "work")
        let original = Draft(key: key(), revision: RevisionID("one"), body: "private")
        try store.saveDraft(original)
        let collision = Draft(id: original.id, key: key("work"), revision: RevisionID("one"), body: "wrong account")
        XCTAssertThrowsError(try store.saveDraft(collision)) { error in
            XCTAssertEqual(error as? StorageError, .draftIdentityConflict)
        }
        XCTAssertEqual(try store.snapshot(for: scope()).drafts, [original])
        XCTAssertTrue(try store.snapshot(for: scope("work")).drafts.isEmpty)
    }

    func testMetadataUpdatesAndRemovalStayScoped() throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store); try seed(store, id: "work")
        try store.setTracked(key().repository, tracked: true)
        try store.setTracked(key("work").repository, tracked: true)
        try store.setPinned(key(), pinned: true)
        try store.setPinned(key("work"), pinned: true)
        try store.setSetting("merge", for: "method", account: scope())
        try store.setSetting("squash", for: "method", account: scope())
        try store.setTracked(key().repository, tracked: false)
        try store.setPinned(key(), pinned: false)
        let personal = try store.snapshot(for: scope())
        let work = try store.snapshot(for: scope("work"))
        XCTAssertTrue(personal.trackedRepositories.isEmpty)
        XCTAssertTrue(personal.pins.isEmpty)
        XCTAssertEqual(personal.settings, ["method": "squash"])
        XCTAssertEqual(work.trackedRepositories, [key("work").repository])
        XCTAssertEqual(work.pins, [key("work")])
        XCTAssertTrue(work.settings.isEmpty)
    }


    func testRelaunchEnumeratesAccountsWithoutKnowingTheirIDs() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try DatabaseStore(path: path)
        try seed(store); try seed(store, id: "work")
        let reopened = try DatabaseStore(path: path)
        let accounts = try reopened.accounts()
        XCTAssertEqual(accounts.map(\.scope), [scope(), scope("work")])
        XCTAssertEqual(accounts.map(\.tokenReference), ["keychain-personal", "keychain-work"])
    }


    private func detailed(_ id: String = "personal", repo: String = "repo", object: String, state: PullRequest.State, updated: Double, head: String = "sha-one") -> PullRequest {
        let key = ProviderKey(host: "github.com", accountID: id, repositoryID: repo, objectID: object)
        var m = PRMetadata(number: Int(object) ?? 1, webURL: URL(string: "https://github.com/org/\(repo)/pull/\(object)")!, repositoryName: "org/\(repo)")
        m.updatedAt = Date(timeIntervalSince1970: updated)
        if state == .open { var e = MergeEvidence(key: key, head: head, base: "b", branch: "main", fetchedAt: Date(timeIntervalSince1970: 1)); e.open = true; e.draft = false; m.mergeEvidence = e }
        return PullRequest(key: key, headRevision: RevisionID(head), title: "PR \(object)", state: state, isDraft: false, metadata: m)
    }

    // Targeted lookups answer exactly what the whole-account snapshot answers, per account.
    func testTargetedLookupsMatchSnapshotAndStayAccountScoped() throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store); try seed(store, id: "work")
        try store.saveRepository(Repository(key: RepositoryKey(account: scope(), repositoryID: "other"), name: "org/other", isPrivate: false, capabilities: [.readPullRequests]))
        let rows = [detailed(object: "1", state: .open, updated: 30), detailed(object: "2", state: .merged, updated: 50), detailed(object: "3", state: .closed, updated: 10),
                    detailed(repo: "other", object: "4", state: .merged, updated: 40), detailed("work", object: "1", state: .open, updated: 99, head: "work-head")]
        try store.savePullRequests(rows)
        try store.setTracked(key().repository, tracked: true)
        try store.setPinned(key(object: "2"), pinned: true)
        try store.setSetting("true", for: "authorizationProblem", account: scope("work"))
        try store.setSetting("squash", for: "mergeMethod", account: scope())
        let snapshot = try store.snapshot(for: scope())
        XCTAssertEqual(try store.setting("mergeMethod", account: scope()), "squash")
        XCTAssertNil(try store.setting("authorizationProblem", account: scope()))
        XCTAssertEqual(try store.setting("authorizationProblem", account: scope("work")), "true")
        XCTAssertEqual(try store.settings(account: scope()), snapshot.settings)
        for pr in snapshot.pullRequests { XCTAssertEqual(try store.pullRequest(for: pr.key), pr) }
        XCTAssertNil(try store.pullRequest(for: key(object: "missing")))
        XCTAssertNil(try store.pullRequest(for: ProviderKey(host: "github.com", accountID: "work", repositoryID: "repo", objectID: "2")))
        XCTAssertTrue(try store.pullRequestExists(rows[0].key, headSHA: "sha-one"))
        XCTAssertFalse(try store.pullRequestExists(rows[0].key, headSHA: "work-head"))
        XCTAssertFalse(try store.pullRequestExists(ProviderKey(host: "github.com", accountID: "work", repositoryID: "repo", objectID: "2"), headSHA: "sha-one"))
        XCTAssertEqual(try store.pullRequests(repository: key().repository), snapshot.pullRequests.filter { $0.key.repositoryID == "repo" })
        XCTAssertEqual(try store.pullRequests(repository: key().repository, states: [.merged, .closed]).map(\.key.objectID), ["2", "3"])
        XCTAssertEqual(try store.pullRequests(repositories: [key().repository, RepositoryKey(account: scope(), repositoryID: "other")]), snapshot.pullRequests)
        XCTAssertEqual(try store.pullRequests(account: scope()).map(\.key.objectID), ["2", "4", "1", "3"])
        XCTAssertEqual(try store.pullRequests(account: scope(), states: [.merged], limit: 1).map(\.key.objectID), ["2"])
        XCTAssertEqual(try store.pullRequests(account: scope(), states: [.open]), snapshot.pullRequests.filter { $0.state == .open })
        XCTAssertEqual(try store.pullRequests(account: scope("work")).map(\.headRevision.rawValue), ["work-head"])
        XCTAssertEqual(try store.repositories(account: scope()), snapshot.repositories)
        XCTAssertEqual(try store.repository(RepositoryKey(account: scope(), repositoryID: "other"))?.name, "org/other")
        XCTAssertNil(try store.repository(RepositoryKey(account: scope("work"), repositoryID: "other")))
        XCTAssertEqual(try store.trackedRepositories(account: scope()), snapshot.trackedRepositories)
        XCTAssertTrue(try store.trackedRepositories(account: scope("work")).isEmpty)
        XCTAssertEqual(try store.pins(account: scope()), snapshot.pins)
        XCTAssertTrue(try store.pins(account: scope("work")).isEmpty)
    }

    // Indexed columns follow every later write of the same row, including state and head changes.
    func testIndexedPullRequestColumnsFollowUpserts() throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store)
        let open = detailed(object: "1", state: .open, updated: 10)
        try store.savePullRequests([open])
        try store.savePullRequests([detailed(object: "1", state: .closed, updated: 20, head: "sha-two")])
        XCTAssertTrue(try store.pullRequests(account: scope(), states: [.open]).isEmpty)
        XCTAssertEqual(try store.pullRequests(account: scope(), states: [.closed]).map(\.headRevision.rawValue), ["sha-two"])
        XCTAssertFalse(try store.pullRequestExists(open.key, headSHA: "sha-one"))
        XCTAssertTrue(try store.pullRequestExists(open.key, headSHA: "sha-two"))
        try store.confirmWrite(detailed(object: "1", state: .merged, updated: 30, head: "sha-two"))
        XCTAssertEqual(try store.pullRequests(repository: key().repository, states: [.merged]).count, 1)
    }

    // The merge-operation overlay seen by the board is identical for a single-row lookup.
    func testPullRequestLookupAppliesActiveOperationOverlay() throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store); try seed(store, id: "work")
        let mine = detailed(object: "1", state: .open, updated: 1), theirs = detailed("work", object: "1", state: .open, updated: 1)
        try store.savePullRequests([mine, theirs])
        let operation = PRWriteOperation(command: .init(key: mine.key, repository: "org/repo", number: 1, revision: .init(head: "sha-one", origin: "b", target: "b"), intent: .review(.approve, "")))
        try DraftReviewStore(database: store).prepare(operation)
        let overlaid = try XCTUnwrap(store.pullRequest(for: mine.key))
        XCTAssertEqual(overlaid.metadata?.mergeEvidence?.operationInProgress, true)
        XCTAssertEqual(overlaid, try store.snapshot(for: scope()).pullRequests.first)
        XCTAssertEqual(try store.pullRequests(repository: key().repository), [overlaid])
        XCTAssertEqual(try store.pullRequest(for: theirs.key)?.metadata?.mergeEvidence?.operationInProgress, false)
        XCTAssertEqual(try store.reviewOperation(id: operation.id)?.state, .prepared)
        XCTAssertNil(try store.reviewOperation(id: UUID()))
    }

    // Existing v7 databases gain lookup columns/indexes derived from their stored JSON.
    func testMigrationFromV7BackfillsLookupColumnsAndIndexes() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try Migrations.migrator().migrate(queue, upTo: "v7-actions-repository-browser")
        let legacy = detailed(object: "7", state: .merged, updated: 1_700_000_000, head: "legacy-head")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO accounts VALUES ('github.com','personal','personal','keychain-personal')")
            try db.execute(sql: "INSERT INTO repositories VALUES ('github.com','personal','repo',?)", arguments: [try JSONEncoder().encode(Repository(key: key().repository, name: "org/repo", isPrivate: true, capabilities: [.readPullRequests]))])
            try db.execute(sql: "INSERT INTO pullRequests VALUES ('github.com','personal','repo','7',?)", arguments: [try JSONEncoder().encode(legacy)])
            try db.execute(sql: "INSERT INTO pullRequests VALUES ('github.com','personal','repo','8',?)", arguments: [try JSONEncoder().encode(PullRequest(key: key(object: "8"), headRevision: RevisionID("v1"), title: "v1 payload", state: .open, isDraft: false))])
            try db.execute(sql: "INSERT INTO pollResponses VALUES ('github.com','personal','https://api.github.com/repos/org/repo/notifications?all=true&per_page=50',NULL,NULL,x'5B5D',NULL)")
            try db.execute(sql: "INSERT INTO pollResponses VALUES ('github.com','personal','https://api.github.com/repos/org/repo/actions/runs',NULL,NULL,x'5B5D',NULL)")
        }
        try queue.close()
        let store = try DatabaseStore(path: path)
        XCTAssertEqual(try store.pullRequest(for: legacy.key), legacy)
        XCTAssertTrue(try store.pullRequestExists(legacy.key, headSHA: "legacy-head"))
        XCTAssertEqual(try store.pullRequests(account: scope(), states: [.open]).map(\.title), ["v1 payload"])
        XCTAssertEqual(try store.pullRequests(account: scope()).map(\.key.objectID), ["7", "8"])
        let reopened = try DatabaseQueue(path: path)
        try reopened.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT state, headSHA, updatedAt FROM pullRequests WHERE objectID='7'"))
            XCTAssertEqual(row["state"] as String?, "merged")
            XCTAssertEqual(row["headSHA"] as String?, "legacy-head")
            XCTAssertEqual(row["updatedAt"] as Double?, Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate)
            XCTAssertNil(try Double.fetchOne(db, sql: "SELECT updatedAt FROM pullRequests WHERE objectID='8'"))
            for index in ["pullRequests_repository_state", "pullRequests_account_state_updated", "reviewOperations_state"] {
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND name=?", arguments: [index]), index)
            }
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT json FROM pullRequests WHERE host=? AND accountID=? AND state IN ('open')", arguments: ["github.com", "personal"]).map { $0["detail"] as String }.joined()
            XCTAssertTrue(plan.contains("pullRequests_account_state_updated") || plan.contains("pullRequests_repository_state"), plan)
            let opsPlan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT json FROM reviewOperations WHERE \(Migrations.reviewOperationState) IN ('prepared','sending','uncertain')").map { $0["detail"] as String }.joined()
            XCTAssertTrue(opsPlan.contains("reviewOperations_state"), opsPlan)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT COALESCE(feature,'-') FROM pollResponses ORDER BY url"), ["-", "github-notification-signals"])
        }
    }

    // One corrupt ledger row must not make the state index (and so the database) fail to open.
    func testV7DatabaseWithMalformedLedgerRowMigratesAndOpens() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try Migrations.migrator().migrate(queue, upTo: "v7-actions-repository-browser")
        let pr = detailed(object: "pull-request:7", state: .open, updated: 1_700_000_000)
        var active = PRWriteOperation(command: PRWriteCommand(key: pr.key, repository: "org/repo", number: 7, revision: PRWriteRevision(head: "sha-one", origin: "b", target: "b"), intent: .review(.approve, "LGTM")))
        active.state = .sending
        try queue.write { db in
            try db.execute(sql: "INSERT INTO accounts VALUES ('github.com','personal','personal','keychain-personal')")
            try db.execute(sql: "INSERT INTO repositories VALUES ('github.com','personal','repo',?)", arguments: [try JSONEncoder().encode(Repository(key: key().repository, name: "org/repo", isPrivate: true, capabilities: [.readPullRequests]))])
            try db.execute(sql: "INSERT INTO pullRequests VALUES ('github.com','personal','repo','pull-request:7',?)", arguments: [try JSONEncoder().encode(pr)])
            try db.execute(sql: "INSERT INTO reviewOperations VALUES (?,?,?)", arguments: [UUID().uuidString, "corrupt", Data("{\"state\":\"sending\",".utf8)])
            try db.execute(sql: "INSERT INTO reviewOperations VALUES (?,?,?)", arguments: [UUID().uuidString, "text", "not json at all"])
            try db.execute(sql: "INSERT INTO reviewOperations VALUES (?,?,?)", arguments: [active.id.uuidString, "valid", try JSONEncoder().encode(active)])
        }
        try queue.close()
        let store = try DatabaseStore(path: path)
        XCTAssertEqual(try store.pullRequest(for: pr.key)?.title, pr.title)
        XCTAssertEqual(try store.database.read { try DatabaseStore.activeReservations($0) }, [pr.key], "valid active rows are still found; corrupt rows are skipped")
        try store.database.read { db in
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT json FROM reviewOperations WHERE \(Migrations.reviewOperationState) IN ('prepared','sending','uncertain')").map { $0["detail"] as String }.joined()
            XCTAssertTrue(plan.contains("reviewOperations_state"), plan)
        }
    }

    // Revocation keeps account-partitioned feed validators but purges other cached response bodies.
    func testPrivatePayloadInvalidationPurgesNonFeedPollResponses() async throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try DatabaseStore(path: path)
        try seed(store); try seed(store, id: "work")
        let cache = try CacheStore(directory: directory.appendingPathComponent("payloads"), database: store)
        let raw = try DatabaseQueue(path: path)
        try await raw.write { db in
            for id in ["personal", "work"] {
                try db.execute(sql: "INSERT INTO pollResponses(host,accountID,url,body,feature) VALUES ('github.com',?,'feed',x'00','github-notification-signals')", arguments: [id])
                try db.execute(sql: "INSERT INTO pollResponses(host,accountID,url,body,feature) VALUES ('github.com',?,'actions',x'00','github-actions')", arguments: [id])
                try db.execute(sql: "INSERT INTO pollResponses(host,accountID,url,body,feature) VALUES ('github.com',?,'unknown',x'00',NULL)", arguments: [id])
            }
        }
        try await cache.invalidatePrivatePayloads(for: scope())
        let remaining = try await raw.read { try String.fetchAll($0, sql: "SELECT accountID || ':' || url FROM pollResponses ORDER BY accountID, url") }
        XCTAssertEqual(remaining, ["personal:feed", "work:actions", "work:feed", "work:unknown"])
        let polls = PollCycleStore(database: store)
        XCTAssertEqual(try polls.responses(account: scope("work"), feature: "github-actions").keys.sorted(), ["actions"])
        XCTAssertEqual(try polls.responses(account: scope("work")).count, 3)
    }

    // Poll work items read only their scope instead of decoding the whole account.
    func testPollStoreScopedReadsMatchWholeAccountReads() throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path: directory.appendingPathComponent("store.sqlite").path)
        try seed(store); try seed(store, id: "work")
        try store.saveRepository(Repository(key: RepositoryKey(account: scope(), repositoryID: "other"), name: "org/other", isPrivate: false, capabilities: [.readPullRequests]))
        try store.savePullRequests([detailed(object: "1", state: .open, updated: 1), detailed(repo: "other", object: "2", state: .merged, updated: 2), detailed("work", object: "3", state: .open, updated: 3)])
        let polls = PollCycleStore(database: store)
        let all = try polls.pullRequests(account: scope())
        XCTAssertEqual(all, try store.snapshot(for: scope()).pullRequests)
        XCTAssertEqual(try polls.pullRequests(repositories: [key().repository]), all.filter { $0.key.repositoryID == "repo" })
        XCTAssertEqual(try polls.repositoryMetadata(account: scope()).keys.map(\.repositoryID).sorted(), ["other", "repo"])
    }

    // Startup must not scan payload files; after a crash the first payload operation still prunes its leftovers.
    func testCacheReconciliationIsDeferredButPrecedesFirstPayloadOperation() async throws {
        let directory = try makeTemporaryDirectory()
        let cacheDirectory = directory.appendingPathComponent("payloads")
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try DatabaseStore(path: path)
        try seed(store)
        let kept = PayloadKey(object: key(), revision: RevisionID("kept"), kind: .blob)
        let first = try CacheStore(directory: cacheDirectory, database: store)
        try await first.put(Data("kept".utf8), for: kept)
        let orphan = cacheDirectory.appendingPathComponent("orphan.payload"), pending = cacheDirectory.appendingPathComponent("crash.pending")
        try Data("orphan".utf8).write(to: orphan); try Data("partial".utf8).write(to: pending)
        // A process killed mid-write leaves no clean marker; only then does reopening scan the folder.
        try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(CacheStore.cleanMarkerName))
        let reopened = try CacheStore(directory: cacheDirectory, database: DatabaseStore(path: path), reconcileInBackground: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "init must not scan payload files")
        let data = try await reopened.data(for: kept)
        XCTAssertEqual(data, Data("kept".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testDatabaseFileIsPrivateToLocalUser() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try DatabaseStore(path: path)
        try seed(store)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

}
