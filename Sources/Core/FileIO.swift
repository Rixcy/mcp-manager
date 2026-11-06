import Foundation

/// Safe read-modify-write for config files other tools rewrite underneath us:
/// backup first, atomic replace, and a retry when the file changed mid-edit.
struct FileIO {
    var backupDir: URL
    var maxBackups = 20
    var maxAttempts = 3
    /// Test seam: runs after the edit is computed and before the change check.
    var beforeReplace: ((URL, Int) -> Void)?

    init(backupDir: URL) {
        self.backupDir = backupDir
    }

    /// Identity of a file version. Size and mtime catch in-place writes; the
    /// inode catches atomic replaces that keep both.
    struct Stamp: Equatable {
        var modified: Date
        var size: UInt64
        var inode: UInt64
        var permissions: Int
    }

    /// Contents, or `nil` when the file does not exist.
    func read(_ url: URL) throws -> Data? {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            return try Data(contentsOf: target)
        } catch {
            throw MCPManagerError.io(path: url.path, detail: error.localizedDescription)
        }
    }

    /// Applies `transform` to the current contents (`nil` when missing) and
    /// replaces the file with the result.
    func modify(_ url: URL, _ transform: (Data?) throws -> Data) throws {
        let target = url.resolvingSymlinksInPath()
        for attempt in 1...maxAttempts {
            let before = try stamp(target)
            let original = try read(target)
            let updated = try transform(original)
            beforeReplace?(target, attempt)
            guard try stamp(target) == before else { continue }
            if let original {
                try backup(original, basename: target.lastPathComponent, permissions: before?.permissions ?? 0o600)
            }
            try atomicWrite(updated, to: target, permissions: before?.permissions ?? 0o600)
            return
        }
        throw MCPManagerError.concurrentModification(path: url.path)
    }

    func stamp(_ url: URL) throws -> Stamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw MCPManagerError.io(path: url.path, detail: String(cString: strerror(errno)))
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Stamp(modified: modified, size: UInt64(info.st_size), inode: UInt64(info.st_ino),
                     permissions: Int(info.st_mode & 0o7777))
    }

    // MARK: Backups

    static func backupTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    static func isBackupName(_ name: String, for basename: String) -> Bool {
        guard name.hasSuffix("-" + basename), name.utf8.count == 20 + basename.utf8.count else { return false }
        return name.prefix(19).range(of: #"^\d{8}-\d{6}-\d{3}$"#, options: .regularExpression) != nil
    }

    func backup(_ data: Data, basename: String, permissions: Int) throws {
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw MCPManagerError.io(path: backupDir.path, detail: error.localizedDescription)
        }
        // Two writes in the same millisecond would collide; nudging the stamp
        // forward keeps names unique and still sorting in write order.
        var date = Date()
        for _ in 0..<1000 {
            let url = backupDir.appendingPathComponent("\(Self.backupTimestamp(date))-\(basename)")
            if try writeNew(data, to: url, permissions: permissions) {
                try prune(basename: basename)
                return
            }
            date.addTimeInterval(0.001)
        }
        throw MCPManagerError.io(path: backupDir.path, detail: "could not pick a unique backup name")
    }

    func prune(basename: String) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []
        let backups = names.filter { Self.isBackupName($0, for: basename) }.sorted(by: >)
        for name in backups.dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: backupDir.appendingPathComponent(name))
        }
    }

    // MARK: Writing

    func atomicWrite(_ data: Data, to target: URL, permissions: Int) throws {
        let dir = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw MCPManagerError.io(path: target.path, detail: error.localizedDescription)
        }
        let temp = dir.appendingPathComponent(".\(target.lastPathComponent).mcp-manager-\(UUID().uuidString).tmp")
        guard try writeNew(data, to: temp, permissions: permissions) else {
            throw MCPManagerError.io(path: target.path, detail: "temporary file already exists")
        }
        guard rename(temp.path, target.path) == 0 else {
            let detail = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            throw MCPManagerError.io(path: target.path, detail: detail)
        }
    }

    /// Creates `url` exclusively with exact permissions from the first byte, so
    /// secrets in the config are never briefly world-readable. Returns `false`
    /// when the file already exists.
    func writeNew(_ data: Data, to url: URL, permissions: Int) throws -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw MCPManagerError.io(path: url.path, detail: String(cString: strerror(errno)))
        }
        defer { close(fd) }
        fchmod(fd, mode_t(permissions))
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        guard ok, fsync(fd) == 0 else {
            let detail = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: url)
            throw MCPManagerError.io(path: url.path, detail: detail)
        }
        return true
    }
}
