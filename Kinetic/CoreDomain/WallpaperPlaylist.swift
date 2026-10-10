import Foundation

/// Module 46: one display's rotation through a wallpaper list. The list itself (members and order) stays in
/// `LocalOrganizationStore`; this only says which list, how often and whether shuffled.
struct DisplayPlaylistConfiguration: Codable, Equatable, Sendable {
    static let intervalRange = 1...1440
    static let defaultIntervalMinutes = 30

    var listID: UUID
    var intervalMinutes = DisplayPlaylistConfiguration.defaultIntervalMinutes
    var shuffle = false

    var interval: TimeInterval { TimeInterval(Self.clamped(intervalMinutes) * 60) }

    static func clamped(_ minutes: Int) -> Int { min(max(minutes, intervalRange.lowerBound), intervalRange.upperBound) }
}

enum PlaylistStep: Equatable, Sendable { case next, previous }

/// Where a display is in its list. Sequential play follows the list's current order; shuffle keeps one
/// permutation per round, so every wallpaper shows once before any repeats.
struct PlaylistCursor: Codable, Equatable, Sendable {
    var shuffledOrder: [Wallpaper.ID] = []
    var currentWallpaperID: Wallpaper.ID?
    /// The current wallpaper's place, so play continues from there after it leaves the list.
    var currentIndex = 0

    /// The order in effect for `members` (the list's playable wallpapers, in list order). Shuffle drops
    /// members that left the list and puts new ones at random places still ahead in this round.
    mutating func order(members: [Wallpaper.ID], shuffle: Bool, random: inout PlaylistRandom) -> [Wallpaper.ID] {
        guard shuffle else {
            shuffledOrder = []
            if let current = currentWallpaperID, let index = members.firstIndex(of: current) { currentIndex = index }
            return members
        }
        let memberSet = Set(members)
        var seen = Set<Wallpaper.ID>()
        var order = shuffledOrder.filter { memberSet.contains($0) && seen.insert($0).inserted }
        if order.isEmpty {
            order = members.shuffled(using: &random)
            if let current = currentWallpaperID, let index = order.firstIndex(of: current) { order.swapAt(0, index) }
        } else {
            for id in members where !seen.contains(id) {
                let ahead = (currentWallpaperID.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 }) ?? 0
                order.insert(id, at: Int.random(in: ahead...order.count, using: &random))
            }
        }
        shuffledOrder = order
        if let current = currentWallpaperID, let index = order.firstIndex(of: current) { currentIndex = index }
        return order
    }

    /// Starts a round. `preferred` (the wallpaper the display page shows for the list) plays first when it is a member.
    mutating func start(members: [Wallpaper.ID], shuffle: Bool, preferred: Wallpaper.ID?,
                        random: inout PlaylistRandom) -> Wallpaper.ID? {
        shuffledOrder = []
        currentWallpaperID = preferred.flatMap { members.contains($0) ? $0 : nil }
        currentIndex = 0
        let order = order(members: members, shuffle: shuffle, random: &random)
        if currentWallpaperID == nil { currentWallpaperID = order.first; currentIndex = 0 }
        return currentWallpaperID
    }

    /// Moves to the next or previous wallpaper and returns it; nil when nothing in the list can play.
    mutating func step(_ step: PlaylistStep, members: [Wallpaper.ID], shuffle: Bool,
                       random: inout PlaylistRandom) -> Wallpaper.ID? {
        var order = order(members: members, shuffle: shuffle, random: &random)
        guard !order.isEmpty else { return nil }
        let target: Int
        if let current = currentWallpaperID, let index = order.firstIndex(of: current) {
            switch step {
            case .next:
                if index + 1 < order.count { target = index + 1 }
                else if shuffle {
                    order = Self.newRound(order, after: current, random: &random)
                    shuffledOrder = order
                    target = 0
                } else { target = 0 }
            case .previous: target = index > 0 ? index - 1 : order.count - 1
            }
        } else {
            // The current wallpaper left the list: the one now in its place is next.
            let anchor = min(max(currentIndex, 0), order.count)
            switch step {
            case .next: target = anchor < order.count ? anchor : 0
            case .previous: target = anchor > 0 ? anchor - 1 : order.count - 1
            }
        }
        currentWallpaperID = order[target]
        currentIndex = target
        return order[target]
    }

    /// A new shuffled round that does not open with the wallpaper that just played.
    private static func newRound(_ order: [Wallpaper.ID], after last: Wallpaper.ID,
                                 random: inout PlaylistRandom) -> [Wallpaper.ID] {
        var next = order.shuffled(using: &random)
        if next.count > 1, next.first == last { next.swapAt(0, Int.random(in: 1..<next.count, using: &random)) }
        return next
    }
}

/// A replaceable random source, so tests can fix the shuffle.
struct PlaylistRandom: RandomNumberGenerator {
    private let source: () -> UInt64
    init(_ source: @escaping () -> UInt64) { self.source = source }
    static var system: PlaylistRandom {
        PlaylistRandom { var generator = SystemRandomNumberGenerator(); return generator.next() }
    }
    mutating func next() -> UInt64 { source() }
}
