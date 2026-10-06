import AppKit
import Foundation
import KineticWPEEngine
import MetalKit

/// The GPU completes before the MainActor reads this owned shared texture.
/// No other frame writes it until the MainActor selects the alternate target.
private struct SceneCompletedFrame: @unchecked Sendable { let texture: MTLTexture }

/// A single scene instance. No library, display identity, settings, or application state is owned here.
@MainActor
public final class KineticSceneRuntime: NSObject, MTKViewDelegate {
    public let displayView: NSView
    public var onFailure: (@MainActor (Error) -> Void)?
    public private(set) var isPrepared = false
    public private(set) var isPlaying = false
    public private(set) var isDisposed = false
    public private(set) var isMuted = true
    public private(set) var preparedFrame: CGImage?
    public var sceneTime: TimeInterval { elapsed + (startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0) }
    public var residentTextureBytes: Int { extendedEngine?.residentBytes ?? engine?.graph.residentBytes ?? 0 }
    public private(set) var usesExtendedRenderGraph = false
    /// Module 28：完整移植引擎（粒子 / Puppet / 文字 / 声音 / 相机 / SceneScript 经上游 JavaScriptCore，用户 2026-10-05 决定）。
    public private(set) var usesFullEngine = false

    private let root: URL
    /// The user's Wallpaper Engine `assets` folder, searched after the scene's own files. Optional.
    private let engineAssets: URL?
    private let dependencyFolder: ((String) -> URL?)?
    private let limits: SceneLimits
    private let fallback = NSView()
    private let metalView = MTKView()
    private var engine: SceneMetalEngine?
    private var extendedEngine: SceneExtendedEngine?
    private var extendedQueue: MTLCommandQueue?
    private var extendedFrame: Task<Void, Never>?
    private var fullHost: KineticWPESceneHost?
    var fullHostForTesting: KineticWPESceneHost? { fullHost }
    private var fullHealthMonitor: Task<Void, Never>?
    /// Complete-engine playback check interval; tests shorten it.
    var fullHealthInterval: UInt64 = 1_000_000_000
    /// GPU failures within one interval that end playback (isolated, sporadic errors are tolerated).
    static let fullGPUFailureBurst = 3
    private var preparation: Task<Void, Never>?
    private var cancelPreparation: (() -> Void)?
    private var elapsed: TimeInterval = 0
    private var startedAt: TimeInterval?
    private var generation: UInt64 = 0
    private var frameInFlight = false
    private var needsPausedRedraw = false
    private var failed = false
    private var failure: Error?
    private(set) var scripts: SceneScriptExecutor?
    private var scriptFrame: Task<Void, Never>?
    private var scriptEpoch: UInt64 = 0
    private var lastScriptTime: TimeInterval = 0
    private var audioSpectrum: SceneAudioSpectrum = .silence
    private var frameTargets: [MTLTexture] = []
    private var lastCompletedFrame: MTLTexture?

    public func setAudioSpectrum(_ spectrum: SceneAudioSpectrum) throws {
        guard !isDisposed else { throw SceneRuntimeError.disposed }
        if let failure { throw failure }
        audioSpectrum = spectrum
        // The complete engine reads one process-wide system spectrum (as Wallpaper Engine does).
        if usesFullEngine { KineticWPEAudioInput.publish(left: spectrum.left, right: spectrum.right) }
    }

    /// Workshop items a scene folder lists in `project.json` `dependencies` (asset packs by other authors).
    public nonisolated static func workshopDependencies(of sceneFolder: URL) -> [String] {
        KineticWPESceneHost.declaredDependencies(inSceneFolder: sceneFolder)
    }

    /// `SceneRuntimeError.missingAsset` detail for a Workshop dependency that is not on this Mac.
    public nonisolated static func missingDependencyDetail(_ id: String) -> String { "创意工坊依赖项 \(id)" }

