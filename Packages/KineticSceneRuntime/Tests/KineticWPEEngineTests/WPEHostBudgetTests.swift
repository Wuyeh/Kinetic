import Metal
import XCTest
@testable import KineticWPEEngine

final class WPEHostBudgetTests: XCTestCase {
    private func descriptor(_ edge: Int = 4) -> MTLTextureDescriptor {
        .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: edge, height: edge, mipmapped: false)
    }
    func testExternalFrameAndLiveTextureCannotOversubscribe() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let budget = WPEHostTextureBudget(maximumBytes: 128, maximumEdge: 8)
        try budget.setExternalBytes(64)
        let texture = try budget.makeTexture(device: device, descriptor: descriptor())
        XCTAssertEqual(budget.residentBytes, 64)
        XCTAssertThrowsError(try budget.makeTexture(device: device, descriptor: descriptor()))
        XCTAssertThrowsError(try budget.checkAdmission())
        XCTAssertEqual(texture.width, 4)
    }
    func testReleasesOnlyAfterLastOwnerAndRollsBackFailedAllocation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let budget = WPEHostTextureBudget(maximumBytes: 128, maximumEdge: 8)
        var held: MTLTexture?
        autoreleasepool { held = try? budget.makeTexture(device: device, descriptor: descriptor()) }
        XCTAssertNotNil(held); XCTAssertEqual(budget.residentBytes, 64)
        autoreleasepool { held = nil }
        XCTAssertEqual(budget.residentBytes, 0)
        XCTAssertThrowsError(try budget.allocate(bytes: 64, width: 4, height: 4) { throw CancellationError() })
        XCTAssertEqual(budget.residentBytes, 0)
        XCTAssertNoThrow(try budget.checkAdmission())
    }
    func testPendingAsyncReservationCountsBeforeUploadFinishes() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let budget = WPEHostTextureBudget(maximumBytes: 64, maximumEdge: 8)
        let reserved = expectation(description: "reservation installed")
        let pending = Task {
            try await budget.allocateAsync(bytes: 64, width: 4, height: 4) {
                reserved.fulfill()
                try await Task.sleep(nanoseconds: 100_000_000)
                return try XCTUnwrap(device.makeTexture(descriptor: self.descriptor()))
            }
        }
        await fulfillment(of: [reserved], timeout: 2)
        XCTAssertEqual(budget.residentBytes, 64)
        XCTAssertThrowsError(try budget.makeTexture(device: device, descriptor: descriptor()))
        let texture = try await pending.value
        XCTAssertEqual(texture.width, 4); XCTAssertEqual(budget.residentBytes, 64)
    }
    func testBufferAndTextureShareBudgetAndDimensionsAreCheckedBeforeAllocation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let budget = WPEHostTextureBudget(maximumBytes: 96, maximumEdge: 4)
        let buffer = try budget.makeBuffer(device: device, length: 32, options: .storageModeShared)
        let texture = try budget.makeTexture(device: device, descriptor: descriptor())
        XCTAssertEqual(budget.residentBytes, 96)
        XCTAssertThrowsError(try budget.makeTexture(device: device, descriptor: descriptor(5)))
        XCTAssertEqual(buffer.length, 32); XCTAssertEqual(texture.height, 4)
    }
}
