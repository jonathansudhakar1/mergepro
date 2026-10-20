import Foundation
public enum ActionsLog {
    public enum Color:String,Sendable { case black,red,green,yellow,blue,magenta,cyan,white }
    public struct Span:Sendable { public let text:String;public let color:Color?;public let bold:Bool }
    public struct Line:Identifiable,Sendable { public let number:Int;public let spans:[Span];public var id:Int { number };public var text:String { spans.map(\.text).joined() } }
    public static func safeJobLink(_ url:URL) -> URL? {
        guard url.scheme=="https",url.host=="github.com",url.user==nil,url.password==nil,var components=URLComponents(url:url,resolvingAgainstBaseURL:false) else { return nil }
        components.fragment=nil;return components.url
    }
    public static func parse(_ text:String) -> [Line] {
        let colors:[Color]=[.black,.red,.green,.yellow,.blue,.magenta,.cyan,.white]
        var color:Color?;var bold=false;var lines:[Line]=[]
        for (index,line) in text.components(separatedBy:"\n").enumerated() {
            var spans:[Span]=[];var buffer="";var i=line.startIndex
            func flush() { if !buffer.isEmpty { spans.append(.init(text:buffer,color:color,bold:bold));buffer="" } }
            while i<line.endIndex {
                if line[i]=="\u{1B}" {
                    flush();i=line.index(after:i);guard i<line.endIndex else { break }
                    if line[i]=="[" {
                        i=line.index(after:i);var code=""
                        while i<line.endIndex,line[i].isNumber || line[i]==";" { code.append(line[i]);i=line.index(after:i) }
                        if i<line.endIndex,line[i]=="m" {
                            for number in code.split(separator:";").compactMap({ Int($0) }) {
                                if number==0 { color=nil;bold=false };if number==1 { bold=true };if number==22 { bold=false };if number==39 { color=nil }
                                if (30...37).contains(number) { color=colors[number-30] };if (90...97).contains(number) { color=colors[number-90] }
                            }
                        }
                        if i<line.endIndex { i=line.index(after:i) };continue
                    }
                    if line[i]=="]" { while i<line.endIndex,line[i] != "\u{7}" { i=line.index(after:i) };if i<line.endIndex { i=line.index(after:i) };continue }
                    i=line.index(after:i);continue
                }
                if line[i]=="\t" || line[i]>=" " { buffer.append(line[i]) }
                i=line.index(after:i)
            }
            flush();lines.append(.init(number:index+1,spans:spans))
        }
        return lines
    }
}
