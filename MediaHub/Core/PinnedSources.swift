import Foundation
import Observation

/// One pinned source per show. A source is identified by add-on + its display name
/// (e.g. "PenguPlay 1080p"), because stream URLs change per episode.
struct Pin: Codable { let addonID: String; let signature: String }

@MainActor @Observable
final class PinnedSources {
    private var pins: [String: Pin] = [:]
    private let key = "pinned.sources"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode([String: Pin].self, from: d) { pins = p }
    }
    func reload() {
        pins = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Pin].self, from: $0) } ?? [:]
    }
    func pin(for show: String) -> Pin? { pins[show] }
    func set(_ p: Pin, for show: String) { pins[show] = p; save() }
    func remove(for show: String) { pins[show] = nil; save() }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(pins), forKey: key) }
}

extension StreamItem {
    var signature: String { (name ?? title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}
