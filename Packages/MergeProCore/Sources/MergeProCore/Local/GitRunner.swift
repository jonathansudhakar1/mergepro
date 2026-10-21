import Foundation
import Darwin

public struct GitResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.exitCode = exitCode; self.standardOutput = standardOutput; self.standardError = standardError
    }
}
public protocol GitRunner: Sendable {
    func run(arguments: [String], directory: URL) async throws -> GitResult
    func run(arguments: [String], directory: URL, standardInput: Data) async throws -> GitResult
}
public extension GitRunner {
    func run(arguments: [String], directory: URL, standardInput: Data) async throws -> GitResult {
        throw GitRunnerError.unsupportedInput
    }
    /// Pure reads (status, diff, ls-files, rev-parse, listings, config lookups) of a possibly untrusted repository.
    /// Mutations keep using `run` so the user's hooks, signing and other configuration still apply to them.
    func runReadOnly(arguments: [String], directory: URL) async throws -> GitResult {
        try await run(arguments: GitReadOnlyOptions.global + arguments, directory: directory)
    }
}
/// Global options (they precede the subcommand) that stop repository configuration from running programs during
/// reads: core.fsmonitor names a command run on every index refresh, and log.showSignature makes `stash list` run
/// gpg.program. Optional index refreshes are skipped, so reads never take locks or write. Diffs still pass
/// --no-ext-diff and --no-textconv themselves.
public enum GitReadOnlyOptions {
    public static let global = ["-c", "core.fsmonitor=false", "-c", "log.showSignature=false", "--no-optional-locks"]
}
public enum GitOutputStream: String, Equatable, Sendable { case standardOutput, standardError }
public enum GitRunnerError: Error, Equatable, Sendable, LocalizedError {
    case executableUnavailable(path: String)
    case unsupportedInput
    case inputLimitExceeded(limit: Int)
    case invalidArgument
    case launchFailed(message: String)
    case outputLimitExceeded(stream: GitOutputStream, limit: Int)
    public var errorDescription: String? {
        switch self {
        case .executableUnavailable(let path): "Git executable is unavailable at \(path). Choose an installed Git executable or open the repository in Terminal."
        case .unsupportedInput: "This Git runner cannot accept input. Open the repository in Terminal."
        case .inputLimitExceeded(let limit): "Git input exceeded the \(limit)-byte limit."
        case .invalidArgument: "Git arguments must not contain NUL bytes."
        case .launchFailed(let message): "Git could not start: \(message). Open the repository in Terminal if sandbox access prevents execution."
        case .outputLimitExceeded(let stream, let limit): "Git \(stream.rawValue) exceeded the \(limit)-byte limit. Narrow the operation or open the repository in Terminal."
        }
    }
}

