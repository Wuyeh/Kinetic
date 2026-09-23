import AppKit
import os

/// 预览区域显示什么内容。与卡片外观状态（Active / Selected / Hover / Unsupported）无关。
/// 没有 Live Preview 会话时为静态缩略图。
enum PreviewContentState: Equatable {
    case staticThumbnail
    case preparing
    case playing
    case failed
}

/// 卡片内的短生命周期预览会话。只显示在卡片自己的预览区域里：
/// 不接触 Desktop Runtime、Playback State Machine、Crossfade、工具条或菜单栏。
@MainActor
protocol LivePreviewSession: AnyObject {
    var wallpaperID: Wallpaper.ID { get }
    /// 放进预览区域的内容；尺寸完全由预览区域决定。
    var contentView: NSView { get }
    var state: PreviewContentState { get }
    var onStateChange: ((PreviewContentState) -> Void)? { get set }
    func start()
    /// 立即停止并释放全部资源；之后不再回调，也不能重新开始。
    func invalidate()
}

/// 全局唯一的悬停预览协调者：延迟、取消，以及“任何时刻最多一个 Live Preview”。
/// 它不是 Desktop Runtime，不会应用壁纸，也不会读写播放状态。
@MainActor
final class WallpaperPreviewCoordinator: NSObject, ObservableObject {
    static let shared = WallpaperPreviewCoordinator()

    /// 悬停后等待多久才创建预览资源。
    nonisolated static let hoverPreviewDelay: TimeInterval = 0.35
    /// 准备超过这个时间才显示轻量进度指示。
    nonisolated static let slowPreparationThreshold: TimeInterval = 0.3
    /// 准备迟迟没有完成时，放弃并保留静态缩略图。
    nonisolated static let preparationTimeout: TimeInterval = 10

    /// 当前正在准备、播放或已失败的那一个预览。
    struct ActivePreview: Equatable {
        let wallpaperID: Wallpaper.ID
        let session: LivePreviewSession
        var state: PreviewContentState
        var showsProgress: Bool

        static func == (lhs: ActivePreview, rhs: ActivePreview) -> Bool {
            lhs.wallpaperID == rhs.wallpaperID && lhs.session === rhs.session
                && lhs.state == rhs.state && lhs.showsProgress == rhs.showsProgress
        }
    }

    /// 暂停预览的系统条件；任一存在时停止预览且不再安排新的预览。
    enum Suppression: Hashable {
        case systemSleep, displaySleep, screenLocked, sessionInactive
    }

    @Published private(set) var activePreview: ActivePreview?
    private(set) var pendingWallpaperID: Wallpaper.ID?
    private(set) var suppressions: Set<Suppression> = []

    private let delay: TimeInterval
    private let slowThreshold: TimeInterval
    private let timeout: TimeInterval
    private let makeSession: @MainActor (Wallpaper) -> LivePreviewSession?
    private let isEligible: @MainActor (Wallpaper) -> Bool
    private var pendingTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// 预览失败的内容不在本次运行中反复重试。
    private var failedWallpaperIDs: Set<Wallpaper.ID> = []
    private let observesSystem: Bool
    private static let log = Logger(subsystem: "com.kinetic.app", category: "LivePreview")

    init(
        delay: TimeInterval = WallpaperPreviewCoordinator.hoverPreviewDelay,
        slowThreshold: TimeInterval = WallpaperPreviewCoordinator.slowPreparationThreshold,
        timeout: TimeInterval = WallpaperPreviewCoordinator.preparationTimeout,
        observesSystem: Bool = true,
        isEligible: @escaping @MainActor (Wallpaper) -> Bool = { LivePreviewEligibility.canLivePreview($0) },
        makeSession: @escaping @MainActor (Wallpaper) -> LivePreviewSession? = { LivePreviewEligibility.makeSession(for: $0) }
    ) {
        self.delay = delay
        self.slowThreshold = slowThreshold
        self.timeout = timeout
        self.observesSystem = observesSystem
        self.isEligible = isEligible
        self.makeSession = makeSession
        super.init()
        if observesSystem { beginObservingSystem() }
    }

    var activePreviewWallpaperID: Wallpaper.ID? { activePreview?.wallpaperID }
    var isSuppressed: Bool { !suppressions.isEmpty }

    /// 某张卡片的预览；其他卡片得到 nil。
    func preview(for wallpaperID: Wallpaper.ID) -> ActivePreview? {
        activePreview?.wallpaperID == wallpaperID ? activePreview : nil
    }

    // MARK: Hover

