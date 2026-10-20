import Foundation
import Markdown

/// Sendable presentation values from a real GFM AST. No HTML renderer or executable content.
public struct NativeMarkdown:Sendable {
    public struct Styles:OptionSet,Sendable,Equatable {
        public let rawValue:Int
        public init(rawValue:Int) { self.rawValue=rawValue }
        public static let strong=Self(rawValue:1),emphasis=Self(rawValue:2),strike=Self(rawValue:4),code=Self(rawValue:8)
    }
    public struct Run:Sendable,Equatable {
        public var text:String
        public var styles:Styles=[]
        public var destination:URL?
        public var image=false
        public var linkDestination:URL?
    }
    public struct Block:Sendable {
        public enum Kind:Sendable { case paragraph,heading,list,item,quote,code,table,rule,literal }
        public enum Alignment:Sendable { case left,center,right }
        public var kind:Kind
        public var inlines:[Run]=[]
        public var children:[Block]=[]
        public var rows:[[[Run]]]=[]
        public var alignments:[Alignment]=[]
        public var level=0
        public var listStart:Int?
        public var checked:Bool?
        public var literal=""
        public var language=""
    }
    public let blocks:[Block]
    public enum Failure:Error { case boundedFallback }
    public static func parse(_ source:String) throws -> Self {
        guard source.utf8.count <= 262_144 else { throw Failure.boundedFallback }
        let document=Document(parsing:source,options:[.disableSmartOpts])
        let detector=try NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue)
        var count=0
        func admit(_ depth:Int) throws { count += 1;guard count <= 4096,depth <= 24 else { throw Failure.boundedFallback } }
        func safeURL(_ value:String?) -> URL? {
            guard let value,let url=URL(string:value),url.scheme?.lowercased() == "https",url.user == nil,url.password == nil else { return nil };return url
        }
        /// Bare `www.` text is detected as http but names no scheme, so it links over https; explicit http stays plain text.
        func detectedURL(_ match:NSTextCheckingResult,_ text:String) -> URL? {
            guard let url=match.url,var parts=URLComponents(url:url,resolvingAgainstBaseURL:false) else { return nil }
            if parts.scheme?.lowercased() == "http",!text.lowercased().hasPrefix("http:") { parts.scheme="https" }
            return safeURL(parts.url?.absoluteString)
        }
        func plainRuns(_ text:String,_ style:Styles,_ depth:Int) throws -> [Run] {
            let ns=text as NSString
            var result:[Run]=[],offset=0
            for match in detector.matches(in:text,range:NSRange(location:0,length:ns.length)) {
                guard match.range.location >= offset,NSMaxRange(match.range) <= ns.length,let url=detectedURL(match,ns.substring(with:match.range)) else { continue }
                if match.range.location > offset { try admit(depth);result.append(.init(text:ns.substring(with:NSRange(location:offset,length:match.range.location-offset)),styles:style)) }
                try admit(depth);result.append(.init(text:ns.substring(with:match.range),styles:style,destination:url));offset=NSMaxRange(match.range)
            }
            if offset < ns.length { try admit(depth);result.append(.init(text:ns.substring(from:offset),styles:style)) };return result
        }
        func inline(_ node:any Markup,_ depth:Int,_ style:Styles = [],_ detectLinks:Bool = true) throws -> [Run] {
            try admit(depth)
            switch node {
            case let text as Markdown.Text:return try detectLinks ? plainRuns(text.string,style,depth) : [.init(text:text.string,styles:style)]
            case is SoftBreak:return [.init(text:" ",styles:style)]
            case is LineBreak:return [.init(text:"\n",styles:style)]
            case let code as InlineCode:return [.init(text:code.code,styles:style.union(.code))]
            case let html as InlineHTML:return [.init(text:html.rawHTML,styles:style)]
            case let image as Markdown.Image:return [.init(text:image.plainText,styles:style,destination:safeURL(image.source),image:true)]
            case let link as Markdown.Link:return try link.children.flatMap { try inline($0,depth+1,style,false) }.map { var run=$0;if run.image { run.linkDestination=safeURL(link.destination) } else { run.destination=safeURL(link.destination) };return run }
            case is Strong:return try node.children.flatMap { try inline($0,depth+1,style.union(.strong),detectLinks) }
            case is Emphasis:return try node.children.flatMap { try inline($0,depth+1,style.union(.emphasis),detectLinks) }
            case is Strikethrough:return try node.children.flatMap { try inline($0,depth+1,style.union(.strike),detectLinks) }
            default:return [.init(text:node.format(),styles:style)]
            }
        }
        func inlines(_ node:any Markup,_ depth:Int) throws -> [Run] { try node.children.flatMap { try inline($0,depth+1) } }
        func block(_ node:any Markup,_ depth:Int) throws -> Block {
            try admit(depth)
            switch node {
            case let heading as Heading:return .init(kind:.heading,inlines:try inlines(heading,depth),level:heading.level)
            case is Paragraph:return .init(kind:.paragraph,inlines:try inlines(node,depth))
            case let code as CodeBlock:return .init(kind:.code,literal:code.code,language:code.language ?? "")
            case let html as HTMLBlock:return .init(kind:.literal,literal:html.rawHTML)
            case is ThematicBreak:return .init(kind:.rule)
            case is BlockQuote:return .init(kind:.quote,children:try node.children.map { try block($0,depth+1) })
            case let list as OrderedList:return .init(kind:.list,children:try node.children.map { try block($0,depth+1) },listStart:Int(list.startIndex))
            case is UnorderedList:return .init(kind:.list,children:try node.children.map { try block($0,depth+1) })
            case let item as ListItem:return .init(kind:.item,children:try node.children.map { try block($0,depth+1) },checked:item.checkbox.map { $0 == .checked })
            case let table as Markdown.Table:
                guard table.maxColumnCount <= 16,table.body.childCount <= 128 else { throw Failure.boundedFallback }
                var rows=[try table.head.children.map { try inlines($0,depth+1) }]
                rows += try table.body.children.map { row in try row.children.map { try inlines($0,depth+1) } }
                return .init(kind:.table,rows:rows,alignments:table.columnAlignments.map { $0 == .center ? .center : $0 == .right ? .right : .left })
            default:return .init(kind:.literal,literal:node.format())
            }
        }
        return .init(blocks:try document.children.map { try block($0,0) })
    }
}
public actor NativeMarkdownWorker {
    public static let shared=NativeMarkdownWorker()
    public func parse(_ source:String) throws -> NativeMarkdown { try Task.checkCancellation();return try NativeMarkdown.parse(source) }
}
