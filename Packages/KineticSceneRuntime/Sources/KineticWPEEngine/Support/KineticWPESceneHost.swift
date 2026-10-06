import AppKit
import CoreImage
import Foundation
import Metal

public enum KineticWPESceneHostError: Error, Equatable, Sendable {
    case metalUnavailable
    case notAScene
    case unsupported(String)
    case entryMissing(String)
    /// A referenced texture / material / shader / model was found nowhere (scene, built-ins, engine assets).
    case missingAsset(String)
    /// A Workshop item listed in `project.json` `dependencies` is not available locally.
    case missingDependency(String)
    case firstFrameFailed
    case timedOut
    case disposed
}

/// Playback health read from the engine's own error sinks (no render-actor hop).
public struct KineticWPESceneHealth: Equatable, Sendable {
    /// GPU command-buffer / uniform-buffer failures since load.
    public let gpuErrorCount: Int
    public let lastGPUError: String?
    /// Custom shaders that failed to compile; the engine skips such a pass (upstream behaviour).
    public let skippedShaderCount: Int
}

/// Engine-assets root for the upstream resolver, which appends `assets/` itself. Kinetic hands over the
/// `assets` folder (or, when the user linked a folder that is itself the assets tree, that folder).
enum WPEEngineAssetsRoot {
    static func assetsFolder(forRoot root: URL) -> URL {
        let nested = root.appendingPathComponent("assets", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nested
        }
        return root
    }
}

/// Kinetic host for the complete ported renderer: effects and render graph, perspective cameras,
/// particles, puppets, text, scene sounds and SceneScript through upstream JavaScriptCore
/// (user decision, 2026-10-05). One host = one scene in one view.
///
/// Frames run on a dedicated render thread (upstream's default `.renderThread` backing), paced by a
/// display link — `CADisplayLink` on macOS 14+, a run-loop timer on macOS 13 (`WPEFrameLink`) — so the
/// app's main thread stays free. The host never creates windows, never writes caches outside the
/// engine's own defaults, starts no audio capture and starts muted.
@MainActor
public final class KineticWPESceneHost {
    public let view: NSView
    public private(set) var isLoaded = false
    public private(set) var isDisposed = false

    private let surface: WPERenderSurface
    private let renderActor: WPEDisplayRenderActor
    private var pendingRenderer: WPERendererHandoff?
    private var adopted = false
    private let gpuErrors: WPEGPUErrorSink
    private let shaderErrors: WPEShaderErrorSink

