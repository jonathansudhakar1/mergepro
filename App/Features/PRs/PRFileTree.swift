import Foundation
import MergeProCore

struct PRFileTree:Identifiable {
    let id:String
    let name:String
    let file:DiffFile?
    let children:[PRFileTree]?
    static func build(_ files:[DiffFile],prefix:String = "") -> [PRFileTree] {
        let groups=Dictionary(grouping:files) { file in String(file.path.dropFirst(prefix.count).split(separator:"/").first ?? "") }
        return groups.keys.sorted().map { name in
            let path=prefix+name,values=groups[name]!
            if let file=values.first(where:{ $0.path == path }) { return .init(id:path,name:name,file:file,children:nil) }
            return .init(id:path,name:name,file:nil,children:build(values,prefix:path+"/"))
        }
    }
}
