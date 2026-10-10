import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import WebKit

/// One macOS desktop picture: the file plus the options NSWorkspace stores with it.
struct SystemDesktopPicture: Codable, Equatable, Sendable {
    var url: URL
    var scaling: UInt?
    var allowClipping: Bool?
    var fillColor: Data?

    init(url: URL, scaling: UInt? = nil, allowClipping: Bool? = nil, fillColor: Data? = nil) {
        self.url = url; self.scaling = scaling; self.allowClipping = allowClipping; self.fillColor = fillColor
    }

    init(url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        self.url = url
        scaling = (options[.imageScaling] as? NSNumber)?.uintValue
        allowClipping = (options[.allowClipping] as? NSNumber)?.boolValue
        fillColor = (options[.fillColor] as? NSColor).flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
    }

    var options: [NSWorkspace.DesktopImageOptionKey: Any] {
        var value: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling { value[.imageScaling] = NSNumber(value: scaling) }
        if let allowClipping { value[.allowClipping] = NSNumber(value: allowClipping) }
        if let fillColor, let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: fillColor) {
            value[.fillColor] = color
        }
        return value
    }
}

/// The system calls, replaceable in tests so they never touch the real desktop picture.
@MainActor
protocol SystemDesktopPictures: AnyObject {
    func current(on display: DisplayID) -> SystemDesktopPicture?
    func set(_ picture: SystemDesktopPicture, on display: DisplayID) throws
}

@MainActor
final class WorkspaceDesktopPictures: SystemDesktopPictures {
    private func screen(for display: DisplayID) -> NSScreen? {
        guard let descriptor = DisplayRegistry.systemDisplays().first(where: { $0.id == display }) else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == descriptor.desktop.id
        }
    }
    func current(on display: DisplayID) -> SystemDesktopPicture? {
        guard let screen = screen(for: display), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return SystemDesktopPicture(url: url, options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
    }
    func set(_ picture: SystemDesktopPicture, on display: DisplayID) throws {
        guard let screen = screen(for: display) else { throw CocoaError(.fileNoSuchFile) }
        try NSWorkspace.shared.setDesktopImageURL(picture.url, for: screen, options: picture.options)
    }
}

enum SystemWallpaperFraming {
    /// 自定义 display region in image pixels (top-left origin): zoom 1 is the cover rect, centred on the frame's centre.
    static func customCrop(imageSize: CGSize, displayAspect: CGFloat, frame: CustomDisplayFrame) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, displayAspect.isFinite, displayAspect > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        var base = imageSize.width / imageSize.height > displayAspect
            ? CGSize(width: imageSize.height * displayAspect, height: imageSize.height)
            : CGSize(width: imageSize.width, height: imageSize.width / displayAspect)
        let zoom = CGFloat(min(max(frame.zoom, 1), CustomDisplayFrame.maximumZoom))
        base = CGSize(width: base.width / zoom, height: base.height / zoom)
        let x = min(max(CGFloat(frame.centerX) * imageSize.width - base.width / 2, 0), imageSize.width - base.width)
        let y = min(max(CGFloat(frame.centerY) * imageSize.height - base.height / 2, 0), imageSize.height - base.height)
        return CGRect(x: x, y: y, width: base.width, height: base.height).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// How macOS should place a still taken from the video file, matching the display's 显示方式.
    static func options(for fit: VideoPlaybackOptions.DisplayFit) -> (scaling: NSImageScaling, clips: Bool) {
        switch fit {
        case .fill, .custom: return (.scaleProportionallyUpOrDown, true)
        case .fit: return (.scaleProportionallyUpOrDown, false)
        case .stretch: return (.scaleAxesIndependently, false)
        }
    }
}

