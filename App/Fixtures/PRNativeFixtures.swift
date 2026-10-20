  import Foundation
  import MergeProCore

  /// Only the distinct signed fixture target compiles this source. Namespace is mandatory.
  enum PRNativeFixtures {
    static var enabled: Bool {
      ProcessInfo.processInfo.environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(
        UUID.init(uuidString:)) != nil
    }
    static func refresh(_ database: DatabaseStore) throws {
      guard enabled, try database.applicationSetting(.prFixtureSeeded) == "true" else { return }
      let account = AccountScope(host: "fixture.invalid", accountID: "fixture-viewer")
      guard
        let prior = try database.snapshot(for: account).pullRequests.max(by: {
          ($0.metadata?.number ?? 0) < ($1.metadata?.number ?? 0)
        })
      else { return }
      var metadata = prior.metadata
      let comments = (metadata?.comments ?? 0) + 1
      metadata?.comments = comments
      try database.savePullRequests([
        PullRequest(
          key: prior.key, headRevision: prior.headRevision, title: prior.title, state: prior.state,
          isDraft: prior.isDraft, metadata: metadata)
      ])
    }
    static func seed(_ database: DatabaseStore) throws {
      if PRMergeFixtures.enabled { try PRMergeFixtures.seed(database);return }
      guard enabled, try database.applicationSetting(.prFixtureSeeded) == nil,
        let count = ProcessInfo.processInfo.environment["MERGEPRO_PR_FIXTURE_COUNT"].flatMap(
          Int.init), [500, 5000].contains(count)
      else { return }
      let account = AccountScope(host: "fixture.invalid", accountID: "fixture-viewer")
      let repo = RepositoryKey(account: account, repositoryID: "fixture-repository")
      try database.saveAccount(
        Account(scope: account, login: "Fixture viewer", tokenReference: nil))
      try database.saveRepository(
        Repository(
          key: repo, name: "Fixtures/NativePRs", isPrivate: false,
          capabilities: ProviderCapabilities()))
      try database.setTracked(repo, tracked: true)
      let now = Date()
      let rows = (1...count).map { number in
        let key = ProviderKey(
          host: account.host, accountID: account.accountID, repositoryID: repo.repositoryID,
          objectID: "pull-request:fixture-\(number)")
        var metadata = PRMetadata(
          number: number, webURL: URL(string: "https://example.invalid/pull/\(number)")!,
          repositoryName: "Fixtures/NativePRs")
        metadata.authorID = "fixture-author"
        metadata.authorLogin = "Fixture author"
        metadata.actorType = "User"
        metadata.viewerID = "fixture-viewer"
        metadata.viewerIsAuthor = number % 2 == 0
        metadata.createdAt = now.addingTimeInterval(-86400)
        metadata.updatedAt = now
        metadata.fetchedAt = now
        metadata.reviewDecision = number % 3 == 0 ? "APPROVED" : "REVIEW_REQUIRED"
        metadata.headBranch = "fixture-\(number)"
        metadata.baseBranch = "main"
        metadata.headRepositoryID = repo.repositoryID
        // Opt-in native stack navigation workload; it still uses only the offline transport.
        if ProcessInfo.processInfo.environment["MERGEPRO_STACK_FIXTURES"] == "1",number == 2 || number == 3 {
          metadata.baseBranch = "fixture-\(number-1)"
        }
        metadata.mergeable = number % 2 == 0 ? "MERGEABLE" : "CONFLICTING"
        metadata.autoMergeKnown = true
        metadata.autoMerge = number % 3 == 0
        metadata.comments = number
        metadata.columnChangedAt = now.addingTimeInterval(-3600)
        metadata.files = 3
        metadata.additions = 42
        metadata.deletions = 7
        metadata.checks = "SUCCESS"
        metadata.requests =
          number % 2 == 0
          ? []
          : [.init(id: "fixture-viewer", name: "Fixture viewer", kind: .direct, isForViewer: true)]
        return PullRequest(
          key: key, headRevision: RevisionID("fixture-revision"),
          title: "Fixture pull request \(number)", state: .open, isDraft: number % 10 == 0,
          metadata: metadata)
      }
      try database.savePullRequests(rows)
      if count == 5000 {
        var state = PRViewState()
        state.current.mode = .list
        state.views[0].configuration = state.current
        try PullRequestStore(database: database).save(state)
      }
      try database.setApplicationSetting("true", for: .prFixtureSeeded)
    }
  }
  /// Deterministic credentials belong only to the isolated offline fixture owner.
  final class PRFixtureCredentialStore: GitHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AccountScope:GitHubCredential] = [
      Phase23Fixtures.accounts[0]:GitHubCredential(accessToken:"offline-phase23-99",scopes:["repo","workflow"]),
      Phase23Fixtures.accounts[1]:GitHubCredential(accessToken:"offline-phase23-100",scopes:["repo","workflow"]),
      AccountScope(host:"fixture.invalid",accountID:"fixture-viewer"): GitHubCredential(accessToken:"offline-fixture"),
      PRMergeFixtures.account:GitHubCredential(accessToken:"offline-merge-fixture",scopes:["repo"]),
      PRPhase1Fixtures.accounts[0]:GitHubCredential(accessToken:PRPhase1Fixtures.token(PRPhase1Fixtures.accounts[0]),scopes:["repo","notifications"]),
      PRPhase1Fixtures.accounts[1]:GitHubCredential(accessToken:PRPhase1Fixtures.token(PRPhase1Fixtures.accounts[1]),scopes:["repo","notifications"])
    ]
    func credential(for account: AccountScope) -> GitHubCredential? { lock.withLock { values[account] } }
    func save(_ credential: GitHubCredential, account: AccountScope) { lock.withLock { values[account] = credential } }
    func remove(account: AccountScope) { _ = lock.withLock { values.removeValue(forKey:account) } }
  }
  struct PRFixtureOfflineTransport: GitHubTransport {
    func send(_ request: URLRequest) async throws -> GitHubResponse {
      if PRMergeFixtures.enabled { return try PRMergeFixtures.response(request) }
      throw GitHubFailure.resourceDenied
    }
  }

  import AppKit
  final class PRFixtureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
      if LocalSandboxVerification.enabled {
        Task { await LocalSandboxVerification.run() }
        return
      }
      let message =
        "TASK5 fixture launch policy=\(NSApp.activationPolicy().rawValue) windows=\(NSApp.windows.count)\n"
      FileHandle.standardError.write(Data(message.utf8))
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        let windows = NSApp.windows.map {
          "\(type(of:$0)) title=\($0.title) visible=\($0.isVisible) frame=\($0.frame)"
        }.joined(separator: "; ")
        @MainActor func tables(_ view: NSView) -> [NSTableView] {
          (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        let counts = NSApp.windows.flatMap { $0.contentView.map(tables) ?? [] }.map(\.numberOfRows)
        FileHandle.standardError.write(
          Data("TASK5 fixture windows: \(windows); native NSTableView rows=\(counts)\n".utf8))
      }
    }
  }