/// Invokes the configured executable directly. Environment overrides are merged into the inherited environment
/// minus its GIT_* variables; hooks, credential helpers, configuration and signing settings are never disabled.
public final class ProcessGitRunner: GitRunner, Sendable {
    private let executableURL: URL
    private let environment: [String: String]
    private let maximumOutputBytes: Int
    static let gate = GitDirectoryGate()
    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"), environment: [String: String]? = nil, maximumOutputBytes: Int = 8 * 1024 * 1024) {
        self.executableURL = executableURL
        self.environment = Self.childEnvironment(inherited: ProcessInfo.processInfo.environment, overrides: environment ?? [:])
        self.maximumOutputBytes = max(1, maximumOutputBytes)
    }
    /// Inherited GIT_* variables (GIT_DIR, GIT_CONFIG_PARAMETERS, GIT_EXTERNAL_DIFF, GIT_SSH_COMMAND, ...) could
    /// redirect a command to another repository or run programs; only explicitly supplied overrides may set them.
    static func childEnvironment(inherited: [String: String], overrides: [String: String]) -> [String: String] {
        inherited.filter { !$0.key.hasPrefix("GIT_") }.merging(overrides) { _, supplied in supplied }
    }
    public func run(arguments: [String], directory: URL) async throws -> GitResult {
        try await runOwned(arguments: arguments, directory: directory, standardInput: nil)
    }
    public func run(arguments: [String], directory: URL, standardInput: Data) async throws -> GitResult {
        guard standardInput.count <= maximumOutputBytes else { throw GitRunnerError.inputLimitExceeded(limit: maximumOutputBytes) }
        return try await runOwned(arguments: arguments, directory: directory, standardInput: standardInput)
    }
    private func runOwned(arguments: [String], directory: URL, standardInput: Data?) async throws -> GitResult {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitRunnerError.executableUnavailable(path: executableURL.path)
        }
        guard !arguments.contains(where: { $0.contains("\0") }) else { throw GitRunnerError.invalidArgument }
        let key = Self.gateKey(directory)
        let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await Self.gate.acquire(key: key, token: token)
        } onCancel: { Task { await Self.gate.cancel(key: key, token: token) } }
        do {
            try Task.checkCancellation()
            let result = try await execute(arguments: arguments, directory: directory, standardInput: standardInput)
            await Self.gate.release(key: key, token: token)
            return result
        } catch {
            await Self.gate.release(key: key, token: token)
            throw error
        }
    }
    /// Commands in one folder run one at a time, whatever path names it.
    static func gateKey(_ directory: URL) -> String { directory.standardizedFileURL.resolvingSymlinksInPath().path }
    private func execute(arguments: [String], directory: URL, standardInput: Data?) async throws -> GitResult {
        let owner = GitOwnedProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do { continuation.resume(returning: try owner.execute(executable: executableURL, arguments: arguments, directory: directory, environment: environment, input: standardInput, limit: maximumOutputBytes)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { owner.cancel() }
    }
}

actor GitDirectoryGate {
    private struct Waiter { let token: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var owners: [String: UUID] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var waiterObservers: [(key: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    func acquire(key: String, token: UUID) async throws {
        try Task.checkCancellation()
        if owners[key] == nil { owners[key] = token; return }
        try await withCheckedThrowingContinuation {
            waiters[key, default: []].append(.init(token: token, continuation: $0))
            waitersChanged(key)
        }
    }
    /// Commands queued behind the one running in `key`'s folder.
    func waiterCount(key: String) -> Int { waiters[key]?.count ?? 0 }
    /// Returns once at least `count` commands queue in `key`'s folder, so a test knows a command reached the gate.
    func untilWaiting(key: String, count: Int = 1) async {
        guard waiterCount(key: key) < count else { return }
        await withCheckedContinuation { waiterObservers.append((key, count, $0)) }
    }
    private func waitersChanged(_ key: String) {
        guard !waiterObservers.isEmpty else { return }
        let current = waiterCount(key: key)
        let ready = waiterObservers.filter { $0.key == key && current >= $0.count }
        waiterObservers.removeAll { $0.key == key && current >= $0.count }
        for observer in ready { observer.continuation.resume() }
    }
    func cancel(key: String, token: UUID) {
        if let index = waiters[key]?.firstIndex(where: { $0.token == token }), let waiter = waiters[key]?.remove(at: index) {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
    func release(key: String, token: UUID) {
        guard owners[key] == token else { return }
        if !(waiters[key] ?? []).isEmpty, let next = waiters[key]?.removeFirst() {
            owners[key] = next.token; next.continuation.resume()
        } else { owners.removeValue(forKey: key); waiters.removeValue(forKey: key) }
    }
}

/// A lock protects launch/cancellation only; buffers are confined to one worker. Nonblocking pipe
/// reads avoid deadlock on full stderr or descendants that retain pipe handles after Git exits.
private final class GitOwnedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; stopLocked(); lock.unlock() }
    private func stopLocked() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
            lock.lock(); defer { lock.unlock() }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
    func execute(executable: URL, arguments: [String], directory: URL, environment: [String: String], input: Data?, limit: Int) throws -> GitResult {
        let output = Pipe(), errors = Pipe(), inputPipe = input.map { _ in Pipe() }
        defer { try? inputPipe?.fileHandleForReading.close(); try? inputPipe?.fileHandleForWriting.close() }
        defer { try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = environment; process.standardOutput = output; process.standardError = errors
        // No inherited stdin: noninteractive commands cannot wait forever for input from the app.
        process.standardInput = inputPipe ?? FileHandle.nullDevice as Any
        // Signalled the moment Git exits. `isRunning`/`waitUntilExit()` only notice exit on a ~50 ms polling loop,
        // which added that much idle time to almost every command.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { lock.unlock(); throw GitRunnerError.launchFailed(message: error.localizedDescription) }
        lock.unlock()
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        try? inputPipe?.fileHandleForReading.close()
        let inputDescriptor = inputPipe?.fileHandleForWriting.fileDescriptor
        if let inputDescriptor {
            _ = fcntl(inputDescriptor, F_SETFL, fcntl(inputDescriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(inputDescriptor, F_SETNOSIGPIPE, 1)
        }
        var inputOffset = 0
        var inputClosed = input == nil
        let descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }
        var buffers = [Data(), Data()]
        var open = [true, true]
        var limitError: GitRunnerError?
        var bytes = [UInt8](repeating: 0, count: 16_384)
        repeat {
            if let input, let inputDescriptor, !inputClosed {
                if inputOffset < input.count {
                    let written = input.withUnsafeBytes { buffer in
                        Darwin.write(inputDescriptor, buffer.baseAddress!.advanced(by: inputOffset), min(16_384, input.count - inputOffset))
                    }
                    if written > 0 { inputOffset += written }
                    else if written < 0 && errno != EAGAIN && errno != EINTR { inputClosed = true; try? inputPipe?.fileHandleForWriting.close() }
                }
                if inputOffset == input.count { inputClosed = true; try? inputPipe?.fileHandleForWriting.close() }
            }
            for index in descriptors.indices where open[index] {
                while true {
                    let count = Darwin.read(descriptors[index], &bytes, bytes.count)
                    if count == 0 { open[index] = false; break }
                    if count < 0 { break }
                    if buffers[index].count + count > limit {
                        if limitError == nil {
                            limitError = .outputLimitExceeded(stream: index == 0 ? .standardOutput : .standardError, limit: limit)
                            lock.lock(); stopLocked(); lock.unlock()
                        }
                        break
                    }
                    buffers[index].append(contentsOf: bytes.prefix(count))
                }
            }
            // Both pipes at end of file: nothing more to read, so wait for the exit itself.
            if !open.contains(true) && inputClosed { exited.wait(); break }
            // Exited while a descendant may still hold a pipe open: stop reading rather than wait for its EOF.
            if exited.wait(timeout: .now()) == .success { break }
            var polls = descriptors.indices.filter { open[$0] }.map { pollfd(fd: descriptors[$0], events: Int16(POLLIN), revents: 0) }
            if let inputDescriptor, !inputClosed { polls.append(pollfd(fd: inputDescriptor, events: Int16(POLLOUT), revents: 0)) }
            _ = Darwin.poll(&polls, nfds_t(polls.count), 20)
        } while true
        // Drain bytes already in the pipes after termination without waiting for descendant EOF.
        if limitError == nil {
            for index in descriptors.indices where open[index] {
                while true {
                    let count = Darwin.read(descriptors[index], &bytes, bytes.count)
                    if count <= 0 { break }
                    guard buffers[index].count + count <= limit else {
                        limitError = .outputLimitExceeded(stream: index == 0 ? .standardOutput : .standardError, limit: limit); break
                    }
                    buffers[index].append(contentsOf: bytes.prefix(count))
                }
            }
        }
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if let limitError { throw limitError }
        return .init(exitCode: process.terminationStatus, standardOutput: buffers[0], standardError: buffers[1])
    }
}
