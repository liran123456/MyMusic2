// AdFreeGoogleApp.swift — גרסה 10: "המוזיקה שלי"
// • גוגל בלי פרסומות • יוטיוב בעיצוב אפליקציית שירים
// • חיפוש רק שירים • ניגון ברקע • שליטה ממסך הנעילה
// • פלייליסטים • ערבוב וחזרה • טיימר שינה • מצב תקליט • צבע לפי השיר
// • החלקה על הנגן הקטן • "עוד כמו זה" • היסטוריית חיפושים • הכי מושמעים
// iOS 17+. עיצוב Liquid Glass ב-iOS 26 ומעלה.

import SwiftUI
import WebKit
import AVFoundation
import AppIntents
import MediaPlayer
import Network
import UniformTypeIdentifiers

/// ב-iOS 26 ומעלה סרגל הלשוניות "צף" וגבוה יותר — מרימים את הנגן הקטן מעליו
enum Layout {
    static var tabBarExtra: CGFloat {
        // רק כשהאפליקציה נבנתה עם הכלים של iOS 26 הסרגל באמת "צף" (במחשב בנייה ישן יותר הוא רגיל)
        #if compiler(>=6.2)
        if #available(iOS 26, *) { return 44 }
        #endif
        return 0
    }
}

enum Theme: String, CaseIterable, Identifiable {
    case pink, blue, green, purple, orange
    var id: String { rawValue }
    static var current: Theme { Theme(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .pink }
    var name: String {
        switch self {
        case .pink: return "ורוד"
        case .blue: return "כחול"
        case .green: return "ירוק"
        case .purple: return "סגול"
        case .orange: return "כתום"
        }
    }
    var main: Color {
        switch self {
        case .pink: return Color(red: 0.98, green: 0.24, blue: 0.40)
        case .blue: return Color(red: 0.16, green: 0.50, blue: 1.00)
        case .green: return Color(red: 0.10, green: 0.72, blue: 0.45)
        case .purple: return Color(red: 0.58, green: 0.32, blue: 1.00)
        case .orange: return Color(red: 1.00, green: 0.50, blue: 0.15)
        }
    }
    var second: Color {
        switch self {
        case .pink: return Color(red: 0.55, green: 0.25, blue: 0.95)
        case .blue: return Color(red: 0.36, green: 0.25, blue: 0.92)
        case .green: return Color(red: 0.05, green: 0.50, blue: 0.70)
        case .purple: return Color(red: 0.92, green: 0.30, blue: 0.62)
        case .orange: return Color(red: 0.92, green: 0.22, blue: 0.40)
        }
    }
}

extension Color {
    static var brand: Color { Theme.current.main }
    static var brand2: Color { Theme.current.second }
}

// MARK: - App

@main
struct AdFreeGoogleApp: App {
    @StateObject private var app = AppState.shared
    var body: some Scene {
        WindowGroup {
            RootView(player: app.player, library: app.library)
                .environmentObject(app)
        }
    }
}

enum AppTab { case home, samples, search, library }

final class AppState: ObservableObject {
    /// אותו מופע משמש את האפליקציה ואת סירי
    static let shared = AppState()

    @Published var tab: AppTab = .home
    @Published var showBrowser = false
    @Published var showGoogle = false
    @Published var showSettings = false
    @Published var songToAdd: Song?
    @Published var toast: String?
    @Published var recsSeed = ""
    @Published var isOnline = true
    private let monitor = NWPathMonitor()

    let library = Library()
    let google = WebModel(kind: .google)
    let browser = WebModel(kind: .youtube)
    let searcher = SearchModel()
    let radio = SearchModel()
    let siriSearch = SearchModel()
    let recs = SearchModel()
    let sampler: SearchModel
    let samples: SamplesModel
    let player = PlayerModel()
    private var toastWork: DispatchWorkItem?

    init() {
        let s = SearchModel()
        sampler = s
        samples = SamplesModel(search: s)
        google.openYouTube = { [weak self] url in self?.handleYouTubeLink(url) }
        browser.onPlay = { [weak self] id in self?.playID(id) }
        player.onSongInfo = { [weak self] song in self?.library.record(song) }
        player.onPlayStart = { [weak self] id in self?.library.countPlay(id) }
        player.onNotice = { [weak self] text in self?.showToast(text) }
        player.onNeedMore = { [weak self] song in self?.fillQueue(after: song) }
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let ok = path.status == .satisfied
                self?.player.networkOK = ok
                withAnimation { self?.isOnline = ok }
            }
        }
        monitor.start(queue: DispatchQueue(label: "net"))
        // רק מגדירים — מפעילים את הקול רק כשבאמת מנגנים (כדי לא לעצור מוזיקה של אפליקציות אחרות)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    func handleYouTubeLink(_ url: URL) {
        showGoogle = false
        tab = .home
        if let id = WebModel.videoID(url) { playID(id) }
        else { showBrowser = true; browser.load(WebModel.normalizeYouTube(url)) }
    }

    func playID(_ id: String) {
        play(library.song(id) ?? Song(id: id, title: "", artist: nil), in: nil)
    }

    func play(_ song: Song, in list: [Song]?) {
        player.play(song, in: list)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { player.expanded = true }
    }

    /// מנגן מיד בלי לפתוח את הנגן המלא
    func quickPlay(_ song: Song, in list: [Song]) {
        Haptics.tap()
        if player.current?.id == song.id { player.togglePlay(); return }
        player.play(song, in: list)
    }

    func playShuffled(_ list: [Song]) {
        guard let first = list.randomElement() else { return }
        player.setShuffle(true)
        play(first, in: list)
    }

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        library.addSearch(q)
        tab = .search
        searcher.run(q)
    }

    func loadRecommendations() {
        guard recs.results.isEmpty, !recs.isLoading else { return }
        let seed = library.seedArtists.first ?? "להיטים חדשים"
        recsSeed = seed
        recs.run(seed)
    }

    func startSamples() {
        samples.start(seeds: library.seedArtists)
    }

    // MARK: Siri

    /// מחפש ומנגן את התוצאה הראשונה (בשביל סירי)
    @MainActor
    func searchAndPlay(_ q: String) async -> Song? {
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        library.addSearch(text)
        return await withCheckedContinuation { (cont: CheckedContinuation<Song?, Never>) in
            var finished = false
            siriSearch.onResults = { [weak self] items in
                guard !finished else { return }
                finished = true
                let songs = items.map { $0.song }
                if let first = songs.first, let self {
                    self.player.setShuffle(false)
                    self.play(first, in: songs)
                }
                cont.resume(returning: songs.first)
            }
            siriSearch.run(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                guard !finished else { return }
                finished = true
                cont.resume(returning: nil)
            }
        }
    }

    /// מוסיף לתור שירים דומים כשהוא עומד להיגמר
    func fillQueue(after song: Song) {
        let artist = song.displayArtist
        let q = artist.isEmpty ? song.displayTitle : artist
        guard !q.isEmpty, q != "טוען…" else { player.enqueue([]); return }
        radio.onResults = { [weak self] items in
            guard let self else { return }
            var songs = items.map { $0.song }.filter { $0.id != song.id }
            songs.shuffle()
            self.player.enqueue(songs)
        }
        radio.run(q)
    }

    func moreLikeThis(_ song: Song) {
        let q = song.displayArtist.isEmpty ? song.displayTitle : song.displayArtist
        guard !song.title.isEmpty, !q.isEmpty else { showToast("עוד לא ידוע מה מתנגן"); return }
        showToast("מחפש שירים דומים…")
        radio.onResults = { [weak self] items in
            guard let self else { return }
            let added = self.player.enqueue(items.map { $0.song })
            self.showToast(added > 0 ? "נוספו \(added) שירים לתור" : "לא נמצאו שירים דומים")
        }
        radio.run(q)
    }

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { toast = text }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }
}

/// פיד "טעימות": שירים לפי האמנים שאתה שומע
final class SamplesModel: ObservableObject {
    @Published private(set) var items: [Song] = []
    @Published private(set) var loading = false
    private let search: SearchModel
    private var seeds: [String] = []
    private var seedIndex = 0

    init(search: SearchModel) {
        self.search = search
        search.onResults = { [weak self] r in self?.append(r) }
    }

    func start(seeds s: [String]) {
        guard items.isEmpty, !loading else { return }
        seeds = s.isEmpty ? ["להיטים חדשים", "שירים חדשים 2026"] : s.shuffled()
        seedIndex = 0
        loadMore()
    }

    func loadMore() {
        guard !loading, !seeds.isEmpty, seedIndex < seeds.count * 2 else { return }
        loading = true
        search.run(seeds[seedIndex % seeds.count])
        seedIndex += 1
    }

    private func append(_ r: [SearchItem]) {
        loading = false
        let ids = Set(items.map { $0.id })
        items += r.map { $0.song }.filter { !ids.contains($0.id) }.shuffled()
    }
}

// MARK: - Models

struct Song: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var artist: String?
    var art: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
    var displayTitle: String { title.isEmpty ? "טוען…" : TitleCleaner.split(title, channel: artist).title }
    var displayArtist: String { TitleCleaner.split(title, channel: artist).artist }
}

/// מנקה שמות של יוטיוב: "אודיה - נמשכת לעצמי (Prod. By X) | Official Video" → שיר "נמשכת לעצמי", אמן "אודיה"
enum TitleCleaner {
    private static let noise = "official|video|audio|lyric|lyrics|prod|clip|hd|4k|visuali[sz]er|music|remaster|קליפ|רשמי|מילים|הקליפ|בהפקת|מוזיקלי"
    private static let bracketRx = try! NSRegularExpression(
        pattern: "\\s*[\\(\\[【][^\\)\\]】]*(\(noise))[^\\)\\]】]*[\\)\\]】]", options: [.caseInsensitive])
    private static let tailRx = try! NSRegularExpression(
        pattern: "\\s*(official\\s*(music\\s*)?video|official\\s*audio|lyric\\s*video|קליפ\\s*רשמי|הקליפ\\s*הרשמי)\\s*$",
        options: [.caseInsensitive])
    private static var cache: [String: (title: String, artist: String)] = [:]

    static func split(_ raw: String, channel: String?) -> (title: String, artist: String) {
        let key = raw + "\u{1}" + (channel ?? "")
        if let c = cache[key] { return c }
        var t = raw
        for sep in [" | ", " ｜ ", "｜", " // "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        if let h = t.range(of: " #") { t = String(t[..<h.lowerBound]) }
        for _ in 0..<3 {
            t = bracketRx.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        t = tailRx.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        t = t.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        var artist = cleanChannel(channel ?? "")
        for sep in [" - ", " – ", " — ", " ~ "] {
            if let r = t.range(of: sep) {
                let left = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let right = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty && !right.isEmpty {
                    artist = left
                    t = right
                }
                break
            }
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—\"'"))
        let result = (title: t.isEmpty ? raw : t, artist: artist)
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private static func cleanChannel(_ c: String) -> String {
        var a = c
        for junk in [" - Topic", "VEVO", "Vevo", " Official", " official", " - Official", "Official ", " רשמי", "הערוץ הרשמי של "] {
            a = a.replacingOccurrences(of: junk, with: "")
        }
        // "Static and Ben El - סטטיק ובן אל" → מעדיפים את החלק בעברית
        if let r = a.range(of: " - ") {
            let parts = [String(a[..<r.lowerBound]), String(a[r.upperBound...])]
            if let heb = parts.first(where: { $0.range(of: "\\p{Hebrew}", options: .regularExpression) != nil }) {
                a = heb
            } else {
                a = parts[0]
            }
        }
        return a.trimmingCharacters(in: .whitespaces)
    }
}

struct Playlist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var songs: [Song] = []
}

struct PlayCount: Identifiable {
    let song: Song
    let count: Int
    var id: String { song.id }
}

final class Library: ObservableObject {
    @Published private(set) var liked: [Song] = Library.load("liked") ?? []
    @Published private(set) var recent: [Song] = Library.load("recent") ?? []
    @Published private(set) var playlists: [Playlist] = Library.load("playlists") ?? []
    @Published private(set) var searches: [String] = Library.load("searches") ?? []
    @Published private(set) var playCounts: [String: Int] = Library.load("playCounts") ?? [:]
    private var known: [String: Song] = Library.load("known") ?? [:]

    func isLiked(_ id: String) -> Bool { liked.contains { $0.id == id } }

    func song(_ id: String) -> Song? {
        if let s = known[id], !s.title.isEmpty { return s }
        return liked.first { $0.id == id } ?? recent.first { $0.id == id }
    }

    func toggleLike(_ song: Song) {
        if isLiked(song.id) { liked.removeAll { $0.id == song.id }; Haptics.tap() }
        else { liked.insert(song, at: 0); Haptics.success() }
        save("liked", liked)
    }

    func record(_ song: Song) {
        guard !song.title.isEmpty else { return }
        topCache = nil
        recent.removeAll { $0.id == song.id }
        recent.insert(song, at: 0)
        recent = Array(recent.prefix(50))
        save("recent", recent)
        known[song.id] = song
        pruneKnown()
        save("known", known)
        if let i = liked.firstIndex(where: { $0.id == song.id }) {
            liked[i] = song
            save("liked", liked)
        }
        var changed = false
        for p in playlists.indices {
            if let i = playlists[p].songs.firstIndex(where: { $0.id == song.id }), playlists[p].songs[i] != song {
                playlists[p].songs[i] = song
                changed = true
            }
        }
        if changed { save("playlists", playlists) }
    }

    func clearRecent() { recent = []; save("recent", recent) }

    /// זיכרון השמות גדל עם כל שיר — שומרים רק את מה שבאמת צריך
    private func pruneKnown() {
        guard known.count > 1500 else { return }
        var keep = Set(liked.map { $0.id } + recent.map { $0.id })
        for p in playlists { keep.formUnion(p.songs.map { $0.id }) }
        keep.formUnion(playCounts.sorted { $0.value > $1.value }.prefix(300).map { $0.key })
        known = known.filter { keep.contains($0.key) }
    }

    // הכי מושמעים
    private var topCache: [PlayCount]?

    func countPlay(_ id: String) {
        playCounts[id, default: 0] += 1
        topCache = nil
        save("playCounts", playCounts)
    }

    var topPlayed: [PlayCount] {
        if let c = topCache { return c }
        let result = computeTop()
        topCache = result
        return result
    }

    private func computeTop() -> [PlayCount] {
        playCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .compactMap { pair -> PlayCount? in
                guard let s = song(pair.key), !s.title.isEmpty else { return nil }
                return PlayCount(song: s, count: pair.value)
            }
            .prefix(12)
            .map { $0 }
    }

    /// אמנים שאתה שומע — בסיס להמלצות ולטעימות
    var seedArtists: [String] {
        var out: [String] = []
        for s in topPlayed.map({ $0.song }) + liked + recent {
            let a = s.displayArtist.trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, !out.contains(a) {
                out.append(a)
            }
        }
        return Array(out.prefix(8))
    }

    // היסטוריית חיפושים
    func addSearch(_ q: String) {
        searches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        searches.insert(q, at: 0)
        searches = Array(searches.prefix(10))
        save("searches", searches)
    }

    func clearSearches() { searches = []; save("searches", searches) }

    func clearPlayCounts() { playCounts = [:]; topCache = nil; save("playCounts", playCounts) }

    // MARK: גיבוי ושחזור

    struct Backup: Codable {
        var version = 1
        var created = Date()
        let liked: [Song]
        let playlists: [Playlist]
        let recent: [Song]
        let playCounts: [String: Int]
        let searches: [String]
    }

    /// כותב קובץ גיבוי ומחזיר את המיקום שלו
    func writeBackup() -> URL? {
        let b = Backup(liked: liked, playlists: playlists, recent: recent, playCounts: playCounts, searches: searches)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("המוזיקה-שלי-גיבוי-\(f.string(from: Date())).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(b), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// משחזר מגיבוי — מוסיף למה שיש, לא מוחק כלום
    @discardableResult
    func restoreBackup(from url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let b = try? JSONDecoder().decode(Backup.self, from: data) else { return false }
        for s in b.liked.reversed() where !isLiked(s.id) { liked.insert(s, at: 0) }
        for p in b.playlists {
            if let i = playlists.firstIndex(where: { $0.id == p.id || $0.name == p.name }) {
                for s in p.songs where !playlists[i].songs.contains(where: { $0.id == s.id }) {
                    playlists[i].songs.append(s)
                }
            } else {
                playlists.append(p)
            }
        }
        for s in b.recent where !recent.contains(where: { $0.id == s.id }) { recent.append(s) }
        recent = Array(recent.prefix(50))
        for (k, v) in b.playCounts { playCounts[k] = max(playCounts[k] ?? 0, v) }
        topCache = nil
        for q in b.searches where !searches.contains(q) { searches.append(q) }
        searches = Array(searches.prefix(10))
        for s in b.liked + b.recent where known[s.id] == nil { known[s.id] = s }
        save("liked", liked); save("playlists", playlists); save("recent", recent)
        save("playCounts", playCounts); save("searches", searches); save("known", known)
        return true
    }

    // פלייליסטים
    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    @discardableResult
    func createPlaylist(_ name: String) -> UUID {
        let p = Playlist(name: name)
        playlists.insert(p, at: 0)
        save("playlists", playlists)
        MusicShortcuts.updateAppShortcutParameters()
        return p.id
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
        save("playlists", playlists)
        MusicShortcuts.updateAppShortcutParameters()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save("playlists", playlists)
        MusicShortcuts.updateAppShortcutParameters()
    }

    func add(_ song: Song, to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }),
              !playlists[i].songs.contains(where: { $0.id == song.id }) else { return }
        playlists[i].songs.append(song)
        save("playlists", playlists)
    }

    func remove(_ songID: String, from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].songs.removeAll { $0.id == songID }
        save("playlists", playlists)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    private func save<T: Encodable>(_ key: String, _ value: T) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var player: PlayerModel
    @ObservedObject var library: Library
    @AppStorage("accent") private var accent = Theme.pink.rawValue

