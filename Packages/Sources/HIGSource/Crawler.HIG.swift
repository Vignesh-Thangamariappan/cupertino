import CoreProtocols
import CrawlerModels
import Foundation
import LoggingModels
import SearchModels
import SharedConstants

// MARK: - HIG Crawler

/// Crawls Apple's Human Interface Guidelines
/// The HIG website is a JavaScript SPA by default, so the production
/// composition root wires a rendered-content fetcher. WebKit is the
/// default transport; Sosumi can be selected by the CLI for Markdown.
extension Crawler {
    @MainActor
    // #673 Phase D iter-5: 395-line class — page discovery + HTML parsing
    // + markdown conversion + file saving in one self-contained crawler;
    // splits would scatter the WebView lifetime + per-page state.
    // swiftlint:disable:next type_body_length
    public final class HIG {
        private enum RenderedContentFormat {
            case html
            case markdown
        }

        private let outputDirectory: URL
        private let forceRecrawl: Bool
        private let maxPages: Int
        /// GoF Strategy seam for log emission (1994 p. 315). Threaded
        /// in from the CLI composition root.
        private let logger: any LoggingModels.Logging.Recording
        /// Strategy seam (#903): the CLI composition root constructs a
        /// rendered-content fetcher factory and passes it here.
        /// The Crawler producer is foundation-only and never links WebKit.
        private let fetcherFactory: any Crawler.HTTPFetcherFactory

        private var fetcher: (any Core.Protocols.StringContentFetcher)?

        public init(
            outputDirectory: URL,
            forceRecrawl: Bool = false,
            maxPages: Int = 500,
            fetcherFactory: any Crawler.HTTPFetcherFactory,
            logger: any LoggingModels.Logging.Recording
        ) {
            self.outputDirectory = outputDirectory
            self.forceRecrawl = forceRecrawl
            self.maxPages = maxPages
            self.fetcherFactory = fetcherFactory
            self.logger = logger
        }

        // MARK: - Public API

        /// Crawl Human Interface Guidelines. Pass an
        /// `any Crawler.HIGProgressObserving` to receive per-page
        /// progress updates; `nil` opts out.
        public func crawl(
            progress: (any Crawler.HIGProgressObserving)? = nil
        ) async throws -> Crawler.HIGStatistics {
            var stats = Crawler.HIGStatistics(startTime: Date())

            logInfo("Starting Human Interface Guidelines crawler")
            logInfo("   Output: \(outputDirectory.path)")
            logInfo("   Max pages: \(maxPages)")

            // Create output directory
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            // Initialize content fetcher via the injected factory (#903).
            // HIG needs the longer javascript-wait because the HIG SPA
            // settles in stages.
            fetcher = fetcherFactory.makeFetcher(
                pageLoadTimeout: Shared.Constants.Timeout.pageLoad,
                javascriptWaitTime: Shared.Constants.Timeout.higJavascriptWait
            )

            // Start from HIG root
            let rootURL = try URL(knownGood: Shared.Constants.BaseURL.appleHIG)

            // Discover all HIG pages
            logInfo("Discovering HIG pages...")
            let pages = try await discoverPages(from: rootURL, stats: &stats)
            logInfo("Found \(pages.count) pages to crawl")

            // Crawl each page
            for (index, page) in pages.prefix(maxPages).enumerated() {
                do {
                    try await crawlPage(page, stats: &stats)

                    // Crawler.HIGProgress callback
                    if let observer = progress {
                        let progressValue = Crawler.HIGProgress(
                            currentPage: index + 1,
                            totalPages: min(pages.count, maxPages),
                            currentItem: page.title,
                            stats: stats
                        )
                        observer.observe(progress: progressValue)
                    }

                    // Rate limiting
                    try await Task.sleep(for: Shared.Constants.Delay.archivePage)

                    // Recycle the fetcher every N pages to free memory
                    if (index + 1) % Shared.Constants.Interval.webViewRecycleEvery == 0 {
                        fetcher?.recycle()
                        logInfo("♻️ Recycled fetcher at page \(index + 1)")
                    }
                } catch {
                    stats.errors += 1
                    logError("Failed to crawl page \(page.title): \(error)")

                    // Recycle on error to recover from potential WebView issues
                    fetcher?.recycle()
                }
            }

            // Cleanup
            fetcher = nil

            stats.endTime = Date()

            logInfo("\nCrawl completed!")
            logStatistics(stats)

            return stats
        }

        // MARK: - Private Methods

