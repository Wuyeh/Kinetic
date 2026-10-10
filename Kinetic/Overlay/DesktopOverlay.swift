import AppKit

/// Effects own their render resources; this interface never receives a Wallpaper Runtime.
/// prepare must cooperate with cancellation. update must validate before changing live state.
/// pause retains the current appearance; dispose is idempotent and stops all owned work.
@MainActor
protocol DesktopOverlay: AnyObject {
    var displayView: NSView { get }
    var onFailure: (@MainActor (Error) -> Void)? { get set }
    func prepare(configuration: OverlayConfiguration, context: OverlayContext) async throws
    func update(configuration: OverlayConfiguration, context: OverlayContext) throws
    func play()
    func pause()
    func dispose()
}

@MainActor
protocol OverlaySurface: AnyObject {
    func present(_ view: NSView, for id: UUID, display: DesktopDisplay) throws
    func remove(_ id: UUID)
    func realign(_ display: DesktopDisplay)
    func setOrder(_ ids: [UUID])
    func close()
}