    /// - Parameters:
    ///   - sceneFolder: wallpaper folder with `project.json` and the scene entry (loose or in `scene.pkg`).
    ///   - engineAssets: the user's Wallpaper Engine `assets` folder, searched after the scene's own files.
    ///   - size: initial view size in points; the view follows its superview afterwards.
    ///   - dependencyFolder: local folder of a Workshop item the scene lists in `dependencies`
    ///     (its `project.json` / `scene.pkg` root); nil when it is not available.
    public init(sceneFolder: URL, engineAssets: URL?, size: CGSize,
                dependencyFolder: ((String) -> URL?)? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw KineticWPESceneHostError.metalUnavailable }
        let project = try WallpaperEngineProject.read(from: sceneFolder)
        guard project.type == .scene else { throw KineticWPESceneHostError.notAScene }
        let packageURL = sceneFolder.appendingPathComponent("scene.pkg", isDirectory: false)
        let provider: any WPESceneAssetProvider
        let storage: SceneAssetStorage
        if FileManager.default.fileExists(atPath: packageURL.path) {
            provider = try WPEPackageSceneAssetProvider(packageURL: packageURL)
            storage = .packageSource(fileName: "scene.pkg")
        } else {
            provider = WPEDirectorySceneAssetProvider(rootURL: sceneFolder)
            storage = .sourceDirectory
        }
        if project.scenePreset() != nil {
            // A preset is property values over another wallpaper (Module 29: properties / presets).
            throw KineticWPESceneHostError.unsupported("Wallpaper Engine preset")
        }
        // Every declared dependency must be mounted; never render around a missing one.
        let mounts = try Self.dependencyMounts(declaredIn: sceneFolder, folder: dependencyFolder)
        guard provider.exists(atRelativePath: project.entryFile) else {
            throw KineticWPESceneHostError.entryMissing(project.entryFile)
        }
        let workshopID = project.workshopID.isEmpty ? sceneFolder.lastPathComponent : project.workshopID
        let descriptor = SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: "kinetic/\(workshopID)",
            entryFile: project.entryFile,
            capabilityTier: .degraded,
            assetStorage: storage,
            dependencyWorkshopIDs: mounts.map(\.workshopID)
        )
        let frame = CGRect(origin: .zero, size: CGSize(width: max(1, size.width), height: max(1, size.height)))
        let surface = WPERenderSurface(frame: frame, device: device, targetScreen: nil, allowsHDR: false)
        let renderActor = WPEDisplayRenderActor(label: "com.kinetic.scene.render.\(workshopID)", backing: .renderThread)
        // The view stays paused; the render thread's display link drives frames (upstream session wiring).
        let pacer = WPERenderThreadFramePacer(surface: surface, renderActor: renderActor)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: descriptor,
            cacheRootURL: sceneFolder,
            assetProvider: provider,
            projectManifestRootURL: sceneFolder,
            dependencyMounts: mounts,
            engineAssetsRootURL: engineAssets,
            surfaceControl: pacer,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.backingDrawableSize,
            presentFitMode: .cover,
            device: device
        )
        surface.attach(client: WPERenderSurfaceClientShim(renderActor: renderActor, backing: .renderThread), monitorsPointer: true)
        surface.startDisplayLinkDriver(renderActor: renderActor)
        self.surface = surface
        self.renderActor = renderActor
        self.pendingRenderer = WPERendererHandoff(renderer: renderer)
        self.gpuErrors = renderer.executor.gpuErrorSink
        self.shaderErrors = renderer.executor.shaderErrorSink
        self.view = surface.mtkView
    }

    /// Workshop IDs listed in a scene folder's `project.json` `dependencies` (strings or numbers, in order).
    public nonisolated static func declaredDependencies(inSceneFolder folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = manifest["dependencies"] as? [Any] else { return [] }
        return list.map { entry in
            if let text = entry as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let number = entry as? NSNumber { return number.stringValue }
            return String(describing: entry)
        }
    }

    /// A dependency folder is usable when it holds `scene.pkg` (mounted in place) or a loose `project.json` tree.
    nonisolated static func dependencyMounts(declaredIn sceneFolder: URL, folder: ((String) -> URL?)?) throws -> [WPEAssetMount] {
        var mounts: [WPEAssetMount] = []
        for id in declaredDependencies(inSceneFolder: sceneFolder) where !mounts.contains(where: { $0.workshopID == id }) {
            guard WPEPathSafety.isSafeProjectID(id), let root = folder?(id) else {
                throw KineticWPESceneHostError.missingDependency(id)
            }
            let package = root.appendingPathComponent("scene.pkg", isDirectory: false)
            if FileManager.default.fileExists(atPath: package.path) {
                mounts.append(WPEAssetMount(workshopID: id, packageURL: package))
            } else if FileManager.default.fileExists(atPath: root.appendingPathComponent("project.json").path) {
                mounts.append(WPEAssetMount(workshopID: id, rootURL: root))
            } else {
                throw KineticWPESceneHostError.missingDependency(id)
            }
        }
        return mounts
    }

    /// Loads the scene, renders and presents the first frame, then leaves it suspended (scene clock at 0)
    /// until `play()`. Returns the first frame as an image for the caller's fallback layer.
    public func prepare(timeout: TimeInterval, muted: Bool = true) async throws -> CGImage? {
        guard !isDisposed, let handoff = pendingRenderer else { throw KineticWPESceneHostError.disposed }
        pendingRenderer = nil
        await renderActor.adopt(handoff.renderer)
        adopted = true
        await renderActor.setAudioMuted(muted)
        await renderActor.applyPerformanceProfile(.suspended)
        try Task.checkCancellation()
        do { try await renderActor.load() }
        catch WPERenderPipelineError.shaderMissing(_, _, let path) { throw KineticWPESceneHostError.missingAsset(path) }
        catch WPERenderPipelineError.includeMissing(let path, _) { throw KineticWPESceneHostError.missingAsset(path) }
        try Task.checkCancellation()
        guard !isDisposed else { throw KineticWPESceneHostError.disposed }
        // Required resources (scene entry, models, materials, shaders, a pass's primary texture) fail the load in
        // the engine itself (`SceneRenderingError.resourceFailed(.fileMissing)`). A missing *auxiliary* texture
        // slot stays unbound, as in Wallpaper Engine; nothing is replaced with substitute content.
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.5, timeout)
        var attempts = 0
        while true {
            // Offscreen until the session shows the view: present explicitly instead of waiting for the view's own loop.
            if attempts % 8 == 0 { await renderActor.renderFrame() }
            attempts += 1
            guard !isDisposed, let snapshot = await renderActor.rendererStateSnapshot() else {
                throw KineticWPESceneHostError.disposed
            }
            if snapshot.isLoaded, snapshot.completedPresentGeneration == snapshot.currentLoadGeneration { break }
            if snapshot.failedPresentGeneration == snapshot.currentLoadGeneration { throw KineticWPESceneHostError.firstFrameFailed }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw KineticWPESceneHostError.timedOut }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        isLoaded = true
        return await captureFrame()
    }

    public func play() {
        guard isLoaded, !isDisposed else { return }
        // Pace frames with the display the view is actually on (the link starts on the main screen).
        if let screen = view.window?.screen { surface.setSpanClockScreen(screen) }
        Task { [renderActor] in await renderActor.applyPerformanceProfile(.quality) }
    }

    /// Freezes the scene clock, particles, cameras and scripts; the view keeps its last frame.
    public func pause() {
        guard adopted, !isDisposed else { return }
        Task { [renderActor] in await renderActor.applyPerformanceProfile(.suspended) }
    }

    public func setMuted(_ muted: Bool) {
        guard adopted, !isDisposed else { return }
        Task { [renderActor] in await renderActor.setAudioMuted(muted) }
    }

    /// Renders and presents one frame now (used by tests and by callers whose view is not on screen yet).
    public func renderFrameNow() async {
        guard adopted, !isDisposed else { return }
        await renderActor.renderFrame()
    }

    /// A steadily growing GPU error count means frames are failing (the caller decides when to give up).
    public var health: KineticWPESceneHealth {
        let gpu = gpuErrors.summary
        return KineticWPESceneHealth(gpuErrorCount: gpu.count, lastGPUError: gpu.last,
                                     skippedShaderCount: shaderErrors.summary.count)
    }

    /// Test hook: places the cursor at `location` (screen points) with the view at `viewFrameInScreen`, as the
    /// pointer publisher would from the global mouse monitor.
    @_spi(KineticTesting) public func simulatePointerForTesting(at location: CGPoint, viewFrameInScreen: CGRect) {
        surface.mailbox.publishGeometry(.init(viewFrameInScreen: viewFrameInScreen))
        surface.mailbox.publishMouseLocation(location, timestampNanos: DispatchTime.now().uptimeNanoseconds)
    }

    /// Test hook: records one synthetic GPU command-buffer failure.
    @_spi(KineticTesting) public func recordGPUFailureForTesting(_ message: String) {
        gpuErrors.record(message)
    }

    /// The last presented frame (SDR, top-left origin).
    public func captureFrame() async -> CGImage? {
        guard adopted, !isDisposed, let capture = await renderActor.captureDisplayedFrame() else { return nil }
        return Self.image(from: capture.texture, colorSpace: capture.colorSpace)
    }

    public func dispose() async {
        guard !isDisposed else { return }
        isDisposed = true
        isLoaded = false
        surface.detach()
        view.removeFromSuperview()
        if let pending = pendingRenderer {
            pendingRenderer = nil
            pending.renderer.cleanup()
        }
        if adopted {
            await renderActor.teardownRenderer()
        }
        _ = await renderActor.shutdown()
    }

    nonisolated static func image(from texture: MTLTexture, colorSpace: CGColorSpace?) -> CGImage? {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // Sampling an `_srgb` texture already decodes to linear light; tag the samples as linear so Core Image
        // does not decode them a second time (that made the fallback frame darker than the screen).
        let source: CGColorSpace
        switch texture.pixelFormat {
        case .rgba8Unorm_srgb, .bgra8Unorm_srgb: source = CGColorSpaceCreateLinearized(space) ?? space
        default: source = space
        }
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: source]) else { return nil }
        let context = CIContext(mtlDevice: texture.device, options: [.outputColorSpace: space])
        // Metal textures are top-left origin; Core Image is bottom-left.
        return context.createCGImage(image.oriented(.downMirrored), from: image.extent, format: .RGBA8, colorSpace: space)
    }
}
