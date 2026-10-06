import Compression
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal

enum SceneTextureFormat: UInt32, Sendable {
    case rgba = 0, bc3 = 4, bc2 = 6, bc1 = 7, rg = 8, r = 9, bc7 = 12, rgb10a2 = 13
    var metal: MTLPixelFormat {
        switch self {
        case .rgba: return .rgba8Unorm
        case .bc3: return .bc3_rgba
        case .bc2: return .bc2_rgba
        case .bc1: return .bc1_rgba
        case .rg: return .rg8Unorm
        case .r: return .r8Unorm
        case .bc7: return .bc7_rgbaUnorm
        case .rgb10a2: return .rgb10a2Unorm
        }
    }
    var isBlockCompressed: Bool { [.bc1, .bc2, .bc3, .bc7].contains(self) }
    func rowBytes(_ width: Int) -> Int {
        if isBlockCompressed { return ((width + 3) / 4) * (self == .bc1 ? 8 : 16) }
        return width * (self == .r ? 1 : self == .rg ? 2 : 4)
    }
    func byteCount(width: Int, height: Int) -> Int { rowBytes(width) * (isBlockCompressed ? (height + 3) / 4 : height) }
}

struct SceneTexture: Sendable {
    struct Mip: Sendable { let width: Int; let height: Int; let bytes: Data }
    let format: SceneTextureFormat
    let mips: [Mip]
    let logicalSize: SIMD2<Float>
    let clamp: Bool
    let nearest: Bool
    var residentBytes: Int { mips.reduce(0) { $0 + $1.bytes.count } }

