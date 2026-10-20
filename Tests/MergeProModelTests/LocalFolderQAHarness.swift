#if LOCAL_FOLDER_VERIFICATION
import Foundation
@testable import MergeProFixtures

/// Standalone offline verification; compile with SecurityScopedFolderStore.swift.
@main struct LocalFolderVerification {
    @MainActor static func main() async throws {
        let folder = AuthorizedLocalFolder(id: UUID(), name: "Fixture", path: "/tmp/local-fixture", bookmarkData: Data([1]))
        let saved = try JSONEncoder().encode([folder])
        var begins = 0
        var ends = 0
        let store = SecurityScopedFolderStore(load: { saved }, save: { _ in }, access: .init(
            resolve: { _ in (URL(fileURLWithPath: folder.path), false) },
            bookmark: { _ in Data([1]) },
            start: { _ in begins += 1; return true },
            stop: { _ in ends += 1 }))
        try await store.load()
        enum FixtureError: Error { case expected }
        do {
            let _: String = try await store.withAccess(id: folder.id) { _ in throw FixtureError.expected }
            preconditionFailure("Expected failure")
        } catch FixtureError.expected { }
        precondition(begins == 1 && ends == 1, "Thrown operations must release their lease")
        let value = try await store.withAccess(id: folder.id) { url in
            try await Task.sleep(for: .milliseconds(1))
            return url.path
        }
        precondition(value == folder.path && begins == 2 && ends == 2)
        precondition(SecurityScopedFolderStore.contains(URL(fileURLWithPath: "/tmp/local-fixture/file"), in: URL(fileURLWithPath: folder.path)))
        precondition(!SecurityScopedFolderStore.contains(URL(fileURLWithPath: "/tmp/local-fixture-other/file"), in: URL(fileURLWithPath: folder.path)), "Sibling prefixes must not inherit access")
        let cancellation = Task { @MainActor in
            try await store.withAccess(id: folder.id) { _ in try await Task.sleep(for: .seconds(30)); return "unexpected" }
        }
        await Task.yield()
        cancellation.cancel()
        do { _ = try await cancellation.value; preconditionFailure("Cancellation expected") } catch is CancellationError { }
        precondition(begins == ends, "Cancellation must release access")

        let second = AuthorizedLocalFolder(id: UUID(), name: "Second", path: "/tmp/second", bookmarkData: Data([2]))
        let allData = try JSONEncoder().encode([folder, second])
        let allStore = SecurityScopedFolderStore(load: { allData }, save: { _ in }, access: .init(
            resolve: { data in (URL(fileURLWithPath: data == Data([1]) ? folder.path : second.path), false) },
            bookmark: { _ in Data([1]) }, start: { _ in begins += 1; return true }, stop: { _ in ends += 1 }))
        try await allStore.load()
        do { let _: String = try await allStore.withAllAccess { roots in
            precondition(roots.count == 2)
            throw FixtureError.expected
        }; preconditionFailure("Failure expected") } catch FixtureError.expected { }
        precondition(begins == ends, "All granted roots must release on operation failure")
        let staleStore = SecurityScopedFolderStore(load: { saved }, save: { _ in throw FixtureError.expected }, access: .init(
            resolve: { _ in (URL(fileURLWithPath: folder.path), true) }, bookmark: { _ in Data([3]) },
            start: { _ in begins += 1; return true }, stop: { _ in ends += 1 }))
        try await staleStore.load()
        do { let _: String = try await staleStore.withAccess(id: folder.id) { _ in "unexpected" }; preconditionFailure("Save failure expected") } catch FixtureError.expected { }
        precondition(staleStore.folders == [folder] && begins == ends, "Failed stale renewal preserves the saved grant and releases the scope")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("granted")
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        precondition(!SecurityScopedFolderStore.contains(link.appendingPathComponent("file"), in: root), "Symlinks cannot escape the grant")
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside.appendingPathComponent("missing"))
        precondition(!SecurityScopedFolderStore.contains(dangling.appendingPathComponent("new-file"), in: root), "Dangling symlinks cannot authorize destinations outside the grant")
        let barrier = FolderSaveBarrier()
        let probe = FolderResolutionProbe()
        let racingStore = SecurityScopedFolderStore(load: { allData }, save: { try await barrier.save($0) }, access: .init(
            resolve: { data in (URL(fileURLWithPath: data == Data([1]) ? folder.path : second.path), true) },
            bookmark: { url in url.path == folder.path ? Data([3]) : Data([4]) },
            start: { url in if url.path == second.path { probe.secondStarted() }; return true }, stop: { _ in }))
        try await racingStore.load()
        let firstRenewal = Task { @MainActor in try await racingStore.withAccess(id: folder.id) { _ in true } }
        await barrier.waitUntilFirstSave()
        let secondRenewal = Task { @MainActor in try await racingStore.withAccess(id: second.id) { _ in true } }
        await probe.waitUntilSecondStarted()
        await barrier.releaseFirstSave()
        _ = try await firstRenewal.value
        _ = try await secondRenewal.value
        let persisted = try JSONDecoder().decode([AuthorizedLocalFolder].self, from: await barrier.lastData())
        precondition(racingStore.folders.first(where: { $0.id == folder.id })?.bookmarkData == Data([3]) && racingStore.folders.first(where: { $0.id == second.id })?.bookmarkData == Data([4]), "Concurrent stale renewal must retain both refreshed bookmarks in memory")
        precondition(persisted == racingStore.folders, "The final persisted grants must include both concurrent renewals")
        let cancellationBarrier = FolderSaveBarrier()
        let cancellationProbe = FolderResolutionProbe()
        var cancellationBegins = 0
        var cancellationEnds = 0
        let cancellationStore = SecurityScopedFolderStore(load: { allData }, save: { try await cancellationBarrier.save($0) }, access: .init(
            resolve: { data in (URL(fileURLWithPath: data == Data([1]) ? folder.path : second.path), true) },
            bookmark: { url in url.path == folder.path ? Data([3]) : Data([4]) },
            start: { url in cancellationBegins += 1; if url.path == second.path { cancellationProbe.secondStarted() }; return true }, stop: { _ in cancellationEnds += 1 }))
        try await cancellationStore.load()
        let owner = Task { @MainActor in try await cancellationStore.withAccess(id: folder.id) { _ in true } }
        await cancellationBarrier.waitUntilFirstSave()
        let cancelledWaiter = Task { @MainActor in try await cancellationStore.withAccess(id: second.id) { _ in true } }
        await cancellationProbe.waitUntilSecondStarted()
        cancelledWaiter.cancel()
        do { _ = try await cancelledWaiter.value; preconditionFailure("Queued renewal should cancel") } catch is CancellationError { }
        await cancellationBarrier.releaseFirstSave()
        _ = try await owner.value
        precondition(cancellationBegins == cancellationEnds && cancellationStore.folders.first(where: { $0.id == second.id })?.bookmarkData == Data([2]), "Cancelling a persistence waiter releases its scope without replacing its grant")
        let loadBarrier = FolderLoadBarrier(data: saved)
        let loadProbe = FolderResolutionProbe()
        let loadingStore = SecurityScopedFolderStore(load: { await loadBarrier.read() }, save: { _ in }, access: .init(resolve: { _ in (URL(fileURLWithPath: folder.path), false) }, bookmark: { _ in Data([1]) }, start: { _ in true }, stop: { _ in }))
        let firstLoad = Task { @MainActor in try await loadingStore.load() }
        await loadBarrier.waitUntilFirstRead()
        let secondLoad = Task { @MainActor in loadProbe.secondStarted(); try await loadingStore.load() }
        await loadProbe.waitUntilSecondStarted()
        await loadBarrier.releaseFirstRead()
        try await firstLoad.value
        try await secondLoad.value
        let initialReads = await loadBarrier.readCount()
        precondition(initialReads == 1 && loadingStore.folders == [folder], "Overlapping initial loads must publish one durable snapshot under the same persistence owner")
        print("Local folder lease and boundary verification passed")
    }
}

