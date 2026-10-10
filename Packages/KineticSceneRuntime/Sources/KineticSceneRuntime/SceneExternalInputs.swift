import Foundation
import KineticWPEEngine

/// Optional host inputs. These APIs never capture audio or request player permissions.
@MainActor public enum SceneExternalInputs {
    public private(set) static var systemAudio: SceneAudioSpectrum?
    public static func publishSystemAudio(_ value: SceneAudioSpectrum?) {
        systemAudio = value
        let spectrum = value ?? .silence
        KineticWPEAudioInput.publish(left: spectrum.left, right: spectrum.right)
    }
    public static func publishMedia(playing: Bool, title: String?, artist: String? = nil, album: String? = nil,
                                    duration: Double? = nil, position: Double? = nil, trackID: String? = nil,
                                    playerBundleID: String? = nil, artwork: Data? = nil) {
        KineticWPENowPlayingInput.publish(playing: playing, title: title, artist: artist, album: album,
            duration: duration, position: position, trackID: trackID, playerBundleID: playerBundleID, artwork: artwork)
    }
}
