// 测试素材生成工具，不参与 App 构建。输出仅写入命令行指定的 Fixtures 目录。
import AVFoundation
import AudioToolbox
import CoreGraphics

@main
struct GenerateVideoFixtures {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, type) in [("loop.mp4", AVFileType.mp4), ("loop.mov", AVFileType.mov)] {
            try await generate(directory.appendingPathComponent(name), type: type)
        }
        try Data("This is deliberately not a movie.".utf8).write(to: directory.appendingPathComponent("corrupt.mp4"))
    }

    static func generate(_ url: URL, type: AVFileType) async throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 200_000]
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        var audioFormat: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &audioFormat) == noErr)
        let audioTask = Task {
            for frame in 0..<72 {
                while !audio.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error! }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            let samples = (0..<1600).map { index in
                Float(sin(2 * Double.pi * 440 * Double(frame * 1600 + index) / 48_000) * 0.1)
            }
            var block: CMBlockBuffer?
            precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: samples.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: samples.count * 4, flags: 0, blockBufferOut: &block) == noErr)
            _ = samples.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                              dataLength: $0.count)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: Int64(frame * 1600), timescale: 48_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: audioFormat, sampleCount: 1600, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sample) == noErr)
            guard audio.append(sample!) else { throw writer.error! }
            }
            audio.markAsFinished()
        }
        for frame in 0..<72 {
            while !video.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error! }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess)
            let pixel = buffer!
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 320, height: 180,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.15, green: 0.35 + CGFloat(frame) / 180, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: frame * 4, y: 60, width: 32, height: 60))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error!
            }

        }
        video.markAsFinished()
        try await audioTask.value
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        print("Generated \(url.lastPathComponent): 320×180 H.264, 2.4 seconds, AAC tone")
    }
}
