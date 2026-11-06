import Darwin
import Foundation

public enum MCPChildProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var groups: Set<pid_t> = []

    /// Signals every stdio server process group this process started. Safe to call while quitting.
    public static func terminateAll() {
        let live = lock.withLock { groups }
        guard !live.isEmpty else { return }
        for group in live { kill(-group, SIGTERM) }
        let deadline = Date().addingTimeInterval(0.3)
        var survivors = live.filter(isAlive)
        while !survivors.isEmpty, Date() < deadline {
            usleep(10_000)
            survivors = survivors.filter(isAlive)
        }
        for group in survivors { kill(-group, SIGKILL) }
    }

    static func register(_ group: pid_t) {
        _ = lock.withLock { groups.insert(group) }
    }

    static func unregister(_ group: pid_t) {
        _ = lock.withLock { groups.remove(group) }
    }

    /// A group exists while any member does, including a leader that has not been reaped yet.
    static func isAlive(_ group: pid_t) -> Bool {
        kill(-group, 0) == 0 || errno == EPERM
    }
}

/// A server launched as a child process, speaking newline-delimited JSON-RPC on stdin and stdout.
final class StdioTransport: MCPClientTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: String?
    private let displayName: String
    private let log: MCPLogSink

    /// Guards everything below and wakes threads waiting for the exit or for the pipes to close.
    private let state = NSCondition()
    private var pid: pid_t = 0
    private var stdinFD: Int32 = -1
    private var exitStatus: ProcessExit?
    private var stdoutOpen = false
    private var stderrOpen = false
    private var handshakeDone = false
    private var closeStarted = false
    private var endReported = false
    private var readersShouldStop = false
    private var lastNoiseLine: String?
    private var noiseLines = 0
    private var stderrTail: [String] = []

    private let writeQueue = DispatchQueue(label: "MCPManager.stdio.write")
    private let terminated = TransportOneShot<Void>()

    private static let stderrTailLength = 20
    private static let noiseLinesLogged = 20
    private static let stderrLineLimit = 64 * 1024
    private static let readChunk = 64 * 1024

    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String?,
         displayName: String, log: MCPLogSink) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.displayName = displayName
        self.log = log
        (events, continuation) = AsyncStream.makeStream()
    }

    var info: MCPTransportInfo {
        state.withLock { MCPTransportInfo(processID: pid > 0 ? pid : nil) }
    }

    func start(budget: Duration) async throws {
        let child = try spawn()
        let closedMeanwhile = state.withLock {
            pid = child.pid
            stdinFD = child.stdin
            stdoutOpen = true
            stderrOpen = true
            return closeStarted
        }
        MCPChildProcesses.register(child.pid)
        log.record(.event, "Started \(displayName) (pid \(child.pid))", detail: nil)
        Self.startThread("stdout") { self.readStdout(child.stdout) }
        Self.startThread("stderr") { self.readStderr(child.stderr) }
        Self.startThread("wait") { self.waitForExit(child.pid) }
        if closedMeanwhile {
            Self.startThread("terminate") { self.terminate(group: child.pid) }
            throw MCPClientError.connectionClosed(detail: nil)
        }
    }

    func send(_ message: JSONRPCMessage, onFailure: @escaping @Sendable (MCPClientError) -> Void) {
        var line = message.encoded()
        line.append(0x0A)
        // A server that stops reading fills the pipe and blocks the write, so writes never run on the caller.
        writeQueue.async { [self] in
            let fd = state.withLock { stdinFD }
            guard fd >= 0 else {
                onFailure(.connectionClosed(detail: nil))
                return
            }
            let failure = Self.writeAll(fd, line)
            if failure != 0 { writeFailed(failure) }
        }
    }

    func handshakeCompleted(protocolVersion: String) {
        state.withLock { handshakeDone = true }
    }

    func initializeTimeoutExplanation() -> MCPClientError? {
        state.withLock { lastNoiseLine.map { .invalidServerOutput(line: $0, stage: .initialize) } }
    }

    func close() async {
        beginClose()
        try? await terminated.value()
    }

    func closeInBackground() {
        beginClose()
    }

    // MARK: Launch

    private struct Child {
        var pid: pid_t
        var stdin: Int32
        var stdout: Int32
        var stderr: Int32
    }

    private func spawn() throws -> Child {
        if let workingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MCPClientError.launchFailed(command: executable,
                                                  detail: "The working directory \(workingDirectory) does not exist.")
            }
        }

        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else {
            let code = errno
            for fd in input + output + errors where fd >= 0 { Darwin.close(fd) }
            throw MCPClientError.launchFailed(command: executable, detail: "Could not create pipes: \(String(cString: strerror(code))).")
        }
        // Other code in the app may spawn processes too; none of them should inherit these pipes.
        for fd in input + output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // A server that dies mid-write must give EPIPE, not a SIGPIPE that kills MCP Manager.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        if let workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group lets close() stop helpers the server starts (npx, uvx) along with it.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = Self.cStrings([executable] + arguments)
        let envp = Self.cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        for fd in [input[0], output[1], errors[1]] { Darwin.close(fd) }
        guard status == 0 else {
            for fd in [input[1], output[0], errors[0]] { Darwin.close(fd) }
            throw spawnError(status)
        }
        return Child(pid: child, stdin: input[1], stdout: output[0], stderr: errors[0])
    }

    private func spawnError(_ code: Int32) -> MCPClientError {
        switch code {
        case ENOENT:
            if FileManager.default.fileExists(atPath: executable) {
                return .launchFailed(command: executable,
                                     detail: "The interpreter named on its first line (#!) was not found.")
            }
            return .commandNotFound(command: executable, searchedPath: [])
        case EACCES, EPERM:
            return .commandNotExecutable(path: executable)
        default:
            return .launchFailed(command: executable, detail: String(cString: strerror(code)))
        }
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private static func startThread(_ name: String, _ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = "MCPManager.stdio.\(name)"
        thread.start()
    }

    // MARK: Reading

    private func readStdout(_ fd: Int32) {
        var buffer: [UInt8] = []
        var scanned = 0
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.readChunk)
        defer {
            chunk.deallocate()
            Darwin.close(fd)
            pipeClosed(stdout: true)
        }
        while true {
            let count = readSome(fd, chunk)
            guard count > 0 else { break }
            buffer.append(contentsOf: UnsafeBufferPointer(start: chunk, count: count))
            var lineStart = 0
            while let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                deliverLine(buffer[lineStart ..< newline])
                lineStart = newline + 1
                scanned = lineStart
            }
            if lineStart > 0 { buffer.removeFirst(lineStart) }
            scanned = buffer.count
            if buffer.count > TransportLimits.maxMessageBytes {
                reportEnd(.messageTooLarge(bytes: buffer.count))
                return
            }
        }
        if !buffer.isEmpty { deliverLine(buffer[...]) }
    }

    private func deliverLine(_ bytes: ArraySlice<UInt8>) {
        var line = bytes
        if line.last == 0x0D { line = line.dropLast() }
        guard line.contains(where: { !Self.isWhitespace($0) }) else { return }
        do {
            for message in try JSONRPCMessage.decode(Data(line)) {
                continuation.yield(.message(message))
            }
        } catch {
            noticeNoise(String(decoding: line, as: UTF8.self))
        }
    }

    private func noticeNoise(_ line: String) {
        let redacted = LogFormatting.detail(text: line)
        let count = state.withLock {
            lastNoiseLine = TransportLog.clip(redacted, 1_000)
            noiseLines += 1
            return noiseLines
        }
        if count <= Self.noiseLinesLogged {
            log.record(.warning, "Server wrote non-JSON to stdout", detail: redacted)
        } else if count == Self.noiseLinesLogged + 1 {
            log.record(.warning, "Server keeps writing non-JSON to stdout; further lines are not logged", detail: nil)
        }
    }

    private func readStderr(_ fd: Int32) {
        var pending: [UInt8] = []
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.readChunk)
        defer {
            chunk.deallocate()
            Darwin.close(fd)
            pipeClosed(stdout: false)
        }
        while true {
            let count = readSome(fd, chunk)
            guard count > 0 else { break }
            for byte in UnsafeBufferPointer(start: chunk, count: count) {
                if byte == 0x0A {
                    stderrLine(pending)
                    pending.removeAll(keepingCapacity: true)
                } else if pending.count < Self.stderrLineLimit {
                    pending.append(byte)
                }
            }
        }
        if !pending.isEmpty { stderrLine(pending) }
    }

    private func stderrLine(_ bytes: [UInt8]) {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let redacted = LogFormatting.detail(text: line)
        state.withLock {
            stderrTail.append(redacted)
            if stderrTail.count > Self.stderrTailLength { stderrTail.removeFirst() }
        }
        let summary = TransportLog.clip(redacted)
        log.record(.stderr, summary, detail: summary == redacted ? nil : redacted)
    }

    /// A blocking read that gives up once the server is gone, so a pipe held open by an
    /// orphan in another process group cannot pin the thread forever.
    private func readSome(_ fd: Int32, _ buffer: UnsafeMutablePointer<UInt8>) -> Int {
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready == 0 {
                if state.withLock({ readersShouldStop }) { return 0 }
                continue
            }
            if ready < 0 {
                if errno == EINTR { continue }
                return -1
            }
            let count = Darwin.read(fd, buffer, Self.readChunk)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            return count
        }
    }

    private func pipeClosed(stdout: Bool) {
        state.withLock {
            if stdout { stdoutOpen = false } else { stderrOpen = false }
            state.broadcast()
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    // MARK: Writing

    private static func writeAll(_ fd: Int32, _ data: Data) -> Int32 {
        data.withUnsafeBytes { raw -> Int32 in
            guard var pointer = raw.baseAddress else { return 0 }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return 0
        }
    }

    /// A failed write nearly always means the server died, and its exit explains more than
    /// the broken pipe does, so the pipe is only blamed if no exit follows.
    private func writeFailed(_ code: Int32) {
        guard !state.withLock({ closeStarted }) else { return }
        let detail = code == EPIPE
            ? "The server stopped reading its input."
            : "Could not write to the server: \(String(cString: strerror(code)))."
        log.record(.warning, detail, detail: nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            reportEnd(.connectionClosed(detail: detail))
        }
    }

    // MARK: Exit and shutdown

    private func waitForExit(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let exit = Self.processExit(status)
        state.lock()
        exitStatus = exit
        state.broadcast()
        // The last messages can still be in the pipe; let the readers deliver them first.
        let deadline = Date().addingTimeInterval(0.25)
        while stdoutOpen || stderrOpen, state.wait(until: deadline) {}
        let closing = closeStarted
        let handshake = handshakeDone
        let noise = lastNoiseLine
        let tail = stderrTail
        state.unlock()

        log.record(.event, "Process \(pid) exited with \(exit)", detail: nil)
        guard !closing else { return }
        if !handshake, let noise {
            reportEnd(.invalidServerOutput(line: noise, stage: .initialize))
        } else {
            reportEnd(.processExited(exit, stderrTail: tail, stage: handshake ? .request : .initialize))
        }
    }

    static func processExit(_ status: Int32) -> ProcessExit {
        let signal = status & 0x7F
        return signal == 0 ? ProcessExit(code: (status >> 8) & 0xFF) : ProcessExit(signal: signal)
    }

    private func reportEnd(_ error: MCPClientError) {
        let first = state.withLock {
            defer { endReported = true }
            return !endReported && !closeStarted
        }
        guard first else { return }
        continuation.yield(.ended(error))
        continuation.finish()
    }

    private func beginClose() {
        let pid: pid_t? = state.withLock {
            guard !closeStarted else { return nil }
            closeStarted = true
            return self.pid
        }
        guard let pid else { return }
        continuation.finish()
        guard pid > 0 else {
            terminated.resolve(.success(()))
            return
        }
        // Queued behind any pending write so a message is never cut off mid-line.
        writeQueue.async { [self] in
            let fd: Int32 = state.withLock {
                defer { stdinFD = -1 }
                return stdinFD
            }
            if fd >= 0 { Darwin.close(fd) }
        }
        Self.startThread("terminate") { self.terminate(group: pid) }
    }

    private func terminate(group: pid_t) {
        // Most stdio servers exit on their own once stdin closes.
        state.lock()
        let deadline = Date().addingTimeInterval(1)
        while exitStatus == nil, state.wait(until: deadline) {}
        state.unlock()
        // The group gets signalled even when the leader is gone: launchers like npx leave children behind.
        kill(-group, SIGTERM)
        if !Self.waitForGroupToEmpty(group, seconds: 2) {
            kill(-group, SIGKILL)
            _ = Self.waitForGroupToEmpty(group, seconds: 0.5)
        }
        MCPChildProcesses.unregister(group)
        state.withLock { readersShouldStop = true }
        terminated.resolve(.success(()))
    }

    private static func waitForGroupToEmpty(_ group: pid_t, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while MCPChildProcesses.isAlive(group) {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }
}
