import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

@MainActor protocol SystemAudioCapturing: AnyObject {
    var onSpectrum: (@MainActor (StereoAudioSpectrum) -> Void)? { get set }
    var onFailure: (@MainActor () -> Void)? { get set }
    func hasPermission() -> Bool
    func requestPermission() -> Bool
    func start() async throws
    func stop() async
}

/// Audio-only output. ScreenCaptureKit's filter still requires a display on macOS 13.
@MainActor final class SystemAudioCapture: SystemAudioCapturing {
    var onSpectrum: (@MainActor (StereoAudioSpectrum) -> Void)?
    var onFailure: (@MainActor () -> Void)?
    private var stream: SCStream?
    private var output: SystemAudioOutput?
    private var generation: UInt64 = 0
    func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if !granted { Self.openPermissionSettings() }
        return granted
    }
    /// Called only after an explicit user action; macOS may decline to show a second consent prompt.
    private static func openPermissionSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !NSWorkspace.shared.open(pane), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(app)
        }
    }
    static func configuration() -> SCStreamConfiguration {
        let value = SCStreamConfiguration()
        value.capturesAudio = true; value.excludesCurrentProcessAudio = true
        value.sampleRate = 48_000; value.channelCount = 2
        value.width = 2; value.height = 2; value.queueDepth = 2
        value.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        value.showsCursor = false
        if #available(macOS 15, *) { value.captureMicrophone = false }
        return value
    }
    func start() async throws {
        guard stream == nil, hasPermission() else { throw AudioCaptureError.unavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw AudioCaptureError.unavailable }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        generation &+= 1
        let token = generation
        let output = SystemAudioOutput(onSpectrum: { [weak self] value in
            guard let self, self.generation == token else { return }
            self.onSpectrum?(value)
        }, onFailure: { [weak self] in
            guard let self, self.generation == token else { return }
            self.onFailure?()
        })
        let stream = SCStream(filter: filter, configuration: Self.configuration(), delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        self.output = output; self.stream = stream
        do { try await stream.startCapture(); try Task.checkCancellation() }
        catch { await stop(); throw error }
    }
    func stop() async {
        generation &+= 1
        let stream = stream, output = output
        self.stream = nil; self.output = nil
        output?.invalidate()
        if let stream {
            try? await stream.stopCapture()
            if let output { try? stream.removeStreamOutput(output, type: .audio) }
        }
    }
}
enum AudioCaptureError: Error { case unavailable }

/// One pending main-actor delivery at most, even while the UI is busy.
private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.kinetic.audio-analysis", qos: .utility)
    private let analyzer = AudioSpectrumAnalyzer()
    private let watchdog: DispatchSourceTimer
    private let lock = NSLock()
    private var active = true, scheduled = false
    private var pending: StereoAudioSpectrum?
    private let onSpectrum: @MainActor (StereoAudioSpectrum) -> Void
    private let onFailure: @MainActor () -> Void
    init(onSpectrum: @escaping @MainActor (StereoAudioSpectrum) -> Void, onFailure: @escaping @MainActor () -> Void) {
        watchdog = DispatchSource.makeTimerSource(queue: queue)
        self.onSpectrum = onSpectrum; self.onFailure = onFailure
        super.init()
        watchdog.setEventHandler { [weak self] in self?.pollSilence() }
        watchdog.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        watchdog.resume()
    }
    deinit { watchdog.cancel() }
    func invalidate() { watchdog.cancel(); lock.lock(); active = false; pending = nil; lock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock(); let active = active; lock.unlock()
        guard active, type == .audio, let samples = AudioPCMReader.read(sampleBuffer),
              let value = analyzer.consume(left: samples.left, right: samples.right, sampleRate: samples.rate,
                at: ProcessInfo.processInfo.systemUptime) else { return }
        enqueue(value)
    }
    private func pollSilence() {
        lock.lock(); let active = active; lock.unlock()
        guard active, let value = analyzer.silenceIfInputStopped(at: ProcessInfo.processInfo.systemUptime) else { return }
        enqueue(value)
    }
    private func enqueue(_ value: StereoAudioSpectrum) {
        lock.lock(); pending = value
        let deliver = !scheduled && self.active; if deliver { scheduled = true }; lock.unlock()
        guard deliver else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let value = takePending() { onSpectrum(value) }
        }
    }
    private func takePending() -> StereoAudioSpectrum? {
        lock.lock(); defer { lock.unlock() }
        let value = active ? pending : nil
        pending = nil; scheduled = false
        return value
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        watchdog.cancel()
        lock.lock(); let notify = active; active = false; pending = nil; lock.unlock()
        if notify { Task { @MainActor [weak self] in self?.onFailure() } }
    }
}

enum AudioPCMReader {
    struct Samples { let left: [Float]; let right: [Float]; let rate: Double }
    static func read(_ sample: CMSampleBuffer) -> Samples? {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (1...2).contains(asbd.mChannelsPerFrame) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard (1...16_384).contains(frames) else { return nil }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard needed >= MemoryLayout<AudioBufferList>.size, needed <= 256 else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let pointer = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: pointer, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        guard (1...2).contains(buffers.count) else { return nil }
        var channels: [[Float]] = []
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            guard (1...2).contains(count), let data = buffer.mData,
                  Int(buffer.mDataByteSize) >= frames * count * MemoryLayout<Float>.size else { return nil }
            let values = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<count { channels.append((0..<frames).map { values[$0 * count + channel] }) }
        }
        guard channels.count == Int(asbd.mChannelsPerFrame), let left = channels.first else { return nil }
        return .init(left: left, right: channels.count == 2 ? channels[1] : left, rate: asbd.mSampleRate)
    }
}
