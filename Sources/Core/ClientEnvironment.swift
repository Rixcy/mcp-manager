import Darwin
import Foundation

/// The environment a terminal would give the server. GUI apps start with a
/// bare PATH and none of the user's exported keys.
public struct ShellEnvironment: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Read from this login shell.
        case loginShell(String)
        /// The login shell could not be read; the app's own environment plus common tool folders.
        case fallback(reason: String)
    }

    public var variables: [String: String]
    public var source: Source

    public init(variables: [String: String], source: Source) {
        self.variables = variables
        self.source = source
    }

    /// Variables that describe the probe shell itself rather than the user's setup.
    static let droppedNames: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    /// Where version managers and package managers put tools when the login shell can't be read.
    static func fallbackFolders(home: String) -> [String] {
        ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
            + [".local/bin", ".cargo/bin", ".bun/bin", ".volta/bin", ".deno/bin", "bin"].map { "\(home)/\($0)" }
    }

    public static func resolve(shell: String? = nil, timeout: Duration = .seconds(10),
                               base: [String: String] = ProcessInfo.processInfo.environment) async -> ShellEnvironment {
        let shellPath = [shell, base["SHELL"], passwdShell()].compactMap { $0 }.first { !$0.isEmpty } ?? "/bin/zsh"
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ShellProbe.Outcome, Never>) in
            // The probe blocks in poll/waitpid, which must not happen on a cooperative thread.
            let thread = Thread {
                continuation.resume(returning: ShellProbe.run(shell: shellPath, timeout: seconds, environment: base))
            }
            thread.name = "MCP Manager shell environment"
            thread.start()
        }
        let name = (shellPath as NSString).lastPathComponent
        switch outcome {
        case let .variables(variables):
            guard variables["PATH"] != nil else {
                return fallback(base: base, reason: "\(name) printed an environment without PATH")
            }
            return ShellEnvironment(variables: variables, source: .loginShell(shellPath))
        case .missing:
            return fallback(base: base, reason: "\(name) was not found at \(shellPath)")
        case let .spawnFailed(detail):
            return fallback(base: base, reason: "\(name) could not be started: \(detail)")
        case .timedOut:
            return fallback(base: base, reason: "\(name) did not finish within \(formatSeconds(seconds))")
        case .noMarkers:
            return fallback(base: base, reason: "\(name) exited without printing its environment")
        }
    }

    static func fallback(base: [String: String], reason: String) -> ShellEnvironment {
        var variables = base
        let home = base["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        var entries = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for folder in fallbackFolders(home: home) where !entries.contains(folder) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue {
                entries.append(folder)
            }
        }
        variables["PATH"] = entries.joined(separator: ":")
        return ShellEnvironment(variables: variables, source: .fallback(reason: reason))
    }

    private static func passwdShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    /// Parses `env -0` output: NUL-separated `KEY=VALUE`, where values may hold `=` and newlines.
    static func parseNULSeparated(_ data: Data) -> [String: String] {
        var variables: [String: String] = [:]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            let text = String(decoding: record, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            let name = String(text[..<equals])
            if droppedNames.contains(name) { continue }
            variables[name] = String(text[text.index(after: equals)...])
        }
        return variables
    }
}

/// Runs `<shell> -l -i -c` once and reads the environment between two markers.
private enum ShellProbe {
    enum Outcome {
        case variables([String: String])
        case missing
        case spawnFailed(String)
        case timedOut
        case noMarkers
    }