    var body: some View {
        let hidePlayer = player.current == nil || player.sampleMode
        let inset: CGFloat = hidePlayer ? 0 : 72 + Layout.tabBarExtra
        ZStack(alignment: .bottom) {
            TabView(selection: $app.tab) {
                MusicHome(library: library, player: player, recs: app.recs, bottomInset: inset)
                    .tabItem { Label("דף הבית", systemImage: "house.fill") }
                    .tag(AppTab.home)
                SamplesView(samples: app.samples, player: player, library: library)
                    .tabItem { Label("טעימות", systemImage: "forward") }
                    .tag(AppTab.samples)
                SearchTab(searcher: app.searcher, library: library, player: player, bottomInset: inset)
                    .tabItem { Label("חיפוש", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)
                LibraryView(library: library, player: player, bottomInset: inset)
                    .tabItem { Label("ספרייה", systemImage: "bookmark") }
                    .tag(AppTab.library)
            }
            .id(accent)
            .sheet(isPresented: $app.showGoogle) {
                NavigationView {
                    GoogleTab(model: app.google, bottomInset: 0)
                        .onAppear { if app.google.webView.url == nil { app.google.goHome() } }
                        .navigationTitle("גוגל")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("סגור") { app.showGoogle = false }
                            }
                        }
                }
            }

            // דפדפנים נסתרים לחיפוש
            WebView(webView: app.searcher.webView)
                .frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false)
            WebView(webView: app.siriSearch.webView)
                .frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false)
            WebView(webView: app.radio.webView)
                .frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false)
            WebView(webView: app.recs.webView)
                .frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false)
            WebView(webView: app.sampler.webView)
                .frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false)
            HiddenVolumeView()
                .frame(width: 1, height: 1).allowsHitTesting(false)

            if player.current != nil {
                PlayerOverlay(player: player, library: library)
                    .opacity(player.sampleMode ? 0.01 : 1)
                    .allowsHitTesting(!player.sampleMode)
            }

            if !app.isOnline {
                VStack {
                    Label("אין חיבור לאינטרנט", systemImage: "wifi.slash")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.red.opacity(0.9), in: Capsule())
                        .padding(.top, 6)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let t = app.toast {
                Toast(text: t)
                    .padding(.bottom, player.expanded ? 40 : inset + 64 + (hidePlayer ? Layout.tabBarExtra : 0))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .tint(Theme(rawValue: accent)?.main ?? .brand)
        .sheet(item: $app.songToAdd) { song in
            AddToPlaylistSheet(song: song, library: library)
        }
        // ההגדרות יושבות מחוץ ללשוניות — כך שבחירת צבע לא סוגרת אותן
        .sheet(isPresented: $app.showSettings) { SettingsView(library: library, player: player) }
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .liquidGlass(in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

// MARK: - Google tab

struct GoogleTab: View {
    @ObservedObject var model: WebModel
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            WebView(webView: model.webView)
            if model.isLoading {
                ProgressView(value: model.progress).progressViewStyle(.linear)
            }
            HStack {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!model.canGoBack)
                Spacer()
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!model.canGoForward)
                Spacer()
                Button { model.goHome() } label: { Image(systemName: "house") }
                Spacer()
                Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .font(.title3)
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .padding(.bottom, bottomInset)
    }
}

// MARK: - Music home

struct MusicHome: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var library: Library
    @ObservedObject var player: PlayerModel
    @ObservedObject var recs: SearchModel
    let bottomInset: CGFloat
    @State private var quickPage = 0

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h >= 5 && h < 12 { return "בוקר טוב" }
        if h >= 12 && h < 17 { return "צהריים טובים" }
        if h >= 17 && h < 21 { return "ערב טוב" }
        return "לילה טוב"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("מה שומעים היום?").font(.title3).foregroundStyle(.secondary)
                        .padding(.top, -16)
                    quickPicksSection
                    likedHero
                    recsSection
                    topSection
                    recentSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, bottomInset + 24)
            }
            .background(LiquidBackground(colors: [.brand, .brand2, .orange.opacity(0.8)]))
            .navigationTitle(greeting)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { app.tab = .search } label: {
                        Image(systemName: "magnifyingglass").font(.headline)
                    }
                }
            }
            .background(
                NavigationLink(
                    destination: WebView(webView: app.browser.webView)
                        .padding(.bottom, bottomInset)
                        .navigationTitle("יוטיוב")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationBarHidden(false),
                    isActive: $app.showBrowser
                ) { EmptyView() }
                .hidden()
            )
            .onAppear { app.loadRecommendations() }
        }
        .navigationViewStyle(.stack)
    }

    /// בחירות מהירות: ערבוב של המלצות, הכי מושמעים, אהובים ואחרונים
    private var quickPicks: [Song] {
        let lists: [[Song]] = [recs.results.map { $0.song }, library.topPlayed.map { $0.song },
                               library.liked, library.recent]
        var out: [Song] = []
        var seen = Set<String>()
        var i = 0
        while out.count < 27 && lists.contains(where: { i < $0.count }) {
            for l in lists where i < l.count {
                let s = l[i]
                if !s.title.isEmpty && !seen.contains(s.id) {
                    seen.insert(s.id)
                    out.append(s)
                }
            }
            i += 1
        }
        return Array(out.prefix(27))
    }

    @ViewBuilder private var quickPicksSection: some View {
        let picks = quickPicks
        if picks.count >= 3 {
            let tile = (UIScreen.main.bounds.width - 40 - 16) / 3
            let pages: [[Song]] = stride(from: 0, to: picks.count, by: 9).map {
                Array(picks[$0..<min($0 + 9, picks.count)])
            }
            let rows = CGFloat(min(3, Int(ceil(Double(pages.first?.count ?? 0) / 3))))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("בחירות מהירות").font(.title2.bold())
                    Spacer()
                    Button { app.playShuffled(picks) } label: {
                        Label("ערבב", systemImage: "shuffle").font(.subheadline.weight(.semibold))
                    }
                }
                TabView(selection: $quickPage) {
                    ForEach(pages.indices, id: \.self) { p in
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 8), count: 3),
                                  alignment: .leading, spacing: 8) {
                            ForEach(pages[p]) { song in
                                QuickTile(song: song, player: player, size: tile) {
                                    app.quickPlay(song, in: picks)
                                }
                                .contextMenu { SongMenuItems(app: app, song: song, library: library, onRemove: nil) }
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .tag(p)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: tile * rows + 8 * (rows - 1))

                if pages.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { p in
                            Circle()
                                .fill(p == quickPage ? Color.primary : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .animation(.easeInOut(duration: 0.2), value: quickPage)
                }
            }
        }
    }

    private var likedHero: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [.brand, .brand2], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "heart.fill").font(.system(size: 28)).foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("שירים שאהבתי").font(.title3.bold()).foregroundStyle(.primary)
                Text(library.liked.isEmpty ? "לחץ ♥ בנגן כדי לשמור" : "\(library.liked.count) שירים")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if !library.liked.isEmpty {
                Button { app.playShuffled(library.liked) } label: {
                    Image(systemName: "shuffle").font(.headline).foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .liquidGlass(in: Circle(), interactive: true)
                }
                Button {
                    player.setShuffle(false)
                    app.play(library.liked[0], in: library.liked)
                } label: {
                    Image(systemName: "play.fill").font(.title3).foregroundStyle(.white)
                        .frame(width: 48, height: 48).background(Color.brand, in: Circle())
                }
            }
        }
        .padding(14)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 26))
    }

    @ViewBuilder private var recsSection: some View {
        let items = Array(recs.results.map { $0.song }.filter { !library.isLiked($0.id) }.prefix(12))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("מומלץ בשבילך").font(.title2.bold())
                    if !app.recsSeed.isEmpty {
                        Text("כי אתה שומע את \(app.recsSeed)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(items) { song in
                            SongCard(song: song, player: player, size: 140, badge: nil) {
                                app.play(song, in: items)
                            }
                            .contextMenu { SongMenuItems(app: app, song: song, library: library, onRemove: nil) }
                        }
                    }
                }
            }
        } else if recs.isLoading {
            VStack(alignment: .leading, spacing: 12) {
                Text("מומלץ בשבילך").font(.title2.bold())
                ScrollView(.horizontal, showsIndicators: false) { SkeletonCards() }
                    .disabled(true)
            }
        }
    }

    @ViewBuilder private var topSection: some View {
        let top = library.topPlayed
        if top.count >= 3 {
            VStack(alignment: .leading, spacing: 12) {
                Text("הכי מושמעים").font(.title2.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(top) { t in
                            SongCard(song: t.song, player: player, size: 120, badge: "\(t.count)") {
                                app.play(t.song, in: top.map { $0.song })
                            }
                            .contextMenu { SongMenuItems(app: app, song: t.song, library: library, onRemove: nil) }
                        }
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("נשמע לאחרונה").font(.title2.bold())
                Spacer()
                if library.recent.count > 6 {
                    NavigationLink(destination: SongListView(kind: .recent, library: library,
                                                             player: player, bottomInset: bottomInset)) {
                        Text("הכל").font(.subheadline.weight(.semibold))
                    }
                }
            }
            if library.recent.isEmpty {
                Text("השירים שתשמע יופיעו כאן")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 18))
            } else {
                ForEach(Array(library.recent.prefix(6))) { song in
                    SongRow(song: song, library: library, player: player, action: {
                        app.play(song, in: library.recent)
                    })
                }
            }
        }
    }
}

// MARK: - Samples (טעימות)

struct SamplesView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var samples: SamplesModel
    @ObservedObject var player: PlayerModel
    @ObservedObject var library: Library
    @State private var currentID: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if samples.items.isEmpty {
                VStack(spacing: 22) {
                    RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.1))
                        .frame(width: 300, height: 300)
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)).frame(width: 220, height: 20)
                        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)).frame(width: 140, height: 14)
                    }
                    .frame(width: 300, alignment: .leading)
                    Text("מכין טעימות בשבילך…").font(.footnote).foregroundStyle(.white.opacity(0.6))
                }
                .shimmer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(samples.items) { s in
                            SampleCard(app: app, song: s, isCurrent: currentID == s.id,
                                       player: player, library: library)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(s.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
            }
        }
        .onAppear {
            app.startSamples()
            if currentID == nil { currentID = samples.items.first?.id }
            playCurrent()
        }
        .onDisappear { player.stopSamples() }
        .onChange(of: currentID) { _, _ in playCurrent() }
        .onChange(of: samples.items.count) { _, _ in
            if currentID == nil { currentID = samples.items.first?.id }
        }
    }

    private func playCurrent() {
        guard app.tab == .samples, let id = currentID,
              let i = samples.items.firstIndex(where: { $0.id == id }) else { return }
        player.playSample(samples.items[i])
        if i >= samples.items.count - 3 { samples.loadMore() }
    }
}

struct SampleCard: View {
    let app: AppState
    let song: Song
    let isCurrent: Bool
    @ObservedObject var player: PlayerModel
    @ObservedObject var library: Library

    var body: some View {
        let live = isCurrent && player.current?.id == song.id
        // התוכן קובע את הגודל; הרקע המטושטש לא יכול להרחיב את המסך
        VStack(spacing: 0) {
                Spacer(minLength: 20)
                ZStack {
                    art
                    if live && !player.isPlaying && !player.inAd {
                        Image(systemName: "play.fill").font(.system(size: 48)).foregroundStyle(.white)
                            .padding(26).background(.black.opacity(0.4), in: Circle())
                    }
                }
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
                .onTapGesture { if live { player.togglePlay() } }
                Spacer(minLength: 20)

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(live ? (player.current?.displayTitle ?? song.displayTitle) : song.displayTitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.title2.bold()).foregroundStyle(.white).lineLimit(2)
                        Text(song.displayArtist).font(.body).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                    Spacer()
                    VStack(spacing: 22) {
                        Button { library.toggleLike(song) } label: {
                            Image(systemName: library.isLiked(song.id) ? "heart.fill" : "heart")
                                .font(.title).foregroundStyle(library.isLiked(song.id) ? Color.brand : .white)
                        }
                        Button { app.songToAdd = song } label: {
                            Image(systemName: "text.badge.plus").font(.title2).foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal, 24)

                Button {
                    player.playFullSample()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { player.expanded = true }
                    app.tab = .home
                } label: {
                    Label("נגן את כל השיר", systemImage: "play.fill")
                        .font(.headline).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(.white, in: Capsule())
                }
                .padding(.top, 18)

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white).frame(width: g.size.width * (live ? player.sampleProgress : 0))
                    }
                }
                .frame(height: 3)
                .environment(\.layoutDirection, .leftToRight)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Color.black
                art.blur(radius: 60).opacity(0.55)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
            .clipped()
        }
        .clipped()
    }

    @ViewBuilder private var art: some View {
        if isCurrent, player.current?.id == song.id, let img = player.artworkImage {
            Color.clear
                .overlay { Image(uiImage: img).resizable().aspectRatio(contentMode: .fill) }
                .clipped()
        } else {
            Artwork(url: song.art, radius: 0)
        }
    }
}

// MARK: - Search tab

struct SearchTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var searcher: SearchModel
    @ObservedObject var library: Library
    @ObservedObject var player: PlayerModel
    let bottomInset: CGFloat
    @State private var query = ""
    @FocusState private var focused: Bool
    @StateObject private var suggest = SuggestModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("שירים, אמנים", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                            .onSubmit { focused = false; app.search(query) }
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 20))

                    if focused && !query.isEmpty && query != searcher.query && !suggest.items.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(suggest.items, id: \.self) { item in
                                Button {
                                    query = item
                                    focused = false
                                    app.search(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                        Text(item).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    } else if searcher.query.isEmpty || (query.isEmpty && !searcher.isLoading) {
                        startContent
                    } else if searcher.isLoading {
                        VStack(alignment: .leading, spacing: 14) {
                            SkeletonBlock(width: 80, height: 20, radius: 5).shimmer()
                            ForEach(0..<7, id: \.self) { _ in SkeletonRow() }
                        }
                    } else if searcher.results.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                            Text(app.isOnline ? "לא נמצאו שירים" : "אין חיבור לאינטרנט").foregroundStyle(.secondary)
                            Button("נסה שוב") { searcher.run(searcher.query) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        results
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomInset + 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LiquidBackground(colors: [.brand2, .brand, .teal.opacity(0.7)]))
            .navigationTitle("חיפוש")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { if query.isEmpty { query = searcher.query } }
            .onChange(of: searcher.query) { _, q in query = q }
            .onChange(of: query) { _, q in if focused { suggest.update(q) } }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder private var startContent: some View {
        if !library.searches.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("חיפושים אחרונים").font(.title3.bold())
                    Spacer()
                    Button("נקה") { library.clearSearches() }.font(.subheadline)
                }
                ForEach(library.searches, id: \.self) { s in
                    Button {
                        query = s
                        app.search(s)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text(s).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        Button { app.showGoogle = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe").font(.title3).foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("חיפוש בגוגל").font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text("בלי פרסומות").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.left").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var results: some View {
        let songs = searcher.results.map { $0.song }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("שירים").font(.title2.bold())
                Spacer()
                Button { app.playShuffled(songs) } label: {
                    Image(systemName: "shuffle").font(.subheadline.weight(.semibold))
                }
                .padding(.trailing, 8)
                Button {
                    player.setShuffle(false)
                    app.play(songs[0], in: songs)
                } label: {
                    Label("נגן הכל", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                }
            }
            ForEach(searcher.results) { item in
                SongRow(song: item.song, library: library, player: player,
                        subtitle: [item.song.displayArtist, item.length].filter { !$0.isEmpty }.joined(separator: " · "),
                        action: { app.play(item.song, in: songs) })
            }
        }
    }
}

// MARK: - Library tab

enum SongListKind { case liked, recent, top }

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var library: Library
    @ObservedObject var player: PlayerModel
    let bottomInset: CGFloat
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    VStack(spacing: 0) {
                        row(icon: "heart.fill", color: .brand, title: "שירים שאהבתי",
                            count: library.liked.count, kind: .liked)
                        Divider().padding(.leading, 64)
                        row(icon: "chart.bar.fill", color: .orange, title: "הכי מושמעים",
                            count: library.topPlayed.count, kind: .top)
                        Divider().padding(.leading, 64)
                        row(icon: "clock.fill", color: .blue, title: "נשמע לאחרונה",
                            count: library.recent.count, kind: .recent)
                    }
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 22))

                    HStack {
                        Text("פלייליסטים").font(.title2.bold())
                        Spacer()
                        Button { showNewPlaylist = true } label: {
                            Image(systemName: "plus.circle.fill").font(.title2)
                        }
                    }

                    if library.playlists.isEmpty {
                        Button { showNewPlaylist = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list").font(.title2).foregroundStyle(Color.brand)
                                Text("צור פלייליסט, למשל \"לנסיעה\" או \"לאימון\"")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(16)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 20))
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                                  alignment: .leading, spacing: 18) {
                            ForEach(library.playlists) { pl in
                                NavigationLink(destination: PlaylistView(playlistID: pl.id, library: library,
                                                                         player: player, bottomInset: bottomInset)) {
                                    PlaylistCard(playlist: pl, size: 160)
                                }
                                .buttonStyle(Pressable())
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomInset + 24)
            }
            .background(LiquidBackground(colors: [.brand, .purple.opacity(0.7), .brand2]))
            .navigationTitle("ספרייה")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { app.showSettings = true } label: { Image(systemName: "gearshape").font(.headline) }
                }
            }
            .alert("פלייליסט חדש", isPresented: $showNewPlaylist) {
                TextField("שם הפלייליסט", text: $newPlaylistName)
                Button("ביטול", role: .cancel) { newPlaylistName = "" }
                Button("צור") {
                    let n = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { library.createPlaylist(n) }
                    newPlaylistName = ""
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(icon: String, color: Color, title: String, count: Int, kind: SongListKind) -> some View {
        NavigationLink(destination: SongListView(kind: kind, library: library, player: player, bottomInset: bottomInset)) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.headline).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(color, in: RoundedRectangle(cornerRadius: 9))
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.left").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SongListView: View {
    @EnvironmentObject var app: AppState
    let kind: SongListKind
    @ObservedObject var library: Library
    @ObservedObject var player: PlayerModel
    let bottomInset: CGFloat

    private var title: String {
        switch kind {
        case .liked: return "שירים שאהבתי"
        case .recent: return "נשמע לאחרונה"
        case .top: return "הכי מושמעים"
        }
    }

    private var songs: [Song] {
        switch kind {
        case .liked: return library.liked
        case .recent: return library.recent
        case .top: return library.topPlayed.map { $0.song }
        }
    }

    var body: some View {
        let list = songs
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if list.isEmpty {
                    Text(kind == .liked ? "לחץ ♥ בנגן כדי לשמור שירים כאן" : "עוד אין כאן שירים")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    HStack(spacing: 12) {
                        Button {
                            player.setShuffle(false)
                            app.play(list[0], in: list)
                        } label: {
                            Label("נגן", systemImage: "play.fill")
                                .font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.brand, in: RoundedRectangle(cornerRadius: 14))
                        }
                        Button { app.playShuffled(list) } label: {
                            Label("ערבב", systemImage: "shuffle")
                                .font(.headline).foregroundStyle(Color.brand)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .liquidGlass(in: RoundedRectangle(cornerRadius: 16), interactive: true)
                        }
                    }
                    ForEach(list) { song in
                        SongRow(song: song, library: library, player: player,
                                onRemove: kind == .liked ? { library.toggleLike(song) } : nil,
                                removeLabel: "הסר מהאהובים",
                                action: { app.play(song, in: list) })
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, bottomInset + 24)
        }
        .background(LiquidBackground(colors: [.brand, .brand2]))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if kind == .recent && !list.isEmpty {
                    Button("נקה") { library.clearRecent() }
                }
            }
        }
    }
}

