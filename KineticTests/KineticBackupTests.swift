import SwiftUI
import XCTest
@testable import Kinetic

@MainActor
final class KineticBackupTests: XCTestCase {
    private var root: URL!
    private var storage: LibraryStorageLocation!
    private var defaults: UserDefaults!
    private var suite = ""
    private let layoutID = UUID(), strayLayoutID = UUID(), coverID = UUID()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Backup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = LibraryStorageLocation(rootURL: root)
        suite = "Kinetic.Backup.Tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A small library: configuration, a referenced and a stray widget layout, a list cover, media and caches.
    private func seed() throws {
        try write(#"{"format":2,"wallpapers":[]}"#, "library.json")
        let cover = root.appendingPathComponent("ListCovers/\(coverID.uuidString).png")
        let organization = OrganizationFixture(lists: [WallpaperList(id: UUID(), name: "夜间", description: nil, coverImageURL: cover,
                                                                      wallpaperIDs: [], createdAt: Date(), updatedAt: Date())])
        try FileManager.default.createDirectory(at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(organization).write(to: root.appendingPathComponent("organization.json"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: cover)
        let overlays = OverlayFixture(configurations: [OverlayConfiguration(kind: .widgets, displayID: DisplayID("display-A"), isEnabled: true,
            parameters: ["widgetLayout": .text(layoutID.uuidString), "widgetVersion": .number(1)])])
        try JSONEncoder().encode(overlays).write(to: root.appendingPathComponent("overlays.json"))
        try write(#"{"version":1,"widgets":[]}"#, "WidgetBoardLayouts/\(layoutID.uuidString).json")
        try write(#"{"version":1,"widgets":[]}"#, "WidgetBoardLayouts/\(strayLayoutID.uuidString).json")
        try write(#"{"version":1,"bookmarks":[]}"#, "bookmarks.json")
        try write("media", "Wallpapers/a/video.mp4")
        try write("{}", "lyrics-cache.json")
        try write("{}", "library.unreadable-1.json")
        var settings = SettingsState(); settings.appearance = .dark
        defaults.set(try JSONEncoder().encode(settings), forKey: SettingsStore.storageKey)
        let assignments = DisplayAssignmentDocument(assignments: [:], hasMigratedLegacy: true)
        defaults.set([root.path: try JSONEncoder().encode(assignments), "/other/library": Data("other".utf8)],
                     forKey: DisplayAssignmentStore.storageKey)
    }

    func testABackupHoldsConfigurationButNoMediaCachesOrUnreferencedFiles() throws {
        try seed()
        let backup = try KineticBackupService.make(storage: storage, defaults: defaults, appVersion: "1.0")
        XCTAssertEqual(Set(backup.files.keys), ["library.json", "organization.json", "overlays.json", "bookmarks.json",
                                                "WidgetBoardLayouts/\(layoutID.uuidString).json", "ListCovers/\(coverID.uuidString).png"])
        XCTAssertNotNil(backup.settings)
        XCTAssertNotNil(try JSONDecoder().decode(DisplayAssignmentDocument.self, from: XCTUnwrap(backup.displayAssignments)))
        let decoded = try KineticBackupService.decode(KineticBackupService.encode(backup))
        XCTAssertEqual(decoded.files, backup.files)
        XCTAssertEqual(decoded.version, 1)
    }

    func testForeignNewerOrUnsafeBackupsAreRejected() throws {
        XCTAssertThrowsError(try KineticBackupService.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? KineticBackupError, .unreadable) }
        XCTAssertThrowsError(try KineticBackupService.decode(Data(#"{"format":"other","version":1}"#.utf8))) {
            XCTAssertEqual($0 as? KineticBackupError, .wrongFormat)
        }
        XCTAssertThrowsError(try KineticBackupService.decode(Data(#"{"format":"com.kinetic.backup","version":2}"#.utf8))) {
            XCTAssertEqual($0 as? KineticBackupError, .newerVersion)
        }
        for path in ["../library.json", "Wallpapers/a.mp4", "ListCovers/../../x.png", "WidgetBoardLayouts/x.json", "lyrics-cache.json",
                     "ListCovers/\(UUID().uuidString).png/extra"] {
            var backup = KineticBackup(createdAt: Date(), appVersion: "1.0")
            backup.files[path] = Data("{}".utf8)
            XCTAssertThrowsError(try KineticBackupService.decode(KineticBackupService.encode(backup)), path)
        }
        var broken = KineticBackup(createdAt: Date(), appVersion: "1.0")
        broken.files["schedule.json"] = Data("{".utf8)
        XCTAssertThrowsError(try KineticBackupService.decode(KineticBackupService.encode(broken))) {
            XCTAssertEqual($0 as? KineticBackupError, .invalidEntry("schedule.json"))
        }
    }

    func testRestoringWaitsForLaunchThenReplacesConfigurationAndKeepsTheOldCopy() throws {
        try seed()
        let backup = try KineticBackupService.make(storage: storage, defaults: defaults, appVersion: "1.0")
        // Later changes that the restore must undo.
        try write(#"{"format":2,"wallpapers":["changed"]}"#, "library.json")
        try write(#"{"version":1,"displays":{}}"#, "schedule.json")
        var changed = SettingsState(); changed.appearance = .light
        defaults.set(try JSONEncoder().encode(changed), forKey: SettingsStore.storageKey)

        try KineticBackupService.stageRestore(backup, in: storage)
        XCTAssertNotNil(KineticBackupService.pendingRestore(in: storage))
        XCTAssertEqual(read("library.json"), #"{"format":2,"wallpapers":["changed"]}"#, "nothing changes until launch")

        let restored = try KineticBackupService.applyPendingRestore(in: storage, defaults: defaults)
        XCTAssertNotNil(restored)
        XCTAssertEqual(read("library.json"), #"{"format":2,"wallpapers":[]}"#)
        XCTAssertNil(read("schedule.json"), "files the backup did not have are set aside")
        XCTAssertEqual(try JSONDecoder().decode(SettingsState.self, from: XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))).appearance, .dark)
        XCTAssertNil(KineticBackupService.pendingRestore(in: storage))
        XCTAssertEqual(read("Wallpapers/a/video.mp4"), "media", "wallpaper files are never touched")
        let safety = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("RestoreSafety").path)
        XCTAssertEqual(safety.count, 1)
        let kept = "RestoreSafety/\(safety[0])/"
        XCTAssertEqual(read(kept + "library.json"), #"{"format":2,"wallpapers":["changed"]}"#)
        XCTAssertNotNil(read(kept + "schedule.json"))
        XCTAssertEqual(try JSONDecoder().decode(SettingsState.self, from: Data(XCTUnwrap(read(kept + "settings.json")).utf8)).appearance, .light)
        let entries = try XCTUnwrap(defaults.dictionary(forKey: DisplayAssignmentStore.storageKey))
        XCTAssertEqual(entries["/other/library"] as? Data, Data("other".utf8), "other libraries' assignments are kept")
        XCTAssertNil(try KineticBackupService.applyPendingRestore(in: storage, defaults: defaults), "nothing left to apply")
    }

    func testAFailedRestorePutsTheConfigurationBackAndDropsTheStagedCopy() throws {
        try seed()
        let backup = try KineticBackupService.make(storage: storage, defaults: defaults, appVersion: "1.0")
        try write(#"{"format":2,"wallpapers":["today"]}"#, "library.json")
        try KineticBackupService.stageRestore(backup, in: storage)
        // A plain file where the cover folder should be makes writing the backup's cover fail.
        try FileManager.default.removeItem(at: root.appendingPathComponent("ListCovers"))
        try write("not a folder", "ListCovers")
        XCTAssertThrowsError(try KineticBackupService.applyPendingRestore(in: storage, defaults: defaults))
        XCTAssertEqual(read("library.json"), #"{"format":2,"wallpapers":["today"]}"#)
        XCTAssertNil(KineticBackupService.pendingRestore(in: storage))
        XCTAssertEqual(try JSONDecoder().decode(SettingsState.self, from: XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))).appearance, .dark)
    }

    func testOnlyTheLatestThreeSafetyCopiesAreKept() throws {
        try seed()
        let backup = try KineticBackupService.make(storage: storage, defaults: defaults, appVersion: "1.0")
        for day in 1...5 {
            try KineticBackupService.stageRestore(backup, in: storage)
            try KineticBackupService.applyPendingRestore(in: storage, defaults: defaults,
                                                         now: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400))
        }
        let safety = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("RestoreSafety").path)
        XCTAssertEqual(safety.count, 3)
    }

    /// Offscreen PNGs of Settings › 通用 › 备份与恢复 with a restore waiting for the next launch.
    func testBackupSectionSnapshots() throws {
        try seed()
        try KineticBackupService.stageRestore(KineticBackupService.make(storage: storage, defaults: defaults, appVersion: "1.0"), in: storage)
        let view = BackupSettingsSection(storage: storage).frame(width: 540, alignment: .leading).padding(28)
        try R4SnapshotTests.render(view, size: CGSize(width: 600, height: 220), name: "module50-backup")
        try R4SnapshotTests.render(view, size: CGSize(width: 600, height: 220), name: "module50-backup-dark", appearance: .darkAqua)
    }

    func testSettingsReplaceKeepsEverythingInOneStep() {
        let store = SettingsStore(defaults: defaults)
        var value = SettingsState(); value.appearance = .dark; value.webMouseInteractionPaused = true
        store.replace(with: value)
        XCTAssertEqual(store.state, value)
        XCTAssertEqual(SettingsStore(defaults: defaults).state.appearance, .dark)
    }
}

private struct OrganizationFixture: Codable { var version = 1; var pinnedIDs: [UUID] = []; var lists: [WallpaperList] }
private struct OverlayFixture: Codable { var version = 1; var configurations: [OverlayConfiguration] }
