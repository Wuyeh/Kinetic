import Foundation
import Metal
import os

/// Per-instance ownership, including render targets. Reserve before allocation;
/// weak records reclaim charges only after the last GPU/host owner releases a texture.
final class WPEHostTextureBudget: @unchecked Sendable {
    private struct Record { weak var texture: AnyObject?; let bytes: Int }
    private struct State { var records: [Record] = []; var reserved = 0; var external = 0; var denied = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let maximumBytes: Int
    let maximumEdge: Int
    init(maximumBytes: Int, maximumEdge: Int) { self.maximumBytes = maximumBytes; self.maximumEdge = maximumEdge }
    var residentBytes: Int {
        state.withLock { value in
            value.records.removeAll { $0.texture == nil }
            return value.reserved + value.records.reduce(0) { $0 + $1.bytes }
        }
    }
    // Optional upstream helpers may return nil. A denied allocation must still
    // reject the entire frame instead of silently dropping an effect.
    func checkAdmission() throws {
        if state.withLock({ $0.denied }) { throw KineticWPEBackendError.budget }
    }
    func allocate(bytes: Int, width: Int, height: Int, _ body: () throws -> MTLTexture) throws -> MTLTexture {
        try state.withLock { value in
            value.records.removeAll { $0.texture == nil }
            let used = value.external + value.reserved + value.records.reduce(0) { $0 + $1.bytes }
            guard width > 0, height > 0, width <= maximumEdge, height <= maximumEdge,
                  bytes > 0, bytes <= maximumBytes - used else { value.denied = true; throw KineticWPEBackendError.budget }
            value.reserved += bytes
        }
        do {
            let texture = try body()
            state.withLock { value in
                value.reserved -= bytes
                value.records.append(Record(texture: texture as AnyObject, bytes: bytes))
            }
            return texture
        } catch {
            state.withLock { $0.reserved -= bytes }; throw error
        }
    }
    func makeTexture(device: MTLDevice, descriptor: MTLTextureDescriptor) throws -> MTLTexture {
        let bytes = WPEMetalTextureByteEstimator.estimatedBytes(pixelFormat: descriptor.pixelFormat,
            width: descriptor.width, height: descriptor.height, mipmapLevelCount: descriptor.mipmapLevelCount,
            arrayLength: descriptor.arrayLength, isCube: descriptor.textureType == .typeCube || descriptor.textureType == .typeCubeArray)
        return try allocate(bytes: bytes, width: descriptor.width, height: descriptor.height) {
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw WPEMetalTextureLoaderError.textureAllocationFailed }
            return texture
        }
    }
    func makeBuffer(device: MTLDevice, length: Int, options: MTLResourceOptions) throws -> MTLBuffer {
        try state.withLock { value in
            value.records.removeAll { $0.texture == nil }
            let used = value.external + value.reserved + value.records.reduce(0) { $0 + $1.bytes }
            guard length > 0, length <= maximumBytes - used else { value.denied = true; throw KineticWPEBackendError.budget }
            value.reserved += length
        }
        guard let buffer = device.makeBuffer(length: length, options: options) else {
            state.withLock { $0.reserved -= length }; throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        state.withLock { value in
            value.reserved -= length; value.records.append(Record(texture: buffer as AnyObject, bytes: length))
        }
        return buffer
    }
    func setExternalBytes(_ bytes: Int) throws {
        try state.withLock { value in
            value.records.removeAll { $0.texture == nil }
            let own = value.reserved + value.records.reduce(0) { $0 + $1.bytes }
            guard bytes >= 0, bytes <= maximumBytes - own else { value.denied = true; throw KineticWPEBackendError.budget }
            value.external = bytes
        }
    }
    func allocateAsync(bytes: Int, width: Int, height: Int, _ body: () async throws -> MTLTexture) async throws -> MTLTexture {
        try state.withLock { value in
            value.records.removeAll { $0.texture == nil }
            let used = value.external + value.reserved + value.records.reduce(0) { $0 + $1.bytes }
            guard width > 0, height > 0, width <= maximumEdge, height <= maximumEdge,
                  bytes > 0, bytes <= maximumBytes - used else { value.denied = true; throw KineticWPEBackendError.budget }
            value.reserved += bytes
        }
        do {
            let texture = try await body()
            state.withLock { value in
                value.reserved -= bytes
                value.records.append(Record(texture: texture as AnyObject, bytes: bytes))
            }
            return texture
        } catch { state.withLock { $0.reserved -= bytes }; throw error }
    }
}
