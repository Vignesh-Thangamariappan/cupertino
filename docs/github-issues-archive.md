# GitHub issue archive (recovered)

Cupertino's issue tracker lived on GitHub (mihaelamj/cupertino) until the
account became inaccessible in mid-2026. This document preserves everything
that could be recovered afterwards. Sources: the Wayback Machine (issue-list
snapshots of 2025-11-28 and 2026-02-10, plus two fully archived issue pages)
and the daily repo digests in mihaela-analytics, which tracked issue activity
from March through June 2026. Roughly 101 issues were open at the end; most
were owner-side planning tickets. Numbers below are the original GitHub
numbers and do not correspond to issues in this repository's tracker.

## Community contributions (fully reconstructed from digests)

### Issues
- #883: first external bug report, `brew upgrade cupertino && cupertino setup`
  hit a `--force` flag error; spawned owner follow-ups #885 and #886.
- #1126 (markusfassbender-lb, 2026-05-28): README update for the VS Code MCP
  config; GitHub Copilot deprecated `.vscode/mcp.json`. Open at the end.
- #1274 (mesqueeb, 2026-06-09): automate periodic bundle refresh via a
  scheduled workflow. Owner replied 2026-06-10 committing to create an epic;
  the epic was never created. Open at the end.
- #1317 (eurobob, 2026-06-28): RFC, Linux support for `cupertino serve`
  (serve-only, on swift-corelibs-foundation). Unanswered at the end. The
  recorded owner stance suggestion: accept serve-only Linux, ask for
  SwiftMCPServer fixes first, prefer package-local SQLite systemLibrary
  targets, request leaf-first PRs, add minimal Linux CI.

### Pull requests
- #1122 (er1c-cartman): feat(fetch), expose crawler request delay.
- #1123 (er1c-cartman): docs, roadmap maintenance protocol (+105).
- #1124 (er1c-cartman): docs, README framing for CLI and MCP users (#748).
- #1125 (er1c-cartman): feat, accept md output format alias (#747).
- #1127 (markusfassbender-lb): docs fix for #1126 (+2/-2).
- #1233 (lvupupui, 2026-06-02): fix(cli), intercept `--force` with a helpful
  migration hint (12 add / 1 del). Review decision CHANGES_REQUESTED
  2026-06-04: confirmed approach = Option 1 from #885, two nits (real
  placeholder help string; restore `mutating` on `run()`), retarget base
  main -> develop. Awaiting contributor at the end.
- #1275 (SSDWGG, 2026-06-13): docs, recommend Homebrew install first.
  MERGED 2026-06-14.
- #1294 (KartavyaDikshit, 2026-06-21): "Fix for issue #13", flagged as
  drive-by (targeted protected main, tripped the external-pr-to-main guard).
  CLOSED unmerged the same day.

### Discussions
- #1276 (davidbjames): Apple Beta documentation; the follow-up regression
  report drove the v1.4.1 setup DB-integrity gate (released 2026-06-24).
- #132 (zzmasoud): Kilo Code / VS Code search failure, answered.
- #105 (bikrrr): docs "(not found)" after install, answered.
- #182 (frankschlegel): show-and-tell, third-party package docs support.
- #24: fetching stuck at 50 percent, answered.

## Owner planning issues, exact titles recovered via Wayback

Open set of 2025-11-28: #5 add --request-delay to FetchCommand, #6 fetch
authenticate broken (browser never opens), #7 cupertino-mcp binary for
non-Apple OS, #8 vector/semantic search with sqlite-vec, #9 search
highlighting, #10 fuzzy search, #11 filter by source_type, #12 search
ranking, #13 resource templates for all types, #14 streaming for large docs,
#15 caching layer, #16 --verbose flag, #17 progress bars, #18 output colors,
#19 config file (.cupertinorc), #20 E2E MCP tests, #21 search benchmarks,
#22 memory profiling, #23 CLI search command.