        private func discoverPages(
            from rootURL: URL,
            stats: inout Crawler.HIGStatistics
        ) async throws -> [Page] {
            var pages: [Page] = []
            var visited: Set<String> = []
            var queue: [URL] = [rootURL]

            // BFS to discover HIG pages
            while !queue.isEmpty, pages.count < maxPages {
                let url = queue.removeFirst()
                let urlString = url.absoluteString

                guard !visited.contains(urlString) else { continue }
                visited.insert(urlString)

                // Only process HIG URLs
                guard urlString.contains("/design/human-interface-guidelines") else { continue }

                // Load page and extract links
                logInfo("Loading: \(url.lastPathComponent.isEmpty ? "root" : url.lastPathComponent)")
                let fetchedPage: Core.Protocols.FetchResult<String>
                do {
                    fetchedPage = try await loadPage(url: url)
                } catch {
                    logError("Failed to load \(url): \(error)")
                    continue
                }
                let content = fetchedPage.content
                let pageURL = fetchedPage.url

                // Extract title from page
                let title = extractTitle(from: content) ?? pageURL.lastPathComponent

                // Determine category from URL path
                let category = extractCategory(from: pageURL)

                // #1078: derive platforms from the URL slug, not from
                // HTML substring matching. Pre-fix `extractPlatforms`
                // lowercased the entire HTML and looked for the
                // tokens "ios"/"macos"/"watchos"/"visionos"/"tvos" —
                // every HIG page's nav/footer mentions ALL of them,
                // so every page reported all 5 platforms regardless
                // of topic. Post-fix: rule-table lookup against the
                // URL slug (single source of truth shared with the
                // indexer strategy + SQL pass via HIGPlatformRules).
                let platforms = Self.inferPlatforms(forURL: pageURL)

                let page = Page(
                    url: pageURL,
                    title: title,
                    category: category,
                    platforms: platforms
                )
                pages.append(page)

                // Extract links to other HIG pages
                let links = extractHIGLinks(from: content, baseURL: pageURL)
                for link in links where !visited.contains(link.absoluteString) {
                    queue.append(link)
                }
            }

            return pages
        }

        private func loadPage(url: URL) async throws -> Core.Protocols.FetchResult<String> {
            guard let fetcher else {
                throw Error.webViewNotInitialized
            }

            return try await fetcher.fetch(url: url)
        }

        private func crawlPage(_ page: Page, stats: inout Crawler.HIGStatistics) async throws {
            // #1076: derive filename from the URL's last path
            // component (Apple's canonical HIG slug), NOT from the
            // HTML <title>. Pre-fix the crawler used
            // `sanitizeFilename(page.title)`; when Apple's site
            // returned two HTML variants for the same URL with
            // different `<title>` shapes (one with the `" | Apple
            // Developer Documentation"` suffix stripped, one with a
            // dehyphenated `"|AppleDeveloperDocumentation"` suffix
            // the strip didn't catch), the same page got saved as two
            // files (`buttons.md` + `buttons-appledeveloperdocumentation.md`)
            // and reached search.db as two rows. Apple's URL slug is
            // the authoritative topic name (it IS the canonical
            // identifier Apple themselves use in URLs + redirects);
            // taking it directly eliminates the title-roundtrip + the
            // dedup problem in one move.
            let filename = Self.canonicalFilename(for: page.url) + ".md"
            let categoryDir = outputDirectory.appendingPathComponent(page.category.rawValue)

            do {
                try FileManager.default.createDirectory(at: categoryDir, withIntermediateDirectories: true)
            } catch {
                logError("Failed to create directory \(categoryDir.path): \(error)")
                throw error
            }

            let outputPath = categoryDir.appendingPathComponent(filename)

            // Check if already crawled
            let isNew = !FileManager.default.fileExists(atPath: outputPath.path)
            if !isNew, !forceRecrawl {
                stats.skippedPages += 1
                logInfo("⏭️ Skipped (exists): \(filename)")
                return
            }

            // Load page content
            logInfo("📥 Loading: \(page.title)")
            let fetchedPage = try await loadPage(url: page.url)

            // Convert to markdown
            let markdown: String
            switch Self.contentFormat(from: fetchedPage) {
            case .html:
                markdown = convertToMarkdown(fetchedPage.content, page: page)
            case .markdown:
                markdown = fetchedPage.content
            }

            // Save
            do {
                try markdown.write(to: outputPath, atomically: true, encoding: .utf8)
                logInfo("💾 Saved: \(outputPath.path)")
            } catch {
                logError("Failed to save \(outputPath.path): \(error)")
                throw error
            }

            if isNew {
                stats.newPages += 1
            } else {
                stats.updatedPages += 1
            }

            stats.totalPages += 1
        }

