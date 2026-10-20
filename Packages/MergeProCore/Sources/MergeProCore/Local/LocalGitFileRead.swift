import Foundation
import Darwin

extension LocalGitService {
    /// Nonblocking open plus descriptor type checks close the file-to-FIFO race. File growth is
    /// bounded while reading, rather than trusting only a size observed before opening.
    public func readRegularFile(_ url: URL, directory: URL, maximumBytes: Int = 8 * 1024 * 1024) throws -> Data {
        try authorize(url, directory: directory)
        let path = try LocalGitPathAccess.canonicalURL(url).path
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalGitMutationError.invalidTarget }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw LocalGitMutationError.unsupportedFileType }
        guard metadata.st_size <= maximumBytes else { throw LocalGitMutationError.oversizedFile }
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= maximumBytes else { throw LocalGitMutationError.oversizedFile }
            data.append(chunk)
        }
        return data
    }
}
