# ADR-CUPERTINO-0002: Refactor Search.IndexBuilder to SourceIndexingStrategy Protocol

**Status**: Proposed — awaiting Viggy's approval  
**Date**: 2026-05-13  
**Author**: Mike (Architect)  
**Refactor Plan**: `docs/plans/2026-05-12-v1-1-package-split.md` §3.6  
**GitHub Issue**: [#314](https://github.com/mihaelamj/cupertino/issues/314) (branching/commit standards)  

---

## Problem Statement

`Search.IndexBuilder.swift` is 1,347 LOC — the worst single file in the Search module and the third-worst in the entire codebase. The `Search.IndexBuilder` actor violates single responsibility by hardcoding **seven different indexing strategies** as private methods alongside orchestration logic, utility helpers, and #284 defense code. This makes it impossible to:

- Add a new source (e.g., WWDC transcripts) without modifying the actor
- Test an individual strategy in isolation without bootstrapping the full actor
- Move the strategies into the planned `SearchStrategies` package (refactor-plan §3.6) without first introducing the abstraction

---

## Current State

`Search.IndexBuilder` is a `public actor` with the following responsibilities inlined:

| Responsibility | Method(s) | LOC |
|---|---|---|
| Orchestration | `buildIndex()` | ~50 |
| Apple Docs (directory) | `indexAppleDocsFromDirectory()` | ~140 |
| Apple Docs (metadata) | `indexAppleDocsFromMetadata()` | ~75 |
| Swift Evolution | `indexEvolutionProposals()`, `indexProposal()` | ~120 |
| Swift.org | `indexSwiftOrgDocs()` | ~130 |
| Apple Archive | `indexArchiveDocs()` | ~95 |
| Human Interface Guidelines | `indexHIGDocs()` | ~80 |
| Sample Code | `indexSampleCodeCatalog()` | ~70 |
| Swift Packages | `indexPackagesCatalog()` | ~40 |
| Shared helpers | `findDocFiles`, `extractTitle`, `extractFramework`, etc. | ~310 |
| #284 defense | `titleLooksLikeHTTPError`, `pageLooksLikeJSFallback` | ~80 |
| Framework synonyms | `registerFrameworkSynonyms()`, `expandFrameworkSynonyms()` | ~45 |

The actor also carries **instance state** for each source's directory URL (`evolutionDirectory`, `swiftOrgDirectory`, `archiveDirectory`, `higDirectory`). When a strategy is absent (nil), `buildIndex()` skips it with an `if` guard. This couples source presence to the init signature rather than to a registry.

**Impact today**: All 19 test files in `SearchTests` that reference `IndexBuilder` depend on internal access (`@testable import Search`). The `indexAppleDocsFromMetadata` and `deduplicateDocFilesByCanonicalURL` functions are marked `internal` specifically to allow test access — a symptom of the missing abstraction layer.

---

## Proposed Solution

Introduce a `SourceIndexingStrategy` protocol. Each of the 7 inlined strategies becomes a concrete `Sendable` struct conforming to this protocol. Shared utility functions are gathered into a `Search.StrategyHelpers` namespace. `IndexBuilder` shrinks to ~250 LOC of orchestration: build a strategy registry, iterate active strategies, call `indexItems` on each, then call `registerFrameworkSynonyms()`.

### Protocol Surface

```swift
// Packages/Sources/Search/Search.SourceIndexingStrategy.swift

extension Search {
    public typealias IndexingProgressCallback = @Sendable (Int, Int) -> Void

    public struct IndexStats: Sendable {
        public let source: String
        public let indexed: Int
        public let skipped: Int

        public init(source: String, indexed: Int, skipped: Int) {
            self.source = source
            self.indexed = indexed
            self.skipped = skipped
        }
    }

    public protocol SourceIndexingStrategy: Sendable {
        /// The source identifier (e.g., "apple-docs", "swift-evolution")
        var source: String { get }

        /// Index all items for this source into the given index.
        func indexItems(
            into index: Search.Index,
            progress: Search.IndexingProgressCallback?
        ) async throws -> Search.IndexStats
    }
}
```

### Concrete Strategy Types

| Strategy type | Source string | Replaces private method(s) |
|---|---|---|
| `AppleDocsStrategy` | `"apple-docs"` | `indexAppleDocsFromDirectory` + `indexAppleDocsFromMetadata` |
| `SwiftEvolutionStrategy` | `"swift-evolution"` | `indexEvolutionProposals` + `indexProposal` |
| `SwiftOrgStrategy` | `"swift-org"` | `indexSwiftOrgDocs` |
| `AppleArchiveStrategy` | `"apple-archive"` | `indexArchiveDocs` |
| `HIGStrategy` | `"hig"` | `indexHIGDocs` |
| `SampleCodeStrategy` | `"sample-code"` | `indexSampleCodeCatalog` |
| `SwiftPackagesStrategy` | `"swift-packages"` | `indexPackagesCatalog` |

Each strategy accepts the directory URL and any other source-specific config through its `init`. Strategies that require a `Search.Index` call (for `getFrameworkAvailability`) receive the index reference at `indexItems(into:)` call time, not at init time — keeping init lightweight and testable without a live database.

### StrategyHelpers Namespace

Shared pure utility methods extracted from the actor into `Search.StrategyHelpers` (a `public enum` acting as namespace):

- `findDocFiles(in:)` → already `static`; moved with no change
- `findMarkdownFiles(in:)` → extracted from private instance method
- `extractFrameworkFromPath(_:relativeTo:)` → extracted
- `canonicalPathComponent(_:)` → extracted
- `extractTitle(from:)` → extracted
- `extractProposalStatus(from:)` → extracted
- `isAcceptedProposal(_:)` → extracted
- `mapSwiftVersionToAvailability(_:)` → extracted
- `extractHIGMetadata(from:)` → extracted
- `extractArchiveMetadata(from:)` → extracted
- `expandFrameworkSynonyms(_:)` → extracted
- `loadStructuredPage(from:)` → extracted
- `canonicalDocumentationURL(for:docsDirectory:)` → extracted (signature gains `docsDirectory` param; was implicitly captured from actor)
- `documentationCrawledAt(for:)` → extracted
- `deduplicateDocFilesByCanonicalURL(_:docsDirectory:)` → extracted (gains `docsDirectory` param)
- `titleLooksLikeHTTPErrorTemplate(_:)` → already `static`; moved with no change
- `pageLooksLikeJavaScriptFallback(_:)` → already `static`; moved with no change
- `is404Page(title:content:)` → already `static`; moved with no change

### Slimmed IndexBuilder

```swift
public actor IndexBuilder {
    private let searchIndex: Search.Index
    private let strategies: [any Search.SourceIndexingStrategy]

    public init(searchIndex: Search.Index, strategies: [any Search.SourceIndexingStrategy]) {
        self.searchIndex = searchIndex
        self.strategies = strategies
    }

    // Convenience factory that mirrors the current 7-directory init signature.
    // Keeps all existing call sites source-compatible.
    public static func makeDefaultStrategies(
        metadata: Shared.Models.CrawlMetadata?,
        docsDirectory: URL,
        evolutionDirectory: URL? = nil,
        swiftOrgDirectory: URL? = nil,
        archiveDirectory: URL? = nil,
        higDirectory: URL? = nil,
        indexSampleCode: Bool = true
    ) -> [any Search.SourceIndexingStrategy] { ... }

    public func buildIndex(
        clearExisting: Bool = true,
        onProgress: Search.IndexingProgressCallback? = nil
    ) async throws {
        if clearExisting { try await searchIndex.clearIndex() }
        for strategy in strategies {
            try await strategy.indexItems(into: searchIndex, progress: onProgress)
        }
        try await registerFrameworkSynonyms()
        let count = try await searchIndex.documentCount()
        logInfo("✅ Search index built: \(count) documents")
    }
}
```

The original `IndexBuilder.init(searchIndex:metadata:docsDirectory:evolutionDirectory:swiftOrgDirectory:archiveDirectory:higDirectory:indexSampleCode:)` is preserved as a `public convenience init` that delegates to `makeDefaultStrategies` — zero source breakage for existing callers.

---

## Alternatives Considered

### A. Leave IndexBuilder as-is, only move the package

Rejected. The plan requires a `SearchStrategies` package. Moving a 1,347-LOC actor whole-cloth into `SearchStrategies` just moves the god object without fixing it; the debt reappears in the new package.

### B. Use async closures instead of a protocol

```swift
typealias IndexingStrategy = @Sendable (Search.Index, ProgressCallback?) async throws -> IndexStats
```

Rejected. Closures are opaque — no `source` identifier, no testability through a concrete type, no `init` for per-source configuration. The protocol is more discoverable and aligns with the existing `SourceIndexer` protocol pattern already in `Search.SourceIndexer.swift`.

### C. Subclass IndexBuilder per source

Rejected. Actors cannot be subclassed in Swift. The strategy pattern is the canonical Swift alternative.

### D. Protocol with associated type or generic IndexBuilder

Rejected. `[any SourceIndexingStrategy]` (existential array) is sufficient here because `indexItems` has no associated type constraints. Introducing generics would make `IndexBuilder` non-ergonomic to construct and test.

---

## Migration Path

Migration is **incremental and source-compatible** across five phases. Each phase is a separate PR off `develop`, verifiable independently.

### Phase A — Write protocol + StrategyHelpers (owned by Mike)

**Scope**: New file `Search.SourceIndexingStrategy.swift` containing the `SourceIndexingStrategy` protocol, `IndexStats`, `IndexingProgressCallback`. New file `Search.StrategyHelpers.swift` with the extracted utility helpers as a `public enum` namespace. **No behavioral change**: existing methods on `IndexBuilder` remain in place. `StrategyHelpers` methods call the same logic; the original private methods are **not yet removed**.

**Files touched**:
- `Packages/Sources/Search/Search.SourceIndexingStrategy.swift` (new)
- `Packages/Sources/Search/Search.StrategyHelpers.swift` (new)

**Acceptance criteria**: `swift build` passes. `swift test` passes with no delta in test counts. `grep -n "func extractTitle\|func findDocFiles\|func titleLooksLikeHTTP" Search.IndexBuilder.swift` still finds all helpers (no premature deletion).

**Risk**: None — additive only.

### Phase B — Implement 4 simpler strategy types (delegate to Jamie)

**Scope**: Implement `AppleArchiveStrategy`, `HIGStrategy`, `SampleCodeStrategy`, `SwiftPackagesStrategy` as concrete structs in `Packages/Sources/Search/Strategies/`. Each calls `Search.StrategyHelpers` for shared utilities. Each returns `Search.IndexStats`.

**Files to create**:
- `Search.Strategies.AppleArchive.swift`
- `Search.Strategies.HIG.swift`
- `Search.Strategies.SampleCode.swift`
- `Search.Strategies.SwiftPackages.swift`

**Files NOT to touch**: `Search.IndexBuilder.swift` (old private methods stay), any test files.

**Patterns to follow**: See Phase A's `StrategyHelpers` and the protocol definition. Implementations must be `Sendable` value types (structs).

**Acceptance criteria**: `swift build` passes. `swift test` unchanged.

**Risk**: Low. These 4 strategies have no shared mutable state and the logic is a direct lift from the corresponding private methods.

**Escalation trigger**: If Jamie finds any strategy requires a reference to `docsDirectory` that isn't passed at init time, stop and raise to Mike.

### Phase C — Implement 3 complex strategy types (delegate to Jamie)

**Scope**: Implement `AppleDocsStrategy`, `SwiftEvolutionStrategy`, `SwiftOrgStrategy`. These are more complex because:
- `AppleDocsStrategy` supports both directory-scan and metadata-driven paths (controlled by a `metadata: CrawlMetadata?` init param).
- `SwiftEvolutionStrategy` has proposal-filtering logic (`isAcceptedProposal`).
- `SwiftOrgStrategy` handles dual JSON/MD file dispatch.

**Files to create**:
- `Search.Strategies.AppleDocs.swift`
- `Search.Strategies.SwiftEvolution.swift`
- `Search.Strategies.SwiftOrg.swift`

**Files NOT to touch**: `Search.IndexBuilder.swift`.

**Escalation trigger**: If `indexAppleDocsFromMetadata` internal access is needed by any strategy (it is currently marked `internal` for test access), escalate to Mike before proceeding.

**Acceptance criteria**: Same as Phase B. Additionally: all `IndexBuilderMalformedURLSkipTests`, `IndexBuilderTitleErrorDefenseTests`, `SwiftOrgIndexTests` still pass.

**Risk**: Medium. The `AppleDocsStrategy` covers the malformed-URL skip logic that has direct test coverage. Any divergence in behavior will surface in the existing test suite.

### Phase D — Wire strategies into IndexBuilder and remove old private methods (owned by Mike)

**Scope**:
1. Add `convenience init` and `makeDefaultStrategies` factory to `IndexBuilder`.
2. Rewrite `buildIndex()` to iterate `strategies`.
3. Delete the 7 private `index*` methods and all helper methods that moved to `StrategyHelpers`.
4. Keep `indexAppleDocsFromMetadata` as a forwarding shim (delegates to `AppleDocsStrategy`) until test references are updated in Phase D.2.
5. Update `IndexBuilderMalformedURLSkipTests` and `IndexBuilderDeduplicationTests` to test the strategy types directly instead of reaching into the actor's internals.

**Files touched**:
- `Search.IndexBuilder.swift` (shrinks from ~1,347 to ~250 LOC)
- `Packages/Tests/SearchTests/IndexBuilderMalformedURLSkipTests.swift`
- `Packages/Tests/SearchTests/IndexBuilderDeduplicationTests.swift`

**Risk**: High. This is the behavioral-change phase. Run the full verification recipe plus a manual reindex against a v1.0.2 bundle. Verify `SELECT COUNT(*) FROM docs_fts GROUP BY source` matches the pre-refactor baseline.

### Phase E — Move to SearchStrategies package (delegate to Jamie)

**Scope**: Per refactor-plan §3.6, move strategy files into `Packages/Sources/SearchStrategies/`. Update `Package.swift` to add `SearchStrategies` target with deps listed in §3.6. Update all import sites.

**Files to move**:
- `Search.SourceIndexingStrategy.swift` → `SearchStrategies/`
- `Search.StrategyHelpers.swift` → `SearchStrategies/`
- `Search.Strategies.*.swift` → `SearchStrategies/`

**Package.swift changes**: Add `SearchStrategies` target and product. Add `import SearchStrategies` to `Search.IndexBuilder.swift`. Update `Indexer` and `Ingest` target deps.

**Risk**: Low (mechanical file move). Standard verification recipe suffices.

---

## Rollback Strategy

Each phase is independently revertable:
- **Phase A**: `git revert` removes the new files. Zero behavioral risk.
- **Phase B/C**: Old `IndexBuilder` private methods are untouched through Phase C; reverting removes the new strategy files with zero behavioral impact.
- **Phase D**: This is the only phase with behavioral risk. If a reindex regression is found, revert the PR and re-open Phase C while diagnosis runs. The `convenience init` shim means all callers continue to compile.
- **Phase E**: Revert the Package.swift change and move files back. Import sweep is mechanical.

---

## Impact Assessment

### Modules affected
- `Search` (primary)
- `Indexer` (imports `Search`; no API change, import paths may gain `SearchStrategies` in Phase E)
- `Ingest` (same as Indexer)
- `CLI` (indirect; no change to `buildIndex()` call signature)

### Impact on Finn and Patch's ongoing work
- **Finn** (Crawler / Availability work): no overlap. This refactor does not touch `Availability`, `Crawler`, or any fetch-side code.
- **Patch** (QA / release): Phase D is the only high-risk PR. Coordinate Phase D timing with Patch's next QA cycle so they can run a full reindex validation before the PR merges.

### Test files affected
- `IndexBuilderMalformedURLSkipTests.swift` — updated in Phase D to test `AppleDocsStrategy` directly
- `IndexBuilderDeduplicationTests.swift` — updated in Phase D to test via `StrategyHelpers`
- All other `SearchTests` test files — no changes expected

---

## Phases Summary

| Phase | Owner | Risk | PR |
|---|---|---|---|
| A: Protocol + StrategyHelpers | Mike | None | 1 |
| B: 4 simpler strategies | Jamie | Low | 1 |
| C: 3 complex strategies | Jamie | Medium | 1 |
| D: Wire + remove old code + update tests | Mike | High | 1 |
| E: Move to SearchStrategies package | Jamie | Low | 1 |

Total: 5 PRs. This task corresponds to refactor-plan §3.6.

---

## Delegation Plan for Jamie

Jamie will own Phases B, C, and E.

### Phase B handoff

- **Task reference**: VIG-276 / refactor-plan §3.6 Phase B
- **Scope**: Implement 4 strategy structs (`AppleArchiveStrategy`, `HIGStrategy`, `SampleCodeStrategy`, `SwiftPackagesStrategy`) conforming to `Search.SourceIndexingStrategy`
- **Files to create**: `Packages/Sources/Search/Strategies/Search.Strategies.AppleArchive.swift`, `.HIG.swift`, `.SampleCode.swift`, `.SwiftPackages.swift`
- **Files NOT to touch**: `Search.IndexBuilder.swift`, any `*Tests.swift` files
- **Patterns to follow**: `Search.StrategyHelpers` (created in Phase A), `Search.SourceIndexingStrategy` protocol
- **Acceptance criteria**: `swift build` + `swift test` pass, no delta in test count
- **Risk areas**: `SampleCodeStrategy` must read from `Sample.Core.Catalog.allEntries` and handle `.missing` source identically to the existing code in `indexSampleCodeCatalog`
- **Escalation trigger**: Any strategy that requires actor-isolated state not available at init

### Phase C handoff

- **Task reference**: VIG-276 / refactor-plan §3.6 Phase C
- **Scope**: Implement 3 strategy structs (`AppleDocsStrategy`, `SwiftEvolutionStrategy`, `SwiftOrgStrategy`)
- **Files to create**: `Packages/Sources/Search/Strategies/Search.Strategies.AppleDocs.swift`, `.SwiftEvolution.swift`, `.SwiftOrg.swift`
- **Files NOT to touch**: `Search.IndexBuilder.swift`
- **Patterns to follow**: Same as Phase B
- **Acceptance criteria**: `swift build` + `swift test` pass. All `IndexBuilderMalformedURLSkipTests`, `IndexBuilderTitleErrorDefenseTests`, and `SwiftOrgIndexTests` pass
- **Risk areas**: `AppleDocsStrategy` must preserve the `indexAppleDocsFromMetadata` logic identically (malformed-URL skip, file-not-found skip). The skip behavior is pinned by `IndexBuilderMalformedURLSkipTests`
- **Escalation trigger**: If `@testable import` in tests reaches a method that has moved into a strategy type and the strategy type is no longer accessible at `internal` visibility

### Phase E handoff

- **Task reference**: VIG-276 / refactor-plan §3.6 Phase E
- **Scope**: Move strategy files to `SearchStrategies` package, update `Package.swift`, sweep imports
- **Files to move**: All `Search.Strategies.*.swift` + `Search.SourceIndexingStrategy.swift` + `Search.StrategyHelpers.swift`
- **Files NOT to touch**: `Search.IndexBuilder.swift` body (only its import line changes)
- **Acceptance criteria**: Standard verification recipe passes
- **Escalation trigger**: Any `Package.swift` dep cycle introduced by the new target

---

## Trade-offs and Risks

| Trade-off | Assessment |
|---|---|
| Protocol existential (`[any SourceIndexingStrategy]`) has slight runtime overhead vs. static dispatch | Acceptable. `indexItems` is I/O-bound; the vtable overhead is unmeasurable against disk and DB latency. |
| `makeDefaultStrategies` factory adds a small API surface | Necessary for source compatibility. Can be `internal` after all callers are migrated (Phase E follow-up). |
| Phase D is the only phase that touches behavior | Mitigated by byte-identical reindex verification and the existing `SearchTests` matrix. |
| `indexAppleDocsFromMetadata` is currently `internal` for test access | Resolved in Phase D by moving the test to target `AppleDocsStrategy` directly. |
| Strategies need `Search.Index` at call time, not init | This is a feature: strategy inits are `Sendable` structs with no actor reference, fully testable in isolation. |

---

## Waiting for Viggy's Approval Before Proceeding

This ADR documents the full architectural plan. No implementation work begins until Viggy explicitly approves. After approval, the subtask sequence is:

1. [DONE] Draft ADR (this document)  
2. [READY] Phase A: Mike writes protocol + StrategyHelpers  
3. [BLOCKED: Phase A] Phase B: Jamie implements 4 simpler strategies  
4. [BLOCKED: Phase B] Phase C: Jamie implements 3 complex strategies  
5. [BLOCKED: Phase C] Phase D: Mike wires registry + removes old code + updates tests  
6. [BLOCKED: Phase D] Phase E: Jamie moves to `SearchStrategies` package  