    static func run(shell: String, timeout: Double, environment: [String: String]) -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return .missing }
        let marker = "__MCP_MANAGER_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let command = "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return .spawnFailed(String(cString: strerror(errno))) }
        let readFD = pipeFDs[0], writeFD = pipeFDs[1]
        defer { close(readFD) }

        var pid: pid_t = 0
        let spawnError = spawn(shell: shell, arguments: ["-l", "-i", "-c", command], environment: environment,
                               stdoutFD: writeFD, pid: &pid)
        close(writeFD)
        if spawnError != 0 { return .spawnFailed(String(cString: strerror(spawnError))) }

        let deadline = Date().addingTimeInterval(timeout)
        let markerBytes = Data(marker.utf8)
        var output = Data()
        var payload: Data?
        var timedOut = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while payload == nil {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            var poller = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining * 1000, 1000).rounded(.up)))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let count = read(readFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if count == 0 { break }
            output.append(buffer, count: count)
            payload = between(marker: markerBytes, in: output)
        }

        // The process group holds anything rc files started in the foreground, so killing
        // it ends the probe without leaving stray children holding the pipe.
        if timedOut {
            kill(-pid, SIGKILL)
            reap(pid)
            return .timedOut
        }
        let graceDeadline = min(deadline, Date().addingTimeInterval(1))
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() >= graceDeadline {
                kill(-pid, SIGKILL)
                reap(pid)
                break
            }
            usleep(10_000)
        }
        guard let payload else { return .noMarkers }
        return .variables(ShellEnvironment.parseNULSeparated(payload))
    }

    private static func between(marker: Data, in output: Data) -> Data? {
        guard let start = output.range(of: marker),
              let end = output.range(of: marker, in: start.upperBound..<output.endIndex) else { return nil }
        return output.subdata(in: start.upperBound..<end.lowerBound)
    }

    private static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    /// `Process` cannot put the child in its own process group, which a clean timeout needs.
    private static func spawn(shell: String, arguments: [String], environment: [String: String],
                              stdoutFD: Int32, pid: inout pid_t) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutFD, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv = ([shell] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        return posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
    }
}

