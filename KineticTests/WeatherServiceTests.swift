import AppKit
import XCTest
@testable import Kinetic

enum WeatherTestFixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static func place(_ id: String = "A") -> WeatherPlace {
        .init(id: id, name: "测试城市 \(id)", latitude: id == "B" ? 31.23 : 52.52,
              longitude: id == "B" ? 121.47 : 13.41, timeZone: id == "B" ? "Asia/Shanghai" : "Europe/Berlin")
    }
    static func snapshot(place: WeatherPlace = place(), code: Int = 61, date: Date = now) -> WeatherSnapshot {
        .init(place: place, weatherCode: code, temperatureCelsius: 12.5, isDay: true,
              windSpeedMetresPerSecond: 7, windDirectionDegrees: 270, precipitationMillimetres: 1,
              observedAt: date.addingTimeInterval(-300), fetchedAt: date)
    }
    static func json(now: Date = now) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "current": ["time": now.timeIntervalSince1970 - 300, "temperature_2m": 12.5, "is_day": 1,
                        "weather_code": 61, "wind_speed_10m": 7, "wind_direction_10m": 270, "precipitation": 1],
            "current_units": ["time": "unixtime", "temperature_2m": "°C", "is_day": "", "weather_code": "wmo code",
                              "wind_speed_10m": "m/s", "wind_direction_10m": "°", "precipitation": "mm"]
        ])
    }
}

actor WeatherTestClient: WeatherFetching {
    private(set) var calls: [WeatherPlace] = []
    private(set) var searches: [String] = []
    var failure: WeatherError?
    var code = 61
    func setFailure(_ error: WeatherError?) { failure = error }
    func setCode(_ code: Int) { self.code = code }
    func fetchWeather(for place: WeatherPlace, now: Date) async throws -> WeatherSnapshot {
        calls.append(place); if let failure { throw failure }
        return WeatherTestFixture.snapshot(place: place, code: code, date: now)
    }
    func searchPlaces(_ query: String) async throws -> [WeatherPlace] { searches.append(query); return [WeatherTestFixture.place()] }
}

actor WeatherGateClient: WeatherFetching {
    private var waiting: [String: (WeatherPlace, Date, CheckedContinuation<WeatherSnapshot, Error>)] = [:]
    private(set) var calls: [String] = []
    func fetchWeather(for place: WeatherPlace, now: Date) async throws -> WeatherSnapshot {
        calls.append(place.id)
        return try await withCheckedThrowingContinuation { waiting[place.id] = (place, now, $0) }
    }
    func resolve(_ id: String) {
        guard let (place, date, continuation) = waiting.removeValue(forKey: id) else { return }
        continuation.resume(returning: WeatherTestFixture.snapshot(place: place, date: date))
    }
    func searchPlaces(_ query: String) async throws -> [WeatherPlace] { [] }
}

@MainActor
final class WeatherTestLocation: WeatherLocating {
    var onAccessRevoked: (() -> Void)?
    private(set) var requests: [Bool] = []
    private(set) var cancellations = 0
    var denied = false
    var authorized = false
    func locate(requestAuthorization: Bool) async throws -> WeatherPlace {
        requests.append(requestAuthorization)
        if denied { throw WeatherError.permissionDenied }
        guard requestAuthorization || authorized else { throw WeatherError.permissionRequired }
        return WeatherTestFixture.place("system")
    }
    func cancel() { cancellations += 1 }
}

