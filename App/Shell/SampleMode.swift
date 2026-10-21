import AppKit
import Foundation
import MergeProCore

/// "Explore with sample data": the shipped app relaunches on its own store, filled with `SampleData` and never
/// connected to GitHub. Real accounts, tokens and cached data stay untouched in the regular store.
enum SampleMode {
    private static let defaultsKey = "sampleDataMode"
    /// `MERGEPRO_SAMPLE_DATA=1` turns it on for one launch (screenshots, demos) without changing the saved choice.
    static let isActive = UserDefaults.standard.bool(forKey: defaultsKey) || ProcessInfo.processInfo.environment["MERGEPRO_SAMPLE_DATA"] == "1"

    /// Switches modes by relaunching, so no state from the other store lingers.
    @MainActor static func set(_ active: Bool) {
        UserDefaults.standard.set(active, forKey: defaultsKey)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

extension AppDependencies {
    /// Sample-data mode: a separate store, an in-memory credential for the sample account and a transport that
    /// answers reads with empty results and refuses every write. Nothing reaches the network or the Keychain.
    static func sample() -> AppDependencies {
        let credentials = InMemoryCredentialStore()
        try? credentials.save(GitHubCredential(accessToken: "sample-data", scopes: ["repo", "workflow"]), account: SampleData.account)
        return AppDependencies(
            storageDirectoryName: "MergePro Sample Data", credentials: credentials,
            transport: SampleTransport(), signInTransport: OfflineTransport(),
            pollFetchers: [], mergeAdapter: { _ in GitHubMergeAdapter() },
            clock: { Date() }, makeNotificationSink: { _ in SystemNotificationSink(isEnabled: { false }, showsTitles: { false }) },
            speculativeDetailReads: false, reportsCycleChanges: false, globalHotkeysUnavailable: nil, fixtures: SampleHooks())
    }
}

/// Reads come back empty, so detail tabs render instead of failing; writes are refused.
private struct SampleTransport: GitHubTransport {
    func send(_ request: URLRequest) async throws -> GitHubResponse {
        guard request.httpMethod ?? "GET" == "GET" else { throw GitHubFailure.resourceDenied }
        return GitHubResponse(status: 200, headers: ["X-RateLimit-Remaining": "5000", "X-RateLimit-Reset": "1893456000"], data: Data("[]".utf8))
    }
}

private struct SampleHooks: FixtureHooks {
    func seed(_ database: DatabaseStore) throws { try SampleData.seed(database) }
    func prepare(database: DatabaseStore, session: GitHubAccountSession, budget: RateBudget) async throws {}
    func manualRefresh(_ database: DatabaseStore) throws {}
    let detail: (any OfflinePRDetail)? = SampleDetail()
    let launchDestination: String? = "pullRequests"
    @MainActor func makeWorkspaceInstrumentation() -> (any WorkspaceInstrumentation)? { nil }
    let detailInstrumentation: (any PRDetailInstrumentation)? = nil
    let codeSurfaceInstrumentation: (any CodeSurfaceInstrumentation)? = nil
}

private struct SampleDetail: OfflinePRDetail {
    func snapshot(_ pr: PullRequest) -> PRDetailSnapshot { SampleData.detail(pr) }
    func blob(_ pr: PullRequest, path: String, sha: String) -> Data { SampleData.blob(path: path) }
}
