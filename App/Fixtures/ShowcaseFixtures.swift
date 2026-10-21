import Foundation
import MergeProCore

/// The fixture app's screenshot data (`MERGEPRO_SHOWCASE=1`): the shipped sample data, offline.
enum ShowcaseFixtures {
    static var enabled: Bool { PRNativeFixtures.enabled && ProcessInfo.processInfo.environment["MERGEPRO_SHOWCASE"] == "1" }
    static var account: AccountScope { SampleData.account }
    static func seed(_ database: DatabaseStore) throws { if enabled { try SampleData.seed(database) } }
    static func detail(_ pr: PullRequest) -> PRDetailSnapshot { SampleData.detail(pr) }
    static func blob(path: String) -> Data { SampleData.blob(path: path) }
}
