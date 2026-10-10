import SwiftUI

/// Editorial-style collections for Home ("Small-Town Secrets"). Each theme is a set of TMDB keywords (and, for a few,
/// an original language); the row shows the most popular shows and movies that match. Home and Explore take their
/// rows from one shared daily slate (see `ThemeCatalog.today`).
struct ThemeDef {
    let title: String
    let keywords: [String]
    /// ISO 639-1 original language ("ko"). With no keywords, the theme is simply "popular in that language".
    var language: String? = nil
}

struct ThemeRow: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [ThemedTitle]

    /// Only movies ("movie") or only shows ("series"); nil when too few are left to fill a row.
    func filtered(type: String) -> ThemeRow? {
        let kept = items.filter { $0.item.type == type }
        return kept.count >= 3 ? ThemeRow(id: id + "-" + type, title: title, items: kept) : nil
    }
}

enum ThemeCatalog {
    /// Rows Home shows, and how many it loads to get them (a theme with too little data is skipped, the spare fills in).
    static let homeRows = 5
    static let homeCandidates = 6
    /// Same for Explore, whose Movies / Shows tabs each drop themes that are mostly the other kind.
    static let exploreRows = 3
    static let exploreCandidates = 4
    /// Themes consumed per day: Home's candidates first, then Explore's, so the two screens never share one.
    private static let perDay = homeCandidates + exploreCandidates

    /// Add your own: any phrase TMDB uses as a keyword works. If TMDB has no keyword with exactly that name it uses
    /// the closest search hit, so keep phrases specific. A theme that ends up with fewer than three titles is skipped.
    static let all: [ThemeDef] = [
        // Mystery, crime & suspense
        ThemeDef(title: "Small-Town Secrets", keywords: ["small town"]),
        ThemeDef(title: "Cold Case Obsessions", keywords: ["cold case", "serial killer"]),
        ThemeDef(title: "Whodunit Weekends", keywords: ["whodunit", "murder mystery"]),
        ThemeDef(title: "Missing Without a Trace", keywords: ["missing person", "kidnapping"]),
        ThemeDef(title: "Heists & Con Artists", keywords: ["heist", "con artist"]),
        ThemeDef(title: "Mob Life", keywords: ["mafia", "organized crime"]),
        ThemeDef(title: "Behind Bars", keywords: ["prison", "prison escape"]),
        ThemeDef(title: "Undercover Operations", keywords: ["undercover"]),
        ThemeDef(title: "Hitmen & Assassins", keywords: ["hitman", "assassin"]),
        ThemeDef(title: "Mind Games", keywords: ["psychological thriller"]),
        ThemeDef(title: "Twist Endings", keywords: ["twist ending"]),
        ThemeDef(title: "Cult Fascinations", keywords: ["cult"]),
        ThemeDef(title: "Follow the Money", keywords: ["white collar crime", "fraud"]),
        ThemeDef(title: "Digital Danger", keywords: ["hacker", "cybercrime"]),
        ThemeDef(title: "Spy Games", keywords: ["spy", "espionage"]),
        ThemeDef(title: "Conspiracies & Cover-Ups", keywords: ["conspiracy", "cover-up"]),
        ThemeDef(title: "Courtroom Drama", keywords: ["courtroom", "lawyer"]),
        ThemeDef(title: "Revenge Served Cold", keywords: ["revenge"]),

        // Sci-fi & fantasy
        ThemeDef(title: "Beyond the Stars", keywords: ["space travel", "outer space"]),
        ThemeDef(title: "Time After Time", keywords: ["time travel", "time loop"]),
        ThemeDef(title: "Parallel Worlds", keywords: ["parallel universe", "multiverse"]),
        ThemeDef(title: "Machines Rising", keywords: ["artificial intelligence", "robot"]),
        ThemeDef(title: "Cyberpunk Futures", keywords: ["cyberpunk", "virtual reality"]),
        ThemeDef(title: "After the End", keywords: ["post-apocalyptic", "dystopia"]),
        ThemeDef(title: "Epic Fantasy Worlds", keywords: ["dragon", "sword and sorcery"]),
        ThemeDef(title: "Wizards & Witchcraft", keywords: ["witch", "wizard"]),
        ThemeDef(title: "Myths & Legends", keywords: ["mythology", "greek mythology"]),
        ThemeDef(title: "Superhero Origins", keywords: ["superhero", "super power"]),
        ThemeDef(title: "Lost Worlds", keywords: ["dinosaur", "lost world"]),
        ThemeDef(title: "Outbreak", keywords: ["pandemic", "virus"]),

        // Horror
        ThemeDef(title: "Ghost Stories", keywords: ["ghost", "haunted house"]),
        ThemeDef(title: "Creature Features", keywords: ["monster", "giant monster"]),
        ThemeDef(title: "Undead Obsessions", keywords: ["zombie", "vampire"]),

        // Drama, family & relationships
        ThemeDef(title: "Behind Closed Doors", keywords: ["dysfunctional family", "family secrets"]),
        ThemeDef(title: "Found Family", keywords: ["found family"]),
        ThemeDef(title: "Coming of Age", keywords: ["coming of age"]),
        ThemeDef(title: "Forbidden Love", keywords: ["forbidden love", "love triangle"]),
        ThemeDef(title: "Wedding Season", keywords: ["wedding"]),
        ThemeDef(title: "Road Trip Therapy", keywords: ["road trip"]),
        ThemeDef(title: "Boarding School Intrigue", keywords: ["boarding school"]),
        ThemeDef(title: "Anti-Heroes", keywords: ["antihero"]),
        ThemeDef(title: "Underdog Stories", keywords: ["underdog", "sports"]),

        // Work, power & ambition
        ThemeDef(title: "Code Blue", keywords: ["hospital", "doctor"]),
        ThemeDef(title: "Stop the Presses", keywords: ["journalist", "newspaper"]),
        ThemeDef(title: "Politics & Power", keywords: ["political intrigue", "corruption"]),
        ThemeDef(title: "Crowns & Conspiracies", keywords: ["monarchy", "royal family"]),
        ThemeDef(title: "Kitchen Confidential", keywords: ["chef", "restaurant"]),
        ThemeDef(title: "Rock & Roll Stories", keywords: ["rock band", "musician"]),
        ThemeDef(title: "Wall Street Wolves", keywords: ["wall street", "stock market"]),

        // History & true stories
        ThemeDef(title: "Based on True Stories", keywords: ["based on true story"]),
        ThemeDef(title: "War Stories", keywords: ["world war ii"]),
        ThemeDef(title: "Cold War Tension", keywords: ["cold war"]),
        ThemeDef(title: "Medieval Intrigue", keywords: ["medieval", "knight"]),
        ThemeDef(title: "Samurai & Shinobi", keywords: ["samurai", "ninja"]),

        // Adventure & survival
        ThemeDef(title: "Survival Against the Odds", keywords: ["survival", "wilderness"]),
        ThemeDef(title: "Stranded", keywords: ["island", "shipwreck"]),
        ThemeDef(title: "High Seas", keywords: ["pirate", "sailing"]),
        ThemeDef(title: "Treasure Hunters", keywords: ["treasure hunt", "treasure"]),
        ThemeDef(title: "Disaster Zone", keywords: ["natural disaster"]),
        ThemeDef(title: "Martial Arts Mastery", keywords: ["martial arts", "kung fu"]),

        // Around the world (original language)
        ThemeDef(title: "K-Drama Fever", keywords: [], language: "ko"),
        ThemeDef(title: "Spanish-Language Standouts", keywords: [], language: "es"),
        ThemeDef(title: "French Connection", keywords: [], language: "fr"),
        ThemeDef(title: "Made in Germany", keywords: [], language: "de"),
        ThemeDef(title: "Turkish Dramas", keywords: [], language: "tr"),
        ThemeDef(title: "Bollywood & Beyond", keywords: [], language: "hi"),
    ]