    /// 鼠标进入卡片：先停止其他任何预览，再等待延迟；延迟内离开则什么资源都不创建。
    func hoverBegan(_ wallpaper: Wallpaper) {
        if pendingWallpaperID == wallpaper.id || activePreview?.wallpaperID == wallpaper.id { return }
        stopAll()
        guard !isSuppressed, !failedWallpaperIDs.contains(wallpaper.id) else { return }
        pendingWallpaperID = wallpaper.id
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.pendingWallpaperID == wallpaper.id else { return }
            self.pendingWallpaperID = nil
            self.pendingTask = nil
            self.startPreview(wallpaper)
        }
    }

    /// 鼠标离开卡片（或卡片不可见）：取消尚未开始的请求，停止并释放这张卡片的预览。
    func hoverEnded(_ wallpaperID: Wallpaper.ID) {
        if pendingWallpaperID == wallpaperID { cancelPending() }
        if activePreview?.wallpaperID == wallpaperID { stopCurrentPreview() }
    }

    /// 预览区域不再可见（窗口关闭、最小化、失去前台、滚出可视范围）：只结束这一个会话，
    /// 不取消之后新的悬停请求。
    func previewInterrupted(_ session: LivePreviewSession) {
        guard activePreview?.session === session else { return }
        stopCurrentPreview()
    }

    /// 应用壁纸、窗口关闭、系统休眠等：立即停止一切预览。
    func stopAll() {
        cancelPending()
        stopCurrentPreview()
    }

    func setSuppressed(_ reason: Suppression, _ suppressed: Bool) {
        if suppressed {
            suppressions.insert(reason)
            stopAll()
        } else {
            suppressions.remove(reason)
        }
    }

    // MARK: Session

    private func startPreview(_ wallpaper: Wallpaper) {
        guard !isSuppressed, isEligible(wallpaper) else { return }
        guard let session = makeSession(wallpaper) else {
            failedWallpaperIDs.insert(wallpaper.id)
            return
        }
        activePreview = ActivePreview(wallpaperID: wallpaper.id, session: session, state: .preparing, showsProgress: false)
        session.onStateChange = { [weak self, weak session] state in
            guard let self, let session else { return }
            self.sessionStateChanged(session, state)
        }
        session.start()
        guard activePreview?.session === session, activePreview?.state == .preparing else { return }

        let slow = UInt64(max(0, slowThreshold) * 1_000_000_000)
        slowTask = Task { [weak self, weak session] in
            try? await Task.sleep(nanoseconds: slow)
            guard !Task.isCancelled, let self, var current = self.activePreview,
                  current.session === session, current.state == .preparing else { return }
            current.showsProgress = true
            self.activePreview = current
        }
        let limit = UInt64(max(0, timeout) * 1_000_000_000)
        timeoutTask = Task { [weak self, weak session] in
            try? await Task.sleep(nanoseconds: limit)
            guard !Task.isCancelled, let self, let session,
                  self.activePreview?.session === session, self.activePreview?.state == .preparing else { return }
            Self.log.notice("Live preview preparation timed out")
            self.sessionStateChanged(session, .failed)
        }
    }

    private func sessionStateChanged(_ session: LivePreviewSession, _ state: PreviewContentState) {
        guard var current = activePreview, current.session === session else { return }
        switch state {
        case .playing:
            cancelPreparationTimers()
            current.state = .playing
            current.showsProgress = false
            activePreview = current
        case .failed:
            // 非关键失败：静默回到静态缩略图，立即释放资源，不影响卡片或桌面。
            cancelPreparationTimers()
            failedWallpaperIDs.insert(current.wallpaperID)
            session.onStateChange = nil
            session.invalidate()
            current.state = .failed
            current.showsProgress = false
            activePreview = current
            Self.log.notice("Live preview failed; keeping the static thumbnail")
        case .preparing, .staticThumbnail:
            break
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingWallpaperID = nil
    }

    private func cancelPreparationTimers() {
        slowTask?.cancel()
        slowTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func stopCurrentPreview() {
        cancelPreparationTimers()
        guard let current = activePreview else { return }
        activePreview = nil
        current.session.onStateChange = nil
        current.session.invalidate()
    }

    // MARK: System conditions

    private func beginObservingSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(NSNotification.Name, Selector)] = [
            (NSWorkspace.willSleepNotification, #selector(systemWillSleep)),
            (NSWorkspace.didWakeNotification, #selector(systemDidWake)),
            (NSWorkspace.screensDidSleepNotification, #selector(displaysDidSleep)),
            (NSWorkspace.screensDidWakeNotification, #selector(displaysDidWake)),
            (NSWorkspace.sessionDidResignActiveNotification, #selector(sessionDidResignActive)),
            (NSWorkspace.sessionDidBecomeActiveNotification, #selector(sessionDidBecomeActive))
        ]
        for (name, selector) in pairs {
            workspace.addObserver(self, selector: selector, name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock),
                                name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock),
                                name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func systemWillSleep() { setSuppressed(.systemSleep, true) }
    @objc private func systemDidWake() { setSuppressed(.systemSleep, false) }
    @objc private func displaysDidSleep() { setSuppressed(.displaySleep, true) }
    @objc private func displaysDidWake() { setSuppressed(.displaySleep, false) }
    @objc private func sessionDidResignActive() { setSuppressed(.sessionInactive, true) }
    @objc private func sessionDidBecomeActive() { setSuppressed(.sessionInactive, false) }
    @objc private func screenDidLock() { setSuppressed(.screenLocked, true) }
    @objc private func screenDidUnlock() { setSuppressed(.screenLocked, false) }

    deinit {
        if observesSystem {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            DistributedNotificationCenter.default().removeObserver(self)
        }
    }
}

/// 哪些壁纸可以做 Live Preview。判断集中在这里，不散落在各个 View。
enum LivePreviewEligibility {
    /// 视频：本地 MP4 / MOV 且文件可读。网页：文件夹内有入口页面。
    /// Scene 与其他 Unsupported 类型、缺失文件一律不预览。
    @MainActor
    static func canLivePreview(_ wallpaper: Wallpaper) -> Bool {
        guard wallpaper.supportState == .supported else { return false }
        switch wallpaper.type {
        case .video:
            let url = wallpaper.resourceURL
            return url.isFileURL
                && LocalImportService.videoExtensions.contains(url.pathExtension.lowercased())
                && FileManager.default.isReadableFile(atPath: url.path)
        case .web:
            return WebPreviewSession.entryURL(for: wallpaper) != nil
        case .scene:
            return false
        }
    }

    @MainActor
    static func makeSession(for wallpaper: Wallpaper) -> LivePreviewSession? {
        switch wallpaper.type {
        case .video: return VideoPreviewSession(wallpaper: wallpaper)
        case .web: return WebPreviewSession(wallpaper: wallpaper)
        case .scene: return nil
        }
    }
}
