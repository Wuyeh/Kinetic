import Foundation

/// Module 26: reasons are observations, not playback state or user intent.
enum SmartPauseReason: String, CaseIterable, Sendable {
    case screenLocked, displayAsleep, systemAsleep, criticalThermal, criticalMemory
    case fullScreenApp, occluded, batteryLow, lowPowerMode, onBatteryPower
}

struct DisplayPauseConditions: Equatable, Sendable {
    var fullScreenApp = false
    var occluded = false
    var asleep = false
    var frontmostBundleID: String?
}

extension SmartPausePreferences {
    func reasons(for conditions: SmartPauseConditions) -> Set<SmartPauseReason> {
        var result = Set<SmartPauseReason>()
        // Master §35: safety cannot be disabled through the configurable smart-pause switch.
        if conditions.screenLocked { result.insert(.screenLocked) }
        if conditions.displayAsleep { result.insert(.displayAsleep) }
        if conditions.systemAsleep { result.insert(.systemAsleep) }
        if conditions.criticalThermal { result.insert(.criticalThermal) }
        if conditions.criticalMemory { result.insert(.criticalMemory) }
        if smartPause && fullScreen && conditions.fullScreenApp { result.insert(.fullScreenApp) }
        if smartPause && conditions.batteryLow { result.insert(.batteryLow) }
        if lowPowerMode && conditions.lowPowerMode { result.insert(.lowPowerMode) }
        if batteryPower && conditions.onBatteryPower { result.insert(.onBatteryPower) }
        return result
    }

    func reasons(for conditions: DisplayPauseConditions) -> Set<SmartPauseReason> {
        var result: Set<SmartPauseReason> = conditions.asleep ? [.displayAsleep] : []
        guard smartPause,
              !excludedApps.contains(conditions.frontmostBundleID ?? "") else { return result }
        if fullScreen && conditions.fullScreenApp { result.insert(.fullScreenApp) }
        if occlusion && conditions.occluded { result.insert(.occluded) }
        return result
    }
}
