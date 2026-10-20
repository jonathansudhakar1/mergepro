import MergeProCore
import XCTest
@testable import MergePro

/// Pure App-target helpers: user-facing Actions wording and the GitHub grant link shown after removing an account.
final class ActionsTextTests: XCTestCase {
    func testWriteStatesReadAsSentencesInsteadOfRawValues() {
        let states: [ActionsWriteState] = [.prepared, .sending, .accepted, .confirmed, .rejected, .uncertain]
        for state in states {
            let text = ProviderStateText.actionsWrite(state)
            XCTAssertNotEqual(text, state.rawValue)
            XCTAssertEqual(text.first?.isUppercase, true, text)
        }
        XCTAssertEqual(ProviderStateText.actionsWrite(.uncertain), "The outcome is unknown. Reconcile before trying again.")
    }

    func testRunStatusesAreReadable() {
        XCTAssertEqual(ProviderStateText.actionsStatus("in_progress"), "In progress")
        XCTAssertEqual(ProviderStateText.actionsStatus("action_required"), "Action required")
        XCTAssertEqual(ProviderStateText.actionsStatus(""), "Unknown")
    }

    func testRunConfirmationsNameWorkflowBranchAndActor() {
        let repository = Repository(key: .init(account: .init(host: "github.com", accountID: "1"), repositoryID: "2"), name: "acme/widgets", isPrivate: true, capabilities: [])
        let run = WorkflowRun(repository: repository, runID: 3, workflowID: 4, attempt: 2, name: "Deploy", branch: "release", headSHA: "abc", event: "push",
                              actor: "octocat", status: "in_progress", conclusion: nil, createdAt: .distantPast, updatedAt: .distantPast)
        for message in [ActionsRunConfirmation.cancelMessage(run), ActionsRunConfirmation.approveForkMessage(run)] {
            XCTAssertTrue(message.contains("Deploy"))
            XCTAssertTrue(message.contains("release"))
            XCTAssertTrue(message.contains("octocat"))
        }
    }

    func testGrantLinkOpensThisAppsAuthorizationOnTheAccountsHost() {
        XCTAssertEqual(GitHubGrantLink.url(host: "github.com", clientID: " Ov23liEXAMPLE "),
                       URL(string: "https://github.com/settings/connections/applications/Ov23liEXAMPLE"))
        XCTAssertEqual(GitHubGrantLink.url(host: "ghe.example.com", clientID: "Iv1.abc_def-1"),
                       URL(string: "https://ghe.example.com/settings/connections/applications/Iv1.abc_def-1"))
        // Without a usable client ID, the list of authorized OAuth apps is the safe destination.
        XCTAssertEqual(GitHubGrantLink.url(host: "github.com", clientID: ""), URL(string: "https://github.com/settings/applications"))
        XCTAssertEqual(GitHubGrantLink.url(host: "github.com", clientID: "../evil?x=1"), URL(string: "https://github.com/settings/applications"))
    }
}
