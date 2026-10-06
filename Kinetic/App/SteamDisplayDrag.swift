import SwiftUI

/// Remote item identity stays separate from a local Wallpaper record; only the drag geometry is reused.
struct SteamDisplayDragPresentation {
    private(set) var item: SteamStoreItem?
    private(set) var posterURL: URL?
    private var drag = LocalWallpaperDragPresentation()
    var location: CGPoint? { drag.location }
    var hoveredDisplayID: DisplayID? { drag.hoveredDisplayID }

    mutating func begin(_ item: SteamStoreItem, posterURL: URL?) {
        guard self.item == nil else { return }
        self.item = item
        self.posterURL = posterURL
        drag.begin(UUID())
    }

    mutating func move(_ point: CGPoint, from id: String, frames: [DisplayID: CGRect], displays: [DisplayID]) {
        guard item?.id == id, let source = drag.wallpaperID else { return }
        drag.move(point, from: source, displayFrames: frames, displayIDs: displays, listFrames: [:], listIDs: [])
    }

    mutating func refresh(frames: [DisplayID: CGRect], displays: [DisplayID]) {
        drag.refresh(displayFrames: frames, displayIDs: displays, listFrames: [:], listIDs: [])
    }

    mutating func takeDrop(from id: String, at point: CGPoint, frames: [DisplayID: CGRect], displays: [DisplayID])
        -> (SteamStoreItem, DisplayID)? {
        guard let item, item.id == id, let source = drag.wallpaperID else { return nil }
        defer { cancel() }
        guard case .display(_, let target) = drag.takeDrop(from: source, at: point,
            displayFrames: frames, displayIDs: displays, listFrames: [:], listIDs: [], isInLibrary: true, isPlayable: true)
        else { return nil }
        return (item, target)
    }

    mutating func cancel(from id: String? = nil) {
        guard id == nil || item?.id == id else { return }
        item = nil; posterURL = nil; drag.cancel()
    }
}