// MARK: - Liquid Glass

extension View {
    /// זכוכית נוזלית אמיתית ב-iOS 26 ומעלה; בגרסאות ישנות יותר — חומר מטושטש עם קו אור דק.
    /// הבדיקה כפולה: גם שהקומפיילר מכיר את ה-API, וגם שהאייפון תומך בו — כך שזה לא יכול לשבור את הבנייה.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.6))
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.6))
        #endif
    }
}

/// רקע חי: כתמי צבע רכים שזזים לאט מאחורי הזכוכית
struct LiquidBackground: View {
    var colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var drift = false

    private let spots: [(x: CGFloat, y: CGFloat)] = [(-0.35, -0.30), (0.40, 0.00), (-0.15, 0.42), (0.30, -0.45)]

    var body: some View {
        GeometryReader { g in
            let d = max(g.size.width, 320) * 0.95
            ZStack {
                Color(.systemBackground)
                ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { i, c in
                    Circle()
                        .fill(c)
                        .frame(width: d, height: d)
                        .offset(x: spots[i].x * g.size.width * (drift ? 1.1 : 0.85),
                                y: spots[i].y * g.size.height * (drift ? 0.9 : 1.1))
                        .blur(radius: 80)
                        .opacity(scheme == .dark ? 0.55 : 0.32)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
            .drawingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 10).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

// MARK: - Polish: רטט, כפתורים שמגיבים, שלד טעינה

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.28), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.4)
                }
                .mask(content)
                .opacity(reduceMotion ? 0 : 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 8
    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color(.tertiarySystemFill))
            .frame(width: width, height: height)
    }
}

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 14) {
            SkeletonBlock(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: 180, height: 12, radius: 4)
                SkeletonBlock(width: 110, height: 10, radius: 4)
            }
            Spacer()
        }
        .shimmer()
    }
}

struct SkeletonCards: View {
    var size: CGFloat = 140
    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: size, height: size, radius: 14)
                    SkeletonBlock(width: size * 0.8, height: 11, radius: 4)
                    SkeletonBlock(width: size * 0.5, height: 9, radius: 4)
                }
            }
        }
        .shimmer()
    }
}

// MARK: - Reusable song views

struct SongCard: View {
    let song: Song
    @ObservedObject var player: PlayerModel
    let size: CGFloat
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    Artwork(url: song.art, radius: 14).frame(width: size, height: size)
                    if player.current?.id == song.id { NowBadge(playing: player.isPlaying).padding(8) }
                }
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Label(badge, systemImage: "play.fill")
                            .font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(8)
                    }
                }
                Text(song.displayTitle).font(.subheadline.weight(.semibold))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(song.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: size, alignment: .leading)
            .foregroundStyle(.primary)
        }
        .buttonStyle(Pressable())
    }
}

struct QuickTile: View {
    let song: Song
    @ObservedObject var player: PlayerModel
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        let isCurrent = player.current?.id == song.id
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Artwork(url: song.art, radius: 0).frame(width: size, height: size).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                Text(song.displayTitle)
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .frame(width: size, alignment: .leading)
                if isCurrent {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative.reversing, isActive: player.isPlaying)
                        .padding(7).background(Color.brand, in: Circle())
                        .padding(7)
                        .frame(width: size, height: size, alignment: .topLeading)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isCurrent ? Color.brand : .clear, lineWidth: 2))
        }
        .buttonStyle(Pressable())
    }
}

struct SongRow: View {
    @EnvironmentObject var app: AppState
    let song: Song
    @ObservedObject var library: Library
    @ObservedObject var player: PlayerModel
    var subtitle: String? = nil
    var onRemove: (() -> Void)? = nil
    var removeLabel: String = "הסר מהפלייליסט"
    let action: () -> Void
    @State private var dragX: CGFloat = 0
    @State private var armed = false
    @Environment(\.layoutDirection) private var direction

    private var threshold: CGFloat { 80 }

