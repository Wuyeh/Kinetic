import AppKit
import Carbon
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol MusicReading: Sendable {
    func read(_ source: MusicSource) async -> MusicSnapshot
    func authorize(_ source: MusicSource) async -> MusicAvailability
    func control(_ command: MusicControl, source: MusicSource) async -> Bool
}

/// Public Apple Events only. Runs on its own actor and never launches a player.
actor LiveMusicReader: MusicReading {
    private var artwork: [MusicSource: (id: String, data: Data?)] = [:]
    private let artworkSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4; c.timeoutIntervalForResource = 6
        c.urlCache = nil; c.httpCookieStorage = nil; c.urlCredentialStorage = nil
        return URLSession(configuration: c)
    }()
    static func code(_ text: String) -> AEKeyword { text.utf8.reduce(0) { ($0 << 8) | AEKeyword($1) } }
    private func running(_ source: MusicSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }
    private func permission(_ source: MusicSource, ask: Bool) -> MusicAvailability {
        guard running(source) else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: source.bundleID)
        let result = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        switch result { case noErr: return .live; case -1744: return .permissionRequired; case -1743: return .denied; default: return .unavailable }
    }
    func authorize(_ source: MusicSource) async -> MusicAvailability { permission(source, ask: true) }
    /// Module 55：只读授权状态，不弹系统询问。
    func permissionStatus(_ source: MusicSource) async -> MusicAvailability { permission(source, ask: false) }
    private func specifier(_ property: String, container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(typeCode: Self.code(property)), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }
    static func event(_ source: MusicSource, eventClass: AEEventClass = kAECoreSuite, id: AEEventID = kAEGetData,
                      object: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        // getd belongs to the 'core' scripting suite. 'aevt' is for open/quit events.
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: id, targetDescriptor: .init(bundleIdentifier: source.bundleID),
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: keyDirectObject) }
        return event
    }
    private func send(_ source: MusicSource, eventClass: AEEventClass = kAECoreSuite, id: AEEventID = kAEGetData,
                      object: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        try Task.checkCancellation()
        guard running(source) else { throw MusicReadError.unavailable }
        let event = Self.event(source, eventClass: eventClass, id: id, object: object)
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 1)
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber), number.int32Value != 0 {
            if number.int32Value == -1743 { throw MusicReadError.denied }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(number.int32Value))
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }
    func read(_ source: MusicSource) async -> MusicSnapshot {
        let allowed = permission(source, ask: false)
        guard allowed == .live else { return .init(availability: allowed) }
        do {
            let state = try send(source, object: specifier("pPlS")).enumCodeValue
            guard state != Self.code("kPSS") else { return .init(availability: .noTrack) }
            let track = specifier("pTrk")
            // Read only the named metadata. Never request all track properties (lyrics, comments, etc.).
            func value(_ key: String) throws -> NSAppleEventDescriptor { try send(source, object: specifier(key, container: track)) }
            let title = try value("pnam").stringValue ?? ""
            let artist = try value("pArt").stringValue ?? "", album = try value("pAlb").stringValue ?? ""
            let id = (try? value(source.trackIDProperty).stringValue) ?? title + "\u{1f}" + artist + "\u{1f}" + album
            guard !title.isEmpty else { return .init(availability: .noTrack) }
            let duration = try value("pDur").doubleValue / (source == .spotify ? 1000 : 1)
            var data: Data?
            if source == .appleMusic {
                if artwork[source]?.id != id {
                    let record = NSAppleEventDescriptor.record()
                    record.setDescriptor(.init(typeCode: Self.code("cArt")), forKeyword: AEKeyword(keyAEDesiredClass))
                    record.setDescriptor(.init(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
                    record.setDescriptor(.init(int32: 1), forKeyword: AEKeyword(keyAEKeyData)); record.setDescriptor(track, forKeyword: AEKeyword(keyAEContainer))
                    let item = record.coerce(toDescriptorType: typeObjectSpecifier)!
                    let raw = try? send(source, object: specifier("pRaw", container: item)).data
                    artwork[source] = (id, raw.flatMap(Self.thumbnail))
                }
                data = artwork[source]?.data
            }
            let url = source == .spotify ? (try? value(source.artworkURLProperty).stringValue).flatMap { $0 }.flatMap(URL.init(string:)) : nil
            if source == .spotify {
                if artwork[source]?.id != id { artwork[source] = (id, await spotifyArtwork(url)) }
                data = artwork[source]?.data
            }
            let parsed = try MusicTrack(id: id, title: title, artist: artist, album: album, duration: duration, artwork: data, artworkURL: url).validated()
            // Sample progress last so cover loading cannot leave lyrics several seconds behind.
            let position = try send(source, object: specifier("pPos")).doubleValue
            guard position.isFinite, position >= 0 else { throw MusicReadError.invalidResponse }
            return .init(availability: .live, track: parsed, isPlaying: state == Self.code("kPSP"), position: min(position, duration), sampledAt: Date())
        } catch {
            let code = (error as NSError).code
            return .init(availability: error as? MusicReadError == .denied || code == -1743 ? .denied : code == -1712 ? .timedOut : .unavailable)
        }
    }
    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= 4 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(encoder, image, nil)
        return CGImageDestinationFinalize(encoder) ? output as Data : nil
    }
    private func spotifyArtwork(_ url: URL?) async -> Data? {
        guard let url, url.scheme == "https", ["i.scdn.co", "mosaic.scdn.co"].contains(url.host), url.user == nil, url.password == nil else { return nil }
        do {
            let (bytes, response) = try await artworkSession.bytes(from: url, delegate: MusicArtworkRedirectPolicy.shared)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= 4 * 1024 * 1024 else { return nil }
            var data = Data()
            for try await byte in bytes { try Task.checkCancellation(); guard data.count < 4 * 1024 * 1024 else { return nil }; data.append(byte) }
            return Self.thumbnail(data)
        } catch { return nil }
    }
    func control(_ command: MusicControl, source: MusicSource) async -> Bool {
        guard permission(source, ask: false) == .live else { return false }
        let id = command == .playPause ? "PlPs" : command == .next ? "Next" : "Prev"
        return (try? send(source, eventClass: Self.code(source.commandSuite), id: Self.code(id))) != nil
    }
}

private final class MusicArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = MusicArtworkRedirectPolicy()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
