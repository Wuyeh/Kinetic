import Foundation

/// The host owns player access and permissions. The engine receives only validated metadata.
@MainActor public enum KineticWPENowPlayingInput {
    public static func publish(playing: Bool, title: String?, artist: String? = nil, album: String? = nil,
                               duration: Double? = nil, position: Double? = nil, trackID: String? = nil,
                               playerBundleID: String? = nil, artwork: Data? = nil) {
        guard [title, artist, album, trackID, playerBundleID].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 2048 }),
              (artwork?.count ?? 0) <= 4 * 1024 * 1024,
              duration.map({ $0.isFinite && (0...86_400).contains($0) }) ?? true,
              position.map({ $0.isFinite && (0...86_400).contains($0) }) ?? true else { return }
        let state = MonitorNowPlayingState(phase: title == nil ? .noPlayer : playing ? .playing : .paused,
            title: title ?? "", artist: artist, album: album, duration: duration, position: position,
            positionSampledAt: Date().timeIntervalSince1970, trackID: trackID,
            playerBundleID: playerBundleID, artwork: artwork)
        #if !LITE_BUILD
        WPEEnrichedNowPlayingFeed.shared.receiveFromHost(state)
        #endif
    }
}
