import Foundation
import SharedConstants

/// Constants and heuristics used for search result ranking.
public enum SearchRanking {
    /// Apple-docs framework authority used as a HEURISTIC 1 tiebreak (#256).
    ///
    /// Only consulted when an apple-docs row already hit the exact-title boost
    /// in HEURISTIC 1 — i.e. multiple frameworks have a top-level page whose
    /// title equals the query (e.g. `Result` on Swift, Vision, Installer JS).
    /// At that point BM25F has nothing useful to say about which framework is
    /// canonical for the bare type name. The map nudges the canonical pick.
    ///
    /// Values are multipliers on `boost` (lower = stronger boost; FTS5 ranks
    /// are negative so smaller multipliers push higher). Frameworks not in
    /// the map default to 1.0 (no nudge).
    ///
    /// Kept narrow on purpose: only frameworks with an actual canonical-page
    /// conflict whose resolution is uncontroversial. Adding a framework here
    /// is an authority claim — be conservative.
    public static let frameworkAuthority: [String: Double] = [
        "swift": 0.5, // language types (Result, Task, String, ...)
        "swiftui": 0.7, // primary UI framework
        "foundation": 0.7, // primary system framework
        "installer_js": 1.4, // niche packaging-script API
        "webkitjs": 1.4, // legacy WebKit JS bindings
        "javascriptcore": 1.2, // JS bridge
        "devicemanagement": 1.2, // MDM payload schemas
    ]

    // MARK: - Pure Ranking Functions (Phase 3)

    /// Kind-based ranking multiplier. Values < 1.0 boost; values > 1.0 penalise.
    public static func kindMultiplier(kind: String) -> Double {
        switch kind {
        case "protocol", "class", "struct", "framework":
            return 0.5
        case "property", "method":
            return 2.0
        default:
            return 1.0
        }
    }

    /// Final adjusted BM25 rank.
    ///
    /// BM25 scores are negative; more-negative = better rank.
    /// Dividing by multipliers < 1 makes the result more negative (boost);
    /// dividing by multipliers > 1 makes it less negative (penalty).
    public static func computeRank(
        bm25Rank: Double,
        kindMultiplier: Double,
        sourceMultiplier: Double,
        combinedBoost: Double
    ) -> Double {
        bm25Rank / (kindMultiplier * sourceMultiplier * combinedBoost)
    }

    /// Intelligent title/query matching heuristic multiplier.
    ///
    /// Returns a boost value where values < 1.0 improve rank (BM25 is negative).
    public static func combinedBoost(
        uri: String,
        query: String,
        queryWords: [String],
        title: String,
        kind: String,
        framework: String
    ) -> Double {
        let titleLower = title.lowercased()
        let titleWords = titleLower.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var boost = 1.0
        let queryLowerJoined = queryWords.joined(separator: " ")
        let uriLower = uri.lowercased()

        let isFrameworkRoot: Bool = {
            if uriLower.hasPrefix("apple-docs://") {
                let parts = uriLower
                    .replacingOccurrences(of: "apple-docs://", with: "")
                    .components(separatedBy: "/")
                if parts.count == 2, parts[1] == "documentation_\(parts[0])" {
                    return parts[0] == queryLowerJoined
                }
            }
            return false
        }()

        let titleWithoutSuffix = titleLower
            .replacingOccurrences(of: " | apple developer documentation", with: "")
            .trimmingCharacters(in: .whitespaces)

        if isFrameworkRoot {
            boost *= 0.01
        } else if kind == "framework", titleWithoutSuffix == queryLowerJoined {
            boost *= 0.05
        }

        if queryWords.count <= 3, titleWithoutSuffix == queryLowerJoined {
            if titleLower != titleWithoutSuffix {
                boost *= 0.02
            } else {
                boost *= 0.05
            }

            if uriLower.hasPrefix("apple-docs://") {
                let pathPart = uriLower.replacingOccurrences(of: "apple-docs://", with: "")
                let parts = pathPart.components(separatedBy: "/")
                if parts.count == 2 {
                    let docPrefix = "documentation_\(parts[0])_"
                    let queryAsIdent = queryLowerJoined.replacingOccurrences(of: " ", with: "")
                    if parts[1].hasPrefix(docPrefix),
                       String(parts[1].dropFirst(docPrefix.count)) == queryAsIdent {
                        boost *= 0.6
                    }
                }
                boost *= frameworkAuthority[framework.lowercased()] ?? 1.0
            }
        } else if !titleWords.isEmpty, !queryWords.isEmpty, titleWords[0] == queryWords[0] {
            boost *= 0.15
        } else if queryWords.allSatisfy({ titleLower.contains($0) }) {
            boost *= 0.3
        } else if queryWords.contains(where: { titleLower.contains($0) }) {
            boost *= 0.6
        }

        let queryLower = query.lowercased()
        if !queryLower.contains("."), titleLower.contains(".") {
            boost *= 2.0
        }

        let queryText = query.lowercased()
        if queryText.contains("protocol"), kind == "protocol" {
            boost *= 0.4
        } else if queryText.contains("class"), kind == "class" {
            boost *= 0.4
        } else if queryText.contains("struct"), kind == "struct" {
            boost *= 0.4
        }

        if queryWords.count == 1, framework == "swiftui" {
            switch kind {
            case "protocol", "class", "struct":
                boost *= 0.5
            default:
                break
            }
        }

        if queryWords.count <= 2, title.count > 50 {
            boost *= 1.3
        }

        return boost
    }

    /// Core source quality × intent multiplier.
    ///
    /// - Parameters:
    ///   - isReleaseNote: true when the URI contains "release-notes"
    ///   - sourceQuality: `SourceProperties.searchQuality` for the source (0.0–1.0)
    ///   - intentScore: `SourceProperties.scoreFor(intent:)` result (0.0–1.0)
    ///   - isIntentBoosted: true when the source is in `QueryIntent.boostedSources`
    public static func sourceMultiplier(
        isReleaseNote: Bool,
        sourceQuality: Double,
        intentScore: Double,
        isIntentBoosted: Bool
    ) -> Double {
        if isReleaseNote { return 2.5 }
        // searchQuality 1.0 → baseMultiplier 0.5 (2x boost)
        // searchQuality 0.5 → baseMultiplier 1.0 (neutral)
        // searchQuality 0.0 → baseMultiplier 1.5 (penalty)
        let baseMultiplier = 1.5 - sourceQuality
        // intentScore 1.0 → intentMultiplier 0.6 (boost), 0.0 → 1.0 (no boost)
        let intentMultiplier = 1.0 - (intentScore * 0.4)
        var result = baseMultiplier * intentMultiplier
        if isIntentBoosted {
            result *= 0.5
        }
        return result
    }
}
