import Metal

extension WPEMetalRenderExecutor {
    /// The host bridge uses discrete, tracked allocations. Legacy standalone
    /// engine callers retain their original allocator when no budget is installed.
    func makeHostTexture(descriptor: MTLTextureDescriptor) throws -> MTLTexture? {
        if let budget = targetPool.hostBudget {
            return try budget.makeTexture(device: device, descriptor: descriptor)
        }
        return device.makeTexture(descriptor: descriptor)
    }
}
