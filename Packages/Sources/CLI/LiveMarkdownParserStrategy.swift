import Core
import CoreJSONParser
import CorePackageIndexing
import CoreProtocols
import CrawlerModels
import Foundation
import Logging
import LoggingModels
import MCPCore
import MCPSupport
import SampleIndex
import SampleIndexModels
import SampleIndexSQLite
import SearchAPI
import SearchModels
import SearchSQLite
import Services
import ServicesModels
import SharedConstants

// MARK: - Production Crawler.MarkdownParserStrategy

// Concrete `Crawler.MarkdownParserStrategy` wrapping
// `Core.JSONParser.MarkdownToStructuredPage`. Crawler doesn't import
// `CoreJSONParser`; only this composition root does.

struct LiveMarkdownParserStrategy: Crawler.MarkdownParserStrategy {
    func toStructuredPage(
        markdown: String,
        url: URL,
        depth _: Int?
    ) -> Shared.Models.StructuredDocumentationPage? {
        Core.JSONParser.MarkdownToStructuredPage.convert(markdown, url: url)
    }
}