    var body: some View {
        // ההזזה נעשית בכיוון פיזי קבוע (שמאל→ימין), כדי שבעברית השורה תזוז עם האצבע ולא הפוך
        rowContent
            .environment(\.layoutDirection, direction)
            .offset(x: dragX)
            .background(swipeBackground)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { v in
                        let w = v.translation.width, h = v.translation.height
                        guard abs(w) > abs(h) * 1.4 else { return }
                        dragX = w > 0 ? min(w, 140) : max(w, -140)
                        let nowArmed = abs(dragX) > threshold
                        if nowArmed != armed { armed = nowArmed; if nowArmed { Haptics.tap() } }
                    }
                    .onEnded { _ in
                        if dragX > threshold {
                            app.player.playNext(song)
                            app.showToast("יתנגן אחרי השיר הנוכחי")
                        } else if dragX < -threshold {
                            library.toggleLike(song)
                            app.showToast(library.isLiked(song.id) ? "נוסף לשירים שאהבתי" : "הוסר מהשירים שאהבתי")
                        }
                        armed = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                    }
            )
            .environment(\.layoutDirection, .leftToRight)
    }

    /// רקע שנחשף בזמן החלקה: ימינה = נגן הבא, שמאלה = אהבתי
    private var swipeBackground: some View {
        HStack {
            if dragX > 0 {
                Image(systemName: "text.insert").font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: max(dragX, 0))
                    .frame(maxHeight: .infinity)
                    .background(armed ? Color.blue : Color.blue.opacity(0.6))
            }
            Spacer(minLength: 0)
            if dragX < 0 {
                Image(systemName: library.isLiked(song.id) ? "heart.slash.fill" : "heart.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: max(-dragX, 0))
                    .frame(maxHeight: .infinity)
                    .background(armed ? Color.brand : Color.brand.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.layoutDirection, .leftToRight)
    }

    private var rowContent: some View {
        let isCurrent = player.current?.id == song.id
        return Button(action: action) {
            HStack(spacing: 14) {
                Artwork(url: song.art, radius: 8).frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(isCurrent ? Color.brand : .primary)
                    let sub = subtitle ?? song.displayArtist
                    if !sub.isEmpty {
                        Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isCurrent {
                    LiveWave(playing: player.isPlaying)
                } else if library.isLiked(song.id) {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(Color.brand)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SongMenuItems(app: app, song: song, library: library, onRemove: onRemove, removeLabel: removeLabel) }
    }
}

struct SongMenuItems: View {
    let app: AppState
    let song: Song
    @ObservedObject var library: Library
    let onRemove: (() -> Void)?
    var removeLabel: String = "הסר מהפלייליסט"

    var body: some View {
        Button {
            app.player.playNext(song)
            app.showToast("יתנגן אחרי השיר הנוכחי")
        } label: { Label("נגן הבא", systemImage: "text.insert") }
        Button { library.toggleLike(song) } label: {
            Label(library.isLiked(song.id) ? "הסר מהאהובים" : "הוסף לאהובים",
                  systemImage: library.isLiked(song.id) ? "heart.slash" : "heart")
        }
        Button { app.songToAdd = song } label: {
            Label("הוסף לפלייליסט", systemImage: "text.badge.plus")
        }
        if let onRemove {
            Button(role: .destructive, action: onRemove) {
                Label(removeLabel, systemImage: "minus.circle")
            }
        }
    }
}

struct Artwork: View {
    let url: URL
    var radius: CGFloat = 12
    var body: some View {
        // התמונה ממלאת את המסגרת ונחתכת בדיוק בגבולות שלה
        Color.clear
            .overlay {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Color(.tertiarySystemFill)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

struct NowBadge: View {
    var playing = true
    var body: some View {
        Image(systemName: "waveform")
            .font(.caption.bold()).foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative.reversing, isActive: playing)
            .padding(6).background(Color.brand, in: Circle())
    }
}

/// גל קול שזז בקצב כשהשיר מתנגן
struct LiveWave: View {
    let playing: Bool
    var body: some View {
        Image(systemName: "waveform")
            .foregroundStyle(Color.brand)
            .symbolEffect(.variableColor.iterative.reversing, isActive: playing)
    }
}

// MARK: - Playlists

struct PlaylistCard: View {
    let playlist: Playlist
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaylistCover(playlist: playlist, size: size)
            Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(playlist.songs.count) שירים").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: size, alignment: .leading)
        .foregroundStyle(.primary)
    }
}

struct PlaylistCover: View {
    let playlist: Playlist
    let size: CGFloat

    var body: some View {
        let arts = Array(playlist.songs.prefix(4))
        ZStack {
            if arts.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { tile(arts[0]); tile(arts[1]) }
                    HStack(spacing: 0) { tile(arts[2]); tile(arts[3]) }
                }
            } else if let first = arts.first {
                Artwork(url: first.art, radius: 0).frame(width: size, height: size).clipped()
            } else {
                LinearGradient(colors: [.brand2, .brand], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note.list").font(.system(size: size * 0.26)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func tile(_ s: Song) -> some View {
        Artwork(url: s.art, radius: 0).frame(width: size / 2, height: size / 2).clipped()
    }
}

struct PlaylistView: View {
    @EnvironmentObject var app: AppState
    let playlistID: UUID
    @ObservedObject var library: Library
    @ObservedObject var player: PlayerModel
    let bottomInset: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        let pl = library.playlist(playlistID)
        ScrollView {
            if let pl {
                VStack(spacing: 18) {
                    PlaylistCover(playlist: pl, size: 200)
                        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
                    VStack(spacing: 4) {
                        Text(pl.name).font(.title.bold())
                        Text("\(pl.songs.count) שירים").foregroundStyle(.secondary)
                    }
                    if !pl.songs.isEmpty {
                        HStack(spacing: 12) {
                            Button {
                                player.setShuffle(false)
                                app.play(pl.songs[0], in: pl.songs)
                            } label: {
                                Label("נגן", systemImage: "play.fill")
                                    .font(.headline).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 14))
                            }
                            Button { app.playShuffled(pl.songs) } label: {
                                Label("ערבב", systemImage: "shuffle")
                                    .font(.headline).foregroundStyle(Color.brand)
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .liquidGlass(in: RoundedRectangle(cornerRadius: 16), interactive: true)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        if pl.songs.isEmpty {
                            Text("עוד אין כאן שירים. לחיצה ארוכה על שיר ← \"הוסף לפלייליסט\".")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                        }
                        ForEach(pl.songs) { song in
                            SongRow(song: song, library: library, player: player,
                                    onRemove: { library.remove(song.id, from: pl.id) },
                                    action: { app.play(song, in: pl.songs) })
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomInset + 24)
            }
        }
        .background(LiquidBackground(colors: [.brand2, .brand]))
        .navigationTitle(pl?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        newName = pl?.name ?? ""
                        renaming = true
                    } label: { Label("שנה שם", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("מחק פלייליסט", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("שם הפלייליסט", isPresented: $renaming) {
            TextField("שם", text: $newName)
            Button("ביטול", role: .cancel) {}
            Button("שמור") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { library.renamePlaylist(playlistID, to: n) }
            }
        }
        .confirmationDialog("למחוק את הפלייליסט?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("מחק", role: .destructive) {
                library.deletePlaylist(playlistID)
                dismiss()
            }
        }
    }
}

struct AddToPlaylistSheet: View {
    let song: Song
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Artwork(url: song.art, radius: 6).frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(song.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(song.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Section("פלייליסט חדש") {
                    HStack {
                        TextField("שם הפלייליסט", text: $name)
                            .submitLabel(.done)
                            .onSubmit { createAndAdd() }
                        Button("צור והוסף") { createAndAdd() }
                            .disabled(trimmed.isEmpty)
                    }
                }
                if !library.playlists.isEmpty {
                    Section("הפלייליסטים שלך") {
                        ForEach(library.playlists) { pl in
                            let has = pl.songs.contains { $0.id == song.id }
                            Button {
                                library.add(song, to: pl.id)
                                dismiss()
                            } label: {
                                HStack {
                                    PlaylistCover(playlist: pl, size: 40)
                                    Text(pl.name).foregroundStyle(.primary)
                                    Spacer()
                                    if has {
                                        Image(systemName: "checkmark").foregroundStyle(Color.brand)
                                    } else {
                                        Text("\(pl.songs.count)").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(has)
                        }
                    }
                }
            }
            .navigationTitle("הוסף לפלייליסט")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("סגור") { dismiss() } }
            }
        }
    }

    private func createAndAdd() {
        guard !trimmed.isEmpty else { return }
        let id = library.createPlaylist(trimmed)
        library.add(song, to: id)
        dismiss()
    }
}

// MARK: - Queue (הבא בתור)

struct QueueView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if let s = player.current {
                    Section("מתנגן עכשיו") {
                        HStack(spacing: 12) {
                            Artwork(url: s.art, radius: 6).frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.displayTitle).font(.body.weight(.semibold)).foregroundStyle(Color.brand).lineLimit(1)
                                Text(s.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            LiveWave(playing: player.isPlaying)
                        }
                    }
                }
                Section {
                    if player.upNext.isEmpty {
                        Text("אין שירים בתור. החלקה ימינה על שיר ← \"נגן הבא\", או ✨ \"עוד כמו זה\".")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, s in
                        Button { player.jumpToUpNext(i) } label: {
                            HStack(spacing: 12) {
                                Artwork(url: s.art, radius: 6).frame(width: 46, height: 46)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.displayTitle).font(.body).foregroundStyle(.primary).lineLimit(1)
                                    Text(s.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { player.removeUpNext(at: $0) }
                } header: {
                    HStack {
                        Text("הבא בתור · \(player.upNext.count)")
                        Spacer()
                        if !player.upNext.isEmpty {
                            Button("נקה") { player.clearUpNext() }.font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle("התור")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("סגור") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
    }
}

// MARK: - Settings (הגדרות)

struct SettingsView: View {
    @ObservedObject var library: Library
    @ObservedObject var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accent") private var accent = Theme.pink.rawValue
    @AppStorage("showVideo") private var showVideo = true
    @State private var confirm: String?
    @State private var backupURL: URL?
    @State private var importing = false
    @State private var restoreResult: String?

    var body: some View {
        NavigationView {
            List {
                Section("צבע ראשי") {
                    HStack(spacing: 14) {
                        ForEach(Theme.allCases) { t in
                            Button {
                                Haptics.tap()
                                accent = t.rawValue
                            } label: {
                                Circle().fill(LinearGradient(colors: [t.main, t.second],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 40, height: 40)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: accent == t.rawValue ? 3 : 0).padding(-4))
                                    .accessibilityLabel(t.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    if let backupURL {
                        ShareLink(item: backupURL) {
                            Label("גיבוי לקובץ", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button { importing = true } label: {
                        Label("שחזור מגיבוי", systemImage: "square.and.arrow.down")
                    }
                } header: { Text("גיבוי") } footer: {
                    Text("שמור את הגיבוי ב\"קבצים\" או ב-iCloud Drive. אם האפליקציה תותקן מחדש, אפשר לשחזר ממנו את השירים שאהבת והפלייליסטים.")
                }
                Section {
                    ForEach(SiriHelp.phrases, id: \.self) { line in
                        Label(line, systemImage: "waveform.circle").font(.subheadline)
                    }
                } header: { Text("פקודות לסירי") } footer: {
                    Text("אומרים \"היי סירי\" ואז אחת הפקודות. אפשר גם להוסיף אותן לאפליקציית קיצורים או לכפתור הפעולה.")
                }
                Section("נגן") {
                    Toggle("מעבר מהיר בין שירים", isOn: $player.earlyStart)
                    Toggle("להמשיך עם שירים דומים כשהתור נגמר", isOn: Binding(get: { player.autoContinue },
                                                                            set: { player.autoContinue = $0 }))
                    Toggle("להציג וידאו בנגן", isOn: $showVideo)
                    Toggle("המשך לנגן ברקע (חלון צף)", isOn: Binding(get: { player.backgroundPiP },
                                                                     set: { player.backgroundPiP = $0 }))
                    Toggle("ברכב: להשאיר את המסך דלוק", isOn: Binding(get: { player.keepAwakeInCar },
                                                                    set: { player.keepAwakeInCar = $0 }))
                    Toggle("להציג מילים", isOn: Binding(get: { player.showLyrics },
                                                         set: { if $0 != player.showLyrics { player.toggleLyrics() } }))
                }
                Section {
                    Button("ניקוי \"נשמע לאחרונה\"", role: .destructive) { confirm = "recent" }
                    Button("ניקוי היסטוריית חיפושים", role: .destructive) { confirm = "searches" }
                    Button("איפוס \"הכי מושמעים\"", role: .destructive) { confirm = "counts" }
                } header: { Text("נתונים") } footer: {
                    Text("השירים שאהבת והפלייליסטים לא יימחקו.")
                }
                Section {
                    NavigationLink("יומן תקלות") { DebugLogView() }
                } footer: {
                    Text("אם משהו לא עובד, היכנס ליומן, לחץ \"העתק\" ושלח לי.")
                }
                Section {
                    HStack { Text("גרסה"); Spacer(); Text("10.4").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("הגדרות")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { backupURL = library.writeBackup() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    restoreResult = library.restoreBackup(from: url) ? "הגיבוי שוחזר ✓" : "הקובץ לא תקין"
                    backupURL = library.writeBackup()
                }
            }
            .alert(restoreResult ?? "", isPresented: Binding(get: { restoreResult != nil },
                                                             set: { if !$0 { restoreResult = nil } })) {
                Button("אישור", role: .cancel) {}
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("סיום") { dismiss() } }
            }
            .confirmationDialog("בטוח?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button("נקה", role: .destructive) {
                    switch confirm {
                    case "recent": library.clearRecent()
                    case "searches": library.clearSearches()
                    case "counts": library.clearPlayCounts()
                    default: break
                    }
                    confirm = nil
                }
            }
        }
        .tint(Theme(rawValue: accent)?.main ?? .brand)
    }
}

struct DebugLogView: View {
    @State private var lines = DebugLog.lines
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "היומן ריק" : lines.reversed().joined(separator: "\n"))
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("יומן תקלות")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(copied ? "הועתק ✓" : "העתק") {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    copied = true
                }
                Button("נקה") { DebugLog.clear(); lines = [] }
            }
        }
    }
}

// MARK: - Search suggestions (הצעות בזמן הקלדה)

final class SuggestModel: ObservableObject {
    @Published var items: [String] = []
    private var work: DispatchWorkItem?
    private var lastQuery = ""

    func update(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        lastQuery = q
        work?.cancel()
        guard !q.isEmpty else { items = []; return }
        let w = DispatchWorkItem { [weak self] in self?.fetch(q) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    private func fetch(_ q: String) {
        var c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        c.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "ds", value: "yt"),
                        URLQueryItem(name: "hl", value: "he"), URLQueryItem(name: "ie", value: "utf-8"),
                        URLQueryItem(name: "oe", value: "utf-8"), URLQueryItem(name: "q", value: q)]
        guard let url = c.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let text = Optional(String(decoding: data, as: UTF8.self)),
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
                  json.count > 1, let list = json[1] as? [String] else { return }
            DispatchQueue.main.async {
                guard let self, self.lastQuery == q else { return }
                self.items = Array(list.prefix(8))
            }
        }.resume()
    }
}

// MARK: - Search model

struct SearchItem: Codable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let length: String
    var song: Song { Song(id: id, title: title, artist: artist.isEmpty ? nil : artist) }
}

/// מחפש ביוטיוב "מאחורי הקלעים" ומחזיר רק שירים: סרטונים של 1–10 דקות, בלי שורטס, לייב, ערוצים ופלייליסטים
final class SearchModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var results: [SearchItem] = []
    @Published var isLoading = false
    @Published private(set) var query = ""
    var onResults: (([SearchItem]) -> Void)?
    private var attempt = 0
    private var token = 0

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        webView.navigationDelegate = self
        AdRules.compile(youtube: true) { list in
            if let list { config.userContentController.add(list) }
        }
    }

    func run(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        query = q
        results = []
        isLoading = true
        attempt = 0
        token += 1
        var c = URLComponents(string: "https://m.youtube.com/results")!
        c.queryItems = [URLQueryItem(name: "search_query", value: q),
                        URLQueryItem(name: "sp", value: "EgIQAQ==")]   // סרטונים בלבד
        if let url = c.url { webView.load(URLRequest(url: url)) }
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if let self, self.token == t, self.isLoading { self.finish([]) }
        }
    }

    private func finish(_ items: [SearchItem]) {
        results = items
        isLoading = false
        onResults?(items)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { extract(token) }

    /// iOS סגר את הדפדפן הנסתר בגלל זיכרון — מחפשים שוב
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isLoading, !query.isEmpty { run(query) }
    }

    /// טעינה קודמת שבוטלה (כי התחיל חיפוש חדש) היא לא כישלון
    private static func isCancel(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isLoading, !Self.isCancel(error) { finish([]) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isLoading, !Self.isCancel(error) { finish([]) }
    }

    private func extract(_ t: Int) {
        webView.evaluateJavaScript(AdRules.searchExtractScript) { [weak self] result, _ in
            guard let self, self.token == t, self.isLoading else { return }
            if let json = result as? String, let data = json.data(using: .utf8),
               let items = try? JSONDecoder().decode([SearchItem].self, from: data), !items.isEmpty {
                self.finish(items)
            } else if self.attempt < 8 {
                self.attempt += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.extract(t) }
            } else {
                self.finish([])
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, AdRules.isAdURL(url) { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
}

// MARK: - Player overlay (נגן קטן + נגן מלא)

struct PlayerOverlay: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var player: PlayerModel
    @ObservedObject var library: Library
    @AppStorage("showVideo") private var showVideo = true
    @State private var scrubbing = false
    @State private var scrub = 0.0
    @State private var showQueue = false

    var body: some View {
        GeometryReader { geo in
            let expanded = player.expanded
            let record = expanded && !showVideo
            // במצב תקליט התמונה מרובעת — מקטינים אותה כשהמילים פתוחות, כדי שהכל ייכנס במסך
            let artMax = geo.size.height * (player.showLyrics ? 0.30 : 0.40)
            let videoW = expanded ? (record ? min(geo.size.width - 48, artMax) : geo.size.width - 48) : 64
            let boxH = record ? videoW : videoW * 9 / 16

            VStack(spacing: 0) {
                if !expanded { Spacer(minLength: 0) }

                if expanded {
                    header.padding(.top, geo.safeAreaInsets.top)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 12) {
                    ZStack {
                        PlayerWebHost(a: player.webA, b: player.webB, active: player.webView)
                            .frame(width: videoW, height: videoW * 9 / 16)
                        if record { recordArt.frame(width: videoW, height: videoW) }
                    }
                    .frame(width: videoW, height: boxH)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? (record ? 26 : 18) : 8))
                    .shadow(color: .black.opacity(expanded ? 0.3 : 0), radius: 24, y: 12)
                    .scaleEffect(record && !player.isPlaying ? 0.86 : 1)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)

                    if !expanded {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.current?.displayTitle ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(player.current?.displayArtist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .transition(.opacity)
                        Spacer(minLength: 4)
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                                .frame(width: 40, height: 40)
                        }
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill").font(.body).frame(width: 36, height: 40)
                        }
                        .disabled(!player.canSkip)
                    }
                }
                .foregroundStyle(.primary)
                .padding(expanded ? 24 : 8)
                .background {
                    if !expanded { Color.clear.liquidGlass(in: RoundedRectangle(cornerRadius: 24)) }
                }
                .overlay(alignment: .bottom) {
                    if !expanded {
                        ProgressView(value: player.duration > 0 ? min(player.time / player.duration, 1) : 0)
                            .progressViewStyle(.linear)
                            .tint(player.tint)
                            .scaleEffect(x: 1, y: 0.5)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if !expanded { expand() } }
                .padding(.horizontal, expanded ? 0 : 8)
                .padding(.bottom, expanded ? 0 : geo.safeAreaInsets.bottom + 54 + Layout.tabBarExtra)

                if expanded {
                    controls
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 60)),
                                                removal: .opacity))
                    Spacer(minLength: 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background {
                if expanded { fullBackground.transition(.opacity) }
            }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                let w = v.translation.width, h = v.translation.height
                if expanded {
                    if h > 120 && abs(h) > abs(w) { minimize() }
                } else if abs(w) > 60 && abs(w) > abs(h) {
                    if w < 0 { player.next() } else { player.previous() }
                } else if h < -50 {
                    expand()
                }
            })
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var recordArt: some View {
        if let img = player.artworkImage {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if let s = player.current {
            Artwork(url: s.art, radius: 0)
        } else {
            Color(.tertiarySystemFill)
        }
    }

    private var fullBackground: some View {
        ZStack {
            // כתמי צבע מתמונת השיר שזזים לאט — עליהם יושבת הזכוכית
            LiquidBackground(colors: [player.tint, .brand2, player.tint.opacity(0.8), .brand])
            if let img = player.artworkImage {
                Color.clear
                    .overlay { Image(uiImage: img).resizable().aspectRatio(contentMode: .fill) }
                    .clipped()
                    .blur(radius: 90).opacity(0.25)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: player.tint)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { minimize() } label: {
                Image(systemName: "chevron.down").font(.headline)
                    .frame(width: 42, height: 42)
                    .liquidGlass(in: Circle(), interactive: true)
            }
            Spacer()
            Text("מתנגן עכשיו").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet").font(.headline)
                    .frame(width: 42, height: 42)
                    .liquidGlass(in: Circle(), interactive: true)
            }
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { showVideo.toggle() }
            } label: {
                Image(systemName: showVideo ? "opticaldisc" : "play.rectangle").font(.headline)
                    .frame(width: 42, height: 42)
                    .liquidGlass(in: Circle(), interactive: true)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .sheet(isPresented: $showQueue) { QueueView(player: player, library: library) }
    }

    @ViewBuilder private var lyricsCard: some View {
        if player.showLyrics {
            VStack(alignment: .leading, spacing: 6) {
                if player.lyricsAvailable == false {
                    Text("אין מילים זמינות לשיר הזה").font(.subheadline).foregroundStyle(.secondary)
                } else if player.lyricLine.isEmpty {
                    Text("מחפש מילים…").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    if !player.lyricPrev.isEmpty {
                        Text(player.lyricPrev).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(player.lyricLine).font(.title3.bold()).lineLimit(3)
                        .id(player.lyricLine)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 20))
            .animation(.easeOut(duration: 0.25), value: player.lyricLine)
        }
    }

    private var controls: some View {
        VStack(spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.current?.displayTitle ?? "").font(.title2.bold()).lineLimit(2)
                    Text(player.current?.displayArtist ?? "").font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let s = player.current {
                    Button { library.toggleLike(s) } label: {
                        Image(systemName: library.isLiked(s.id) ? "heart.fill" : "heart")
                            .font(.title2).foregroundStyle(Color.brand)
                            .frame(width: 50, height: 50)
                            .liquidGlass(in: Circle(), interactive: true)
                    }
                }
            }

            if player.inAd {
                Label("מדלג על פרסומת…", systemImage: "forward.end.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            lyricsCard

            VStack(spacing: 6) {
                Slider(value: Binding(get: { scrubbing ? scrub : player.time },
                                      set: { scrub = $0 }),
                       in: 0...max(player.duration, 1),
                       onEditingChanged: { editing in
                           if editing { scrub = player.time } else { player.seek(scrub) }
                           scrubbing = editing
                       })
                HStack {
                    Text(fmt(scrubbing ? scrub : player.time))
                    Spacer()
                    Text("-" + fmt(player.duration - (scrubbing ? scrub : player.time)))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .environment(\.layoutDirection, .leftToRight)

            HStack {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.title3)
                        .foregroundStyle(player.shuffle ? Color.brand : .secondary)
                }
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 26)) }
                Spacer()
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28)).foregroundStyle(.white)
                        .frame(width: 66, height: 66).background(Color.brand, in: Circle())
                }
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 26)) }
                    .disabled(!player.canSkip)
                Spacer()
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                        .foregroundStyle(player.repeatMode == .off ? .secondary : Color.brand)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .liquidGlass(in: Capsule())
            .environment(\.layoutDirection, .leftToRight)

            HStack {
                Menu {
                    Button("15 דקות") { setSleep(15) }
                    Button("30 דקות") { setSleep(30) }
                    Button("45 דקות") { setSleep(45) }
                    Button("שעה") { setSleep(60) }
                    Button("בסוף השיר") {
                        player.setSleepEndOfSong()
                        app.showToast("המוזיקה תיעצר בסוף השיר")
                    }
                    if player.sleepActive {
                        Button("בטל טיימר", role: .destructive) {
                            player.cancelSleep()
                            app.showToast("הטיימר בוטל")
                        }
                    }
                } label: {
                    actionLabel(player.sleepActive ? "moon.fill" : "moon", player.sleepLabel, active: player.sleepActive)
                }
                Button {
                    if let s = player.current { app.moreLikeThis(s) }
                } label: {
                    actionLabel("sparkles", "עוד כמו זה", active: false)
                }
                Button {
                    if let s = player.current, !s.title.isEmpty { app.songToAdd = s }
                } label: {
                    actionLabel("text.badge.plus", "לפלייליסט", active: false)
                }
                Button { player.toggleLyrics() } label: {
                    actionLabel("quote.bubble", "מילים", active: player.showLyrics)
                }
            }
            .padding(.vertical, 10)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 24))
        }
        .padding(.horizontal, 24)
    }

    private func actionLabel(_ icon: String, _ text: String, active: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.title3)
            Text(text).font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(active ? Color.brand : .primary)
    }

    private func setSleep(_ minutes: Int) {
        player.setSleep(minutes: minutes)
        app.showToast(minutes == 60 ? "המוזיקה תיעצר בעוד שעה" : "המוזיקה תיעצר בעוד \(minutes) דקות")
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(max(0, s.isFinite ? s : 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
    private func expand() {
        Haptics.tap()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { player.expanded = true }
    }
    private func minimize() {
        Haptics.tap()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { player.expanded = false }
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// יומן אירועים של הנגן — כדי לראות בדיוק מה קרה כשמשהו לא עובד
enum DebugLog {
    private static let key = "debugLog"
    static var lines: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        var l = lines
        l.append("\(f.string(from: Date()))  \(text)")
        if l.count > 200 { l.removeFirst(l.count - 200) }
        UserDefaults.standard.set(l, forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// עוצמת הקול של האייפון — משמשת להחלשה והתחזקות בין שירים.
/// חשוב: כל עוד בקר הווליום הנסתר מחובר למסך, iOS מסתיר את סימן הווליום שלו.
/// לכן מחברים אותו רק לשניות של המעבר, ומנתקים מיד אחרי.
final class SystemVolume {
    static let shared = SystemVolume()
    weak var host: UIView?
    private var view: MPVolumeView?
    private var timer: Timer?
    private var detachWork: DispatchWorkItem?
    private var base: Float?
    private var lastSet: Float?

    private var slider: UISlider? { view?.subviews.compactMap { $0 as? UISlider }.first }
    private var output: Float { AVAudioSession.sharedInstance().outputVolume }

    init() {
        // אם האפליקציה נסגרה באמצע מעבר — מחזירים את הקול
        if let saved = UserDefaults.standard.object(forKey: "volumeBase") as? Float {
            UserDefaults.standard.removeObject(forKey: "volumeBase")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.attach { self?.set(saved); self?.scheduleDetach() }
            }
        }
    }

    /// מחבר את בקר הווליום הנסתר ומחכה רגע שיהיה מוכן
    private func attach(_ then: @escaping () -> Void) {
        detachWork?.cancel()
        if view == nil, let host {
            let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
            v.alpha = 0.01
            host.addSubview(v)
            view = v
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: then)
        } else {
            then()
        }
    }

    /// מנתק אותו — וסימן הווליום של האייפון חוזר להופיע
    private func scheduleDetach() {
        detachWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.timer == nil else { return }
            self.view?.removeFromSuperview()
            self.view = nil
        }
        detachWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func set(_ v: Float) {
        lastSet = v
        slider?.value = max(0, min(1, v))
    }

    /// משנה בהדרגה את הקול ל-fraction מהקול המקורי של המשתמש
    func ramp(toFraction fraction: Float, duration: Double, completion: (() -> Void)? = nil) {
        timer?.invalidate()
        timer = nil
        // אם המשתמש שינה בעצמו את הקול באמצע — מכבדים את מה שהוא בחר
        if let last = lastSet, abs(output - last) > 0.08 { base = nil }
        if base == nil { base = output }
        guard let b = base, b > 0.05, host != nil else {
            base = nil
            completion?()
            return
        }
        attach { [weak self] in
            guard let self, self.slider != nil else {
                self?.base = nil
                completion?()
                return
            }
            UserDefaults.standard.set(b, forKey: "volumeBase")
            let start = self.lastSet ?? self.output
            let target = b * fraction
            let steps = max(1, Int(duration * 20))
            var step = 0
            self.timer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                step += 1
                let p = Float(step) / Float(steps)
                let eased = p * p * (3 - 2 * p)
                self.set(start + (target - start) * eased)
                if step >= steps {
                    t.invalidate()
                    self.timer = nil
                    if fraction >= 1 { self.finish() }
                    completion?()
                }
            }
        }
    }

    /// מחזיר מיד את הקול המקורי
    func restore() {
        timer?.invalidate()
        timer = nil
        if let b = base { set(b) }
        finish()
    }

    private func finish() {
        base = nil
        lastSet = nil
        UserDefaults.standard.removeObject(forKey: "volumeBase")
        scheduleDetach()
    }
}

struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        SystemVolume.shared.host = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// מציג את הנגן הפעיל; הנגן השני מכין את השיר הבא מאחוריו
final class PlayerHostView: UIView {
    var players: [WKWebView] = []
    override func layoutSubviews() {
        super.layoutSubviews()
        players.forEach { $0.frame = bounds }
    }
}

struct PlayerWebHost: UIViewRepresentable {
    let a: WKWebView
    let b: WKWebView
    let active: WKWebView

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.backgroundColor = .black
        v.clipsToBounds = true
        v.players = [a, b]
        v.addSubview(a)
        v.addSubview(b)
        return v
    }

    func updateUIView(_ v: PlayerHostView, context: Context) {
        v.bringSubviewToFront(active)
        for w in [a, b] { w.alpha = (w === active) ? 1 : 0.01 }
    }
}

// MARK: - Player model

final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

enum RepeatMode: Int { case off, all, one }

final class PlayerModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webA: WKWebView
    let webB: WKWebView
    @Published private(set) var webView: WKWebView          // הנגן שמתנגן עכשיו
    private var standby: WKWebView { webView === webA ? webB : webA }   // מכין את השיר הבא
    @Published private(set) var sampleMode = false
    // מילים
    @Published var showLyrics = UserDefaults.standard.bool(forKey: "showLyrics") {
        didSet { UserDefaults.standard.set(showLyrics, forKey: "showLyrics") }
    }
    @Published var lyricLine = ""
    @Published var lyricPrev = ""
    @Published var lyricsAvailable: Bool?
    // המשך מאיפה שהפסקת
    private var restoring = false
    private var resumeAt: Double = 0
    private var lastSave = Date.distantPast
    private var sampleStart: Double = 0
    private var sampleSeeked = false
    var sampleProgress: Double {
        guard sampleMode, sampleSeeked else { return 0 }
        return min(max((time - sampleStart) / 30, 0), 1)
    }
    private var standbyID: String?
    private var standbyReady = false
    private var didEarly = false
    private var endHandled = false
    @Published var earlyStart: Bool = (UserDefaults.standard.object(forKey: "earlyStart") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(earlyStart, forKey: "earlyStart") }
    }
    @Published var current: Song?
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var isPlaying = false
    @Published var inAd = false
    @Published var expanded = false
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var sleepEnd: Date?
    @Published var stopAfterSong = false
    @Published var artworkImage: UIImage?
    @Published var tint: Color = .brand

    var onSongInfo: ((Song) -> Void)?
    var onPlayStart: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    /// התור עומד להיגמר — מבקשים עוד שירים דומים
    var onNeedMore: ((Song) -> Void)?
    private var moreRequestedFor = ""
    private var advanceWhenMore = false
    private var lastTickTime = -1.0
    private var stallTicks = 0
    var autoContinue: Bool {
        get { (UserDefaults.standard.object(forKey: "autoContinue") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoContinue"); objectWillChange.send() }
    }

    /// האם המשתמש רוצה שהמוזיקה תתנגן (לא תלוי במה שיוטיוב מדווח)
    private(set) var wantsPlay = false
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveTimer: Timer?
    private var inBackground: Bool { UIApplication.shared.applicationState != .active }

    // שומר על הנגן: שיר שלא מתחיל / נגן שנסגר
    private var loadedAt = Date.distantPast
    private var started = false
    private var watchdog: DispatchWorkItem?
    private var pendingSeek: Double?
    private var failedInARow = 0
    /// מתעדכן מ-AppState — בלי אינטרנט לא מדלגים על שירים בטעות
    var networkOK = true
    /// האם השיר נמצא עכשיו בחלון צף (שם iOS כן מרשה להחליף שירים ברקע)
    private var pipActive = false
    /// מחובר לרכב (CarPlay / בלוטות' של רכב)
    @Published private(set) var inCar = false
    var keepAwakeInCar: Bool {
        get { (UserDefaults.standard.object(forKey: "keepAwakeInCar") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepAwakeInCar"); objectWillChange.send(); updateCarState() }
    }

    private(set) var queue: [Song] = []
    private var original: [Song] = []
    private var index = 0
    private var ready = false
    private var pending: URL?
    private var previousTitle = ""
    private var observers: [NSKeyValueObservation] = []
    private var sleepWork: DispatchWorkItem?
    private var artworkFor = ""
    private var lastNowPlaying = Date.distantPast

    struct Session: Codable { let queue: [Song]; let index: Int; let time: Double }

    var hasNext: Bool { nextIndex != nil }
    /// אפשר ללחוץ "הבא" גם בסוף התור, כשממשיכים עם שירים דומים
    var canSkip: Bool { hasNext || (autoContinue && current != nil && !sampleMode) }
    private var nextIndex: Int? {
        if index + 1 < queue.count { return index + 1 }
        if repeatMode == .all, !queue.isEmpty { return 0 }
        return nil
    }
    var sleepActive: Bool { sleepEnd != nil || stopAfterSong }
    var sleepLabel: String {
        if stopAfterSong { return "סוף השיר" }
        if let end = sleepEnd {
            let m = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
            return "עוד \(m) דק׳"
        }
        return "טיימר שינה"
    }

    private static func makePlayerWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(
            WKUserScript(source: AdRules.playerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let w = WKWebView(frame: .zero, configuration: config)
        w.isUserInteractionEnabled = false
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.isScrollEnabled = false
        return w
    }

    override init() {
        webA = PlayerModel.makePlayerWebView()
        webB = PlayerModel.makePlayerWebView()
        webView = webA
        super.init()
        for w in [webA, webB] {
            w.configuration.userContentController.add(WeakHandler(self), name: "player")
            w.navigationDelegate = self
        }
        observers = [
            webA.observe(\.url) { [weak self] wv, _ in if self?.webView === wv { self?.urlChanged() } },
            webB.observe(\.url) { [weak self] wv, _ in if self?.webView === wv { self?.urlChanged() } }
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(appWentToBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResign),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        setupRemoteCommands()
        restoreSession()
        DispatchQueue.main.async { [weak self] in self?.updateCarState() }
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)

        AdRules.compile(youtube: true) { [weak self] list in
            guard let self else { return }
            if let list {
                self.webA.configuration.userContentController.add(list)
                self.webB.configuration.userContentController.add(list)
            }
            self.ready = true
            if let p = self.pending { self.webView.load(URLRequest(url: p)); self.pending = nil }
        }
    }

    // MARK: Queue

    func play(_ song: Song, in list: [Song]?) {
        var q = list ?? [song]
        if !q.contains(where: { $0.id == song.id }) { q = [song] }
        original = q
        if shuffle {
            var rest = q.filter { $0.id != song.id }
            rest.shuffle()
            queue = [song] + rest
            load(at: 0)
        } else {
            queue = q
            load(at: q.firstIndex { $0.id == song.id } ?? 0)
        }
    }

    func next() {
        if UIApplication.shared.applicationState == .active { Haptics.tap() }
        SystemVolume.shared.restore()
        if switchToPreloaded() { return }
        if let n = nextIndex { load(at: n); return }
        // סוף התור: מביאים שירים דומים ועוברים אליהם
        if autoContinue, let s = current, !sampleMode {
            advanceWhenMore = true
            onNotice?("מחפש שירים דומים…")
            onNeedMore?(s)
        }
    }

    /// מסך נעילה / אוזניות / הגה: לפעמים אותה לחיצה מגיעה פעמיים — מתעלמים מהכפילות
    private var lastRemoteSkip = Date.distantPast
    func remoteSkip(forward: Bool) {
        guard Date().timeIntervalSince(lastRemoteSkip) > 0.8 else { return }
        lastRemoteSkip = Date()
        if forward { next() } else { previous() }
    }

    // MARK: Up next (הבא בתור)

    var upNext: [Song] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    func moveUpNext(from: IndexSet, to: Int) {
        var list = upNext
        list.move(fromOffsets: from, toOffset: to)
        queue = Array(queue[...index]) + list
        original = queue
        objectWillChange.send()
    }

    func removeUpNext(at offsets: IndexSet) {
        var list = upNext
        list.remove(atOffsets: offsets)
        queue = Array(queue[...index]) + list
        original = queue
        objectWillChange.send()
    }

    func clearUpNext() {
        guard !queue.isEmpty else { return }
        queue = Array(queue[...index])
        original = queue
        objectWillChange.send()
    }

    func jumpToUpNext(_ offset: Int) {
        let i = index + 1 + offset
        guard i < queue.count else { return }
        load(at: i)
    }

    // MARK: Session (המשך מאיפה שהפסקת)

    private func saveSession(force: Bool = false) {
        guard !sampleMode, !restoring, let _ = current, !queue.isEmpty else { return }
        if !force && Date().timeIntervalSince(lastSave) < 5 { return }
        lastSave = Date()
        let session = Session(queue: Array(queue.prefix(200)), index: min(index, 199), time: time)
        UserDefaults.standard.set(try? JSONEncoder().encode(session), forKey: "session")
    }

    private func restoreSession() {
        guard let d = UserDefaults.standard.data(forKey: "session"),
              let session = try? JSONDecoder().decode(Session.self, from: d),
              session.index < session.queue.count else { return }
        queue = session.queue
        original = session.queue
        index = session.index
        let s = queue[index]
        current = s
        time = session.time
        resumeAt = session.time
        restoring = true
        isPlaying = false
        wantsPlay = false
        loadArtwork(for: s.id)
        updateNowPlaying(force: true)
        let url = URL(string: "https://m.youtube.com/watch?v=\(s.id)&restore=1")!
        if ready { webView.load(URLRequest(url: url)) } else { pending = url }
    }

    // MARK: Lyrics (מילים)

    func toggleLyrics() {
        Haptics.tap()
        showLyrics.toggle()
        js("window.__wantLyrics=\(showLyrics);")
    }

    // MARK: Samples (טעימות): 30 שניות מאמצע השיר

    /// מה שהתנגן לפני שנכנסת לטעימות — חוזרים אליו כשיוצאים
    private var resumeAfterRestore = false
    private var hadSessionBeforeSamples = false

    func playSample(_ s: Song) {
        if sampleMode, current?.id == s.id { return }
        SystemVolume.shared.restore()
        if !sampleMode {
            hadSessionBeforeSamples = current != nil && !queue.isEmpty
            resumeAfterRestore = hadSessionBeforeSamples && wantsPlay
            if hadSessionBeforeSamples { saveSession(force: true) }
        }
        sampleMode = true
        sampleSeeked = false
        sampleStart = 0
        expanded = false
        queue = [s]
        original = [s]
        standbyID = nil
        standbyReady = false
        load(at: 0)
    }

    func playFullSample() {
        guard sampleMode, let s = current else { return }
        hadSessionBeforeSamples = false
        resumeAfterRestore = false
        sampleMode = false
        sampleSeeked = false
        seek(0)
        setPlaying(true)
        if !s.title.isEmpty { onSongInfo?(s) }
        onPlayStart?(s.id)
    }

    func stopSamples() {
        guard sampleMode else { return }
        let resume = resumeAfterRestore
        setPlaying(false)
        sampleMode = false
        sampleSeeked = false
        current = nil
        queue = []
        original = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if hadSessionBeforeSamples {
            hadSessionBeforeSamples = false
            restoreSession()                 // חוזרים לשיר ולתור שהיו לפני הטעימות
            resumeAfterRestore = resume      // ואם הוא התנגן — ממשיכים לנגן
        }
    }

    // MARK: Next song, prepared in advance

    private func handleEnded() {
        if sampleMode {
            seek(sampleStart)
            setPlaying(true)
            return
        }
        guard !endHandled else { return }
        endHandled = true
        if stopAfterSong {
            stopAfterSong = false
            setPlaying(false)
            return
        }
        if repeatMode == .one {
            endHandled = false
            seek(0)
            setPlaying(true)
            return
        }
        DebugLog.add("שיר נגמר: \(current?.displayTitle ?? "?")" + (inBackground ? " (ברקע)" : ""))
        guard let n = nextIndex else {
            // התור נגמר — ממשיכים עם שירים דומים, כמו בספוטיפיי
            if autoContinue, let s = current {
                DebugLog.add("התור נגמר, מחפש שירים דומים")
                advanceWhenMore = true
                if inBackground { startKeepAlive() }
                moreRequestedFor = s.id
                onNeedMore?(s)
            } else {
                DebugLog.add("התור נגמר")
                setPlaying(false)
            }
            return
        }
        if switchToPreloaded() {
            DebugLog.add("עבר לשיר הבא (מוכן מראש)")
            SystemVolume.shared.restore()
        } else {
            DebugLog.add("טוען את השיר הבא")
            SystemVolume.shared.restore()
            load(at: n)
        }
    }

    /// טוען את השיר הבא בנגן השני, מושתק ועצור בהתחלה (כולל דילוג על פרסומת)
    private func preloadNext() {
        guard ready, !(inBackground && pipActive), let n = nextIndex, n < queue.count, standbyID != queue[n].id else { return }
        let id = queue[n].id
        standbyID = id
        standbyReady = false
        // ברקע: השיר הבא נטען כשמע בלבד — כך iOS מרשה לו להתחיל גם כשהאייפון נעול
        let warm = inBackground ? "&warm=1&audio=1" : ""
        if inBackground { DebugLog.add("ברקע: מכין את השיר הבא") }
        if let url = URL(string: "https://m.youtube.com/watch?v=\(id)&standby=1" + warm) {
            standby.load(URLRequest(url: url))
        }
    }

    /// עובר מיד לשיר הבא שכבר מוכן ברקע
    @discardableResult
    private func switchToPreloaded() -> Bool {
        guard !inBackground || !pipActive else { return false }
        guard let n = nextIndex, n < queue.count, let sid = standbyID, sid == queue[n].id else { return false }
        let old = webView
        old.evaluateJavaScript("window.__userPaused=true; document.querySelectorAll('video').forEach(v => v.pause())", completionHandler: nil)
        webView = standby
        standbyID = nil
        js("window.__standby=false; window.__keepWarm=false; window.__userPaused=false; var v=document.querySelector('video'); if(v){ v.muted=false; v.currentTime=0; var p=v.play(); if(p&&p.catch)p.catch(function(){}); }")
        index = n
        let s = queue[n]
        previousTitle = current?.title ?? ""
        current = s
        time = 0; duration = 0
        didEarly = false
        endHandled = false
        standbyReady = false
        lyricLine = ""; lyricPrev = ""; lyricsAvailable = nil
        isPlaying = true
        wantsPlay = true
        try? AVAudioSession.sharedInstance().setActive(true)
        metaPushed = ""
        armWatchdog(for: s.id)
        if inBackground { startKeepAlive() }
        if !s.title.isEmpty { onSongInfo?(s) }
        onPlayStart?(s.id)
        loadArtwork(for: s.id)
        updateNowPlaying(force: true)
        old.loadHTMLString("", baseURL: nil)   // מפנה את הנגן הישן להכנת השיר הבא
        return true
    }

    func previous() {
        if UIApplication.shared.applicationState == .active { Haptics.tap() }
        if time > 3 || index == 0 { seek(0) } else { load(at: index - 1) }
    }

    func playNext(_ song: Song) {
        guard !queue.isEmpty else { play(song, in: nil); return }
        if let i = queue.firstIndex(where: { $0.id == song.id }) {
            if i == index { return }
            queue.remove(at: i)
            if i < index { index -= 1 }
        }
        queue.insert(song, at: index + 1)
        if !original.contains(where: { $0.id == song.id }) { original.append(song) }
        objectWillChange.send()
    }

    @discardableResult
    func enqueue(_ songs: [Song]) -> Int {
        let ids = Set(queue.map { $0.id })
        let new = Array(songs.filter { !ids.contains($0.id) }.prefix(15))
        queue.append(contentsOf: new)
        original.append(contentsOf: new)
        objectWillChange.send()
        DebugLog.add("נוספו \(new.count) שירים לתור")
        if advanceWhenMore {
            advanceWhenMore = false
            if !new.isEmpty, let n = nextIndex { load(at: n) }
            else { setPlaying(false); onNotice?("אין עוד שירים בתור") }
        }
        return new.count
    }

    func toggleShuffle() { Haptics.tap(); setShuffle(!shuffle) }

    func setShuffle(_ on: Bool) {
        shuffle = on
        guard !queue.isEmpty, index < queue.count else { return }
        let cur = queue[index]
        if on {
            original = queue
            var rest = queue
            rest.remove(at: index)
            rest.shuffle()
            queue = [cur] + rest
            index = 0
        } else if !original.isEmpty {
            queue = original
            index = original.firstIndex { $0.id == cur.id } ?? 0
        }
    }

    func cycleRepeat() {
        Haptics.tap()
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    // MARK: Playback

    func togglePlay() { setPlaying(!isPlaying) }

    func setPlaying(_ on: Bool) {
        wantsPlay = on
        if UIApplication.shared.applicationState == .active { Haptics.soft() }
        if !on { endKeepAlive() }
        if on {
            try? AVAudioSession.sharedInstance().setActive(true)
            if restoring {
                // השיר עוד נטען אחרי פתיחת האפליקציה — ממשיכים מאותה שנייה ולא מההתחלה
                if resumeAt > 1 { pendingSeek = resumeAt }
                started = false
            }
            restoring = false
            js("window.__restore=false; window.__userPaused=false; var v=document.querySelector('video'); if(v){ v.muted=false; v.play(); }")
        } else {
            js("window.__userPaused=true; var v=document.querySelector('video'); if(v){ v.pause(); }")
        }
        isPlaying = on
        updateNowPlaying(force: true)
    }

    func seek(_ t: Double) {
        js("var v=document.querySelector('video'); if(v){ v.currentTime=\(t); }")
        time = t
        updateNowPlaying(force: true)
    }

    private func load(at i: Int) {
        guard i >= 0, i < queue.count else { return }
        index = i
        let s = queue[i]
        previousTitle = current?.title ?? ""
        current = s
        time = 0; duration = 0
        didEarly = false
        endHandled = false
        restoring = false
        lyricLine = ""; lyricPrev = ""; lyricsAvailable = nil
        lastTickTime = -1; stallTicks = 0
        metaPushed = ""
        if standbyID == s.id { standbyID = nil; standbyReady = false }
        if !sampleMode {
            if !s.title.isEmpty { onSongInfo?(s) }
            onPlayStart?(s.id)
        }
        loadArtwork(for: s.id)
        updateNowPlaying(force: true)
        armWatchdog(for: s.id)
        wantsPlay = true
        try? AVAudioSession.sharedInstance().setActive(true)
        let url = URL(string: "https://m.youtube.com/watch?v=\(s.id)")!
        if inBackground && !pipActive && ready && !sampleMode {
            // אייפון נעול: טוענים את השיר כשמע בלבד (iOS לא חוסם התחלה של שמע ברקע)
            let audioURL = URL(string: "https://m.youtube.com/watch?v=\(s.id)&audio=1")!
            DebugLog.add("ברקע (נעול): טוען את השיר כשמע בלבד")
            webView.load(URLRequest(url: audioURL))
            startKeepAlive()
        } else if inBackground && ready && webView.url != nil {
            // ברקע: מחליפים שיר בתוך אותו נגן, כדי שהחלון הצף והקול לא ייסגרו
            let js = "(function(){var mp=document.getElementById('movie_player');" +
                "if(mp&&mp.loadVideoById){window.__userPaused=false;mp.loadVideoById('\(s.id)');" +
                "try{mp.playVideo&&mp.playVideo();}catch(e){}return true;}return false;})()"
            webView.evaluateJavaScript(js) { [weak self] result, error in
                if (result as? Bool) == true {
                    DebugLog.add("ברקע: הוחלף שיר בתוך הנגן")
                } else {
                    DebugLog.add("ברקע: החלפה בתוך הנגן נכשלה (\(error?.localizedDescription ?? "אין נגן")), טוען דף")
                    self?.webView.load(URLRequest(url: url))
                }
            }
            startKeepAlive()
        } else {
            if ready { webView.load(URLRequest(url: url)) } else { pending = url }
            if inBackground { startKeepAlive() }
        }
    }

    // MARK: Watchdog + recovery

    private func armWatchdog(for id: String) {
        loadedAt = Date()
        started = false
        watchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.checkStarted(id) }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
    }

    private func checkStarted(_ id: String) {
        guard current?.id == id, !started, !restoring else { return }
        if inAd || !networkOK { armWatchdog(for: id); return }
        if inBackground {
            // זה לא שיר "לא זמין" — iOS לא מרשה לשיר חדש להתחיל כשהאייפון נעול.
            // משאירים אותו מוכן: לחיצה על ▶ (ברכב / במסך הנעילה) או פתיחת האפליקציה ימשיכו אותו.
            DebugLog.add("ברקע: iOS לא נתן לשיר להתחיל — מחכה ל-▶ או לפתיחת האפליקציה"
                         + ((webView.url?.absoluteString.contains("audio=1") ?? false) ? " (גם כשמע בלבד)" : ""))
            isPlaying = false
            updateNowPlaying(force: true)
            return
        }
        songUnavailable()
    }

    /// השיר הוסר / חסום / מוגבל — מדלגים לבא בתור
    private func songUnavailable() {
        guard !sampleMode else { return }
        DebugLog.add("שיר לא זמין: \(current?.displayTitle ?? "?")")
        started = true
        watchdog?.cancel()
        failedInARow += 1
        if failedInARow >= 4 {
            failedInARow = 0
            setPlaying(false)
            onNotice?("יש בעיה בניגון. בדוק את החיבור ונסה שוב")
            return
        }
        if hasNext {
            onNotice?("השיר לא זמין, עובר לבא")
            if let n = nextIndex { load(at: n) }
        } else {
            onNotice?("השיר לא זמין")
            setPlaying(false)
        }
    }

    /// iOS סגר את הנגן בגלל זיכרון — טוענים מחדש מאותה שנייה
    func webViewWebContentProcessDidTerminate(_ wv: WKWebView) {
        if wv === standby {
            standbyID = nil
            standbyReady = false
            return
        }
        guard wv === webView, let s = current else { return }
        let wasPlaying = isPlaying
        pendingSeek = time > 2 ? time : nil
        let url = URL(string: "https://m.youtube.com/watch?v=\(s.id)" + (wasPlaying ? "" : "&restore=1"))!
        if !wasPlaying { restoring = true; resumeAt = time; pendingSeek = nil }
        armWatchdog(for: s.id)
        wv.load(URLRequest(url: url))
    }

    private func js(_ s: String) { webView.evaluateJavaScript(s, completionHandler: nil) }

    // MARK: Sleep timer

    func setSleep(minutes: Int) {
        cancelSleep()
        let seconds = Double(minutes * 60)
        sleepEnd = Date().addingTimeInterval(seconds)
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sleepEnd = nil
            self.setPlaying(false)
        }
        sleepWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func setSleepEndOfSong() {
        cancelSleep()
        stopAfterSong = true
    }

    func cancelSleep() {
        sleepWork?.cancel()
        sleepWork = nil
        sleepEnd = nil
        stopAfterSong = false
    }

    // MARK: Background + lock screen

    private var interrupted = false

    /// שיחת טלפון / שעון מעורר: עוצרים, וממשיכים כשנגמר
    @objc private func audioInterrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.interrupted = self.wantsPlay
                self.wantsPlay = false
                self.endKeepAlive()
                self.js("window.__userPaused=true;")
                self.isPlaying = false
            } else {
                let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                if self.interrupted && AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) {
                    self.setPlaying(true)
                }
                self.interrupted = false
            }
        }
    }

    /// אוזניות נותקו: עוצרים (לא ממשיכים מהרמקול). רכב התחבר/התנתק: מעדכנים מצב רכב.
    @objc private func routeChanged(_ n: Notification) {
        DispatchQueue.main.async { self.updateCarState() }
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { self.setPlaying(false) }
    }

    /// כשהאייפון מחובר לרכב — המסך לא נכבה לבד. כך האפליקציה נשארת פתוחה, ו-iOS לא חוסם את השיר הבא.
    func updateCarState() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let car = outputs.contains { $0.portType == .carAudio }
        if car != inCar {
            inCar = car
            DebugLog.add(car ? "מחובר לרכב" : "התנתק מהרכב")
            if car && keepAwakeInCar { onNotice?("מחובר לרכב: המסך יישאר דלוק כדי שהשירים יתחלפו") }
        }
        UIApplication.shared.isIdleTimerDisabled = car && keepAwakeInCar
    }

    /// iOS לא מרשה לווידאו מדף אינטרנט להמשיך ברקע — חוץ מבחלון צף (תמונה בתוך תמונה).
    /// לכן ברגע שיוצאים מהאפליקציה, השיר עובר לחלון צף וממשיך להתנגן.
    var backgroundPiP: Bool {
        get { (UserDefaults.standard.object(forKey: "bgPiP") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "bgPiP"); objectWillChange.send() }
    }

    static let enterPiPJS = """
    (function(){
      var v = document.querySelector('video');
      if (!v || v.paused || !v.webkitSupportsPresentationMode) return 'no';
      v.disablePictureInPicture = false;
      v.removeAttribute('disablepictureinpicture');
      if (!v.webkitSupportsPresentationMode('picture-in-picture')) return 'unsupported';
      if (v.webkitPresentationMode !== 'picture-in-picture') v.webkitSetPresentationMode('picture-in-picture');
      return 'ok';
    })();
    """

    static let exitPiPJS = """
    (function(){
      var v = document.querySelector('video');
      if (v && v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
    })();
    """

    @objc private func appWillResign() {
        js("window.__appActive=false;")
        // השיר הבא כבר מתנגן בשקט ברקע — כך שאפשר להחליף אליו גם כשהאייפון נעול
        standby.evaluateJavaScript("window.__appActive=false; window.__keepWarm=true; var v=document.querySelector('video'); if(v){ v.muted=true; var p=v.play(); if(p&&p.catch)p.catch(function(){}); }", completionHandler: nil)
        if autoContinue, !sampleMode, queue.count - index <= 5, let s = current, !s.title.isEmpty,
           moreRequestedFor != s.id {
            moreRequestedFor = s.id
            DebugLog.add("יציאה מהאפליקציה: ממלא את התור מראש")
            onNeedMore?(s)
        }
        guard wantsPlay, isPlaying, !sampleMode, !inAd, backgroundPiP else { return }
        webView.evaluateJavaScript(PlayerModel.enterPiPJS) { [weak self] r, err in
            let result = (r as? String) ?? (err?.localizedDescription ?? "?")
            self?.pipActive = result == "ok"
            DebugLog.add("חלון צף: " + result)
        }
    }

    @objc private func appWentToBackground() {
        saveSession(force: true)
        DebugLog.add("יצאת מהאפליקציה (מתנגן: \(isPlaying ? "כן" : "לא"))")
        // בודקים מה המשתמש רוצה, לא מה יוטיוב מדווח — בשלב הזה האייפון כבר עצר את הווידאו
        guard wantsPlay, !sampleMode else { return }
        startKeepAlive()
    }

    @objc private func appBecameActive() {
        endKeepAlive()
        pipActive = false
        // שיר שנטען כשמע בלבד כשהאייפון היה נעול — מחזירים לו את התמונה מאותה שנייה
        if let u = webView.url?.absoluteString, u.contains("audio=1"), let s = current, !sampleMode {
            DebugLog.add("חזרה לאפליקציה: מחזיר וידאו לשיר")
            let keepPlaying = wantsPlay
            pendingSeek = time > 2 ? time : nil
            if !keepPlaying { restoring = true; resumeAt = time; pendingSeek = nil }
            armWatchdog(for: s.id)
            webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(s.id)" + (keepPlaying ? "" : "&restore=1"))!))
        }
        // השיר הבא שהוכן כשמע בלבד — מכינים אותו מחדש עם וידאו
        if let u = standby.url?.absoluteString, u.contains("audio=1") { standbyID = nil; standbyReady = false }
        updateCarState()
        js("window.__appActive=true;")
        standby.evaluateJavaScript("window.__appActive=true; window.__keepWarm=false;", completionHandler: nil)
        js(PlayerModel.exitPiPJS)
        if wantsPlay && !isPlaying && !inAd && !restoring { js(PlayerModel.resumeJS) }
    }

    /// סקריפט שמחזיר את השיר לנגן ומדווח אם הוא מתנגן
    static let resumeJS = """
    (function(){
      var v = document.querySelector('video');
      if (!v) return false;
      window.__userPaused = false;
      if (window.__standby || window.__restore) return !v.paused;
      if (document.querySelector('.ad-showing, .ad-interrupting')) { v.muted = true; return true; }
      if (v.paused && !v.ended) {
        v.muted = false;
        try { var mp = document.getElementById('movie_player'); if (mp && mp.playVideo) mp.playVideo(); } catch (e) {}
        try { var p = v.play(); if (p && p.catch) p.catch(function(){}); } catch (e) {}
      }
      return !v.paused;
    })();
    """

    /// מחזיק את האפליקציה ער עד שהשיר חוזר לנגן ברקע (עד 25 שניות)
    func startKeepAlive() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "keepPlaying") { [weak self] in
                self?.endKeepAlive()
            }
        }
        keepAliveTimer?.invalidate()
        var ticks = 0
        var playingTicks = 0
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1
            if !self.wantsPlay || ticks > 100 { self.endKeepAlive(); return }
            self.webView.evaluateJavaScript(PlayerModel.resumeJS) { result, _ in
                if (result as? Bool) == true { playingTicks += 1 } else { playingTicks = 0 }
                // מתנגן ברצף כ-3 שניות — האייפון כבר ישאיר אותו ער לבד
                if playingTicks >= 12 { self.endKeepAlive() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        keepAliveTimer = t
    }

    private func endKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in DebugLog.add("פקודת מערכת: נגן"); self?.setPlaying(true); return .success }
        c.pauseCommand.addTarget { [weak self] _ in DebugLog.add("פקודת מערכת: עצור"); self?.setPlaying(false); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.remoteSkip(forward: true); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.remoteSkip(forward: false); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) }
            return .success
        }
    }

    private var metaPushed = ""

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        guard wv === webView, let s = current else { return }
        metaPushed = ""
        pushPageMeta(s)
    }

    /// שולח לדף את השם הנקי — זה מה שמסך הנעילה מציג
    private func pushPageMeta(_ s: Song) {
        guard !s.title.isEmpty else { return }
        let key = "\(ObjectIdentifier(webView).hashValue)|\(s.id)|\(s.displayTitle)|\(s.displayArtist)"
        guard key != metaPushed else { return }
        metaPushed = key
        func lit(_ x: String) -> String {
            let d = (try? JSONSerialization.data(withJSONObject: [x])) ?? Data("[\"\"]".utf8)
            let arr = String(decoding: d, as: UTF8.self)
            return String(arr.dropFirst().dropLast())
        }
        let art = "https://i.ytimg.com/vi/\(s.id)/hqdefault.jpg"
        js("window.__setMeta && window.__setMeta(\(lit(s.displayTitle)), \(lit(s.displayArtist)), \(lit(art)));")
    }

    private func updateNowPlaying(force: Bool = false) {
        guard let s = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        pushPageMeta(s)
        if !force && Date().timeIntervalSince(lastNowPlaying) < 5 { return }
        lastNowPlaying = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.displayTitle,
            MPMediaItemPropertyArtist: s.displayArtist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let img = artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Artwork + color

    private func loadArtwork(for id: String) {
        guard artworkFor != id else { return }
        artworkFor = id
        artworkImage = nil
        fetchArtwork(id: id, names: ["maxresdefault", "hqdefault", "mqdefault"])
    }

    private func fetchArtwork(id: String, names: [String]) {
        guard let name = names.first,
              let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok, let data, let raw = UIImage(data: data), raw.size.width > 200 {
                let img = PlayerModel.cropLetterbox(raw)
                let color = PlayerModel.vividColor(from: img)
                DispatchQueue.main.async {
                    guard let self, self.artworkFor == id else { return }
                    self.artworkImage = img
                    self.tint = color
                    self.updateNowPlaying(force: true)
                }
            } else {
                self?.fetchArtwork(id: id, names: Array(names.dropFirst()))
            }
        }.resume()
    }

    /// תמונות hqdefault מגיעות עם פסים שחורים — חותכים לחלק של הסרטון (16:9)
    static func cropLetterbox(_ img: UIImage) -> UIImage {
        guard let cg = img.cgImage else { return img }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let targetH = w * 9 / 16
        guard h - targetH > 4 else { return img }
        let rect = CGRect(x: 0, y: (h - targetH) / 2, width: w, height: targetH)
        guard let cropped = cg.cropping(to: rect) else { return img }
        return UIImage(cgImage: cropped, scale: img.scale, orientation: img.imageOrientation)
    }

    static func vividColor(from image: UIImage) -> Color {
        guard let src = image.cgImage else { return .brand }
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return .brand }
        var r = 0.0, g = 0.0, b = 0.0
        for k in 0..<(n * n) {
            r += Double(px[k * 4]); g += Double(px[k * 4 + 1]); b += Double(px[k * 4 + 2])
        }
        let count = Double(n * n) * 255
        let ui = UIColor(red: CGFloat(r / count), green: CGFloat(g / count), blue: CGFloat(b / count), alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        ui.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return Color(hue: Double(hue), saturation: Double(max(sat, 0.45)),
                     brightness: Double(min(max(bri, 0.45), 0.75)))
    }

    // MARK: YouTube page events

    private func urlChanged() {
        guard let url = webView.url else { return }
        if url.host == "music.youtube.com" || url.path.hasPrefix("/shorts/") {
            webView.load(URLRequest(url: WebModel.normalizeYouTube(url)))
            return
        }
        guard let id = WebModel.videoID(url) else { return }
        if current?.id != id, !sampleMode, !restoring, let n = nextIndex, n < queue.count {
            // יוטיוב ניגן "הבא בתור" משלו — חוזרים לתור שלנו
            DebugLog.add("יוטיוב עבר לשיר אחר בעצמו, חוזר לתור")
            load(at: n)
            return
        }
        if current?.id != id {          // יוטיוב עבר לשיר הבא בעצמו (התור שלנו נגמר)
            DebugLog.add("יוטיוב בחר שיר בעצמו, מוסיף אותו לתור")
            previousTitle = current?.title ?? ""
            let s = Song(id: id, title: "", artist: nil)
            // מכניסים אותו לתור במקום הנכון, כדי שהקודם/הבא/השמירה יעבדו נכון
            if !sampleMode {
                if queue.isEmpty { queue = [s]; index = 0 }
                else { index = min(index + 1, queue.count); queue.insert(s, at: index) }
                original.append(s)
            }
            current = s
            advanceWhenMore = false
            time = 0; duration = 0
            didEarly = false
            endHandled = false
            metaPushed = ""
            armWatchdog(for: id)
            onPlayStart?(id)
            loadArtwork(for: id)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }

        // הודעות מהנגן השני: האם השיר הבא כבר מוכן?
        if message.webView === standby {
            if (d["audioOnly"] as? Bool) == true { DebugLog.add("ברקע: השיר הבא הוכן כשמע בלבד"); return }
            let buffered = (d["buf"] as? Double) ?? 0
            let ad = (d["ad"] as? Bool) ?? true
            standbyReady = standbyID != nil && !ad && buffered >= 3
            return
        }
        guard message.webView === webView else { return }

        if (d["audioOnly"] as? Bool) == true {
            DebugLog.add("ברקע: השיר נטען כשמע בלבד")
            return
        }

        if let p = d["pip"] as? Bool {
            if p != pipActive { DebugLog.add(p ? "חלון צף נפתח" : "חלון צף נסגר") }
            pipActive = p
            return
        }

        if let r = d["remote"] as? String {
            DebugLog.add("מסך נעילה: " + r)
            switch r {
            case "next": remoteSkip(forward: true)
            case "prev": remoteSkip(forward: false)
            case "pause": setPlaying(false)
            case "play": setPlaying(true)
            default: break
            }
            return
        }

        if (d["ended"] as? Bool) == true { handleEnded(); return }

        let wasPlaying = isPlaying
        time = (d["t"] as? Double) ?? time
        duration = (d["d"] as? Double) ?? duration
        isPlaying = !((d["p"] as? Bool) ?? true)
        inAd = (d["ad"] as? Bool) ?? false
        if (d["err"] as? Bool) == true, !started, !restoring { songUnavailable(); return }
        if !started && !inAd && (time > 0.3 || (restoring && duration > 0)) {
            started = true
            failedInARow = 0
            watchdog?.cancel()
        }
        if inAd { loadedAt = Date() }
        if let ps = pendingSeek, !inAd, duration > 0 {
            pendingSeek = nil
            if ps < duration - 3 { seek(ps) }
        }
        if restoring {
            if !inAd, duration > 0 {
                restoring = false
                if resumeAt > 1 && resumeAt < duration - 3 { seek(resumeAt) }
                if resumeAfterRestore {
                    resumeAfterRestore = false
                    setPlaying(true)
                }
            }
            if restoring { isPlaying = false }
        }
        if wantsPlay && !isPlaying && !inAd && !restoring && !sampleMode && inBackground && started {
            js(PlayerModel.resumeJS)
            if keepAliveTimer == nil { startKeepAlive() }
        }
        updateNowPlaying(force: wasPlaying != isPlaying)
        saveSession()

        // מילים מהכתוביות של יוטיוב
        if showLyrics {
            if (d["wl"] as? Bool) != true { js("window.__wantLyrics=true;") }
            let line = ((d["lyr"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty && line != lyricLine {
                lyricPrev = lyricLine
                lyricLine = line
                lyricsAvailable = true
            }
            if let la = d["la"] as? Int, la == 0, time > 6, lyricsAvailable == nil { lyricsAvailable = false }
            if let la = d["la"] as? Int, la > 0, lyricsAvailable == false { lyricsAvailable = nil }
        }

        if sampleMode {
            if !inAd && duration > 0 {
                if !sampleSeeked {
                    sampleSeeked = true
                    sampleStart = max(0, min(duration * 0.35, duration - 35))
                    seek(sampleStart)
                } else if time > sampleStart + 30 || time < sampleStart - 2 {
                    seek(sampleStart)
                }
            }
        } else if !inAd && duration > 0 {
            let remaining = duration - time
            // מכינים את השיר הבא כבר מהשנייה ה-3 (גם ברקע כשאין חלון צף)
            if time > 3 && repeatMode != .one { preloadNext() }

            // ברקע (CarPlay / מסך נעול): עוברים לשיר הבא כשהנוכחי עוד מתנגן.
            // iOS לא מרשה לווידאו שנעצר להתחיל מחדש ברקע — אבל מרשה לנגן שממשיך לנגן.
            if inBackground, !didEarly, isPlaying, wantsPlay, duration > 20, time > 10, remaining <= 1.5,
               repeatMode != .one, !stopAfterSong, let n = nextIndex {
                didEarly = true
                endHandled = true
                if !pipActive, standbyReady, switchToPreloaded() {
                    DebugLog.add("ברקע (נעול): עבר לשיר הבא שהתנגן בשקט")
                } else {
                    DebugLog.add(pipActive ? "ברקע (חלון צף): מחליף שיר בתוך הנגן" : "ברקע (נעול): השיר הבא לא היה מוכן, מנסה בתוך הנגן")
                    load(at: n)
                }
                return
            }

            // 5 שניות לפני הסוף: השיר הבא מתחיל מיד, בעוצמה מלאה (בלי החלשה)
            if earlyStart, !inBackground, !didEarly, isPlaying, duration > 30, time > 10, remaining <= 5,
               repeatMode != .one, !stopAfterSong, standbyReady, nextIndex != nil {
                didEarly = true
                if switchToPreloaded() { DebugLog.add("עבר לשיר הבא 5 שניות לפני הסוף") }
                return
            }

            // גיבוי: אם יוטיוב לא שלח "נגמר" — מזהים לבד את סוף השיר
            // ממלאים את התור מראש כשמתנגן השיר האחרון
            if autoContinue, repeatMode == .off, time > 15, queue.count - index <= 3,
               let s = current, moreRequestedFor != s.id {
                moreRequestedFor = s.id
                onNeedMore?(s)
            }

            // זיהוי סוף שיר שלא תלוי בהודעה של יוטיוב
            let ended = (d["e"] as? Bool) == true
            if !endHandled, wantsPlay, duration > 5, time > 5 {
                if ended || (!isPlaying && remaining < 0.8) {
                    DebugLog.add("סוף שיר זוהה בבדיקה")
                    handleEnded(); return
                }
                if remaining < 3 && abs(time - lastTickTime) < 0.01 { stallTicks += 1 } else { stallTicks = 0 }
                if stallTicks >= 8 {
                    stallTicks = 0
                    DebugLog.add("השיר נתקע בסוף, ממשיך")
                    handleEnded(); return
                }
            }
            lastTickTime = time
        }

        guard !inAd, var s = current else { return }
        let title = ((d["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let artist = ((d["artist"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != previousTitle,
              title != s.title || (!artist.isEmpty && artist != s.artist) else { return }
        s.title = title
        if !artist.isEmpty { s.artist = artist }
        current = s
        if index < queue.count, queue[index].id == s.id { queue[index] = s }
        if !sampleMode { onSongInfo?(s) }
        updateNowPlaying(force: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if AdRules.isAdURL(url) { decisionHandler(.cancel); return }
        if url.host == "music.youtube.com" || url.path.hasPrefix("/shorts/") {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: WebModel.normalizeYouTube(url)))
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - Browser model (גוגל, וחיפוש ביוטיוב)

final class WebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum Kind { case google, youtube }

    let kind: Kind
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0

    var openYouTube: ((URL) -> Void)?
    var onPlay: ((String) -> Void)?

    private var observers: [NSKeyValueObservation] = []
    private var ready = false
    private var pending: URL?

    init(kind: Kind) {
        self.kind = kind
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsInlineMediaPlayback = true
        if kind == .google {
            config.userContentController.addUserScript(
                WKUserScript(source: AdRules.googleScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self

        observers = [
            webView.observe(\.canGoBack) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            webView.observe(\.canGoForward) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
            webView.observe(\.isLoading) { [weak self] wv, _ in self?.isLoading = wv.isLoading },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in self?.progress = wv.estimatedProgress },
            webView.observe(\.url) { [weak self] _, _ in self?.urlChanged() }
        ]

        AdRules.compile(youtube: kind == .youtube) { [weak self] list in
            guard let self else { return }
            if let list { config.userContentController.add(list) }
            self.ready = true
            if let p = self.pending { self.webView.load(URLRequest(url: p)); self.pending = nil }

        }
    }

    func load(_ url: URL) {
        if ready { webView.load(URLRequest(url: url)) } else { pending = url }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url != nil { webView.reload() }
    }

    func goHome() { load(URL(string: "https://www.google.com")!) }

    static func isYouTube(_ url: URL) -> Bool {
        let h = url.host ?? ""
        return h.hasSuffix("youtube.com") || h == "youtu.be"
    }

    static func videoID(_ url: URL) -> String? {
        let h = url.host ?? ""
        if h == "youtu.be" { return url.pathComponents.dropFirst().first }
        guard h.hasSuffix("youtube.com") else { return nil }
        if url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/embed/") { return url.lastPathComponent }
        guard url.path == "/watch" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value
    }

    /// יוטיוב מיוזיק, שורטס ו-youtu.be → יוטיוב רגיל
    static func normalizeYouTube(_ url: URL) -> URL {
        if let id = videoID(url) { return URL(string: "https://m.youtube.com/watch?v=\(id)")! }
        if url.host == "music.youtube.com", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.host = "m.youtube.com"
            return c.url ?? url
        }
        return url
    }

    // לחיצה על סרטון בתוצאות → נפתח בנגן שלך
    private func urlChanged() {
        guard kind == .youtube, let url = webView.url else { return }
        if url.host == "music.youtube.com" { webView.load(URLRequest(url: Self.normalizeYouTube(url))); return }
        guard let id = Self.videoID(url) else { return }
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())")
        if webView.canGoBack { webView.goBack() }
        onPlay?(id)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if AdRules.isAdURL(url) { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true

        if kind == .google, mainFrame, Self.isYouTube(url) {
            decisionHandler(.cancel)
            openYouTube?(url)
            return
        }
        if kind == .youtube, mainFrame, let id = Self.videoID(url) {
            decisionHandler(.cancel)
            onPlay?(id)
            return
        }
        if kind == .youtube, mainFrame, url.host == "music.youtube.com" {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: Self.normalizeYouTube(url)))
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - Ad blocking + YouTube cleanup rules

enum AdRules {
    static func isAdURL(_ url: URL) -> Bool {
        let s = url.absoluteString
        return s.contains("/aclk?") || s.contains("googleadservices.com") || s.contains("doubleclick.net")
    }

    private static var compiled: [Bool: WKContentRuleList] = [:]
    private static var waiting: [Bool: [(WKContentRuleList?) -> Void]] = [:]

    /// מכין את רשימת החסימה פעם אחת ומחלק אותה לכל הדפדפנים (במקום להכין אותה 8 פעמים בפתיחה)
    static func compile(youtube: Bool, done: @escaping (WKContentRuleList?) -> Void) {
        if let list = compiled[youtube] {
            DispatchQueue.main.async { done(list) }
            return
        }
        if waiting[youtube] != nil {
            waiting[youtube]?.append(done)
            return
        }
        waiting[youtube] = [done]
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: youtube ? "YouTubeRules" : "GoogleRules",
            encodedContentRuleList: json(youtube: youtube)
        ) { list, error in
            if let error { print("Rule compile error: \(error)") }
            DispatchQueue.main.async {
                if let list { compiled[youtube] = list }
                let callbacks = waiting[youtube] ?? []
                waiting[youtube] = nil
                callbacks.forEach { $0(list) }
            }
        }
    }

    static let blockedDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "adservice.google.com", "googletagservices.com", "googletagmanager.com",
        "google-analytics.com", "adnxs.com", "taboola.com", "outbrain.com",
        "criteo.com", "criteo.net", "amazon-adsystem.com", "adsrvr.org",
        "pubmatic.com", "rubiconproject.com", "openx.net", "moatads.com",
        "scorecardresearch.com", "quantserve.com", "popads.net", "propellerads.com",
        "mgid.com", "revcontent.com", "media.net", "smartadserver.com", "teads.tv",
        "facebook.net", "ads-twitter.com", "bidswitch.net", "casalemedia.com",
        "3lift.com", "sharethrough.com"
    ]

    static let googleSelectors = [
        "#tads", "#tadsb", "#bottomads", "[data-text-ad]",
        ".commercial-unit-desktop-top", ".commercial-unit-mobile-top",
        ".commercial-unit-mobile-bottom", ".cu-container", ".pla-unit",
        "div[aria-label='Ads']", "div[aria-label='מודעות']",
        "div[aria-label='Sponsored']", "div[aria-label='ממומן']", "[data-pla]"
    ].joined(separator: ", ")

    static let youtubeHidden = [
        // שורטס
        "ytm-reel-shelf-renderer", "ytm-shorts-lockup-view-model", "ytm-shorts-lockup-view-model-v2",
        "ytm-rich-section-renderer:has(ytm-shorts-lockup-view-model)",
        "ytm-rich-item-renderer:has(a[href^='/shorts'])",
        "ytm-video-with-context-renderer:has(a[href^='/shorts'])",
        "ytm-pivot-bar-item-renderer:has(.pivot-shorts)", "[tab-identifier='FEshorts']",
        "a[href^='/shorts']",
        // תגובות
        "ytm-comment-section-renderer", "ytm-comments-entry-point-header-renderer",
        "ytm-item-section-renderer[section-identifier='comments-entry-point']",
        "ytm-item-section-renderer[section-identifier='comment-item-section']",
        "ytm-engagement-panel-section-list-renderer[target-id='engagement-panel-comments-section']",
        // פרסומות ובאנרים
        "ytm-promoted-sparkles-web-renderer", "ytm-companion-ad-renderer", "ad-slot-renderer",
        "ytm-ad-slot-renderer", "ytm-promoted-video-renderer", "ytm-mealbar-promo-renderer",
        "ytm-statement-banner-renderer", "ytm-paid-content-overlay-renderer",
        // הודעת "חוסם פרסומות" של יוטיוב
        "ytd-enforcement-message-view-model", "ytm-enforcement-message-view-model",
        "tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)"
    ].joined(separator: ", ")

    static let genericSelectors = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^='google_ads_']", "[id^='div-gpt-ad']",
        "iframe[src*='doubleclick']", "iframe[src*='googlesyndication']",
        ".ad-banner", ".advertisement", "[data-ad-slot]"
    ].joined(separator: ", ")

    static func json(youtube: Bool) -> String {
        var rules: [[String: Any]] = blockedDomains.map { d in
            let e = d.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^https?://([^/]*\\.)?\(e)[:/]"],
                    "action": ["type": "block"]]
        }
        func hide(_ selector: String, on domains: [String]? = nil) {
            var trigger: [String: Any] = ["url-filter": ".*"]
            if let domains { trigger["if-domain"] = domains }
            rules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
        }
        hide(genericSelectors)
        if youtube { hide(youtubeHidden, on: ["*youtube.com"]) }
        else { hide(googleSelectors, on: ["*google.com", "*google.co.il"]) }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(data: data, encoding: .utf8)!
    }

    static let googleScript = """
    (function () {
      if (!/(^|\\.)google\\./.test(location.hostname)) return;
      const labels = ['Sponsored', 'ממומן', 'Ad', 'Ads', 'מודעה', 'מודעות'];
      function clean() {
        document.querySelectorAll('span, div[role="heading"], h2, h3').forEach(el => {
          const t = (el.textContent || '').trim();
          if (t.length < 25 && labels.includes(t)) {
            const box = el.closest('#tads, #tadsb, #bottomads, [data-text-ad], .uEierd, .cu-container, [data-hveid]');
            if (box) box.remove();
          }
        });
      }
      clean();
      new MutationObserver(clean).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """


    // שולף מתוצאות החיפוש רק שירים (1–10 דקות), בלי שורטס/לייב/ערוצים/פלייליסטים
    static let searchExtractScript = """
    (function () {
      function txt(o) {
        if (!o) return '';
        if (typeof o === 'string') return o;
        if (o.simpleText) return o.simpleText;
        if (o.runs) return o.runs.map(r => r.text).join('');
        if (o.content) return o.content;
        return '';
      }
      function secs(s) {
        if (!s) return 0;
        const p = s.trim().split(':').map(Number);
        if (p.some(isNaN)) return 0;
        return p.reduce((a, b) => a * 60 + b, 0);
      }
      let data = window.ytInitialData;
      if (typeof data === 'string') { try { data = JSON.parse(data); } catch (e) { data = null; } }
      const out = [], seen = {};
      function add(id, title, artist, length) {
        if (!id || seen[id] || !title) return;
        const s = secs(length);
        if (s < 60 || s > 600) return;
        seen[id] = 1;
        out.push({ id: id, title: title, artist: artist || '', length: length || '' });
      }
      function walk(o, depth) {
        if (!o || typeof o !== 'object' || depth > 40 || out.length >= 40) return;
        const r = o.videoWithContextRenderer || o.videoRenderer || o.compactVideoRenderer;
        if (r && r.videoId) {
          const length = txt(r.lengthText) ||
            (r.thumbnailOverlays || []).map(x => txt(x.thumbnailOverlayTimeStatusRenderer && x.thumbnailOverlayTimeStatusRenderer.text)).find(Boolean) || '';
          add(r.videoId, txt(r.headline) || txt(r.title), txt(r.shortBylineText) || txt(r.longBylineText) || txt(r.ownerText), length);
          return;
        }
        for (const k in o) walk(o[k], depth + 1);
      }
      if (data) walk(data, 0);
      if (!out.length) {
        document.querySelectorAll('ytm-video-with-context-renderer, ytm-compact-video-renderer').forEach(el => {
          const a = el.querySelector('a[href*="/watch?v="]');
          if (!a) return;
          const m = a.getAttribute('href').match(/v=([^&]+)/);
          const title = (el.querySelector('h3, .media-item-headline') || {}).textContent || '';
          const by = (el.querySelector('.media-item-byline, .subhead') || {}).textContent || '';
          const len = (el.querySelector('.badge-shape-wiz__text, ytm-thumbnail-overlay-time-status-renderer, .time-status') || {}).textContent || '';
          if (m) add(m[1], title.trim(), by.trim().split('·')[0].trim(), len.trim());
        });
      }
      return JSON.stringify(out);
    })();
    """

    // הנגן: מציג רק את הווידאו, מדלג על מודעות, ושולח לאפליקציה זמן/שם שיר/אמן
    static let playerScript = """
    (function () {
      if (!/youtube\\.com$/.test(location.hostname)) return;
      // מסך הנעילה: שיר קודם/הבא במקום ±10 שניות, ושם נקי של השיר
      try {
        const ms = navigator.mediaSession;
        if (ms) {
          const proto = Object.getPrototypeOf(ms);
          const desc = Object.getOwnPropertyDescriptor(proto, 'metadata');
          const origSet = ms.setActionHandler.bind(ms);
          const post = a => { try { window.webkit.messageHandlers.player.postMessage({ remote: a }); } catch (e) {} };
          window.__ytMeta = null;
          window.__ourMeta = null;
          if (desc && desc.set) {
            Object.defineProperty(ms, 'metadata', {
              configurable: true,
              get() { return window.__ytMeta; },
              set(v) { window.__ytMeta = v; desc.set.call(ms, window.__ourMeta || v); }
            });
          }
          // השהיה מהמסך הנעול / אוזניות: מסמנים שהמשתמש עצר, כדי שהנגן לא ימשיך מעצמו
          const mine = {
            nexttrack: () => post('next'),
            previoustrack: () => post('prev'),
            pause: () => { window.__userPaused = true; const v = document.querySelector('video'); if (v) v.pause(); post('pause'); },
            play: () => { window.__userPaused = false; const v = document.querySelector('video');
                          if (v) { const p = v.play(); if (p && p.catch) p.catch(() => {}); } post('play'); }
          };
          ms.setActionHandler = function (action, handler) {
            if (mine[action]) return origSet(action, mine[action]);
            if (action === 'seekbackward' || action === 'seekforward') return origSet(action, null);
            return origSet(action, handler);
          };
          origSet('nexttrack', mine.nexttrack);
          origSet('previoustrack', mine.previoustrack);
          try { origSet('pause', mine.pause); origSet('play', mine.play); } catch (e) {}
          try { origSet('seekbackward', null); origSet('seekforward', null); } catch (e) {}
          window.__setMeta = function (t, a, art) {
            try {
              window.__ourMeta = new MediaMetadata({ title: t, artist: a,
                artwork: art ? [{ src: art, sizes: '480x360', type: 'image/jpeg' }] : [] });
              if (desc && desc.set) desc.set.call(ms, window.__ourMeta);
            } catch (e) {}
          };
        }
      } catch (e) {}
      try {
        Object.defineProperty(document, 'hidden', { get: () => false, configurable: true });
        Object.defineProperty(document, 'webkitHidden', { get: () => false, configurable: true });
        Object.defineProperty(document, 'visibilityState', { get: () => 'visible', configurable: true });
        Object.defineProperty(document, 'webkitVisibilityState', { get: () => 'visible', configurable: true });
        ['visibilitychange', 'webkitvisibilitychange'].forEach(n =>
          document.addEventListener(n, e => e.stopImmediatePropagation(), true));
        ['blur', 'pagehide'].forEach(n => window.addEventListener(n, e => e.stopImmediatePropagation(), true));
      } catch (e) {}
      const css = `
        html, body { background:#000 !important; overflow:hidden !important; }
        body * { visibility:hidden !important; }
        #player-container-id, #player-container-id *, .player-container, .player-container *,
        #movie_player, #movie_player * { visibility:visible !important; }
        #player-container-id, .player-container { position:fixed !important; inset:0 !important;
          width:100vw !important; height:100vh !important; margin:0 !important; padding:0 !important;
          z-index:2147483647 !important; }
        #player, #movie_player, .html5-video-player, .html5-video-container, video {
          width:100vw !important; height:100vh !important; left:0 !important; top:0 !important; }
        video { object-fit:cover !important; }
        .ytp-chrome-top, .ytp-chrome-bottom, #player-control-overlay, .player-controls-background,
        .ytp-pause-overlay, .ytp-ce-element, .ytp-paid-content-overlay, .ytp-ad-overlay-container,
        .ytp-unmute, .ytmUnmuteButton, ytm-unmute-button, [class*="unmute"]
          { display:none !important; }
        .ytp-caption-window-container, .caption-window, .captions-text { opacity:0 !important; }
        .ytp-pip-button, .ytp-pip-placeholder { display:none !important; }
        ytd-enforcement-message-view-model, ytm-enforcement-message-view-model,
        tp-yt-paper-dialog:has(ytd-enforcement-message-view-model), .ytp-ad-blocker-dialog,
        ytm-popup-container:has([class*="enforcement"]), tp-yt-iron-overlay-backdrop
          { display:none !important; }`;
      function ensureStyle() {
        if (!document.getElementById('__music_style')) {
          const st = document.createElement('style');
          st.id = '__music_style';
          st.textContent = css;
          (document.head || document.documentElement).appendChild(st);
        }
      }
      window.__standby = /[?&]standby=1/.test(location.search);
      if (/[?&]warm=1/.test(location.search)) window.__keepWarm = true;
      window.__restore = /[?&]restore=1/.test(location.search);
      if (window.__restore) window.__userPaused = true;
      if (window.__appActive === undefined) window.__appActive = true;
      const postMsg = o => { try { window.webkit.messageHandlers.player.postMessage(o); } catch (e) {} };
      const isPiP = v => v && v.webkitPresentationMode === 'picture-in-picture';
      // מצב "שמע בלבד" לשיר שנטען כשהאייפון נעול: iOS לא חוסם התחלה של שמע ברקע, רק של וידאו.
      // הנגן של יוטיוב ממשיך לעבוד כרגיל — רק שחלק התמונה של הסרטון לא נכנס לנגן בכלל.
      if (/[?&]audio=1/.test(location.search)) {
        const fullRange = end => ({ length: 1, start: () => 0, end: () => end });
        const hook = MS => {
          if (!MS || !MS.prototype || MS.prototype.__audioHooked) return;
          const orig = MS.prototype.addSourceBuffer;
          MS.prototype.__audioHooked = true;
          MS.prototype.addSourceBuffer = function (mime) {
            if (!/^video\\//i.test(String(mime || ''))) return orig.call(this, mime);
            const ms = this;
            const fake = new EventTarget();
            Object.assign(fake, { mode: 'segments', updating: false, timestampOffset: 0,
              appendWindowStart: 0, appendWindowEnd: Infinity,
              onupdatestart: null, onupdate: null, onupdateend: null, onerror: null, onabort: null });
            Object.defineProperty(fake, 'buffered', {
              get: () => fullRange(isFinite(ms.duration) && ms.duration > 0 ? ms.duration : 1e9) });
            const finish = () => {
              fake.updating = true;
              setTimeout(() => {
                ['updatestart', 'update', 'updateend'].forEach(n => {
                  if (n === 'updateend') fake.updating = false;
                  const ev = new Event(n);
                  fake.dispatchEvent(ev);
                  const h = fake['on' + n];
                  if (typeof h === 'function') h.call(fake, ev);
                });
              }, 0);
            };
            fake.appendBuffer = () => finish();
            fake.remove = () => finish();
            fake.abort = () => {};
            fake.changeType = () => {};
            if (!window.__audioOnly) { window.__audioOnly = true; postMsg({ audioOnly: true }); }
            return fake;
          };
        };
        hook(window.MediaSource); hook(window.ManagedMediaSource); hook(window.WebKitMediaSource);
      }
      // השיר הבא (בהכנה) או שיר ששוחזר — שקט מהרגע הראשון, בלי "הצצה" של קול
      ['loadstart', 'loadedmetadata', 'play', 'playing', 'volumechange'].forEach(n =>
        document.addEventListener(n, e => {
          const v = e.target;
          if (!v || v.tagName !== 'VIDEO') return;
          if ((window.__standby || window.__restore) && !v.muted) v.muted = true;
          if (window.__restore && n === 'play') v.pause();
          // נגן מהחלון הצף = המשתמש רוצה לנגן
          if (n === 'play' && isPiP(v) && !window.__standby) { window.__userPaused = false; postMsg({ remote: 'play' }); }
        }, true));
      // סגירת החלון הצף כשהאפליקציה ברקע = המשתמש עצר
      document.addEventListener('webkitpresentationmodechanged', e => {
        const v = e.target;
        if (!v || v.tagName !== 'VIDEO') return;
        if (!window.__standby) postMsg({ pip: v.webkitPresentationMode === 'picture-in-picture' });
        if (window.__appActive) return;
        // "חזרה לאפליקציה" ממשיכה לנגן; סגירה ב-X עוצרת — מסמנים עצירה רק אם הווידאו באמת נעצר
        if (v.webkitPresentationMode === 'inline' && v.paused) {
          window.__userPaused = true;
          postMsg({ remote: 'pause' });
        }
      }, true);
      let capsFor = '';
      function captions() {
        // מפעיל כתוביות (עברית אם יש) ומחזיר כמה מסלולים קיימים
        try {
          const mp = document.getElementById('movie_player');
          if (!mp || !mp.getOption) return -1;
          const vid = (mp.getVideoData && mp.getVideoData().video_id) || '';
          if (mp.loadModule) mp.loadModule('captions');
          const list = mp.getOption('captions', 'tracklist') || [];
          if (list.length && capsFor !== vid) {
            const pick = list.find(t => /^(he|iw)/.test(t.languageCode || '')) ||
                         list.find(t => t.kind !== 'asr') || list[0];
            mp.setOption('captions', 'track', pick);
            capsFor = vid;
          }
          return list.length;
        } catch (e) { return -1; }
      }
      let adMuted = false;
      setInterval(() => {
        ensureStyle();
        document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, button[class*="skip-ad"]')
          .forEach(b => b.click());
        const v = document.querySelector('video');
        const ad = !!document.querySelector('.ad-showing, .ad-interrupting');
        if (v && ad) {
          v.muted = true; adMuted = true;
          if (isFinite(v.duration) && v.duration > 0) v.currentTime = v.duration;
        } else if (v && window.__restore) {
          v.muted = true;
          if (!v.paused) v.pause();
        } else if (v && window.__standby) {
          v.muted = true;
          if (window.__keepWarm) {
            // האייפון ברקע: השיר הבא ממשיך לנגן בשקט (iOS לא מרשה להתחיל שיר מחדש ברקע, רק להמשיך)
            if (v.paused) { const pr = v.play(); if (pr && pr.catch) pr.catch(() => {}); }
            if (isFinite(v.duration) && v.duration > 0 && v.currentTime > v.duration - 8) v.currentTime = 0;
          } else {
            const b = v.buffered.length ? v.buffered.end(v.buffered.length - 1) : 0;
            if (b < 4) { if (v.paused) { const pr = v.play(); if (pr && pr.catch) pr.catch(() => {}); } }
            else { if (!v.paused) v.pause(); if (v.currentTime > 0.3) v.currentTime = 0; }
          }
        } else if (v && (adMuted || v.muted)) {
          adMuted = false;
          v.muted = false; v.volume = 1;
          try { const mp = document.getElementById('movie_player'); if (mp && mp.unMute) mp.unMute(); } catch (e) {}
        }
        const m = navigator.mediaSession && navigator.mediaSession.metadata;
        let la = -1, lyr = '';
        if (window.__wantLyrics && !window.__standby) {
          la = captions();
          let segs = document.querySelectorAll('.ytp-caption-segment');
          if (!segs.length) segs = document.querySelectorAll('.caption-visual-line');
          if (!segs.length) segs = document.querySelectorAll('.captions-text');
          lyr = Array.from(segs).map(e => e.textContent).join(' ').replace(/\\s+/g, ' ').trim();
        }
        try {
          window.webkit.messageHandlers.player.postMessage({
            t: v ? v.currentTime : 0,
            d: v && isFinite(v.duration) ? v.duration : 0,
            p: v ? v.paused : true,
            ad: ad,
            e: v ? v.ended : false,
            err: !!document.querySelector('.ytp-error, ytm-player-error-message-renderer, .player-error, .ytp-error-content'),
            buf: v && v.buffered.length ? v.buffered.end(v.buffered.length - 1) : 0,
            title: m ? (m.title || '') : '',
            artist: m ? (m.artist || '') : '',
            wl: !!window.__wantLyrics,
            la: la,
            lyr: lyr
          });
        } catch (e) {}
      }, 500);
      // כשיוצאים מהאפליקציה האייפון עוצר את הווידאו — ממשיכים מיד, אלא אם עצרת בעצמך
      document.addEventListener('pause', e => {
        const v = e.target;
        if (!v || v.tagName !== 'VIDEO' || v.ended || window.__standby) return;
        // השהיה מתוך החלון הצף — זה המשתמש, לא האייפון
        if (isPiP(v)) { window.__userPaused = true; postMsg({ remote: 'pause' }); return; }
        const resume = () => {
          if (window.__userPaused || window.__standby || v.ended || !v.paused) return;
          if (document.querySelector('.ad-showing, .ad-interrupting')) return;
          try { const p = v.play(); if (p && p.catch) p.catch(() => {}); } catch (err) {}
        };
        setTimeout(resume, 150);
        setTimeout(resume, 600);
      }, true);
      document.addEventListener('ended', e => {
        if (e.target && e.target.tagName === 'VIDEO' && !document.querySelector('.ad-showing')) {
          try { window.webkit.messageHandlers.player.postMessage({ ended: true }); } catch (e) {}
        }
      }, true);
    })();
    """
}


// MARK: - Siri (פקודות קוליות)

enum SiriHelp {
    static let phrases = [
        "נגן שיר במוזיקה שלי",
        "נגן את השירים שאהבתי במוזיקה שלי",
        "ערבב את השירים שאהבתי במוזיקה שלי",
        "נגן את הפלייליסט [שם] במוזיקה שלי",
        "מה מתנגן במוזיקה שלי",
        "אהבתי את השיר במוזיקה שלי",
        "עוד כמו זה במוזיקה שלי",
        "טיימר שינה במוזיקה שלי",
        "המשך לנגן במוזיקה שלי",
        "השיר הבא / השהה / המשך (בלי שם האפליקציה)"
    ]
}

struct PlaylistEntity: AppEntity {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "פלייליסט"
    static var defaultQuery = PlaylistQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ p: Playlist) {
        id = p.id
        name = p.name
    }
}

struct PlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        await MainActor.run {
            AppState.shared.library.playlists.filter { identifiers.contains($0.id) }.map { PlaylistEntity($0) }
        }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        await MainActor.run {
            AppState.shared.library.playlists
                .filter { $0.name.localizedCaseInsensitiveContains(string) || string.localizedCaseInsensitiveContains($0.name) }
                .map { PlaylistEntity($0) }
        }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        await MainActor.run { AppState.shared.library.playlists.map { PlaylistEntity($0) } }
    }
}

