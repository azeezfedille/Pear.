import Foundation

/// A kind of title the user can switch off (Settings -> Content & catalogues).
/// Most are plain TMDB genres. Anime and Cartoons are both "Animation" on TMDB, so they are told apart by where the
/// title comes from: Japanese animation is anime, everything else animated is a cartoon (see `TitleTraits`).
/// The region categories (Asian, Indian & South Asian, Other foreign-language) are decided by origin alone and only
/// ever apply to live-action titles: animation is governed by Anime and Cartoons. They don't overlap, so each
/// non-English live-action title belongs to exactly one of them.
enum ContentCategory: String, CaseIterable, Identifiable, Sendable {
    case anime, cartoons, kids, documentary, reality, talkNews, soap, horror, romance
    case asian, indian, foreign, music, tvMovies

    /// Decided by where a title comes from (language / country), not by its genres.
    static let regions: [ContentCategory] = [.asian, .indian, .foreign]
    /// Everything else, in the order the settings screen lists it.
    static let kinds: [ContentCategory] = allCases.filter { !regions.contains($0) }
    var isRegion: Bool { Self.regions.contains(self) }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anime: return "Anime"
        case .cartoons: return "Cartoons & animation"
        case .kids: return "Kids & family"
        case .documentary: return "Documentaries"
        case .reality: return "Reality TV"
        case .talkNews: return "Talk shows & news"
        case .soap: return "Soap operas"
        case .horror: return "Horror"
        case .romance: return "Romance"
        case .asian: return "Asian film & TV"
        case .indian: return "Indian & South Asian"
        case .foreign: return "Other foreign-language"
        case .music: return "Music & musicals"
        case .tvMovies: return "TV movies"
        }
    }

    var detail: String {
        switch self {
        case .anime: return "Japanese animation, films and series."
        case .cartoons: return "Animated films and shows that aren't anime."
        case .kids: return "Children's TV and family films."
        case .documentary: return "Documentary films and series."
        case .reality: return "Reality shows and competitions."
        case .talkNews: return "Talk shows, late night and news."
        case .soap: return "Soap operas and telenovelas."
        case .horror: return "Horror films and series."
        case .romance: return "Romance films and series."
        case .asian: return "Live-action from Japan, Korea, China, Taiwan, Hong Kong and Southeast Asia (K-dramas, C-dramas, J-dramas). Anime has its own switch."
        case .indian: return "Bollywood and South Indian cinema, plus other South Asian film and TV."
        case .foreign: return "Live-action not made in English or in Asia: European, Latin American, Turkish, Middle Eastern, African."
        case .music: return "Concerts, music documentaries, biopics and musicals."
        case .tvMovies: return "Made-for-TV films."
        }
    }

    var symbol: String {
        switch self {
        case .anime: return "sparkles"
        case .cartoons: return "pawprint.fill"
        case .kids: return "balloon.fill"
        case .documentary: return "globe.americas.fill"
        case .reality: return "person.3.fill"
        case .talkNews: return "mic.fill"
        case .soap: return "theatermasks.fill"
        case .horror: return "eye.fill"
        case .romance: return "heart.fill"
        case .asian: return "globe.asia.australia.fill"
        case .indian: return "globe.central.south.asia.fill"
        case .foreign: return "globe.europe.africa.fill"
        case .music: return "music.note"
        case .tvMovies: return "tv.fill"
        }
    }

    /// TMDB genre ids that put a title in this category. nil for Anime, Cartoons and the regions, which depend on origin.
    var genreIDs: Set<Int>? {
        switch self {
        case .anime, .cartoons, .asian, .indian, .foreign: return nil
        case .kids: return [10762, 10751]        // Kids (TV), Family
        case .documentary: return [99]
        case .reality: return [10764]
        case .talkNews: return [10767, 10763]    // Talk, News
        case .soap: return [10766]
        case .horror: return [27]
        case .romance: return [10749]
        case .music: return [10402]
        case .tvMovies: return [10770]
        }
    }

    static let animationGenre = 16
}

/// What the filter needs to know about a title: its TMDB genres and where it was made.
struct TitleTraits: Codable, Hashable, Sendable {
    var genres: Set<Int>
    /// ISO 639-1 original language ("ja").
    var language: String?
    /// ISO 3166-1 countries of origin ("JP").
    var countries: [String]

    var isAnimation: Bool { genres.contains(ContentCategory.animationGenre) }
    /// Anime vs. other animation can only be decided once the origin is known.
    var hasOrigin: Bool { language != nil || !countries.isEmpty }
    var isJapanese: Bool { language == "ja" || countries.contains("JP") }

