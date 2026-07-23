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
    @State private var dropStatus: String?
    @State private var isImporting: Bool = false
    // Detail panel visibility — persisted so the layout survives relaunch.
    @AppStorage("Sift.detailPaneVisible") private var showDetailPane: Bool = true
    @State private var showImportReview: Bool = false
    @State private var showDuplicates: Bool = false
    @State private var discoveryBannerDismissed: Bool = false
    @State private var duplicateBannerDismissed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar appears only once a reader tab is open — the default
            // library-only state stays chrome-free.
            if !store.openReaderTabs.isEmpty {
                readerTabBar
                Divider()
            }
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
            // All tabs stay alive in a ZStack (opacity-switched, not if/else)
            // so PDF scroll positions and chat drafts survive tab switches.
            ZStack {
                librarySplit
                    .opacity(isLibraryActive ? 1 : 0)
                    .allowsHitTesting(isLibraryActive)
                    .toolbar(isLibraryActive ? .automatic : .hidden, for: .windowToolbar)
                ForEach(store.openReaderTabs, id: \.self) { id in
                    ReaderView(paperId: id)
                        .opacity(store.activeReaderTab == id ? 1 : 0)
                        .allowsHitTesting(store.activeReaderTab == id)
                }
            }
        }
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedFiles(providers)
            return true
        }
        .overlay(alignment: .bottom) {
            if let s = dropStatus ?? store.statusToast {
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

    /// Banner surfacing watched-folder finds — the discoverable entry point
    /// for the import feature.
    private var discoveryBanner: some View {
        let n = store.newFoundPDFCount
        return HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.tint)
            Text("Found ^[\(n) new PDF](inflect: true) in your watched folders.")
                .font(.callout)
            Spacer()
            Button("Review…") { showImportReview = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                discoveryBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss until the next scan")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.08))
    }

    /// Banner surfacing likely-duplicate papers already in the library.
    private var duplicateBanner: some View {
        let n = store.duplicateExtraCount
        return HStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.orange)
            Text("^[\(n) possible duplicate paper](inflect: true) in your library.")
                .font(.callout)
            Spacer()
            Button("Review…") { showDuplicates = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button {
                duplicateBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss until the next refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
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

    // MARK: - Reader tab bar

    private var readerTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tabChip(
                    label: { Label("Library", systemImage: "tray.full") },
                    active: isLibraryActive,
                    activate: { store.activeReaderTab = nil },
                    close: nil)
                ForEach(store.openReaderTabs, id: \.self) { id in
                    let title = store.papers.first(where: { $0.id == id })?.title ?? "Paper"
                    tabChip(
                        label: {
                            Label(title, systemImage: "text.book.closed")
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 220, alignment: .leading)
                        },
                        active: store.activeReaderTab == id,
                        activate: { store.activeReaderTab = id },
                        close: { store.closeReader(id) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    private func tabChip<L: View>(
        @ViewBuilder label: () -> L,
        active: Bool,
        activate: @escaping () -> Void,
        close: (() -> Void)?
    ) -> some View {
        HStack(spacing: 5) {
            Button(action: activate) {
                label()
            }
            .buttonStyle(.plain)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            active ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
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

    private func handleDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in
                    await ingestDropped(url: url)
                }
            }
        }
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
            let count = store.papers.filter { store.paperNeedsTagging($0) }.count
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
                  : "No AI helper connected. Open Settings to connect Claude or Ollama.")
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
        isImporting = true
        defer { isImporting = false }
        let ingest = IngestService(config: store.config)
        do {
            let result = try await ingest.addLocalPDF(at: url)
            await store.rescan()
            if !result.alreadyExisted {
                store.generateTagsInBackground(for: result.paperId)
            }
            showStatus(result.alreadyExisted
                ? "Already in library: \(url.lastPathComponent)"
                : "Added \(url.lastPathComponent)")
        } catch {
            showStatus("Failed: \(error.localizedDescription)")
        }
    }

    private func showStatus(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            dropStatus = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if dropStatus == message { dropStatus = nil }
                }
            }
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
