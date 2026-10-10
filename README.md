# MediaHub (iOS 26, SwiftUI)
App name "Pear.", version 0.1.0, bundle id `com.mediahub.pear` (set in `project.yml`).

1. `brew install xcodegen && xcodegen` (generates MediaHub.xcodeproj from project.yml)
2. Open in Xcode 26, run on an iOS 26 simulator/device.
Or: new iOS App project in Xcode 26, drag in the `MediaHub/` folder.

Next: Player (AVPlayer) -> Simkl PIN login/sync -> MDBList ratings/lists -> TVDB artwork -> Library/Search.

## Peer-to-peer (opt-in)
Torrentio torrent streams play through an embedded Rust engine (`p2p-core/`, librqbit + UniFFI). Off by default: Settings -> Peer-to-peer.
- CI builds `Vendor/P2PCore.xcframework` before `xcodegen` (see `.github/workflows/build.yml`). Locally: `cd p2p-core && make xcframework`.
- Swift side lives in `MediaHub/P2P/`. Engine only exists while a P2P stream is playing; idle/background/memory/network changes tear it down.

## Jellyfin & Plex
Settings -> Integrations -> Media servers. Sign in to a Jellyfin server (password or Quick Connect) and/or a Plex account (Plex's own login page; every server on the account is offered).
- **Sources:** a title that is in the library shows up in the Sources list, in the player's source switcher and for next-episode, ahead of every add-on. Files are played as they are (direct play through the same player engine), one source per version of the file. Titles are matched by IMDb id; a title without one in Jellyfin / Plex isn't found.
- **Home and Search:** each server adds "New" rows for movies and series (touch and hold the server in Media servers to hide them) and takes part in search.
- **How it plugs in** (`MediaHub/Servers/`): each enabled server is a synthetic add-on (`Addon.server`, `pear-server://<id>/manifest.json`, never fetched). `AddonClient.catalog` and `streamUpdates` hand its requests to a `MediaServerBackend` (`JellyfinBackend`, `PlexBackend`), so pins, filters, the player and Home need no special cases. `MediaServerStore` keeps accounts in UserDefaults and tokens in the Keychain; neither is in a settings backup.
- **Plex** lists the whole library once (500 titles a request) the first time it is needed and keeps that for 15 minutes; matching, "New" and search run on it. Episodes are fetched per show when one is opened. The server's other connections (LAN, remote, relay) are tried in turn if the saved one stops answering.
- **Not done:** progress isn't reported back to Jellyfin / Plex (watch state stays in Pear and Simkl), no transcoding, no external subtitle tracks from the server, and downloads still need an https link.
- `NSLocalNetworkUsageDescription` is set in `project.yml`; iOS asks for local-network access the first time a LAN server is reached.

## Picture in Picture
The pill in the player has a PiP button (native AVPlayer path only; hidden for software-decoded AV1 / VP9). Leaving the app while a video plays opens the window automatically. Code: `MediaHub/Features/PlayerPiP.swift`.

## Content & catalogues
Settings -> Content & catalogues. Saved per profile, so a kids' profile can hide what yours doesn't.
- **Categories:** switch off Anime, Cartoons & animation, Kids & family, Documentaries, Reality TV, Talk & news, Soap operas, Horror or Romance. Hidden titles are removed from Home, Explore, recommendations, themed collections and "See all" pages. Search is unfiltered unless you turn on "Also filter search results". Continue Watching and your library are never filtered.
- **Rows:** switch off built-in Home rows and individual add-on catalogues (or touch and hold a row title on Home -> Hide this row). Hidden catalogues are skipped before the 12-row cap, so they don't use up slots.
- **AIOMetadata:** Settings -> Content & catalogues -> AIOMetadata. An AIOMetadata add-on can offer dozens of catalogues (TMDB, TVDB, MDBList, MAL, streaming services...), so unlike other add-ons none of them show on Home until you add them. Switch a catalogue on to give it a row, off (or touch and hold its row title on Home -> Remove from Home) to take it away. Saved per profile and included in settings backups; "Show everything again" leaves them alone. The add-on is recognised by \"aiometadata\" in its manifest id, name, description or host (`Addon.isAIOMetadata`); a copy hosted under another name can be switched on by hand under \"Other add-ons\" on that screen. Added rows are not counted against the 12-row cap. Code: `Features/AIOMetadataSettingsView.swift`, `ContentRules.addedRows`.
- **How titles are classified** (`Core/ContentRules.swift`, `Core/TitleClassifier.swift`): TMDB lists already carry genres and original language, and most add-ons list genre names, so most titles are decided with no extra request. Anime = Animation + Japanese origin; Cartoons = any other Animation. Titles that can't be decided (an add-on that lists no genres, or Animation with no origin) cost one small TMDB request each, run six at a time, and the answer is cached on disk forever. Kitsu/MAL/AniList items count as anime from their id alone.
- **Without a TMDB key** anime and cartoons can't be told apart, so all animation is hidden while either is off. Titles with no genre info at all stay visible.
- Adding a category: a case in `ContentCategory` plus its TMDB genre ids.

## Themed rows
Editorial collections ("Small-Town Secrets", "K-Drama Fever"...) on Home and Explore. Code: `Features/Themerows.swift`.
- **Catalogue:** `ThemeCatalog.all`, about 65 themes. Each is a set of TMDB keywords, or an original language (`language: "ko"`) for the "around the world" ones. Add your own with any phrase TMDB uses as a keyword; if the name isn't an exact match TMDB's closest hit is used, and a theme that ends up with fewer than three titles is skipped.
- **Rotation:** one daily slate of 10 themes (Home's 6 candidates, then Explore's 4), taken from seeded shuffles of the whole catalogue. Nothing repeats until every theme has had a turn, consecutive days never overlap, and Home and Explore never share a theme. Home shows 5 rows (the sixth is a spare in case one theme is empty), spread through the feed: after Continue Watching, after the suggestions, after your lists, then after every second add-on row. Explore shows 3.
- **AIOMetadata enrichment:** when an AIOMetadata add-on (or one marked as such under Settings -> Content & catalogues -> AIOMetadata) is switched on and serves `meta`, theme rows load from TMDB first and are then updated in place with the add-on's genres (the caption under the logo) and its title logo, which takes priority over the TMDB / TVDB logo for the session. Only the first 8 titles of a row are looked up; titles the add-on doesn't know keep their TMDB data. Skipped in Low Power Mode. Code: `ThemeEnrichment`, `AddonClient.metaExtras`, `LogoResolver.prefer`.


## Performance & battery notes
- **Hidden pages rest.** The sidebar layout keeps visited pages alive under `opacity(0)`, so `onAppear`/`onDisappear` never fire for them. `EnvironmentValues.pageActive` (set in `SidebarShell`, and cleared for the poster panel while the pane covers it) tells loops like the hero auto-advance and Ken Burns zoom to stop. `HeroCarousel` / `WideHeroPanel` also stop outside `scenePhase == .active`.
- **Failed reloads keep the page.** Home's rows, suggestions and lists no longer swap in an empty result when every request failed; they keep what is on screen (re-filtered with the current content rules) and are not marked fresh, so the next visit retries.
- **Explore theme rows** are loaded once per 15 minutes per input set and swapped in once, not rebuilt every time the tab is revisited.
- **TMDB**: one shared `/find` per IMDb id (a detail page used to send several), no request at all for ids TMDB can't resolve (kitsu:, mal:...), URLs built without force unwraps, keyword/id caches written in batches and flushed when the app leaves the foreground.
- **Logos**: cache writes are batched; "no logo" answers are kept for 6 h on disk (not recorded while offline).
- **Downloads**: URLSession progress callbacks are throttled to 1% steps on the delegate queue before touching the main actor; season enqueue saves the index once.
- **Pear loader** runs at 30 fps (the launch intro stays at 60 unless Low Power Mode / heat).
- **Player** banks the resume point when paused and when the app goes to the background.
