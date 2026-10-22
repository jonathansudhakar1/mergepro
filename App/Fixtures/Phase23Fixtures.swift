import Foundation
import MergeProCore

/// Provider-shaped data for the separate fixture app. This transport never reaches the network.
enum Phase23Fixtures {
    static var enabled:Bool { ProcessInfo.processInfo.processInfoEnvironmentPhase23 }
    static var repositoryCount:Int { min(500,max(2,Int(ProcessInfo.processInfo.environment["MERGEPRO_PHASE23_REPO_COUNT"] ?? "2") ?? 2)) }
    static let accounts = [AccountScope(host:"github.com",accountID:"99"),AccountScope(host:"github.com",accountID:"100")]
    static let sha = String(repeating:"a",count:40),tree = String(repeating:"b",count:40),child = String(repeating:"c",count:40)
    static let code = "import Foundation\n\nstruct BuildStatus {\n    let name: String\n    let passed: Bool\n}\n"
    static let readme = "# Phase 2 + 3 workspace\n\nAn offline repository for checking Actions, immutable files, history and releases.\n\n- Workflow attempts remain distinct.\n- Files load at the selected commit.\n"
    static let yaml = """
    name: Build and deploy
    on:
      workflow_dispatch:
        inputs:
          target:
            type: environment
            required: true
            default: staging
          version:
            type: string
            default: next
          dry_run:
            type: boolean
            default: true
          count:
            type: number
            default: 1
          platform:
            type: choice
            options: [macOS, Linux]
            default: macOS
    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - run: echo fixture
    """
    static func seed(_ database:DatabaseStore) throws {
        guard enabled,try database.applicationSetting(.phase23Seeded) == nil else { return }
        for account in accounts {
            try database.saveAccount(.init(scope:account,login:"Fixture "+account.accountID,tokenReference:nil))
            for id in [7,8] {
                let key = RepositoryKey(account:account,repositoryID:String(id))
                try database.saveRepository(.init(key:key,name:id == 7 ? "fixtures/phase23" : "fixtures/library",isPrivate:true,capabilities:[]))
                try database.setTracked(key,tracked:true)
                if id == 7 {
                    try database.setPinned(.init(host:account.host,accountID:account.accountID,repositoryID:String(id),objectID:"repository"),pinned:true)
                    var metadata = PRMetadata(number:1,webURL:URL(string:"https://github.com/fixtures/phase23/pull/1")!,repositoryName:"fixtures/phase23")
                    metadata.headBranch = "feature/native";metadata.baseBranch = "main";metadata.authorLogin = "Fixture author";metadata.descriptionPreview = "Verify reusable review and Actions tabs."
                    metadata.createdAt = Date();metadata.updatedAt = Date();metadata.fetchedAt = Date()
                    try database.savePullRequests([.init(key:.init(host:account.host,accountID:account.accountID,repositoryID:String(id),objectID:"PR_PHASE23"),headRevision:.init(sha),title:"Native workspace integration",state:.open,isDraft:false,metadata:metadata)])
                }
            }
        }
        try database.setApplicationSetting(AccountSessionStore.tokenReference(for:accounts[0]),for:.activeActionAccount)
        try database.setApplicationSetting("true",for:.phase23Seeded)
    }
}
private extension ProcessInfo {
    var processInfoEnvironmentPhase23:Bool { environment["MERGEPRO_PHASE23_FIXTURES"] == "1" && environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(UUID.init(uuidString:)) != nil }
}

