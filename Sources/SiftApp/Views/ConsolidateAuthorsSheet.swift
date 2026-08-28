import SwiftUI

/// Sheet that runs `LibraryStore.proposeAuthorMergesThorough(maxPasses:onPass:)`,
/// displays the LLM-proposed merges ("J. Smith" → "John Smith", "Smith, John"
/// → "John Smith"), lets the user check/uncheck each one, then applies them.
struct ConsolidateAuthorsSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var proposals: [Proposal] = []
    @State private var errorMessage: String?
    @State private var progressLabel: String = "Cleaning up author entries…"
    @State private var junkCleaned: Int = 0

    enum Phase { case loading, ready, applying, done }

    struct Proposal: Identifiable {
        let id: UUID
        var merge: LLMTagger.AuthorMergeProposal
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
            Text("Consolidate authors")
                .font(.title3.weight(.semibold))
            Text("First strips \"et al.\" entries that snuck in from PDF metadata, then runs the LLM in up to three passes — each pass sees the simulated result of the previous, so subtle duplicates that only emerge after first-round cleanup still get caught.")
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
                Text(progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Provider: \(store.llmProvider.label)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                    systemImage: "person.2",
                    description: Text(junkCleaned > 0
                        ? "Stripped \"et al.\" from \(junkCleaned) paper\(junkCleaned == 1 ? "" : "s"). The LLM found no further duplicates across \(maxPassesLabel)."
                        : "The LLM found no duplicate author names across \(maxPassesLabel). Your author list is already clean."))
            } else {
                VStack(spacing: 0) {
                    if junkCleaned > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "scissors")
                                .foregroundStyle(.secondary)
                            Text("Stripped \"et al.\" from \(junkCleaned) paper\(junkCleaned == 1 ? "" : "s") before running the LLM.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        Divider()
                    }
                    List {
                        ForEach($proposals) { $p in
                            MergeProposalRow(
                                from: p.merge.from,
                                into: p.merge.into,
                                reason: p.merge.reason,
                                approved: $p.approved)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        case .done:
            ContentUnavailableView(
                "Done",
                systemImage: "checkmark.seal",
                description: Text("Authors were merged across the library."))
        }
    }

    private var maxPassesLabel: String {
        "\(maxPasses) pass\(maxPasses == 1 ? "" : "es")"
    }

    private let maxPasses = 3

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
        progressLabel = "Cleaning up author entries…"
        // Task inherits the view's main actor, so state writes are direct.
        Task {
            // Step 1: strip "et al." junk from disk. Idempotent, fast.
            junkCleaned = store.cleanupAuthorJunk()

            // Step 2: multi-pass LLM consolidation. Each pass sees the
            // simulated result of the previous so subtle duplicates surface.
            do {
                let merges = try await store.proposeAuthorMergesThorough(maxPasses: maxPasses) { pass, total in
                    self.progressLabel = "LLM pass \(pass) of \(total)…"
                }
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
        store.applyAuthorMerges(approved)
        phase = .done
    }
}

// Row UI moved to MergeProposalRow (shared with ConsolidateTagsSheet).