    /// The Workshop ID when a `missingAsset` detail names a missing dependency; nil for ordinary paths.
    public nonisolated static func missingDependencyID(inDetail detail: String) -> String? {
        let prefix = missingDependencyDetail("")
        guard detail.hasPrefix(prefix) else { return nil }
        let id = String(detail.dropFirst(prefix.count))
        return !id.isEmpty && id.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) ? id : nil
    }

    /// - Parameter dependencyFolder: local folder of a Workshop item listed in the scene's `project.json`
    ///   `dependencies` (complete-engine tier only); nil when it is not on this Mac.
    public init(root: URL, engineAssets: URL? = nil, limits: SceneLimits = .init(),
                dependencyFolder: ((String) -> URL?)? = nil) {
        self.root = root; self.engineAssets = engineAssets; self.limits = limits
        self.dependencyFolder = dependencyFolder
        displayView = SceneSurfaceView()
        super.init()
        displayView.wantsLayer = true
        displayView.layer?.masksToBounds = true
        fallback.wantsLayer = true
        fallback.layer?.contentsGravity = .resizeAspectFill
        fallback.layer?.masksToBounds = true
        fallback.translatesAutoresizingMaskIntoConstraints = false
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.isPaused = true; metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 30; metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false
        metalView.alphaValue = 0
        displayView.addSubview(fallback); displayView.addSubview(metalView)
        for child in [fallback, metalView] {
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: displayView.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: displayView.trailingAnchor),
                child.topAnchor.constraint(equalTo: displayView.topAnchor), child.bottomAnchor.constraint(equalTo: displayView.bottomAnchor)])
        }
    }

    /// Tiers: the bounded Kinetic runtime first, then the scriptless image / render-graph backend, then the
    /// complete ported renderer, which is the final arbiter (user decision 2026-10-05: success rate first).
    /// The two earlier tiers are optional fast paths with their own stricter parsers and budgets, so any
    /// failure there (Unsupported, a missing asset, their own malformed / budget / graphics verdicts, or a
    /// foreign error) only means "this tier cannot draw it" and the next tier is tried. Only an unsafe path,
    /// disposal and cancellation stop at once. When every tier fails, a missing asset reported earlier stays
    /// the reported cause (the ported engines provide built-in programs the bounded runtime looks for on
    /// disk); otherwise the complete engine's error is reported.
    public func prepare() async throws {
        var missing: SceneRuntimeError?
        func moveOn(_ error: Error) throws {
            switch error {
            case is CancellationError, SceneRuntimeError.disposed, SceneRuntimeError.invalidPath: throw error
            case SceneRuntimeError.missingAsset(let path): if missing == nil { missing = .missingAsset(path) }
            default: break
            }
            try Task.checkCancellation()
            guard !isDisposed else { throw SceneRuntimeError.disposed }
        }
        do { try await prepareBounded(); return } catch { try moveOn(error) }
        do { try await prepareExtended(); return } catch { try moveOn(error) }
        do { try await prepareFull() }
        catch let error as SceneRuntimeError where error != .disposed { throw missing ?? error }
    }

    private func prepareFull() async throws {
        if let failure { throw failure }
        guard preparation == nil, fullHost == nil else { throw SceneRuntimeError.malformed("concurrent prepare") }
        let token = generation
        let size = displayView.bounds.size.width >= 1 && displayView.bounds.size.height >= 1
            ? displayView.bounds.size : (NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080))
        let host: KineticWPESceneHost
        do { host = try KineticWPESceneHost(sceneFolder: root, engineAssets: engineAssets, size: size,
                                            dependencyFolder: dependencyFolder) }
        catch { throw Self.translateFull(error) }
        fullHost = host
        do {
            let frame = try await host.prepare(timeout: limits.preparationTimeout, muted: isMuted)
            try Task.checkCancellation()
            guard !isDisposed, token == generation, fullHost === host else { throw SceneRuntimeError.disposed }
            if let frame { preparedFrame = frame; fallback.layer?.contents = frame }
            let view = host.view
            view.translatesAutoresizingMaskIntoConstraints = false
            view.alphaValue = 0
            displayView.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: displayView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: displayView.trailingAnchor),
                view.topAnchor.constraint(equalTo: displayView.topAnchor), view.bottomAnchor.constraint(equalTo: displayView.bottomAnchor)])
            usesFullEngine = true
            isPrepared = true
        } catch {
            if fullHost === host { fullHost = nil }
            await host.dispose()
            throw Self.translateFull(error)
        }
    }

    private static func translateFull(_ error: Error) -> Error {
        switch error {
        case let error as SceneRuntimeError: return error
        case is CancellationError: return error
        case KineticWPESceneHostError.timedOut: return SceneRuntimeError.budgetExceeded("prepare deadline")
        case KineticWPESceneHostError.disposed: return SceneRuntimeError.disposed
        case KineticWPESceneHostError.notAScene: return SceneRuntimeError.malformed("project.json is not a Scene project")
        case KineticWPESceneHostError.unsupported(let detail): return SceneRuntimeError.unsupported(detail)
        case KineticWPESceneHostError.entryMissing(let entry): return SceneRuntimeError.missingAsset(entry)
        case KineticWPESceneHostError.missingAsset(let path): return SceneRuntimeError.missingAsset(path)
        case KineticWPESceneHostError.missingDependency(let id): return SceneRuntimeError.missingAsset(missingDependencyDetail(id))
        case KineticWPESceneHostError.metalUnavailable: return SceneRuntimeError.graphics("Metal unavailable")
        case KineticWPESceneHostError.firstFrameFailed: return SceneRuntimeError.graphics("first frame")
        case SceneRenderingError.resourceFailed(let diagnostic):
            if case .fileMissing(_, let path) = diagnostic { return SceneRuntimeError.missingAsset(path) }
            return SceneRuntimeError.unsupported(diagnostic.errorDescription)
        case SceneRenderingError.parseFailed(let detail): return SceneRuntimeError.malformed(detail)
        case WPERenderGraphError.fileMissing(let path): return SceneRuntimeError.missingAsset(path)
        case WPERenderGraphError.invalidJSON(let path): return SceneRuntimeError.malformed(path)
        case SceneRenderingError.metalRendererUnsupported(let reason): return SceneRuntimeError.unsupported(reason)
        default: return SceneRuntimeError.unsupported("scene engine: \(error.localizedDescription)")
        }
    }

    private func prepareExtended() async throws {
        if let failure { throw failure }
        guard preparation == nil else { throw SceneRuntimeError.malformed("concurrent prepare") }
        let root = root, assets = engineAssets, limits = limits, token = generation
        let completion = ScenePreparation<SceneExtendedEngine>()
        let task = Task.detached(priority: .userInitiated) {
            do { completion.finish(.success(try await SceneExtendedEngine.prepare(root: root, engineAssets: assets, limits: limits))) }
            catch { completion.finish(.failure(error)) }
        }
        preparation = task
        cancelPreparation = { task.cancel(); completion.finish(.failure(CancellationError())) }
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: UInt64(limits.preparationTimeout * 1_000_000_000)) } catch { return }
            task.cancel(); completion.finish(.failure(SceneRuntimeError.budgetExceeded("extended prepare deadline")))
        }
        defer { watchdog.cancel(); preparation = nil; cancelPreparation = nil }
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { completion.install($0) }
        }, onCancel: { task.cancel(); completion.finish(.failure(CancellationError())) })
        do { try Task.checkCancellation() }
        catch { await result.backend.dispose(); throw error }
        guard !isDisposed, token == generation else { await result.backend.dispose(); throw SceneRuntimeError.disposed }
        guard let queue = result.device.makeCommandQueue() else { await result.backend.dispose(); throw SceneRuntimeError.graphics("extended presentation queue") }
        extendedEngine = result; extendedQueue = queue; usesExtendedRenderGraph = true
        preparedFrame = result.frame; fallback.layer?.contents = result.frame
        metalView.device = result.device; metalView.delegate = self
        isPrepared = true
    }

    private func prepareBounded() async throws {
        guard !isDisposed else { throw SceneRuntimeError.disposed }
        if let failure { throw failure }
        if isPrepared { return }
        guard preparation == nil else { throw SceneRuntimeError.malformed("concurrent prepare") }
        try limits.validate()
        let root = root, engineAssets = engineAssets, limits = limits, token = generation
        let completion = ScenePreparation<(SceneMetalEngine, CGImage)>()
        let task = Task.detached(priority: .userInitiated) {
            do {
                let graph = try SceneRenderGraph.load(root: root, engineAssets: engineAssets, limits: limits)
                try Task.checkCancellation()
                let engine = try SceneMetalEngine(graph: graph)
                let frame = try await engine.firstFrame()
                completion.finish(.success((engine, frame)))
            } catch { completion.finish(.failure(error)) }
        }
        preparation = task
        cancelPreparation = { task.cancel(); completion.finish(.failure(CancellationError())) }
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: UInt64(limits.preparationTimeout * 1_000_000_000)) }
            catch { return }
            task.cancel(); completion.finish(.failure(SceneRuntimeError.budgetExceeded("prepare deadline")))
        }
        defer { watchdog.cancel(); preparation = nil; cancelPreparation = nil }
        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { completion.install($0) }
        }, onCancel: { task.cancel(); completion.finish(.failure(CancellationError())) })
        try Task.checkCancellation()
        guard !isDisposed, generation == token else { throw SceneRuntimeError.disposed }
        var firstFrame = result.1
        if !result.0.graph.document.scripts.isEmpty {
            let executor = SceneScriptExecutor()
            // While this tier is still preparing, a Worker failure only fails this tier (the next tier is tried);
            // it must not mark the whole runtime failed or reach the host as a playback failure.
            let preparationFailure = ScenePreparationFailure()
            executor.onFailure = { error in preparationFailure.error = preparationFailure.error ?? error }
            scripts = executor
            do {
                let values = try await executor.prepare(result.0.graph.document.scripts)
                try Task.checkCancellation()
                guard !isDisposed, generation == token else { throw SceneRuntimeError.disposed }
                try result.0.applyScriptValues(values)
                firstFrame = try await result.0.firstFrame()
                try Task.checkCancellation()
                guard !isDisposed, generation == token else { throw SceneRuntimeError.disposed }
                if let error = preparationFailure.error { throw error }
            } catch { executor.dispose(); scripts = nil; throw error }
            executor.onFailure = { [weak self] error in self?.fail(error) }
        }
        if let failure { throw failure }
        engine = result.0; preparedFrame = firstFrame
        fallback.layer?.contents = firstFrame
        metalView.device = result.0.device; metalView.delegate = self
        isPrepared = true
    }

    public func play() {
        guard isPrepared, !isDisposed, !failed, !isPlaying else { return }
        startedAt = ProcessInfo.processInfo.systemUptime; isPlaying = true
        if let fullHost {
            fullHost.play()
            fullHost.view.alphaValue = 1
            monitorFullHealth(fullHost)
            return
        }
        metalView.isPaused = false
    }
    public func pause() {
        guard !isDisposed else { return }
        if isPlaying { elapsed = sceneTime; startedAt = nil }
        isPlaying = false; metalView.isPaused = true
        fullHost?.pause()
        fullHealthMonitor?.cancel(); fullHealthMonitor = nil
        scriptEpoch &+= 1
        // Keep the last presented drawable. Pausing never clears either backing view.
    }
    public func resume() { play() }
    public func setMuted(_ muted: Bool) { isMuted = muted; fullHost?.setMuted(muted) }
    public func dispose() {
        guard !isDisposed else { return }
        pause(); isDisposed = true; generation &+= 1
        cancelPreparation?(); cancelPreparation = nil; preparation?.cancel(); preparation = nil
        scriptFrame?.cancel(); scriptFrame = nil; scripts?.dispose(); scripts = nil
        extendedFrame?.cancel(); extendedFrame = nil
        if let extendedEngine { Task { await extendedEngine.backend.dispose() } }
        extendedEngine = nil; extendedQueue = nil
        if let fullHost { fullHost.view.removeFromSuperview(); Task { await fullHost.dispose() } }
        fullHost = nil; usesFullEngine = false
        metalView.delegate = nil; metalView.device = nil; metalView.alphaValue = 0
        fallback.layer?.contents = nil; preparedFrame = nil; engine = nil; isPrepared = false
        onFailure = nil
        audioSpectrum = .silence
        frameTargets = []; lastCompletedFrame = nil
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard isPrepared, !isPlaying, !isDisposed, !failed else { return }
        needsPausedRedraw = true
        view.draw()
    }
    public func draw(in view: MTKView) {
        if let extendedEngine {
            drawExtended(in: view, engine: extendedEngine)
            return
        }
        guard isPrepared, (isPlaying || needsPausedRedraw), !isDisposed, !failed, !frameInFlight,
              scriptFrame == nil, let engine else { return }
        let token = generation
        let cursor: SIMD2<Float>
        if let window = displayView.window {
            let position = NSEvent.mouseLocation
            let local = window.convertPoint(fromScreen: position)
            let point = displayView.convert(local, from: nil)
            cursor = SIMD2(Float(min(1, max(0, point.x / max(1, displayView.bounds.width)))),
                           Float(min(1, max(0, point.y / max(1, displayView.bounds.height)))))
        } else { cursor = SIMD2(repeating: 0.5) }
        let time = sceneTime
        if isPlaying, let scripts {
            let epoch = scriptEpoch, delta = max(0, time - lastScriptTime)
            scriptFrame = Task { [weak self] in
                do {
                    let values = try await scripts.update(time: time, delta: delta, cursor: cursor, audio: self?.audioSpectrum ?? .silence)
                    guard let self, !self.isDisposed, self.generation == token else { return }
                    self.scriptFrame = nil
                    guard self.isPlaying, self.scriptEpoch == epoch else {
                        if self.needsPausedRedraw { self.metalView.draw() }
                        return
                    }
                    try engine.applyScriptValues(values)
                    self.lastScriptTime = time
                    self.render(in: view, engine: engine, time: time, cursor: cursor)
                } catch {
                    guard let self, !self.isDisposed, self.generation == token else { return }
                    self.scriptFrame = nil; self.fail(error)
                }
            }
        } else { render(in: view, engine: engine, time: time, cursor: cursor) }
    }
    private func drawExtended(in view: MTKView, engine: SceneExtendedEngine) {
        guard isPrepared, (isPlaying || needsPausedRedraw), !isDisposed, !failed,
              !frameInFlight, let drawable = view.currentDrawable, let queue = extendedQueue else { return }
        let token = generation, epoch = scriptEpoch, time = sceneTime
        let width = drawable.texture.width, height = drawable.texture.height
        do {
            guard width > 0, height > 0, width <= limits.maximumTextureEdge, height <= limits.maximumTextureEdge else {
                throw SceneRuntimeError.budgetExceeded("extended frame dimensions")
            }
            if frameTargets.first?.width != width || frameTargets.first?.height != height {
                // Reserve the peak while both old and new pairs are alive,
                // including the CPU first frame and detached completed frame.
                let oldBytes = frameTargets.reduce(0) { $0 + $1.width * $1.height * 4 }
                let preview = (preparedFrame?.width ?? 0) * (preparedFrame?.height ?? 0) * 4
                let detached = lastCompletedFrame.map { old in frameTargets.contains { $0 === old } ? 0 : old.width * old.height * 4 } ?? 0
                try engine.backend.setExternalBytes(width * height * 8 + oldBytes + preview + detached)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
                guard let a = engine.device.makeTexture(descriptor: descriptor), let b = engine.device.makeTexture(descriptor: descriptor) else {
                    throw SceneRuntimeError.graphics("extended presentation buffers")
                }
                frameTargets = [a, b]
            }
            guard width * height * 8 <= limits.maximumResidentBytes - engine.residentBytes else {
                throw SceneRuntimeError.budgetExceeded("extended scene + presentation")
            }
            let target = frameTargets.first { $0 !== lastCompletedFrame }!
            let previewBytes = (preparedFrame?.width ?? 0) * (preparedFrame?.height ?? 0) * 4
            let retainedBytes = lastCompletedFrame.map { texture in
                frameTargets.contains { $0 === texture } ? 0 : texture.width * texture.height * 4
            } ?? 0
            try engine.backend.setExternalBytes(width * height * 8 + previewBytes + retainedBytes)
            let completed = SceneCompletedFrame(texture: target)
            frameInFlight = true; needsPausedRedraw = false
            var cursor = SIMD2<Double>(repeating: 0.5)
            if let window = displayView.window {
                let local = displayView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                cursor = SIMD2(min(1, max(0, local.x / max(1, displayView.bounds.width))),
                               min(1, max(0, local.y / max(1, displayView.bounds.height))))
            }
            extendedFrame = Task { [weak self] in
                do {
                    try await engine.backend.render(time: time, cursor: cursor, target: completed.texture)
                    try Task.checkCancellation()
                    guard let self, !self.isDisposed, !self.failed, self.generation == token else { return }
                    guard self.scriptEpoch == epoch else {
                        self.frameInFlight = false; self.extendedFrame = nil
                        if self.needsPausedRedraw { self.metalView.draw() }
                        return
                    }
                    guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
                        throw SceneRuntimeError.graphics("extended presentation")
                    }
                    blit.copy(from: completed.texture, to: drawable.texture); blit.endEncoding(); command.present(drawable)
                    command.addCompletedHandler { [weak self] result in
                        let error = result.status == .completed ? nil : SceneRuntimeError.graphics("extended presentation GPU failure")
                        Task { @MainActor in
                            guard let self, !self.isDisposed, self.generation == token else { return }
                            self.extendedFrame = nil; self.frameInFlight = false
                            if let error { self.fail(error) }
                            else { self.lastCompletedFrame = completed.texture; self.metalView.alphaValue = 1 }
                        }
                    }
                    command.commit()
                } catch {
                    guard let self, !self.isDisposed, self.generation == token else { return }
                    self.extendedFrame = nil; self.frameInFlight = false; self.fail(SceneExtendedEngine.translate(error))
                }
            }
        } catch { fail(error) }
    }

    private func render(in view: MTKView, engine: SceneMetalEngine, time: TimeInterval, cursor: SIMD2<Float>) {
        guard let drawable = view.currentDrawable, let command = engine.queue.makeCommandBuffer() else { return }
        let token = generation
        do {
            let width = drawable.texture.width, height = drawable.texture.height
            guard width > 0, height > 0, width <= limits.maximumTextureEdge, height <= limits.maximumTextureEdge else {
                throw SceneRuntimeError.budgetExceeded("scene frame dimensions")
            }
            if frameTargets.first?.width != width || frameTargets.first?.height != height {
                let previousBytes = lastCompletedFrame.map { $0.width * $0.height * 4 } ?? 0
                guard width * height * 8 + previousBytes <= limits.maximumResidentBytes - engine.graph.residentBytes else {
                    throw SceneRuntimeError.budgetExceeded("scene frame buffers")
                }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .shared; descriptor.usage = [.renderTarget]
                guard let first = engine.device.makeTexture(descriptor: descriptor), let second = engine.device.makeTexture(descriptor: descriptor) else {
                    throw SceneRuntimeError.graphics("scene frame buffers")
                }
                frameTargets = [first, second]
            }
            let target = frameTargets.first(where: { $0 !== lastCompletedFrame })!
            try engine.encode(target: target, time: time, cursor: cursor, command: command)
            guard let blit = command.makeBlitCommandEncoder() else { throw SceneRuntimeError.graphics("scene frame presentation") }
            blit.copy(from: target, to: drawable.texture); blit.endEncoding()
            frameInFlight = true
            needsPausedRedraw = false
            command.present(drawable)
            let completedFrame = SceneCompletedFrame(texture: target)
            command.addCompletedHandler { [weak self] result in
                let error = result.status == .completed ? nil : SceneRuntimeError.graphics(result.error?.localizedDescription ?? "GPU frame failure")
                Task { @MainActor in
                    guard let self, self.generation == token, !self.isDisposed else { return }
                    self.frameInFlight = false
                    if let error { self.fail(error) }
                    else {
                        self.lastCompletedFrame = completedFrame.texture
                        self.metalView.alphaValue = 1
                        if self.needsPausedRedraw { self.metalView.draw() }
                    }
                }
            }
            command.commit()
        } catch { fail(error) }
    }
    /// While playing, a burst of GPU command-buffer failures ends complete-engine playback the same way as
    /// the bounded runtime: freeze the last presented frame, release the engine, report through `onFailure`.
    private func monitorFullHealth(_ host: KineticWPESceneHost) {
        fullHealthMonitor?.cancel()
        let interval = fullHealthInterval
        fullHealthMonitor = Task { @MainActor [weak self, weak host] in
            var previous = host?.health.gpuErrorCount ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self, let host, self.fullHost === host, self.isPlaying, !self.failed else { return }
                let health = host.health
                if health.gpuErrorCount - previous >= Self.fullGPUFailureBurst {
                    await self.failFull(.graphics("GPU command buffers failing: \(health.lastGPUError ?? "unknown")"), host: host)
                    return
                }
                previous = health.gpuErrorCount
            }
        }
    }

    private func failFull(_ error: SceneRuntimeError, host: KineticWPESceneHost) async {
        let frame = await host.captureFrame()
        guard !failed, !isDisposed, fullHost === host else { return }
        if let frame { preparedFrame = frame; fallback.layer?.contents = frame }
        fullHealthMonitor = nil
        host.view.removeFromSuperview()
        fullHost = nil
        Task { await host.dispose() }
        fail(error)
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        pause(); scripts?.dispose(); scripts = nil; failed = true; failure = error
        if let texture = lastCompletedFrame, let image = try? SceneMetalEngine.snapshot(texture) {
            preparedFrame = image; fallback.layer?.contents = image
        }
        metalView.alphaValue = 0
        frameTargets = []; lastCompletedFrame = nil
        extendedFrame?.cancel(); extendedFrame = nil
        if let extendedEngine { Task { await extendedEngine.backend.dispose() } }
        extendedEngine = nil; extendedQueue = nil
        onFailure?(error)
    }
}

/// Holds a SceneScript Worker failure reported while the bounded tier is still preparing.
@MainActor
private final class ScenePreparationFailure {
    var error: Error?
}

/// Wallpaper surfaces never intercept desktop mouse events.
private final class SceneSurfaceView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
