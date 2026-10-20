import Foundation
import COnigBridge

public struct ScannerMatch: Sendable { public let index:Int;public let captures:[NSRange] }
enum TokenizerFailure: Error { case grammar, budget, regex(Int32), invalidRange }
/// Confined to the single synchronous tokenizer call that created it. C state never crosses an isolation boundary.
final class NativeScanner {
    private let pointer:OpaquePointer
    init(patterns:[String]) throws {
        guard patterns.count <= 512,let pointer=mp_scanner_new() else { throw TokenizerFailure.budget }
        do {
            for pattern in patterns {
                let bytes=Array(pattern.utf8)+[0]
                let status=bytes.withUnsafeBufferPointer { mp_scanner_add(pointer,$0.baseAddress,Int32(bytes.count-1)) }
                guard status == 0 else { throw TokenizerFailure.regex(status) }
            }
        } catch { mp_scanner_free(pointer);throw error }
        self.pointer=pointer
    }
    deinit { mp_scanner_free(pointer) }
    func search(_ text:String,start:Int,flags:Int) throws -> ScannerMatch? {
        let map=UnicodeOffsets(text)
        guard let byteStart=map.utf8(atUTF16:start) else { throw TokenizerFailure.invalidRange }
        var captures=[MPCapture](repeating:.init(start:0,end:0),count:256);var count:Int32=0
        let bytes=Array(text.utf8)+[0]
        let result=bytes.withUnsafeBufferPointer { mp_scanner_search(pointer,$0.baseAddress,Int32(bytes.count-1),Int32(byteStart),Int32(flags),&captures,256,&count) }
        if result == -1 { return nil };guard result >= 0 else { throw TokenizerFailure.regex(result) }
        let ranges=try captures.prefix(Int(count)).map { capture -> NSRange in
            // Match the pinned JS binding: unsigned sentinel clamps to UTF-16 end for
            // non-ASCII text, and remains UInt32.max on its ASCII identity path.
            if capture.start < 0 { return NSRange(location:text.utf8.count == text.utf16.count ? Int(UInt32.max) : text.utf16.count,length:0) }
            guard let lo=map.utf16(atUTF8:Int(capture.start)),let hi=map.utf16(atUTF8:Int(capture.end)),hi >= lo else { throw TokenizerFailure.invalidRange }
            return NSRange(location:lo,length:hi-lo)
        }
        return .init(index:Int(result),captures:ranges)
    }
}
struct UnicodeOffsets {
    private var to8:[Int:Int]=[:]
    private var to16:[Int:Int]=[:]
    init(_ text:String) {
        var i8=0,i16=0;to8[0]=0;to16[0]=0
        for scalar in text.unicodeScalars {
            let n8=scalar.utf8.count,n16=scalar.utf16.count
            for i in 0..<n8 { to16[i8+i]=i16 };for i in 0..<n16 { to8[i16+i]=i8 }
            i8 += n8;i16 += n16;to8[i16]=i8;to16[i8]=i16
        }
    }
    func utf8(atUTF16 offset:Int) -> Int? { to8[offset] }
    func utf16(atUTF8 offset:Int) -> Int? { to16[offset] }
}
