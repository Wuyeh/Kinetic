import AppKit
import Combine
import Foundation

/// App-owned capture, independent of music metadata, wallpaper sound and renderer lifecycle.
@MainActor final class AudioResponseService: ObservableObject {
    static let storageKey = "Kinetic.AudioResponse.v1"
    @Published private(set) var settings: AudioResponseSettings
    @Published private(set) var status = AudioResponseStatus.off
    @Published private(set) var level: Float = 0
    private let defaults: UserDefaults
    private let capture: any SystemAudioCapturing
    private let music: MusicService
    private let publishSpectrum: @MainActor (StereoAudioSpectrum?) -> Void
    private let publishMedia: @MainActor (MusicSource, MusicSnapshot?) -> Void
    private var musicLease: MusicSubscription?
    private var observers = Set<AnyCancellable>()
    private var operation: Task<Void, Never>?
    private var hasScene = false, suspended = false, capturing = false, failed = false, disposed = false
    private var lastLevelUpdate = 0.0
    private(set) var analyzedFrames: UInt64 = 0
    init(music: MusicService, defaults: UserDefaults = .standard, capture: (any SystemAudioCapturing)? = nil,
         publishSpectrum: @escaping @MainActor (StereoAudioSpectrum?) -> Void,
         publishMedia: @escaping @MainActor (MusicSource, MusicSnapshot?) -> Void) {
        self.music = music; self.defaults = defaults; self.capture = capture ?? SystemAudioCapture()
        self.publishSpectrum = publishSpectrum; self.publishMedia = publishMedia
        settings = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(AudioResponseSettings.self, from: $0) } ?? .init()
        self.capture.onSpectrum = { [weak self] value in
            guard let self, self.wantsCapture, self.capturing, !self.disposed else { return }
            self.analyzedFrames &+= 1; self.publishSpectrum(value)
            let time = ProcessInfo.processInfo.systemUptime
            if time - self.lastLevelUpdate >= 0.2 { self.lastLevelUpdate = time; self.level = value.peak }
        }
        self.capture.onFailure = { [weak self] in
            guard let self, !self.disposed else { return }
            self.failed = true; self.publishSpectrum(nil); self.level = 0; self.reconcile()
        }
        music.$snapshots.sink { [weak self] snapshots in
            guard let self, self.wantsCapture else { return }
            self.publishMedia(self.settings.mediaSource, snapshots[self.settings.mediaSource])
        }.store(in: &observers)
    }
    func start(runtime: WallpaperRuntimeManager, library: WallpaperLibrary, monitor: SmartPauseMonitor?) {
        runtime.$summary.sink { [weak self, weak library] summary in
            let scene = summary.displays.contains { display in
                display.runtime.playbackState == .playing && library?.wallpapers.first(where: { $0.id == display.runtime.activeWallpaperID })?.type == .scene
            }
            self?.setScenePlaying(scene)
        }.store(in: &observers)
        monitor?.$conditions.removeDuplicates().sink { [weak self] in self?.updateConditions($0) }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshAuthorization() }.store(in: &observers)
        reconcile()
    }
    /// Returning from System Settings checks authorization without requesting another prompt.
    func refreshAuthorization() { guard !disposed else { return }; reconcile() }
    func setScenePlaying(_ playing: Bool) {
        if hasScene != playing { hasScene = playing; failed = false }; reconcile()
    }
    func updateConditions(_ value: SmartPauseConditions) {
        suspended = value.screenLocked || value.systemAsleep || value.displayAsleep || value.criticalMemory || value.criticalThermal
        reconcile()
    }
    func setEnabled(_ enabled: Bool) {
        guard !disposed else { return }
        settings.isEnabled = enabled; persist(); failed = false
        if enabled && !capture.hasPermission() { _ = capture.requestPermission() }
        reconcile()
    }
    func setMediaSource(_ source: MusicSource) {
        guard settings.mediaSource != source, !disposed else { return }
        settings.mediaSource = source; persist(); reconcile()
    }
    func retry() {
        guard settings.isEnabled, !disposed else { return }
        failed = false
        if !capture.hasPermission() { _ = capture.requestPermission() }
        reconcile()
    }
    private func persist() { if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.storageKey) } }
    private var wantsCapture: Bool { settings.isEnabled && hasScene && !suspended && !disposed }
    private func reconcile() {
        if wantsCapture {
            if musicLease == nil { musicLease = music.subscribe(source: settings.mediaSource, lyrics: false, visible: true) }
            else { musicLease?.update(visible: true, source: settings.mediaSource, lyrics: false) }
            publishMedia(settings.mediaSource, music.snapshots[settings.mediaSource])
        } else {
            musicLease?.cancel(); musicLease = nil
            publishMedia(settings.mediaSource, nil); publishSpectrum(nil); level = 0
        }
        guard operation == nil else { return }
        operation = Task { [weak self] in
            guard let self else { return }
            defer { operation = nil }
            while !Task.isCancelled {
                if !wantsCapture || failed {
                    if capturing { capturing = false; await capture.stop(); continue }
                    status = disposed || !settings.isEnabled ? .off : suspended ? .suspended : failed ? .failed : .waitingForScene
                    return
                }
                guard capture.hasPermission() else {
                    if capturing { capturing = false; await capture.stop() }
                    publishSpectrum(nil); level = 0; status = .permissionRequired; return
                }
                if capturing { status = .listening; return }
                status = .starting
                do {
                    try await capture.start(); capturing = true
                } catch {
                    failed = true; publishSpectrum(nil); level = 0
                    // start() owns cleanup for partial starts; never retry in a tight loop.
                }
            }
        }
    }
    func shutdown() {
        guard !disposed else { return }; disposed = true; observers.removeAll(); reconcile()
    }
    func waitForIdle() async { await operation?.value }
}
