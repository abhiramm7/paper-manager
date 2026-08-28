import Foundation
import Combine
import AppKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published var papers: [Paper] = []
    @Published var prefs: PrefsMap = [:]
    /// Library root + derived paths. Reassigning this (Settings → Apply,
    /// first-run onboarding) re-points the tag vocabulary at the new library —
    /// without that, tags.json keeps being written into whichever folder the
    /// app happened to launch with.
    @Published var config: AppConfig {
        didSet {
            guard oldValue.iCloudRoot != config.iCloudRoot else { return }
            tagStore = TagStore(libraryRoot: config.iCloudRoot)
        }
    }
    @Published var isScanning = false
    /// Last library-level failure (unreadable library dir, failed metadata
    /// write). Surfaced as a dismissable banner in ContentView; cleared by a
    /// successful rescan.
    @Published var lastScanError: String?

    /// Paper IDs currently mid-LLM-tagging. Views can use this for spinners.
    @Published var taggingInFlight: Set<String> = []
    /// Last detected LLM provider. Refreshed by `refreshLLMProvider()`.
    @Published var llmProvider: LLMTagger.Provider = .unavailable
    /// Hint shown in Settings when no provider resolves (or one is forced).
    @Published var llmDiagnostic: String?
    @Published var lastTaggerError: String?

    /// User preference for which provider to use. Persisted to UserDefaults.
    @Published var llmPreference: LLMTagger.Preference = LLMTagger.Preference(
        rawValue: UserDefaults.standard.string(forKey: "Sift.llmPreference") ?? "auto"
    ) ?? .auto {
        didSet {
            UserDefaults.standard.set(llmPreference.rawValue, forKey: "Sift.llmPreference")
            Task { await refreshLLMProvider() }
        }
    }

    /// User-selected Claude model alias ("default", "haiku", "sonnet", "opus", or a full model id).
    @Published var claudeModel: String = UserDefaults.standard.string(forKey: "Sift.claudeModel") ?? "default" {
        didSet {
            UserDefaults.standard.set(claudeModel, forKey: "Sift.claudeModel")
            Task { await refreshLLMProvider() }
        }
    }

    /// User-pinned Ollama model name. Empty = auto-pick.
    @Published var ollamaModel: String = UserDefaults.standard.string(forKey: "Sift.ollamaModel") ?? "" {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: "Sift.ollamaModel")
            Task { await refreshLLMProvider() }
        }
    }

    /// Locally-installed Ollama chat models. Refreshed on demand for the Settings picker.
    @Published var availableOllamaModels: [String] = []

    /// Library tag vocabulary — steers LLM tag generation toward existing tags.
    @Published var tagStore: TagStore

    // MARK: - Watched folders

    /// Folders Sift checks for importable PDFs. Absolute paths, persisted to
    /// UserDefaults (machine-local config, like the library root — these paths
    /// mean nothing on another Mac, so they don't belong in prefs.json).
    @Published var watchedFolders: [String] = UserDefaults.standard
        .stringArray(forKey: "Sift.watchedFolders") ?? [] {
        didSet {
            UserDefaults.standard.set(watchedFolders, forKey: "Sift.watchedFolders")
        }
    }

    /// Result of the last watched-folder scan.
    @Published var foundPDFs: [FoundPDF] = []
    @Published var isScanningFolders = false

    /// Remembered SHA-256s for watched-folder files, keyed by path and guarded
    /// by (size, mtime). Hashing is the whole cost of a scan, and scans run on
    /// every launch — without this, pointing Sift at a folder of GBs of PDFs
    /// re-reads all of them every time. Persisted because the launch scan is
    /// exactly the one worth making cheap. Machine-local (absolute paths), so
    /// it lives in Application Support, not in the synced library.
    private var scanCache: ScanCache = LibraryStore.loadScanCache()

    /// `~/Library/Application Support/Sift/scan-cache.json`.
    private static var scanCacheURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base
            .appendingPathComponent("Sift", isDirectory: true)
            .appendingPathComponent("scan-cache.json")
    }

    private static func loadScanCache() -> ScanCache {
        guard let url = scanCacheURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ScanCache.self, from: data) else { return [:] }
        return decoded
    }

    /// Write the cache off the main actor — it can hold thousands of entries
    /// and nothing waits on the result.
    private static func saveScanCache(_ cache: ScanCache) {
        guard let url = scanCacheURL else { return }
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// LLM verdicts on found PDFs, keyed by content sha256 — survives folder
    /// re-scans (paths and mtimes change; content identity doesn't). Session-
    /// scoped: not persisted, a fresh launch re-assesses on demand.
    @Published var importAssessments: [String: LLMTagger.ImportAssessment] = [:]
    /// Assessment progress. nil when idle.
    @Published var assessProgress: (done: Int, total: Int)? = nil
    private var assessTask: Task<Void, Never>?

    /// PDFs found that aren't in the library yet — drives the sidebar badge.
    var newFoundPDFCount: Int {
        foundPDFs.filter { !$0.isInLibrary }.count
    }

    /// Clusters of likely-duplicate papers already in the library (same work,
    /// different files — so ingest's byte-hash dedupe missed them). Recomputed
    /// after every rescan.
    @Published var duplicateGroups: [[Paper]] = []

    /// Number of redundant copies across all clusters (total papers minus one
    /// keeper per cluster) — the count worth surfacing to the user.
    var duplicateExtraCount: Int {
        duplicateGroups.reduce(0) { $0 + max($1.count - 1, 0) }
    }

    // MARK: - Cached aggregates
    //
    // These used to be computed properties. The sidebar reads each of them
    // several times per render and the toolbar read `untaggedCount` (which
    // hit the disk once per paper), so every published change re-walked the
    // whole library. They're recomputed once, in `recomputeAggregates()`,
    // whenever `papers` changes.

    /// Paper IDs with a non-empty summary.md on disk. Refreshed by `rescan()`
    /// and kept in sync by the tagger, so `paperNeedsTagging` never touches
    /// the filesystem.
    @Published private(set) var papersWithSummary: Set<String> = []
    /// How many papers still need LLM work — drives the AI menu's label.
    @Published private(set) var untaggedCount: Int = 0
    /// All unique tags across the library (user_tags ∪ auto.tags).
    @Published private(set) var allTags: [(tag: String, count: Int)] = []
    /// All unique folders across the library, with paper counts. Uses each
    /// paper's `effectiveFolder` (user override if set, else the LLM's
    /// auto-assigned folder). Case-folded for uniqueness; the displayed name
    /// is the most common spelling among papers that share that key.
    @Published private(set) var allFolders: [(folder: String, count: Int)] = []
    /// All authors across the library with paper counts. Every author across
    /// every position counts — so a paper by ["Abhiram", "Branko"] contributes
    /// one to each name. Case-folded dedup; the displayed spelling is the
    /// most common one for that case-folded key. "et al." junk is stripped
    /// here too, so libraries with dirty data still see clean sidebars before
    /// the consolidate pass runs.
    @Published private(set) var allAuthors: [(author: String, count: Int)] = []

    init(config: AppConfig = AppConfig.load()) {
        self.config = config
        self.tagStore = TagStore(libraryRoot: config.iCloudRoot)
    }

    func rescan() async {
        isScanning = true
        defer { isScanning = false }

        let cfg = self.config
        let result = await Task.detached(priority: .userInitiated) { () -> (papers: [Paper], prefs: PrefsMap, summaries: Set<String>, error: String?) in
            var papers: [Paper] = []
            var prefs: PrefsMap = [:]
            var summaries: Set<String> = []
            var firstError: String?

            let fm = FileManager.default
            // Papers
            if let entries = try? fm.contentsOfDirectory(at: cfg.libraryDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                for url in entries {
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: url.path, isDirectory: &isDir)
                    guard isDir.boolValue else { continue }
                    let meta = url.appendingPathComponent("metadata.json")
                    guard fm.fileExists(atPath: meta.path) else { continue }
                    do {
                        let data = try Data(contentsOf: meta)
                        let p = try JSONDecoder().decode(Paper.self, from: data)
                        papers.append(p)
                        // Note which papers already have a summary while we're
                        // walking the directory anyway — that keeps
                        // `paperNeedsTagging` (called from view bodies) off
                        // the filesystem entirely.
                        let summary = url.appendingPathComponent("summary.md")
                        if let vals = try? summary.resourceValues(forKeys: [.fileSizeKey]),
                           (vals.fileSize ?? 0) > 0 {
                            summaries.insert(p.id)
                        }
                    } catch {
                        if firstError == nil {
                            firstError = "Failed to decode \(meta.lastPathComponent) in \(url.lastPathComponent): \(error.localizedDescription)"
                        }
                    }
                }
            } else {
                firstError = "Library directory not readable: \(cfg.libraryDir.path)"
            }

            // Prefs
            if let data = try? Data(contentsOf: cfg.prefsFile),
               let map = try? JSONDecoder().decode(PrefsMap.self, from: data) {
                prefs = map
            }

            return (papers, prefs, summaries, firstError)
        }.value

        self.papers = result.papers.sorted { lhs, rhs in
            (lhs.addedDate ?? .distantPast) > (rhs.addedDate ?? .distantPast)
        }
        self.prefs = result.prefs
        self.papersWithSummary = result.summaries
        self.lastScanError = result.error
        // Refresh tag vocabulary from current paper set.
        self.tagStore.rebuildFromPapers(self.papers)
        // Recompute duplicate clusters against the fresh paper set.
        self.duplicateGroups = DuplicateFinder.findDuplicates(in: self.papers)
        recomputeAggregates()
    }

    /// Rebuild every cached aggregate from `papers`. Called whenever the paper
    /// set or a paper's metadata changes — one pass instead of the handful of
    /// full-library walks the computed-property versions cost per render.
    private func recomputeAggregates() {
        var tagCounts: [String: Int] = [:]
        var folderCounts: [String: Int] = [:]
        var folderDisplays: [String: [String: Int]] = [:]
        var authorCounts: [String: Int] = [:]
        var authorDisplays: [String: [String: Int]] = [:]
        var untagged = 0

        for p in papers {
            for t in p.allTags {
                tagCounts[t, default: 0] += 1
            }
            if let f = p.effectiveFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
               !f.isEmpty {
                let key = f.lowercased()
                folderCounts[key, default: 0] += 1
                folderDisplays[key, default: [:]][f, default: 0] += 1
            }
            for a in p.authors {
                guard let cleaned = LLMTagger.cleanAuthorName(a) else { continue }
                let key = cleaned.lowercased()
                authorCounts[key, default: 0] += 1
                authorDisplays[key, default: [:]][cleaned, default: 0] += 1
            }
            if paperNeedsTagging(p) { untagged += 1 }
        }

        allTags = tagCounts
            .map { ($0.key, $0.value) }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.tag < $1.tag) }
        allFolders = folderCounts.map { (key, count) -> (folder: String, count: Int) in
            (folderDisplays[key]?.max(by: { $0.value < $1.value })?.key ?? key, count)
        }
        .sorted { $0.count > $1.count || ($0.count == $1.count && $0.folder < $1.folder) }
        allAuthors = authorCounts.map { (key, count) -> (author: String, count: Int) in
            (authorDisplays[key]?.max(by: { $0.value < $1.value })?.key ?? key, count)
        }
        .sorted { $0.count > $1.count || ($0.count == $1.count && $0.author < $1.author) }
        untaggedCount = untagged
    }

    func prefs(for id: String) -> PrefsEntry {
        prefs[id] ?? PrefsEntry()
    }

    /// Point the app at a different library root: create the standard layout,
    /// swap the config (which re-points the tag store), persist the choice,
    /// and rescan. The one path for changing libraries — Settings and
    /// first-run onboarding both go through here.
    func setLibraryRoot(_ url: URL) throws {
        let cfg = AppConfig(iCloudRoot: url)
        try cfg.ensureLayout()
        config = cfg
        cfg.save()
        Task { await rescan() }
    }

    // MARK: - Watched-folder scanning

    /// Scan every watched folder for PDFs and match them against the library
    /// by SHA-256. Runs on launch and on demand from the sidebar / review
    /// sheet. Heavy work (enumeration + hashing) happens off the main actor.
    func scanWatchedFolders() async {
        guard !isScanningFolders else { return }
        guard !watchedFolders.isEmpty else {
            foundPDFs = []
            return
        }
        isScanningFolders = true
        defer { isScanningFolders = false }

        let folders = watchedFolders.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        var known: [String: String] = [:]   // sha256 → paper id
        for p in papers where !p.sha256.isEmpty {
            known[p.sha256] = p.id
        }
        let exclude = config.iCloudRoot
        let cache = scanCache

        let result = await Task.detached(priority: .userInitiated) {
            FolderScanService.scan(folders: folders,
                                   excluding: exclude,
                                   knownHashes: known,
                                   cache: cache)
        }.value
        foundPDFs = result.found
        scanCache = result.cache
        Self.saveScanCache(result.cache)
    }

    func addWatchedFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !watchedFolders.contains(path) else { return }
        watchedFolders.append(path)
        Task { await scanWatchedFolders() }
    }

    func removeWatchedFolder(_ path: String) {
        watchedFolders.removeAll { $0 == path }
        Task { await scanWatchedFolders() }
    }

    /// Move a found duplicate to the macOS Trash (recoverable). Drops it from
    /// the scan results so the review sheet updates immediately.
    func trashFoundPDF(_ f: FoundPDF) {
        NSWorkspace.shared.recycle([f.url]) { _, _ in }
        foundPDFs.removeAll { $0.id == f.id }
    }

    /// Run the LLM over every un-assessed new PDF in the scan results and
    /// record an import/skip verdict for each. Advisory — nothing is imported
    /// or deleted here. Same concurrency budget as bulk tagging. Returns
    /// immediately; observe `assessProgress`, cancel with `cancelAssessment()`.
    func assessFoundPDFs() {
        guard assessTask == nil else { return }
        let targets = foundPDFs.filter {
            !$0.isInLibrary && importAssessments[$0.sha256] == nil
        }
        guard !targets.isEmpty else { return }
        assessProgress = (0, targets.count)
        let total = targets.count

        assessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.assessTask = nil
                self.assessProgress = nil
            }

            guard let provider = await self.availableProvider() else { return }
            // A few pages is plenty for import-or-skip; keep the prompt small
            // even on Claude so verdicts come back fast.
            let charCap = min(LLMTagger.maxCharsForProvider(provider), 16_000)

            await self.runBulk(targets) { (f: FoundPDF) -> (String, LLMTagger.ImportAssessment?) in
                let text = LLMTagger.extractText(
                    from: f.url, maxChars: charCap, maxPages: 5)
                let verdict = try? await LLMTagger.assessImport(
                    fileName: f.fileName, text: text, using: provider)
                return (f.sha256, verdict)
            } onEach: { result, done in
                if let verdict = result.1 {
                    self.importAssessments[result.0] = verdict
                }
                self.assessProgress = (done, total)
            }
        }
    }

    /// Cancel the running assessment (if any). Verdicts already recorded stay.
    func cancelAssessment() {
        assessTask?.cancel()
    }

    // MARK: - Reader tabs

    /// Paper ids open as reader tabs in the main window, in open order.
    @Published var openReaderTabs: [String] = []
    /// The active tab: a paper id, or nil for the Library tab.
    @Published var activeReaderTab: String? = nil

    func openReader(for id: String) {
        if !openReaderTabs.contains(id) {
            openReaderTabs.append(id)
        }
        activeReaderTab = id
        // Opening a paper to read is the clearest signal there is that you're
        // reading it — pin it without making the user say so twice. Marking it
        // read (or toggling it off by hand) unpins it.
        if !prefs(for: id).read {
            setReading(true, for: id)
        }
        seedChatIfNeeded(for: id)
    }

    /// Pre-load the paper's saved summary (summary.md, written at tagging
    /// time) as the opening chat message — the conversation starts with
    /// context the LLM already produced, instead of making it re-derive the
    /// gist question by question. The seed rides along in the chat history,
    /// so every follow-up call sees it too. No-op when a conversation
    /// already exists or the paper has no summary.
    private func seedChatIfNeeded(for id: String) {
        guard (paperChats[id] ?? []).isEmpty,
              let paper = papers.first(where: { $0.id == id }),
              let raw = loadSummary(paper) else { return }
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        // Chat bubbles render inline Markdown only — turn "## Heading" lines
        // into bold so they don't show as literal hash marks.
        let cleaned = summary.replacingOccurrences(
            of: #"(?m)^#{1,6}\s*(.+)$"#,
            with: "**$1**",
            options: .regularExpression)
        paperChats[id] = [.init(
            role: .assistant,
            text: "Here's the saved summary of this paper:\n\n\(cleaned)")]
    }

    func closeReader(_ id: String) {
        openReaderTabs.removeAll { $0 == id }
        if activeReaderTab == id {
            activeReaderTab = openReaderTabs.last
        }
        findQuery.removeValue(forKey: id)
        findStatus.removeValue(forKey: id)
    }

    // MARK: - Find in PDF

    /// How far along the current find is, for the toolbar's "3 of 17".
    /// `index` is 1-based; zero means nothing matched. `searching` covers the
    /// gap while PDFKit scans a long document — without it the toolbar would
    /// claim "Not found" for the seconds a first search over a book takes.
    struct FindStatus: Equatable {
        var count: Int = 0
        var index: Int = 0
        var searching: Bool = false
    }

    /// A single character matches half a paper and buries the reader in
    /// highlights, so a find only runs from two characters up.
    static let minFindLength = 2

    /// Find-in-PDF query per reader tab. The toolbar search field writes it
    /// (it searches the library on the Library tab and the PDF on a reader
    /// tab); the matching `ReaderView` watches its own entry and runs the
    /// search. Session state — deliberately not persisted.
    @Published var findQuery: [String: String] = [:]
    /// Match count + position, written back by the reader for the toolbar.
    @Published var findStatus: [String: FindStatus] = [:]

    /// The active tab's find query, trimmed — empty when on Library or when
    /// nothing has been typed.
    var activeFindQuery: String {
        guard let id = activeReaderTab else { return "" }
        return (findQuery[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reader Q&A

    /// Per-paper reader conversations. Session-scoped (not persisted) —
    /// cheap to regenerate, and answers can go stale if the PDF is re-tagged.
    /// Lives here rather than in the view so a conversation survives closing
    /// and reopening the reader window.
    @Published var paperChats: [String: [LLMTagger.ChatMessage]] = [:]
    /// Paper IDs with a reader answer currently in flight.
    @Published var chatInFlight: Set<String> = []

    /// Ask a question about a paper. Appends the question to the chat
    /// immediately; the answer (or an error message) follows asynchronously.
    func askPaper(_ question: String, paperId: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chatInFlight.contains(paperId) else { return }
        guard let paper = papers.first(where: { $0.id == paperId }) else { return }

        let history = paperChats[paperId] ?? []
        paperChats[paperId] = history + [.init(role: .user, text: q)]
        chatInFlight.insert(paperId)

        let pdfURL = config.pdfURL(paperId)
        let title = paper.title

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.chatInFlight.remove(paperId) }

            let provider = await self.resolveProvider()
            guard provider.isAvailable else {
                self.paperChats[paperId, default: []].append(.init(
                    role: .assistant,
                    text: LLMTagger.Provider.missingHint))
                return
            }
            // Whole paper on Claude (capped so per-question latency stays
            // sane); provider cap on Ollama.
            let charCap = min(LLMTagger.maxCharsForProvider(provider), 80_000)

            var answer: String
            do {
                answer = try await Task.detached(priority: .userInitiated) {
                    let text = LLMTagger.extractText(from: pdfURL, maxChars: charCap)
                    return try await LLMTagger.answerQuestion(
                        title: title,
                        documentText: text,
                        history: history,
                        question: q,
                        using: provider)
                }.value
            } catch {
                answer = "Couldn't get an answer: \(error.localizedDescription)"
            }
            self.paperChats[paperId, default: []].append(.init(role: .assistant, text: answer))
        }
    }

    func clearChat(paperId: String) {
        paperChats.removeValue(forKey: paperId)
    }

    // MARK: - Bulk attribution verification

    /// Progress of the library-wide attribution check. nil when idle.
    @Published var verifyProgress: (done: Int, total: Int)? = nil
    private var verifyTask: Task<Void, Never>?

    /// Transient status line surfaced by ContentView's bottom overlay.
    @Published var statusToast: String?

    func showToast(_ message: String) {
        statusToast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.statusToast == message { self?.statusToast = nil }
        }
    }

    /// Record an LLM-operation failure. Keeps it in `lastTaggerError` and puts
    /// it in front of the user — these used to be written and never read, so
    /// a failed tagging run looked identical to one that did nothing.
    func reportTaggerError(_ message: String) {
        lastTaggerError = message
        showToast(message)
    }

    /// Re-check title/author attribution for every paper using multiple
    /// passes of a cheap model (haiku on Claude; the local model on Ollama).
    /// Each paper's first pages are read 2–3 times; a title or author list is
    /// only rewritten when two independent passes agree AND the agreed value
    /// differs from what's stored. Observe `verifyProgress`; cancel with
    /// `cancelVerifyAttributions()`.
    func verifyAllAttributions() {
        guard verifyTask == nil else { return }
        let targets = papers
        guard !targets.isEmpty else { return }
        verifyProgress = (0, targets.count)
        let total = targets.count

        verifyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.verifyTask = nil
                self.verifyProgress = nil
            }

            guard let provider = await self.availableProvider() else { return }
            let cheap = LLMTagger.cheapVariant(of: provider)

            var checked = 0
            var changed = 0
            let cfg = self.config
            await self.runBulk(targets) { (p: Paper) -> (String, LLMTagger.TitleAuthorsProposal) in
                let sample = LLMTagger.extractText(
                    from: cfg.pdfURL(p.id), maxChars: 8_000, maxPages: 2)
                // Empty seed: consensus needs two fresh passes to agree
                // before anything is trusted.
                let verdict = await LLMTagger.consensusTitleAuthors(
                    text: sample,
                    seed: LLMTagger.TitleAuthorsProposal(title: nil, authors: nil),
                    maxExtraPasses: 3,
                    using: cheap)
                return (p.id, verdict)
            } onEach: { result, done in
                if self.applyVerifiedAttribution(result.1, to: result.0) {
                    changed += 1
                }
                checked = done
                self.verifyProgress = (done, total)
            }
            self.showToast("Checked \(checked) paper\(checked == 1 ? "" : "s") — corrected \(changed).")
        }
    }

    /// Cancel the running attribution check. Corrections already made stay.
    func cancelVerifyAttributions() {
        verifyTask?.cancel()
    }

    /// Write a consensus verdict to disk if it's plausible and actually
    /// different from what's stored. Returns true when something changed.
    private func applyVerifiedAttribution(
        _ v: LLMTagger.TitleAuthorsProposal, to id: String
    ) -> Bool {
        guard let p = papers.first(where: { $0.id == id }) else { return false }
        let newTitle: String? = {
            guard let t = v.title, LLMTagger.isPlausibleTitle(t) else { return nil }
            return LLMTagger.titleVoteKey(t) == LLMTagger.titleVoteKey(p.title) ? nil : t
        }()
        let newAuthors: [String]? = {
            guard let a = v.authors, LLMTagger.arePlausibleAuthors(a) else { return nil }
            return LLMTagger.authorsVoteKey(a) == LLMTagger.authorsVoteKey(p.authors) ? nil : a
        }()
        guard newTitle != nil || newAuthors != nil else { return false }
        updateMetadata(id: id) { obj in
            if let t = newTitle { obj["title"] = t }
            if let a = newAuthors { obj["authors"] = a }
        }
        return true
    }

    /// Folder names in their current canonical spelling, for the LLM prompt.
    /// Includes user-set folders so the LLM will reuse names the user has
    /// adopted, not just ones the LLM previously invented.
    var folderVocabulary: [String] {
        allFolders.map { $0.folder }
    }

    func openInPreview(_ paper: Paper) {
        let url = config.pdfURL(paper.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ paper: Paper) {
        let dir = config.paperDir(paper.id)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    func loadSummary(_ paper: Paper) -> String? {
        let url = config.summaryURL(paper.id)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Mutations (write back to prefs.json)

    /// Read-modify-write one paper's prefs entry: stamps `updated_at` and
    /// flushes prefs.json. Every prefs mutation goes through here, the way
    /// every metadata.json edit goes through `updateMetadata`.
    private func updatePrefs(for id: String, mutate: (inout PrefsEntry) -> Void) {
        var e = prefs[id] ?? PrefsEntry()
        mutate(&e)
        e.updated_at = ISO8601.now()
        prefs[id] = e
        writePrefs()
    }

    /// rating: -1 (down), 1..5 (stars), or nil to clear. Matches Python prefs.set_rating.
    func setRating(_ rating: Int?, for id: String) {
        updatePrefs(for: id) { $0.rating = rating }
    }

    func setRead(_ read: Bool, for id: String) {
        updatePrefs(for: id) {
            $0.read = read
            // Finishing a paper takes it off the "Currently reading" shelf.
            if read { $0.reading = false }
        }
    }

    /// Pin/unpin the paper in the "Currently reading" section at the top of
    /// the list. Marking it reading also clears `read` — the two states are
    /// mutually exclusive by definition.
    func setReading(_ reading: Bool, for id: String) {
        updatePrefs(for: id) {
            $0.reading = reading
            if reading { $0.read = false }
        }
    }

    func setStarred(_ saved: Bool, for id: String) {
        updatePrefs(for: id) { $0.saved = saved }
    }

    /// Move the paper's library/<id>/ folder to the Trash and drop it from
    /// in-memory state. Reversible — user can drag it back out of Trash.
    func deletePaper(_ id: String) {
        let dir = config.paperDir(id)
        NSWorkspace.shared.recycle([dir]) { _, _ in }
        papers.removeAll { $0.id == id }
        papersWithSummary.remove(id)
        closeReader(id)   // a reader tab on a trashed paper would dangle
        // Always rewrite prefs.json — a prior session may have written an entry
        // even if this session never loaded it. Without this, deleted papers
        // leave ghost prefs entries on disk that accumulate over time.
        prefs.removeValue(forKey: id)
        writePrefs()
        // A trashed paper may have been part of a duplicate cluster.
        duplicateGroups = DuplicateFinder.findDuplicates(in: papers)
        recomputeAggregates()
    }

    // MARK: - Duplicate resolution

    /// Resolve a duplicate cluster: keep `keepID`, fold the others' useful
    /// state into it (user tags, and rating/saved when the keeper lacks them),
    /// then move the redundant copies to the Trash. Nothing is lost — the
    /// keeper inherits the best metadata, and trashed files stay recoverable.
    func resolveDuplicates(keep keepID: String, trash trashIDs: [String]) {
        guard papers.contains(where: { $0.id == keepID }) else { return }
        let losers = trashIDs.filter { $0 != keepID }
        guard !losers.isEmpty else { return }

        // Merge user tags from every loser into the keeper.
        var mergedTags = papers.first(where: { $0.id == keepID })?.user_tags ?? []
        var seen = Set(mergedTags.map { $0.lowercased() })
        for lid in losers {
            guard let lp = papers.first(where: { $0.id == lid }) else { continue }
            for t in lp.user_tags where seen.insert(t.lowercased()).inserted {
                mergedTags.append(t)
            }
        }
        if mergedTags != (papers.first(where: { $0.id == keepID })?.user_tags ?? []) {
            setUserTags(mergedTags, for: keepID)
        }

        // Inherit rating / saved / read from a loser only where the keeper is
        // unset — the user's explicit choice on the keeper always wins.
        updatePrefs(for: keepID) { keeper in
            for lid in losers {
                let lp = prefs[lid] ?? PrefsEntry()
                if keeper.rating == nil, let r = lp.rating { keeper.rating = r }
                if !keeper.saved, lp.saved { keeper.saved = true }
                if !keeper.read, lp.read { keeper.read = true }
            }
        }

        // Trash the redundant copies (deletePaper recomputes duplicateGroups).
        for lid in losers {
            deletePaper(lid)
        }
    }

    // MARK: - Metadata edits (write back to metadata.json)

    /// Read-modify-write a paper's metadata.json on disk. Then refresh that
    /// paper's entry in `papers` so the UI sees the change.
    private func updateMetadata(id: String, mutate: (inout [String: Any]) -> Void) {
        if rewriteMetadata(id: id, mutate: mutate) {
            refreshPaperOnDisk(id: id)
        }
    }

    /// The disk half of `updateMetadata`, without the per-paper refresh —
    /// library-wide passes (tag/author merges) rewrite many files and then
    /// reload everything once with `rescan()`. Returns whether it wrote.
    /// Silent when `mutate` leaves the JSON untouched, so a no-op merge
    /// doesn't churn iCloud files.
    @discardableResult
    private func rewriteMetadata(id: String, mutate: (inout [String: Any]) -> Void) -> Bool {
        let url = config.metadataURL(id)
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastScanError = "Couldn't read \(url.lastPathComponent)"
            return false
        }
        var obj = loaded
        mutate(&obj)
        guard !NSDictionary(dictionary: obj).isEqual(to: loaded) else { return false }
        do {
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
            return true
        } catch {
            lastScanError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// Set the paper's title. Used by the inline editor when PDFKit gave a junky
    /// title or the LLM heuristic missed a real-but-wrong title.
    func setTitle(_ title: String, for id: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        updateMetadata(id: id) { $0["title"] = cleaned }
    }

    /// Set the paper's kind (paper / book / report).
    func setKind(_ kind: PaperKind, for id: String) {
        updateMetadata(id: id) { $0["kind"] = kind.rawValue }
    }

    /// Set the paper's user_tags. Replaces the entire array — caller normalizes.
    func setUserTags(_ tags: [String], for id: String) {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let deduped = cleaned.filter { seen.insert($0).inserted }
        updateMetadata(id: id) { $0["user_tags"] = deduped }
        // Refresh vocabulary so the sidebar tag list and LLM prompt see the change.
        tagStore.rebuildFromPapers(papers)
    }

    func addUserTag(_ tag: String, for id: String) {
        guard let p = papers.first(where: { $0.id == id }) else { return }
        let new = p.user_tags + [tag]
        setUserTags(new, for: id)
    }

    func removeUserTag(_ tag: String, for id: String) {
        guard let p = papers.first(where: { $0.id == id }) else { return }
        let lower = tag.lowercased()
        let new = p.user_tags.filter { $0.lowercased() != lower }
        setUserTags(new, for: id)
    }

    // MARK: - LLM tagging

    /// Resolve the active provider for an LLM operation. Every feature-level
    /// LLM entry point in this class goes through here, so provider-selection
    /// logic lives in exactly one place — and each resolution also refreshes
    /// the published `llmProvider`/`llmDiagnostic`, keeping Settings honest.
    /// `resolveProvider()` for jobs that can't run without one: reports the
    /// standard hint and returns nil so the caller just bails.
    private func availableProvider() async -> LLMTagger.Provider? {
        let provider = await resolveProvider()
        guard provider.isAvailable else {
            reportTaggerError(LLMTagger.Provider.missingHint)
            return nil
        }
        return provider
    }

    func resolveProvider() async -> LLMTagger.Provider {
        let (p, diag) = await LLMTagger.detectProvider(
            llmPreference,
            claudeModel: claudeModel,
            ollamaModel: ollamaModel)
        self.llmProvider = p
        self.llmDiagnostic = diag
        return p
    }

    func refreshLLMProvider() async {
        _ = await resolveProvider()
        self.availableOllamaModels = await LLMTagger.listOllamaChatModels()
    }

    /// Read one paper's metadata.json from disk and replace it in `papers`.
    private func refreshPaperOnDisk(id: String) {
        let metaURL = config.metadataURL(id)
        guard let data = try? Data(contentsOf: metaURL),
              let p = try? JSONDecoder().decode(Paper.self, from: data) else { return }
        if let idx = papers.firstIndex(where: { $0.id == id }) {
            papers[idx] = p
            recomputeAggregates()
        }
    }

    /// Bulk-tagging progress. nil when idle.
    @Published var bulkTagProgress: (done: Int, total: Int)? = nil

    /// Handle to the currently-running bulk-tag task. Used to cancel it.
    private var bulkTagTask: Task<Void, Never>?

    /// Per-paper task handles for individual (non-bulk) tagging. Cancellable.
    private var taggingTasks: [String: Task<Void, Never>] = [:]

    /// How many papers to tag concurrently in bulk mode. nonisolated: it's an
    /// immutable constant, and `runBulk`'s default parameter is evaluated in
    /// a nonisolated context.
    nonisolated static let bulkConcurrency = 3

    /// Shared prime-and-refill loop for every bulk LLM operation (tag all,
    /// assess found PDFs, verify attributions): keeps `width` workers in
    /// flight, invokes `onEach` on the main actor after every completion (in
    /// completion order, with a running done-count), and stops refilling when
    /// the surrounding task is cancelled.
    private func runBulk<T: Sendable, R: Sendable>(
        _ items: [T],
        width: Int = LibraryStore.bulkConcurrency,
        worker: @escaping @Sendable (T) async -> R,
        onEach: (R, _ done: Int) -> Void
    ) async {
        var done = 0
        var iter = items.makeIterator()
        await withTaskGroup(of: R.self) { group in
            for _ in 0..<min(width, items.count) {
                if let item = iter.next() {
                    group.addTask { await worker(item) }
                }
            }
            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                done += 1
                onEach(result, done)
                if let item = iter.next() {
                    group.addTask { await worker(item) }
                }
            }
        }
    }

    /// How much of the PDF the LLM sees.
    enum TaggingMode {
        case fast    // first 3 pages — cheap, fits any provider, good for tagging
        case full    // provider's char cap — whole paper on Claude
    }

    /// Spawn a background task that runs the LLM tagger and writes results into
    /// metadata.json / summary.md. Silent on failure (no-op if no provider).
    /// - Parameter force: if false, skip papers that already have all fields.
    /// - Parameter mode: `.fast` (3 pages, default) or `.full` (provider cap).
    func generateTagsInBackground(for id: String, force: Bool = false, mode: TaggingMode = .fast) {
        // Replace any prior task for this paper.
        taggingTasks[id]?.cancel()
        taggingTasks[id] = Task { @MainActor [weak self] in
            await self?.runTagging(for: id, force: force, mode: mode)
            self?.taggingTasks.removeValue(forKey: id)
        }
    }

    /// Cancel an in-flight per-paper tagging operation. No-op if not running.
    /// This does NOT cancel a paper being tagged as part of `tagAllUntagged` —
    /// for that, use `cancelBulkTagging()`.
    func cancelTagging(for id: String) {
        taggingTasks[id]?.cancel()
    }

    // MARK: - Consolidate tags

    /// Ask the LLM to look at the current tag vocabulary and propose merges.
    /// Throws if no provider is available.
    func proposeTagMerges() async throws -> [LLMTagger.TagMergeProposal] {
        let provider = await resolveProvider()
        guard provider.isAvailable else { throw LLMTagger.TaggerError.noProvider }
        let vocab = Array(tagStore.vocabulary.values)
        return try await LLMTagger.proposeMerges(vocabulary: vocab, using: provider)
    }

    /// Apply a set of tag merges across every paper's metadata.json. For each
    /// merge, every occurrence of any `from` tag (in user_tags, auto.tags,
    /// auto.topics, auto.application_areas, auto.methods) is replaced with
    /// `into`. Duplicates after replacement are deduped. Then the vocabulary
    /// is rebuilt from the (now updated) paper set.
    func applyTagMerges(_ merges: [LLMTagger.TagMergeProposal]) {
        guard !merges.isEmpty else { return }

        // Build a single from→into lookup for O(1) renames.
        var renames: [String: String] = [:]
        for m in merges {
            for f in m.from {
                renames[f.lowercased()] = m.into.lowercased()
            }
        }
        guard !renames.isEmpty else { return }

        for p in papers {
            rewriteMetadata(id: p.id) { obj in
                if let ut = obj["user_tags"] as? [String] {
                    obj["user_tags"] = Self.renameList(ut, with: renames, lowercased: true)
                }
                if var auto = obj["auto"] as? [String: Any] {
                    for key in ["tags", "topics", "application_areas", "methods"] {
                        if let arr = auto[key] as? [String] {
                            auto[key] = Self.renameList(arr, with: renames, lowercased: true)
                        }
                    }
                    obj["auto"] = auto
                }
            }
        }

        // Reload all papers from disk and rebuild the vocabulary.
        Task { await self.rescan() }
    }

    // MARK: - Consolidate authors

    /// Strip "et al." junk from every paper's `authors[]` on disk. Idempotent:
    /// only rewrites a paper if its cleaned list differs from what's stored.
    /// Returns the number of papers actually modified.
    @discardableResult
    func cleanupAuthorJunk() -> Int {
        var modified = 0
        for p in papers {
            let cleaned = LLMTagger.cleanAuthorList(p.authors)
            guard cleaned != p.authors else { continue }
            modified += 1
            updateMetadata(id: p.id) { obj in
                obj["authors"] = cleaned
            }
        }
        return modified
    }

    /// Multi-pass LLM author consolidation. Each pass sees the simulated
    /// result of the previous, so the LLM can find merges that only become
    /// obvious after first-round duplicates collapse. Stops when a pass
    /// returns nothing new or `maxPasses` is reached.
    func proposeAuthorMergesThorough(
        maxPasses: Int = 3,
        onPass: @MainActor @escaping (Int, Int) -> Void
    ) async throws -> [LLMTagger.AuthorMergeProposal] {
        let provider = await resolveProvider()
        guard provider.isAvailable else { throw LLMTagger.TaggerError.noProvider }

        var simulated = allAuthors.map { (name: $0.author, count: $0.count) }
        var combined: [LLMTagger.AuthorMergeProposal] = []
        var seenTargets = Set<String>()  // dedup proposals across passes

        for pass in 1...maxPasses {
            await MainActor.run { onPass(pass, maxPasses) }
            let merges = try await LLMTagger.proposeAuthorMerges(
                authors: simulated, using: provider)
            // Drop proposals whose target is already a from→into in combined,
            // and drop ones identical to an earlier merge.
            let fresh = merges.filter { m in
                let key = "\(m.into.lowercased())|\(m.from.map { $0.lowercased() }.sorted().joined(separator: ","))"
                return seenTargets.insert(key).inserted
            }
            if fresh.isEmpty { break }
            combined.append(contentsOf: fresh)
            simulated = Self.simulateAuthorMerges(simulated, merges: fresh)
        }
        return combined
    }

    /// Apply merges to an in-memory author list (no disk writes) so the next
    /// LLM pass sees what would happen if the user approved.
    nonisolated private static func simulateAuthorMerges(
        _ authors: [(name: String, count: Int)],
        merges: [LLMTagger.AuthorMergeProposal]
    ) -> [(name: String, count: Int)] {
        var renames: [String: String] = [:]
        for m in merges {
            for f in m.from where !f.isEmpty {
                renames[f.lowercased()] = m.into
            }
        }
        var counts: [String: Int] = [:]
        var displays: [String: String] = [:]
        for a in authors {
            let target = renames[a.name.lowercased()] ?? a.name
            let key = target.lowercased()
            counts[key, default: 0] += a.count
            displays[key] = target
        }
        return counts.map { (key, count) in
            (name: displays[key] ?? key, count: count)
        }
        .sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) }
    }

    /// Apply author merges across every paper's `authors[]`. For each merge,
    /// every occurrence of any `from` name (case-insensitive) is replaced
    /// with `into` (preserving the target's case). Adjacent duplicates after
    /// replacement are deduped.
    func applyAuthorMerges(_ merges: [LLMTagger.AuthorMergeProposal]) {
        guard !merges.isEmpty else { return }
        var renames: [String: String] = [:]  // lowercased from → preserved-case into
        for m in merges {
            for f in m.from where !f.isEmpty {
                renames[f.lowercased()] = m.into
            }
        }
        guard !renames.isEmpty else { return }

        for p in papers {
            rewriteMetadata(id: p.id) { obj in
                if let existing = obj["authors"] as? [String] {
                    obj["authors"] = Self.renameList(existing, with: renames, lowercased: false)
                }
            }
        }
        Task { await self.rescan() }
    }

    // MARK: - Folder management

    /// Rename or delete a folder library-wide. Touches both `auto.folder`
    /// (LLM-assigned) and `user_folder` (user override) so the change applies
    /// regardless of which path put the paper there. Pass nil for `to` to
    /// clear the folder from every matching paper. If `to` matches an
    /// existing folder name, this effectively merges the two folders.
    /// Matching is case-insensitive on the source name.
    func renameFolder(from oldName: String, to newName: String?) {
        let oldKey = oldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !oldKey.isEmpty else { return }
        let cleaned = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = (cleaned?.isEmpty ?? true) ? nil : cleaned

        for p in papers {
            let autoMatches = (p.auto?.folder?.lowercased() ?? "") == oldKey
            let userMatches = (p.user_folder?.lowercased() ?? "") == oldKey
            guard autoMatches || userMatches else { continue }
            updateMetadata(id: p.id) { obj in
                if autoMatches {
                    var auto = (obj["auto"] as? [String: Any]) ?? [:]
                    if let n = newValue {
                        auto["folder"] = n
                    } else {
                        auto.removeValue(forKey: "folder")
                    }
                    obj["auto"] = auto
                }
                if userMatches {
                    if let n = newValue {
                        obj["user_folder"] = n
                    } else {
                        obj.removeValue(forKey: "user_folder")
                    }
                }
            }
        }
    }

    /// Dedupe-preserving list rename: applies `renames` (keyed by lowercased
    /// name) to each entry and drops case-insensitive duplicates, preserving
    /// order. Tags are a lowercase vocabulary, so they pass `lowercased: true`;
    /// author names keep the casing the merge target was written with.
    nonisolated private static func renameList(
        _ list: [String],
        with renames: [String: String],
        lowercased: Bool
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in list {
            let renamed = renames[name.lowercased()] ?? (lowercased ? name.lowercased() : name)
            if seen.insert(renamed.lowercased()).inserted {
                out.append(renamed)
            }
        }
        return out
    }

    /// True if the paper still needs LLM work: tags, title, authors, summary,
    /// or folder missing/bad. Reads only in-memory state (`papersWithSummary`
    /// stands in for summary.md) so it's safe to call from a view body.
    func paperNeedsTagging(_ p: Paper) -> Bool {
        let noTags = p.auto?.tags?.isEmpty ?? true
        let badTitle = LLMTagger.isLikelyBadTitle(p.title)
        let badAuthors = LLMTagger.areLikelyBadAuthors(p.authors)
        let noSummary = !papersWithSummary.contains(p.id)
        let noFolder = (p.auto?.folder?.isEmpty ?? true)
        return noTags || badTitle || badAuthors || noSummary || noFolder
    }

    /// Set the user's folder override. Stored at the top level as `user_folder`
    /// so the LLM's tagging pass (which writes `auto.folder`) never clobbers it.
    /// Pass nil to clear the override and fall back to the LLM's suggestion.
    func setUserFolder(_ folder: String?, for id: String) {
        let cleaned = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateMetadata(id: id) { obj in
            if let f = cleaned, !f.isEmpty {
                obj["user_folder"] = f
            } else {
                obj.removeValue(forKey: "user_folder")
            }
        }
    }

    /// Tag every paper that's missing tags / title / authors / summary. Runs
    /// `bulkConcurrency` LLM calls in parallel. Returns immediately — observe
    /// `bulkTagProgress` for progress, call `cancelBulkTagging()` to stop.
    func tagAllUntagged() {
        guard bulkTagTask == nil else { return }
        let ids = papers.compactMap { p -> String? in
            paperNeedsTagging(p) ? p.id : nil
        }
        guard !ids.isEmpty else { return }
        bulkTagProgress = (0, ids.count)
        let total = ids.count

        bulkTagTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.bulkTagTask = nil
                self.bulkTagProgress = nil
            }
            await self.runBulk(ids) { [weak self] id in
                await self?.runTagging(for: id, force: false, mode: .fast)
            } onEach: { _, done in
                self.bulkTagProgress = (done, total)
            }
        }
    }

    /// Cancel the running bulk-tag operation (if any). Each in-flight Claude
    /// subprocess gets a SIGTERM via `withTaskCancellationHandler`.
    func cancelBulkTagging() {
        bulkTagTask?.cancel()
    }

    /// Core tagging routine. Async so callers can await it; safe to call from
    /// a fire-and-forget `Task` too.
    private func runTagging(for id: String, force: Bool, mode: TaggingMode) async {
        guard !taggingInFlight.contains(id) else { return }
        taggingInFlight.insert(id)
        defer { taggingInFlight.remove(id) }

        let metaURL = config.metadataURL(id)
        let pdfURL = config.pdfURL(id)
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return }

        guard let metaData = try? Data(contentsOf: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            return
        }
        let existingTitle = (obj["title"] as? String) ?? ""
        let existingAuthors = (obj["authors"] as? [String]) ?? []
        let summaryURL = config.summaryURL(id)
        let hasSummary = FileManager.default.fileExists(atPath: summaryURL.path)
            && ((try? Data(contentsOf: summaryURL))?.isEmpty == false)
        if !force {
            let hasTags: Bool = {
                guard let auto = obj["auto"] as? [String: Any],
                      let existing = auto["tags"] as? [String] else { return false }
                return !existing.isEmpty
            }()
            let hasFolder: Bool = {
                guard let auto = obj["auto"] as? [String: Any],
                      let f = auto["folder"] as? String else { return false }
                return !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }()
            let titleOK = !LLMTagger.isLikelyBadTitle(existingTitle)
            let authorsOK = !LLMTagger.areLikelyBadAuthors(existingAuthors)
            if hasTags && titleOK && authorsOK && hasSummary && hasFolder { return }
        }

        // Provider must be resolved on the main actor (reads model prefs).
        guard let provider = await availableProvider() else { return }

        // Heavy work off the main actor: PDF text extraction + LLM call.
        // Trim text to fit the active provider's context budget AND the chosen mode.
        let textCap = LLMTagger.maxCharsForProvider(provider)
        let pageCap: Int
        switch mode {
        case .fast: pageCap = 3
        case .full: pageCap = .max
        }
        // Pre-rendered vocab passes to the LLM so it prefers existing tags.
        let vocabPrompt = tagStore.promptVocabulary(maxTags: 80)
        // Folder vocab — snapshot here on the main actor so the detached Task
        // can use it without touching `self`.
        let existingFolders = folderVocabulary
        let result: Result<LLMTagger.ExtractedInfo, Error> = await Task.detached(priority: .utility) {
            let text = LLMTagger.extractText(from: pdfURL, maxChars: textCap, maxPages: pageCap)
            do {
                let info = try await LLMTagger.extractInfo(
                    currentTitle: existingTitle,
                    text: text,
                    vocabulary: vocabPrompt,
                    existingFolders: existingFolders,
                    using: provider)
                return .success(info)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .failure(let error):
            // A user-initiated stop isn't a failure worth shouting about.
            if !(error is CancellationError) {
                self.reportTaggerError(error.localizedDescription)
            }
            return
        case .success(let info):
            guard !info.isEmpty else { return }

            // Canonicalize LLM-proposed tags against the library vocabulary —
            // exact match wins, near matches (case / hyphen / plural) snap to
            // existing, genuinely new tags pass through.
            var canon = info
            canon.topics = tagStore.canonicalize(info.topics)
            canon.applicationAreas = tagStore.canonicalize(info.applicationAreas)
            canon.methods = tagStore.canonicalize(info.methods)
            // Case-insensitive snap on folder: prevents "Machine Learning" /
            // "machine learning" duplicates.
            if let f = canon.folder {
                canon.folder = LLMTagger.canonicalizeFolder(f, against: existingFolders)
            }

            // Multi-pass attribution check. Wrong title/author attribution is
            // the most visible tagging failure, so before rewriting either
            // field, get second (and if needed third) opinions from a cheap
            // model and require two votes to agree. The main pass's proposal
            // is the seed vote; on disagreement with no majority, fields fall
            // back to the single-shot proposal below.
            var verified = LLMTagger.TitleAuthorsProposal(
                title: canon.title, authors: canon.authors)
            let titleNeedsWork = force || LLMTagger.isLikelyBadTitle(existingTitle)
            let authorsNeedWork = force || LLMTagger.areLikelyBadAuthors(existingAuthors)
            if titleNeedsWork || authorsNeedWork {
                let cheap = LLMTagger.cheapVariant(of: provider)
                let seed = verified
                let consensus = await Task.detached(priority: .utility) {
                    () -> LLMTagger.TitleAuthorsProposal in
                    // Attribution lives on the first pages — a small sample
                    // keeps the verification passes fast and cheap.
                    let sample = LLMTagger.extractText(
                        from: pdfURL, maxChars: 8_000, maxPages: 2)
                    return await LLMTagger.consensusTitleAuthors(
                        text: sample, seed: seed, using: cheap)
                }.value
                if let t = consensus.title { verified.title = t }
                if let a = consensus.authors { verified.authors = a }
            }

            // Title: on the conservative path (force=false, bulk), only
            // overwrite when the existing one looks bad. On force=true
            // (user-triggered re-extract), accept any plausible verified
            // title — the whole point of re-extract is to fix titles the
            // heuristic misses.
            let titleUpdate: String? = {
                guard let proposed = verified.title,
                      LLMTagger.isPlausibleTitle(proposed) else { return nil }
                if force { return proposed != existingTitle ? proposed : nil }
                return LLMTagger.isLikelyBadTitle(existingTitle) ? proposed : nil
            }()
            // Same logic for authors.
            let authorsUpdate: [String]? = {
                guard let proposed = verified.authors,
                      LLMTagger.arePlausibleAuthors(proposed) else { return nil }
                if force { return proposed != existingAuthors ? proposed : nil }
                return LLMTagger.areLikelyBadAuthors(existingAuthors) ? proposed : nil
            }()

            do {
                try Self.writeAutoInfo(canon, titleUpdate: titleUpdate, authorsUpdate: authorsUpdate, to: metaURL)
                // Fold the new tag set into the vocabulary so the next paper sees it.
                tagStore.recordUsage(canon.union)
                if let s = canon.summary, !s.isEmpty {
                    // Only write summary if there isn't already a user-curated one, OR
                    // if we're being forced. (Bulk run defaults to non-force, which
                    // means we already passed the hasSummary guard above for any paper
                    // that gets here — so it's safe to write.)
                    try s.write(to: summaryURL, atomically: true, encoding: .utf8)
                    papersWithSummary.insert(id)
                }
            } catch {
                self.reportTaggerError("Couldn't save tagging results: \(error.localizedDescription)")
                return
            }
            refreshPaperOnDisk(id: id)
        }
    }

    nonisolated private static func writeAutoInfo(
        _ info: LLMTagger.ExtractedInfo,
        titleUpdate: String?,
        authorsUpdate: [String]?,
        to url: URL
    ) throws {
        let data = try Data(contentsOf: url)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Sift", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "malformed metadata.json"])
        }
        var auto = (obj["auto"] as? [String: Any]) ?? [:]
        auto["topics"] = info.topics
        auto["application_areas"] = info.applicationAreas
        auto["methods"] = info.methods
        // Keep auto.tags as the flat union — used by sidebar tag list + search fallback.
        auto["tags"] = info.union
        // Only overwrite folder when the LLM produced one — don't clobber a
        // user-edited folder if the LLM (e.g. small ollama model) skipped it.
        if let f = info.folder, !f.isEmpty {
            auto["folder"] = f
        }
        obj["auto"] = auto
        if let newTitle = titleUpdate {
            obj["title"] = newTitle
        }
        if let newAuthors = authorsUpdate {
            obj["authors"] = newAuthors
        }
        let out = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    private func writePrefs() {
        do {
            try FileManager.default.createDirectory(
                at: config.userDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(prefs)
            try data.write(to: config.prefsFile, options: .atomic)
        } catch {
            lastScanError = "Failed to write prefs.json: \(error.localizedDescription)"
        }
    }
}
