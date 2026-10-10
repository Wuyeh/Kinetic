import AVFoundation
import ScreenCaptureKit
import XCTest
@testable import Kinetic

@MainActor private final class TestAudioCapture: SystemAudioCapturing {
    var onSpectrum: (@MainActor (StereoAudioSpectrum) -> Void)?
    var onFailure: (@MainActor () -> Void)?
    var permission = false, grantOnRequest = false, fail = false
    var requests = 0, starts = 0, stops = 0
    var delay: UInt64 = 0
    func hasPermission() -> Bool { permission }
    func requestPermission() -> Bool { requests += 1; permission = grantOnRequest; return permission }
    func start() async throws {
        starts += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fail { throw AudioCaptureError.unavailable }
    }
    func stop() async { stops += 1 }
}

@MainActor final class AudioResponseTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "Kinetic.AudioResponseTests." + UUID().uuidString)! }
    private func music() -> MusicService { MusicService(reader: TestMusicReader(), scheduler: TestMusicScheduler()) }
    func testDefaultsNeverRequestPermissionsCaptureOrReadMusic() async {
        let capture = TestAudioCapture(), music = music()
        var outputs = [StereoAudioSpectrum?]()
        let service = AudioResponseService(music: music, defaults: defaults(), capture: capture,
            publishSpectrum: { outputs.append($0) }, publishMedia: { _, _ in })
        service.setScenePlaying(true); await service.waitForIdle()
        XCTAssertFalse(service.settings.isEnabled); XCTAssertEqual(service.status, .off)
        XCTAssertEqual(capture.requests, 0); XCTAssertEqual(capture.starts, 0); XCTAssertEqual(music.subscriberCount, 0)
        XCTAssertTrue(outputs.allSatisfy { $0 == nil })
        service.shutdown(); await service.waitForIdle(); music.shutdown()
    }
    func testDeniedAudioDoesNotStopExistingMusicOrWallpapersAndDoesNotReprompt() async {
        let capture = TestAudioCapture(), music = music(), d = defaults()
        let existing = music.subscribe(source: .appleMusic, lyrics: false, visible: true)
        let service = AudioResponseService(music: music, defaults: d, capture: capture, publishSpectrum: { _ in }, publishMedia: { _, _ in })
        service.setScenePlaying(true); service.setEnabled(true); await service.waitForIdle()
        XCTAssertEqual(capture.requests, 1); XCTAssertEqual(capture.starts, 0); XCTAssertEqual(service.status, .permissionRequired)
        service.setScenePlaying(true); await service.waitForIdle(); XCTAssertEqual(capture.requests, 1)
        try? await Task.sleep(nanoseconds: 80_000_000); XCTAssertEqual(music.snapshots[.appleMusic]?.availability, .live)
        service.setEnabled(false); await service.waitForIdle(); XCTAssertEqual(music.subscriberCount, 1)
        XCTAssertTrue(music.isSampling); XCTAssertFalse(service.settings.isEnabled)
        service.shutdown(); await service.waitForIdle(); existing.cancel(); music.shutdown()
    }
    func testSlowStartAndRapidDisableIgnoreLateSpectrumAndReleaseCapture() async {
        let capture = TestAudioCapture(); capture.permission = true; capture.delay = 100_000_000
        let music = music(); var last: StereoAudioSpectrum?
        let service = AudioResponseService(music: music, defaults: defaults(), capture: capture,
            publishSpectrum: { last = $0 }, publishMedia: { _, _ in })
        service.setScenePlaying(true); service.setEnabled(true)
        try? await Task.sleep(nanoseconds: 10_000_000)
        service.setEnabled(false); await service.waitForIdle()
        capture.onSpectrum?(.init(left: .init(repeating: 1, count: 64), right: .init(repeating: 1, count: 64)))
        XCTAssertNil(last); XCTAssertEqual(service.status, .off); XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(service.analyzedFrames, 0); XCTAssertEqual(music.subscriberCount, 0)
        service.shutdown(); await service.waitForIdle(); music.shutdown()
    }
    func testLockScenePauseResumeAndExplicitFailureRetry() async {
        let capture = TestAudioCapture(); capture.permission = true
        let music = music(); var last: StereoAudioSpectrum?
        let service = AudioResponseService(music: music, defaults: defaults(), capture: capture,
            publishSpectrum: { last = $0 }, publishMedia: { _, _ in })
        service.setScenePlaying(true); service.setEnabled(true); await service.waitForIdle()
        XCTAssertEqual(service.status, .listening)
        capture.onSpectrum?(.init(left: .init(repeating: 0.5, count: 64), right: .init(repeating: 0.3, count: 64)))
        XCTAssertNotNil(last); XCTAssertEqual(service.analyzedFrames, 1)
        var conditions = SmartPauseConditions(); conditions.screenLocked = true; service.updateConditions(conditions); await service.waitForIdle()
        XCTAssertEqual(service.status, .suspended); XCTAssertNil(last); XCTAssertEqual(capture.stops, 1)
        conditions.screenLocked = false; service.updateConditions(conditions); await service.waitForIdle()
        XCTAssertEqual(capture.starts, 2); XCTAssertEqual(capture.requests, 0)
        capture.onFailure?(); await service.waitForIdle(); XCTAssertEqual(service.status, .failed); XCTAssertNil(last)
        XCTAssertEqual(capture.starts, 2); service.retry(); await service.waitForIdle(); XCTAssertEqual(capture.starts, 3)
        service.setScenePlaying(false); await service.waitForIdle(); XCTAssertEqual(service.status, .waitingForScene)
        XCTAssertEqual(music.subscriberCount, 0)
        service.shutdown(); await service.waitForIdle(); music.shutdown()
    }
    func testPersistedEnabledNeverPromptsAtStartupAndHasIndependentSource() async throws {
        let d = defaults(); var options = AudioResponseSettings(); options.isEnabled = true; options.mediaSource = .spotify
        d.set(try JSONEncoder().encode(options), forKey: AudioResponseService.storageKey)
        let capture = TestAudioCapture(), music = music()
        let service = AudioResponseService(music: music, defaults: d, capture: capture, publishSpectrum: { _ in }, publishMedia: { _, _ in })
        service.setScenePlaying(true); await service.waitForIdle()
        XCTAssertEqual(service.settings, options); XCTAssertEqual(capture.requests, 0); XCTAssertEqual(service.status, .permissionRequired)
        service.shutdown(); await service.waitForIdle(); music.shutdown()
    }
    func testRepeatedShutdownReleasesServiceAndSubscriptions() async {
        let music = music()
        for _ in 0..<30 {
            let capture = TestAudioCapture(); capture.permission = true
            var service: AudioResponseService? = AudioResponseService(music: music, defaults: defaults(), capture: capture,
                publishSpectrum: { _ in }, publishMedia: { _, _ in })
            weak var released = service
            service?.setScenePlaying(true); service?.setEnabled(true); await service?.waitForIdle()
            service?.shutdown(); service?.shutdown(); await service?.waitForIdle(); service = nil
            XCTAssertNil(released); XCTAssertEqual(capture.stops, 1); XCTAssertEqual(music.subscriberCount, 0)
        }
        music.shutdown()
    }
    func testCaptureConfigurationExcludesOwnAudioAndMicrophone() {
        let config = SystemAudioCapture.configuration()
        XCTAssertTrue(config.capturesAudio); XCTAssertTrue(config.excludesCurrentProcessAudio)
        XCTAssertEqual(config.sampleRate, 48_000); XCTAssertEqual(config.channelCount, 2)
        XCTAssertEqual(config.width, 2); XCTAssertEqual(config.height, 2); XCTAssertEqual(config.queueDepth, 2)
        if #available(macOS 15, *) { XCTAssertFalse(config.captureMicrophone) }
    }
    func testReturningFromSystemSettingsReconnectsWithoutRepromptAndRevocationStopsCapture() async {
        let capture = TestAudioCapture(), music = music()
        let service = AudioResponseService(music: music, defaults: defaults(), capture: capture,
            publishSpectrum: { _ in }, publishMedia: { _, _ in })
        service.setScenePlaying(true); service.setEnabled(true); await service.waitForIdle()
        XCTAssertEqual(service.status, .permissionRequired); XCTAssertEqual(capture.requests, 1)
        capture.permission = true; service.refreshAuthorization(); await service.waitForIdle()
        XCTAssertEqual(service.status, .listening); XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.requests, 1)
        capture.permission = false; service.refreshAuthorization(); await service.waitForIdle()
        XCTAssertEqual(service.status, .permissionRequired); XCTAssertEqual(capture.stops, 1); XCTAssertEqual(capture.requests, 1)
        XCTAssertEqual(music.subscriberCount, 1, "Revoked audio authorization does not revoke the independent metadata lease")
        service.shutdown(); await service.waitForIdle(); music.shutdown()
    }
    func testRealCaptureOnlyWhenExplicitlyEnabledForAcceptance() async throws {
        guard ProcessInfo.processInfo.environment["KINETIC_AUDIO_CAPTURE_LIVE"] == "1" else { throw XCTSkip("Explicit live system audio acceptance only") }
        let capture = SystemAudioCapture()
        guard capture.hasPermission() else { throw XCTSkip("No system capture authorization; tests never request it") }
        var frames = 0, peak: Float = 0
        capture.onSpectrum = { frames += 1; peak = max(peak, $0.peak) }
        try await capture.start(); try await Task.sleep(nanoseconds: 2_000_000_000); await capture.stop()
        XCTAssertGreaterThan(frames, 0); XCTAssertGreaterThan(peak, 0.05)
        print("KAUDIO_LIVE frames=\(frames) peak=\(peak)")
    }
}