        private func extractTitle(from html: String) -> String? {
            if let title = Self.frontmatterValue("title", from: html) {
                return title
            }

            for line in html.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Try to extract from <title> tag
            let titlePattern = #"<title[^>]*>([^<]+)</title>"#
            guard let regex = try? NSRegularExpression(pattern: titlePattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else {
                return nil
            }

            var title = String(html[range])
            // Clean up title
            title = title.replacingOccurrences(of: " - Human Interface Guidelines", with: "")
            title = title.replacingOccurrences(of: " | Apple Developer Documentation", with: "")
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private nonisolated static func contentFormat(from result: Core.Protocols.FetchResult<String>) -> RenderedContentFormat {
            if let headers = result.responseHeaders {
                for (key, value) in headers where key.lowercased() == "content-type" {
                    let lowercased = value.lowercased()
                    if lowercased.contains("text/markdown")
                        || lowercased.contains("application/markdown")
                        || lowercased.contains("text/x-markdown") {
                        return .markdown
                    }
                }
            }

            let prefix = result.content.prefix(4096).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasPrefix("---\n"),
               prefix.contains("\nsource:"),
               prefix.contains("developer.apple.com") {
                return .markdown
            }

            return .html
        }

        private nonisolated static func frontmatterValue(_ key: String, from markdown: String) -> String? {
            guard markdown.hasPrefix("---\n") else { return nil }
            let parts = markdown.dropFirst(4).split(separator: "---", maxSplits: 1)
            guard let yaml = parts.first else { return nil }

            for line in yaml.split(separator: "\n") {
                let keyValue = line.split(separator: ":", maxSplits: 1)
                guard keyValue.count == 2,
                      keyValue[0].trimmingCharacters(in: .whitespaces) == key
                else { continue }
                return unquoteYAMLValue(String(keyValue[1]).trimmingCharacters(in: .whitespacesAndNewlines))
            }

            return nil
        }

        private nonisolated static func unquoteYAMLValue(_ value: String) -> String {
            if value.count >= 2,
               value.first == "\"",
               value.last == "\"" {
                return String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
            return value
        }

        private func extractCategory(from url: URL) -> Category {
            let path = url.path.lowercased()

            if path.contains("/foundations") {
                return .foundations
            } else if path.contains("/patterns") {
                return .patterns
            } else if path.contains("/components") {
                return .components
            } else if path.contains("/technologies") {
                return .technologies
            } else if path.contains("/inputs") {
                return .inputs
            } else {
                return .general
            }
        }

        /// #1078: derive applicable platforms from the URL slug via
        /// `HIGPlatformRules`. Returns `[.iOS, .macOS, .tvOS,
        /// .watchOS, .visionOS]` for cross-platform topics, the
        /// rule's `keep` set for platform-specific topics. The empty
        /// case is not reachable (the rules table's fallthrough is
        /// "all 5 platforms"), so the legacy `.all` sentinel is no
        /// longer emitted from this path; the enum case stays for
        /// backward-compat in case any caller still constructs it.
        nonisolated static func inferPlatforms(forURL url: URL) -> [Platform] {
            let keep = HIGPlatformRules.applicablePlatforms(for: url.absoluteString)
            // Preserve a stable display order (iOS, macOS, watchOS,
            // visionOS, tvOS) — matches the order the HIG markdown
            // body line used pre-fix.
            var result: [Platform] = []
            if keep.contains("ios") { result.append(.iOS) }
            if keep.contains("macos") { result.append(.macOS) }
            if keep.contains("watchos") { result.append(.watchOS) }
            if keep.contains("visionos") { result.append(.visionOS) }
            if keep.contains("tvos") { result.append(.tvOS) }
            return result
        }

        private func extractHIGLinks(from content: String, baseURL: URL) -> [URL] {
            var links: [URL] = []

            // Extract href values
            let hrefPattern = #"href=[\"']([^\"']*human-interface-guidelines[^\"']*)[\"']"#
            if let regex = try? NSRegularExpression(pattern: hrefPattern, options: .caseInsensitive) {
                let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))

                for match in matches {
                    guard let range = Range(match.range(at: 1), in: content) else { continue }
                    let href = String(content[range])
                    appendHIGLink(href, baseURL: baseURL, to: &links)
                }
            }

            let markdownPattern = #"(?<!!)\[[^\]]+\]\(([^)\s]*human-interface-guidelines[^)\s]*)(?:\s+"[^"]*")?\)"#
            if let regex = try? NSRegularExpression(pattern: markdownPattern, options: .caseInsensitive) {
                let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))

                for match in matches where match.numberOfRanges >= 2 {
                    guard let range = Range(match.range(at: 1), in: content) else { continue }
                    let href = String(content[range])
                    appendHIGLink(href, baseURL: baseURL, to: &links)
                }
            }

