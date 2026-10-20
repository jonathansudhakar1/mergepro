import Foundation
import XCTest
import MergeProCore

func repo(_ id: Int, push: Bool = false) -> String { "{\"id\":\(id),\"full_name\":\"org/r\(id)\",\"private\":true,\"permissions\":{\"pull\":true,\"push\":\(push)}}" }
@MainActor
final class DiscoveryTests: XCTestCase {
    let account = AccountScope(host: "github.com", accountID: "42")
    let credential = GitHubCredential(accessToken: "fixture", scopes: ["repo", "read:org"])
    func testThreePagesAccountPermissionsAndOwnerGroups() async throws {
        let t = ScriptedTransport([json("[\(repo(1))]", headers: ["Link":"<https://api.github.com/user/repos?page=2>; rel=\"next\""]), json("[\(repo(2))]", headers: ["Link":"<https://api.github.com/user/repos?page=3>; rel=\"next\""]), json("[\(repo(3))]"), json("[]"), json("[]")])
        let result = try await RepositoryDiscovery(client: GitHubHTTPClient(transport: t)).discover(account: account, credential: credential)
        XCTAssertEqual(result.repositories.map(\.name), ["org/r1", "org/r2", "org/r3"]); XCTAssertTrue(result.isComplete)
        XCTAssertFalse(result.repositories[0].capabilities.contains(.merge))
        let requests = await t.captured(); XCTAssertTrue(requests[0].url!.absoluteString.contains("affiliation=")); XCTAssertFalse(requests[0].url!.absoluteString.contains("type="))
    }
    func testRestrictedOrganizationRetainsReposAndAnotherAccountSucceeds() async throws {
        let t = ScriptedTransport([json("[\(repo(1))]"), json("{}", status: 403, headers: ["X-GitHub-SSO":"required; url=https://github.com/orgs/a/sso"]), json("[]"), json("[\(repo(1, push:true))]"), json("[]"), json("[]")])
        let discovery = RepositoryDiscovery(client: GitHubHTTPClient(transport:t))
        let first = try await discovery.discover(account: account, credential: credential)
        let other = try await discovery.discover(account: AccountScope(host:"github.com", accountID:"55"), credential: GitHubCredential(accessToken:"other", scopes:["repo","read:org"]))
        XCTAssertFalse(first.isComplete); XCTAssertEqual(first.repositories.count, 1); XCTAssertFalse(first.issues.isEmpty)
        XCTAssertTrue(other.isComplete); XCTAssertNotEqual(first.repositories[0].key, other.repositories[0].key)
        XCTAssertTrue(other.repositories[0].capabilities.contains(.merge))
    }
    func testPageFailureAndPartialSSOAreIncomplete() async throws {
        let t = ScriptedTransport([json("[\(repo(1))]", headers:["Link":"<https://api.github.com/user/repos?page=2>; rel=\"next\"", "X-GitHub-SSO":"partial-results; organizations=99"]), json("{}", status:500), json("[]"), json("[]")])
        let result = try await RepositoryDiscovery(client: GitHubHTTPClient(transport:t)).discover(account: account, credential: credential)
        XCTAssertEqual(result.repositories.count, 1); XCTAssertFalse(result.isComplete); XCTAssertGreaterThanOrEqual(result.issues.count, 2)
    }
    func testOffOriginPaginationNeverReceivesToken() async throws {
        let t = ScriptedTransport([json("[\(repo(1))]", headers:["Link":"<https://evil.invalid/page>; rel=\"next\""]), json("[]"), json("[]")])
        let result = try await RepositoryDiscovery(client: GitHubHTTPClient(transport:t)).discover(account: account, credential: credential)
        XCTAssertFalse(result.isComplete)
        let requests = await t.captured(); XCTAssertTrue(requests.allSatisfy { $0.url!.host == "api.github.com" })
    }
    func testSameOriginRedirectKeepsCredentialsAndUnsafeRedirectIsRejected() async throws {
        let t = ScriptedTransport([json("", status:301, headers:["Location":"https://api.github.com/new"]), json("[]")])
        _ = try await GitHubHTTPClient(transport:t).get(URL(string:"https://api.github.com/old")!, token:"fixture")
        let requests = await t.captured(); XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[1].value(forHTTPHeaderField:"Authorization"), "Bearer fixture")
        for destination in ["https://evil.invalid/asset", "http://api.github.com/page", "https://user@api.github.com/page", "https://api.github.com:444/page"] {
            let unsafe = ScriptedTransport([json("", status:302, headers:["Location":destination])])
            do { _ = try await GitHubHTTPClient(transport:unsafe).get(URL(string:"https://api.github.com/old")!, token:"fixture"); XCTFail("unsafe redirect") } catch { XCTAssertEqual(error as? GitHubFailure, .unsafeURL) }
            let sent = await unsafe.captured(); XCTAssertEqual(sent.count, 1)
        }
    }
    func testUnexpected304RefetchesWithoutReplacingInventoryWithEmptyBody() async throws {
        let t = ScriptedTransport([json("",status:304), json("[\(repo(1))]"), json("[]"), json("[]")])
        let result = try await RepositoryDiscovery(client:GitHubHTTPClient(transport:t)).discover(account:account, credential:credential)
        XCTAssertTrue(result.isComplete); XCTAssertEqual(result.repositories.count,1)
        let requests = await t.captured(); XCTAssertEqual(requests.count,4)
        XCTAssertNil(requests[1].value(forHTTPHeaderField:"If-None-Match"))
    }
    func testCommaInPageQueryAndMultipleRelationsAreParsed() async throws {
        let link = "<https://api.github.com/user/repos?affiliation=owner,collaborator&page=2>; rel=\"next alternate\""
        let t = ScriptedTransport([json("[\(repo(1))]",headers:["Link":link]),json("[\(repo(2))]"),json("[]"),json("[]")])
        let result = try await RepositoryDiscovery(client:GitHubHTTPClient(transport:t)).discover(account:account,credential:credential)
        XCTAssertTrue(result.isComplete); XCTAssertEqual(result.repositories.count,2)
    }
    func test403WithAcceptedScopeAlreadyGrantedIsResourceDenial() async {
        let t = ScriptedTransport([json("{}",status:403,headers:["X-Accepted-OAuth-Scopes":"read:org", "X-OAuth-Scopes":"repo, user"])])
        do { _ = try await GitHubHTTPClient(transport:t).get(URL(string:"https://api.github.com/user/orgs")!,token:"fixture"); XCTFail("denied") }
        catch { XCTAssertEqual(error as? GitHubFailure,.resourceDenied) }
    }
    func testMalformedNextLinkAnd401HaveDifferentAccountOutcomes() async throws {
        let malformed = ScriptedTransport([json("[\(repo(1))]",headers:["Link":"not-a-link; rel=\"next\""]),json("[]"),json("[]")])
        let partial = try await RepositoryDiscovery(client:GitHubHTTPClient(transport:malformed)).discover(account:account,credential:credential)
        XCTAssertFalse(partial.isComplete); XCTAssertEqual(partial.repositories.count,1)
        let revoked = ScriptedTransport([json("{}",status:401)])
        do { _ = try await RepositoryDiscovery(client:GitHubHTTPClient(transport:revoked)).discover(account:account,credential:credential); XCTFail("revoked") }
        catch { XCTAssertEqual(error as? GitHubFailure,.invalidAuthentication) }
    }
    func testFirstEndpointThrottleStopsAccountDiscoveryAndPreservesDeadline() async throws {
        let transport = ScriptedTransport([json("{}",status:429,headers:["Retry-After":"60"]),json("[]"),json("[]")])
        let result = try await RepositoryDiscovery(client:GitHubHTTPClient(transport:transport,clock:FixtureClock())).discover(account:account,credential:credential)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.retryAt,Date(timeIntervalSince1970:60))
        let requests = await transport.captured(); XCTAssertEqual(requests.count,1)
    }
    func testSecondaryThrottleIgnoresPrimaryResetWithPositiveHeadroom() async {
        let transport = ScriptedTransport([json(#"{"message":"secondary rate limit"}"#,status:403,headers:["X-RateLimit-Remaining":"42","X-RateLimit-Reset":"30"])])
        do { _ = try await GitHubHTTPClient(transport:transport,clock:FixtureClock()).get(URL(string:"https://api.github.com/user")!,token:"fixture"); XCTFail("throttle") }
        catch { XCTAssertEqual(error as? GitHubFailure,.rateLimited(until:Date(timeIntervalSince1970:60))) }
        let primary = ScriptedTransport([json("{}",status:403,headers:["X-RateLimit-Remaining":"0","X-RateLimit-Reset":"30"])])
        do { _ = try await GitHubHTTPClient(transport:primary,clock:FixtureClock()).get(URL(string:"https://api.github.com/user")!,token:"fixture"); XCTFail("throttle") }
        catch { XCTAssertEqual(error as? GitHubFailure,.rateLimited(until:Date(timeIntervalSince1970:30))) }
    }
    func test403WithPrimaryHeadroomIsRateLimitedNotRevoked() async {
        let t = ScriptedTransport([json(#"{"message":"secondary rate limit"}"#, status:403, headers:["X-RateLimit-Remaining":"42", "Retry-After":"60"])])
        do { _ = try await GitHubHTTPClient(transport:t).get(URL(string:"https://api.github.com/user")!, token:"fixture"); XCTFail("throttle") } catch {
            guard case .rateLimited = error as? GitHubFailure else { return XCTFail("wrong normalized error") }
        }
    }
    func testUnauthenticatedAPIRequestCannotProduceAccountRevocation() async throws {
        for query in [false,true] {
            let transport = ScriptedTransport([json("{}",status:401)])
            let client = GitHubHTTPClient(transport:transport)
            do {
                if query { _ = try await client.readQuery("query Fixture { viewer { id } }",variables:[:],token:"") }
                else { _ = try await client.get(URL(string:"https://api.github.com/user")!,token:"") }
                XCTFail("Authenticated API surface must reject an empty credential")
            } catch { XCTAssertEqual(error as? GitHubFailure,.unsafeURL) }
        }
    }
    func testCancelledTrusted401StillSurfacesButSuccessfulResponseIsDiscarded() async throws {
        for query in [false,true] {
            for status in [200,401] {
                let transport = ScriptedTransport.suspended()
                let budgeted = BudgetedGitHubTransport(base:transport,budget:RateBudget(minimumSpacing:.zero),account:account)
                let client = GitHubHTTPClient(transport:budgeted)
                let task = Task {
                    if query { return try await client.readQuery("query Fixture { viewer { id } }",variables:[:],token:"fixture") }
                    return try await client.get(URL(string:"https://api.github.com/user")!,token:"fixture")
                }
                await transport.waitUntilHolding()
                task.cancel()
                await transport.release(json("{}",status:status))
                do { _ = try await task.value; XCTFail("No canceled response may become a successful result") }
                catch {
                    if status == 401 { XCTAssertEqual(error as? GitHubFailure,.invalidAuthentication) }
                    else { XCTAssertTrue(error is CancellationError) }
                }
            }
        }
    }

    func testForeign401ResponseAndForeignAssetDestinationCannotRevokeAnAccount() async throws {
        for query in [false,true] {
            let foreign = ScriptedTransport([GitHubResponse(status:401,responseURL:URL(string:"https://foreign.invalid/asset"))])
            let client = GitHubHTTPClient(transport:foreign)
            do {
                if query { _ = try await client.readQuery("query Fixture { viewer { id } }",variables:[:],token:"fixture") }
                else { _ = try await client.get(URL(string:"https://api.github.com/user")!,token:"fixture") }
                XCTFail("Foreign response must be rejected before auth classification")
            } catch { XCTAssertEqual(error as? GitHubFailure,.unsafeURL) }
        }
        let transport = ScriptedTransport([json("{}",status:401)])
        do { _ = try await GitHubHTTPClient(transport:transport).get(URL(string:"https://foreign.invalid/asset")!,token:"fixture"); XCTFail("Foreign asset must not receive credential") }
        catch { XCTAssertEqual(error as? GitHubFailure,.unsafeURL) }
        let captured = await transport.captured(); XCTAssertTrue(captured.isEmpty)
    }

}
