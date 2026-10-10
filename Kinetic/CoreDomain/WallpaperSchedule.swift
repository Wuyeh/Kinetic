import Foundation

/// Module 47: the five named day periods. Choosing one fills in its times; `custom` keeps the user's own.
enum SchedulePeriod: String, Codable, CaseIterable, Sendable {
    case morning, midday, afternoon, evening, night, custom

    /// Minutes after local midnight; the end is exclusive and may wrap past midnight.
    var defaultRange: (start: Int, end: Int)? {
        switch self {
        case .morning: return (6 * 60, 11 * 60)
        case .midday: return (11 * 60, 14 * 60)
        case .afternoon: return (14 * 60, 18 * 60)
        case .evening: return (18 * 60, 22 * 60)
        case .night: return (22 * 60, 6 * 60)
        case .custom: return nil
        }
    }

    var title: String {
        switch self {
        case .morning: return "早晨"
        case .midday: return "中午"
        case .afternoon: return "下午"
        case .evening: return "傍晚"
        case .night: return "夜间"
        case .custom: return "自定义"
        }
    }
}

/// What a time slot shows: one wallpaper, a wallpaper list rotated with its own interval (Module 46),
/// or a bookmark — a wallpaper with saved parameters (Module 48).
enum ScheduleContent: Codable, Equatable, Hashable, Sendable {
    case wallpaper(Wallpaper.ID)
    case list(UUID, intervalMinutes: Int, shuffle: Bool)
    case bookmark(UUID)
}

struct ScheduleSlot: Codable, Equatable, Identifiable, Sendable {
    static let minutesPerDay = 24 * 60

    var id = UUID()
    var period: SchedulePeriod
    /// Minutes after local midnight, 0..<1440. `end` is exclusive; an end at or before the start wraps past midnight.
    var start: Int
    var end: Int
    var content: ScheduleContent?

    init(id: UUID = UUID(), period: SchedulePeriod, start: Int? = nil, end: Int? = nil, content: ScheduleContent? = nil) {
        self.id = id
        self.period = period
        let range = period.defaultRange
        self.start = start ?? range?.start ?? 9 * 60
        self.end = end ?? range?.end ?? 17 * 60
        self.content = content
    }

    var isValidRange: Bool {
        (0..<Self.minutesPerDay).contains(start) && (0..<Self.minutesPerDay).contains(end) && start != end
    }

    /// The half-open minute ranges this slot covers within one day.
    var dayRanges: [Range<Int>] {
        guard isValidRange else { return [] }
        if start < end { return [start..<end] }
        return [start..<Self.minutesPerDay, 0..<end].filter { !$0.isEmpty }
    }

    func overlaps(_ other: ScheduleSlot) -> Bool {
        dayRanges.contains { mine in other.dayRanges.contains { mine.overlaps($0) } }
    }

    /// When the slot covering `date` began, or nil when it does not cover `date`.
    func occurrenceStart(covering date: Date, calendar: Calendar) -> Date? {
        guard isValidRange else { return nil }
        let day = calendar.startOfDay(for: date)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        func at(_ dayOffset: Int) -> Date? {
            guard let base = calendar.date(byAdding: .day, value: dayOffset, to: day) else { return nil }
            return calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: base)
        }
        if start < end { return (start..<end).contains(minute) ? at(0) : nil }
        if minute >= start { return at(0) }
        if minute < end { return at(-1) }
        return nil
    }

    /// The next time this slot begins after `date`.
    func nextStart(after date: Date, calendar: Calendar) -> Date? {
        guard isValidRange else { return nil }
        return calendar.nextDate(after: date, matching: DateComponents(hour: start / 60, minute: start % 60, second: 0),
                                 matchingPolicy: .nextTime)
    }
}

/// One display's schedule.
struct DisplaySchedule: Codable, Equatable, Sendable {
    static let maximumSlots = 24

    var isEnabled = false
    var slots: [ScheduleSlot] = []

    /// Slots whose times overlap another slot of this display, with the slots they overlap.
    var conflicts: [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        for (index, slot) in slots.enumerated() {
            for other in slots[(index + 1)...] where slot.overlaps(other) {
                result[slot.id, default: []].append(other.id)
                result[other.id, default: []].append(slot.id)
            }
        }
        return result
    }

    /// Problems that keep this schedule from being applied, in display order.
    var problems: [UUID: ScheduleProblem] {
        var result: [UUID: ScheduleProblem] = [:]
        let conflicts = conflicts
        for slot in slots {
            if !slot.isValidRange { result[slot.id] = .emptyRange }
            else if let others = conflicts[slot.id] { result[slot.id] = .overlaps(others) }
            else if slot.content == nil { result[slot.id] = .noContent }
        }
        return result
    }

    var canApply: Bool { slots.count <= Self.maximumSlots && (!isEnabled || problems.isEmpty) }

    /// The slot covering `date` and when that occurrence began.
    func activeSlot(at date: Date, calendar: Calendar) -> (slot: ScheduleSlot, began: Date)? {
        guard isEnabled else { return nil }
        for slot in slots { if let began = slot.occurrenceStart(covering: date, calendar: calendar) { return (slot, began) } }
        return nil
    }
}

enum ScheduleProblem: Equatable, Sendable {
    case emptyRange
    case overlaps([UUID])
    case noContent
}

extension Int {
    /// "06:00" for minutes after midnight.
    var scheduleClockText: String { String(format: "%02d:%02d", self / 60, self % 60) }
}
