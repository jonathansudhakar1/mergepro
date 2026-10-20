import Foundation

/// An inert Mermaid flowchart subset. Unsupported syntax rejects the whole diagram.
public struct NativeFlowchart:Sendable {
    public enum Direction:Sendable { case vertical,horizontal }
    public struct Node:Sendable,Identifiable { public let id:String;public let label:String }
    public struct Edge:Sendable { public let from:String;public let to:String }
    public let direction:Direction
    public let nodes:[Node]
    public let edges:[Edge]
    public enum Failure:Error { case unsupported }
    public static func parse(_ source:String) throws -> Self {
        guard source.utf8.count <= 8192 else { throw Failure.unsupported }
        let lines=source.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        guard let header=lines.first,["flowchart TD","flowchart TB","flowchart LR","graph TD","graph TB","graph LR"].contains(header) else { throw Failure.unsupported }
        var nodes:[Node]=[];var edges:[Edge]=[]
        func node(_ source:String) throws -> String {
            let value=source.trimmingCharacters(in:.whitespaces)
            let id:String;let label:String
            if let bracket=value.firstIndex(of:"[") {
                guard value.hasSuffix("]") else { throw Failure.unsupported }
                id=String(value[..<bracket]);label=String(value[value.index(after:bracket)..<value.index(before:value.endIndex)])
            } else { id=value;label=value }
            guard !id.isEmpty,id.count <= 32,id.first?.isLetter == true,id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),!label.isEmpty,label.count <= 80,!label.contains(where:{ "<>[]{}\\`".contains($0) }),!label.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw Failure.unsupported }
            if let old=nodes.first(where:{ $0.id == id }) { guard label == id || old.label == label else { throw Failure.unsupported } }
            else { nodes.append(.init(id:id,label:label)) }
            return id
        }
        for line in lines.dropFirst() {
            let parts=line.components(separatedBy:"-->")
            guard parts.count <= 2 else { throw Failure.unsupported }
            let first=try node(parts[0])
            if parts.count == 2 { edges.append(.init(from:first,to:try node(parts[1]))) }
            guard nodes.count <= 16,edges.count <= 24 else { throw Failure.unsupported }
        }
        guard !nodes.isEmpty else { throw Failure.unsupported }
        return .init(direction:header.hasSuffix("LR") ? .horizontal : .vertical,nodes:nodes,edges:edges)
    }
}