Open set of 2026-02-10: #78 framework statistics command, #80 submit to MCP
registries, #89 Swift Forums in search index, #101 proper concurrency in
ArchiveGuideCatalog tests, #103 index Kernel Programming Guide and IOKit from
Apple Archive, #104 track documents without availability data, #107 fetch
--type package-docs ignores selected-packages.json, #109 search-all and
search-hig CLI parity, #110 swift.org indexing skips 8 pages (missing url
key), #113 dedupe results and resolve doc:// links, #116 external library
docs (SQLite, Redis), #121 formatter improvements, #122 index package
READMEs/source/examples for FTS, #125 Claude Desktop review improvements
(v0.8.0), #138 publish to official MCP registry, #139 upgrade MCP protocol to
2025-11-25, #154 TUI help screen, #155 TUI progress indicators, #156 TUI
event-loop refactor, #157 TUI package details view, #158 TUI confirmation
dialogs, #159 missing DeviceCheck framework, #160 crawler seeding from
technologies.json, #161 (adamhill) fetch package-docs and archive fails,
#166 (tijs) Cupertino as skill?

Fully archived issue pages (bodies recoverable from the Wayback Machine):
#52 add --remote flag to save command for streaming from GitHub;
#72 add documentation updates tracking tool.

## Owner planning clusters (digest-reconstructed, titles as recorded)

- Corpus integrity (May): #283 URL case-canonicalization (~122k duplicate
  rows), #284 crawler persists HTTP error pages, #285 dash/underscore URI
  duplicates.
- DI and refactor arc: #381 DI epic, #400/#403/#408 package standalone
  tickets, #425/#430/#431 crawler extraction, #432 SPA no-content gate,
  #286 search-URL normalisation, #536 producer-standalone design doc,
  #409 AST signal cleanup, #410 search.db split.
- May bug burst: #548 kill Logging.Unified.shared singleton epic, #587
  CLI/MCP read-URL asymmetry, #588 import-diligence audit, #593-#598
  (including the CRITICAL --base-dir data-loss bug), #607 rawMarkdown null
  regression, #610 search-ranking bug, #618 serve hangs on stdin EOF,
  #620 error-message ambiguity, #517 MCP silent degradation, #429 corpus
  reconciliation tests, #449 DocC catalog audit.
- v1.2.x epic: #673 (parent), #665, #668, #675, #682, #686 CI flaky-network,
  #742/#754 AST extractor robustness, #744 label hygiene, #747 md alias,
  #748 dual-consumer README, #759 search_generics where-clauses, #761
  external-PR-to-main guard, #763 coverage for #759, #859 v1.2.0 planning.
- Eval harness and search strategies: #892 xcodebuild external sources,
  #899 epic with #944/#946/#947 phases and #968-#971 per-source strategy
  extraction, #935, #957 packages.db canonical community packages.
- Per-source DB split: #1036 epic, #1039/#1040/#1041, #1048-#1075
  SourceProvider enrichment seam, #1073/#1184 HIG audit-recorder flake,
  #1132 SynonymsPass attaches 0 synonyms, #1133 community-health profile,
  #1146 save --resume skips unchanged docs, #1154/#1155 AST search flags,
  #1167 adopt shared swift-mcp-core, #1168 serve reads legacy search.db,
  #1175 Homebrew-first docs, #1178 desktop E2E round-trip.
- Package extraction: #1259 workspace Package.resolved, #1261
  CupertinoDataEngine embedded reader, #1262 desktop backend surface.
- June search quality: #1200-#1212 planning burst, epics #1222/#1223/#1228/
  #1242, #1251 SE-proposal lookup, #1252 broad-query perf, #1253 relevance
  score near-constant, #1254 stale pre-#1036 DBs, #1258 package-local API
  context, #1270 pre-UI readiness gate, #1283 MCP tool honesty, #1288
  hierarchy salvage, #1310-#1312 unified list tooling, #1316 undocumented
  Apple API ingest, #1309 PR fix(serve) --no-reap exemption.
- #1314: automated issue-body staleness tracker (bot).

## Provenance

Compiled 2026-07-03. Digest source: mihaela-analytics sources/github daily
and community files. Wayback snapshots: web.archive.org captures of
github.com/mihaelamj/cupertino/issues (20251128162512, 20260210155045) and
issues/52 (20251214231625), issues/72 (20260105031052).
