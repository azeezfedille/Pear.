import SwiftUI
import UniformTypeIdentifiers

/// Export / import of app settings as a property-list file.
/// Includes API keys, add-on URLs, appearance, playback, subtitle style, profiles, pinned sources and each profile's
/// content settings (hidden categories and rows, and the catalogues added to Home from AIOMetadata).
/// Optionally includes each profile's watch history and local library.
/// Not included: the Simkl login (reconnect after importing).
enum SettingsBackup {
    static let formatKey = "_pearBackupVersion"
    static let version = 1

    static let keys = [
        "addon.manifestURLs", "addon.disabled", "addon.catalogPicker", "tmdb.key", "tvdb.key", "tvdb.pin", "mdblist.key", "mdblist.lists",
        "ui.accent", "ui.networkBadges", "ui.titleLogos", "ui.landscapeLayout", "player.glass", "player.autoplayNext",
        "player.pip", "player.pillPinned", "player.pillOrder",
        "skip.enabled", "skip.fallbackSeconds", "sub.lang", "sub.style", "subs.online", "subs.baseURL", "library.collapsed",
        "profiles.list", "profiles.active", "pinned.sources", "artwork.pinned",
    ]
    /// Per-profile settings (each profile's hidden categories and rows): "content.prefs" plus ".<profile id>" variants.
    /// Always included, unlike the data below, because they are settings.
    static let settingsPrefixes = ["content.prefs"]
    /// Per-profile data: "watch.history" and "library.local", plus their ".<profile id>" variants.
    static let dataPrefixes = ["watch.history", "watch.archive", "watch.log", "library.local", "library.prefs"]

    enum Failure: LocalizedError {
        case unreadable, notBackup, newer
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file couldn't be read."
            case .notBackup: return "That isn't a Pear settings backup."
            case .newer: return "That backup was made by a newer version of the app."
            }
        }
    }

    static func export(includeData: Bool) throws -> Data {
        let all = UserDefaults.standard.dictionaryRepresentation()
        var out: [String: Any] = [formatKey: version]
        for (k, v) in all where isAllowed(k, includeData: includeData) { out[k] = v }
        return try PropertyListSerialization.data(fromPropertyList: out, format: .xml, options: 0)
    }

    /// Reads a picked file. Goes through a file coordinator, so a backup that sits in iCloud Drive (or another
    /// provider) and isn't on the device yet is downloaded first instead of failing to open.
    static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(Failure.unreadable)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Writes the file's settings into UserDefaults. Returns the number of values restored.
    static func restore(_ data: Data) throws -> Int {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { throw Failure.unreadable }
        guard let v = dict[formatKey] as? Int else { throw Failure.notBackup }
        guard v <= version else { throw Failure.newer }
        var n = 0
        for (k, val) in dict where isAllowed(k, includeData: true) {
            UserDefaults.standard.set(val, forKey: k); n += 1
        }
        // The add-on list comes from the backup, so its on/off state must too. Backups made before add-ons
        // could be switched off have no such key: everything in them is on.
        if dict["addon.manifestURLs"] != nil && dict["addon.disabled"] == nil {
            UserDefaults.standard.removeObject(forKey: "addon.disabled")
        }
        return n
    }

    private static func isAllowed(_ k: String, includeData: Bool) -> Bool {
        if keys.contains(k) { return true }
        if settingsPrefixes.contains(where: { k == $0 || k.hasPrefix($0 + ".") }) { return true }
        return includeData && dataPrefixes.contains { k == $0 || k.hasPrefix($0 + ".") }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.propertyList] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Opens the system file picker in "copy" mode: the chosen file is copied into the app's own temporary folder, so
/// reading it needs no security-scoped access. SwiftUI's `fileImporter` hands back a scoped URL instead, which
/// fails in sideloaded or containerised installs (LiveContainer) where the app can't claim that access.
enum BackupPicker {
    private static var holder: PickerDelegate?

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(_ done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
        private func finish(_ url: URL?) { BackupPicker.holder = nil; done(url) }
    }

    /// `done` gets the copied file, or nil when the picker was cancelled or couldn't be shown.
    static func present(_ done: @escaping (URL?) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else { done(nil); return }
        while let next = top.presentedViewController { top = next }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.propertyList, .xml, .data], asCopy: true)
        let delegate = PickerDelegate(done)
        holder = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }
}
