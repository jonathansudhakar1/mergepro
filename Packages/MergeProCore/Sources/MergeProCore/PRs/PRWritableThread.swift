import Foundation

public struct PRWritableComment:Sendable,Identifiable {
    public let id:String
    public let body:String
    public let author:String?
    public let url:URL?
    public let kind:PRCommentKind
    public let own:Bool
    public let canEdit:Bool
    public let canDelete:Bool
    public let canReact:Bool
    public let canModerate:Bool
    public let canUnminimize:Bool
    public let minimized:Bool
    public let coordinates:PRCommentCoordinates?
    public let diffHunk:String?
    public let reviewID:String?
}
public struct PRWritableThread:Sendable,Identifiable {
    public let id:String
    public let path:String
    public let resolved:Bool
    public let outdated:Bool
    public let canReply:Bool
    public let canResolve:Bool
    public let canUnresolve:Bool
    public let comments:[PRWritableComment]
    public let complete:Bool
}