struct PlaySongIntent: AppIntent {
    static var title: LocalizedStringResource = "נגן שיר"
    static var description = IntentDescription("מחפש שיר או אמן ומנגן אותו")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "שיר או אמן", requestValueDialog: "איזה שיר לנגן?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppState.shared.tab = .home
        guard let s = await AppState.shared.searchAndPlay(query) else {
            return .result(dialog: "לא מצאתי שירים של \(query)")
        }
        return .result(dialog: "מנגן את \(s.displayTitle)")
    }
}

struct PlayLikedIntent: AppIntent {
    static var title: LocalizedStringResource = "נגן את השירים שאהבתי"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "ערבוב", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppState.shared
        let liked = app.library.liked
        guard !liked.isEmpty else { return .result(dialog: "עוד אין שירים שאהבת") }
        if shuffle { app.playShuffled(liked) } else {
            app.player.setShuffle(false)
            app.play(liked[0], in: liked)
        }
        return .result(dialog: shuffle ? "מערבב את השירים שאהבת" : "מנגן את השירים שאהבת")
    }
}

struct ShuffleLikedIntent: AppIntent {
    static var title: LocalizedStringResource = "ערבב את השירים שאהבתי"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppState.shared
        guard !app.library.liked.isEmpty else { return .result(dialog: "עוד אין שירים שאהבת") }
        app.playShuffled(app.library.liked)
        return .result(dialog: "מערבב את השירים שאהבת")
    }
}

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "נגן פלייליסט"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "פלייליסט", requestValueDialog: "איזה פלייליסט?")
    var playlist: PlaylistEntity

    @Parameter(title: "ערבוב", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppState.shared
        guard let pl = app.library.playlist(playlist.id), !pl.songs.isEmpty else {
            return .result(dialog: "הפלייליסט \(playlist.name) ריק")
        }
        if shuffle { app.playShuffled(pl.songs) } else {
            app.player.setShuffle(false)
            app.play(pl.songs[0], in: pl.songs)
        }
        return .result(dialog: "מנגן את \(pl.name)")
    }
}

