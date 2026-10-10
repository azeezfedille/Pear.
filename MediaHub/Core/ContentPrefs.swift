import Foundation
import Observation

/// What the active profile wants to see: which categories are hidden and which Home rows are switched off.
/// Per profile (like the watch history), so a kids' profile can hide what an adult's doesn't.
@MainActor @Observable
final class ContentPrefs {
    private(set) var rules: ContentRules
    @ObservationIgnored private var profileID = ProfileKeys.activeID

    private static func key(_ profile: String) -> String { ProfileKeys.scoped("content.prefs", profile) }

    init() { rules = Self.read(Self.key(ProfileKeys.activeID)) }

    /// Switches to another profile's settings. No-op when already loaded.
    func load(profile id: String) {
        guard id != profileID else { return }
        profileID = id
        rules = Self.read(Self.key(id))
    }

    /// Re-reads from storage (after a settings import).
    func reload() {
        profileID = ProfileKeys.activeID
        rules = Self.read(Self.key(profileID))
    }

    // MARK: Changing

    func setHidden(_ category: ContentCategory, _ hidden: Bool) {
        if hidden { rules.hiddenCategories.insert(category) } else { rules.hiddenCategories.remove(category) }
        save()
    }

    func setRowHidden(_ key: String, _ hidden: Bool) {
        if hidden, rules.addedRows.contains(key) {
            // A catalogue the user added is taken off Home rather than "hidden": it was never on by default.
            rules.addedRows.remove(key)
        } else if hidden {
            rules.hiddenRows.insert(key)
        } else {
            rules.hiddenRows.remove(key)
        }
        save()
    }

    /// Adds a catalogue to Home (or takes it off again). For add-ons with a catalogue picker, e.g. AIOMetadata.
    func setRowAdded(_ key: String, _ added: Bool) {
        setRowsAdded([key], added)
    }

    /// Same, for several catalogues at once (one save).
    func setRowsAdded(_ keys: [String], _ added: Bool) {
        if added {
            rules.addedRows.formUnion(keys)
            rules.hiddenRows.subtract(keys)
        } else {
            rules.addedRows.subtract(keys)
        }
        save()
    }

    func setFilterSearch(_ on: Bool) {
        guard rules.filterSearch != on else { return }
        rules.filterSearch = on
        save()
    }

    /// Back to the default: everything shown. Catalogues the user added to Home stay.
    func reset() {
        var fresh = ContentRules()
        fresh.addedRows = rules.addedRows
        rules = fresh
        save()
    }

    // MARK: Storage

    private static func read(_ key: String) -> ContentRules {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ContentRules.self, from: $0) } ?? ContentRules()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: Self.key(profileID))
    }
}
