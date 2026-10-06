import XCTest
@testable import Kinetic

final class LocalOrganizationTests: XCTestCase {
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