struct WhatsPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "מה מתנגן"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = AppState.shared.player
        guard let s = player.current, !s.title.isEmpty, player.isPlaying || player.wantsPlay else {
            return .result(dialog: "כרגע לא מתנגן שום שיר")
        }
        let artist = s.displayArtist
        return .result(dialog: artist.isEmpty ? "\(s.displayTitle)" : "\(s.displayTitle) של \(artist)")
    }
}

struct LikeCurrentIntent: AppIntent {
    static var title: LocalizedStringResource = "אהבתי את השיר"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppState.shared
        guard let s = app.player.current, !s.title.isEmpty else {
            return .result(dialog: "כרגע לא מתנגן שום שיר")
        }
        if app.library.isLiked(s.id) { return .result(dialog: "\(s.displayTitle) כבר בשירים שאהבת") }
        app.library.toggleLike(s)
        return .result(dialog: "הוספתי את \(s.displayTitle) לשירים שאהבת")
    }
}

struct MoreLikeThisIntent: AppIntent {
    static var title: LocalizedStringResource = "עוד כמו זה"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppState.shared
        guard let s = app.player.current, !s.title.isEmpty else {
            return .result(dialog: "כרגע לא מתנגן שום שיר")
        }
        app.moreLikeThis(s)
        return .result(dialog: "מוסיף שירים דומים לתור")
    }
}