    /// Which region a live-action title belongs to, or nil for English-language titles (and anything we can't place).
    /// The language decides when it is known; the country only when there is no language, so an English-language
    /// film shot in Japan isn't "Asian".
    var region: ContentCategory? {
        if let l = language?.lowercased(), !l.isEmpty, l != "xx" {
            if Region.eastAsianLanguages.contains(l) { return .asian }
            if Region.southAsianLanguages.contains(l) { return .indian }
            return l == "en" ? nil : .foreign
        }
        if countries.contains(where: Region.eastAsianCountries.contains) { return .asian }
        if countries.contains(where: Region.southAsianCountries.contains) { return .indian }
        return nil
    }
}

/// Origin tables for the region categories (ISO 639-1 languages, ISO 3166-1 countries).
enum Region {
    static let eastAsianLanguages: Set<String> = ["ja", "ko", "zh", "cn", "th", "vi", "id", "ms", "tl", "fil", "km", "lo", "my", "mn"]
    static let southAsianLanguages: Set<String> = ["hi", "ta", "te", "ml", "kn", "bn", "mr", "pa", "gu", "ur", "or", "as", "ne", "si"]
    static let eastAsianCountries: Set<String> = ["JP", "KR", "CN", "TW", "HK", "MO", "TH", "VN", "ID", "MY", "PH", "SG", "KH", "LA", "MM", "MN"]
    static let southAsianCountries: Set<String> = ["IN", "PK", "BD", "LK", "NP"]
}

/// Add-ons list genres by name ("Reality-TV"). Maps the ones the filter cares about to their TMDB ids.
enum GenreNames {
    private static let table: [String: Int] = [
        "animation": 16, "documentary": 99, "family": 10751, "kids": 10762, "children": 10762,
        "news": 10763, "reality": 10764, "realitytv": 10764, "soap": 10766,
        "talk": 10767, "talkshow": 10767, "horror": 27, "romance": 10749,
    ]

    static func ids(from names: [String]) -> [Int] {
        names.compactMap { table[$0.lowercased().filter(\.isLetter)] }
    }
}

extension MetaPreview {
    /// Anime add-ons (Kitsu, MAL, AniList...) say so in the catalogue type or the id prefix: no lookup needed.
    var isAnimeByIdentity: Bool {
        type == "anime" || ["kitsu:", "mal:", "anidb:", "anilist:"].contains { id.hasPrefix($0) }
    }

    /// Genres and origin as far as the source told us. nil = the source said nothing about genres.
    var traits: TitleTraits? {
        guard let genreIDs else { return nil }
        return TitleTraits(genres: Set(genreIDs), language: language, countries: countries ?? [])
    }
}

/// The user's content settings for one profile, and the decision logic that applies them.
/// Pure value type: no I/O, safe to hand to background tasks.
struct ContentRules: Hashable, Sendable {
    var hiddenCategories: Set<ContentCategory> = []
    /// Rows switched off on Home / Explore (see `rowKey` and `Builtin`).
    var hiddenRows: Set<String> = []
    /// Add-on catalogues the user chose to put on Home (`rowKey`). Only used for add-ons with a long catalogue list
    /// that starts empty, like AIOMetadata (see `AddonStore.usesCatalogPicker`): nothing from them shows until added.
    var addedRows: Set<String> = []
    /// Search is an explicit request, so by default it isn't filtered.
    var filterSearch = false

    static let none = ContentRules()

    var hasFilters: Bool { !hiddenCategories.isEmpty }

    /// Some region (Asian, Indian & South Asian, Other foreign-language) is switched off.
    var hidesRegions: Bool { hiddenCategories.contains { $0.isRegion } }

    /// True when a theme row built from titles in this original language could only ever show hidden titles
    /// ("K-Drama Fever" with Asian titles off), so it needn't be fetched at all.
    func hidesLanguage(_ language: String) -> Bool {
        guard hidesRegions else { return false }
        let t = TitleTraits(genres: [], language: language, countries: [])
        return t.region.map { hiddenCategories.contains($0) } ?? false
    }

    /// Something is switched off (a category, a row or search filtering). Catalogues the user added don't count:
    /// "Show everything again" must not take those away.
    var hidesAnything: Bool { !hiddenCategories.isEmpty || !hiddenRows.isEmpty || filterSearch }

    /// Changes whenever the category choice does. Used as a `.task(id:)` so screens reload exactly when needed.
    var categoryKey: String { hiddenCategories.map(\.rawValue).sorted().joined(separator: ",") }
    /// Changes whenever an add-on catalogue is switched on or off, or added to / removed from Home.
    var addonRowKey: String {
        let hidden: String = hiddenRows.filter { $0.hasPrefix("addon:") }.sorted().joined(separator: ",")
        let added: String = addedRows.sorted().joined(separator: ",")
        return hidden + "|" + added
    }

    // MARK: Rows

