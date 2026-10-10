import AppKit
import SwiftUI

private typealias Tokens = MainWindowDesignTokens

// MARK: - 对象

/// R4 第 50–51 节：详情窗口展示的对象。在线项目与已下载的同一 Steam 壁纸共用同一个详情来源与窗口。
enum WallpaperDetailsSubject: Equatable {
    case steam(SteamStoreItem)
    case local(Wallpaper)

    /// 窗口身份：同一壁纸再次打开时复用并聚焦原窗口。
    var key: String {
        if let workshopID { return "steam:\(workshopID)" }
        if case .local(let wallpaper) = self { return "local:\(wallpaper.id.uuidString)" }
        return "unknown"
    }

    var workshopID: String? {
        switch self {
        case .steam(let item): return item.workshopID
        case .local(let wallpaper): return wallpaper.steamMetadata?.workshopID
        }
    }

    var title: String {
        switch self {
        case .steam(let item): return item.title
        case .local(let wallpaper): return wallpaper.name
        }
    }

    var type: WallpaperType? {
        switch self {
        case .steam(let item): return item.type
        case .local(let wallpaper): return wallpaper.type
        }
    }

    var knownAuthor: String? {
        switch self {
        case .steam(let item): return item.authorName
        case .local(let wallpaper): return wallpaper.steamMetadata?.author
        }
    }
}

// MARK: - 窗口尺寸

enum WallpaperDetailsWindowMetrics {
    /// 规格：初始宽高约为主窗口「默认」宽高的 75%（不按主窗口当前被拉伸的尺寸计算），比例与主窗口默认比例一致。
    static let scale: CGFloat = 0.75
    static var defaultSize: CGSize {
        CGSize(width: Tokens.Window.defaultWidth * scale, height: Tokens.Window.defaultHeight * scale)
    }
    /// 左右两栏仍可读的最小尺寸。
    static let minimumSize = CGSize(width: 640, height: 420)
    /// 屏幕可用区域内保留的边距。
    static let screenMargin: CGFloat = 40

    /// 初始 / 最小尺寸都要适配当前屏幕的可用区域；比例只用于初始值，之后可以自由拉伸。
    static func initialSize(visibleFrame: CGRect?) -> CGSize {
        guard let visibleFrame else { return defaultSize }
        let available = CGSize(width: max(320, visibleFrame.width - 2 * screenMargin),
                               height: max(240, visibleFrame.height - 2 * screenMargin))
        let fit = min(1, available.width / defaultSize.width, available.height / defaultSize.height)
        return CGSize(width: (defaultSize.width * fit).rounded(), height: (defaultSize.height * fit).rounded())
    }

    static func minimumSize(visibleFrame: CGRect?) -> CGSize {
        let initial = initialSize(visibleFrame: visibleFrame)
        return CGSize(width: min(minimumSize.width, initial.width), height: min(minimumSize.height, initial.height))
    }
}

// MARK: - 窗口管理

/// 独立、非阻塞、可移动、可自由调整大小的标准窗口（不是 Sheet、Popover 或侧栏）。
/// 同一壁纸复用并聚焦原窗口；不同壁纸各自一个窗口。关闭只释放详情视图与它的请求，不影响任何 Runtime。
@MainActor
final class WallpaperDetailsWindows: NSObject, NSWindowDelegate {
    static let shared = WallpaperDetailsWindows()

    private var open: [String: (window: NSWindow, model: WallpaperDetailsModel)] = [:]

    var openKeys: Set<String> { Set(open.keys) }

    func window(for key: String) -> NSWindow? { open[key]?.window }

    /// 打开（或聚焦）详情窗口。`store` 提供在线详情；为 nil 时只显示本地信息。
    @discardableResult
    func show(_ subject: WallpaperDetailsSubject, store: SteamStoreService?, activate: Bool = true) -> NSWindow {
        if let existing = open[subject.key] {
            existing.window.makeKeyAndOrderFront(nil)
            if activate { NSApp.activate(ignoringOtherApps: true) }
            return existing.window
        }
        let model = WallpaperDetailsModel(subject: subject, store: store)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let size = WallpaperDetailsWindowMetrics.initialSize(visibleFrame: screen?.visibleFrame)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = subject.title
        window.minSize = WallpaperDetailsWindowMetrics.minimumSize(visibleFrame: screen?.visibleFrame)
        window.contentView = NSHostingView(rootView: WallpaperDetailsView(model: model)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        window.setContentSize(size)
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("Kinetic.WallpaperDetails.\(subject.key)")
        if let visible = screen?.visibleFrame {
            // 后打开的窗口错开一点，避免完全重叠。
            let offset = CGFloat(open.count % 6) * 24
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2 + offset,
                                          y: visible.midY - size.height / 2 - offset))
        } else {
            window.center()
        }
        open[subject.key] = (window, model)
        model.start()
        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = open.first(where: { $0.value.window === window })?.key else { return }
        open[key]?.model.cancel()
        open[key] = nil
        window.delegate = nil
        window.contentView = nil
    }

    func closeAll() {
        for entry in open.values { entry.window.close() }
    }
}

