import AppKit
import Combine
import SwiftUI

@MainActor final class MusicPresentation: ObservableObject {
    @Published var options = MusicOverlayOptions()
    @Published var snapshot = MusicSnapshot()
    @Published var lyrics = LyricsSnapshot()
    @Published var date = Date()
    @Published var artwork: NSImage?
    private var artworkData: Data?
    func receive(_ value: MusicSnapshot, lyrics: LyricsSnapshot) {
        snapshot = value; self.lyrics = lyrics; date = Date()
        if artworkData != value.track?.artwork {
            artworkData = value.track?.artwork; artwork = artworkData.flatMap(NSImage.init(data:))
        }
    }
}

/// No interaction on the desktop: transport actions are explicit buttons in the music editor.
struct NowPlayingFace: View {
    let options: MusicOverlayOptions
    let snapshot: MusicSnapshot
    let artwork: NSImage?
    let date: Date
    private var vinyl: Bool { options.layout == .vinyl }
    var body: some View {
        HStack(spacing: 14) {
            cover.frame(width: vinyl ? 122 : 82, height: vinyl ? 122 : 82)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: snapshot.isPlaying ? "waveform" : "pause.fill")
                    Text(options.source.title)
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(snapshot.track?.title ?? NSLocalizedString("music.noTrack", comment: ""))
                    .font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text(snapshot.track?.artist ?? snapshot.availability.message)
                    .font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary)
                if let track = snapshot.track, track.duration > 0 {
                    ProgressView(value: snapshot.elapsed(at: date), total: track.duration).tint(.primary)
                    HStack {
                        Text(Self.time(snapshot.elapsed(at: date))); Spacer(); Text(Self.time(track.duration))
                    }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial)
            if options.layout == .aurora {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [.cyan.opacity(0.22), .purple.opacity(0.18), .pink.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 0.7))
        .opacity(options.opacity)
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var cover: some View {
        if vinyl {
            ZStack {
                Circle().fill(Color(white: 0.09))
                ForEach(0..<8, id: \.self) { i in Circle().stroke(Color.white.opacity(0.1), lineWidth: 1).padding(CGFloat(i * 4 + 3)) }
                artworkView.clipShape(Circle()).padding(30)
                Circle().fill(.black).frame(width: 5, height: 5)
            }
        } else { artworkView.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
    }
    private var artworkView: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let artwork { Image(nsImage: artwork).resizable().scaledToFit() }
            else { Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.secondary) }
        }
    }
    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, min(86_400, seconds))) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct LyricsFace: View {
    let mode: LyricsMode
    let snapshot: LyricsSnapshot
    let seconds: Double
    var body: some View {
        VStack(spacing: 10) {
            if let value = snapshot.value, snapshot.status == .ready {
                if mode == .synced, !value.lines.isEmpty {
                    let index = value.currentIndex(at: seconds) ?? -1
                    ForEach(max(0, index - 1)..<min(value.lines.count, index + 2), id: \.self) { i in
                        Text(value.lines[i].text.isEmpty ? "♪" : value.lines[i].text)
                            .font(.system(size: i == index ? 20 : 14, weight: i == index ? .semibold : .regular))
                            .foregroundStyle(i == index ? .primary : .secondary).lineLimit(2)
                    }
                    if index < 0 { Text("lyrics.waiting").foregroundStyle(.secondary) }
                } else {
                    Text(value.plain).font(.system(size: 16)).lineLimit(6)
                    if mode == .synced { Text("lyrics.plainFallback").font(.caption2).foregroundStyle(.secondary) }
                }
            } else {
                Text(LocalizedStringKey("lyrics.status." + snapshot.status.rawValue)).font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.7))
        .accessibilityElement(children: .combine)
    }
}

struct MusicCanvas: View {
    @ObservedObject var state: MusicPresentation
    var body: some View {
        GeometryReader { geometry in
            if let frame = state.options.frame(in: geometry.size) {
                let base = state.options.layout == .vinyl ? CGSize(width: 340, height: 160) : CGSize(width: 340, height: 130)
                NowPlayingFace(options: state.options, snapshot: state.snapshot, artwork: state.artwork, date: state.date)
                    .frame(width: base.width, height: base.height).scaleEffect(frame.width / base.width)
                    .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
            }
            if state.options.lyrics != .off, let frame = state.options.frame(in: geometry.size, isLyrics: true) {
                LyricsFace(mode: state.options.lyrics, snapshot: state.lyrics, seconds: state.snapshot.elapsed(at: state.date))
                    .frame(width: 500, height: 160).scaleEffect(frame.width / 500)
                    .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
            }
        }
    }
}

@MainActor final class MusicOverlay: DesktopOverlay {
    let state = MusicPresentation()
    private let service: MusicService
    private let host: NSHostingView<MusicCanvas>
    private var lease: MusicSubscription?
    private var observer: AnyCancellable?
    private(set) var timer: Timer?
    private(set) var isPlaying = false
    private(set) var isDisposed = false
    private var context: OverlayContext?
    var displayView: NSView { host }
    var onFailure: (@MainActor (Error) -> Void)?
    init(service: MusicService) {
        self.service = service; host = NSHostingView(rootView: MusicCanvas(state: state))
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
    }
    func prepare(configuration: OverlayConfiguration, context: OverlayContext) async throws { try update(configuration: configuration, context: context) }
    func update(configuration: OverlayConfiguration, context: OverlayContext) throws {
        guard !isDisposed else { throw OverlayError.invalidConfiguration }
        let options = try MusicOverlayOptions(configuration: configuration)
        state.options = options; self.context = context; host.frame = context.frame
        if observer == nil {
            observer = service.$snapshots.combineLatest(service.$lyrics).sink { [weak self] snapshots, lyrics in
                guard let self, self.isPlaying, self.context?.isPaused == false else { return }
                self.state.receive(snapshots[self.state.options.source] ?? .init(), lyrics: lyrics[self.state.options.source] ?? .init())
                self.synchronizeTimer()
            }
        }
        if lease == nil { lease = service.subscribe(source: options.source, lyrics: options.lyrics != .off) }
        if context.isPaused { pause() } else { reconcile() }
    }
    func play() { guard !isDisposed, context?.isPaused == false else { return }; isPlaying = true; reconcile() }
    func pause() { isPlaying = false; timer?.invalidate(); timer = nil; lease?.update(visible: false, source: state.options.source, lyrics: state.options.lyrics != .off) }
    private func reconcile() {
        guard isPlaying else { return }
        lease?.update(visible: true, source: state.options.source, lyrics: state.options.lyrics != .off)
        state.receive(service.snapshots[state.options.source] ?? .init(), lyrics: service.lyrics[state.options.source] ?? .init())
        synchronizeTimer()
    }
    private func synchronizeTimer() {
        guard isPlaying, !isDisposed, state.snapshot.availability == .live, state.snapshot.isPlaying else { timer?.invalidate(); timer = nil; return }
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.date = Date() }
            }; timer.tolerance = 0.2; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    func dispose() {
        guard !isDisposed else { return }; pause(); isDisposed = true; lease?.cancel(); lease = nil; observer = nil
        state.artwork = nil; host.removeFromSuperview()
    }
    deinit { timer?.invalidate() }
}