            return Array(Set(links))
        }

        private func appendHIGLink(_ href: String, baseURL: URL, to links: inout [URL]) {
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  url.host == "developer.apple.com",
                  url.path.contains("/design/human-interface-guidelines")
            else {
                return
            }

            // Remove fragment
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.fragment = nil
            if let cleanURL = components?.url {
                links.append(cleanURL)
            }
        }

        private func convertToMarkdown(_ html: String, page: Page) -> String {
            var lines: [String] = []

            // YAML front matter
            lines.append("---")
            lines.append("title: \"\(escapeYAML(page.title))\"")
            lines.append("category: \"\(page.category.rawValue)\"")
            lines.append("platforms: [\(page.platforms.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))]")
            lines.append("url: \"\(page.url.absoluteString)\"")
            lines.append("source: hig")
            lines.append("---")
            lines.append("")

            // Title
            lines.append("# \(page.title)")
            lines.append("")

            // Category badge
            lines.append("> **Category:** \(page.category.displayName)")
            lines.append("> **Platforms:** \(page.platforms.map(\.displayName).joined(separator: ", "))")
            lines.append("")

            // Convert HTML content to markdown
            let content = extractMainContent(from: html)
            let markdownContent = htmlToMarkdown(content)
            lines.append(markdownContent)

            return lines.joined(separator: "\n")
        }

        private func extractMainContent(from html: String) -> String {
            // Try to extract main content area
            let patterns = [
                #"<main[^>]*>([\s\S]*?)</main>"#,
                #"<article[^>]*>([\s\S]*?)</article>"#,
                #"<div[^>]*class=[\"'][^\"']*content[^\"']*[\"'][^>]*>([\s\S]*?)</div>"#,
            ]

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let range = Range(match.range(at: 1), in: html)
                else {
                    continue
                }
                return String(html[range])
            }