    /// Built-in Home rows.
    enum Builtin {
        static let trendingMovies = "builtin:trend-movie"
        static let trendingShows = "builtin:trend-tv"
        static let because = "builtin:because"
        static let themes = "builtin:themes"
    }

    /// Stable id of an add-on catalogue. Uses the add-on's manifest id, never its URL (debrid add-on URLs hold API keys),
    /// so the choice also survives re-adding an add-on with new settings.
    static func rowKey(_ addon: Addon, _ catalog: AddonManifest.CatalogDef) -> String {
        "addon:\(addon.manifest.id)/\(catalog.type)/\(catalog.id)"
    }

    func isRowHidden(_ key: String?) -> Bool {
        guard let key else { return false }
        return hiddenRows.contains(key)
    }

    func isRowAdded(_ key: String) -> Bool { addedRows.contains(key) }

    /// Whether this catalogue gets a row on Home. Add-ons with a catalogue picker show only what was added;
    /// every other add-on shows everything that wasn't switched off.
    func showsOnHome(_ addon: Addon, _ catalog: AddonManifest.CatalogDef, picker: Bool) -> Bool {
        let key = Self.rowKey(addon, catalog)
        return picker ? addedRows.contains(key) : !hiddenRows.contains(key)
    }

    // MARK: Genres

    /// True when picking this genre in Explore could only ever show hidden titles.
    func hidesGenre(_ id: Int) -> Bool {
        if id == ContentCategory.animationGenre {
            return hiddenCategories.contains(.anime) && hiddenCategories.contains(.cartoons)
        }
        return hiddenCategories.contains { $0.genreIDs?.contains(id) == true }
    }

    /// TMDB `without_genres` value for the categories that are plain genres. Only an optimisation, so Explore pages
    /// come back full: `outcome` stays the authority.
    var excludedGenreQuery: String? {
        let ids = hiddenCategories.compactMap(\.genreIDs).flatMap { $0 }
        return ids.isEmpty ? nil : Set(ids).sorted().map(String.init).joined(separator: ",")
    }

    // MARK: Decisions

    enum Outcome { case hide, keep, undecided }

    /// `resolved` is what a TMDB lookup found, when one has been done.
    func outcome(for item: MetaPreview, resolved: TitleTraits? = nil) -> Outcome {
        guard hasFilters else { return .keep }
        if item.isAnimeByIdentity { return hiddenCategories.contains(.anime) ? .hide : .keep }
        guard let t = resolved ?? item.traits else { return .undecided }
        return outcome(forTraits: t)
    }

    func outcome(forTraits t: TitleTraits) -> Outcome {
        for c in hiddenCategories {
            if let ids = c.genreIDs, !t.genres.isDisjoint(with: ids) { return .hide }
        }
        // Animation is anime or a cartoon, whatever its region.
        if t.isAnimation {
            guard hiddenCategories.contains(.anime) || hiddenCategories.contains(.cartoons) else { return .keep }
            guard t.hasOrigin else { return .undecided }
            let kind: ContentCategory = t.isJapanese ? .anime : .cartoons
            return hiddenCategories.contains(kind) ? .hide : .keep
        }
        // Live-action: hidden when its region is switched off.
        guard hidesRegions else { return .keep }
        guard t.hasOrigin else { return .undecided }
        if let r = t.region, hiddenCategories.contains(r) { return .hide }
        return .keep
    }

    /// Verdict when a lookup isn't possible (no TMDB key, offline, unknown id). Animation of unknown origin goes when
    /// either animation category is hidden, since it might be either. Titles we know nothing about stay.
    func fallbackHides(_ item: MetaPreview) -> Bool {
        guard let t = item.traits, t.isAnimation else { return false }
        return hiddenCategories.contains(.anime) || hiddenCategories.contains(.cartoons)
    }
}

/// Stored tolerantly: a value written by a newer build (an unknown category) is dropped, never fatal.
extension ContentRules: Codable {
    private enum K: String, CodingKey { case categories, rows, added, filterSearch }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let names = (try? c.decodeIfPresent([String].self, forKey: .categories)) ?? []
        hiddenCategories = Set(names.compactMap(ContentCategory.init(rawValue:)))
        hiddenRows = Set((try? c.decodeIfPresent([String].self, forKey: .rows)) ?? [])
        addedRows = Set((try? c.decodeIfPresent([String].self, forKey: .added)) ?? [])
        filterSearch = (try? c.decodeIfPresent(Bool.self, forKey: .filterSearch)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(hiddenCategories.map(\.rawValue).sorted(), forKey: .categories)
        try c.encode(hiddenRows.sorted(), forKey: .rows)
        try c.encode(addedRows.sorted(), forKey: .added)
        try c.encode(filterSearch, forKey: .filterSearch)
    }
}
