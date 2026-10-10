import Foundation
import Observation

/// Seconds actually spent watching, per day and per hour of the day, for the active profile.
/// The player adds to it while a video is playing; the profile page turns it into "favourite time of day"
/// and "average daily watch". Stored as { "2026-10-05": [24 hourly buckets in seconds] }, trimmed to ~14 months.
@MainActor @Observable
final class WatchLog {
    private(set) var days: [String: [Int]] = [:]
    @ObservationIgnored private var profileID = ProfileKeys.activeID
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave = Date.distantPast
    private var storeKey: String { ProfileKeys.scoped("watch.log", profileID) }

    init() { days = Self.read(storeKey) }

    /// After a settings import: storage is the truth, so unsaved in-memory data is dropped, not written over it.
    func reload() { dirty = false; profileID = ProfileKeys.activeID; days = Self.read(storeKey) }

    func load(profile id: String) {
        guard id != profileID else { return }
        flush()
        profileID = id
        days = Self.read(storeKey)
    }

    // MARK: Recording

    /// Adds `seconds` of playback to the hour containing `date`.
    func record(seconds: Double, at date: Date = .now) {
        guard seconds > 0.5, seconds < 600 else { return }
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour], from: date)
        let key = Self.dayKey(c)
        var hours = days[key] ?? Array(repeating: 0, count: 24)
        hours[min(max(c.hour ?? 0, 0), 23)] += Int(seconds.rounded())
        days[key] = hours
        dirty = true
        if Date().timeIntervalSince(lastSave) > 60 { flush() }     // the 10 s player tick would otherwise rewrite it constantly
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        lastSave = .now
        if days.count > 430 {
            for k in days.keys.sorted().dropLast(400) { days[k] = nil }
        }
        if let d = try? JSONEncoder().encode(days) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    // MARK: Queries

    var isEmpty: Bool { days.isEmpty }
    var totalSeconds: Double { days.values.reduce(0) { $0 + Double($1.reduce(0, +)) } }

    /// Seconds watched in each hour of the day (index 0 = midnight), summed over all days.
    var hourTotals: [Double] {
        var out = Array(repeating: 0.0, count: 24)
        for hours in days.values { for (i, s) in hours.enumerated() where i < 24 { out[i] += Double(s) } }
        return out
    }

    /// First day with any recorded playback.
    var firstDay: Date? { days.keys.min().flatMap(Self.date(from:)) }

    /// Average seconds per day over the last `window` days, counting only days since tracking began
    /// (so a new install isn't averaged against a month it wasn't there for).
    func averageDailySeconds(window: Int = 30) -> Double? {
        guard let first = firstDay else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let span = max((cal.dateComponents([.day], from: cal.startOfDay(for: first), to: today).day ?? 0) + 1, 1)
        let n = min(span, window)
        guard let from = cal.date(byAdding: .day, value: -(n - 1), to: today) else { return nil }
        var total = 0.0
        for (k, hours) in days {
            guard let d = Self.date(from: k), d >= from else { continue }
            total += Double(hours.reduce(0, +))
        }
        return total / Double(n)
    }

    // MARK: Storage

    private static func dayKey(_ c: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    private static func date(from key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    private static func read(_ key: String) -> [String: [Int]] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([String: [Int]].self, from: d) else { return [:] }
        return v
    }
}