public enum VariableExpansion {
    /// Expands `${VAR}` and `${VAR:-default}`. Names with no value and no default are appended to `missing`.
    public static func expand(_ text: String, using variables: [String: String], missing: inout [String]) -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var rest = text[...]
        while let open = rest.range(of: "${") {
            result += rest[..<open.lowerBound]
            // Claude Code matches `\$\{([^}]+)\}`: no closing brace, or nothing inside, stays literal.
            guard let close = rest[open.upperBound...].firstIndex(of: "}"), close > open.upperBound else {
                result += rest[open.lowerBound..<open.upperBound]
                rest = rest[open.upperBound...]
                continue
            }
            let reference = rest[open.upperBound..<close]
            if let separator = reference.range(of: ":-") {
                let name = String(reference[..<separator.lowerBound])
                let value = variables[name] ?? ""
                result += value.isEmpty ? String(reference[separator.upperBound...]) : value
            } else {
                let name = String(reference)
                if let value = variables[name] {
                    result += value
                } else if !missing.contains(name) {
                    missing.append(name)
                }
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    /// Variables the config needs from the environment: `${VAR}` references
    /// without a default, and the bearer token variable.
    public static func requiredNames(in config: MCPServerConfig) -> [String] {
        var names: [String] = []
        for text in expandableTexts(config.transport) {
            _ = expand(text, using: [:], missing: &names)
        }
        if let bearer = config.bearerTokenEnvVar, !bearer.isEmpty, !names.contains(bearer) {
            names.append(bearer)
        }
        return names
    }

    /// Every config string that may hold references, in the order resolution reads them.
    private static func expandableTexts(_ transport: MCPTransport) -> [String] {
        switch transport {
        case let .stdio(command, args, env):
            return [command] + args + env.keys.sorted().map { env[$0]! }
        case let .http(url, headers), let .sse(url, headers):
            return [url] + headers.keys.sorted().map { headers[$0]! }
        }
    }
}

public enum LaunchResolver {
    /// Expands variables and finds the command. Variables come from the shell,
    /// then the config's own env, then `variables`, later ones winning.
    /// Throws `missingVariables`, `commandNotFound`, `commandNotExecutable` or `invalidURL`.
    public static func resolve(_ target: MCPServerTarget, shell: ShellEnvironment, variables: [ClientVariable],
                               homeDirectory: String) throws -> ResolvedLaunch {
        var clientValues: [String: String] = [:]
        for variable in variables where !variable.name.isEmpty {
            clientValues[variable.name] = variable.value
        }
        let lookup = shell.variables.merging(clientValues) { $1 }
        var missing: [String] = []

        switch target.config.transport {
        case let .stdio(command, args, env):
            let expandedCommand = VariableExpansion.expand(command, using: lookup, missing: &missing)
            let expandedArgs = args.map { VariableExpansion.expand($0, using: lookup, missing: &missing) }
            var expandedEnv: [String: String] = [:]
            for key in env.keys.sorted() {
                expandedEnv[key] = VariableExpansion.expand(env[key]!, using: lookup, missing: &missing)
            }
            if !missing.isEmpty { throw MCPClientError.missingVariables(missing) }

            let environment = shell.variables.merging(expandedEnv) { $1 }.merging(clientValues) { $1 }
            let workingDirectory = target.projectPath.flatMap(isDirectory) ?? homeDirectory
            let executable = try locate(expandedCommand, searchPath: environment["PATH"],
                                        workingDirectory: workingDirectory, home: homeDirectory)
            return ResolvedLaunch(target: .stdio(executable: executable, arguments: expandedArgs,
                                                 environment: environment, workingDirectory: workingDirectory),
                                  displayName: commandLine(command, args))

        case let .http(url, headers), let .sse(url, headers):
            let expandedURL = VariableExpansion.expand(url, using: lookup, missing: &missing)
            var expandedHeaders: [String: String] = [:]
            for name in headers.keys.sorted() {
                expandedHeaders[name] = VariableExpansion.expand(headers[name]!, using: lookup, missing: &missing)
            }
            if let bearer = target.config.bearerTokenEnvVar, !bearer.isEmpty,
               !headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
                if let token = lookup[bearer] {
                    expandedHeaders["Authorization"] = "Bearer \(token)"
                } else if !missing.contains(bearer) {
                    missing.append(bearer)
                }
            }
            if !missing.isEmpty { throw MCPClientError.missingVariables(missing) }

            guard let parsed = URL(string: expandedURL), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = parsed.host, !host.isEmpty else {
                throw MCPClientError.invalidURL(url)
            }
            if case .sse = target.config.transport {
                return ResolvedLaunch(target: .sse(url: parsed, headers: expandedHeaders), displayName: url)
            }
            return ResolvedLaunch(target: .streamableHTTP(url: parsed, headers: expandedHeaders), displayName: url)
        }
    }

    /// Absolute path for `command`: itself when it contains a slash, else the first match on `searchPath`.
    public static func findExecutable(_ command: String, searchPath: String?, workingDirectory: String?) -> String? {
        try? locate(command, searchPath: searchPath, workingDirectory: workingDirectory, home: NSHomeDirectory())
    }

    static func locate(_ command: String, searchPath: String?, workingDirectory: String?, home: String) throws -> String {
        if command.contains("/") {
            var path = command
            if path.hasPrefix("~/") { path = home + path.dropFirst() }
            if !path.hasPrefix("/") {
                let base = workingDirectory ?? FileManager.default.currentDirectoryPath
                path = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).path
            }
            path = (path as NSString).standardizingPath
            var info = stat()
            guard stat(path, &info) == 0 else {
                throw MCPClientError.commandNotFound(command: command, searchedPath: [])
            }
            guard info.st_mode & S_IFMT != S_IFDIR, access(path, X_OK) == 0 else {
                throw MCPClientError.commandNotExecutable(path: path)
            }
            return path
        }
        let entries = (searchPath ?? "").split(separator: ":").map(String.init)
        for entry in entries {
            let directory = entry.hasPrefix("/") ? entry : ((workingDirectory ?? "") as NSString).appendingPathComponent(entry)
            let candidate = (directory as NSString).appendingPathComponent(command)
            var info = stat()
            if stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        throw MCPClientError.commandNotFound(command: command, searchedPath: entries)
    }

    private static func isDirectory(_ path: String) -> String? {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue ? path : nil
    }

    private static func commandLine(_ command: String, _ args: [String]) -> String {
        ([command] + args.map { $0.isEmpty || $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 })
            .joined(separator: " ")
    }
}

/// Per-server variables the user adds in MCP Manager, stored 0600.
public struct ClientVariableStore: Sendable {
    public let url: URL

    /// One lock for every store: two instances may point at the same file.
    private static let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func variables(for key: String) throws -> [ClientVariable] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try readAll()[key] ?? []
    }

    public func setVariables(_ variables: [ClientVariable], for key: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var all = try readAll()
        all[key] = variables.isEmpty ? nil : variables
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(all)
        } catch {
            throw MCPManagerError.io(path: url.path, detail: error.localizedDescription)
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw MCPManagerError.io(path: directory.path, detail: error.localizedDescription)
        }
        try FileIO(backupDir: directory).atomicWrite(data, to: url, permissions: 0o600)
    }

    private func readAll() throws -> [String: [ClientVariable]] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            throw MCPManagerError.io(path: url.path, detail: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode([String: [ClientVariable]].self, from: data)
        } catch {
            throw MCPManagerError.parse(path: url.path, detail: "not a JSON object of variable lists")
        }
    }
}