// MARK: - 数据

@MainActor
final class WallpaperDetailsModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        /// 只在真实详情请求进行时。
        case loading
        case loaded
        /// 网络等失败：保留已有内容，可重试。
        case failed(String)
        /// 没有 Steam 来源，或没有可用的 API Key：不请求。
        case noSteamInfo
    }

    let subject: WallpaperDetailsSubject
    @Published private(set) var details: SteamItemDetails?
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var posterURL: URL?
    @Published private(set) var localSize: Int64?
    private let store: SteamStoreService?
    private var task: Task<Void, Never>?
    private var posterTask: Task<Void, Never>?

    init(subject: WallpaperDetailsSubject, store: SteamStoreService?) {
        self.subject = subject
        self.store = store
    }

    func start() {
        loadPoster()
        loadLocalSize()
        fetchDetails()
    }

    func retry() {
        guard state != .loading else { return }
        fetchDetails()
    }

    func cancel() {
        task?.cancel()
        posterTask?.cancel()
        task = nil
        posterTask = nil
    }

    private func fetchDetails() {
        guard let workshopID = subject.workshopID, let store, store.hasAPIKey else {
            state = .noSteamInfo
            return
        }
        state = .loading
        task?.cancel()
        task = Task { [weak self] in
            do {
                let details = try await store.details(workshopID: workshopID)
                guard let self, !Task.isCancelled else { return }
                self.details = details
                self.state = .loaded
                if self.posterURL == nil { self.loadPoster() }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func loadPoster() {
        switch subject {
        case .local(let wallpaper):
            if let url = wallpaper.thumbnailURL { posterURL = url; return }
        case .steam:
            break
        }
        let item: SteamStoreItem? = {
            if case .steam(let item) = subject { return item }
            return details?.item
        }()
        guard let item, let posters = store?.posters else { return }
        if let cached = posters.cachedURL(for: item) { posterURL = cached; return }
        posterTask?.cancel()
        posterTask = Task { [weak self] in
            let url = await posters.load(item)
            guard let self, !Task.isCancelled else { return }
            self.posterURL = url
        }
    }

    private func loadLocalSize() {
        guard case .local(let wallpaper) = subject else { return }
        if let size = wallpaper.steamMetadata?.sizeInBytes { localSize = size }
        let url = wallpaper.resourceURL
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) { LocalImportFiles.fingerprint(of: url)?.size }.value
            guard let self, let size else { return }
            self.localSize = size
        }
    }

    // MARK: 显示用字段

    var title: String { details?.item.title ?? subject.title }

    var author: String? { details?.item.authorName ?? subject.knownAuthor }

    var tags: [String] {
        if let details { return details.item.tags }
        if case .steam(let item) = subject { return item.tags }
        return []
    }

    var fileSize: Int64? {
        details?.item.fileSize ?? {
            if case .steam(let item) = subject { return item.fileSize }
            return localSize
        }()
    }

    var published: Date? {
        details?.item.timeCreated ?? {
            if case .steam(let item) = subject { return item.timeCreated }
            return nil
        }()
    }

    var updated: Date? {
        details?.item.timeUpdated ?? {
            switch subject {
            case .steam(let item): return item.timeUpdated
            case .local(let wallpaper): return wallpaper.steamMetadata?.remoteUpdatedAt
            }
        }()
    }
}

// MARK: - 视图

/// 标题 / 作者；上方左侧海报（约 60%）右侧信息（约 40%）；下方全宽作者描述。一个垂直滚动区域。
struct WallpaperDetailsView: View {
    @ObservedObject var model: WallpaperDetailsModel
    @Environment(\.locale) private var locale

