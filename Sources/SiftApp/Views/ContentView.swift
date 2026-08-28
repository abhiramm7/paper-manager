import SwiftUI
import UniformTypeIdentifiers

enum LibraryFilter: Hashable {
    case all
    case unread
    case starred
    case highlyRated    // rating >= 4
    case kind(PaperKind)
    case tag(String)
    case folder(String)
    case author(String)
}

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var filter: LibraryFilter = .all
    @State private var selectedID: String?
    @State private var searchText: String = ""
    @State private var showAdd: Bool = false
    @State private var sortPreset: SortPreset = .recent
    @State private var sortOrder: [KeyPathComparator<Paper>] = SortPreset.recent.comparators
    // Detail panel visibility — persisted so the layout survives relaunch.
    @AppStorage("Sift.detailPaneVisible") private var showDetailPane: Bool = true
    @State private var showImportReview: Bool = false
    @State private var showDuplicates: Bool = false
    @State private var discoveryBannerDismissed: Bool = false
    @State private var duplicateBannerDismissed: Bool = false
    /// Bumped by ⌘F; the toolbar search field takes focus when it changes.
    @State private var searchFocusToken: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // The tab strip lives in the window toolbar (see `tabStrip`), so
            // it sits beside the traffic lights the way Safari's does.
            //
            // Proactively surface watched-folder finds. Without this the
            // feature is invisible — a quiet sidebar row you'd only find
            // after configuring Settings. Dismissable per batch.
            if isLibraryActive, store.newFoundPDFCount > 0, !discoveryBannerDismissed {
                discoveryBanner
                Divider()
            }
            if isLibraryActive, store.duplicateExtraCount > 0, !duplicateBannerDismissed {
                duplicateBanner
                Divider()
            }
            // Library-level failures (unreadable library folder, a metadata
            // write that didn't land) used to be recorded and never shown.
            if isLibraryActive, let err = store.lastScanError {
                errorBanner(err)
                Divider()
            }
            // All tabs stay alive in a ZStack (opacity-switched, not if/else)
            // so PDF scroll positions and chat drafts survive tab switches.
            ZStack {
                librarySplit
                    .opacity(isLibraryActive ? 1 : 0)
                    .allowsHitTesting(isLibraryActive)
                ForEach(store.openReaderTabs, id: \.self) { id in
                    ReaderView(paperId: id)
                        .opacity(store.activeReaderTab == id ? 1 : 0)
                        .allowsHitTesting(store.activeReaderTab == id)
                }
            }
        }
        // Hide the title *text* without renaming the window: the tab strip
        // names the active view the way Safari's does, while the Window menu
        // and Mission Control still say "Sift". (`.navigationTitle("")` would
        // blank the window's actual name; `.toolbar(removing: .title)` is
        // macOS 15+.)
        .background(WindowAccessor(
            // Toggling the details pane swaps NavigationSplitView variants,
            // which rebuilds the titlebar and brings the title text back —
            // so it belongs in the token too.
            token: "\(store.activeReaderTab ?? "library")-\(store.openReaderTabs.count)-\(showDetailPane)"
        ) { window in
            window.titleVisibility = .hidden
        })
        .sheet(isPresented: $showAdd) {
            AddSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showImportReview) {
            ImportReviewSheet().environmentObject(store)
        }
        .sheet(isPresented: $showDuplicates) {
            DuplicateReviewSheet().environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddSheet)) { _ in
            showAdd = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showImportReview)) { _ in
            showImportReview = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDuplicates)) { _ in
            showDuplicates = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            searchFocusToken += 1
        }
        .onChange(of: store.foundPDFs.count) { _, _ in
            // New scan results → let the banner reappear for the new batch.
            discoveryBannerDismissed = false
        }
        .onChange(of: store.duplicateGroups.count) { _, _ in
            duplicateBannerDismissed = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshLibrary)) { _ in
            Task { await store.rescan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeActiveTab)) { _ in
            if let active = store.activeReaderTab {
                store.closeReader(active)
            } else {
                NSApp.keyWindow?.performClose(nil)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedFiles(providers)
        }
        .overlay(alignment: .bottom) {
            if let s = store.statusToast {
                Text(s)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    private var isLibraryActive: Bool { store.activeReaderTab == nil }

    /// One banner shape for the three things that can interrupt the library:
    /// watched-folder finds, likely duplicates, and a library-level error.
    /// Icon + message on the left, the one useful action and a dismiss on the
    /// right, tinted by severity.
    private func banner(
        icon: String,
        tint: Color,
        message: Text,
        actionTitle: String,
        prominent: Bool = false,
        dismissHelp: String,
        action: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            message
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Group {
                if prominent {
                    Button(actionTitle, action: action).buttonStyle(.borderedProminent)
                } else {
                    Button(actionTitle, action: action).buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(dismissHelp)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
    }

    /// Watched-folder finds — the discoverable entry point for the import
    /// feature, which is otherwise a quiet sidebar row.
    private var discoveryBanner: some View {
        let n = store.newFoundPDFCount
        return banner(
            icon: "tray.and.arrow.down.fill",
            tint: .accentColor,
            message: Text("Found ^[\(n) new PDF](inflect: true) in your watched folders."),
            actionTitle: "Review…",
            prominent: true,
            dismissHelp: "Dismiss until the next scan",
            action: { showImportReview = true },
            dismiss: { discoveryBannerDismissed = true })
    }

    /// Likely-duplicate papers already in the library.
    private var duplicateBanner: some View {
        let n = store.duplicateExtraCount
        return banner(
            icon: "doc.on.doc",
            tint: .orange,
            message: Text("^[\(n) possible duplicate paper](inflect: true) in your library."),
            actionTitle: "Review…",
            dismissHelp: "Dismiss until the next refresh",
            action: { showDuplicates = true },
            dismiss: { duplicateBannerDismissed = true })
    }

    /// A library-level problem — the one class of error the user can usually
    /// act on (wrong folder, permissions, iCloud not downloaded).
    private func errorBanner(_ message: String) -> some View {
        banner(
            icon: "exclamationmark.triangle.fill",
            tint: .red,
            message: Text(message),
            actionTitle: "Try again",
            dismissHelp: "Dismiss",
            action: { Task { await store.rescan() } },
            dismiss: { store.lastScanError = nil })
    }

    /// The details panel toggles (⌥⌘0) by swapping between a three-column
    /// and a two-column NavigationSplitView. The paper list Table always
    /// lives in a REAL split-view column — hosting it in an HSplitView
    /// pane broke the table's column layout (headers/cells misaligned),
    /// since Table sizes its columns against the split-view column, not
    /// an arbitrary pane. Selection and filter state live up in ContentView,
    /// so they survive the swap.
    @ViewBuilder
    private var librarySplit: some View {
        if showDetailPane {
            NavigationSplitView {
                sidebarColumn
            } content: {
                listColumn
                    .navigationSplitViewColumnWidth(min: 360, ideal: 480)
            } detail: {
                detailPane
                    .navigationSplitViewColumnWidth(min: 340, ideal: 440)
            }
        } else {
            NavigationSplitView {
                sidebarColumn
            } detail: {
                listColumn
            }
        }
    }

    // MARK: - Reader tabs

    /// Safari-style tab strip. Lives at `.navigation` placement so it renders
    /// immediately to the right of the window's close/minimize/zoom buttons,
    /// with Library as the permanent first tab and each open PDF after it.
    private var tabStrip: some View {
        // macOS draws its own capsule behind a toolbar item, so the chips are
        // inset from it: flush chips let the active tab's corners poke out
        // past that capsule's curve.
        HStack(spacing: 2) {
            tabChip(
                title: "Library",
                systemImage: "tray.full",
                active: isLibraryActive,
                maxWidth: nil,
                activate: { store.activeReaderTab = nil },
                close: nil)
            ForEach(store.openReaderTabs, id: \.self) { id in
                let title = store.papers.first(where: { $0.id == id })?.title ?? "Paper"
                tabChip(
                    title: title,
                    systemImage: "text.book.closed",
                    active: store.activeReaderTab == id,
                    maxWidth: 180,
                    activate: { store.activeReaderTab = id },
                    close: { store.closeReader(id) })
            }
        }
        .padding(.horizontal, 6)
    }

    private func tabChip(
        title: String,
        systemImage: String,
        active: Bool,
        maxWidth: CGFloat?,
        activate: @escaping () -> Void,
        close: (() -> Void)?
    ) -> some View {
        HStack(spacing: 5) {
            Button(action: activate) {
                Label(title, systemImage: systemImage)
                    // Toolbar items default to icon-only; a tab needs its name.
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .fixedSize(horizontal: maxWidth == nil, vertical: false)
            }
            .buttonStyle(.plain)
            .help(title)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        // Capsule, not a rounded rect: it nests inside the toolbar's own
        // capsule instead of cutting across its corners.
        .background(
            active ? Color.accentColor.opacity(0.16) : Color.clear,
            in: Capsule())
        .contentShape(Rectangle())
    }

    private var sidebarColumn: some View {
        Sidebar(filter: $filter)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }

    /// Paper list plus the window toolbar. The toolbar is attached here (not
    /// to the NavigationSplitView) so both split-view variants share it.
    private var listColumn: some View {
        PaperList(
            papers: filteredPapers,
            selectedID: $selectedID,
            searchText: $searchText,
            sortOrder: $sortOrder
        )
        .toolbar {
            // Tabs first, hard left — the Safari arrangement: traffic lights,
            // then tabs, then the tools for whatever tab you're on.
            ToolbarItem(placement: .navigation) {
                tabStrip
            }
            // Library tools only apply to the Library tab. On a reader tab the
            // toolbar collapses to the tab strip, and the reader's own bar
            // (contents, highlights) takes over below it.
            if isLibraryActive {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(SortPreset.allCases) { preset in
                            Button {
                                sortPreset = preset
                                // Rating sort needs prefs; PaperList sees empty
                                // comparators and applies the rating-aware sort.
                                sortOrder = preset.comparators
                            } label: {
                                if sortPreset == preset {
                                    Label(preset.label, systemImage: "checkmark")
                                } else {
                                    Text(preset.label)
                                }
                            }
                        }
                    } label: {
                        Label("Sort: \(sortPreset.label)", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort the paper list")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add a paper (⌘N)")
                }
                ToolbarItem(placement: .primaryAction) {
                    aiToolbar
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.rescan() }
                    } label: {
                        if store.isScanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .help("Rescan iCloud (⌘R)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showDetailPane.toggle()
                    } label: {
                        Label(showDetailPane ? "Hide details" : "Show details",
                              systemImage: "sidebar.trailing")
                    }
                    .keyboardShortcut("0", modifiers: [.option, .command])
                    .help(showDetailPane
                          ? "Hide the details panel (⌥⌘0)"
                          : "Show the details panel (⌥⌘0)")
                }
            }
            // Search stays put — top right, same spot on every tab. The
            // Spacer is a flexible toolbar space: without it the field packs
            // in behind whatever items precede it, so losing the library
            // tools on a reader tab slid it left against the tab strip.
            // Declared outside the `isLibraryActive` gate because the field
            // is there on every tab; only what it searches changes.
            ToolbarItem(placement: .primaryAction) {
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                searchControls
            }
        }
    }

    // MARK: - Search / find

    /// Match counter and steppers sit to the *left* of the field, so the
    /// field itself doesn't shift when they appear.
    private var searchControls: some View {
        HStack(spacing: 6) {
            if !isLibraryActive, store.activeFindQuery.count >= LibraryStore.minFindLength {
                findSteppers
            }
            ToolbarSearchField(
                text: searchBinding,
                prompt: isLibraryActive ? "Search title, authors, tags" : "Find in PDF",
                focusToken: searchFocusToken,
                onSubmit: {
                    guard !isLibraryActive else { return }
                    NotificationCenter.default.post(name: .findNext, object: nil)
                })
            .help(isLibraryActive
                  ? "Search the library by title, author, tag or venue (⌘F)"
                  : "Find in this PDF (⌘F) — ↩ or ⌘G for the next match")
        }
    }

    /// Whichever query the active tab owns: the library filter, or that
    /// reader tab's find-in-PDF query.
    private var searchBinding: Binding<String> {
        guard let id = store.activeReaderTab else { return $searchText }
        return Binding(
            get: { store.findQuery[id] ?? "" },
            set: { store.findQuery[id] = $0 })
    }

    private func findLabel(_ status: LibraryStore.FindStatus) -> String {
        if status.searching { return "Searching…" }
        return status.count == 0 ? "Not found" : "\(status.index) of \(status.count)"
    }

    private var findSteppers: some View {
        let status = store.activeReaderTab.flatMap { store.findStatus[$0] }
            ?? LibraryStore.FindStatus()
        return HStack(spacing: 2) {
            Text(findLabel(status))
                .font(.caption.monospacedDigit())
                .foregroundStyle(status.count == 0 ? Color.secondary : Color.primary)
                .fixedSize()
            Button {
                NotificationCenter.default.post(name: .findPrevious, object: nil)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(status.count == 0)
            .help("Previous match (⇧⌘G)")
            Button {
                NotificationCenter.default.post(name: .findNext, object: nil)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(status.count == 0)
            .help("Next match (⌘G)")
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedID, let p = store.papers.first(where: { $0.id == id }) {
            PaperDetail(paper: p)
        } else {
            ContentUnavailableView(
                "Select a paper",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Pick an item from the list to see details.")
            )
        }
    }

    /// Returns whether anything was actually accepted, so a drag of something
    /// that isn't a file bounces back instead of silently vanishing.
    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter {
            $0.canLoadObject(ofClass: URL.self)
        }
        guard !usable.isEmpty else { return false }
        for provider in usable {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in
                    await ingestDropped(url: url)
                }
            }
        }
        return true
    }

    /// Combined AI actions. Idle: a single "AI" menu (Tag all + Verify
    /// attributions) — collapsing two toolbar buttons into one keeps the
    /// toolbar under control. Running: the relevant inline progress + stop,
    /// so a bulk op stays visible and cancellable.
    @ViewBuilder
    private var aiToolbar: some View {
        if let progress = store.bulkTagProgress {
            bulkProgress(progress, label: "Tagging", cancel: store.cancelBulkTagging)
        } else if let progress = store.verifyProgress {
            bulkProgress(progress, label: "Verifying attributions",
                         cancel: store.cancelVerifyAttributions)
        } else {
            let count = store.untaggedCount
            let providerAvailable = store.llmProvider.isAvailable
            Menu {
                Button {
                    store.tagAllUntagged()
                } label: {
                    Label(count > 0 ? "Tag \(count) untagged paper\(count == 1 ? "" : "s")" : "Tag all",
                          systemImage: "sparkles")
                }
                .disabled(count == 0)

                Button {
                    store.verifyAllAttributions()
                } label: {
                    Label("Verify attributions", systemImage: "checkmark.seal")
                }
                .disabled(store.papers.isEmpty)
            } label: {
                Label("AI", systemImage: "sparkles")
            }
            .disabled(!providerAvailable)
            .help(providerAvailable
                  ? "AI actions: tag untagged papers, or verify titles & authors"
                  : LLMTagger.Provider.missingHint)
        }
    }

    /// Shared inline progress + stop control for a running bulk operation.
    private func bulkProgress(
        _ progress: (done: Int, total: Int),
        label: String,
        cancel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 80)
            Text("\(progress.done)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: cancel) {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Stop")
        }
        .help("\(label) — \(progress.done) of \(progress.total) done")
    }

    @MainActor
    private func ingestDropped(url: URL) async {
        let ingest = IngestService(config: store.config)
        do {
            let result = try await ingest.addLocalPDF(at: url)
            await store.rescan()
            if !result.alreadyExisted {
                store.generateTagsInBackground(for: result.paperId)
            }
            store.showToast(result.alreadyExisted
                ? "Already in library: \(url.lastPathComponent)"
                : "Added \(url.lastPathComponent)")
        } catch {
            store.showToast("Failed: \(error.localizedDescription)")
        }
    }

    private var filteredPapers: [Paper] {
        let base: [Paper]
        switch filter {
        case .all:
            base = store.papers
        case .unread:
            base = store.papers.filter { !store.prefs(for: $0.id).read }
        case .starred:
            base = store.papers.filter { store.prefs(for: $0.id).saved }
        case .highlyRated:
            base = store.papers.filter { (store.prefs(for: $0.id).rating ?? 0) >= 4 }
        case .kind(let k):
            base = store.papers.filter { $0.kind == k }
        case .tag(let t):
            let key = t.lowercased()
            base = store.papers.filter { paper in
                paper.allTags.contains { $0.lowercased() == key }
            }
        case .folder(let f):
            let key = f.lowercased()
            base = store.papers.filter { paper in
                (paper.effectiveFolder ?? "").lowercased() == key
            }
        case .author(let a):
            let key = a.lowercased()
            base = store.papers.filter { paper in
                paper.authors.contains { $0.lowercased() == key }
            }
        }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter { paper in
            if paper.title.lowercased().contains(q) { return true }
            if paper.authors.contains(where: { $0.lowercased().contains(q) }) { return true }
            if paper.allTags.contains(where: { $0.lowercased().contains(q) }) { return true }
            if let v = paper.venue, v.lowercased().contains(q) { return true }
            return false
        }
    }
}

/// Reaches the hosting `NSWindow` so we can set the handful of things SwiftUI
/// doesn't expose on macOS 14 (title visibility). Zero-size and invisible;
/// lives in a `.background`.
struct WindowAccessor: NSViewRepresentable {
    /// Changes whenever something that can reset the window chrome changes
    /// (opening or switching a tab rebuilds the toolbar, and SwiftUI restores
    /// title visibility when it does). Re-applies the config for that pass.
    let token: String
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(view)
    }

    private func apply(_ view: NSView) {
        // Once now (the view may not be in a window yet on the first pass) and
        // once after the current update lands, since SwiftUI writes its own
        // titlebar state during the same turn.
        if let window = view.window { configure(window) }
        DispatchQueue.main.async {
            if let window = view.window { configure(window) }
        }
    }
}
