import Foundation

/// IEEE-754 binary16 decoding without the architecture-specific Swift Float16 type.
/// Xcode may compile dependency slices beyond the app's arm64 ARCHS setting.
enum WPEHalfFloat {
    static func decode(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x1f)
        var fraction = UInt32(bits & 0x03ff)
        if exponent == 0 {
            guard fraction != 0 else { return Float(bitPattern: sign) }
            var normalizedExponent: UInt32 = 113
            while fraction & 0x0400 == 0 {
                fraction <<= 1
                normalizedExponent -= 1
            }
            return Float(bitPattern: sign | (normalizedExponent << 23) | ((fraction & 0x03ff) << 13))
        }
        if exponent == 31 {
            return Float(bitPattern: sign | 0x7f800000 | (fraction << 13))
        }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (fraction << 13))
    }
}