    static let padding: CGFloat = 28
    static let columnGap: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.section) {
                    header
                    let width = max(0, proxy.size.width - 2 * Self.padding)
                    HStack(alignment: .top, spacing: Self.columnGap) {
                        poster
                            .frame(width: (width - Self.columnGap) * 0.6)
                        information
                            .frame(width: (width - Self.columnGap) * 0.4, alignment: .leading)
                    }
                    Divider().opacity(0.6)
                    descriptionSection
                }
                .padding(Self.padding)
                .frame(width: proxy.size.width, alignment: .leading)
            }
        }
        .frame(minWidth: WallpaperDetailsWindowMetrics.minimumSize.width / 2,
               minHeight: WallpaperDetailsWindowMetrics.minimumSize.height / 2)
        .background(WindowGlassBackground().ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title)
                .font(.system(size: 22, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let author = model.author, !author.isEmpty {
                Text(String(format: NSLocalizedString("details.author", comment: ""), author))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let url = model.posterURL, let artwork = PosterArtworkCache.shared.artwork(for: url) {
            // 规格：Aspect Fit，保留原始内容与比例，不使用网格的 1:1 裁切。
            Image(decorative: artwork.firstFrame, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.container, style: .continuous))
                .accessibilityLabel(Text("details.poster"))
        } else {
            RoundedRectangle(cornerRadius: Tokens.Radius.container, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    Image(systemName: model.subject.type == .video ? "play.rectangle" : "photo")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.compact) {
            switch model.state {
            case .loading:
                HStack(spacing: Tokens.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("details.loading").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                    Text(String(format: NSLocalizedString("details.failed", comment: ""), reason))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("details.retry") { model.retry() }
                        .kineticGlassButton()
                        .controlSize(.small)
                }
            case .noSteamInfo:
                Text("details.noSteamInfo").font(.system(size: 12)).foregroundStyle(.secondary)
            case .idle, .loaded:
                EmptyView()
            }
            ForEach(rows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .font(.system(size: 13))
                        .foregroundStyle(row.isMissing ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private struct Row {
        let label: String
        let value: String
        var isMissing = false
    }

    /// 至少覆盖参考图中的真实字段；缺失显示「暂无信息」，不推测。同组多个标签并列显示。
    private var rows: [Row] {
        let missing = NSLocalizedString("details.missing", comment: "")
        let grouped = SteamTagCatalog.grouped(model.tags)
        var rows: [Row] = []
        let isSteam = model.subject.workshopID != nil
        func tagRow(_ group: SteamTagGroup, always: Bool = true) {
            if let values = grouped[group], !values.isEmpty {
                rows.append(Row(label: group.title, value: values.joined(separator: "、")))
            } else if always {
                rows.append(Row(label: group.title, value: missing, isMissing: true))
            }
        }
        if isSteam {
            tagRow(.miscellaneous)
            if grouped[.type] == nil, let type = model.subject.type {
                rows.append(Row(label: SteamTagGroup.type.title, value: type.localizedName))
            } else {
                tagRow(.type)
            }
            tagRow(.ageRating)
            tagRow(.genre)
            tagRow(.resolution)
            tagRow(.category)
            tagRow(.assetType, always: false)
            tagRow(.assetGenre, always: false)
            tagRow(.scriptType, always: false)
        } else if let type = model.subject.type {
            rows.append(Row(label: SteamTagGroup.type.title, value: type.localizedName))
            if case .local(let wallpaper) = model.subject {
                rows.append(Row(label: NSLocalizedString("details.source", comment: ""),
                                value: NSLocalizedString("shell.tile.source.\(wallpaper.source.rawValue)", comment: "")))
            }
        }
        rows.append(Row(label: NSLocalizedString("details.fileSize", comment: ""),
                        value: model.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? missing,
                        isMissing: model.fileSize == nil))
        if isSteam {
            rows.append(dateRow("details.published", model.published, missing: missing))
            rows.append(dateRow("details.updated", model.updated, missing: missing))
        } else if case .local(let wallpaper) = model.subject {
            rows.append(dateRow("details.imported", wallpaper.importedAt, missing: missing))
        }
        return rows
    }

    private func dateRow(_ key: String, _ date: Date?, missing: String) -> Row {
        Row(label: NSLocalizedString(key, comment: ""),
            value: date.map { $0.formatted(.dateTime.year().month().day().hour().minute().locale(locale)) } ?? missing,
            isMissing: date == nil)
    }

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            Text("details.description.title")
                .font(.system(size: 15, weight: .semibold))
            if let description = model.details?.description {
                Text(SteamDescriptionText.attributed(description))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(LocalizedStringKey(descriptionPlaceholderKey))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var descriptionPlaceholderKey: String {
        switch model.state {
        case .loaded: return "details.description.none"
        case .noSteamInfo: return "details.noSteamInfo"
        case .loading, .idle: return "details.description.loading"
        case .failed: return "details.description.unavailable"
        }
    }
}
