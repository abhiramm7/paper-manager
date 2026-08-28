import SwiftUI

/// Sheet that runs `LibraryStore.proposeTagMerges()`, displays the LLM-proposed
/// merges, lets the user check/uncheck each one, then applies them.
struct ConsolidateTagsSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var proposals: [Proposal] = []
    @State private var errorMessage: String?
    @State private var alsoRetag: Bool = false

    enum Phase { case loading, ready, applying, done }

    /// Local wrapper so we can attach a per-row "approved" toggle.
    struct Proposal: Identifiable {
        let id: UUID
        var merge: LLMTagger.TagMergeProposal
        var approved: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 360, idealHeight: 520)
        .onAppear(perform: kickoff)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Consolidate tags")
                .font(.title3.weight(.semibold))
            Text("Looks for near-duplicate tags in your library and proposes merges. Conservative on purpose — only merges semantically equivalent tags.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Asking \(store.llmProvider.label)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .applying:
            if let err = errorMessage {
                ScrollView {
                    Text(err)
                        .foregroundStyle(.red)
                        .padding()
                }
            } else if proposals.isEmpty {
                ContentUnavailableView(
                    "Nothing to consolidate",
                    systemImage: "sparkles",
                    description: Text("The LLM didn't find any near-duplicate tags. Your vocabulary is already clean."))
            } else {
                VStack(spacing: 0) {
                    List {
                        ForEach($proposals) { $p in
                            MergeProposalRow(
                                from: p.merge.from,
                                into: p.merge.into,
                                reason: p.merge.reason,
                                approved: $p.approved,
                                prefix: "#")
                        }
                    }
                    .listStyle(.inset)
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Toggle(isOn: $alsoRetag) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Also re-tag the library with the cleaner vocabulary")
                                Text("Runs the tagger on all \(store.papers.count) paper(s) afterwards. With Claude this is ~\(store.papers.count * 5)s; with Ollama, several minutes. You can cancel from the toolbar.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        case .done:
            ContentUnavailableView(
                "Done",
                systemImage: "checkmark.seal",
                description: Text(alsoRetag
                                  ? "Tags were merged. Re-tagging the library now — watch the toolbar."
                                  : "Tags were merged across the library."))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .applying)
            if phase == .ready, !proposals.isEmpty {
                Button(applyLabel) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0)
            } else if phase == .done {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var selectedCount: Int { proposals.filter { $0.approved }.count }

    private var applyLabel: String {
        let n = selectedCount
        return n == 1 ? "Apply 1 merge" : "Apply \(n) merges"
    }

    private func kickoff() {
        phase = .loading
        errorMessage = nil
        // Task inherits the view's main actor, so state writes are direct.
        Task {
            do {
                let merges = try await store.proposeTagMerges()
                proposals = merges.map { Proposal(id: UUID(), merge: $0, approved: true) }
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .ready
        }
    }

    private func apply() {
        let approved = proposals.filter { $0.approved }.map { $0.merge }
        guard !approved.isEmpty else { return }
        phase = .applying
        store.applyTagMerges(approved)
        if alsoRetag {
            // Re-tag every paper. tagAllUntagged would skip already-tagged
            // ones; force a refresh instead.
            for id in store.papers.map(\.id) {
                store.generateTagsInBackground(for: id, force: true, mode: .fast)
            }
        }
        phase = .done
    }
}

// Row UI moved to MergeProposalRow (shared with ConsolidateAuthorsSheet).
