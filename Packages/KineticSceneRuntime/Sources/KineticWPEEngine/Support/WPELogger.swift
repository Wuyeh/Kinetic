import Foundation
import os

/// Kinetic adaptation: the upstream engine logs through LiveWallpaperCore's `Logger`
/// (with a persistent log file). Kinetic only forwards to the unified system log,
/// never writes a log file, and keeps the same call surface so ported code compiles unchanged.
public enum Logger {
    public enum Category: String, CaseIterable, Sendable {
        case general = "General"
        case screenManager = "ScreenManager"
        case videoPlayer = "VideoPlayer"
        case powerMonitor = "PowerMonitor"
        case fileAccess = "FileAccess"
        case settings = "Settings"
        case ui = "UserInterface"
        case performance = "Performance"
        case startup = "Startup"
        case lifecycle = "Lifecycle"
        case memory = "Memory"
        case wpeRender = "WPERender"
        case audioCapture = "AudioCapture"
        case workshop = "Workshop"
        case updates = "Updates"

        public static let subsystem = "com.kinetic.app.SceneEngine"

        fileprivate var logger: os.Logger { os.Logger(subsystem: Self.subsystem, category: rawValue) }
    }

    public enum Level: Sendable {
        case debug, info, notice, warning, error, fault

        fileprivate var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .notice, .warning: return .default
            case .error: return .error
            case .fault: return .fault
            }
        }
    }

    public static func log(_ message: @autoclosure () -> String, category: Category, level: Level = .info,
                           file: String = #file, function: String = #function, line: Int = #line) {
        let text = message()
        category.logger.log(level: level.osLogType, "\(text, privacy: .public)")
        #if DEBUG
        if let sink = testSink.withLock({ $0 }) { sink("[\(category.rawValue)] \(text)") }
        #endif
    }

    #if DEBUG
    private static let testSink = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    /// Debug builds only: lets diagnostics tests read the engine's messages (Kinetic never writes a log file).
    @_spi(KineticTesting) public static func setTestSink(_ sink: (@Sendable (String) -> Void)?) {
        testSink.withLock { $0 = sink }
    }
    #endif

    public static func debug(_ message: @autoclosure () -> String, category: Category = .general,
                             file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(message(), category: category, level: .debug)
        #endif
    }

    public static func info(_ message: @autoclosure () -> String, category: Category = .general,
                            file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .info)
    }

    public static func notice(_ message: @autoclosure () -> String, category: Category = .general,
                              file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .notice)
    }

    public static func warning(_ message: @autoclosure () -> String, category: Category = .general,
                               file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .warning)
    }

    public static func error(_ message: @autoclosure () -> String, category: Category = .general,
                             file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .error)
    }

    public static func functionStart(category: Category = .general, file: String = #file,
                                     function: String = #function, line: Int = #line) {}

    public static func functionEnd(category: Category = .general, file: String = #file,
                                   function: String = #function, line: Int = #line) {}
}