final class AudioSpectrumTests: XCTestCase {
    private func tone(_ frequency: Double, count: Int = 2048) -> [Float] {
        (0..<count).map { Float(0.3 * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    }
    func testLogBandsDistinguishRealStereoFrequencies() throws {
        let analyzer = AudioSpectrumAnalyzer()
        let value = try XCTUnwrap(analyzer.consume(left: tone(1000), right: tone(8000), sampleRate: 48_000, at: 1))
        let l = try XCTUnwrap(value.left.indices.max(by: { value.left[$0] < value.left[$1] }))
        let r = try XCTUnwrap(value.right.indices.max(by: { value.right[$0] < value.right[$1] }))
        XCTAssertTrue((34...38).contains(l)); XCTAssertTrue((53...57).contains(r)); XCTAssertGreaterThan(r, l)
        XCTAssertGreaterThan(value.peak, 0.1); XCTAssertTrue((value.left + value.right).allSatisfy { $0.isFinite && (0...1).contains($0) })
    }
    func testSilenceDecayAndPacketLimits() throws {
        let analyzer = AudioSpectrumAnalyzer(), zeros = [Float](repeating: 0, count: 2048)
        XCTAssertEqual(analyzer.consume(left: zeros, right: zeros, sampleRate: 48_000, at: 0), .silence)
        XCTAssertNil(analyzer.consume(left: zeros, right: zeros, sampleRate: 48_000, at: 0.001), "Analysis is bounded to 30Hz")
        var value = try XCTUnwrap(analyzer.consume(left: tone(1000), right: tone(1000), sampleRate: 48_000, at: 0.1))
        XCTAssertGreaterThan(value.peak, 0.1)
        for i in 1...40 { value = try XCTUnwrap(analyzer.consume(left: zeros, right: zeros, sampleRate: 48_000, at: 0.1 + Double(i) * 0.04)) }
        XCTAssertEqual(value, .silence)
        XCTAssertNil(analyzer.consume(left: zeros, right: [], sampleRate: 48_000, at: 3))
        XCTAssertNil(analyzer.consume(left: zeros, right: zeros, sampleRate: .nan, at: 3))
        XCTAssertNil(analyzer.consume(left: .init(repeating: 0, count: 16385), right: .init(repeating: 0, count: 16385), sampleRate: 48_000, at: 3))
    }
    func testPCMReaderPreservesPlanarStereoAndMono() throws {
        for channels in [UInt32(1), 2] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)); buffer.frameLength = 100
            for c in 0..<Int(channels) { for i in 0..<100 { buffer.floatChannelData![c][i] = c == 0 ? 0.25 : -0.5 } }
            var desc: CMAudioFormatDescription?
            XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc), noErr)
            var sample: CMSampleBuffer?, timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: desc, sampleCount: 100, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            let s = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(s, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList), noErr)
            let result = try XCTUnwrap(AudioPCMReader.read(s)); XCTAssertEqual(result.left, .init(repeating: 0.25, count: 100))
            XCTAssertEqual(result.right, .init(repeating: channels == 1 ? 0.25 : -0.5, count: 100))
        }
    }
    func testMissingPacketsDecayToSilenceAndResumeWithFreshAudio() throws {
        let analyzer = AudioSpectrumAnalyzer()
        let sound = try XCTUnwrap(analyzer.consume(left: tone(1000), right: tone(1000), sampleRate: 48000, at: 1))
        XCTAssertGreaterThan(sound.peak, 0.1)
        XCTAssertNil(analyzer.silenceIfInputStopped(at: 1.19))
        let decayed = try XCTUnwrap(analyzer.silenceIfInputStopped(at: 1.3))
        XCTAssertLessThan(decayed.peak, sound.peak)
        var quiet = decayed
        for i in 4...20 { quiet = try XCTUnwrap(analyzer.silenceIfInputStopped(at: 1 + Double(i) / 10)) }
        XCTAssertEqual(quiet, .silence)
        let resumed = try XCTUnwrap(analyzer.consume(left: tone(1000), right: tone(1000), sampleRate: 48000, at: 4))
        XCTAssertGreaterThan(resumed.peak, 0.1)
        XCTAssertNil(analyzer.silenceIfInputStopped(at: 4.1))
    }
}
