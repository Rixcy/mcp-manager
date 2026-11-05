import Foundation

/// The order global servers are listed in. Neither client keeps one we can
/// rely on (Claude's file is rewritten with sorted keys), so MCP Manager saves
/// its own list of names, newest first.
public enum ServerOrder {
    /// Names in `saved` keep their saved order; any other name is new and goes
    /// on top, in `fallback` order.
    static func arrange(_ names: Set<String>, saved: [String], fallback: [String]) -> [String] {
        let known = saved.filter(names.contains)
        let knownSet = Set(known)
        var fresh = fallback.filter { names.contains($0) && !knownSet.contains($0) }
        var seen = Set(fresh)
        for name in names.sorted(by: Self.byName) where !knownSet.contains(name) && seen.insert(name).inserted {
            fresh.append(name)
        }
        return fresh + known
    }

    /// `names` with `name` dropped onto `target`'s row: before it when dragged
    /// up, after it when dragged down.
    public static func moving(_ name: String, onto target: String, in names: [String]) -> [String] {
        guard name != target, let from = names.firstIndex(of: name), let to = names.firstIndex(of: target) else {
            return names
        }
        var result = names
        result.remove(at: from)
        result.insert(name, at: to)
        return result
    }

    static func byName(_ a: String, _ b: String) -> Bool {
        let order = a.caseInsensitiveCompare(b)
        return order == .orderedSame ? a < b : order == .orderedAscending
    }
}

/// `server-order.json` in MCP Manager's support folder.
struct ServerOrderStore {
    let url: URL

    /// The app's refresh and the user's reorder can write from different threads.
    private static let lock = NSLock()

    private struct File: Codable {
        var global: [String]
    }

    func global() throws -> [String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try read()
    }

    func setGlobal(_ names: [String]) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try write(names)
    }

    func pinGlobal(_ names: [String]) throws {
        try change { saved in
            let known = Set(saved)
            saved = names.filter { !known.contains($0) } + saved
        }
    }

    func removeGlobal(_ name: String) throws {
        try change { $0.removeAll { $0 == name } }
    }

    func renameGlobal(_ oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        try change { saved in saved = saved.map { $0 == oldName ? newName : $0 } }
    }

    /// Writes only when `edit` changed the list.
    private func change(_ edit: (inout [String]) -> Void) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let saved = try read()
        var names = saved
        edit(&names)
        if names != saved { try write(names) }
    }

    private func read() throws -> [String] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw MCPManagerError.io(path: url.path, detail: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(File.self, from: data).global
        } catch {
            throw MCPManagerError.parse(path: url.path, detail: error.localizedDescription)
        }
    }

    private func write(_ names: [String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data: Data
        do {
            data = try encoder.encode(File(global: names))
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
}
