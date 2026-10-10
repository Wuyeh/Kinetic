import AppKit
import XCTest
@testable import Kinetic

@MainActor
private final class BoardTestContent: WidgetContent {
    let displayView = NSView()
    var onFailure: (@MainActor () -> Void)?
    var contexts: [OverlayContext] = []
    var plays = 0, pauses = 0, disposals = 0
    var rejectsUpdates = false
    func update(configuration: WidgetConfiguration, context: OverlayContext) throws {
        if rejectsUpdates { throw WidgetBoardError.invalidLayout }; contexts.append(context)
    }
    func play() { plays += 1 }
    func pause() { pauses += 1 }
    func dispose() { disposals += 1; onFailure = nil }
}

@MainActor
private final class BoardTestSurface: OverlaySurface {
    var views: [UUID: NSView] = [:]
    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws { views[id] = view }
    func remove(_ id: UUID) { views[id] = nil }
    func realign(_ display: DesktopDisplay) {}
    func setOrder(_ ids: [UUID]) {}
    func close() { views = [:] }
}

@MainActor
final class WidgetBoardTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func storage() throws -> LibraryStorageLocation {
        let root = TestWorkspaceDirectory.make(".build/Module37/Fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root); return .init(rootURL: root)
    }
    private func display(_ id: String = "display-A") -> DisplayDescriptor {
        .init(id: .init(id), name: id, desktop: .init(id: 1, frame: .init(x: -5000, y: -5000, width: 640, height: 400), backingScaleFactor: 2), isPersistent: true)
    }
    private func context(paused: Bool = false, width: CGFloat = 640, height: CGFloat = 400) -> OverlayContext {
        .init(frame: .init(x: -4000, y: -4000, width: width, height: height), backingScaleFactor: 2,
              maximumFramesPerSecond: 30, allowsAnimation: true, isPaused: paused)
    }
    private func setup(_ storage: LibraryStorageLocation, discover: @escaping @MainActor () -> [DisplayDescriptor]) -> (OverlayManager, DisplayRegistry, WidgetLayoutRepository, WidgetContentRegistry) {
        let registry = DisplayRegistry(discover: discover); registry.start()
        let repository = WidgetLayoutRepository(storage: storage), contents = WidgetContentRegistry()
        let manager = OverlayManager(store: .init(storage: storage), registry: registry, readReduceMotion: { false }, makeSurface: { _ in BoardTestSurface() })
        manager.register(.widgets) { _ in WidgetBoardOverlay(repository: repository, registry: contents) }; manager.start()
        return (manager, registry, repository, contents)
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() { guard ProcessInfo.processInfo.systemUptime < deadline else { throw WidgetBoardError.invalidLayout }; try await Task.sleep(nanoseconds: 5_000_000) }
    }
    private func configuration(_ revision: UUID, display: String = "display-A") throws -> OverlayConfiguration {
        var value = OverlayConfiguration(kind: .widgets, displayID: .init(display)); value.isEnabled = true
        return try WidgetBoardReference.applying(revision, to: value)
    }