    /// Today's themes, starting `offset` into the day's slate. Home takes the first `homeCandidates`, Explore the
    /// next `exploreCandidates`, so the two never show the same one. The same themes all day, new ones tomorrow.
    static func today(count: Int, offset: Int = 0) -> [ThemeDef] {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        let slate = slate(forDay: day)
        return (0..<count).map { slate[(offset + $0) % slate.count] }
    }

    /// The day's themes, in order. Each "deck" is the whole catalogue shuffled with a fixed seed; days take the next
    /// `perDay` themes along the decks, so nothing repeats until every theme has had its turn, consecutive days
    /// never overlap, and a theme doesn't always sit beside the same neighbours when the catalogue comes round again.
    private static func slate(forDay day: Int) -> [ThemeDef] {
        let n = all.count
        guard n > perDay else { return all }
        var picked: [Int] = []
        var position = day * perDay
        while picked.count < perDay {
            let index = deck(position / n)[position % n]
            if !picked.contains(index) { picked.append(index) }     // only matters where two decks meet
            position += 1
        }
        return picked.map { all[$0] }
    }

    private static func deck(_ number: Int) -> [Int] {
        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: number) &+ 0x9E37_79B9_7F4A_7C15)
        return Array(all.indices).shuffled(using: &rng)
    }

    /// The first `show` rows that have data, in theme order (nil = all of them).
    private static func visible(_ done: [Int: ThemeRow], show: Int?) -> [ThemeRow] {
        let rows = done.keys.sorted().compactMap { done[$0] }
        guard let show else { return rows }
        return Array(rows.prefix(show))
    }

    /// Loads the rows concurrently and reports after each one lands (in theme order). A theme with too little data is
    /// skipped. With an AIOMetadata add-on given, rows show up straight from TMDB first and are then enriched in place
    /// (see `ThemeEnrichment`), so the add-on never delays them.
    static func load(count: Int, offset: Int = 0, limit: Int = 8, show: Int? = nil, rules: ContentRules = .none,
                     enrichWith addon: Addon? = nil,
                     update: @MainActor @escaping ([ThemeRow]) -> Void) async {
        guard TMDBClient.shared.hasKey, !rules.isRowHidden(ContentRules.Builtin.themes) else { await update([]); return }
        var done: [Int: ThemeRow] = [:]
        await withTaskGroup(of: (Int, ThemeRow?).self) { group in
            for (i, t) in today(count: count, offset: offset).enumerated() {
                group.addTask {
                    let items = await TMDBClient.shared.themed(keywords: t.keywords, language: t.language,
                                                               limit: limit, rules: rules)
                    return (i, items.count >= 3 ? ThemeRow(id: "theme-\(t.title)", title: t.title, items: items) : nil)
                }
            }
            for await (i, row) in group {
                guard let row else { continue }
                done[i] = row
                await update(visible(done, show: show))
            }
        }
        guard let addon, !Task.isCancelled else { return }
        // Decorative extras: skipped in Low Power Mode / when the phone is hot.
        let saving = await MainActor.run { PowerMode.shared.saving }
        guard !saving else { return }
        let shown = Array(done.keys.sorted().prefix(show ?? done.count))
        await withTaskGroup(of: (Int, ThemeRow).self) { group in
            for i in shown {
                guard let row = done[i] else { continue }
                group.addTask { (i, await ThemeEnrichment.enrich(row, with: addon)) }
            }
            for await (i, row) in group {
                guard !Task.isCancelled else { return }
                done[i] = row
                await update(visible(done, show: show))
            }
        }
    }
}

