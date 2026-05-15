@testable import Crawler
import CrawlerModels
import Foundation
import LoggingModels
import SharedConstants
import Testing

// MARK: - Retry Queue Tests (#292)

@Suite("Retry Queue")
struct RetryQueueTests {
    // MARK: - Test 1: QueuedRetryURL Codable round-trip + backward compat

    @Test("QueuedRetryURL encodes and decodes with all fields")
    func queuedRetryURLCodableRoundTrip() throws {
        let now = Date()
        let original = Shared.Models.QueuedRetryURL(
            url: "https://developer.apple.com/documentation/swift/array",
            attempts: 1,
            nextAttempt: now
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Shared.Models.QueuedRetryURL.self, from: data)

        #expect(decoded.url == original.url)
        #expect(decoded.attempts == original.attempts)
        #expect(abs(decoded.nextAttempt.timeIntervalSince(original.nextAttempt)) < 1)
    }

    @Test("CrawlSessionState decodes without retryQueue field (backward compat)")
    func crawlSessionStateBackwardCompatDecode() throws {
        // Simulate an old-format session file that has no retryQueue field.
        let json = """
        {
            "visited": ["https://developer.apple.com/documentation/swift"],
            "queue": [],
            "startURL": "https://developer.apple.com/documentation/swift",
            "outputDirectory": "/tmp/cupertino-test",
            "sessionStartTime": "2026-05-15T00:00:00Z",
            "lastSaveTime": "2026-05-15T00:01:00Z",
            "isActive": true
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(Shared.Models.CrawlSessionState.self, from: data)

        // retryQueue must default to empty — not crash
        #expect(state.retryQueue.isEmpty)
        #expect(state.visited.count == 1)
    }

    // MARK: - Test 2: Backoff schedule

    @Test("Deferred retry backoff schedule: 30s → 5min → 30min")
    @MainActor
    func deferredRetryBackoffSchedule() {
        #expect(Crawler.AppleDocs.deferredRetryDelay(forAttempt: 0) == 30)
        #expect(Crawler.AppleDocs.deferredRetryDelay(forAttempt: 1) == 300)
        #expect(Crawler.AppleDocs.deferredRetryDelay(forAttempt: 2) == 1800)
        // Beyond max attempt always clamps to the last value (1800s)
        #expect(Crawler.AppleDocs.deferredRetryDelay(forAttempt: 5) == 1800)
    }

    // MARK: - Test 3: Counter methods

    @Test("recordDeferredRetry increments deferredRetries, recordRetrySucceeded increments retriesSucceeded")
    func stateCounterMethods() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = Shared.Configuration.ChangeDetection(
            enabled: false,
            metadataFile: tempDir.appendingPathComponent("metadata.json"),
            outputDirectory: tempDir
        )
        let state = Crawler.AppleDocs.State(configuration: config, logger: Logging.NoopRecording())

        var stats = await state.getStatistics()
        #expect(stats.deferredRetries == 0)
        #expect(stats.retriesSucceeded == 0)
        #expect(stats.errors == 0)

        await state.recordDeferredRetry()
        await state.recordDeferredRetry()
        await state.recordRetrySucceeded()

        stats = await state.getStatistics()
        #expect(stats.deferredRetries == 2)
        #expect(stats.retriesSucceeded == 1)
        #expect(stats.errors == 0, "recordDeferredRetry must not touch the error counter")
    }

    // MARK: - Test 4: Integration — looksLikeHTTPErrorPage leads to deferral not immediate error

    @Test("looksLikeHTTPErrorPage triggers deferred retry, not immediate error counter increment")
    @MainActor
    func httpErrorPageDefersInsteadOfErrors() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = try Shared.Configuration(
            crawler: Shared.Configuration.Crawler(
                startURL: #require(URL(string: "https://developer.apple.com/documentation/swift")),
                maxPages: 1,
                outputDirectory: tempDir,
                requestDelay: 0
            ),
            changeDetection: Shared.Configuration.ChangeDetection(
                enabled: false,
                metadataFile: tempDir.appendingPathComponent("metadata.json"),
                outputDirectory: tempDir
            ),
            output: Shared.Configuration.Output()
        )

        let crawler = await Crawler.AppleDocs(
            configuration: config,
            htmlParser: AlwaysHTTPErrorHTMLParserStrategy(),
            appleJSONParser: Crawler.NoopAppleJSONParserStrategy(),
            priorityPackageStrategy: Crawler.NoopPriorityPackageStrategy(),
            logger: Logging.NoopRecording()
        )

        // crawl() returns; we can't easily block on the retry queue itself
        // (it would wait 30s+ for real), but we can verify the deferral
        // stat is > 0 and errors == 0 right after the main loop runs.
        //
        // The NoopAppleJSONParserStrategy returns nil for jsonAPIURL so
        // the crawler falls through to the HTML path, which triggers the
        // AlwaysHTTPError strategy's looksLikeHTTPErrorPage returning true.
        let stats = try await crawler.crawl()

        // URL must have been deferred — not immediately counted as an error.
        // (The retry queue processes after the main loop; with 0 attempt URLs
        // they wait 30s, so the integration test doesn't exhaust them.
        // deferredRetries > 0 is the observable signal.)
        #expect(stats.deferredRetries > 0, "At least one URL should have been deferred for retry")
        #expect(stats.errors == 0, "Deferred URLs must not increment the error counter at deferral time")
    }

    // MARK: - Test 5: Integration — final retry exhausted → rejection log entry (AC-4)

    @Test("3 retries exhausted: recordRejection(.httpErrorTemplate) called once, URL not in pending queue")
    @MainActor
    func retriesExhaustedWritesRejectionLogEntry() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let startURL = try #require(URL(string: "https://developer.apple.com/documentation/swift"))
        let targetURL = "https://developer.apple.com/documentation/swift/array"

        // Pre-seed a resumable session with the target URL already at attempts: 2
        // (representing two prior retry passes). One more httpErrorPage response
        // from processRetryQueue pushes attempts to 3 (>= 3) and triggers
        // recordRejection(.httpErrorTemplate). nextAttempt is in the past so
        // processRetryQueue handles the item immediately — no real-time sleep.
        let metadataFile = tempDir.appendingPathComponent("metadata.json")
        var seedMetadata = Shared.Models.CrawlMetadata()
        seedMetadata.crawlState = Shared.Models.CrawlSessionState(
            visited: [startURL.absoluteString],
            queue: [],
            retryQueue: [
                Shared.Models.QueuedRetryURL(
                    url: targetURL,
                    attempts: 2,
                    nextAttempt: Date(timeIntervalSinceNow: -1)
                ),
            ],
            startURL: startURL.absoluteString,
            outputDirectory: tempDir.path
        )
        try seedMetadata.save(to: metadataFile)

        let config = try Shared.Configuration(
            crawler: Shared.Configuration.Crawler(
                startURL: startURL,
                maxPages: 1,
                outputDirectory: tempDir,
                requestDelay: 0
            ),
            changeDetection: Shared.Configuration.ChangeDetection(
                enabled: false,
                metadataFile: metadataFile,
                outputDirectory: tempDir
            ),
            output: Shared.Configuration.Output()
        )

        let crawler = await Crawler.AppleDocs(
            configuration: config,
            htmlParser: AlwaysHTTPErrorHTMLParserStrategy(),
            appleJSONParser: Crawler.NoopAppleJSONParserStrategy(),
            priorityPackageStrategy: Crawler.NoopPriorityPackageStrategy(),
            logger: Logging.NoopRecording()
        )

        let stats = try await crawler.crawl()

        // recordRejection(.httpErrorTemplate) must have been called exactly once.
        let rejectionLog = tempDir.appendingPathComponent(".cupertino-rejected-urls.jsonl")
        #expect(
            FileManager.default.fileExists(atPath: rejectionLog.path),
            "Rejection log must exist after all retries are exhausted"
        )
        let logLines = try String(contentsOf: rejectionLog, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        #expect(logLines.count == 1, "Exactly one rejection entry must be written")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(
            Crawler.AppleDocs.State.RejectedURLRecord.self,
            from: try #require(logLines.first?.data(using: .utf8))
        )
        #expect(record.reason == .httpErrorTemplate)
        #expect(record.url == targetURL)

        // The URL must not remain in the pending queue: exhaustion calls
        // recordError() instead of re-queuing, so errors > 0.
        #expect(stats.errors > 0, "Exhausted URL must increment the error counter, not be re-queued")
    }
}

// MARK: - Test helper: HTML parser that always signals an HTTP error page

private struct AlwaysHTTPErrorHTMLParserStrategy: Crawler.HTMLParserStrategy {
    func convert(html: String, url: URL) -> String { "" }

    func toStructuredPage(
        html: String,
        url: URL,
        source: Shared.Models.StructuredDocumentationPage.Source,
        depth: Int?
    ) -> Shared.Models.StructuredDocumentationPage? { nil }

    func looksLikeHTTPErrorPage(html: String) -> Bool { true }

    func looksLikeJavaScriptFallback(html: String) -> Bool { false }
}
