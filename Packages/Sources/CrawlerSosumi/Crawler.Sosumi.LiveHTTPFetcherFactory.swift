import CoreProtocols
import CrawlerModels
import Foundation

public extension Crawler.Sosumi {
    struct LiveHTTPFetcherFactory: Crawler.HTTPFetcherFactory {
        private let baseURL: URL

        public init(baseURL: URL) {
            self.baseURL = baseURL
        }

        public func makeFetcher(
            pageLoadTimeout: Duration,
            javascriptWaitTime _: Duration
        ) -> any Core.Protocols.StringContentFetcher {
            ContentFetcher(
                baseURL: baseURL,
                timeout: Self.timeInterval(from: pageLoadTimeout)
            )
        }

        private static func timeInterval(from duration: Duration) -> TimeInterval {
            let components = duration.components
            return TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1000000000000000000
        }
    }
}
