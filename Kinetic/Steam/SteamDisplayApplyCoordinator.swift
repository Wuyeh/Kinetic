import Combine
import Foundation

/// Module 18：下载与 Runtime 之间的应用意图。下载服务仍只负责入库，Renderer 生命周期仍由 Runtime 管理。
@MainActor
final class SteamDisplayApplyCoordinator {
    typealias Acquire = @MainActor (SteamWorkshopItemInfo) async -> Result<Wallpaper, SteamAcquisitionError>
    enum Outcome: Equatable {
        case downloadedAndApplied, appliedExisting, downloadFailed, applyFailed, disconnected, cancelled

        var messageKey: String {
            switch self {
            case .downloadedAndApplied: return "steam.apply.succeeded"
            case .appliedExisting: return "steam.apply.existing"
            case .downloadFailed: return "steam.apply.downloadFailed"
            case .applyFailed: return "steam.apply.prepareFailed"
            case .disconnected: return "steam.apply.disconnected"
            case .cancelled: return "steam.apply.cancelled"
            }
        }
    }
    struct Notice {
        let workshopID: String
        let displayID: DisplayID
        let outcome: Outcome
        let detail: String?
        var message: String {
            let text = NSLocalizedString(outcome.messageKey, comment: "Steam display apply outcome")
            // 顶部提示只显示一行；错误原因不能放到会被截掉的第二行。
            return detail.map { text + "：" + $0 } ?? text
        }
    }

    let notices = PassthroughSubject<Notice, Never>()
    private enum Phase { case acquiring, preparing(Wallpaper.ID) }
    private struct Request {
        let id = UUID()
        let item: SteamWorkshopItemInfo
        let display: DisplayID
        let initialWallpaper: Wallpaper.ID?
        let initiallyStopped: Bool
        let needsDownload: Bool
        var phase: Phase = .acquiring
        var cancellation: Outcome?
    }
    private let runtime: WallpaperRuntimeManager
    private let resolveWorkshop: (String) -> Wallpaper?
    private let resolveWallpaper: (Wallpaper.ID) -> Wallpaper?
    private let acquire: Acquire
    private var requests: [DisplayID: Request] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var subscriptions = Set<AnyCancellable>()

    init(runtime: WallpaperRuntimeManager,
         resolveWorkshop: @escaping (String) -> Wallpaper?,
         resolveWallpaper: @escaping (Wallpaper.ID) -> Wallpaper?,
         acquire: @escaping Acquire) {
        self.runtime = runtime
        self.resolveWorkshop = resolveWorkshop
        self.resolveWallpaper = resolveWallpaper
        self.acquire = acquire
        runtime.$summary.sink { [weak self] in self?.observe($0) }.store(in: &subscriptions)
        runtime.$lastFailure.compactMap { $0 }.sink { [weak self] failure in
            guard let self, let request = self.requests[failure.displayID],
                  case .preparing(let id) = request.phase, id == failure.wallpaperID else { return }
            self.finish(request, .applyFailed)
        }.store(in: &subscriptions)
        runtime.$globalUserCommand.dropFirst().sink { [weak self] command in
            switch command {
            case .stop?, .reenable?: self?.cancelAllApplications()
            default: break // Pause / Resume are preserved by the existing Runtime during preparation.
            }
        }.store(in: &subscriptions)
    }

    convenience init(runtime: WallpaperRuntimeManager, library: WallpaperLibrary, steam: SteamAcquisitionService) {
        self.init(runtime: runtime, resolveWorkshop: { library.wallpaper(workshopID: $0) },
                  resolveWallpaper: { library.wallpaper(id: $0) }, acquire: { item in
            let result = await steam.acquire(item)
            guard case .failure(.alreadyInProgress) = result else { return result }
            // Attach to the existing ordinary download without starting another task or changing its House animation.
            // @Published emits in willSet: use the delivered dictionary, never re-read steam.tasks inside the event.
            for await phases in steam.$tasks.values {
                if Task.isCancelled { break }
                switch phases[item.workshopID] {
                case .finished(let id):
                    if let wallpaper = library.wallpaper(id: id) { return .success(wallpaper) }
                    return .failure(.importFailed(NSLocalizedString("library.error.notFound", comment: "")))
                case .failed(let reason): return .failure(.downloadFailed(reason))
                default: break
                }
            }
            return .failure(.alreadyInProgress)
        })
    }