/// Module 53：把每台显示器的 macOS 系统壁纸换成 Kinetic 当前壁纸的静止画面（设置 › 播放「同步为系统壁纸」，默认关）。
///
/// 第一次替换某台显示器前记住它原来的系统壁纸；关闭时换回去（当时没连接的显示器在重新连接时换回）。
/// 画面取自正在显示的渲染：场景与网页是桌面上的这一帧，视频是文件里当前时间的画面并按显示方式摆放。
/// 只在这块屏幕换了壁纸或应用了参数之后更新一次；停止、没有壁纸时不改动。
@MainActor
final class SystemWallpaperProvider: ObservableObject {
    struct Provided: Codable, Equatable, Sendable {
        var wallpaperID: Wallpaper.ID
        var file: String
    }
    private struct Document: Codable {
        var version = 1
        var originals: [String: SystemDesktopPicture] = [:]
        var provided: [String: Provided] = [:]
    }
    struct Still {
        var image: CGImage
        var scaling: NSImageScaling = .scaleProportionallyUpOrDown
        var clips = true
    }
    typealias Capture = @MainActor (Wallpaper, DisplayID) async -> Still?

    nonisolated static let settleDelay: TimeInterval = 1.5

    @Published private(set) var lastError: String?
    let folder: URL
    private let fileURL: URL
    private let runtime: WallpaperRuntimeManager
    private let library: WallpaperLibrary
    private let pictures: SystemDesktopPictures
    private let capture: Capture
    private let settleDelay: TimeInterval
    private var document = Document()
    private var enabled: Bool
    private var forced = Set<DisplayID>()
    private var inFlight = Set<DisplayID>()
    private var pending: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(storage: LibraryStorageLocation, settings: SettingsStore, runtime: WallpaperRuntimeManager, library: WallpaperLibrary,
         editor: DisplayWallpaperEditor?, pictures: SystemDesktopPictures, capture: @escaping Capture,
         settleDelay: TimeInterval = SystemWallpaperProvider.settleDelay) {
        self.runtime = runtime; self.library = library; self.pictures = pictures; self.capture = capture
        self.settleDelay = settleDelay
        folder = storage.rootURL.appendingPathComponent("SystemWallpapers", isDirectory: true)
        fileURL = storage.rootURL.appendingPathComponent("system-wallpaper.json")
        enabled = settings.state.systemWallpaperSyncEnabled
        load()
        settings.$state.map(\.systemWallpaperSyncEnabled).removeDuplicates().dropFirst()
            .sink { [weak self] in self?.setEnabled($0) }.store(in: &subscriptions)
        runtime.$summary.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &subscriptions)
        // Parameters applied on the display page (显示方式, scene values …) change the picture without a new wallpaper.
        editor?.$applying.scan((Set<DisplayID>(), Set<DisplayID>())) { ($0.1, $1) }.sink { [weak self] previous, current in
            let finished = previous.subtracting(current)
            guard let self, !finished.isEmpty else { return }
            self.forced.formUnion(finished); self.scheduleUpdate()
        }.store(in: &subscriptions)
    }

    var isEnabled: Bool { enabled }
    func providedWallpaper(on display: DisplayID) -> Wallpaper.ID? { document.provided[display.rawValue]?.wallpaperID }
    func savedOriginal(on display: DisplayID) -> SystemDesktopPicture? { document.originals[display.rawValue] }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { forced.formUnion(runtime.displayIDs); scheduleUpdate() } else { pending?.cancel(); restoreConnected() }
    }

    /// Waits for the crossfade and first frames, then updates whatever changed (tests call `updateNow`).
    private func scheduleUpdate() {
        guard enabled || !document.originals.isEmpty else { return }
        pending?.cancel()
        let delay = settleDelay
        pending = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.updateNow()
        }
    }

    func updateNow() async {
        guard enabled else { restoreConnected(); return }
        for display in runtime.displayIDs {
            guard let state = runtime.state(of: display), state.playbackState != .stopped,
                  let wallpaper = runtime.activeWallpaper(on: display) else { continue }
            guard !inFlight.contains(display) else { continue }
            let force = forced.remove(display) != nil
            guard force || providedWallpaper(on: display) != wallpaper.id else { continue }
            inFlight.insert(display)
            await provide(wallpaper, on: display)
            inFlight.remove(display)
        }
    }

    private func provide(_ wallpaper: Wallpaper, on display: DisplayID) async {
        guard let still = await capture(wallpaper, display), enabled,
              runtime.activeWallpaper(on: display)?.id == wallpaper.id else { return }
        do {
            if document.originals[display.rawValue] == nil, let original = pictures.current(on: display),
               !isOurs(original.url) {
                document.originals[display.rawValue] = original
                try persist()
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = Self.fileStem(display) + "-" + UUID().uuidString + ".png"
            let url = folder.appendingPathComponent(name)
            try Self.writePNG(still.image, to: url)
            try pictures.set(SystemDesktopPicture(url: url, scaling: still.scaling.rawValue, allowClipping: still.clips,
                                                  fillColor: try? NSKeyedArchiver.archivedData(withRootObject: NSColor.black,
                                                                                             requiringSecureCoding: true)),
                             on: display)
            let previous = document.provided[display.rawValue]?.file
            document.provided[display.rawValue] = Provided(wallpaperID: wallpaper.id, file: name)
            try persist()
            if let previous, previous != name { try? FileManager.default.removeItem(at: folder.appendingPathComponent(previous)) }
            lastError = nil
        } catch {
            lastError = "无法同步系统壁纸：" + error.localizedDescription
        }
    }

    /// Puts back the pictures Kinetic replaced on the displays connected now; others wait until they reconnect.
    private func restoreConnected() {
        var changed = false
        for display in runtime.displayIDs {
            let key = display.rawValue
            guard let original = document.originals[key] else { continue }
            do {
                try pictures.set(original, on: display)
                document.originals[key] = nil
                if let provided = document.provided.removeValue(forKey: key) {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(provided.file))
                }
                changed = true
            } catch {
                lastError = "无法换回原来的系统壁纸：" + error.localizedDescription
            }
        }
        if changed { try? persist(); lastError = lastError?.hasPrefix("无法换回") == true ? lastError : nil }
    }

    private func isOurs(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    private static func fileStem(_ display: DisplayID) -> String {
        String(display.rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(48))
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func persist() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let value = try? JSONDecoder().decode(Document.self, from: data),
              value.version == 1 else { return }
        document = value
    }

    func shutdown() { pending?.cancel(); subscriptions.removeAll() }
}

