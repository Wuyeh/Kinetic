import XCTest
@testable import Kinetic

final class LocalOrganizationTests: XCTestCase {
    @MainActor
    func testManagedCoverCleanupPreservesSharedCoversOriginalImagesAndWallpaperReferences() throws {
        let root = TestWorkspaceDirectory.make(".build/SidebarDisplayRevision/ListFixtures")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.png")
        try Data("original image".utf8).write(to: source)
        let store = LocalOrganizationStore(storage: .init(rootURL: root))
        let wallpaper = UUID()
        let first = try store.createList(name: "  夜间  ", coverSourceURL: source, wallpaperIDs: [wallpaper])
        let duplicate = try store.duplicateList(first)
        let cover = try XCTUnwrap(store.lists.first?.coverImageURL)
        let second = try store.createList(name: "夜间", wallpaperIDs: [wallpaper])
        XCTAssertNotEqual(first, second); XCTAssertEqual(store.lists.first?.name, "夜间")
        try store.setPinned(true, for: [wallpaper])
        try store.deleteList(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path), "A shared cover still has an owner")
        XCTAssertEqual(store.lists.first { $0.id == duplicate }?.wallpaperIDs, [wallpaper])
        try store.deleteList(duplicate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original image".utf8))
        XCTAssertTrue(store.isPinned(wallpaper))
        XCTAssertEqual(store.lists.first { $0.id == second }?.wallpaperIDs, [wallpaper])
    }

    @MainActor
    func testListCoverReferenceOutsideManagedFolderCannotDeleteSource() throws {
        let root = TestWorkspaceDirectory.make(".build/SidebarDisplayRevision/ListSafetyFixtures")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("wallpaper.png")
        try Data("wallpaper source".utf8).write(to: source)
        let store = LocalOrganizationStore(storage: .init(rootURL: root))
        let id = try store.createList(name: "引用")
        let file = root.appendingPathComponent("organization.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var lists = document["lists"] as! [[String: Any]]
        lists[0]["coverImageURL"] = source.absoluteString; document["lists"] = lists
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let reopened = LocalOrganizationStore(storage: .init(rootURL: root))
        try reopened.deleteList(id)
        XCTAssertEqual(try Data(contentsOf: source), Data("wallpaper source".utf8))
    }
    @MainActor
    func testListsKeepStableReferencesAndPinsWithoutCopyingWallpaperFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticLists-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LibraryStorageLocation(rootURL: root)
        let resource = root.appendingPathComponent("source.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original video".utf8).write(to: resource)
        let first = UUID(), second = UUID()

        let store = LocalOrganizationStore(storage: storage)
        let listID = try store.createList(name: "工作", description: "白天")
        try store.add([first, second, first], to: listID)
        try store.setPinned(true, for: [first])
        let copyID = try store.duplicateList(listID)
        XCTAssertEqual(store.lists.first { $0.id == listID }?.wallpaperIDs, [first, second])
        XCTAssertEqual(store.lists.first { $0.id == copyID }?.wallpaperIDs, [first, second])

        let reopened = LocalOrganizationStore(storage: storage)
        XCTAssertTrue(reopened.isPinned(first))
        XCTAssertEqual(reopened.lists.first { $0.id == listID }?.description, "白天")
        try reopened.deleteList(listID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.path), "Deleting a list cannot delete wallpaper resources")
        XCTAssertEqual(LocalOrganizationStore(storage: storage).lists.map(\.id), [copyID])
        try reopened.removeMissingReferences(validIDs: [second])
        XCTAssertFalse(reopened.isPinned(first))
        XCTAssertEqual(reopened.lists.first?.wallpaperIDs, [second])
    }

    @MainActor
    func testUnreadableOrganizationIsBackedUpBeforeFutureWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KineticListsCorrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ broken json".utf8).write(to: root.appendingPathComponent("organization.json"))
        let store = LocalOrganizationStore(storage: LibraryStorageLocation(rootURL: root))
        XCTAssertTrue(store.lists.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("organization.unreadable-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(backups[0])), Data("{ broken json".utf8))
        _ = try store.createList(name: "恢复后")
        XCTAssertEqual(store.lists.count, 1)
    }
}
