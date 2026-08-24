import SwiftUI

struct Sidebar: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var filter: LibraryFilter
    @State private var tagSearch: String = ""
    @State private var showAllTags: Bool = false
    @State private var authorSearch: String = ""
    @State private var showAllAuthors: Bool = false
    // Collapsed/expanded state persists across launches — Authors and Tags
    // can get long enough that the user wants them out of the way.
    @AppStorage("Sift.sidebarAuthorsExpanded") private var authorsExpanded: Bool = true
    @AppStorage("Sift.sidebarTagsExpanded") private var tagsExpanded: Bool = true

    // Sheets surfaced from the sidebar itself, not just Settings.
    @State private var showManageFolders: Bool = false
    @State private var showConsolidateAuthors: Bool = false
    @State private var showConsolidateTags: Bool = false

    // Inline remove confirmation for a folder picked from the right-click menu.
    // Rename intentionally lives only in FolderManagementSheet — having two
    // rename surfaces (one modal alert, one inline sheet) is the kind of
    // duplication that ages badly.
    @State private var removeFolderTarget: String? = nil


    var body: some View {
        listBody
            .listStyle(.sidebar)
            .sheet(isPresented: $showManageFolders) {
                FolderManagementSheet().environmentObject(store)
            }
            .sheet(isPresented: $showConsolidateAuthors) {
                ConsolidateAuthorsSheet().environmentObject(store)
            }
            .sheet(isPresented: $showConsolidateTags) {
                ConsolidateTagsSheet().environmentObject(store)
            }
            .alert(
                "Remove folder?",
                isPresented: Binding(
                    get: { removeFolderTarget != nil },
                    set: { if !$0 { removeFolderTarget = nil } }
                ),
                presenting: removeFolderTarget,
                actions: removeAlertActions,
                message: removeAlertMessage)
    }

    private var listBody: some View {
        List(selection: Binding(
            get: { filter },
            set: { if let v = $0 { filter = v } }
        )) {
            librarySection
            importSection
            kindSection
            foldersSection
            vocabularySection(.authors)
            vocabularySection(.tags)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var librarySection: some View {
        Section {
            Label("All", systemImage: "tray.full")
                .badge(store.papers.count)
                .tag(LibraryFilter.all)
            Label("Unread", systemImage: "circle.dashed")
                .badge(unreadCount)
                .tag(LibraryFilter.unread)
            Label("Saved", systemImage: "bookmark")
                .badge(starredCount)
                .tag(LibraryFilter.starred)
            Label("Rated 4+", systemImage: "star.fill")
                .badge(highlyRatedCount)
                .tag(LibraryFilter.highlyRated)
        } header: {
            sectionHeaderWithAction(
                title: "Library",
                icon: "doc.on.doc",
                enabled: store.duplicateExtraCount > 0,
                helpEnabled: "Review \(store.duplicateExtraCount) possible duplicate paper(s)",
                helpDisabled: "No duplicate papers detected",
                action: { NotificationCenter.default.post(name: .showDuplicates, object: nil) })
        }
    }

    /// Watched-folder import. Operations live here (sidebar owns operations);
    /// which folders are watched is configured in Settings. Hidden entirely
    /// until the user configures at least one folder — no dead UI.
    @ViewBuilder
    private var importSection: some View {
        if !store.watchedFolders.isEmpty {
            Section {
                Button {
                    NotificationCenter.default.post(name: .showImportReview, object: nil)
                } label: {
                    HStack {
                        Label("Review found PDFs…", systemImage: "tray.and.arrow.down")
                        Spacer()
                        if store.isScanningFolders {
                            ProgressView().controlSize(.small)
                        } else if store.newFoundPDFCount > 0 {
                            Text("\(store.newFoundPDFCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(store.newFoundPDFCount > 0
                      ? "\(store.newFoundPDFCount) new PDF\(store.newFoundPDFCount == 1 ? "" : "s") found in watched folders"
                      : "Review PDFs found in watched folders")
            } header: {
                sectionHeaderWithAction(
                    title: "Watched folders",
                    icon: "arrow.clockwise",
                    enabled: !store.isScanningFolders,
                    helpEnabled: "Rescan watched folders for PDFs",
                    helpDisabled: "Scanning…",
                    action: { Task { await store.scanWatchedFolders() } })
            }
        }
    }

    @ViewBuilder
    private var kindSection: some View {
        Section("Kind") {
            ForEach(PaperKind.allCases, id: \.self) { k in
                Label(k.label + "s", systemImage: k.symbol)
                    .badge(store.papers.filter { $0.kind == k }.count)
                    .tag(LibraryFilter.kind(k))
            }
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        Section {
            if store.allFolders.isEmpty {
                Text("Tag papers to fill this in.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(store.allFolders, id: \.folder) { entry in
                    folderRow(entry)
                }
            }
        } header: {
            sectionHeaderWithAction(
                title: "Folders",
                icon: "square.and.pencil",
                enabled: !store.allFolders.isEmpty,
                helpEnabled: "Manage folders — rename, merge, remove",
                helpDisabled: "No folders yet — tag papers first.",
                action: { showManageFolders = true })
        }
    }

    @ViewBuilder
    private func folderRow(_ entry: (folder: String, count: Int)) -> some View {
        Label(entry.folder, systemImage: "folder")
            .badge(entry.count)
            .tag(LibraryFilter.folder(entry.folder))
            .contextMenu {
                // Rename happens in the Manage folders sheet — the inline
                // editor there can see all folders (which matters for merging
                // by retyping a name) and a TextField alert cannot.
                Button("Manage folder…") {
                    showManageFolders = true
                }
                Button("Remove folder…", role: .destructive) {
                    removeFolderTarget = entry.folder
                }
            }
    }

    /// Authors and Tags are the same widget over different vocabularies: a
    /// collapsible header carrying the LLM-consolidate action, a list capped
    /// until you ask for all of it, and a filter field once it is. Everything
    /// that actually differs between the two lives in this enum.
    private enum Vocabulary {
        case authors, tags

        var title: String { self == .authors ? "Authors" : "Tags" }
        var icon: String { self == .authors ? "person" : "tag" }
        /// How many rows before the list stops and offers "Show all".
        var cap: Int { self == .authors ? 30 : 40 }
        var filterPrompt: String { self == .authors ? "Filter authors" : "Filter tags" }
        var emptyHint: String {
            self == .authors
                ? "Add some papers to fill this in."
                : "Tag papers to fill this in."
        }
        var consolidateHelp: String {
            self == .authors
                ? "Consolidate duplicate author names with the LLM"
                : "Consolidate near-duplicate tags with the LLM"
        }
        /// Tags read as #tag; authors as their plain name.
        func rowLabel(_ name: String) -> String { self == .authors ? name : "#\(name)" }
        func libraryFilter(_ name: String) -> LibraryFilter {
            self == .authors ? .author(name) : .tag(name)
        }
    }

    private func entries(_ v: Vocabulary) -> [(name: String, count: Int)] {
        switch v {
        case .authors: return store.allAuthors.map { (name: $0.author, count: $0.count) }
        case .tags:    return store.allTags.map { (name: $0.tag, count: $0.count) }
        }
    }

    private func expanded(_ v: Vocabulary) -> Binding<Bool> {
        v == .authors ? $authorsExpanded : $tagsExpanded
    }

    private func showAll(_ v: Vocabulary) -> Binding<Bool> {
        v == .authors ? $showAllAuthors : $showAllTags
    }

    private func search(_ v: Vocabulary) -> Binding<String> {
        v == .authors ? $authorSearch : $tagSearch
    }

    private func consolidating(_ v: Vocabulary) -> Binding<Bool> {
        v == .authors ? $showConsolidateAuthors : $showConsolidateTags
    }

    /// The rows actually shown: capped until "Show all", then narrowed by
    /// whatever is typed in the filter field.
    private func visibleEntries(_ v: Vocabulary) -> [(name: String, count: Int)] {
        let all = entries(v)
        let scoped = showAll(v).wrappedValue ? all : Array(all.prefix(v.cap))
        let q = search(v).wrappedValue.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return scoped }
        return scoped.filter { $0.name.lowercased().contains(q) }
    }

    private func vocabularySection(_ v: Vocabulary) -> some View {
        Section {
            if expanded(v).wrappedValue {
                vocabularyBody(v)
            }
        } header: {
            collapsibleHeader(
                title: v.title,
                count: entries(v).count,
                isExpanded: expanded(v),
                trailing: { vocabularyHeaderTrailing(v) })
        }
    }

    @ViewBuilder
    private func vocabularyBody(_ v: Vocabulary) -> some View {
        let all = entries(v)
        if showAll(v).wrappedValue {
            TextField(v.filterPrompt, text: search(v))
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 2)
        }
        if all.isEmpty {
            Text(v.emptyHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 2)
        } else {
            // No per-entry context menu: consolidation is library-wide, not
            // scoped to the clicked name. The header icon is the honest
            // affordance for it.
            ForEach(visibleEntries(v), id: \.name) { entry in
                Label(v.rowLabel(entry.name), systemImage: v.icon)
                    .badge(entry.count)
                    .tag(v.libraryFilter(entry.name))
            }
            if !showAll(v).wrappedValue, all.count > v.cap {
                Button("Show all \(all.count) \(v.title.lowercased())…") {
                    showAll(v).wrappedValue = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func vocabularyHeaderTrailing(_ v: Vocabulary) -> some View {
        if expanded(v).wrappedValue && showAll(v).wrappedValue {
            Button("Show top \(v.cap)") {
                showAll(v).wrappedValue = false
                search(v).wrappedValue = ""
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        Button {
            consolidating(v).wrappedValue = true
        } label: {
            Image(systemName: "sparkles")
        }
        .buttonStyle(.borderless)
        .disabled(!store.llmProvider.isAvailable || entries(v).count < 4)
        .help(store.llmProvider.isAvailable ? v.consolidateHelp : LLMTagger.Provider.missingHint)
    }

    // MARK: - Alerts

    @ViewBuilder
    private func removeAlertActions(_ name: String) -> some View {
        Button("Remove", role: .destructive) {
            store.renameFolder(from: name, to: nil)
            removeFolderTarget = nil
        }
        Button("Cancel", role: .cancel) {
            removeFolderTarget = nil
        }
    }

    private func removeAlertMessage(_ name: String) -> Text {
        let count = store.allFolders.first(where: { $0.folder == name })?.count ?? 0
        return Text("\"\(name)\" will be cleared from \(count) paper\(count == 1 ? "" : "s"). The papers stay; they just won't have a folder.")
    }

    // MARK: - Section header helpers

    /// Plain (non-collapsible) section header with a trailing action icon.
    /// Used for the Folders section, which always stays expanded.
    @ViewBuilder
    private func sectionHeaderWithAction(
        title: String,
        icon: String,
        enabled: Bool,
        helpEnabled: String,
        helpDisabled: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer()
            Button(action: action) {
                Image(systemName: icon)
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(enabled ? helpEnabled : helpDisabled)
        }
    }

    /// Standard collapsible-section header: chevron + title; the whole header
    /// is a button that toggles `isExpanded`. When collapsed, shows the count
    /// so the user knows what's hidden. Optional trailing view sits on the
    /// right (e.g. the "Show top N" toggle and the ⋯ action button).
    @ViewBuilder
    private func collapsibleHeader<Trailing: View>(
        title: String,
        count: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title)
                    if !isExpanded.wrappedValue {
                        Text("(\(count))")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
    }

    private var unreadCount: Int {
        store.papers.filter { !store.prefs(for: $0.id).read }.count
    }

    private var starredCount: Int {
        store.papers.filter { store.prefs(for: $0.id).saved }.count
    }

    private var highlyRatedCount: Int {
        store.papers.filter { (store.prefs(for: $0.id).rating ?? 0) >= 4 }.count
    }
}