private final class WeatherHTTPFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var payload = Data()
    static var status = 200
    static var declaredLength: Int?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.open-meteo.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var headers = ["Content-Type": "application/json"]
        if let length = Self.declaredLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class WeatherServiceTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    func root() throws -> URL {
        let root = TestWorkspaceDirectory.make(".build/Module35-36/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root); return root
    }
    func store() throws -> WeatherStore { .init(storage: .init(rootURL: try root()), now: { WeatherTestFixture.now }) }
    func wait(_ condition: @escaping @MainActor () -> Bool, timeout: Double = 3) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() { guard ProcessInfo.processInfo.systemUptime < end else { throw WeatherError.network }; try await Task.sleep(nanoseconds: 10_000_000) }
    }
    func waitAsync(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()) { guard ProcessInfo.processInfo.systemUptime < end else { throw WeatherError.network }; try await Task.sleep(nanoseconds: 10_000_000) }
    }
    func testDefaultOffCreatesNoFileTimerNetworkOrLocationManager() async throws {
        let store = try store(), client = WeatherTestClient(), location = WeatherTestLocation()
        let service = WeatherService(store: store, client: client, location: location, now: { WeatherTestFixture.now })
        service.start(); service.refresh()
        XCTAssertEqual(service.reading.activity, .off); XCTAssertFalse(service.hasRefreshTimer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path)); XCTAssertTrue(location.requests.isEmpty)
        let calls = await client.calls; XCTAssertTrue(calls.isEmpty)
        let native = WeatherSystemLocation(); XCTAssertFalse(native.hasCreatedManager)
        service.shutdown()
    }
    func testWMOConditionsIncludingUnknownNeverPretendToBeSunny() {
        for (code, condition): (Int, WeatherCondition) in [(0, .clear), (3, .cloudy), (45, .fog), (51, .drizzle), (66, .rain), (86, .snow), (99, .thunderstorm), (123, .unknown)] {
            XCTAssertEqual(WeatherCondition(code: code), condition)
        }
    }
    func testPlaceConfigurationFiniteRangeAndTimezoneValidation() {
        var place = WeatherTestFixture.place()
        place.latitude = .nan; XCTAssertThrowsError(try place.validated())
        place.latitude = 91; XCTAssertThrowsError(try place.validated())
        place = WeatherTestFixture.place(); place.longitude = -.infinity; XCTAssertThrowsError(try place.validated())
        place = WeatherTestFixture.place(); place.timeZone = "fake-time-zone"; XCTAssertThrowsError(try place.validated())
        XCTAssertThrowsError(try WeatherConfiguration(mode: .manual).validated())
        XCTAssertNoThrow(try WeatherConfiguration().validated())
    }
    func testRealAPISchemaUnitsUTCTimestampAndMissingFields() throws {
        let data = try WeatherTestFixture.json(), place = WeatherTestFixture.place()
        let value = try WeatherClient.decodeSnapshot(data, place: place, now: WeatherTestFixture.now)
        XCTAssertEqual(value, WeatherTestFixture.snapshot()); XCTAssertEqual(value.availability, .live)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var units = try XCTUnwrap(json["current_units"] as? [String: String]); units["wind_speed_10m"] = "km/h"; json["current_units"] = units
        XCTAssertThrowsError(try WeatherClient.decodeSnapshot(JSONSerialization.data(withJSONObject: json), place: place, now: WeatherTestFixture.now))
        XCTAssertThrowsError(try WeatherClient.decodeSnapshot(Data("{}".utf8), place: place, now: WeatherTestFixture.now))
        XCTAssertThrowsError(try WeatherClient.decodeSnapshot(Data(repeating: 0, count: WeatherClient.maximumResponseBytes + 1), place: place, now: WeatherTestFixture.now))
    }
    func testSnapshotRejectsNonfiniteFutureAndInvalidWeatherMeasurements() throws {
        for mutate: (inout WeatherSnapshot) -> Void in [
            { $0.temperatureCelsius = .infinity }, { $0.precipitationMillimetres = -1 }, { $0.windSpeedMetresPerSecond = 151 },
            { $0.windDirectionDegrees = -1 }, { $0.observedAt = WeatherTestFixture.now.addingTimeInterval(600) },
            { $0.fetchedAt = Date(timeIntervalSince1970: .nan) }
        ] { var snapshot = WeatherTestFixture.snapshot(); mutate(&snapshot); XCTAssertThrowsError(try snapshot.validated(now: WeatherTestFixture.now)) }
    }
    func testGeocodingDecodedNamesDuplicatesAndSafeSearchURL() throws {
        let data = Data(#"{"results":[{"id":1,"name":"北京","latitude":39.9,"longitude":116.4,"timezone":"Asia/Shanghai","country":"中国"},{"id":1,"name":"北京","latitude":39.9,"longitude":116.4,"timezone":"Asia/Shanghai"},{"id":2,"name":"Bad","latitude":999,"longitude":1,"timezone":"UTC"}]}"#.utf8)
        let places = try WeatherClient.decodePlaces(data); XCTAssertEqual(places.count, 1); XCTAssertTrue(places[0].name.contains("北京"))
        let url = try WeatherClient.searchURL("北京 & name=evil")
        XCTAssertEqual(url.host, "geocoding-api.open-meteo.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "name" }?.value, "北京 & name=evil")
        XCTAssertThrowsError(try WeatherClient.searchURL("x"))
        let forecast = try WeatherClient.forecastURL(for: WeatherTestFixture.place())
        XCTAssertEqual(URLComponents(url: forecast, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "wind_speed_unit" }?.value, "ms")
    }
    func testNativeHTTPClientBoundedBodyStatusAndDeclaredLength() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WeatherHTTPFixtureProtocol.self]
        let client = WeatherClient(configuration: config)
        WeatherHTTPFixtureProtocol.payload = try WeatherTestFixture.json(); WeatherHTTPFixtureProtocol.status = 200; WeatherHTTPFixtureProtocol.declaredLength = nil
        let snapshot = try await client.fetchWeather(for: WeatherTestFixture.place(), now: WeatherTestFixture.now)
        XCTAssertEqual(snapshot.condition, .rain)
        for (status, length, payload) in [(429, Optional<Int>.none, Data()), (302, nil, Data()),
            (200, WeatherClient.maximumResponseBytes + 1, Data()), (200, nil, Data(repeating: 0, count: WeatherClient.maximumResponseBytes + 1))] {
            WeatherHTTPFixtureProtocol.status = status; WeatherHTTPFixtureProtocol.declaredLength = length; WeatherHTTPFixtureProtocol.payload = payload
            do { _ = try await client.fetchWeather(for: WeatherTestFixture.place(), now: WeatherTestFixture.now); XCTFail("Unsafe response accepted") } catch { XCTAssertTrue(error is WeatherError) }
        }
    }
    func testCacheRoundTripMatchingCityLRUBoundsAndOffModeRetention() throws {
        let store = try store(); try store.saveConfiguration(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
        for id in 0..<20 { try store.saveSnapshot(WeatherTestFixture.snapshot(place: WeatherTestFixture.place(String(id))), system: false) }
        XCTAssertNil(store.cached(for: WeatherTestFixture.place("0"))); XCTAssertNotNil(store.cached(for: WeatherTestFixture.place("19")))
        var changed = WeatherTestFixture.place("19"); changed.latitude += 1; XCTAssertNil(store.cached(for: changed))
        try store.saveConfiguration(.init())
        let reread = WeatherStore(storage: .init(rootURL: store.fileURL.deletingLastPathComponent()), now: { WeatherTestFixture.now })
        XCTAssertEqual(reread.configuration.mode, .off); XCTAssertNotNil(reread.cached(for: WeatherTestFixture.place("19")))
    }
    func testCorruptFutureAndSymlinkSettingsPreserveOriginalBytes() throws {
        for text in ["broken", #"{"version":2,"configuration":{"mode":"off"},"cache":[]}"#] {
            let root = try root(), file = root.appendingPathComponent("weather.json"); let bytes = Data(text.utf8); try bytes.write(to: file)
            let store = WeatherStore(storage: .init(rootURL: root), now: { WeatherTestFixture.now })
            XCTAssertNotNil(store.loadError); XCTAssertThrowsError(try store.saveConfiguration(.init()))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        let root = try root(), target = root.appendingPathComponent("target.json"), link = root.appendingPathComponent("weather.json")
        try Data("original".utf8).write(to: target); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = WeatherStore(storage: .init(rootURL: root)); XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.saveConfiguration(.init())); XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
    }
    func testAtomicWriteFailureDoesNotPublishNewConfiguration() throws {
        let root = try root(), block = root.appendingPathComponent("block"); try Data().write(to: block)
        let store = WeatherStore(storage: .init(rootURL: block))
        XCTAssertThrowsError(try store.saveConfiguration(.init(mode: .manual, manualPlace: WeatherTestFixture.place())))
        XCTAssertEqual(store.configuration.mode, .off)
    }
    func testManualFetchCachesThenNetworkFailureUsesActualStaleCache() async throws {
        var date = WeatherTestFixture.now
        let store = WeatherStore(storage: .init(rootURL: try root()), now: { date }), client = WeatherTestClient(), location = WeatherTestLocation()
        let service = WeatherService(store: store, client: client, location: location, now: { date }); service.start()
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
        try await wait { service.reading.activity == .ready && !service.isFetching }
        let actual = try XCTUnwrap(service.reading.snapshot); XCTAssertEqual(actual.condition, .rain); XCTAssertTrue(location.requests.isEmpty)
        date.addTimeInterval(3_600); await client.setFailure(.network); service.refresh()
        try await wait { !service.isFetching }
        let cached = try XCTUnwrap(service.reading.snapshot); XCTAssertEqual(cached.temperatureCelsius, actual.temperatureCelsius)
        XCTAssertEqual(cached.observedAt, actual.observedAt); XCTAssertEqual(cached.availability, .cached); XCTAssertTrue(cached.isStale)
        XCTAssertTrue(cached.permitsResponse(at: date)); date.addTimeInterval(6 * 3_600); XCTAssertFalse(cached.permitsResponse(at: date))
        service.shutdown(); XCTAssertFalse(service.hasRefreshTimer)
    }
    func testFirstNetworkFailureLeavesWeatherUnavailableRatherThanInventingData() async throws {
        let client = WeatherTestClient(); await client.setFailure(.network)
        let service = WeatherService(store: try store(), client: client, location: WeatherTestLocation(), now: { WeatherTestFixture.now }); service.start()
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
        try await wait { !service.isFetching }; XCTAssertEqual(service.reading.activity, .unavailable); XCTAssertNil(service.reading.snapshot); service.shutdown()
    }
    func testLocationAuthorizationOnlyExplicitSaveAndRevocationClearsResponseData() async throws {
        let store = try store(); try store.saveConfiguration(.init(mode: .system))
        let location = WeatherTestLocation(), client = WeatherTestClient()
        let service = WeatherService(store: store, client: client, location: location, now: { WeatherTestFixture.now }); service.start()
        try await wait { !service.isFetching }; XCTAssertEqual(location.requests, [false]); XCTAssertNil(service.reading.snapshot)
        let before = await client.calls; XCTAssertTrue(before.isEmpty)
        try service.configure(.init(mode: .system), requestSystemPermission: true)
        try await wait { !service.isFetching }; XCTAssertEqual(location.requests, [false, true]); XCTAssertNotNil(service.reading.snapshot)
        location.onAccessRevoked?(); XCTAssertNil(service.reading.snapshot); XCTAssertEqual(service.reading.activity, .unavailable)
        service.shutdown(); location.onAccessRevoked?(); XCTAssertEqual(service.reading.activity, .off)
    }
    func testDeniedSystemLocationDoesNotReuseOrSendCachedCoordinates() async throws {
        let store = try store(); try store.saveSnapshot(WeatherTestFixture.snapshot(place: WeatherTestFixture.place("system")), system: true)
        try store.saveConfiguration(.init(mode: .system))
        let location = WeatherTestLocation(); location.denied = true; let client = WeatherTestClient()
        let service = WeatherService(store: store, client: client, location: location, now: { WeatherTestFixture.now }); service.start()
        try await wait { !service.isFetching }; XCTAssertNil(service.reading.snapshot)
        let calls = await client.calls; XCTAssertTrue(calls.isEmpty); service.shutdown()
    }
    func testRapidCityChangesRejectLateSuccessAndNeverPublishOtherCity() async throws {
        let store = try store(), client = WeatherGateClient()
        let service = WeatherService(store: store, client: client, location: WeatherTestLocation(), now: { WeatherTestFixture.now }); service.start()
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place("A")))
        try await waitAsync { await client.calls.contains("A") }
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place("B")))
        XCTAssertNil(service.reading.snapshot)
        try await waitAsync { await client.calls.contains("B") }; await client.resolve("B")
        try await wait { !service.isFetching }; XCTAssertEqual(service.reading.snapshot?.place.id, "B")
        await client.resolve("A"); try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(service.reading.snapshot?.place.id, "B"); XCTAssertNil(store.cached(for: WeatherTestFixture.place("A"))); service.shutdown()
    }
    func testOffAndShutdownCancelLateFetchWithoutResurrectingWeather() async throws {
        for off in [true, false] {
            let client = WeatherGateClient(), service = WeatherService(store: try store(), client: client, location: WeatherTestLocation(), now: { WeatherTestFixture.now })
            service.start(); try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
            try await waitAsync { await client.calls.count == 1 }
            if off { try service.configure(.init()) } else { service.shutdown() }
            await client.resolve("A"); try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(service.reading.activity, .off); XCTAssertNil(service.reading.snapshot); XCTAssertFalse(service.hasRefreshTimer); service.shutdown()
        }
    }
    func testSafetySuspensionCancelsFetchAndWakeResumesWithoutPermissionPrompt() async throws {
        let client = WeatherGateClient(), location = WeatherTestLocation()
        let service = WeatherService(store: try store(), client: client, location: location, now: { WeatherTestFixture.now }); service.start()
        try service.configure(.init(mode: .manual, manualPlace: WeatherTestFixture.place()))
        try await waitAsync { await client.calls.count == 1 }; service.setSuspended(true); XCTAssertFalse(service.hasRefreshTimer)
        await client.resolve("A"); try await Task.sleep(nanoseconds: 20_000_000); XCTAssertNil(service.reading.snapshot)
        service.setSuspended(false); try await waitAsync { await client.calls.count == 2 }; await client.resolve("A")
        try await wait { !service.isFetching }; XCTAssertNotNil(service.reading.snapshot); XCTAssertTrue(location.requests.isEmpty); service.shutdown()
    }
}