/// Fills theme rows with what the user's AIOMetadata add-on knows about each title, when it is installed.
///
/// - **Genres** under the logo come from the add-on (so they match the rest of the add-on's metadata) instead of
///   TMDB's two first genres.
/// - **Title logo** is the one the add-on serves (it follows whichever artwork providers the user set up there),
///   and takes priority over the TMDB / TVDB logo for that title for this session.
///
/// Only the first `limit` titles of a row are looked up, and a title the add-on doesn't know (or that fails to
/// answer in time) just keeps its TMDB data.
enum ThemeEnrichment {
    static let limit = 8

    static func enrich(_ row: ThemeRow, with addon: Addon) async -> ThemeRow {
        var items = row.items
        await withTaskGroup(of: (Int, ThemedTitle?).self) { group in
            for (i, title) in row.items.enumerated() where i < limit {
                group.addTask { (i, await enrich(title, with: addon)) }
            }
            for await (i, title) in group { if let title { items[i] = title } }
        }
        return ThemeRow(id: row.id, title: row.title, items: items)
    }

    private static func enrich(_ title: ThemedTitle, with addon: Addon) async -> ThemedTitle? {
        let item = title.item
        // Most add-ons that serve metadata accept TMDB ids; if this one only takes IMDb ids, translate (cached).
        var lookup = item.id
        if !addon.provides("meta", type: item.type, id: lookup),
           lookup.hasPrefix("tmdb:"), let n = Int(lookup.dropFirst(5)),
           let imdb = await TMDBClient.shared.imdbID(tmdb: n, type: item.type) {
            lookup = imdb
        }
        let extras = await AddonClient.shared.metaExtras(addon: addon, type: item.type, id: lookup)
        guard !Task.isCancelled else { return nil }

        var enriched = item
        if let logo = extras.logo, await LogoResolver.shared.prefer(logo, for: item.id) {
            enriched = item.with(logo: logo.absoluteString)
        }
        let genres = extras.genres.isEmpty ? title.genres : Array(extras.genres.prefix(2))
        guard genres != title.genres || enriched.logo != item.logo else { return nil }
        return ThemedTitle(item: enriched, genres: genres)
    }
}

/// Small deterministic generator, so a "shuffle" can be repeated: the same seed gives the same order on every launch.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct ThemeCarousel: View {
    let row: ThemeRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.title).font(.title2.bold()).padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(row.items) { ThemeCard(entry: $0) }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// Big 4:5 card: key art, a small tag, the title logo and "TV Show · Thriller · Mystery". The next card peeks in.
private struct ThemeCard: View {
    let entry: ThemedTitle
    @Environment(\.wideLayout) private var wide
    private var item: MetaPreview { entry.item }

    private var tag: String? {
        var parts: [String] = []
        if let y = item.year { parts.append(String(y)) }
        if let r = item.rating { parts.append("★ " + String(format: "%.1f", r)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var caption: String {
        ([item.type == "series" ? "TV Show" : "Movie"] + entry.genres).joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: item) {
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .containerRelativeFrame(.horizontal) { w, _ in wide ? 270 : min(w - 56, 440) }
                .overlay { RotatingArtwork(item: item, kind: .hero(wide: false), size: 440) }
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.85), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) { info }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1) }
        }
        .buttonStyle(PressableStyle())
        .posterContextMenu(item)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tag {
                Text(tag).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.black.opacity(0.35), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
            TitleArt(item: item, maxWidth: 260, maxHeight: 72, font: .system(size: 30, weight: .heavy, design: .rounded))
            HStack(spacing: 8) {
                Image(systemName: item.type == "series" ? "tv" : "film")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26).background(.black.opacity(0.35), in: Circle())
                Text(caption).font(.subheadline.weight(.medium)).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
