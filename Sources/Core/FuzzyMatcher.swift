import Foundation

public enum FuzzyMatcher {
    private static let matchScore = 10
    private static let prefixBonus = 15
    private static let boundaryBonus = 8
    private static let consecutiveBonus = 12
    /// Keeps every path-only match below every name match.
    private static let pathPenalty = 1000

    /// Score for a query against a candidate; `nil` means no match. Higher is better.
    public static func score(query: String, candidate: String) -> Int? {
        let q = Array(query.filter { !$0.isWhitespace }.lowercased())
        let original = Array(candidate)
        let c = Array(candidate.lowercased())
        guard !q.isEmpty else { return 0 }
        // Lowercasing can change the character count (e.g. "İ"); fall back to no case bonus info then.
        let caseInfo = original.count == c.count ? original : c
        guard q.count <= c.count else { return nil }

        let bonus = c.indices.map { j -> Int in
            var value = matchScore
            if j == 0 {
                value += prefixBonus + boundaryBonus
            } else if "-_/ .".contains(caseInfo[j - 1]) || (caseInfo[j - 1].isLowercase && caseInfo[j].isUppercase) {
                value += boundaryBonus
            }
            return value
        }

        // best[j]: best score with the current query character matched at candidate index j.
        var best = [Int?](repeating: nil, count: c.count)
        for j in c.indices where c[j] == q[0] { best[j] = bonus[j] }
        for i in 1..<q.count {
            var next = [Int?](repeating: nil, count: c.count)
            var runningMax: Int?
            for j in c.indices {
                if j >= 2, let prev = best[j - 2] { runningMax = max(runningMax ?? prev, prev) }
                guard c[j] == q[i], j >= 1 else { continue }
                var candidates: [Int] = []
                if let adjacent = best[j - 1] { candidates.append(adjacent + consecutiveBonus) }
                if let earlier = runningMax { candidates.append(earlier) }
                if let top = candidates.max() { next[j] = top + bonus[j] }
            }
            best = next
        }
        guard let top = best.compactMap({ $0 }).max() else { return nil }
        return top - (c.count - q.count)
    }

    /// Projects matching `query`, best first. An empty query returns all projects unchanged.
    public static func rank(_ projects: [ProjectRef], query: String) -> [ProjectRef] {
        guard query.contains(where: { !$0.isWhitespace }) else { return projects }
        let scored: [(ProjectRef, Int)] = projects.compactMap { project in
            if let s = score(query: query, candidate: project.name) { return (project, s) }
            if let s = score(query: query, candidate: project.path) { return (project, s - pathPenalty) }
            return nil
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.name.count != b.0.name.count { return a.0.name.count < b.0.name.count }
            return a.0.path < b.0.path
        }.map(\.0)
    }
}
