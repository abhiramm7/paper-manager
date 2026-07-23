import SwiftUI

/// Review sheet for likely-duplicate papers already in the library (same work,
/// different files — so ingest's byte-hash dedupe missed them). Per cluster
/// the user picks which copy to keep; the rest move to the Trash, and the
/// keeper inherits their tags / rating / saved state.
struct DuplicateReviewSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// keeper choice per cluster, keyed by the cluster's first paper id.
    @State private var keepChoice: [String: String] = [:]
    @State private var statusLine: String = ""

    private var groups: [[Paper]] { store.duplicateGroups }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 440, idealHeight: 580)
        .onAppear(perform: primeChoices)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Possible duplicates")
                .font(.title3.weight(.semibold))
            Text("These papers look like the same work stored more than once — matched by arXiv id, DOI, or title (not by file, so re-downloads and preprint-vs-published copies show up). Pick the copy to keep in each group; the rest move to the Trash and the keeper inherits their tags and rating.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "No duplicates found",
                systemImage: "checkmark.seal",
                description: Text("Every paper in your library looks distinct."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        clusterCard(group)
                    }
                }
                .padding(16)
            }
        }
    }

    private func clusterCard(_ group: [Paper]) -> some View {
        let key = group.first?.id ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text("^[\(group.count) copy](inflect: true) of the same paper")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(group) { p in
                copyRow(p, clusterKey: key, isKeeper: keepChoice[key] == p.id)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func copyRow(_ p: Paper, clusterKey: String, isKeeper: Bool) -> some View {
        Button {
            keepChoice[clusterKey] = p.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isKeeper ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.callout).lineLimit(2)
                    Text(metaLine(p))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isKeeper {
                    Text("Keep").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                } else {
                    Text("Trash").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One-line evidence to pick a keeper: rating, source, year, pages, added.
    private func metaLine(_ p: Paper) -> String {
        var bits: [String] = []
        let e = store.prefs(for: p.id)
        if let r = e.rating, r > 0 { bits.append("★\(r)") }
        if e.saved { bits.append("saved") }
        if !p.authors.isEmpty { bits.append(p.authorsShort) }
        if let y = p.year { bits.append(String(y)) }
        if let pages = p.pages { bits.append("\(pages)p") }
        if !p.source.isEmpty { bits.append(p.source) }
        let tagCount = p.allTags.count
        if tagCount > 0 { bits.append("\(tagCount) tag\(tagCount == 1 ? "" : "s")") }
        return bits.joined(separator: "  ·  ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !statusLine.isEmpty {
                Label(statusLine, systemImage: "checkmark.circle")
                    .foregroundStyle(.green).font(.callout).lineLimit(1)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Resolve \(groups.count) group\(groups.count == 1 ? "" : "s")") {
                resolveAll()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(groups.isEmpty)
            .help("Keep the selected copy in each group and move the rest to the Trash")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func primeChoices() {
        for group in groups {
            let key = group.first?.id ?? ""
            if keepChoice[key] == nil {
                keepChoice[key] = bestKeeper(group).id
            }
        }
    }

    /// Default keeper: highest rating, then saved, then most tags, then most
    /// pages (full paper over a truncated copy), then most recently added.
    private func bestKeeper(_ group: [Paper]) -> Paper {
        group.max { a, b in
            let ea = store.prefs(for: a.id), eb = store.prefs(for: b.id)
            if (ea.rating ?? 0) != (eb.rating ?? 0) { return (ea.rating ?? 0) < (eb.rating ?? 0) }
            if ea.saved != eb.saved { return !ea.saved && eb.saved }
            if a.allTags.count != b.allTags.count { return a.allTags.count < b.allTags.count }
            if (a.pages ?? 0) != (b.pages ?? 0) { return (a.pages ?? 0) < (b.pages ?? 0) }
            return (a.addedDate ?? .distantPast) < (b.addedDate ?? .distantPast)
        } ?? group[0]
    }

    private func resolveAll() {
        var resolved = 0
        for group in groups {
            let key = group.first?.id ?? ""
            let keeper = keepChoice[key] ?? bestKeeper(group).id
            let losers = group.map(\.id).filter { $0 != keeper }
            guard !losers.isEmpty else { continue }
            store.resolveDuplicates(keep: keeper, trash: losers)
            resolved += 1
        }
        statusLine = "Resolved \(resolved) group\(resolved == 1 ? "" : "s")."
        // store.duplicateGroups is now recomputed/empty; keep the sheet open so
        // the user sees the confirmation, then they can close.
    }
}