    static func decode(_ data: Data, limits: SceneLimits) throws -> SceneTexture {
        if data.starts(with: Data("TEXV".utf8)) { return try decodeTEX(data, limits: limits) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw SceneRuntimeError.unsupported("raster / animated texture format")
        }
        try validateSize(width, height, limits: limits)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw SceneRuntimeError.malformed("raster pixels")
        }
        guard image.width == width, image.height == height else { throw SceneRuntimeError.malformed("raster dimensions changed") }
        return try raster(image, limits: limits)
    }

    static func raster(_ image: CGImage, limits: SceneLimits) throws -> SceneTexture {
        let width = image.width, height = image.height
        try validateSize(width, height, limits: limits)
        var bytes = Data(count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
            // GPU uses straight-alpha sampling for TEX and raster alike.
            let pointer = buffer.bindMemory(to: UInt8.self)
            for pixel in stride(from: 0, to: pointer.count, by: 4) {
                let alpha = Int(pointer[pixel + 3])
                if alpha > 0 && alpha < 255 {
                    for component in 0..<3 { pointer[pixel + component] = UInt8(min(255, Int(pointer[pixel + component]) * 255 / alpha)) }
                }
            }
            return true
        }
        guard success else { throw SceneRuntimeError.graphics("raster allocation") }
        return .init(format: .rgba, mips: [.init(width: width, height: height, bytes: bytes)],
                     logicalSize: SIMD2(Float(width), Float(height)), clamp: true, nearest: false)
    }

    static func text(_ text: String, font: String, pointSize: Float, size: SIMD2<Float>?, limits: SceneLimits, fontData: Data? = nil) throws -> SceneTexture {
        guard (1...512).contains(pointSize) else { throw SceneRuntimeError.budgetExceeded("text point size") }
        let ctFont: CTFont
        if let data = fontData {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
                  descriptors.count == 1, let descriptor = descriptors.first else { throw SceneRuntimeError.malformed("Scene font data") }
            // No global font registration: the descriptor lives only in this Scene preparation.
            ctFont = CTFontCreateWithFontDescriptor(descriptor, CGFloat(pointSize), nil)
        } else {
            ctFont = CTFontCreateWithName(font as CFString, CGFloat(pointSize), nil)
            let actual = CTFontCopyPostScriptName(ctFont) as String, family = CTFontCopyFamilyName(ctFont) as String
            guard actual.caseInsensitiveCompare(font) == .orderedSame || family.caseInsensitiveCompare(font) == .orderedSame else {
                throw SceneRuntimeError.missingAsset("font: \(font)")
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: size.map { CGFloat($0.x) } ?? 4_096, height: 4_096), nil)
        let width = Int(ceil(size.map { CGFloat($0.x) } ?? max(1, suggested.width + 4)))
        let height = Int(ceil(size.map { CGFloat($0.y) } ?? max(1, suggested.height + 4)))
        try validateSize(width, height, limits: limits)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SceneRuntimeError.graphics("text allocation")
        }
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { throw SceneRuntimeError.graphics("text rasterization") }
        return try raster(image, limits: limits)
    }

    static func validateSize(_ width: Int, _ height: Int, limits: SceneLimits) throws {
        guard width > 0, height > 0, width <= limits.maximumTextureEdge, height <= limits.maximumTextureEdge else {
            throw SceneRuntimeError.budgetExceeded("texture dimensions \(width)×\(height)")
        }
        guard width <= limits.maximumTextureBytes / 4 / height else { throw SceneRuntimeError.budgetExceeded("decoded texture bytes") }
    }

    private static func decodeTEX(_ data: Data, limits: SceneLimits) throws -> SceneTexture {
        var reader = SceneByteReader(data: data)
        guard try reader.tag() == "TEXV0005", try reader.tag() == "TEXI0001" else {
            throw SceneRuntimeError.unsupported("TEX container / info version")
        }
        let formatCode = try reader.uint32(), flags = try reader.uint32()
        guard let format = SceneTextureFormat(rawValue: formatCode) else { throw SceneRuntimeError.unsupported("TEX format \(formatCode)") }
        let width = Int(try reader.uint32()), height = Int(try reader.uint32())
        try validateSize(width, height, limits: limits)
        let logicalWidth = Int(try reader.uint32()), logicalHeight = Int(try reader.uint32())
        _ = try reader.uint32()
        if flags & 0x40 != 0 { _ = try reader.uint32() }
        let block = try reader.tag()
        guard ["TEXB0001", "TEXB0002", "TEXB0003", "TEXB0004"].contains(block) else { throw SceneRuntimeError.unsupported(block) }
        let version = Int(String(block.suffix(4)))!
        guard try reader.uint32() == 1 else { throw SceneRuntimeError.unsupported("animated TEX images") }
        var encoded = false
        if version >= 3 { encoded = try reader.uint32() != UInt32.max }
        if version == 4, try reader.uint32() != 0 { throw SceneRuntimeError.unsupported("video TEX") }
        let mipCount = Int(try reader.uint32())
        guard (1...14).contains(mipCount) else { throw SceneRuntimeError.malformed("TEX mip count") }
        var mips: [Mip] = [], total = 0
        var encodedTexture: SceneTexture?
        for index in 0..<mipCount {
            let mipWidth = Int(try reader.uint32()), mipHeight = Int(try reader.uint32())
            guard mipWidth == max(1, width >> index), mipHeight == max(1, height >> index) else {
                throw SceneRuntimeError.malformed("TEX mip geometry")
            }
            let expected = format.byteCount(width: mipWidth, height: mipHeight)
            guard expected <= limits.maximumTextureBytes - total else { throw SceneRuntimeError.budgetExceeded("TEX mip bytes") }
            let compressed = version >= 2 ? try reader.uint32() : 0
            let inflatedSize = version >= 2 ? Int(try reader.uint32()) : expected
            guard compressed <= 1 else { throw SceneRuntimeError.unsupported("TEX compression") }
            if !encoded && compressed == 1 && inflatedSize != expected { throw SceneRuntimeError.malformed("TEX inflated size") }
            let stored = Int(try reader.uint32())
            guard stored > 0, stored <= limits.maximumAssetBytes else { throw SceneRuntimeError.budgetExceeded("TEX stored bytes") }
            var bytes = try reader.read(stored)
            if compressed == 1 {
                guard inflatedSize > 0, inflatedSize <= limits.maximumTextureBytes - total else { throw SceneRuntimeError.budgetExceeded("TEX decompression") }
                var result = Data(count: inflatedSize)
                let decoded = result.withUnsafeMutableBytes { destination in
                    bytes.withUnsafeBytes { source in
                        compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, inflatedSize,
                            source.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_LZ4_RAW)
                    }
                }
                guard decoded == inflatedSize else { throw SceneRuntimeError.malformed("TEX LZ4 payload") }
                bytes = result
            }
            if encoded {
                guard !bytes.starts(with: Data("TEXV".utf8)) else { throw SceneRuntimeError.malformed("nested TEX payload") }
                // Wallpaper Engine stores each level of an encoded (PNG / JPEG …) chain as its own image; the
                // first level is the full picture, later ones are its downscaled copies and are only read past.
                if index == 0 { encodedTexture = try decode(bytes, limits: limits) }
                continue
            }
            guard bytes.count == expected else { throw SceneRuntimeError.malformed("TEX mip byte count") }
            mips.append(.init(width: mipWidth, height: mipHeight, bytes: bytes)); total += expected
        }
        guard reader.remaining == 0 else { throw SceneRuntimeError.unsupported("TEX trailing animation data") }
        if let encodedTexture { return encodedTexture }
        guard logicalWidth > 0, logicalHeight > 0, logicalWidth <= width, logicalHeight <= height else {
            throw SceneRuntimeError.malformed("TEX logical dimensions")
        }
        return .init(format: format, mips: mips, logicalSize: SIMD2(Float(logicalWidth), Float(logicalHeight)),
                     clamp: flags & 2 != 0, nearest: flags & 1 != 0)
    }
}
