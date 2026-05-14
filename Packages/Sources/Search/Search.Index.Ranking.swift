import Foundation
import SharedConstants
import SearchModels
import SearchRanking

extension Search.Index {
    // MARK: - Ranking Heuristics (Phase 2 Extraction / Phase 3 Delegation)

    func kindMultiplier(for kind: String) -> Double {
        SearchRanking.kindMultiplier(kind: kind)
    }

    /// Calculate source-based ranking multiplier with intent-aware boosting (Block B)
    func sourceMultiplier(for source: String, uri: String, queryIntent: SearchModule.QueryIntent) -> Double {
        if uri.contains("release-notes") {
            return 2.5
        }

        let searchSource = SearchModule.Source(rawValue: source)
        let isIntentBoosted = searchSource.map { queryIntent.boostedSources.contains($0) } ?? false
        let sourceProps = searchSource.flatMap { SearchModule.SourceRegistry.properties(for: $0.rawValue) }

        let sourceQuality: Double = {
            if let props = sourceProps {
                return props.searchQuality
            }
            // Fallback for unknown sources: approximate quality from static values
            typealias SourcePrefix = Shared.Constants.SourcePrefix
            switch source {
            case SourcePrefix.appleDocs:      return 0.5  // baseline → multiplier 1.0
            case SourcePrefix.appleArchive:   return 0.0  // penalty  → multiplier 1.5
            case SourcePrefix.swiftEvolution: return 0.2  // slight penalty → 1.3
            case SourcePrefix.swiftBook, SourcePrefix.swiftOrg: return 0.6  // slight boost → 0.9
            default: return 0.5
            }
        }()

        let intentScore: Double = sourceProps.map { $0.scoreFor(intent: queryIntent) } ?? 0.0

        return SearchRanking.sourceMultiplier(
            isReleaseNote: false,
            sourceQuality: sourceQuality,
            intentScore: intentScore,
            isIntentBoosted: isIntentBoosted
        )
    }

    func combinedBoost(
        uri: String,
        query: String,
        queryWords: [String],
        title: String,
        kind: String,
        framework: String
    ) -> Double {
        SearchRanking.combinedBoost(
            uri: uri,
            query: query,
            queryWords: queryWords,
            title: title,
            kind: kind,
            framework: framework
        )
    }

    /// Boost results that also match in doc_symbols_fts (Block D/E)
    func boostSymbolMatches(results: [Search.Result], symbolMatchURIs: Set<String>) -> [Search.Result] {
        guard !symbolMatchURIs.isEmpty else { return results }
        return results.map { result in
            if symbolMatchURIs.contains(result.uri) {
                return Search.Result(
                    id: result.id,
                    uri: result.uri,
                    source: result.source,
                    framework: result.framework,
                    title: result.title,
                    summary: result.summary,
                    filePath: result.filePath,
                    wordCount: result.wordCount,
                    rank: result.rank * 3.0,
                    availability: result.availability
                )
            }
            return result
        }
    }

    /// Apply platform version filters (Block E)
    func filterByPlatformAvailability(
        results: [Search.Result],
        minIOS: String?,
        minMacOS: String?,
        minTvOS: String?,
        minWatchOS: String?,
        minVisionOS: String?
    ) -> [Search.Result] {
        var filteredResults = results

        if let minIOS {
            filteredResults = filteredResults.filter { result in
                guard let version = result.minimumiOS else { return false }
                return Self.isVersion(version, lessThanOrEqualTo: minIOS)
            }
        }
        if let minMacOS {
            filteredResults = filteredResults.filter { result in
                guard let version = result.minimumMacOS else { return false }
                return Self.isVersion(version, lessThanOrEqualTo: minMacOS)
            }
        }
        if let minTvOS {
            filteredResults = filteredResults.filter { result in
                guard let version = result.minimumTvOS else { return false }
                return Self.isVersion(version, lessThanOrEqualTo: minTvOS)
            }
        }
        if let minWatchOS {
            filteredResults = filteredResults.filter { result in
                guard let version = result.minimumWatchOS else { return false }
                return Self.isVersion(version, lessThanOrEqualTo: minWatchOS)
            }
        }
        if let minVisionOS {
            filteredResults = filteredResults.filter { result in
                guard let version = result.minimumVisionOS else { return false }
                return Self.isVersion(version, lessThanOrEqualTo: minVisionOS)
            }
        }

        return filteredResults
    }

    /// Force-include canonical framework and type pages (Block F)
    func forceIncludeCanonicalPages(
        results: [Search.Result],
        query: String,
        effectiveSource: String?
    ) async throws -> [Search.Result] {
        var updatedResults = results

        let shouldFetchFrameworkRoot = effectiveSource == nil ||
            effectiveSource == Shared.Constants.SourcePrefix.appleDocs

        guard shouldFetchFrameworkRoot else { return results }

        if let frameworkRoot = try await fetchFrameworkRoot(query: query) {
            updatedResults.removeAll { $0.uri == frameworkRoot.uri }
            updatedResults.insert(frameworkRoot, at: 0)
        }

        let canonicals = try await fetchCanonicalTypePages(query: query)
        if !canonicals.isEmpty {
            let canonicalURIs = Set(canonicals.map(\.uri))
            updatedResults.removeAll { canonicalURIs.contains($0.uri) }
            updatedResults.insert(contentsOf: canonicals, at: 0)
        }

        return updatedResults
    }

    /// Calculate final adjusted rank (Block D)
    static func computeRank(
        bm25Rank: Double,
        kindMultiplier: Double,
        sourceMultiplier: Double,
        combinedBoost: Double
    ) -> Double {
        SearchRanking.computeRank(
            bm25Rank: bm25Rank,
            kindMultiplier: kindMultiplier,
            sourceMultiplier: sourceMultiplier,
            combinedBoost: combinedBoost
        )
    }
}
