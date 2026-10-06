import Foundation
import Metal

/// Kinetic adaptation: upstream compiles WPEMetalBuiltins.metal into the app's default library.
/// In the package it is compiled into this module's resource bundle.
enum WPEEngineMetalLibrary {
    static func make(_ device: MTLDevice) -> MTLLibrary? {
        try? device.makeDefaultLibrary(bundle: .module)
    }
}
