import Foundation

public enum MarkdownRasterFailure:Error,Equatable { case unsafeURL,unavailable,oversized,unsupported }
public enum MarkdownRasterPolicy {
    public static let maximumBytes=2_000_000
    /// Public, unsigned URLs only. Authentication and signed-query assets must link out.
    public static func approved(_ url:URL) -> URL? {
        guard url.scheme?.lowercased() == "https",url.user == nil,url.password == nil,url.query == nil,(url.port ?? 443) == 443,
              let host=url.host?.lowercased(),!url.path.split(separator:"/").contains("..") else { return nil }
        guard ["user-images.githubusercontent.com","raw.githubusercontent.com"].contains(host) || host == "github.com" && url.path.hasPrefix("/user-attachments/assets/") else { return nil }
        var value=URLComponents(url:url,resolvingAgainstBaseURL:false);value?.fragment=nil
        return value?.url
    }
}
/// No account/session reference exists here. Asset denial cannot revoke a GitHub credential.
public struct MarkdownRasterClient:Sendable {
    private let transport:any GitHubTransport
    public init(transport:any GitHubTransport = AnonymousRasterTransport()) { self.transport=transport }
    public func load(_ source:URL) async throws -> Data {
        guard var url=MarkdownRasterPolicy.approved(source) else { throw MarkdownRasterFailure.unsafeURL }
        for _ in 0..<4 {
            try Task.checkCancellation()
            var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:20)
            request.httpShouldHandleCookies=false
            request.setValue("image/png, image/jpeg, image/gif, image/webp",forHTTPHeaderField:"Accept")
            let response=try await transport.send(request)
            try Task.checkCancellation()
            if let observed=response.responseURL { guard observed == url,MarkdownRasterPolicy.approved(observed) != nil else { throw MarkdownRasterFailure.unsafeURL } }
            if [301,302,303,307,308].contains(response.status) {
                guard let location=response.header("Location"),let next=URL(string:location,relativeTo:url)?.absoluteURL,let approved=MarkdownRasterPolicy.approved(next) else { throw MarkdownRasterFailure.unsafeURL }
                url=approved;continue
            }
            guard response.status == 200 else { throw MarkdownRasterFailure.unavailable }
            guard response.data.count <= MarkdownRasterPolicy.maximumBytes else { throw MarkdownRasterFailure.oversized }
            guard let mime=response.header("Content-Type")?.split(separator:";").first?.lowercased(),["image/png","image/jpeg","image/gif","image/webp"].contains(mime) else { throw MarkdownRasterFailure.unsupported }
            return response.data
        }
        throw MarkdownRasterFailure.unsafeURL
    }
}
private final class RasterRedirectDelegate:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge,nil)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
}
/// Dedicated ephemeral streaming session bounds memory before the entire response arrives.
public struct AnonymousRasterTransport:GitHubTransport {
    public init() {}
    public func send(_ request:URLRequest) async throws -> GitHubResponse {
        guard let url=request.url,MarkdownRasterPolicy.approved(url) != nil else { throw MarkdownRasterFailure.unsafeURL }
        let configuration=URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false;configuration.urlCredentialStorage=nil;configuration.urlCache=nil
        configuration.timeoutIntervalForRequest=20;configuration.timeoutIntervalForResource=30
        let session=URLSession(configuration:configuration,delegate:RasterRedirectDelegate(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        // Rebuild rather than inherit caller-supplied credentials or headers.
        var anonymous=URLRequest(url:url);anonymous.httpShouldHandleCookies=false
        anonymous.setValue("image/png, image/jpeg, image/gif, image/webp",forHTTPHeaderField:"Accept")
        let (bytes,response)=try await session.bytes(for:anonymous)
        guard let http=response as? HTTPURLResponse else { throw MarkdownRasterFailure.unavailable }
        guard response.expectedContentLength <= MarkdownRasterPolicy.maximumBytes else { throw MarkdownRasterFailure.oversized }
        let headers=Dictionary(uniqueKeysWithValues:http.allHeaderFields.map { (String(describing:$0.key),String(describing:$0.value)) })
        var data=Data()
        if http.statusCode == 200 {
            for try await byte in bytes {
                guard data.count < MarkdownRasterPolicy.maximumBytes else { throw MarkdownRasterFailure.oversized }
                data.append(byte)
            }
        }
        return .init(status:http.statusCode,headers:headers,data:data,responseURL:http.url)
    }
}
