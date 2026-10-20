import Foundation

public struct MetadataService:Sendable {
    public let coordinator:PRWriteCoordinator
    public init(coordinator:PRWriteCoordinator) { self.coordinator=coordinator }
    public func update(pr:PullRequest,revision:PRWriteRevision,mutation:PRMetadataMutation) async throws -> PRWriteOperation {
        guard let m=pr.metadata else { throw PRWriteFailure.unavailable }
        return try await coordinator.perform(.init(key:pr.key,repository:m.repositoryName,number:m.number,revision:revision,intent:.metadata(mutation)))
    }
}
