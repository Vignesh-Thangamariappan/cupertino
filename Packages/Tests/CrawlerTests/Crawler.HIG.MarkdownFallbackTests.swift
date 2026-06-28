import CoreProtocols
import CrawlerModels
import Foundation
@testable import HIGSource
import LoggingModels
import SharedConstants
import Testing

@Suite("Crawler.HIG Markdown fallback", .serialized)
struct HIGMarkdownFallbackTests {
    @Test("Markdown responses are saved directly and links are discovered")
    @MainActor
    func markdownResponsesAreSavedDirectly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cupertino-hig-markdown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let crawler = Crawler.HIG(
            outputDirectory: tempDir,
            forceRecrawl: true,
            maxPages: 2,
            fetcherFactory: HIGMarkdownFetcherFactory(),
            logger: Logging.NoopRecording()
        )

        let stats = try await crawler.crawl()

        #expect(stats.totalPages == 2)
        let buttonsURL = tempDir
            .appendingPathComponent("general")
            .appendingPathComponent("buttons.md")
        let markdown = try String(contentsOf: buttonsURL, encoding: .utf8)
        #expect(markdown.contains("# Buttons"))
        #expect(!markdown.contains("<html"))
    }
}

@MainActor
private struct HIGMarkdownFetcherFactory: Crawler.HTTPFetcherFactory {
    func makeFetcher(
        pageLoadTimeout _: Duration,
        javascriptWaitTime _: Duration
    ) -> any Core.Protocols.StringContentFetcher {
        HIGMarkdownFetcher()
    }
}

private struct HIGMarkdownFetcher: Core.Protocols.StringContentFetcher {
    func fetch(url: URL) async throws -> Core.Protocols.FetchResult<String> {
        let markdown: String
        if url.lastPathComponent == "buttons" {
            markdown = """
            ---
            title: "Buttons"
            source: https://developer.apple.com/design/human-interface-guidelines/buttons
            ---

            # Buttons

            Use buttons to initiate actions.
            """
        } else {
            markdown = """
            ---
            title: "Human Interface Guidelines"
            source: https://developer.apple.com/design/human-interface-guidelines
            ---

            # Human Interface Guidelines

            [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)
            """
        }

        return Core.Protocols.FetchResult(
            content: markdown,
            url: url,
            responseHeaders: ["content-type": "text/markdown; charset=utf-8"]
        )
    }
}
