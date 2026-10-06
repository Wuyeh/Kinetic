import Foundation

/// Audio analysis input is separate from wallpaper sound/mute. Module 45 may supply
/// authorized system capture later; the Scene package never asks for capture permission.
public struct SceneAudioSpectrum: Sendable, Equatable {
    public let left: [Float]
    public let right: [Float]
    public static let silence = try! SceneAudioSpectrum(left: .init(repeating: 0, count: 64), right: .init(repeating: 0, count: 64))

    public init(left: [Float], right: [Float]) throws {
        guard left.count == 64, right.count == 64, (left + right).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw SceneRuntimeError.malformed("audio spectrum requires 64 finite normalized stereo bands")
        }
        self.left = left; self.right = right
    }
}
