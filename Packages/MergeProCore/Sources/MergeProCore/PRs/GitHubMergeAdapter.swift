import Foundation

public protocol MergeAdapter:Sendable {
    func inspect(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeInspection
    func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse
    func status(_ id:UUID,target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse
    /// Read-only commit-text prefill. Kept out of `inspect` so a body edit never changes admission.
    func messageDefaults(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeMessageDefaults?
}
public extension MergeAdapter {
    /// Adapters without a provider prefill (fixtures) present empty, unedited text.
    func messageDefaults(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeMessageDefaults? { nil }
}
public struct GitHubMergeAdapter:MergeAdapter {
    public init() {}
    public static func request(_ operation:PRWriteOperation) throws -> GitHubPRWriteAdapter.Request {
        guard case .merge(let c)=operation.command.intent,let action=MergeAction(rawValue:c.action),MergeMethod(rawValue:c.method) != nil,!c.expectedHeadSHA.isEmpty else { throw PRWriteFailure.unavailable }
        let t=c.target,parts=t.repository.split(separator:"/",omittingEmptySubsequences:false)
        guard t.key.host == "github.com",!t.gitHubNodeID.isEmpty,t.number>0,parts.count==2,parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { throw PRWriteFailure.unavailable }
        func request(_ path:String,_ method:String,_ body:[String:Any]) throws -> GitHubPRWriteAdapter.Request { .init(path:path,method:method,body:try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)) }
        let root="repos/\(t.repository)/pulls/\(t.number)"
        // Commit text is sent only when the user overrode it, and never for rebase (also guards decoded legacy commands).
        let text=c.method != MergeMethod.rebase.rawValue
        if [.direct,.queue].contains(action) {
            var body:[String:Any]=["sha":c.expectedHeadSHA,"merge_action":c.action,"bypass_rules":false]
            if action == .direct {
                body["merge_method"]=c.method
                if text,let title=c.title { body["commit_title"]=title };if text,let message=c.message { body["commit_message"]=message }
            }
            return try request(root+"/merge-async","PUT",body)
        }
        if action == .updateBranch {
            // Nil (legacy) is the nonforce merge update; an unknown stored value is never guessed.
            let update:MergeUpdateMethod?=c.updateMethod.map { MergeUpdateMethod(rawValue:$0) } ?? .merge
            guard let update else { throw PRWriteFailure.unavailable }
            if update == .merge { return try request(root+"/update-branch","PUT",["expected_head_sha":c.expectedHeadSHA]) }
        }
        let name:String,type:String,fields:String
        var input:[String:Any]=["pullRequestId":t.gitHubNodeID,"clientMutationId":operation.id.uuidString]
        switch action {
        case .enableAutoMerge:
            name="enablePullRequestAutoMerge";type="EnablePullRequestAutoMergeInput";fields="pullRequest { id autoMergeRequest { enabledAt mergeMethod commitHeadline commitBody } }"
            input["expectedHeadOid"]=c.expectedHeadSHA;input["mergeMethod"]=c.method.uppercased()
            if text,let title=c.title { input["commitHeadline"]=title };if text,let message=c.message { input["commitBody"]=message }
        case .disableAutoMerge:name="disablePullRequestAutoMerge";type="DisablePullRequestAutoMergeInput";fields="pullRequest { id autoMergeRequest { enabledAt } }"
        case .removeQueue:name="dequeuePullRequest";type="DequeuePullRequestInput";fields="mergeQueueEntry { id }"
        case .updateBranch:
            // Rebase update rewrites the head; only the GraphQL mutation offers it, still bound to the expected head.
            name="updatePullRequestBranch";type="UpdatePullRequestBranchInput";fields="pullRequest { id headRefOid }"
            input["expectedHeadOid"]=c.expectedHeadSHA;input["updateMethod"]="REBASE"
        default:throw PRWriteFailure.unavailable
        }
        return try request("graphql","POST",["query":"mutation MergeAction($input:\(type)!) { \(name)(input:$input) { clientMutationId \(fields) } }","variables":["input":input]])
    }
    public func inspect(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeInspection { try await GitHubMergeReader(client:client,credential:credential).inspect(target) }
    public func messageDefaults(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeMessageDefaults? { try await GitHubMergeReader(client:client,credential:credential).messageDefaults(target) }
    public func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse {
        let request=try Self.request(operation)
        if request.path == "graphql" { return try await GitHubPRWriteAdapter().send(operation,client:client,credential:credential) }
        let response=try await client.mutate(path:request.path,method:request.method,body:request.body,token:credential.accessToken,acceptedStatuses:[400,409,422])
        guard response.data.count<=8_000_000 else { throw PRDetailFailure.oversized };return response
    }
    public func status(_ id:UUID,target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse {
        try await client.get(client.origin.appendingPathComponent("repos/\(target.repository)/pulls/\(target.number)/merge-async/\(id.uuidString)"),token:credential.accessToken)
    }
    public static func pendingID(_ response:GitHubResponse,command:MergeCommand) throws -> UUID? {
        let root=try JSONSerialization.jsonObject(with:response.data) as? [String:Any] ?? [:]
        guard root["status"] as? String == "pending" else { return nil }
        let details=root["details"] as? [String:Any] ?? [:]
        guard let id=(details["uuid"] as? String).flatMap(UUID.init(uuidString:)),details["expected_head_sha"] as? String == command.expectedHeadSHA,details["merge_action"] as? String == command.action,(details["bypass_rules"] as? Bool ?? false) == false else { throw PRWriteFailure.uncertain }
        let method=details["merge_method"] as? String
        guard command.action == MergeAction.queue.rawValue ? ["default",command.method].contains(method ?? "") : method == command.method else { throw PRWriteFailure.uncertain }
        // Existing-operation responses omit custom commit fields; matching cannot be proven for any override,
        // including a deliberately blank body. Unedited text is nil and follows GitHub's default.
        if response.status == 409,command.title != nil || command.message != nil { throw PRWriteFailure.uncertain }
        return id
    }
}