private actor FolderSaveBarrier {
    private var saved: [Data] = []
    private var firstGate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func save(_ data: Data) async throws {
        saved.append(data)
        if saved.count == 1 {
            await withCheckedContinuation { continuation in
                firstGate = continuation
                let pending = waiters; waiters = []; for waiter in pending { waiter.resume() }
            }
        }
    }
    func waitUntilFirstSave() async { if firstGate != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseFirstSave() { let continuation = firstGate; firstGate = nil; continuation?.resume() }
    func lastData() -> Data { saved.last! }
}

private actor FolderLoadBarrier {
    private let data: Data
    private var reads = 0
    private var firstGate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(data: Data) { self.data = data }
    func read() async -> Data {
        reads += 1
        if reads == 1 {
            await withCheckedContinuation { continuation in
                firstGate = continuation
                let pending = waiters; waiters = []; for waiter in pending { waiter.resume() }
            }
        }
        return data
    }
    func waitUntilFirstRead() async { if firstGate != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseFirstRead() { let continuation = firstGate; firstGate = nil; continuation?.resume() }
    func readCount() -> Int { reads }
}

@MainActor private final class FolderResolutionProbe {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func secondStarted() { started = true; waiter?.resume(); waiter = nil }
    func waitUntilSecondStarted() async { if started { return }; await withCheckedContinuation { waiter = $0 } }
}
#endif
