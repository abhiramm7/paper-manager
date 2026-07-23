import SwiftUI

/// Review sheet for watched-folder scan results. Two groups:
///  - New PDFs: check the ones you want, hit Import.
///  - Already in Sift: content-hash duplicates of library papers — each can
///    be moved to the Trash (recoverable) to clean up the source folder.
struct ImportReviewSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// Selected FoundPDF ids (paths) among the new files.
    @State private var selected: Set<String> = []
    @State private var isImporting = false
    @State private var importProgress: (done: Int, total: Int)? = nil
    @State private var statusLine: String = ""
    /// Files queued for the trash confirmation alert (one or many).
    @State private var trashTargets: [FoundPDF] = []

    private var newFiles: [FoundPDF] { store.foundPDFs.filter { !$0.isInLibrary } }
    private var dupFiles: [FoundPDF] { store.foundPDFs.filter { $0.isInLibrary } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { !trashTargets.isEmpty },
                set: { if !$0 { trashTargets = [] } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                for f in trashTargets { store.trashFoundPDF(f) }
                trashTargets = []
            }
            Button("Cancel", role: .cancel) { trashTargets = [] }
        } message: {
            if trashTargets.count == 1, let f = trashTargets.first {
                Text("\"\(f.fileName)\" is already in your Sift library. The source file will move to the Trash; the library copy is untouched.")
            } else {
                Text("\(trashTargets.count) files are already in your Sift library. The source files will move to the Trash; the library copies are untouched.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Import from watched folders")
                    .font(.title3.weight(.semibold))
                Spacer()
                assessButton
                Button {
                    Task { await store.scanWatchedFolders() }
                } label: {
                    if store.isScanningFolders {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isScanningFolders || isImporting)
                .help("Rescan the watched folders now")
            }
            Text("PDFs found in your watched folders. Check the ones to import. Assess with AI reads each new PDF and recommends import or skip — advisory only, you decide. Files already in Sift (matched by content, not name) can be moved to the Trash to tidy the folder — the library copy stays.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// "Assess with AI" — runs the LLM over unassessed new PDFs. Shows inline
    /// progress + a stop button while running.
    @ViewBuilder
    private var assessButton: some View {
        if let p = store.assessProgress {
            HStack(spacing: 6) {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("\(p.done)/\(p.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    store.cancelAssessment()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop assessing — verdicts so far are kept")
            }
        } else {
            let unassessed = newFiles.filter { assessment($0) == nil }.count
            Button {
                store.assessFoundPDFs()
            } label: {
                Label("Assess with AI", systemImage: "sparkles")
            }
            .disabled(!store.llmProvider.isAvailable || isImporting || unassessed == 0)
            .help(!store.llmProvider.isAvailable
                  ? "No LLM detected. Open Settings to choose Claude or Ollama."
                  : unassessed == 0
                  ? (newFiles.isEmpty ? "No new PDFs to assess." : "All new PDFs are assessed.")
                  : "Read each new PDF with \(store.llmProvider.label) and recommend import or skip")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.foundPDFs.isEmpty {
            ContentUnavailableView(
                store.isScanningFolders ? "Scanning…" : "No PDFs found",
                systemImage: "tray",
                description: Text(store.isScanningFolders
                    ? "Checking the watched folders."
                    : "Nothing to review — the watched folders have no PDFs. Manage folders in Settings → Watched folders."))
        } else {
            List {
                if !newFiles.isEmpty {
                    Section {
                        ForEach(newFiles) { f in newRow(f) }
                    } header: {
                        HStack {
                            Text("New (\(newFiles.count))")
                            Spacer()
                            if newFiles.contains(where: { assessment($0)?.shouldImport == true }) {
                                Button("Select recommended") {
                                    selected = Set(newFiles
                                        .filter { assessment($0)?.shouldImport == true }
                                        .map { $0.id })
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .disabled(isImporting)
                                .help("Check every PDF the AI recommends importing")
                            }
                            Button(allNewSelected ? "Deselect all" : "Select all") {
                                if allNewSelected {
                                    selected.removeAll()
                                } else {
                                    selected = Set(newFiles.map { $0.id })
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(isImporting)
                        }
                    }
                }
                if !dupFiles.isEmpty {
                    Section {
                        ForEach(dupFiles) { f in dupRow(f) }
                    } header: {
                        HStack {
                            Text("Already in Sift (\(dupFiles.count))")
                            Spacer()
                            Button("Trash all…") {
                                trashTargets = dupFiles
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .disabled(isImporting)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func newRow(_ f: FoundPDF) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected.contains(f.id) },
                set: { on in
                    if on { selected.insert(f.id) } else { selected.remove(f.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isImporting)
            fileInfo(f)
            verdictBadge(f)
        }
        .padding(.vertical, 2)
    }

    /// LLM verdict pill. Green "Paper"/"Book"/… for import, orange "Skip"
    /// otherwise; the reason lives in the tooltip. Nothing until assessed.
    @ViewBuilder
    private func verdictBadge(_ f: FoundPDF) -> some View {
        if let a = assessment(f) {
            Text(a.shouldImport ? (a.kind?.label ?? "Import") : "Skip")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    (a.shouldImport ? Color.green : Color.orange).opacity(0.15),
                    in: Capsule())
                .foregroundStyle(a.shouldImport ? .green : .orange)
                .help(a.reason.isEmpty
                      ? (a.shouldImport ? "Recommended for import" : "Probably not library material")
                      : a.reason)
        }
    }

    private func assessment(_ f: FoundPDF) -> LLMTagger.ImportAssessment? {
        store.importAssessments[f.sha256]
    }

    private func dupRow(_ f: FoundPDF) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Already in the library — importing again would be a no-op")
            fileInfo(f)
            Button(role: .destructive) {
                trashTargets = [f]
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(isImporting)
            .help("Move this source file to the Trash — the library copy stays")
        }
        .padding(.vertical, 2)
    }

    private func fileInfo(_ f: FoundPDF) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(f.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(folderLabel(f))  ·  \(f.sizeLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(f.url.path)
    }

    private func folderLabel(_ f: FoundPDF) -> String {
        (f.url.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let p = importProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(p.done)/\(p.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !statusLine.isEmpty {
                Label(statusLine, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .lineLimit(1)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isImporting
                   ? "Importing…"
                   : "Import \(selected.count) PDF\(selected.count == 1 ? "" : "s")") {
                Task { await importSelected() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isImporting || selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private var allNewSelected: Bool {
        !newFiles.isEmpty && newFiles.allSatisfy { selected.contains($0.id) }
    }

    private func importSelected() async {
        let targets = newFiles.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        isImporting = true
        statusLine = ""
        importProgress = (0, targets.count)
        defer {
            isImporting = false
            importProgress = nil
        }

        let ingest = IngestService(config: store.config)
        var added = 0
        var failed = 0
        for (i, f) in targets.enumerated() {
            do {
                let result = try await ingest.addLocalPDF(at: f.url)
                if !result.alreadyExisted {
                    // The LLM read this PDF during assessment — carry its kind
                    // verdict over so a 30-page book chapter isn't misfiled as
                    // a paper by the page-count heuristic.
                    if let kind = assessment(f)?.kind {
                        store.setKind(kind, for: result.paperId)
                    }
                    store.generateTagsInBackground(for: result.paperId)
                }
                added += 1
            } catch {
                failed += 1
            }
            importProgress = (i + 1, targets.count)
        }
        selected.removeAll()
        statusLine = failed == 0
            ? "Imported \(added) PDF\(added == 1 ? "" : "s")."
            : "Imported \(added), \(failed) failed."
        await store.rescan()
        // Re-scan folders so freshly imported files move to "Already in Sift"
        // — from there the user can trash the source copies if they want.
        await store.scanWatchedFolders()
    }
}