    func testDefaultHasNoFilesWindowsWidgetsOrProviders() throws {
        let storage = try storage(), a = display(), (manager, registry, repository, contents) = setup(storage, discover: { [a] })
        defer { manager.shutdown(); registry.stop() }
        let model = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
        XCTAssertTrue(manager.states.isEmpty); XCTAssertTrue(model.edits.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.store.fileURL.path))
        XCTAssertNil(try contents.make(.init(kind: .cpu)))
    }
    func testLayoutValidationRejectsInvalidGeometryDuplicateIDsFutureAndOversize() throws {
        var widget = WidgetConfiguration(kind: .cpu)
        for scale in [Double.nan, .infinity, 0.49, 2.01] { widget.scale = scale; XCTAssertThrowsError(try widget.validated()) }
        widget.scale = 1; widget.position.x = -0.01; XCTAssertThrowsError(try widget.validated())
        widget.position.x = 0; widget.opacity = 0; XCTAssertThrowsError(try widget.validated())
        widget.opacity = 1; widget.customTitle = "invalid\n"; XCTAssertThrowsError(try widget.validated())
        widget.customTitle = ""; let layout = WidgetBoardLayout(widgets: [widget])
        XCTAssertEqual(try WidgetBoardLayout.decode(layout.encoded()), layout)
        XCTAssertThrowsError(try WidgetBoardLayout(widgets: [widget, widget]).validated())
        XCTAssertThrowsError(try WidgetBoardLayout(version: 2).validated())
        XCTAssertThrowsError(try WidgetBoardLayout(widgets: (0..<33).map { _ in .init(kind: .memory) }).validated())
        XCTAssertThrowsError(try WidgetBoardLayout.decode(Data(repeating: 0, count: WidgetBoardLayout.maximumBytes + 1)))
    }
    func testGridSnapsEverySizeToCellsWithoutOverlapAndStaysOnScreenAtEveryResolution() throws {
        XCTAssertEqual(WidgetSize.small.dimensions, .init(width: 160, height: 160))
        XCTAssertEqual(WidgetSize.medium.dimensions, .init(width: 336, height: 160))
        XCTAssertEqual(WidgetSize.large.dimensions, .init(width: 336, height: 336))
        let metrics = try XCTUnwrap(WidgetGrid.Metrics(canvas: .init(width: 1512, height: 982)))
        XCTAssertEqual(metrics.columns, 8); XCTAssertEqual(metrics.rows, 5)
        XCTAssertEqual(metrics.origin.x, 1512 - metrics.origin.x - CGFloat(8) * WidgetGrid.pitch + WidgetGrid.spacing, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(metrics.origin.y, WidgetGrid.topInset)
        // Every widget asks for the same corner: they are laid out side by side, never on top of each other.
        var widgets: [WidgetConfiguration] = []
        for (index, size) in [WidgetSize.large, .medium, .small, .small, .medium, .large].enumerated() {
            var widget = WidgetConfiguration(kind: .cpu); widget.size = size; widget.scale = index.isMultiple(of: 2) ? 2 : 0.5; widgets.append(widget)
        }
        for canvas in [CGSize(width: 1512, height: 982), .init(width: 1920, height: 1080), .init(width: 2560, height: 1440), .init(width: 1024, height: 768)] {
            let frames = WidgetGrid.frames(widgets, in: canvas)
            XCTAssertEqual(frames.count, widgets.count)
            for widget in widgets {
                let frame = try XCTUnwrap(frames[widget.id])
                XCTAssertEqual(frame.size, widget.size.dimensions) // the retired scale no longer resizes a tile
                XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, canvas.width)
                XCTAssertGreaterThanOrEqual(frame.minY, WidgetGrid.topInset); XCTAssertLessThanOrEqual(frame.maxY, canvas.height)
                for other in widgets where other.id != widget.id { XCTAssertFalse(frame.intersects(try XCTUnwrap(frames[other.id]))) }
            }
            // Stored positions become exact cells; arranging the normalized layout again changes nothing.
            let normalized = WidgetGrid.normalized(.init(widgets: widgets), in: canvas)
            XCTAssertTrue(normalized.widgets.allSatisfy { $0.scale == 1 })
            XCTAssertEqual(WidgetGrid.frames(normalized.widgets, in: canvas), frames)
            XCTAssertEqual(WidgetGrid.normalized(normalized, in: canvas), normalized)
        }
        XCTAssertNil(WidgetGrid.Metrics(canvas: .init(width: CGFloat.nan, height: 500)))
        XCTAssertNil(WidgetGrid.Metrics(canvas: .init(width: 100, height: 60)))
        XCTAssertTrue(WidgetGrid.frames(widgets, in: .init(width: 100, height: 60)).isEmpty)
    }
    func testDropLandsOnNearestFreeCellAddFillsLeadingColumnAndFullGridHidesInsteadOfOverlapping() throws {
        let canvas = CGSize(width: 1512, height: 982), metrics = try XCTUnwrap(WidgetGrid.Metrics(canvas: canvas))
        var layout = WidgetBoardLayout()
        for _ in 0..<3 {
            var widget = WidgetConfiguration(kind: .memory)
            widget.position = try XCTUnwrap(WidgetGrid.firstFree(.small, in: layout, canvas: canvas)); layout.widgets.append(widget)
        }
        let cells = WidgetGrid.arrange(layout.widgets, in: metrics)
        XCTAssertEqual(layout.widgets.map { cells[$0.id] }, [.init(column: 0, row: 0), .init(column: 0, row: 1), .init(column: 0, row: 2)])
        // Dropped half a cell from (3, 1): snaps there. Dropped onto a taken cell: the closest free one.
        let first = layout.widgets[0].id, near = metrics.frame(.init(column: 3, row: 1), .small).origin
        let cell = try XCTUnwrap(WidgetGrid.dropCell(for: first, at: .init(x: near.x + 60, y: near.y - 50), in: layout, canvas: canvas))
        XCTAssertEqual(cell, .init(column: 3, row: 1))
        let moved = WidgetGrid.placing(first, at: cell, in: layout, canvas: canvas)
        XCTAssertEqual(WidgetGrid.arrange(moved.widgets, in: metrics)[first], cell)
        XCTAssertEqual(moved.widgets.map(\.id), layout.widgets.map(\.id))
        let taken = metrics.frame(.init(column: 0, row: 1), .small).origin
        let landed = try XCTUnwrap(WidgetGrid.dropCell(for: first, at: taken, in: moved, canvas: canvas))
        XCTAssertNotEqual(landed, .init(column: 0, row: 1)); XCTAssertEqual(abs(landed.column) + abs(landed.row - 1), 1)
        // A full grid has no room for another widget; an extra stored widget is left out rather than overlapping.
        var full = WidgetBoardLayout()
        for _ in 0..<(metrics.columns * metrics.rows) {
            var widget = WidgetConfiguration(kind: .cpu); widget.position = try XCTUnwrap(WidgetGrid.firstFree(.small, in: full, canvas: canvas))
            full.widgets.append(widget)
        }
        XCTAssertNil(WidgetGrid.firstFree(.small, in: full, canvas: canvas))
        full.widgets[0].size = .large
        let frames = WidgetGrid.frames(full.widgets, in: canvas)
        XCTAssertLessThan(frames.count, full.widgets.count)
        let shown = Array(frames.values)
        for (index, frame) in shown.enumerated() { for other in shown[(index + 1)...] { XCTAssertFalse(frame.intersects(other)) } }
    }
    func testReferenceValidatesIdentityVersionAndPreservesPauseFPS() throws {
        let id = UUID(); var value = try configuration(id); value.isManuallyPaused = true; value.maximumFramesPerSecond = 12
        let next = try WidgetBoardReference.applying(UUID(), to: value)
        XCTAssertEqual(next.id, value.id); XCTAssertTrue(next.isManuallyPaused); XCTAssertEqual(next.maximumFramesPerSecond, 12)
        XCTAssertEqual(try WidgetBoardReference(configuration: value).layoutID, id)
        value.parameters["widgetVersion"] = .number(2); XCTAssertThrowsError(try WidgetBoardReference(configuration: value))
        value = try configuration(id); value.displayID = .main; XCTAssertThrowsError(try WidgetBoardReference(configuration: value))
    }
    func testImmutablePersistencePrunesOnlyUnreferencedValidFilesAndBoundsCache() throws {
        let repository = WidgetLayoutRepository(storage: try storage()), layout = WidgetBoardLayout(widgets: [.init(kind: .cpu)])
        var refs = Set<UUID>()
        for _ in 0..<12 { refs.insert(try repository.write(layout, keeping: refs)) }
        XCTAssertLessThanOrEqual(repository.cachedLayoutCount, 8)
        for id in refs { XCTAssertEqual(try repository.load(id), layout) }
        let future = repository.url(for: UUID()), bytes = Data(#"{"version":2,"widgets":[]}"#.utf8); try bytes.write(to: future)
        let corrupt = repository.url(for: UUID()); try Data("bad".utf8).write(to: corrupt)
        let keep = try XCTUnwrap(refs.first); repository.prune(keeping: [keep])
        XCTAssertEqual(try Data(contentsOf: future), bytes); XCTAssertEqual(try Data(contentsOf: corrupt), Data("bad".utf8))
        XCTAssertEqual(try repository.load(keep), layout)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.directory.path).count, 3)
        var futureReference = try configuration(keep)
        futureReference.parameters["widgetVersion"] = .number(2)
        repository.prune(keeping: WidgetLayoutRepository.references(in: [futureReference]))
        XCTAssertEqual(try repository.load(keep), layout)
        for _ in 0..<140 {
            let id = try repository.write(layout, keeping: [keep]); repository.prune(keeping: [keep, id])
        }
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: repository.directory.path).count, 4)
    }
    func testPayloadSymlinkRootSymlinkAndCorruptFileNeverOverwriteTargets() throws {
        let storage = try storage(), repository = WidgetLayoutRepository(storage: storage), layout = WidgetBoardLayout(widgets: [.init(kind: .cpu)])
        let id = try repository.write(layout, keeping: []), bytes = Data("keep".utf8)
        let target = storage.rootURL.appendingPathComponent("target"); try bytes.write(to: target)
        let link = repository.url(for: UUID()); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try repository.load(UUID(uuidString: link.deletingPathExtension().lastPathComponent)!))
        repository.prune(keeping: [id]); XCTAssertEqual(try Data(contentsOf: target), bytes)
        try Data("bad".utf8).write(to: repository.url(for: id)); XCTAssertThrowsError(try repository.load(id))
        let second = try self.storage(), linked = WidgetLayoutRepository(storage: second)
        try FileManager.default.createSymbolicLink(at: linked.directory, withDestinationURL: repository.directory)
        XCTAssertThrowsError(try linked.write(layout, keeping: [])); XCTAssertEqual(try Data(contentsOf: repository.url(for: id)), Data("bad".utf8))
    }
    func testDraftAddRemoveResizeDragAndCloseHaveNoDesktopOrStorageSideEffects() throws {
        let storage = try storage(), a = display(), (manager, registry, repository, contents) = setup(storage, discover: { [a] })
        defer { manager.shutdown(); registry.stop() }
        let model = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
        model.opened(); defer { model.closed() }
        model.add(.cpu); let id = try XCTUnwrap(model.selectedWidgetID); model.editSelected { $0.size = .medium; $0.opacity = 0.7 }
        XCTAssertEqual(model.selectedWidget?.size, .medium); XCTAssertTrue(model.isDirty(on: a.id))
        let canvas = model.canvasSize(on: a.id), metrics = try XCTUnwrap(WidgetGrid.Metrics(canvas: canvas))
        model.drop(id, at: metrics.frame(.init(column: 1, row: 1), .medium).origin, on: a.id)
        XCTAssertEqual(WidgetGrid.arrange(model.layout.widgets, in: metrics)[id], .init(column: 1, row: 1))
        XCTAssertGreaterThan(try XCTUnwrap(model.selectedWidget).position.x, 0)
        XCTAssertTrue(manager.states.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: manager.store.fileURL.path))
        // Closing the window keeps the draft: the display page still shows it until 应用.
        model.closed(); model.opened(); XCTAssertEqual(model.layout.widgets.map(\.id), [id])
        model.removeSelected(); XCTAssertTrue(model.layout.widgets.isEmpty); XCTAssertFalse(model.isDirty(on: a.id)); XCTAssertFalse(model.isEnabled)
    }
    func testSaveReloadPersistsTargetAndImportIsDraftWithoutEnabling() async throws {
        let storage = try storage(), a = display(), b = display("display-B"), (manager, registry, repository, contents) = setup(storage, discover: { [a, b] })
        defer { manager.shutdown(); registry.stop() }
        let model = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
        model.opened(); defer { model.closed() }; model.selectDisplay(b.id); model.add(.memory); model.isEnabled = true; model.save()
        try await wait { manager.states.first?.lifecycle == .running }
        XCTAssertEqual(manager.states.first?.displayID, b.id); XCTAssertEqual(manager.states.count, 1)
        let old = try Data(contentsOf: manager.store.fileURL), saved = try XCTUnwrap(model.savedConfiguration)
        XCTAssertEqual(try repository.load(WidgetBoardReference(configuration: saved).layoutID), model.layout)
        model.selectDisplay(a.id); XCTAssertFalse(model.isEnabled)
        let archive = try WidgetBoardLayout(widgets: [.init(kind: .weather)]).encoded(); model.importLayout(archive)
        XCTAssertFalse(model.isEnabled); XCTAssertEqual(model.layout.widgets.first?.kind, .weather)
        XCTAssertEqual(try Data(contentsOf: manager.store.fileURL), old); XCTAssertEqual(manager.states.count, 1)
        // The imported draft stays unapplied for display A; B keeps its saved layout.
        model.closed(); model.opened(); XCTAssertEqual(model.layout.widgets.first?.kind, .weather); XCTAssertTrue(model.isDirty(on: a.id))
        model.selectDisplay(b.id); XCTAssertEqual(model.layout.widgets.first?.kind, .memory); XCTAssertTrue(model.isEnabled)
        XCTAssertFalse(model.isDirty(on: b.id))
    }
    func testFailedAtomicReferenceCommitKeepsOldBytesAndRemovesCandidate() throws {
        let storage = try storage(), a = display(), (manager, registry, repository, contents) = setup(storage, discover: { [a] })
        defer { manager.shutdown(); registry.stop() }
        let model = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
        model.opened(); defer { model.closed() }; model.add(.cpu); model.save()
        let saved = try XCTUnwrap(model.savedConfiguration), id = try WidgetBoardReference(configuration: saved).layoutID
        let old = try Data(contentsOf: repository.url(for: id)); let original = try Data(contentsOf: manager.store.fileURL)
        let target = storage.rootURL.appendingPathComponent("untouched"); try original.write(to: target)
        try FileManager.default.removeItem(at: manager.store.fileURL); try FileManager.default.createSymbolicLink(at: manager.store.fileURL, withDestinationURL: target)
        model.editSelected { $0.opacity = 0.5 }; model.save()
        XCTAssertNotNil(model.error); XCTAssertEqual(model.savedConfiguration, saved)
        XCTAssertEqual(try Data(contentsOf: repository.url(for: id)), old); XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.directory.path).count, 1)
    }
    func testMalformedImportDoesNotReplaceDraftAndArchiveOmitsDisplayAndPlayback() throws {
        let storage = try storage(), a = display(), (manager, registry, repository, contents) = setup(storage, discover: { [a] })
        defer { manager.shutdown(); registry.stop() }
        let model = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
        model.opened(); defer { model.closed() }; model.add(.cpu); let old = model.layout
        model.importLayout(Data("bad".utf8)); XCTAssertEqual(model.layout, old); XCTAssertNotNil(model.error)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: model.exportLayout()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "widgets"]); XCTAssertNil(json["displayID"]); XCTAssertNil(json["isEnabled"])
    }
    func testProviderUpdateKeepsIdentityPauseFPSReduceMotionAndIndividualFailureIsolation() throws {
        let repository = WidgetLayoutRepository(storage: try storage()), contents = WidgetContentRegistry()
        var providers: [BoardTestContent] = []
        contents.register(.cpu) { _ in let p = BoardTestContent(); providers.append(p); return p }
        let overlay = WidgetBoardOverlay(repository: repository, registry: contents); defer { overlay.dispose() }
        var layout = WidgetBoardLayout(widgets: [.init(kind: .cpu), .init(kind: .cpu)]), ctx = context()
        try overlay.updatePreview(layout: layout, context: ctx); overlay.play(); let identity = overlay.contentIdentity(layout.widgets[0].id)
        layout.widgets[0].scale = 1.2; layout.widgets[0].position.x = 0.4; try overlay.updatePreview(layout: layout, context: ctx)
        XCTAssertEqual(overlay.contentIdentity(layout.widgets[0].id), identity); XCTAssertEqual(providers.count, 2)
        overlay.pause(); ctx.isPaused = true; ctx.allowsAnimation = false; ctx.maximumFramesPerSecond = 15
        try overlay.updatePreview(layout: layout, context: ctx); overlay.play()
        XCTAssertFalse(overlay.isPlaying); XCTAssertEqual(providers[0].contexts.last?.maximumFramesPerSecond, 15)
        XCTAssertEqual(providers[0].contexts.last?.allowsAnimation, false); XCTAssertEqual(providers[0].contexts.last?.isPaused, true)
        ctx.isPaused = false; try overlay.updatePreview(layout: layout, context: ctx); overlay.play()
        providers[0].onFailure?(); XCTAssertEqual(providers[0].disposals, 1)
        XCTAssertNotNil(overlay.contentIdentity(layout.widgets[1].id)); XCTAssertEqual(providers[1].disposals, 0)
        XCTAssertFalse(overlay.view.isOpaque); XCTAssertNil(overlay.view.hitTest(.zero))
    }
    func testInvalidLiveRevisionPreservesOldLayoutAndFrame() async throws {
        let repository = WidgetLayoutRepository(storage: try storage()), contents = WidgetContentRegistry()
        let oldLayout = WidgetBoardLayout(widgets: [.init(kind: .cpu)]), id = try repository.write(oldLayout, keeping: [])
        let overlay = WidgetBoardOverlay(repository: repository, registry: contents); defer { overlay.dispose() }
        try await overlay.prepare(configuration: configuration(id), context: context()); overlay.play()
        let frame = overlay.widgetFrame(oldLayout.widgets[0].id)
        XCTAssertThrowsError(try overlay.update(configuration: configuration(UUID()), context: context()))
        XCTAssertEqual(overlay.layout, oldLayout); XCTAssertEqual(overlay.widgetFrame(oldLayout.widgets[0].id), frame); XCTAssertTrue(overlay.isPlaying)
    }
    func testDisconnectedAssignmentNeverFallsBackAndCanDisableWithoutRetargeting() async throws {
        let storage = try storage(), a = display(), b = display("display-B"); var connected = [a, b]
        let (manager, registry, repository, contents) = setup(storage, discover: { connected })
        defer { manager.shutdown(); registry.stop() }
        let model = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
        model.opened(); defer { model.closed() }; model.selectDisplay(a.id); model.add(.cpu); model.isEnabled = true; model.save()
        try await wait { manager.states.first?.lifecycle == .running }; let id = try XCTUnwrap(model.savedConfiguration).id
        connected = [b]; registry.refresh(); XCTAssertEqual(model.selectedDisplayID, a.id); XCTAssertFalse(model.canSave)
        XCTAssertEqual(manager.states.first?.lifecycle, .waitingForDisplay); XCTAssertEqual(manager.states.first?.displayID, a.id)
        model.isEnabled = false; XCTAssertTrue(model.canSave); model.save(); XCTAssertEqual(model.savedConfiguration?.id, id)
        XCTAssertEqual(model.savedConfiguration?.displayID, a.id); XCTAssertEqual(manager.states.first?.lifecycle, .disabled)
        connected = [a, b]; registry.refresh(); XCTAssertEqual(manager.states.first?.lifecycle, .disabled)
    }
    func testRemoveLastWidgetAndFortyDisposalsReleaseProviderAndTileViews() async throws {
        let repository = WidgetLayoutRepository(storage: try storage()), contents = WidgetContentRegistry()
        for _ in 0..<40 {
            weak var provider: BoardTestContent?, weakOverlay: WidgetBoardOverlay?
            contents.register(.cpu) { _ in let p = BoardTestContent(); provider = p; return p }
            do {
                let overlay = WidgetBoardOverlay(repository: repository, registry: contents); weakOverlay = overlay
                try overlay.updatePreview(layout: .init(widgets: [.init(kind: .cpu)]), context: context()); overlay.play()
                XCTAssertNotNil(provider); try overlay.updatePreview(layout: .init(), context: context())
                XCTAssertTrue(overlay.view.subviews.isEmpty); overlay.dispose(); overlay.dispose()
            }
            try await Task.sleep(nanoseconds: 5_000_000); XCTAssertNil(provider); XCTAssertNil(weakOverlay)
        }
    }
    func testDisplayPageApplyAndDesktopTilesAboveIconsPersistMoveResizeRemove() async throws {
        let storage = try storage(), a = display(), (manager, registry, repository, contents) = setup(storage, discover: { [a] })
        defer { manager.shutdown(); registry.stop() }
        contents.register(.cpu) { _ in BoardTestContent() }
        let model = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
        // Added from the display page's side: a draft only, until 应用.
        model.add(.cpu, on: a.id); model.add(.memory, on: a.id)
        XCTAssertTrue(model.canApply(on: a.id)); XCTAssertTrue(manager.states.isEmpty); XCTAssertNil(model.selectedDisplayID)
        model.selectDisplay(a.id); model.isEnabled = true; model.apply(on: a.id)
        XCTAssertFalse(model.isDirty(on: a.id)); XCTAssertNil(model.applyErrors[a.id])
        try await wait { manager.states.first?.lifecycle == .running }
        let saved = model.saved(on: a.id).draft.layout, cpu = saved.widgets[0].id, memory = saved.widgets[1].id
        // An unapplied draft change for the same display survives desktop edits.
        model.edit(memory, on: a.id) { $0.opacity = 0.5 }; XCTAssertTrue(model.isDirty(on: a.id))
        let canvas = model.canvasSize(on: a.id), metrics = try XCTUnwrap(WidgetGrid.Metrics(canvas: canvas))
        model.desktopWidget(cpu, movedTo: .init(column: 2, row: 1), on: a.id)
        XCTAssertEqual(WidgetGrid.arrange(model.saved(on: a.id).draft.layout.widgets, in: metrics)[cpu], .init(column: 2, row: 1))
        XCTAssertEqual(WidgetGrid.arrange(model.draft(on: a.id).layout.widgets, in: metrics)[cpu], .init(column: 2, row: 1))
        XCTAssertEqual(model.draft(on: a.id).layout.widgets.first { $0.id == memory }?.opacity, 0.5)
        model.desktopWidget(cpu, resizedTo: .large, on: a.id)
        XCTAssertEqual(model.saved(on: a.id).draft.layout.widgets.first { $0.id == cpu }?.size, .large)
        model.desktopWidgetRemoved(memory, on: a.id)
        XCTAssertEqual(model.saved(on: a.id).draft.layout.widgets.map(\.id), [cpu]); XCTAssertEqual(model.draft(on: a.id).layout.widgets.map(\.id), [cpu])
        var requested: (DisplayID, UUID)?
        model.onEditRequest = { requested = ($0, $1) }; model.desktopWidgetEdit(cpu, on: a.id)
        XCTAssertEqual(requested?.0, a.id); XCTAssertEqual(requested?.1, cpu)

        // Desktop tiles: one small window each, just above Finder's desktop icons, at the grid frame.
        let tiles = WidgetDesktopTiles(displayID: a.id, editor: model)
        let overlay = WidgetBoardOverlay(repository: repository, registry: contents, desktop: tiles); defer { overlay.dispose() }
        let frame = CGRect(x: -6000, y: -6000, width: 1512, height: 982)
        try overlay.updatePreview(layout: model.saved(on: a.id).draft.layout, context: context(width: frame.width, height: frame.height).with(frame))
        let panel = try XCTUnwrap(tiles.panel(cpu))
        XCTAssertEqual(panel.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        let grid = try XCTUnwrap(WidgetGrid.frames(model.saved(on: a.id).draft.layout.widgets, in: frame.size)[cpu])
        XCTAssertEqual(panel.frame, CGRect(x: frame.minX + grid.minX, y: frame.maxY - grid.maxY, width: grid.width, height: grid.height))
        XCTAssertTrue(overlay.view.subviews.isEmpty) // nothing drawn in the shared overlay window below the icons
        overlay.dispose(); XCTAssertTrue(tiles.panelIDs.isEmpty); XCTAssertFalse(panel.isVisible)
    }
    func testNativeEditorAndDisplayPagePreviewLightDark() async throws {
        let folder = TestWorkspaceDirectory.make(".build/Module37/Snapshots").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = NSApp.appearance; defer { NSApp.appearance = original }
        XCTAssertEqual(NSLocalizedString("widgets.notConnected", comment: ""), "数据源尚未接入")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let storage = try storage(), a = display(), (manager, registry, repository, contents) = setup(storage, discover: { [a] })
            defer { manager.shutdown(); registry.stop() }
            NSApp.appearance = NSAppearance(named: appearance)
            let model = WidgetBoardEditorModel(manager: manager, registry: registry, repository: repository, contents: contents)
            let owner = WidgetBoardWindow(model: model), window = owner.show(activate: false)
            window.setFrameOrigin(.init(x: -5000, y: -5000)); window.appearance = NSAppearance(named: appearance)
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView)); XCTAssertEqual(window.titleVisibility, .hidden)
            model.add(.cpu); model.add(.weather); model.editSelected { $0.size = .medium }; model.isEnabled = true; model.save()
            try await wait { manager.states.first?.lifecycle == .running }
            let host = try XCTUnwrap(window.contentView); host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("board-\(name).png"))
            XCTAssertGreaterThanOrEqual(host.bounds.width, 330)
            // The display page draws the same board at the display's size; tiles sit on grid frames.
            let page = DisplayWidgetPreview()
            page.update(model, layout: model.draft(on: a.id).layout, context: model.previewContext(on: a.id, visible: true), floating: [:])
            let preview = try XCTUnwrap(page.overlay)
            let frames = WidgetGrid.frames(model.layout.widgets, in: model.canvasSize(on: a.id))
            for widget in model.layout.widgets { XCTAssertEqual(preview.widgetFrame(widget.id), frames[widget.id]) }
            page.pause(); XCTAssertFalse(preview.isPlaying)
            page.stop(); XCTAssertTrue(preview.isDisposed); XCTAssertNil(page.overlay)
            owner.close(); XCTAssertNil(owner.window)
            XCTAssertEqual(manager.states.first?.lifecycle, .running)
        }
    }
}

private extension OverlayContext {
    func with(_ frame: CGRect) -> OverlayContext { var value = self; value.frame = frame; return value }
}