    /// A valid drop already resolved a stable display ID. Never infer a target or fall back to the main display.
    func request(_ item: SteamWorkshopItemInfo, to display: DisplayID) {
        guard let state = runtime.state(of: display) else { return }
        if let previous = requests[display], previous.item.workshopID == item.workshopID,
           previous.cancellation == nil { return }
        let existing = resolveWorkshop(item.workshopID)
        let request = Request(item: item, display: display,
                              initialWallpaper: state.preparingWallpaperID ?? state.activeWallpaperID ?? state.lastActiveWallpaperID,
                              initiallyStopped: state.playbackState == .stopped, needsDownload: existing == nil)
        requests[display] = request
        if let existing { apply(existing, for: request); return }
        tasks[request.id] = Task { [weak self, acquire] in
            let result = await acquire(item)
            guard let self else { return }
            self.tasks[request.id] = nil
            guard !Task.isCancelled, let current = self.requests[display], current.id == request.id else { return }
            switch result {
            case .success(let wallpaper): self.apply(wallpaper, for: current)
            case .failure(.alreadyInLibrary(let id)):
                if let wallpaper = self.resolveWallpaper(id) { self.apply(wallpaper, for: current) }
                else { self.finish(current, .applyFailed) }
            case .failure(let error): self.finish(current, .downloadFailed, detail: error.localizedDescription)
            }
        }
    }

    /// A newer explicit local Apply wins even if it requests the same wallpaper ID as before.
    func cancelApplication(on display: DisplayID) {
        guard var request = requests[display] else { return }
        if case .acquiring = request.phase {
            if request.cancellation == nil { request.cancellation = .cancelled }
            requests[display] = request // Download continues and still enters the local library.
        } else { finish(request, .cancelled) }
    }

    func shutdown() {
        subscriptions.removeAll()
        requests.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func cancelAllApplications() {
        for display in Array(requests.keys) { cancelApplication(on: display) }
    }

    private func apply(_ downloaded: Wallpaper, for request: Request) {
        guard let current = requests[request.display], current.id == request.id else { return }
        if let cancelled = current.cancellation { finish(current, cancelled); return }
        guard runtime.hasDisplay(current.display) else { finish(current, .disconnected); return }
        guard let wallpaper = resolveWallpaper(downloaded.id), wallpaper.supportState == .supported,
              WallpaperRuntimeManager.isRendererAvailable(for: wallpaper.type) else {
            finish(current, .applyFailed); return
        }
        var preparing = current
        preparing.phase = .preparing(wallpaper.id)
        requests[current.display] = preparing
        WallpaperPreviewCoordinator.shared.stopAll()
        runtime.apply(wallpaper, to: current.display)
        // An already-active wallpaper may be an intentional no-op; don't leave that request pending forever.
        observe(runtime.summary)
    }

    private func observe(_ summary: RuntimeSummary) {
        for request in Array(requests.values) {
            guard let state = summary.state(of: request.display) else {
                if case .acquiring = request.phase {
                    var disconnected = request; disconnected.cancellation = .disconnected
                    requests[request.display] = disconnected
                } else { finish(request, .disconnected) }
                continue
            }
            switch request.phase {
            case .acquiring:
                let intent = state.preparingWallpaperID ?? state.activeWallpaperID ?? state.lastActiveWallpaperID
                if intent != request.initialWallpaper || (!request.initiallyStopped && state.playbackState == .stopped) {
                    cancelApplication(on: request.display)
                }
            case .preparing(let id):
                if state.activeWallpaperID == id, state.preparingWallpaperID == nil {
                    finish(request, request.needsDownload ? .downloadedAndApplied : .appliedExisting)
                } else if state.preparingWallpaperID != id {
                    // A stop or a newer application superseded this candidate. Failures arrive before this snapshot.
                    finish(request, .cancelled)
                }
            }
        }
    }

    private func finish(_ request: Request, _ outcome: Outcome, detail: String? = nil) {
        guard requests[request.display]?.id == request.id else { return }
        requests[request.display] = nil
        notices.send(Notice(workshopID: request.item.workshopID, displayID: request.display,
                            outcome: outcome, detail: detail))
    }
}