            return html
        }

        /// HTML-to-Markdown conversion: many sequential regex replacements.
        /// Splitting would obscure the linear transformation pipeline; kept
        /// as a single function. Body sits at 77 lines (default threshold 50).
        // swiftlint:disable:next function_body_length
        private func htmlToMarkdown(_ html: String) -> String {
            var result = html

            // Remove script and style tags
            result = result.replacingOccurrences(
                of: #"<script[^>]*>[\s\S]*?</script>"#,
                with: "",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"<style[^>]*>[\s\S]*?</style>"#,
                with: "",
                options: .regularExpression
            )

            // Headers
            for level in 1...6 {
                let hashes = String(repeating: "#", count: level)
                result = result.replacingOccurrences(
                    of: #"<h\#(level)[^>]*>(.*?)</h\#(level)>"#,
                    with: "\(hashes) $1\n",
                    options: .regularExpression
                )
            }

            // Paragraphs
            result = result.replacingOccurrences(
                of: #"<p[^>]*>(.*?)</p>"#,
                with: "$1\n\n",
                options: .regularExpression
            )

            // Bold and italic
            result = result.replacingOccurrences(
                of: #"<strong[^>]*>(.*?)</strong>"#,
                with: "**$1**",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"<b[^>]*>(.*?)</b>"#,
                with: "**$1**",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"<em[^>]*>(.*?)</em>"#,
                with: "*$1*",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"<i[^>]*>(.*?)</i>"#,
                with: "*$1*",
                options: .regularExpression
            )

            // Code
            result = result.replacingOccurrences(
                of: #"<code[^>]*>(.*?)</code>"#,
                with: "`$1`",
                options: .regularExpression
            )

            // Links
            result = result.replacingOccurrences(
                of: #"<a[^>]*href=[\"']([^\"']*)[\"'][^>]*>(.*?)</a>"#,
                with: "[$2]($1)",
                options: .regularExpression
            )

            // Lists
            result = result.replacingOccurrences(
                of: #"<li[^>]*>(.*?)</li>"#,
                with: "- $1\n",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"</?[ou]l[^>]*>"#,
                with: "\n",
                options: .regularExpression
            )

            // Remove remaining HTML tags
            result = result.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: .regularExpression
            )

            // Decode HTML entities
            result = decodeHTMLEntities(result)

            // Clean up whitespace
            result = result.replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)

            return result
        }

        private func decodeHTMLEntities(_ text: String) -> String {
            var result = text
            let entities: [(String, String)] = [
                ("&amp;", "&"),
                ("&lt;", "<"),
                ("&gt;", ">"),
                ("&quot;", "\""),
                ("&apos;", "'"),
                ("&#39;", "'"),
                ("&nbsp;", " "),
                ("&mdash;", "—"),
                ("&ndash;", "–"),
                ("&hellip;", "..."),
            ]

            for (entity, replacement) in entities {
                result = result.replacingOccurrences(of: entity, with: replacement)
            }

            return result
        }

        private func escapeYAML(_ text: String) -> String {
            text.replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
        }

        private func sanitizeFilename(_ name: String) -> String {
            let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
            return name.components(separatedBy: invalidChars).joined(separator: "-")
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }

        /// #1076: derive the canonical .md filename from Apple's HIG
        /// URL last path component. Apple's URL slug is the
        /// authoritative topic identifier — e.g. the HIG buttons page
        /// at `developer.apple.com/design/human-interface-guidelines/buttons`
        /// canonicalizes to `buttons`. Strips any trailing slash and a
        /// trailing `.html` extension (defensive — Apple's HIG URLs
        /// don't carry them today). Internal + `nonisolated` so the
        /// focused regression suite can import and exercise this
        /// pure-function helper without entering @MainActor (the
        /// enclosing `Crawler.HIG` is @MainActor because it owns a
        /// WebKit fetcher; the URL canonicalizer carries no actor
        /// state).
        nonisolated static func canonicalFilename(for url: URL) -> String {
            var slug = url.lastPathComponent
            if slug.hasSuffix(".html") {
                slug = String(slug.dropLast(".html".count))
            }
            return slug.lowercased()
        }

        // MARK: - Logging

        private func logInfo(_ message: String) {
            let memoryMB = fetcher?.getMemoryUsageMB() ?? 0
            let memoryMsg = "\(String(format: "%.1f", memoryMB))MB | \(message)"
            logger.info(memoryMsg, category: .hig)
        }

        private func logError(_ message: String) {
            logger.error("Error: \(message)", category: .hig)
        }

        private func logStatistics(_ stats: Crawler.HIGStatistics) {
            let messages = [
                "Crawler.HIGStatistics:",
                "   Total pages: \(stats.totalPages)",
                "   New: \(stats.newPages)",
                "   Updated: \(stats.updatedPages)",
                "   Skipped: \(stats.skippedPages)",
                "   Errors: \(stats.errors)",
                stats.duration.map { "   Duration: \(Int($0))s" } ?? "",
                "",
                "Output: \(outputDirectory.path)",
            ]

            for message in messages where !message.isEmpty {
                logger.info(message, category: .hig)
            }
        }
    }
}

// MARK: - Models

extension Crawler.HIG {
    /// Represents an HIG page to crawl
    public struct Page: Sendable {
        public let url: URL
        public let title: String
        public let category: Category
        public let platforms: [Platform]

        public init(url: URL, title: String, category: Category, platforms: [Platform]) {
            self.url = url
            self.title = title
            self.category = category
            self.platforms = platforms
        }
    }

    /// HIG content categories
    public enum Category: String, Sendable, CaseIterable {
        case foundations
        case patterns
        case components
        case technologies
        case inputs
        case general

        public var displayName: String {
            switch self {
            case .foundations: return "Foundations"
            case .patterns: return "Patterns"
            case .components: return "Components"
            case .technologies: return "Technologies"
            case .inputs: return "Inputs"
            case .general: return "General"
            }
        }
    }

    /// HIG platforms
    public enum Platform: String, Sendable, CaseIterable {
        case iOS
        case macOS
        case watchOS
        case visionOS
        case tvOS
        case all

        public var displayName: String {
            switch self {
            case .iOS: return "iOS"
            case .macOS: return "macOS"
            case .watchOS: return "watchOS"
            case .visionOS: return "visionOS"
            case .tvOS: return "tvOS"
            case .all: return "All Platforms"
            }
        }
    }
}

// `Crawler.HIGStatistics` + `Crawler.HIGProgress` +
// `Crawler.HIGProgressObserving` moved to the foundation-only
// `CrawlerModels` seam target so any Observer conformer can implement
// without `import Crawler`.

// MARK: - Errors

extension Crawler.HIG {
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case invalidResponse(URL)
        case webViewNotInitialized

        public var errorDescription: String? {
            switch self {
            case .invalidResponse(let url):
                return "Invalid response from \(url)"
            case .webViewNotInitialized:
                return "WebView not initialized"
            }
        }
    }
}
