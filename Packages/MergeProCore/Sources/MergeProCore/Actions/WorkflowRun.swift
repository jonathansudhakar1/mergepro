import Foundation

public struct WorkflowRun: Codable, Equatable, Identifiable, Sendable {
    public let repository: Repository
    public let runID: Int64
    public let workflowID: Int64
    public let attempt: Int
    public let name: String
    public let branch: String
    public let headSHA: String
    public let event: String
    public let actor: String
    public let status: String
    public let conclusion: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let startedAt: Date?
    public let webURL: URL?
    public let pullRequestNumbers: [Int]
    public var id: ProviderKey { key }
    public var key: ProviderKey { .init(host:repository.key.account.host,accountID:repository.key.account.accountID,repositoryID:repository.key.repositoryID,objectID:"run:\(runID):\(attempt)") }
    public var isActive: Bool { status != "completed" }
    public var duration: TimeInterval { max(0,updatedAt.timeIntervalSince(startedAt ?? createdAt)) }
    public init(repository:Repository,runID:Int64,workflowID:Int64,attempt:Int,name:String,branch:String,headSHA:String,event:String,actor:String,status:String,conclusion:String?,createdAt:Date,updatedAt:Date,startedAt:Date?=nil,webURL:URL?=nil,pullRequestNumbers:[Int]=[]) {
        self.repository=repository;self.runID=runID;self.workflowID=workflowID;self.attempt=attempt;self.name=name;self.branch=branch;self.headSHA=headSHA;self.event=event;self.actor=actor;self.status=status;self.conclusion=conclusion;self.createdAt=createdAt;self.updatedAt=updatedAt;self.startedAt=startedAt;self.webURL=webURL;self.pullRequestNumbers=pullRequestNumbers
    }
}
public struct ActionsWorkflow: Codable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let path: String
    public let state: String
    public let webURL: URL?
    public let manualTrigger:Bool?
    public init(id:Int64,name:String,path:String,state:String,webURL:URL?,manualTrigger:Bool?=nil) { self.id=id;self.name=name;self.path=path;self.state=state;self.webURL=webURL;self.manualTrigger=manualTrigger }
}
public struct ActionsStep: Codable, Equatable, Identifiable, Sendable {
    public let number: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public var id:Int { number }
}
public struct ActionsJob: Codable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let steps: [ActionsStep]
    public let checkRunID: Int64?
    public let webURL: URL?
}
public struct ActionsArtifact: Codable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let size: Int64
    public let expired: Bool
    public let expiresAt: Date?
}
public struct ActionsAnnotation: Codable, Equatable, Identifiable, Sendable {
    public let path:String
    public let startLine:Int
    public let endLine:Int
    public let level:String
    public let message:String
    public let title:String?
    public var id:String { "\(path):\(startLine):\(endLine):\(level):\(message)" }
}
public struct ActionsEnvironment: Codable, Equatable, Identifiable, Sendable {
    public let id:Int64
    public let name:String
    public let canApprove:Bool
    public let production:Bool
}
public struct ActionsDeployment: Codable, Equatable, Identifiable, Sendable {
    public let id:Int64
    public let environment:String
    public let ref:String
    public let sha:String
    public let production:Bool
    public let state:String
    public let webURL:URL?
}
public struct ActionsCatalog: Codable, Equatable, Sendable {
    public let repository:Repository
    public let runs:[WorkflowRun]
    public let workflows:[ActionsWorkflow]
    public let deployments:[ActionsDeployment]
    public let environments:[ActionsEnvironment]
    public let unavailableSections:[String:String]
    public init(repository:Repository,runs:[WorkflowRun],workflows:[ActionsWorkflow],deployments:[ActionsDeployment],environments:[ActionsEnvironment],unavailableSections:[String:String]=[:]) { self.repository=repository;self.runs=runs;self.workflows=workflows;self.deployments=deployments;self.environments=environments;self.unavailableSections=unavailableSections }
}
public struct ActionsRunDetail: Sendable {
    public let run:WorkflowRun
    public let jobs:[ActionsJob]
    public let artifacts:[ActionsArtifact]
    public let annotations:[ActionsAnnotation]
    public let pendingDeployments:[ActionsEnvironment]
    public let unavailableSections:[String:String]
    public init(run:WorkflowRun,jobs:[ActionsJob],artifacts:[ActionsArtifact],annotations:[ActionsAnnotation],pendingDeployments:[ActionsEnvironment],unavailableSections:[String:String]=[:]) { self.run=run;self.jobs=jobs;self.artifacts=artifacts;self.annotations=annotations;self.pendingDeployments=pendingDeployments;self.unavailableSections=unavailableSections }
}
public enum ActionsLogAvailability: Equatable, Sendable { case available(String), unavailable }
public enum ActionsFailure: Error, Equatable, Sendable {
    case accountChanged, permissionDenied, staleRun, staleSchema, invalidInput(String), noManualTrigger, productionConfirmationRequired, operationInProgress, expiredArtifact, tooLarge, unavailable, persistenceBeforeSend
}

extension ActionsFailure: LocalizedError {
    public var errorDescription:String? {
        switch self {
        case .accountChanged:"The account changed or its authorization was revoked. Refresh before continuing."
        case .permissionDenied:"The current account does not have permission for this action."
        case .staleRun:"The run attempt or status changed. Refresh the run before continuing."
        case .staleSchema:"The workflow revision or inputs changed. Select the ref again and review the current form."
        case .invalidInput(let name):"Enter a valid value for \(name)."
        case .noManualTrigger:"This workflow does not declare a manual trigger at the selected ref."
        case .productionConfirmationRequired:"Confirm this production workflow before running it."
        case .operationInProgress:"A previous request is pending or its outcome is unknown. Reconcile its provider state before continuing."
        case .expiredArtifact:"The artifact expired or its download link is no longer available."
        case .tooLarge:"The download exceeds the supported size limit. Open it on GitHub to download it."
        case .unavailable:"This provider data is unavailable. Refresh or open it on GitHub."
        case .persistenceBeforeSend:"The operation could not be saved locally, so it was not sent."
        }
    }
}
