import XCTest
@testable import SearchRanking

final class SearchRankingTests: XCTestCase {

    // MARK: - kindMultiplier

    func testKindMultiplierBoostsProtocol() {
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: "protocol"), 0.5)
    }

    func testKindMultiplierBoostsClass() {
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: "class"), 0.5)
    }

    func testKindMultiplierBoostsStruct() {
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: "struct"), 0.5)
    }

    func testKindMultiplierBoostsFramework() {
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: "framework"), 0.5)
    }

    func testKindMultiplierPenalisesProperty() {
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: "property"), 2.0)
    }

    func testKindMultiplierPenalisesMethod() {
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: "method"), 2.0)
    }

    func testKindMultiplierNeutralForEnum() {
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: "enum"), 1.0)
    }

    func testKindMultiplierNeutralForUnknown() {
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: ""), 1.0)
        XCTAssertEqual(SearchRanking.kindMultiplier(kind: "typealias"), 1.0)
    }

    // MARK: - computeRank

    func testComputeRankNoBoost() {
        XCTAssertEqual(SearchRanking.computeRank(bm25Rank: -10.0, kindMultiplier: 1.0, sourceMultiplier: 1.0, combinedBoost: 1.0), -10.0, accuracy: 1e-9)
    }

    func testComputeRankBoostsWithKindMultiplier() {
        // kindMultiplier 0.5 → rank / 0.5 → more negative → better rank
        let rank = SearchRanking.computeRank(bm25Rank: -10.0, kindMultiplier: 0.5, sourceMultiplier: 1.0, combinedBoost: 1.0)
        XCTAssertEqual(rank, -20.0, accuracy: 1e-9)
        XCTAssertLessThan(rank, -10.0, "Boosted rank must be more negative than input")
    }

    func testComputeRankPenalisesWithKindMultiplier() {
        // kindMultiplier 2.0 → rank / 2.0 → less negative → worse rank
        let rank = SearchRanking.computeRank(bm25Rank: -10.0, kindMultiplier: 2.0, sourceMultiplier: 1.0, combinedBoost: 1.0)
        XCTAssertEqual(rank, -5.0, accuracy: 1e-9)
        XCTAssertGreaterThan(rank, -10.0, "Penalised rank must be less negative than input")
    }

    func testComputeRankCombinesAllMultipliers() {
        // -10 / (0.5 * 0.5 * 0.5) = -10 / 0.125 = -80
        let rank = SearchRanking.computeRank(bm25Rank: -10.0, kindMultiplier: 0.5, sourceMultiplier: 0.5, combinedBoost: 0.5)
        XCTAssertEqual(rank, -80.0, accuracy: 1e-9)
    }

    func testComputeRankPreservesZeroBM25() {
        XCTAssertEqual(SearchRanking.computeRank(bm25Rank: 0.0, kindMultiplier: 0.5, sourceMultiplier: 0.5, combinedBoost: 0.5), 0.0, accuracy: 1e-9)
    }

    // MARK: - combinedBoost

    func testCombinedBoostFrameworkRootOnlyNoTitleMatch() {
        // URI is the exact apple-docs framework root, but title doesn't match query.
        // Only the framework-root 0.01 boost should fire.
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://swiftui/documentation_swiftui",
            query: "swiftui",
            queryWords: ["swiftui"],
            title: "App Entry Point",   // title doesn't contain "swiftui"
            kind: "article",
            framework: "swiftui"
        )
        XCTAssertEqual(boost, 0.01, accuracy: 1e-9, "Framework root (no title match) should return 0.01")
    }

    func testCombinedBoostFrameworkRootWithTitleMatchStacks() {
        // Framework root + exact title match + apple-docs framework authority all stack.
        // Expected: 0.01 * 0.05 * 0.7 (swiftui authority) = 0.00035
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://swiftui/documentation_swiftui",
            query: "swiftui",
            queryWords: ["swiftui"],
            title: "SwiftUI",
            kind: "framework",
            framework: "swiftui"
        )
        XCTAssertEqual(boost, 0.01 * 0.05 * 0.7, accuracy: 1e-9, "Stacked boosts: framework root × heuristic-1 × swiftui authority")
    }

    func testCombinedBoostFrameworkKindExactTitle() {
        // kind == "framework" AND exact title match, non-apple-docs URI.
        // Both the framework-kind boost (0.05) and heuristic-1 exact match (0.05) fire independently.
        // Expected: 0.05 * 0.05 = 0.0025
        let boost = SearchRanking.combinedBoost(
            uri: "some-uri",
            query: "foundation",
            queryWords: ["foundation"],
            title: "Foundation",
            kind: "framework",
            framework: "foundation"
        )
        XCTAssertEqual(boost, 0.05 * 0.05, accuracy: 1e-9, "framework kind + heuristic-1 exact match stack to 0.0025")
    }

    func testCombinedBoostExactTitleMatchWithAppleSuffix() {
        // Title has "| Apple Developer Documentation" suffix stripped before comparison.
        // URI path matches the sub-symbol tiebreak pattern (documentation_swift_result),
        // so: heuristic-1 (0.02) × sub-symbol tiebreak (0.6) × swift authority (0.5) = 0.006
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://swift/documentation_swift_result",
            query: "result",
            queryWords: ["result"],
            title: "Result | Apple Developer Documentation",
            kind: "struct",
            framework: "swift"
        )
        XCTAssertEqual(boost, 0.02 * 0.6 * 0.5, accuracy: 1e-9, "Apple-suffixed canonical page: 0.02 × sub-symbol tiebreak 0.6 × swift authority 0.5")
    }

    func testCombinedBoostExactTitleMatchNoSuffix() {
        // Non-apple-docs URI, title matches query exactly, no suffix.
        // Heuristic-1 plain path: 0.05
        let boost = SearchRanking.combinedBoost(
            uri: "swift-book://types/result",
            query: "result",
            queryWords: ["result"],
            title: "result",
            kind: "struct",
            framework: "swift"
        )
        XCTAssertEqual(boost, 0.05, accuracy: 1e-9, "Non-apple-docs exact title match should return 0.05")
    }

    func testCombinedBoostFirstWordMatch() {
        // Title starts with the query word but isn't an exact match.
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://uikit/documentation_uikit_uiview_frame",
            query: "uiview",
            queryWords: ["uiview"],
            title: "UIView Frame",
            kind: "property",
            framework: "uikit"
        )
        XCTAssertEqual(boost, 0.15, accuracy: 1e-9, "First word exact match should return 0.15")
    }

    func testCombinedBoostAllQueryWordsInTitle() {
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://uikit/some-page",
            query: "view controller",
            queryWords: ["view", "controller"],
            title: "UIViewController Presentation Styles",
            kind: "class",
            framework: "uikit"
        )
        XCTAssertEqual(boost, 0.3, accuracy: 1e-9, "All query words in title should return 0.3")
    }

    func testCombinedBoostAnyQueryWordInTitle() {
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://uikit/some-page",
            query: "animation delegate",
            queryWords: ["animation", "delegate"],
            title: "UIView Animation Proxy",
            kind: "class",
            framework: "uikit"
        )
        XCTAssertEqual(boost, 0.6, accuracy: 1e-9, "Any query word in title should return 0.6")
    }

    func testCombinedBoostNoMatch() {
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://uikit/some-page",
            query: "combine",
            queryWords: ["combine"],
            title: "UIView Frame",
            kind: "property",
            framework: "uikit"
        )
        XCTAssertEqual(boost, 1.0, accuracy: 1e-9, "No match should return neutral 1.0")
    }

    func testCombinedBoostNestedTypePenaltyOnly() {
        // Query has no ".", title has "." — penalty 2.0 applies on top of no-match (1.0).
        // "string" is not in "nsobject.perform", so no title-match boost fires.
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://foundation/some-page",
            query: "string",
            queryWords: ["string"],
            title: "NSObject.perform",
            kind: "method",
            framework: "foundation"
        )
        XCTAssertEqual(boost, 2.0, accuracy: 1e-9, "No-match + nested-type penalty = 2.0")
    }

    func testCombinedBoostNestedTypePenaltyStacksWithAllWordsMatch() {
        // "uiview" IS in "UIView.ContentMode" → all-words match (0.3) × nested penalty (2.0) = 0.6
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://uikit/some-page",
            query: "uiview",
            queryWords: ["uiview"],
            title: "UIView.ContentMode",
            kind: "enum",
            framework: "uikit"
        )
        XCTAssertEqual(boost, 0.3 * 2.0, accuracy: 1e-9, "All-words match × nested-type penalty = 0.6")
    }

    func testCombinedBoostProtocolQueryKeyword() {
        // Title starts with "Protocol" (not the first query word "equatable"),
        // so the first-word branch is skipped and all-words match (0.3) fires.
        // Then protocol keyword boost (×0.4) = 0.12.
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://swift/some-page",
            query: "equatable protocol",
            queryWords: ["equatable", "protocol"],
            title: "Protocol Equatable Requirements",
            kind: "protocol",
            framework: "swift"
        )
        XCTAssertEqual(boost, 0.3 * 0.4, accuracy: 1e-9, "All-words match × protocol keyword boost = 0.12")
    }

    func testCombinedBoostSwiftUISingleWordCoreType() {
        // First word match (0.15) × SwiftUI single-word core type (×0.5) = 0.075
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://swiftui/some-page",
            query: "view",
            queryWords: ["view"],
            title: "View Protocol Explanation",
            kind: "protocol",
            framework: "swiftui"
        )
        XCTAssertEqual(boost, 0.15 * 0.5, accuracy: 1e-9, "First word match × SwiftUI core-type boost = 0.075")
    }

    func testCombinedBoostVerboseTitlePenalty() {
        // No match → 1.0, verbose title (>50 chars) for short query (≤2 words) → ×1.3
        let longTitle = String(repeating: "a", count: 51)
        let boost = SearchRanking.combinedBoost(
            uri: "apple-docs://uikit/some-page",
            query: "uiview",
            queryWords: ["uiview"],
            title: longTitle,
            kind: "class",
            framework: "uikit"
        )
        XCTAssertEqual(boost, 1.3, accuracy: 1e-9, "No-match + verbose title penalty = 1.3")
    }

    // MARK: - sourceMultiplier

    func testSourceMultiplierReleaseNotePenalty() {
        // Release-note URIs always return 2.5 regardless of other inputs
        let multiplier = SearchRanking.sourceMultiplier(
            isReleaseNote: true,
            sourceQuality: 1.0,
            intentScore: 1.0,
            isIntentBoosted: true
        )
        XCTAssertEqual(multiplier, 2.5, accuracy: 1e-9, "Release notes should always return 2.5 penalty")
    }

    func testSourceMultiplierHighQualitySource() {
        // searchQuality = 1.0 → baseMultiplier = 0.5; intentScore = 0 → intentMultiplier = 1.0
        let multiplier = SearchRanking.sourceMultiplier(
            isReleaseNote: false,
            sourceQuality: 1.0,
            intentScore: 0.0,
            isIntentBoosted: false
        )
        XCTAssertEqual(multiplier, 0.5, accuracy: 1e-9, "High-quality source should have 0.5 multiplier (2x boost)")
    }

    func testSourceMultiplierMediumQualitySource() {
        // searchQuality = 0.5 → baseMultiplier = 1.0; intentScore = 0 → intentMultiplier = 1.0
        let multiplier = SearchRanking.sourceMultiplier(
            isReleaseNote: false,
            sourceQuality: 0.5,
            intentScore: 0.0,
            isIntentBoosted: false
        )
        XCTAssertEqual(multiplier, 1.0, accuracy: 1e-9, "Medium-quality source should return neutral 1.0")
    }

    func testSourceMultiplierLowQualitySource() {
        // searchQuality = 0.0 → baseMultiplier = 1.5; intentScore = 0 → intentMultiplier = 1.0
        let multiplier = SearchRanking.sourceMultiplier(
            isReleaseNote: false,
            sourceQuality: 0.0,
            intentScore: 0.0,
            isIntentBoosted: false
        )
        XCTAssertEqual(multiplier, 1.5, accuracy: 1e-9, "Low-quality source should return 1.5 penalty")
    }

    func testSourceMultiplierIntentBoostHalvesMultiplier() {
        // baseMultiplier = 1.0 (quality 0.5), intentMultiplier = 1.0, boosted → ×0.5
        let multiplier = SearchRanking.sourceMultiplier(
            isReleaseNote: false,
            sourceQuality: 0.5,
            intentScore: 0.0,
            isIntentBoosted: true
        )
        XCTAssertEqual(multiplier, 0.5, accuracy: 1e-9, "Intent-boosted source should halve the multiplier")
    }

    func testSourceMultiplierIntentScoreReducesMultiplier() {
        // baseMultiplier = 1.0 (quality 0.5), intentScore = 1.0 → intentMultiplier = 0.6
        let multiplier = SearchRanking.sourceMultiplier(
            isReleaseNote: false,
            sourceQuality: 0.5,
            intentScore: 1.0,
            isIntentBoosted: false
        )
        XCTAssertEqual(multiplier, 0.6, accuracy: 1e-9, "Perfect intent score should reduce multiplier to 0.6")
    }

    func testSourceMultiplierCombinedHighQualityIntentBoosted() {
        // baseMultiplier = 0.5 (quality 1.0), intentScore = 1.0 → intentMultiplier = 0.6, boosted → ×0.5
        let multiplier = SearchRanking.sourceMultiplier(
            isReleaseNote: false,
            sourceQuality: 1.0,
            intentScore: 1.0,
            isIntentBoosted: true
        )
        XCTAssertEqual(multiplier, 0.5 * 0.6 * 0.5, accuracy: 1e-9, "Combined: high-quality × intent score × intent boost")
    }

    // MARK: - frameworkAuthority

    func testFrameworkAuthoritySwiftIsCanonical() {
        XCTAssertEqual(SearchRanking.frameworkAuthority["swift"], 0.5)
    }

    func testFrameworkAuthorityInstallerJsIsNiche() {
        XCTAssertGreaterThan(SearchRanking.frameworkAuthority["installer_js"]!, 1.0)
    }

    func testFrameworkAuthorityUnknownFrameworkDefaultsToNil() {
        XCTAssertNil(SearchRanking.frameworkAuthority["unknownframework"])
    }
}