extension SystemWallpaperProvider {
    /// The frame on screen now: the scene's last rendered frame, a snapshot of the web page, or the video file
    /// at the current time placed by the display's 显示方式. Falls back to the wallpaper's poster.
    static func liveCapture(runtime: WallpaperRuntimeManager, editor: DisplayWallpaperEditor?) -> Capture {
        { [weak runtime, weak editor] wallpaper, display in
            guard let runtime else { return nil }
            var scene: SceneRenderer?, web: WKWebView?, videoTime: CMTime?
            _ = runtime.configureActive(wallpaper, on: display) { renderer, _ in
                if let value = renderer as? SceneRenderer { scene = value }
                else if let value = renderer as? WebRenderer { web = value.contentView.webView }
                else if let value = renderer as? VideoRenderer { videoTime = value.currentTime }
                return false
            }
            if let scene, let image = await scene.scene.capturePreviewFrame() { return Still(image: image) }
            if let web {
                let configuration = WKSnapshotConfiguration()
                configuration.afterScreenUpdates = false
                if let image = try? await web.takeSnapshot(configuration: configuration),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return Still(image: cgImage) }
            }
            if let videoTime {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: wallpaper.resourceURL))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
                generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
                if let image = try? await generator.image(at: videoTime).image {
                    let options = editor?.configuration(for: wallpaper, on: display).video ?? VideoPlaybackOptions()
                    if options.displayFit == .custom, let frame = options.customFrame,
                       let size = runtime.summary.displays.first(where: { $0.id == display })?.frame?.size, size.height > 0 {
                        let rect = SystemWallpaperFraming.customCrop(imageSize: CGSize(width: image.width, height: image.height),
                                                                    displayAspect: size.width / size.height, frame: frame)
                        if let cropped = image.cropping(to: rect) { return Still(image: cropped) }
                    }
                    let placement = SystemWallpaperFraming.options(for: options.displayFit)
                    return Still(image: image, scaling: placement.scaling, clips: placement.clips)
                }
            }
            if let url = wallpaper.thumbnailURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return Still(image: image) }
            return nil
        }
    }
}
