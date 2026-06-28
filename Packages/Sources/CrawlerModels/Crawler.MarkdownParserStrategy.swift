import Foundation
import SharedConstants

// MARK: - Crawler.MarkdownParserStrategy

/// Pure Markdown→structured-page transformer used when a crawler
/// transport returns rendered Markdown directly (for example, Sosumi).
///
/// The Crawler producer holds this seam instead of importing
/// `CoreJSONParser`. Composition roots wrap
/// `Core.JSONParser.MarkdownToStructuredPage.convert(_:url:)`.
public extension Crawler {
    protocol MarkdownParserStrategy: Sendable {
        /// Convert rendered documentation Markdown to a structured page.
        /// Returns nil when the Markdown lacks enough documentation
        /// shape to become a page.
        func toStructuredPage(
            markdown: String,
            url: URL,
            depth: Int?
        ) -> Shared.Models.StructuredDocumentationPage?
    }
}