actor Phase23FixtureTransport:GitHubTransport {
    private func response(_ object:Any,status:Int = 200,headers:[String:String] = [:]) throws -> GitHubResponse {
        .init(status:status,headers:["X-RateLimit-Remaining":"4900","X-RateLimit-Reset":"1893456000"].merging(headers) { _,new in new },data:try JSONSerialization.data(withJSONObject:object))
    }
    private func repository(_ id:Int,account:String) -> [String:Any] {
        let name=id == 7 ? "phase23":id == 8 ? "library":"catalog-\(id)"
        return
        ["id":id,"name":name,"full_name":"fixtures/"+name,"owner":["login":"fixtures","id":70],"private":true,"default_branch":"main","language":"Swift","topics":["macos","developer-tools"],"archived":false,"fork":false,"stargazers_count":42,"pushed_at":"2026-10-04T16:00:00Z","permissions":["push":account == "99","admin":account == "99"]]
    }
    private func run(_ id:Int) -> [String:Any] {
        ["id":id,"workflow_id":10,"run_attempt":id == 101 ? 2 : 1,"name":"Build and deploy","head_branch":"feature/native","head_sha":Phase23Fixtures.sha,"event":"workflow_dispatch","actor":["login":"Fixture 99"],"status":id == 101 ? "in_progress" : "completed","conclusion":id == 101 ? NSNull() : "success" as Any,"created_at":"2026-10-04T16:00:00Z","updated_at":"2026-10-04T16:02:00Z","run_started_at":"2026-10-04T16:00:05Z","html_url":"https://github.com/fixtures/phase23/actions/runs/\(id)","pull_requests":[["number":1]]]
    }
    private func commit(_ sha:String) -> [String:Any] {
        ["sha":sha,"commit":["message":"Build native repository workspace\n\nProvider-shaped offline fixture.","author":["name":"Fixture author","email":"fixture@example.invalid","date":"2026-10-04T16:00:00Z"],"tree":["sha":Phase23Fixtures.tree]],"author":["login":"fixture-author"],"html_url":"https://github.com/fixtures/phase23/commit/\(sha)","parents":[["sha":String(repeating:"d",count:40)]],"files":[]]
    }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        guard Phase23Fixtures.enabled,let url = request.url,url.host == "api.github.com" else { throw GitHubFailure.resourceDenied }
        let method = request.httpMethod ?? "GET",path = url.path
        if method == "POST",path == "/graphql",let data=request.httpBody,
           let body=try JSONSerialization.jsonObject(with:data) as? [String:Any],
           let query=body["query"] as? String,query.hasPrefix("query RepositoryOverview") {
            return try response(["data":["repository":["pullRequests":["totalCount":1],"latestRelease":["name":"Native workspace preview","tagName":"v1.0"],"defaultBranchRef":["target":["statusCheckRollup":["state":"SUCCESS"]]]]]])
        }
        if method == "POST",path == "/graphql",let data=request.httpBody,
           let body=try JSONSerialization.jsonObject(with:data) as? [String:Any],
           let query=body["query"] as? String,query.hasPrefix("query WorkflowRefs") {
            let typed=((body["variables"] as? [String:Any])?["query"] as? String ?? "").lowercased()
            func nodes(_ names:[String]) -> [String:Any] { ["nodes":names.filter { typed.isEmpty || $0.lowercased().contains(typed) }.map { ["name":$0] }] }
            return try response(["data":["repository":["defaultBranchRef":["name":"main"],"branches":nodes(["feature/native","main"]),"tags":nodes(["v1.0"])]]])
        }
        // Fixture writes are local simulations only. Production transport cannot enter this branch.
        guard method == "GET" else { throw GitHubFailure.resourceDenied }
        let account = request.value(forHTTPHeaderField:"Authorization")?.hasSuffix("100") == true ? "100" : "99"
        let parts = path.split(separator:"/").map(String.init)
        if path == "/user/repos" {
            let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            let page=Int(query.first { $0.name == "page" }?.value ?? "1") ?? 1
            let count=Int(query.first { $0.name == "per_page" }?.value ?? "100") ?? 100
            let start=(page-1)*count,end=min(page*count,Phase23Fixtures.repositoryCount)
            let values=start<end ? (start..<end).map { repository($0+7,account:account) } : []
            let headers=end<Phase23Fixtures.repositoryCount ? ["Link":"<https://api.github.com/user/repos?per_page=\(count)&page=\(page+1)>; rel=\"next\""] : [:]
            return try response(values,headers:headers)
        }
        guard parts.count >= 3,parts[0] == "repos",parts[1] == "fixtures" else { throw GitHubFailure.resourceDenied }
        let suffix = parts.dropFirst(3).joined(separator:"/")
        if suffix.isEmpty { return try response(repository(parts[2] == "phase23" ? 7:parts[2] == "library" ? 8:Int(parts[2].replacingOccurrences(of:"catalog-",with:"")) ?? 8,account:account)) }
        if suffix == "actions/runs" { return try response(["total_count":2,"workflow_runs":[run(101),run(100)]]) }
        if suffix == "actions/workflows" { return try response(["total_count":1,"workflows":[["id":10,"name":"Build and deploy","path":".github/workflows/build.yml","state":"active","html_url":"https://github.com/fixtures/phase23/actions/workflows/build.yml"]]]) }
        if suffix.hasPrefix("actions/runs/") {
            let id = Int(parts[5]) ?? 101
            if suffix.hasSuffix("/jobs") { return try response(["total_count":1,"jobs":[["id":201,"name":"Build macOS","status":"completed","conclusion":"success","started_at":"2026-10-04T16:00:05Z","completed_at":"2026-10-04T16:01:05Z","check_run_url":"https://api.github.com/repos/fixtures/phase23/check-runs/301","html_url":"https://github.com/fixtures/phase23/actions/runs/\(id)/job/201","steps":[["number":1,"name":"Checkout","status":"completed","conclusion":"success"],["number":2,"name":"Test Core","status":"completed","conclusion":"success"]]]]]) }
            if suffix.hasSuffix("/artifacts") { return try response(["total_count":1,"artifacts":[["id":401,"name":"Core test report","size_in_bytes":22,"expired":false,"expires_at":"2027-01-01T00:00:00Z"]]]) }
            if suffix.hasSuffix("/pending_deployments") { return try response(id == 101 ? [["environment":["id":501,"name":"production"],"current_user_can_approve":account == "99"]] : []) }
            return try response(run(id))
        }
        if suffix == "actions/jobs/201/logs" { return .init(status:200,data:Data("\u{1B}[32m✓ Core tests passed\u{1B}[0m\n291 baseline tests\nBuild completed in 60 seconds\n".utf8)) }
        if suffix == "actions/artifacts/401/zip" { return .init(status:200,data:Data("Offline fixture report".utf8)) }
        if suffix == "check-runs/301/annotations" { return try response([["path":"Sources/BuildStatus.swift","start_line":4,"end_line":4,"annotation_level":"notice","message":"Typed provider fixture","title":"Native check"]]) }
        if suffix == "environments" { return try response(["environments":[["id":500,"name":"staging"],["id":501,"name":"production"]]]) }
        if suffix == "deployments" { return try response([["id":601,"environment":"staging","ref":"main","sha":Phase23Fixtures.sha,"production_environment":false]]) }
        if suffix == "deployments/601/statuses" { return try response([["state":"success","environment_url":"https://github.com/fixtures/phase23/deployments"]]) }
        if suffix == "branches" { return try response([["name":"main","protected":true,"commit":["sha":Phase23Fixtures.sha]],["name":"feature/native","protected":false,"commit":["sha":Phase23Fixtures.sha]]]) }
        if suffix.hasPrefix("branches/") { return try response(["name":parts.last!,"protected":parts.last == "main","commit":["sha":Phase23Fixtures.sha]]) }
        if suffix == "tags" { return try response([["name":"v1.0","commit":["sha":Phase23Fixtures.sha]]]) }
        if suffix == "commits" { return try response([commit(Phase23Fixtures.sha)]) }
        if suffix.hasPrefix("commits/") { return try response(commit(Phase23Fixtures.sha)) }
        if suffix.hasPrefix("contents/") { let source = suffix.hasSuffix("build.yml") ? Phase23Fixtures.yaml : Phase23Fixtures.readme;return try response(["encoding":"base64","content":Data(source.utf8).base64EncodedString(),"sha":Phase23Fixtures.sha]) }
        if suffix.hasPrefix("git/trees/") {
            let entries:[[String:Any]] = parts.last == Phase23Fixtures.child ? [["path":"BuildStatus.swift","mode":"100644","type":"blob","sha":String(repeating:"e",count:40),"size":Phase23Fixtures.code.utf8.count]] : [["path":"Sources","mode":"040000","type":"tree","sha":Phase23Fixtures.child],["path":"README.md","mode":"100644","type":"blob","sha":String(repeating:"f",count:40),"size":Phase23Fixtures.readme.utf8.count]]
            return try response(["sha":parts.last!,"truncated":ProcessInfo.processInfo.environment["MERGEPRO_PHASE23_TRUNCATED_TREE"] == "1" && parts.last != Phase23Fixtures.child,"tree":entries])
        }
        if suffix.hasPrefix("git/blobs/") { let source = parts.last == String(repeating:"f",count:40) ? Phase23Fixtures.readme : Phase23Fixtures.code;return try response(["encoding":"base64","content":Data(source.utf8).base64EncodedString(),"size":source.utf8.count]) }
        if suffix.hasPrefix("compare/") { return try response(["ahead_by":1,"behind_by":0,"status":"ahead","files":[],"commits":[commit(Phase23Fixtures.sha)],"total_commits":1]) }
        if suffix == "releases/assets/801" { return .init(status:200,data:Data("Offline fixture report".utf8)) }
        if suffix == "releases" || suffix == "releases/latest" {
            let release:[String:Any] = ["id":701,"tag_name":"v1.0","name":"Native workspace preview","body":"## Changes\n\nActions and repository browsing are ready for fixture verification.","draft":false,"prerelease":true,"published_at":"2026-10-04T16:00:00Z","html_url":"https://github.com/fixtures/phase23/releases/tag/v1.0","assets":[["id":801,"name":"report.txt","size":22,"url":"https://api.github.com/repos/fixtures/phase23/releases/assets/801","browser_download_url":"https://github.com/fixtures/phase23/releases/download/v1.0/report.txt"]]]
            return try response(suffix == "releases" ? [release] : release)
        }
        if suffix == "pulls" || suffix == "notifications" { return try response([]) }
        throw GitHubFailure.resourceDenied
    }
}
