import Foundation
import MergeProCore

/// Provider metadata is a requested mapping, never a local filesystem grant.
struct LocalPRCheckoutRequest:Identifiable,Hashable,Sendable {
    let requestID:UUID
    let repository:RepositoryKey
    let repositoryName:String
    let number:Int
    let expectedHeadSHA:String
    let headBranch:String
    let cloneWebURL:URL
    var id:UUID { requestID }
}
