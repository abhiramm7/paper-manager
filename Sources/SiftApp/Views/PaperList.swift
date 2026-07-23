import SwiftUI
import AppKit

struct PaperList: View {
    @EnvironmentObject var store: LibraryStore
    let papers: [Paper]
    @Binding var selectedID: String?
    @Binding var searchText: String
    @Binding var sortOrder: [KeyPathComparator<Paper>]
    @State private var pendingDeleteID: String?

    var body: some View {
        Table(of: Paper.self, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("") { p in
                let saved = store.prefs(for: p.id).saved
                Image(systemName: saved ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(saved ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 14)
            }
            .width(20)

            TableColumn("") { p in
                let read = store.prefs(for: p.id).read
                Circle()
                    .fill(read ? Color.clear : Color.accentColor)
                    .frame(width: 7, height: 7)
                    .help(read ? "Read" : "Unread")
            }
            .width(14)

            TableColumn("Title", value: \Paper.titleSort) { p in
                HStack(spacing: 6) {
                    Text(p.title)
                        .font(.body)
                        .lineLimit(2)
                    // While the LLM is filling in this paper, show a spinner +
                    // "tagging…" so a freshly-added row (still showing its
                    // filename as the title) doesn't look broken or stuck.
                    if store.taggingInFlight.contains(p.id) {
                        ProgressView().controlSize(.small)
                        Text("tagging…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onHover { hovering in
                    // The double-click-to-open gesture is invisible without
                    // a cursor change — Table doesn't inherit NSTableView's
                    // built-in pointing-hand on clickable cells.
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }

            TableColumn("Authors") { p in
                Text(p.authorsShort).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 160)

            TableColumn("★") { p in
                let r = store.prefs(for: p.id).rating ?? 0
                if r > 0 {
                    HStack(spacing: 0) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= r ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(i <= r ? .yellow : Color.secondary.opacity(0.25))
                        }
                    }
                    .help("\(r) star\(r == 1 ? "" : "s")")
                } else {
                    Text("").frame(maxWidth: .infinity)
                }
            }
            .width(min: 60, ideal: 64, max: 72)

            TableColumn("Year", value: \Paper.yearSort) { p in
                Text(p.year.map(String.init) ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 40, ideal: 50, max: 70)

            TableColumn("Added", value: \Paper.addedSort) { p in
                Text(Self.shortDate(p.addedDate))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("Kind") { p in
                Label(p.kind.label, systemImage: p.kind.symbol)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help(p.kind.label)
            }
            .width(min: 32, ideal: 36, max: 50)
        } rows: {
            ForEach(sorted) { p in
                TableRow(p)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let p = store.papers.first(where: { $0.id == id }) {
                rowMenu(for: p)
            }
        } primaryAction: { ids in
            // Double-click opens the built-in reader (highlights + AI Q&A).
            // Preview is still available from the right-click menu.
            if let id = ids.first {
                store.openReader(for: id)
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search title, authors, tags")
        .overlay {
            if papers.isEmpty {
                ContentUnavailableView(
                    "No papers",
                    systemImage: "tray",
                    description: Text(emptyMessage)
                )
            }
        }
        .onDeleteCommand {
            if let id = selectedID { pendingDeleteID = id }
        }
        .alert(
            "Move paper to Trash?",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            presenting: pendingDeleteID
        ) { id in
            Button("Move to Trash", role: .destructive) {
                let nextSelection = neighbor(of: id)
                store.deletePaper(id)
                selectedID = nextSelection
            }
            Button("Cancel", role: .cancel) {}
        } message: { id in
            if let p = store.papers.first(where: { $0.id == id }) {
                Text("\"\(p.title)\" will be moved to the Trash. The PDF and metadata are reversible from the Finder until you empty the Trash.")
            } else {
                Text("The paper will be moved to the Trash.")
            }
        }
    }

    /// Pick the next selection target after deleting `id`: prefer the row below,
    /// fall back to the one above, then nil.
    private func neighbor(of id: String) -> String? {
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return nil }
        if i + 1 < sorted.count { return sorted[i + 1].id }
        if i - 1 >= 0 { return sorted[i - 1].id }
        return nil
    }

    private var sorted: [Paper] {
        // sortOrder empty means the caller wants a prefs-aware sort (rating).
        // Otherwise apply the standard KeyPath sort over Paper fields.
        guard sortOrder.isEmpty else { return papers.sorted(using: sortOrder) }
        // Rating sort: highest first; ties broken by added date (newest first).
        return papers.sorted { lhs, rhs in
            let lr = store.prefs(for: lhs.id).rating ?? 0
            let rr = store.prefs(for: rhs.id).rating ?? 0
            if lr != rr { return lr > rr }
            return (lhs.addedDate ?? .distantPast) > (rhs.addedDate ?? .distantPast)
        }
    }

    private var emptyMessage: String {
        if store.papers.isEmpty {
            return "Drop a PDF onto the window or press ⌘N to add one."
        } else {
            return "No items match your filters."
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func shortDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        return shortDateFormatter.string(from: d)
    }

    @ViewBuilder
    private func rowMenu(for p: Paper) -> some View {
        let prefs = store.prefs(for: p.id)
        Button("Read & Ask") { store.openReader(for: p.id) }
        Button("Open in Preview") { store.openInPreview(p) }
        Button("Reveal in Finder") { store.revealInFinder(p) }
        ShareLink("Share…", item: store.config.pdfURL(p.id))
        Divider()
        Button(prefs.read ? "Mark as Unread" : "Mark as Read") {
            store.setRead(!prefs.read, for: p.id)
        }
        Button(prefs.saved ? "Remove from Saved" : "Save") {
            store.setStarred(!prefs.saved, for: p.id)
        }
        Menu("Rate") {
            ForEach(1...5, id: \.self) { i in
                Button("\(i) star\(i == 1 ? "" : "s")") {
                    store.setRating(i, for: p.id)
                }
            }
            Divider()
            Button("Clear rating") { store.setRating(nil, for: p.id) }
        }
        Menu("Kind") {
            ForEach(PaperKind.allCases, id: \.self) { k in
                Button {
                    store.setKind(k, for: p.id)
                } label: {
                    if k == p.kind {
                        Label(k.label, systemImage: "checkmark")
                    } else {
                        Label(k.label, systemImage: k.symbol)
                    }
                }
            }
        }
        Divider()
        if let arxiv = p.arxiv_id, !arxiv.isEmpty {
            Button("Open arXiv page") {
                if let url = URL(string: "https://arxiv.org/abs/\(arxiv)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        if let doi = p.doi, !doi.isEmpty {
            Button("Open DOI") {
                if let url = URL(string: "https://doi.org/\(doi)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) {
            pendingDeleteID = p.id
        }
    }
}
