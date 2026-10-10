import AVFoundation
import CoreVideo
import VideoToolbox

/// Self-authored tiny fixtures; no user video or third-party sample is read.
@main struct GenerateAdvancedVideoFixtures {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await generate(folder.appendingPathComponent("hlg-hevc.mov"), hdr: true)
        try await generate(folder.appendingPathComponent("rotated-h264.mov"), hdr: false)
    }
    static func generate(_ url: URL, hdr: Bool) async throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: hdr ? AVVideoCodecType.hevc : .h264,
                                       AVVideoWidthKey: 192, AVVideoHeightKey: 108]
        if hdr {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        if !hdr { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 108, ty: 0) }
        let format = hdr ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format, kCVPixelBufferWidthKey as String: 192,
            kCVPixelBufferHeightKey as String: 108, kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoFixtureError.write }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? VideoFixtureError.write }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess,
                  let pixel = buffer else { throw VideoFixtureError.write }
            CVPixelBufferLockBaseAddress(pixel, [])
            let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
            let base = CVPixelBufferGetBaseAddress(pixel)!
            for y in 0..<108 {
                for x in 0..<192 {
                    if hdr {
                        let ptr = base.advanced(by: y * rowBytes + x * 8).assumingMemoryBound(to: Float16.self)
                        ptr[0] = Float16(x < 96 ? 2.0 : 0.2); ptr[1] = Float16(0.4 + Double(frame) / 60)
                        ptr[2] = Float16(y < 54 ? 0.3 : 1.2); ptr[3] = 1
                    } else {
                        let ptr = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                        ptr[0] = y < 54 ? 220 : 30; ptr[1] = UInt8(60 + frame * 4)
                        ptr[2] = x < 96 ? 240 : 20; ptr[3] = 255
                    }
                }
            }
            if hdr {
                CVBufferSetAttachment(pixel, kCVImageBufferCGColorSpaceKey,
                    CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!, .shouldPropagate)
                CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? VideoFixtureError.write
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoFixtureError.write }
        print("Generated \(url.lastPathComponent): 192×108, 1 second, \(hdr ? "HEVC Main10 / Rec.2020 HLG / float16 HDR input" : "H.264 / 90-degree track transform")")
    }
    enum VideoFixtureError: Error { case write }
}
