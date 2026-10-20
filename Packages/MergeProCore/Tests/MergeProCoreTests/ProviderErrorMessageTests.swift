import Foundation
import XCTest
import MergeProCore

final class ProviderErrorMessageTests: XCTestCase {
    func testGitHubFailuresUseTheRepositoryBrowserWording() {
        XCTAssertEqual(GitHubFailure.invalidAuthentication.localizedDescription, "GitHub rejected this account's authorization. Reconnect it in Setup.")
        XCTAssertEqual(GitHubFailure.rateLimited(until:nil).localizedDescription, "GitHub rate limited this account. Retry later.")
        let until = Date(timeIntervalSince1970:1_800_000_000)
        XCTAssertEqual(GitHubFailure.rateLimited(until:until).localizedDescription,
                       "GitHub rate limited this account. Retry after "+until.formatted(date:.omitted,time:.shortened)+".")
        XCTAssertEqual(RepositoryBrowserFailure.defaultBranch.localizedDescription, "The default branch cannot be deleted.")
    }
    func testOtherFailuresHaveCalmSpecificMessages() {
        let account = AccountScope(host:"github.com", accountID:"1")
        let errors: [any Error] = [
            StorageError.revisionConflict, StorageError.accountMissing(account), PRDetailFailure.revisionChanged,
            ProviderError.rateLimited(account:account, retryAfter:nil), ProviderError.unauthenticated(account),
            DeviceFlowFailure.expired, DeviceFlowFailure.invalidResponse
        ]
        for error in errors {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("operation couldn’t be completed") || message.contains("operation couldn't be completed"), message)
            XCTAssertFalse(message.contains("MergeProCore"), message)
        }
        XCTAssertEqual(StorageError.accountMissing(account).localizedDescription, "This account is no longer connected. Reconnect it in Setup.")
        XCTAssertEqual(DeviceFlowFailure.expired.localizedDescription, "The GitHub sign-in code expired. Start a new connection.")
    }
    func testDeviceFlowRejectionOnlyEchoesKnownSafeMessages() {
        XCTAssertEqual(DeviceFlowFailure.rejected("GitHub authorization was denied.").localizedDescription, "GitHub authorization was denied.")
        XCTAssertEqual(DeviceFlowFailure.rejected("<script>unexpected server text</script>").localizedDescription,
                       "GitHub authorization could not complete. Start a new connection.")
    }
}
