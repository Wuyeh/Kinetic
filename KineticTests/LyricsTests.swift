import XCTest
@testable import Kinetic

final class LyricsTests: XCTestCase {
    private let track = MusicTrack(id: "1", title: "Test Song", artist: "Test Artist", album: "Test Album", duration: 180)
    func testLRCFractionsMultipleTimestampsAndSeek() {
        let lines = TrackLyrics.parseLRC("[00:01.5][00:02.125]Test\n[00:30]Next", duration: 180)
        XCTAssertEqual(lines.map(\.time), [1.5, 2.125, 30])
        let value = TrackLyrics(plain: "", lines: lines, instrumental: false)
        XCTAssertNil(value.currentIndex(at: 0)); XCTAssertEqual(value.currentIndex(at: 2.2), 1)
        XCTAssertEqual(value.currentIndex(at: 40), 2); XCTAssertEqual(value.currentIndex(at: 1.6), 0)
    }
    func testUnreliableTimingIsRejectedRatherThanPretendingToSync() {
        for input in ["[00:01]A\n[00:01]B", "[00:61]A", "[10:00]A", "[offset:200]\n[00:01]A", "no timestamps"] {
            XCTAssertTrue(TrackLyrics.parseLRC(input, duration: 180).isEmpty)
        }
        XCTAssertTrue(TrackLyrics.parseLRC(String(repeating: "x", count: 300000), duration: 180).isEmpty)
    }
    private func response(title: String = "Test Song", artist: String = "Test Artist", duration: Double = 180, synced: String = "[00:10]Original test line") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["trackName": title, "artistName": artist, "albumName": "Test Album", "duration": duration, "instrumental": false,
                                                    "plainLyrics": "Original test line", "syncedLyrics": synced])
    }
    func testStrictMatchingAndPlainFallbackAndResponseBound() throws {
        let value = try LRCLIBClient.decode(response(), matching: track); XCTAssertEqual(value.lines.first?.time, 10)
        for data in [try response(title: "Another Song"), try response(artist: "Another Artist"), try response(duration: 190)] {
            XCTAssertThrowsError(try LRCLIBClient.decode(data, matching: track))
        }
        let plain = try LRCLIBClient.decode(response(synced: "unreliable timing"), matching: track)
        XCTAssertTrue(plain.lines.isEmpty); XCTAssertFalse(plain.plain.isEmpty)
        XCTAssertThrowsError(try LRCLIBClient.decode(Data(repeating: 0, count: LRCLIBClient.responseLimit + 1), matching: track))
        let url = try LRCLIBClient.url(track)
        XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.host, "lrclib.net")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 4)
    }
    func testCacheSurvivesRestartAndIsBoundedAndPreservesFutureFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lyrics.json"), client = TestLyricsClient()
        let repo = LyricsRepository(client: client, file: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let original = try await repo.lyrics(for: track)
        let other = LyricsRepository(client: client, file: file)
        let cached = try await other.lyrics(for: track); XCTAssertEqual(cached, original)
        let calls = await client.calls; XCTAssertEqual(calls, 1)
        for i in 0..<40 { _ = try await repo.lyrics(for: .init(id: String(i), title: "Test \(i)", artist: "Artist", album: "", duration: 180)) }
        let data = try Data(contentsOf: file); XCTAssertLessThanOrEqual(data.count, 1024 * 1024)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["entries"] as? [Any])?.count, 32)
        let future = Data("{\"version\":99,\"entries\":[]}".utf8); try future.write(to: file)
        _ = try await LyricsRepository(client: client, file: file).lyrics(for: track)
        XCTAssertEqual(try Data(contentsOf: file), future)
    }
    func testSymlinkCacheDoesNotReadOrOverwriteTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), file = root.appendingPathComponent("cache")
        let sentinel = Data("preserve".utf8); try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        _ = try await LyricsRepository(client: TestLyricsClient(), file: file).lyrics(for: track)
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
    }
    func testHTTPFailuresDeclaredAndStreamedLimitsAndValidResponse() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LyricsMockURLProtocol.self]
        let client = LRCLIBClient(configuration: config)
        for (status, body, headers) in [
            (404, Data(), [String: String]()),
            (302, Data(), ["Location": "https://example.com/never-follow"]),
            (200, Data(), ["Content-Length": String(LRCLIBClient.responseLimit + 1)]),
            (200, Data(repeating: 65, count: LRCLIBClient.responseLimit + 1), [String: String]())
        ] {
            LyricsMockURLProtocol.set(status: status, data: body, headers: headers)
            do { _ = try await client.fetch(track); XCTFail("Invalid HTTP response accepted") } catch { }
        }
        LyricsMockURLProtocol.set(status: 200, data: try response(), headers: ["Content-Type": "application/json"])
        let value = try await client.fetch(track); XCTAssertEqual(value.lines.first?.time, 10)
    }
}

private final class LyricsMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var status = 200, body = Data(), headers: [String: String] = [:]
    static func set(status: Int, data: Data, headers: [String: String]) {
        lock.lock(); defer { lock.unlock() }; self.status = status; body = data; self.headers = headers
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lrclib.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let status = Self.status, body = Self.body, headers = Self.headers; Self.lock.unlock()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class LyricsServiceTests: XCTestCase {
    private func settle(_ milliseconds: UInt64 = 90) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
    func testExplicitOptInThenOffCancelsAndMusicStillWorks() async {
        let reader = TestMusicReader(), client = TestLyricsClient()
        let service = MusicService(reader: reader, repository: .init(client: client), scheduler: TestMusicScheduler())
        let lease = service.subscribe(source: .appleMusic, lyrics: false, visible: true)
        await settle(); let observed1 = await client.calls; XCTAssertEqual(observed1, 0)
        lease.update(visible: true, source: .appleMusic, lyrics: true); await settle()
        let observed2 = await client.calls; XCTAssertEqual(observed2, 1); XCTAssertEqual(service.lyrics[.appleMusic]?.status, .ready)
        lease.update(visible: true, source: .appleMusic, lyrics: false); await settle()
        XCTAssertEqual(service.lyrics[.appleMusic]?.status, .off); XCTAssertNotNil(service.snapshots[.appleMusic]?.track)
        lease.cancel(); service.shutdown()
    }
    func testRapidTrackChangeDiscardsOlderLyricsAndFailureIsGraceful() async {
        let reader = TestMusicReader(), client = TestLyricsClient(); await client.configure(delay: 180_000_000)
        let service = MusicService(reader: reader, repository: .init(client: client), scheduler: TestMusicScheduler())
        let lease = service.subscribe(source: .appleMusic, lyrics: true, visible: true)
        await settle(50)
        var value = await reader.value; value.track = .init(id: "2", title: "第二首", artist: "Artist", album: "", duration: 180)
        await reader.set(value); service.refresh(); await settle(260)
        XCTAssertEqual(service.lyrics[.appleMusic]?.value?.plain, "第二首\n测试第二行")
        await client.configure(fail: true); value.track = .init(id: "3", title: "第三首", artist: "Artist", album: "", duration: 180)
        await reader.set(value); service.refresh(); await settle()
        XCTAssertEqual(service.lyrics[.appleMusic]?.status, .unavailable)
        XCTAssertEqual(service.snapshots[.appleMusic]?.track?.title, "第三首")
        lease.cancel(); service.shutdown()
    }
}
