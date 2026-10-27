import AppKit
import Foundation

/// Opens a song you asked her to play, on YouTube, Spotify or Apple Music. No account or API
/// key is involved: an official video from the song knowledge base plays straight away, a song
/// in your Music library plays through Music, anything else opens that service's search.
@MainActor
final class MusicPlayback {
    static let shared = MusicPlayback()

    private static let lastPlatformKey = "music.lastPlatform"
    private static let spotifyBundleID = "com.spotify.client"
    private static let musicBundleID = "com.apple.Music"

    private let defaults: UserDefaults
    private let knowledge: SongKnowledgeStore
    private let vocaDB: VocaDBLookup

    init(defaults: UserDefaults = .standard, knowledge: SongKnowledgeStore = .shared, vocaDB: VocaDBLookup = .shared) {
        self.defaults = defaults
        self.knowledge = knowledge
        self.vocaDB = vocaDB
    }

    /// The service you named last time; YouTube until you name one.
    var defaultPlatform: MusicPlatform {
        defaults.string(forKey: Self.lastPlatformKey).flatMap(MusicPlatform.init(rawValue:)) ?? .youtube
    }

    /// Song titles she knows, so "我想聽 Tell Your World" counts as asking to play it.
    func knownTitles() async -> [String] {
        await knowledge.allEntries().filter { $0.kind == .song }.flatMap(\.aliases)
    }

    func plan(for request: MusicRequest) async -> MusicPlan {
        if let named = request.platform { defaults.set(named.rawValue, forKey: Self.lastPlatformKey) }
        let platform = request.platform ?? defaultPlatform
        guard !request.query.isEmpty else {
            return MusicPlan(platform: platform, mode: .openService, title: "", searchTerms: "")
        }
        let entry = await knowledge.entries(matching: request.query).first { $0.kind == .song }
        // Not in the knowledge base, or listed without a YouTube video: VocaDB (only if you
        // turned it on) may know the song and its official upload.
        let knownVideo = entry.flatMap { MusicLinks.officialYouTubeVideo($0.sourceURL) }
        let found = knownVideo == nil ? await vocaDB.song(for: entry?.displayTitle ?? request.query) : nil
        let title = entry?.displayTitle ?? found?.name ?? request.query
        let creator = entry?.creators.first ?? found?.producers.first
        let searchTerms = [title, creator].compactMap { $0 }.joined(separator: " ")
        let officialVideo = knownVideo ?? found?.youtube
        let mode: MusicPlan.Mode
        switch platform {
        case .youtube:
            mode = officialVideo.map(MusicPlan.Mode.officialVideo) ?? .youtubeSearch
        case .spotify:
            mode = .spotifySearch
        case .appleMusic:
            mode = .appleMusicLibrary
        }
        return MusicPlan(platform: platform, mode: mode, title: title, searchTerms: searchTerms)
    }

    func perform(_ plan: MusicPlan) async {
        switch plan.mode {
        case let .officialVideo(url):
            open(url)
        case .youtubeSearch:
            MusicLinks.youtubeSearch(plan.searchTerms).map(open)
        case .spotifySearch:
            if hasApp(Self.spotifyBundleID), let url = MusicLinks.spotifyAppSearch(plan.searchTerms) {
                open(url)
            } else {
                MusicLinks.spotifyWebSearch(plan.searchTerms).map(open)
            }
        case .appleMusicLibrary:
            if await Self.playFromLibrary(title: plan.title) { return }
            MusicLinks.appleMusicSearch(plan.searchTerms).map(open)
        case .openService:
            switch plan.platform {
            case .youtube: open(MusicLinks.youtubeHome)
            case .spotify:
                if let app = appURL(Self.spotifyBundleID) { openApp(app) } else { open(MusicLinks.spotifyWeb) }
            case .appleMusic:
                if let app = appURL(Self.musicBundleID) { openApp(app) }
            }
        }
    }

    // MARK: - Helpers

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func hasApp(_ bundleID: String) -> Bool { appURL(bundleID) != nil }

    private func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func openApp(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Searches your Music library and plays the first song found. Uses the same Automation
    /// permission as reading what's playing; false if not found or not allowed.
    nonisolated private static func playFromLibrary(title: String) async -> Bool {
        guard let literal = AwarenessPolicy.appleScriptStringLiteral(title) else { return false }
        let source = """
        tell application "Music"
          set found to (search library playlist 1 for \(literal) only songs)
          if (count of found) is 0 then return "none"
          play item 1 of found
          return "playing"
        end tell
        """
        return await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error == nil && result?.stringValue == "playing"
        }.value
    }
}