struct SleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "טיימר שינה"

    @Parameter(title: "דקות", requestValueDialog: "לכמה דקות?")
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = max(1, min(minutes, 240))
        AppState.shared.player.setSleep(minutes: m)
        return .result(dialog: "המוזיקה תיעצר בעוד \(m) דקות")
    }
}

struct ResumeIntent: AppIntent {
    static var title: LocalizedStringResource = "המשך לנגן"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppState.shared
        if app.player.current != nil {
            app.player.setPlaying(true)
            return .result(dialog: "ממשיך לנגן")
        }
        if let first = app.library.recent.first {
            app.play(first, in: app.library.recent)
            return .result(dialog: "מנגן את \(first.displayTitle)")
        }
        return .result(dialog: "אין עדיין מה להמשיך. נסה \"נגן שיר\"")
    }
}

struct MusicShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .pink

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlaySongIntent(), phrases: [
            "נגן שיר ב\(.applicationName)",
            "חפש שיר ב\(.applicationName)",
            "\(.applicationName) נגן שיר"
        ], shortTitle: "נגן שיר", systemImageName: "music.magnifyingglass")
        AppShortcut(intent: PlayLikedIntent(), phrases: [
            "נגן את השירים שאהבתי ב\(.applicationName)",
            "נגן אהובים ב\(.applicationName)",
            "\(.applicationName) השירים שאהבתי"
        ], shortTitle: "שירים שאהבתי", systemImageName: "heart.fill")
        AppShortcut(intent: ShuffleLikedIntent(), phrases: [
            "ערבב את השירים שאהבתי ב\(.applicationName)",
            "\(.applicationName) ערבב"
        ], shortTitle: "ערבוב", systemImageName: "shuffle")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: [
            "נגן את \(\.$playlist) ב\(.applicationName)",
            "נגן את הפלייליסט \(\.$playlist) ב\(.applicationName)",
            "נגן פלייליסט ב\(.applicationName)"
        ], shortTitle: "פלייליסט", systemImageName: "music.note.list")
        AppShortcut(intent: WhatsPlayingIntent(), phrases: [
            "מה מתנגן ב\(.applicationName)",
            "איזה שיר זה ב\(.applicationName)"
        ], shortTitle: "מה מתנגן", systemImageName: "waveform")
        AppShortcut(intent: LikeCurrentIntent(), phrases: [
            "אהבתי את השיר ב\(.applicationName)",
            "שמור את השיר ב\(.applicationName)"
        ], shortTitle: "אהבתי", systemImageName: "heart")
        AppShortcut(intent: MoreLikeThisIntent(), phrases: [
            "עוד כמו זה ב\(.applicationName)",
            "שירים דומים ב\(.applicationName)"
        ], shortTitle: "עוד כמו זה", systemImageName: "sparkles")
        AppShortcut(intent: SleepTimerIntent(), phrases: [
            "טיימר שינה ב\(.applicationName)",
            "\(.applicationName) טיימר שינה"
        ], shortTitle: "טיימר שינה", systemImageName: "moon")
        AppShortcut(intent: ResumeIntent(), phrases: [
            "המשך לנגן ב\(.applicationName)",
            "\(.applicationName) המשך"
        ], shortTitle: "המשך", systemImageName: "play.fill")
    }
}
