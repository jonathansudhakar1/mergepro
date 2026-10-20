import Foundation

/// Bounded provider evidence reader. Unknown configured rules remain explicit gates.
struct GitHubMergeReader:Sendable {
    let client:GitHubHTTPClient
    let credential:GitHubCredential
    typealias Object=[String:Any]
    func object(_ value:Any?) -> Object { value as? Object ?? [:] }
    func list(_ value:Any?) -> [Object] { value as? [Object] ?? [] }
    func query(_ query:String,_ variables:[String:String?]) async throws -> Object {
        let response=try await client.readQuery(query,variables:variables,token:credential.accessToken)
        guard response.data.count<=8_000_000,let root=try JSONSerialization.jsonObject(with:response.data) as? Object,root["errors"] == nil,let data=root["data"] as? Object else { throw PRWriteFailure.unavailable };return data
    }
    func restList(_ url:URL,repositoryID:String? = nil) async throws -> [Object] {
        var values:[Object]=[],next:URL?=url,visited:Set<URL>=[],bytes=0
        while let current=next {
            guard visited.count<30,visited.insert(current).inserted,client.isSafeAPIURL(current),GitHubHTTPClient.samePaginatedPath(current,as:url,repositoryID:repositoryID) else { throw PRWriteFailure.unavailable }
            let response=try await client.get(current,token:credential.accessToken);bytes += response.data.count
            guard bytes<=12_000_000,let page=try JSONSerialization.jsonObject(with:response.data) as? [Object] else { throw PRWriteFailure.unavailable }
            values += page;guard values.count<=3000 else { throw PRWriteFailure.unavailable }
            next=try GitHubPagination.next(response.header("Link"),client:client,requested:url,repositoryID:repositoryID)
        }
        return values
    }
    func completeConnection(_ first:Object,load:(String) async throws -> Object) async throws -> Object {
        var connection=first,nodes=list(first["nodes"]),cursors:Set<String>=[],bytes=try JSONSerialization.data(withJSONObject:first).count
        while object(connection["pageInfo"])["hasNextPage"] as? Bool == true {
            guard cursors.count<29,let cursor=object(connection["pageInfo"])["endCursor"] as? String,cursors.insert(cursor).inserted else { throw PRWriteFailure.unavailable }
            connection=try await load(cursor);nodes += list(connection["nodes"])
            bytes += try JSONSerialization.data(withJSONObject:connection).count
            guard nodes.count<=3000,bytes<=12_000_000 else { throw PRWriteFailure.unavailable }
        }
        guard object(connection["pageInfo"])["hasNextPage"] as? Bool == false else { throw PRWriteFailure.unavailable }
        connection["nodes"]=nodes;return connection
    }
    func inspect(_ t:MergeTarget, includeNativeAdmission:Bool = true) async throws -> MergeInspection {
        guard t.key.host == "github.com",!t.gitHubNodeID.isEmpty else { throw PRWriteFailure.unavailable }
        let data=try await query(Self.admissionQuery,["id":t.gitHubNodeID])
        let p=object(data["node"]),repo=object(p["repository"]),viewer=object(data["viewer"])
        guard p["id"] as? String == t.gitHubNodeID,p["number"] as? Int == t.number,repo["nameWithOwner"] as? String == t.repository,String(describing:repo["databaseId"] ?? "") == t.key.repositoryID,String(describing:viewer["databaseId"] ?? "") == t.key.accountID,let head=p["headRefOid"] as? String,let base=p["baseRefOid"] as? String,let branch=p["baseRefName"] as? String else { throw PRWriteFailure.unavailable }
        var e=MergeEvidence(key:t.key,head:head,base:base,branch:branch,fetchedAt:Date())
        e.open=p["state"] as? String == "OPEN";e.draft=p["isDraft"] as? Bool ?? true;e.behind=p["mergeStateStatus"] as? String == "BEHIND"
        e.conflictFree=(p["mergeable"] as? String).flatMap { $0 == "MERGEABLE" ? true : $0 == "CONFLICTING" ? false : nil }
        e.actorAllowed=["WRITE","MAINTAIN","ADMIN"].contains(repo["viewerPermission"] as? String ?? "")
        e.tokenCanWrite=credential.scopes.contains("repo") || (repo["isPrivate"] as? Bool == false && credential.scopes.contains("public_repo"))
        e.asyncSupported=true
        e.methods=MergeMethod.allCases;e.methodReasons=[:]
        e.removeMethods(because:"Disabled in repository settings") { repo[$0 == .merge ? "mergeCommitAllowed" : $0 == .squash ? "squashMergeAllowed" : "rebaseMergeAllowed"] as? Bool != true }
        e.canEnableAutoMerge=repo["autoMergeAllowed"] as? Bool == true && p["viewerCanEnableAutoMerge"] as? Bool == true
        e.canDisableAutoMerge=p["viewerCanDisableAutoMerge"] as? Bool == true;e.canUpdateBranch=p["viewerCanUpdateBranch"] as? Bool == true
        e.autoMergeEnabled=p["autoMergeRequest"] is Object;e.queued=p["isInMergeQueue"] as? Bool == true
        // No ordinary can-enqueue/dequeue oracle. Removal uses baseline actor access and
        // configured actor restriction evidence, with the provider still enforcing dispatch.
        let ref=object(p["baseRef"]),classic=object(ref["branchProtectionRule"])
        e.rulesComplete=ref.keys.contains("branchProtectionRule")
        var configured:[Object]=[],rulesetNames:[Int:String]=[:]
        do {
            configured=try await restList(client.origin.appendingPathComponent("repos/\(t.repository)/rules/branches").appendingPathComponent(branch).appending(queryItems:[.init(name:"per_page",value:"100")]),repositoryID:t.key.repositoryID)
            let scopes=try await restList(client.origin.appendingPathComponent("repos/\(t.repository)/rulesets").appending(queryItems:[.init(name:"per_page",value:"100"),.init(name:"includes_parents",value:"true")]),repositoryID:t.key.repositoryID)
            if scopes.contains(where:{ $0["enforcement"] as? String == "active" && !["branch","tag"].contains($0["target"] as? String ?? "") }) { e.requirements.append(.init(name:"Push or repository-wide rule evaluation",state:.unknown)) }
            for scope in scopes { if let id=scope["id"] as? Int,let name=scope["name"] as? String { rulesetNames[id]=name } }
        } catch { if error as? GitHubFailure == .invalidAuthentication || error as? GitHubFailure == .scopeRequired || error as? GitHubFailure == .organizationRestricted { throw error };Log.merge.info("Branch rules unavailable; evidence stays incomplete: \(Log.kind(error), privacy: .public)");e.rulesComplete=false;e.limitations.append("Applicable branch and inherited push rules could not be read completely.") }
        e.ruleIdentity=String(data:try JSONSerialization.data(withJSONObject:["classic":classic,"rules":configured],options:.sortedKeys),encoding:.utf8) ?? ""
        if classic["restrictsPushes"] as? Bool == true {
            do {
                let allowances=try await completeConnection(object(classic["pushAllowances"])) { cursor in
                    let data=try await query(Self.pushAllowancesQuery,["id":classic["id"] as? String,"after":cursor])
                    return object(object(data["node"])["pushAllowances"])
                }
                let actors=list(allowances["nodes"]).map { object($0["actor"]) }
                if actors.contains(where:{ $0["__typename"] as? String == "User" && $0["id"] as? String == viewer["id"] as? String }) {}
                else if actors.contains(where:{ $0["__typename"] as? String == "Team" }) {
                    guard !credential.scopes.isDisjoint(with:["read:org","write:org","admin:org"]) else { throw PRWriteFailure.unavailable }
                    let teams=try await restList(client.origin.appendingPathComponent("user/teams").appending(queryItems:[.init(name:"per_page",value:"100")]))
                    let ids=Set(teams.compactMap { $0["node_id"] as? String })
                    e.actorAllowed=e.actorAllowed == true && actors.contains { $0["__typename"] as? String == "Team" && ids.contains($0["id"] as? String ?? "") }
                } else { e.actorAllowed=false }
            } catch { if error as? GitHubFailure == .invalidAuthentication { throw error };Log.merge.info("Push allowance evidence unavailable; actor stays unknown: \(Log.kind(error), privacy: .public)");e.actorAllowed=nil;e.limitations.append("Configured push allowance or authoritative membership evidence is incomplete.") }
        }
        e.canRemoveQueue=e.actorAllowed == true && e.tokenCanWrite == true && e.rulesComplete
        var required:[MergeCheckRequirement]=list(classic["requiredStatusChecks"]).compactMap { item in
            guard let context=item["context"] as? String else { return nil };return .init(context:context,appID:object(item["app"])["databaseId"] as? Int)
        }
        var reviewRequired=(classic["requiredApprovingReviewCount"] as? Int ?? 0)>0 || classic["requiresCodeOwnerReviews"] as? Bool == true || classic["requireLastPushApproval"] as? Bool == true
        if classic["requiresApprovingReviews"] as? Bool == true && classic["requiredApprovingReviewCount"] == nil { e.requirements.append(.init(name:"Required review count",state:.unknown)) }
        var threadsRequired=classic["requiresConversationResolution"] as? Bool == true
        var strict=classic["requiresStrictStatusChecks"] as? Bool == true
        var signatures=classic["requiresCommitSignatures"] as? Bool == true
        var linear=classic["requiresLinearHistory"] as? Bool == true
        if classic["requiresDeployments"] as? Bool == true { e.requirements.append(.init(name:"Required deployment evaluation",state:.unknown)) }
        for rule in configured {
            let type=rule["type"] as? String ?? "unknown",parameters=object(rule["parameters"])
            switch type {
            case "pull_request":
                if ["dismiss_stale_reviews_on_push","require_code_owner_review","require_last_push_approval","required_approving_review_count","required_review_thread_resolution"].contains(where:{ parameters[$0] == nil }) { e.requirements.append(.init(name:"Incomplete pull-request rule parameters",state:.unknown)) }
                if !list(parameters["required_reviewers"]).isEmpty { reviewRequired=true }
                reviewRequired=reviewRequired || (parameters["required_approving_review_count"] as? Int ?? 0)>0 || parameters["require_code_owner_review"] as? Bool == true || parameters["require_last_push_approval"] as? Bool == true
                threadsRequired=threadsRequired || parameters["required_review_thread_resolution"] as? Bool == true
                if let allowed=parameters["allowed_merge_methods"] as? [String] { e.removeMethods(because:((rule["ruleset_id"] as? Int).flatMap { rulesetNames[$0] }).map { "Not allowed by ruleset '\($0)'" } ?? "Not allowed by a ruleset") { !allowed.contains($0.rawValue) } }
            case "required_status_checks":
                if parameters["required_status_checks"] as? [Object] == nil || parameters["strict_required_status_checks_policy"] as? Bool == nil { e.requirements.append(.init(name:"Incomplete required-check parameters",state:.unknown)) }
                strict=strict || parameters["strict_required_status_checks_policy"] as? Bool == true
                required += list(parameters["required_status_checks"]).compactMap { item in guard let context=item["context"] as? String else { return nil };return .init(context:context,appID:item["integration_id"] as? Int) }
            case "required_linear_history":linear=true
            case "required_signatures":signatures=true
            case "merge_queue":e.queueRequired=true
            case "non_fast_forward","deletion":break // Neither merge nor MERGE update forces/deletes refs.
            default:e.requirements.append(.init(name:"Unsupported applicable rule: \(type)",state:.unknown))
            }
        }
        e.queueRequired=e.queueRequired || p["isMergeQueueEnabled"] as? Bool == true
        e.queueMethod=(object(object(p["mergeQueue"])["configuration"])["mergeMethod"] as? String).flatMap { MergeMethod(rawValue:$0.lowercased()) }
        if linear { e.removeMethods(because:"Linear history required") { $0 == .merge } }
        if reviewRequired { e.requirements.append(.init(name:"Required reviews (provider evaluation)",state:p["reviewDecision"] as? String == "APPROVED" ? .satisfied : .pending)) }
        if strict && !e.queueRequired { e.requirements.append(.init(name:"Branch up to date",state:e.behind ? .pending : ["CLEAN","UNSTABLE","HAS_HOOKS"].contains(p["mergeStateStatus"] as? String ?? "") ? .satisfied : .unknown)) }
        let commits=object(p["commits"]),commitNodes=list(commits["nodes"]),commitsComplete=object(commits["pageInfo"])["hasNextPage"] as? Bool == false
        if signatures { e.requirements.append(.init(name:"Commit signatures",state:commitsComplete && !commitNodes.isEmpty && commitNodes.allSatisfy { object(object($0["commit"])["signature"])["isValid"] as? Bool == true } ? .satisfied : .unknown)) }
        if threadsRequired {
            let threads=object(p["reviewThreads"])
            e.requirements.append(.init(name:"Resolved review threads",state:object(threads["pageInfo"])["hasNextPage"] as? Bool != false ? .unknown : list(threads["nodes"]).allSatisfy { $0["isResolved"] as? Bool == true } ? .satisfied : .pending))
        }
        var checks:[MergeCheck]=[],checksComplete=true
        for commit in [object(p["headRef"])["target"],p["potentialMergeCommit"]] {
            let commit=object(commit);guard let sha=commit["oid"] as? String else { continue }
            let rollup=object(commit["statusCheckRollup"]),contexts=object(rollup["contexts"])
            if !contexts.isEmpty && object(contexts["pageInfo"])["hasNextPage"] as? Bool != false { checksComplete=false }
            for check in list(contexts["nodes"]) {
                let suite=object(check["checkSuite"]),app=object(suite["app"]),workflow=object(suite["workflowRun"])
                let status=check["__typename"] as? String == "StatusContext"
                var state=(check[status ? "state" : "conclusion"] as? String) ?? "PENDING"
                if !status && check["status"] as? String != "COMPLETED" { state="PENDING" }
                if workflow["event"] as? String == "workflow_dispatch",configured.contains(where:{ $0["type"] as? String == "required_status_checks" }) { state="PENDING" }
                checks.append(.init(context:check[status ? "context" : "name"] as? String ?? "",appID:app["databaseId"] as? Int,sha:sha,state:state,kind:status ? .status : .check))
            }
        }
        for requirement in required { e.requirements.append(.init(name:"Required check \(requirement.context)\(requirement.appID.map { " (App \($0))" } ?? "")",state:checksComplete ? MergePolicy.checkState(requirement,checks:checks,head:head,testMerge:object(p["potentialMergeCommit"])["oid"] as? String) : .unknown)) }
        if classic["requiresStatusChecks"] as? Bool == true && classic["requiredStatusChecks"] == nil { e.requirements.append(.init(name:"Required check identities",state:.unknown)) }
        e.optionalFailures=checks.filter { !["SUCCESS","NEUTRAL","SKIPPED"].contains($0.state) && !required.contains(.init(context:$0.context,appID:$0.appID)) }.map(\.context)
        if !["CLEAN","UNSTABLE","HAS_HOOKS","BEHIND"].contains(p["mergeStateStatus"] as? String ?? "UNKNOWN") { e.requirements.append(.init(name:"Provider merge state",state:.unknown)) }
        var m=PRMetadata(number:t.number,webURL:URL(string:p["url"] as? String ?? "https://github.com/\(t.repository)/pull/\(t.number)")!,repositoryName:t.repository)
        m.headRepositoryID=(object(p["headRepository"])["databaseId"] as? Int).map(String.init);m.headBranch=p["headRefName"] as? String ?? "";m.baseBranch=branch;m.baseRevision=base;m.viewerID=viewer["id"] as? String;m.mergeable=p["mergeable"] as? String;m.reviewDecision=p["reviewDecision"] as? String;m.fetchedAt=Date();m.autoMerge=e.autoMergeEnabled;m.autoMergeKnown=true;m.mergedAt=(p["mergedAt"] as? String).flatMap(GitHubDate.parse);m.mergeEvidence=e;m.mergeEligible=MergePolicy.evaluate(e).eligible
        let pr=PullRequest(key:t.key,headRevision:.init(head),title:p["title"] as? String ?? "",state:p["state"] as? String == "MERGED" ? .merged : e.open ? .open : .closed,isDraft:e.draft,metadata:m)
        var stack:PRStack?
        if let native=p["stack"] as? Object {
            var connection=object(native["entries"])
            do {
                connection=try await completeConnection(connection) { cursor in
                    let data=try await query(Self.stackPageQuery,["id":t.gitHubNodeID,"after":cursor])
                    let node=object(data["node"]),stack=object(node["stack"])
                    guard node["headRefOid"] as? String == head,stack["id"] as? String == native["id"] as? String else { throw PRWriteFailure.revisionChanged };return object(stack["entries"])
                }
            } catch { if error as? GitHubFailure == .invalidAuthentication { throw error };Log.merge.info("Native stack pages unavailable; stack stays incomplete: \(Log.kind(error), privacy: .public)");connection["pageInfo"]=["hasNextPage":true] }
            let entries=list(connection["nodes"]).compactMap { entry -> StackGraph.Entry? in
                let row=object(entry["pullRequest"]);guard let node=row["id"] as? String,let n=row["number"] as? Int,let head=row["headRefOid"] as? String,let position=entry["position"] as? Int else { return nil }
                var metadata=PRMetadata(number:n,webURL:URL(string:"https://github.com/\(t.repository)/pull/\(n)")!,repositoryName:t.repository);metadata.headBranch=row["headRefName"] as? String ?? "";metadata.baseBranch=row["baseRefName"] as? String ?? "";metadata.baseRevision=row["baseRefOid"] as? String ?? ""
                let key=ProviderKey(host:t.key.host,accountID:t.key.accountID,repositoryID:t.key.repositoryID,objectID:"pull-request:"+node)
                return .init(position:position,pr:.init(key:key,headRevision:.init(head),title:row["title"] as? String ?? "",state:row["state"] as? String == "MERGED" ? .merged : row["state"] as? String == "CLOSED" ? .closed : .open,isDraft:row["isDraft"] as? Bool ?? true,metadata:metadata))
            }
            // Native API documents linear history as a prerequisite, but exposes no Boolean.
            // Verify each entry's bounded commits rather than inventing a server canMerge flag.
            let allLinear=list(connection["nodes"]).allSatisfy { entry in
                let commits=object(object(entry["pullRequest"])["commits"])
                return object(commits["pageInfo"])["hasNextPage"] as? Bool == false && list(commits["nodes"]).allSatisfy { object(object($0["commit"])["parents"])["totalCount"] as? Int == 1 }
            }
            stack=StackGraph.native(id:native["id"] as? String ?? "",number:native["number"] as? Int ?? 0,size:native["size"] as? Int ?? 0,entries:entries,complete:object(connection["pageInfo"])["hasNextPage"] as? Bool == false,linear:allLinear)
        }
        if let stack {
            e.nativeAdmissionVersion = 1
            e.nativeAdmission = .init(name:"Native affected-layer admission has not been established",state:.unknown)
            if includeNativeAdmission {
                do {
                    let affected = try stack.affected(upTo:t.key)
                    guard affected.count <= 20 else { throw PRWriteFailure.unavailable }
                    e.nativeAffected = affected.map(\.key)
                    var reasons: [String] = []
                    var hasUnknownProof = false
                    var methods = Set(e.methods)
                    for layer in affected where layer.key != t.key {
                        let lower = try await inspect(MergeTarget(layer),includeNativeAdmission:false)
                        guard lower.pr.headRevision == layer.headRevision,
                              let lowerStack = lower.stack,
                              lowerStack.id == stack.id,
                              lowerStack.revisionSignature == stack.revisionSignature else { throw PRWriteFailure.revisionChanged }
                        let prefix = "Layer #\(layer.metadata?.number ?? 0): "
                        guard lowerStack.warnings.isEmpty else {
                            // Matching revisions do not establish complete pagination,
                            // linearity, valid membership positions or absence of gaps.
                            reasons += lowerStack.warnings.map { prefix + $0 }
                            hasUnknownProof = true
                            continue
                        }
                        // Only the nonrecursive placeholder is removed after validating
                        // the lower topology. Unknown ordinary evidence remains unknown.
                        var evidence = lower.evidence
                        evidence.nativeAdmission = nil
                        let policy = MergePolicy.evaluate(evidence)
                        if MergePolicy.requirementState(evidence) == .unknown { hasUnknownProof = true }
                        if !policy.eligible { reasons += policy.reasons.map { prefix + $0 } }
                        if evidence.queueRequired != e.queueRequired || evidence.queueMethod != e.queueMethod {
                            reasons.append("Affected layer queue configuration differs.")
                        }
                        for method in MergeMethod.allCases where methods.contains(method) && !evidence.methods.contains(method) && e.methodReasons?[method.rawValue] == nil {
                            e.methodReasons?[method.rawValue]="Not allowed by stack layer #\(layer.metadata?.number ?? 0)"+(evidence.methodReasons?[method.rawValue].map { " (\($0))" } ?? "")
                        }
                        methods.formIntersection(evidence.methods)
                    }
                    e.methods = MergeMethod.allCases.filter { methods.contains($0) }
                    let state: MergeRequirementState = hasUnknownProof ? .unknown : reasons.isEmpty ? .satisfied : .pending
                    e.nativeAdmission = .init(name:reasons.isEmpty ? "Native topology and affected layers verified" : reasons.joined(separator:" "),state:state)
                } catch {
                    if error as? GitHubFailure == .invalidAuthentication { throw error }
                    Log.merge.info("Native affected-layer admission unavailable; stays unknown: \(Log.kind(error), privacy: .public)")
                    let reason = stack.warnings.isEmpty ? "Native affected-layer read incomplete, changed, or exceeds the 20-layer admission bound" : stack.warnings.joined(separator:" ")
                    e.nativeAdmission = .init(name:reason,state:.unknown)
                }
            }
        }
        var resolvedMetadata = pr.metadata
        resolvedMetadata?.mergeEvidence = e
        resolvedMetadata?.nativeStack = stack
        resolvedMetadata?.mergeEligible = MergePolicy.evaluate(e).eligible
        let resolvedPR = PullRequest(key:pr.key,headRevision:pr.headRevision,title:pr.title,state:pr.state,isDraft:pr.isDraft,metadata:resolvedMetadata)
        var inspection=MergeInspection(pr:resolvedPR,evidence:e,stack:stack,mergeCommitSHA:object(p["mergeCommit"])["oid"] as? String)
        inspection.headParents=list(object(object(object(p["headRef"])["target"])["parents"])["nodes"]).compactMap { $0["oid"] as? String }
        // A complete, linear chain ending at head proves which base the branch now sits on (rebase update proof).
        let chain=commitNodes.map { object($0["commit"]) }
        func parents(_ commit:Object) -> [String] { list(object(commit["parents"])["nodes"]).compactMap { $0["oid"] as? String } }
        if commitsComplete,let first=chain.first,chain.last?["oid"] as? String == head,chain.allSatisfy({ object($0["parents"])["totalCount"] as? Int == 1 && parents($0).count == 1 }),zip(chain.dropFirst(),chain).allSatisfy({ parents($0.0) == [$0.1["oid"] as? String ?? ""] }) { inspection.linearBase=parents(first).first }
        if let auto=p["autoMergeRequest"] as? Object {
            inspection.autoMergeRequest = .init(method:(auto["mergeMethod"] as? String).flatMap { MergeMethod(rawValue:$0.lowercased()) },commitHeadline:auto["commitHeadline"] as? String,commitBody:auto["commitBody"] as? String,enabledAt:(auto["enabledAt"] as? String).flatMap(GitHubDate.parse))
        }
        // Evidence spans multiple endpoints. Reject a revision/state/actor change during
        // those reads; the mutation additionally carries the selected expected head.
        let final=try await query(Self.identityQuery,["id":t.gitHubNodeID])
        let latest=object(final["node"]),latestRepository=object(latest["repository"])
        guard latest["id"] as? String == t.gitHubNodeID,latest["headRefOid"] as? String == head,latest["baseRefOid"] as? String == base,latest["state"] as? String == p["state"] as? String,latest["isDraft"] as? Bool == p["isDraft"] as? Bool,latestRepository["viewerPermission"] as? String == repo["viewerPermission"] as? String,String(describing:latestRepository["databaseId"] ?? "") == t.key.repositoryID,String(describing:object(final["viewer"])["databaseId"] ?? "") == t.key.accountID else { throw PRWriteFailure.revisionChanged }
        return inspection
    }
    /// Separate read-only prefill query. Not part of `MergeEvidence`: a PR body edit must not change admission.
    func messageDefaults(_ t:MergeTarget) async throws -> MergeMessageDefaults {
        guard t.key.host == "github.com",!t.gitHubNodeID.isEmpty else { throw PRWriteFailure.unavailable }
        let data=try await query(Self.messageDefaultsQuery,["id":t.gitHubNodeID])
        let p=object(data["node"]),repo=object(p["repository"])
        guard p["id"] as? String == t.gitHubNodeID,p["number"] as? Int == t.number,repo["nameWithOwner"] as? String == t.repository,String(describing:repo["databaseId"] ?? "") == t.key.repositoryID,String(describing:object(data["viewer"])["databaseId"] ?? "") == t.key.accountID,let head=p["headRefOid"] as? String else { throw PRWriteFailure.unavailable }
        let settings=MergeMessageSettings(squashTitle:(repo["squashMergeCommitTitle"] as? String).flatMap(MergeMessageSettings.SquashTitle.init) ?? .commitOrPRTitle,squashBody:(repo["squashMergeCommitMessage"] as? String).flatMap(MergeMessageSettings.SquashBody.init) ?? .commitMessages,mergeTitle:(repo["mergeCommitTitle"] as? String).flatMap(MergeMessageSettings.MergeTitle.init) ?? .mergeMessage,mergeBody:(repo["mergeCommitMessage"] as? String).flatMap(MergeMessageSettings.MergeBody.init) ?? .prTitle)
        let connection=object(p["commits"]),author=object(p["author"])["login"] as? String
        let commits=list(connection["nodes"]).map { node -> MergeMessageCommit in
            let c=object(node["commit"])
            return .init(headline:c["messageHeadline"] as? String ?? "",body:c["messageBody"] as? String ?? "",authors:list(object(c["authors"])["nodes"]).map { .init(name:$0["name"] as? String ?? "",email:$0["email"] as? String ?? "",login:object($0["user"])["login"] as? String) })
        }
        let headLabel=[object(p["headRepositoryOwner"])["login"] as? String,p["headRefName"] as? String].compactMap { $0 }.joined(separator:"/")
        var (titles,bodies)=MergeMessageComposer.fallback(settings:settings,prTitle:p["title"] as? String ?? "",prBody:p["body"] as? String ?? "",number:t.number,headLabel:headLabel,commits:commits,prAuthor:author)
        var prefill=false
        for (method,alias) in [(MergeMethod.merge,"merge"),(.squash,"squash")] {
            if let value=p[alias+"Headline"] as? String { titles[method]=value;prefill=true }
            if let value=p[alias+"Body"] as? String { bodies[method]=value;prefill=true }
        }
        // GitHub's squash prefill can name co-authors beyond the single bounded commit page.
        let trailers=MergeMessageComposer.trailers(in:MergeMessageComposer.coAuthors(commits:commits,prAuthor:author).joined(separator:"\n")+"\n"+(bodies[.squash] ?? ""))
        return .init(head:head,titles:titles,bodies:bodies,coAuthorTrailers:trailers,settings:settings,commitsComplete:object(connection["pageInfo"])["hasNextPage"] as? Bool == false,providerPrefill:prefill)
    }
    // GraphQL names per GitHub's public schema: PullRequest.viewerMergeHeadlineText/viewerMergeBodyText(mergeType:PullRequestMergeMethod),
    // Repository.squashMergeCommitTitle/squashMergeCommitMessage/mergeCommitTitle/mergeCommitMessage, Commit.authors(first:).
    static let messageDefaultsQuery="""
    query MergeMessageDefaults($id:ID!) {
      viewer { databaseId }
      node(id:$id) { ... on PullRequest {
        id number title body headRefOid headRefName headRepositoryOwner { login } author { login }
        mergeHeadline: viewerMergeHeadlineText(mergeType:MERGE) mergeBody: viewerMergeBodyText(mergeType:MERGE)
        squashHeadline: viewerMergeHeadlineText(mergeType:SQUASH) squashBody: viewerMergeBodyText(mergeType:SQUASH)
        repository { databaseId nameWithOwner squashMergeCommitTitle squashMergeCommitMessage mergeCommitTitle mergeCommitMessage }
        commits(first:100) { nodes { commit { messageHeadline messageBody authors(first:5) { nodes { name email user { login } } } } } pageInfo { hasNextPage endCursor } }
      } }
      rateLimit { cost remaining resetAt }
    }
    """
    static let checkFields="""
    oid statusCheckRollup { contexts(first:100) {
      nodes { __typename ... on CheckRun { name status conclusion checkSuite { app { databaseId } workflowRun { event } } } ... on StatusContext { context state } }
      pageInfo { hasNextPage endCursor }
    } }
    """
    static let stackEntryFields="""
    position pullRequest {
      id number title state isDraft headRefOid baseRefOid headRefName baseRefName
      commits(first:100) { nodes { commit { parents(first:2) { totalCount } } } pageInfo { hasNextPage endCursor } }
    }
    """
    static let pushActorFields="actor { __typename ... on User { id } ... on Team { id slug } ... on App { id databaseId } }"
    static let pushAllowancesQuery="""
    query PushAllowances($id:ID!,$after:String) {
      node(id:$id) { ... on BranchProtectionRule {
        pushAllowances(first:100,after:$after) { nodes { \(pushActorFields) } pageInfo { hasNextPage endCursor } }
      } }
      rateLimit { cost remaining resetAt }
    }
    """
    static let stackPageQuery="""
    query StackPage($id:ID!,$after:String) {
      node(id:$id) { ... on PullRequest {
        headRefOid
        stack { id entries(first:100,after:$after) {
          nodes { \(stackEntryFields) }
          pageInfo { hasNextPage endCursor }
        } }
      } }
      rateLimit { cost remaining resetAt }
    }
    """
    /// Rechecked after every evidence read: revision, state, actor permission and identity.
    static let identityQuery="""
    query MergeIdentity($id:ID!) {
      viewer { databaseId }
      node(id:$id) { ... on PullRequest { id headRefOid baseRefOid state isDraft repository { databaseId viewerPermission } } }
      rateLimit { cost remaining resetAt }
    }
    """
    static let admissionQuery="""
    query MergeEvidence($id:ID!) {
      viewer { id databaseId login }
      node(id:$id) { ... on PullRequest {
        id number title url state isDraft headRefOid baseRefOid headRefName baseRefName mergedAt mergeCommit { oid }
        mergeable mergeStateStatus reviewDecision isMergeQueueEnabled isInMergeQueue autoMergeRequest { enabledAt mergeMethod commitHeadline commitBody }
        viewerCanEnableAutoMerge viewerCanDisableAutoMerge viewerCanUpdateBranch
        mergeQueue { configuration { mergeMethod } }
        headRepository { databaseId }
        repository { id databaseId nameWithOwner isPrivate viewerPermission mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed autoMergeAllowed }
        baseRef { branchProtectionRule {
          id restrictsPushes requiresApprovingReviews requiredApprovingReviewCount requiresCodeOwnerReviews dismissesStaleReviews requireLastPushApproval
          requiresConversationResolution requiresCommitSignatures requiresDeployments requiredDeploymentEnvironments requiresLinearHistory
          requiresStatusChecks requiresStrictStatusChecks requiredStatusChecks { context app { databaseId } }
          pushAllowances(first:100) { nodes { \(pushActorFields) } pageInfo { hasNextPage endCursor } }
        } }
        headRef { target { ... on Commit { parents(first:2) { nodes { oid } } \(checkFields) } } } potentialMergeCommit { \(checkFields) }
        commits(first:100) { nodes { commit { oid signature { isValid } parents(first:2) { totalCount nodes { oid } } } } pageInfo { hasNextPage endCursor } }
        reviewThreads(first:100) { nodes { isResolved } pageInfo { hasNextPage endCursor } }
        stack { id number size entries(first:100) {
          nodes { \(stackEntryFields) }
          pageInfo { hasNextPage endCursor }
        } }
      } }
      rateLimit { cost remaining resetAt }
    }
    """
}
