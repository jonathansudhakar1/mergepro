import Foundation

public enum RepositoryAssetDownload {
    /// Exclusive writes prevent overwriting a file created by another download.
    public static func save(_ data:Data,name:String,directory:URL) throws -> URL {
        let clean=safeFileName(name)
        guard !clean.isEmpty,directory.isFileURL else { throw RepositoryBrowserFailure.invalidAsset }
        let stem=(clean as NSString).deletingPathExtension,ext=(clean as NSString).pathExtension
        for index in 0..<10000 {
            let candidate=index == 0 ? clean : stem+" (\(index))"+(ext.isEmpty ? "" : "."+ext)
            let url=directory.appendingPathComponent(candidate)
            do { try data.write(to:url,options:[.withoutOverwriting]);return url }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
        }
        throw RepositoryBrowserFailure.invalidAsset
    }
    /// A release can name its asset anything. Keep only the last component, drop separators (/, \, and : which Finder
    /// shows as /) and control or invisible format characters, then strip leading dots so the download can never be a
    /// hidden dotfile such as .zshenv (or `.`/`..`). The caller rejects an empty result. Public so a save panel
    /// can suggest exactly the name a directory download would use.
    public static func safeFileName(_ name:String) -> String {
        let last=(name as NSString).lastPathComponent
        var scalars=String.UnicodeScalarView()
        scalars.append(contentsOf:last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0) })
        var clean=String(scalars).trimmingCharacters(in:.whitespaces)
        while clean.hasPrefix(".") { clean=String(clean.dropFirst()).trimmingCharacters(in:.whitespaces) }
        return clean
    }
    static func download(client:GitHubHTTPClient,repository:String,asset:RepositoryReleaseAsset,token:String) async throws -> Data {
        guard asset.id>0,asset.size>=0,asset.size<=256_000_000 else { throw RepositoryBrowserFailure.assetTooLarge }
        let path=try GitHubRepoReader.repositoryPath(repository)+"/releases/assets/\(asset.id)"
        var destination=client.origin.appendingPathComponent(path)
        var authenticated=true
        for _ in 0..<6 {
            guard destination.scheme == "https",destination.user == nil,destination.password == nil,(destination.port ?? 443)==443 else { throw GitHubFailure.unsafeURL }
            if !authenticated {
                guard let host=destination.host,host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com" else { throw GitHubFailure.unsafeURL }
            }
            var request=URLRequest(url:destination)
            request.setValue("application/octet-stream",forHTTPHeaderField:"Accept")
            request.setValue(GitHubHTTPClient.apiVersion,forHTTPHeaderField:"X-GitHub-Api-Version")
            if authenticated { request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization") }
            let response=try await client.transport.send(request)
            if let actual=response.responseURL,actual != destination { throw GitHubFailure.unsafeURL }
            if authenticated,response.status==401 { throw GitHubFailure.invalidAuthentication }
            if [301,302,303,307,308].contains(response.status) {
                guard let location=response.header("Location"),let next=URL(string:location,relativeTo:destination)?.absoluteURL else { throw GitHubFailure.unsafeURL }
                let nextAuthenticated=client.isSafeAPIURL(next)
                if !authenticated,nextAuthenticated { throw GitHubFailure.unsafeURL }
                authenticated=nextAuthenticated;destination=next;continue
            }
            guard response.status==200,response.data.count<=256_000_000,response.data.count==asset.size else { throw RepositoryBrowserFailure.invalidAsset }
            return response.data
        }
        throw GitHubFailure.unsafeURL
    }
}
