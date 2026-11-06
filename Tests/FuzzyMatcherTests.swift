import Foundation

private func refs(_ paths: [String]) -> [ProjectRef] { paths.map(ProjectRef.init(path:)) }

func runFuzzyMatcherTests() {
    test("fuzzy: 'rls' ranks rails above rick-local-scripts") {
        let ranked = FuzzyMatcher.rank(refs(["/p/rick-local-scripts", "/p/rails"]), query: "rls")
        expectEqual(ranked.map(\.name), ["rails", "rick-local-scripts"])
    }

    test("fuzzy: 'reels' matches reels and my-reels-app, exact first, case-insensitive") {
        let ranked = FuzzyMatcher.rank(refs(["/p/my-reels-app", "/p/Reels", "/p/rails"]), query: "reels")
        expectEqual(ranked.map(\.name), ["Reels", "my-reels-app"])
    }

    test("fuzzy: no subsequence means no match") {
        expectEqual(FuzzyMatcher.rank(refs(["/p/rails"]), query: "zz"), [])
        expectEqual(FuzzyMatcher.score(query: "slr", candidate: "rails"), nil)
    }

    test("fuzzy: name matches outrank path-only matches") {
        let ranked = FuzzyMatcher.rank(refs(["/zebra/app", "/p/zebra-ui"]), query: "zeb")
        expectEqual(ranked.map(\.path), ["/p/zebra-ui", "/zebra/app"])
    }

    test("fuzzy: word boundaries and camelCase humps score higher") {
        let camel = try require(FuzzyMatcher.score(query: "mr", candidate: "myReels"), "no camel match")
        let plain = try require(FuzzyMatcher.score(query: "mr", candidate: "mxxrxxx"), "no plain match")
        expectTrue(camel > plain, "camelCase hump not rewarded: \(camel) <= \(plain)")
        let dashed = try require(FuzzyMatcher.score(query: "ra", candidate: "rick-app"), "no dash match")
        let inner = try require(FuzzyMatcher.score(query: "ra", candidate: "rickxapp"), "no inner match")
        expectTrue(dashed > inner, "boundary not rewarded: \(dashed) <= \(inner)")
    }

    test("fuzzy: empty query returns projects unchanged") {
        let projects = refs(["/p/zeta", "/p/alpha"])
        expectEqual(FuzzyMatcher.rank(projects, query: "  "), projects)
    }
}
