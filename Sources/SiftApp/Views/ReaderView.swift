import SwiftUI
import PDFKit

/// Shared height for the two reader-pane headers (PDF side + chat side) so
/// their bottom dividers line up across the split instead of shifting.
private let readerHeaderHeight: CGFloat = 44

/// Live bridge between the AppKit PDFView and SwiftUI: exposes the view for
/// actions (highlight, jump) plus the bits of state the reader bar needs.
final class PDFViewProxy: ObservableObject {
    weak var pdfView: PDFView?
    /// True while the user has text selected in the PDF.
    @Published var hasSelection = false
    /// Bumped after every highlight add/remove so derived lists recompute.
    @Published var annotationsVersion = 0
    /// Bumped once the PDFView's document is attached. `pdfView` itself is a
    /// non-published weak ref, so views that derive from the document (TOC,
    /// highlight count) need this published signal to recompute after load —
    /// without it the TOC/Highlights buttons stay disabled forever.
    @Published var documentVersion = 0
}

/// Reader tab: the paper's PDF (with highlighting) alongside an LLM chat
/// grounded in the document text. Opened from PaperDetail's "Read & Ask"
/// (⇧⌘R); hosted as a tab in ContentView, one per paper.
struct ReaderView: View {
    @EnvironmentObject var store: LibraryStore
    let paperId: String

    @StateObject private var proxy = PDFViewProxy()
    @State private var showHighlights = false
    @State private var showTOC = false

    private var paper: Paper? { store.papers.first(where: { $0.id == paperId }) }

    var body: some View {
        if let paper {
            HSplitView {
                VStack(spacing: 0) {
                    readerBar(paper)
                    Divider()
                    PDFKitView(url: store.config.pdfURL(paper.id), proxy: proxy)
                }
                .frame(minWidth: 420, idealWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                ReaderChatPanel(paper: paper)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 560, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                "Paper not found",
                systemImage: "questionmark.folder",
                description: Text("It may have been deleted from the library."))
        }
    }

    // MARK: - Reader bar (title + highlight controls)

    private func readerBar(_ paper: Paper) -> some View {
        HStack(spacing: 10) {
            Button {
                showTOC = true
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .disabled(tocEntries.isEmpty)
            .popover(isPresented: $showTOC, arrowEdge: .bottom) {
                tocList
            }
            .help(tocEntries.isEmpty
                  ? "This PDF has no table of contents"
                  : "Table of contents — click a heading to jump to it")

            Text(paper.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(paper.title)
            Spacer()
            Menu {
                highlightColorButton("Yellow", .systemYellow)
                highlightColorButton("Green", .systemGreen)
                highlightColorButton("Blue", .systemBlue)
                highlightColorButton("Pink", .systemPink)
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
            .fixedSize()
            .disabled(!proxy.hasSelection)
            .help(proxy.hasSelection
                  ? "Highlight the selected text"
                  : "Select text in the PDF first, then highlight it")

            Button {
                showHighlights = true
            } label: {
                Label("\(highlights.count)", systemImage: "list.bullet.clipboard")
            }
            .disabled(highlights.isEmpty)
            .popover(isPresented: $showHighlights, arrowEdge: .bottom) {
                highlightsList
            }
            .help(highlights.isEmpty
                  ? "No highlights yet"
                  : "Show saved highlights — click one to jump to it")
        }
        .padding(.horizontal, 12)
        .frame(height: readerHeaderHeight)
    }

    /// A colored menu item for the highlight picker — a filled swatch next to
    /// the color name, so the menu shows the actual colors instead of four
    /// identical text rows.
    private func highlightColorButton(_ name: String, _ color: NSColor) -> some View {
        Button {
            addHighlight(color)
        } label: {
            Label {
                Text(name)
            } icon: {
                Image(systemName: "square.fill")
                    .foregroundStyle(Color(nsColor: color))
            }
        }
    }

    // MARK: - Table of contents

    /// One flattened outline entry: a heading, its nesting depth (for
    /// indentation), and where it points.
    struct TOCEntry: Identifiable {
        let id = UUID()
        let label: String
        let level: Int
        let destination: PDFDestination
        let pageLabel: String
    }

    /// The PDF's embedded outline, flattened depth-first. Empty when the PDF
    /// ships without an outline (common for arXiv preprints). Tied to
    /// `annotationsVersion` only indirectly — the document is stable, so this
    /// is cheap and recomputed on demand while the popover is open.
    private var tocEntries: [TOCEntry] {
        _ = proxy.documentVersion   // recompute once the document attaches
        guard let doc = proxy.pdfView?.document, let root = doc.outlineRoot else { return [] }
        var out: [TOCEntry] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let dest = child.destination, !label.isEmpty {
                    let pageLabel: String = {
                        guard let page = dest.page,
                              let idx = doc.index(for: page) as Int? else { return "" }
                        return page.label ?? "\(idx + 1)"
                    }()
                    out.append(TOCEntry(label: label, level: level,
                                        destination: dest, pageLabel: pageLabel))
                }
                if child.numberOfChildren > 0 {
                    walk(child, level: level + 1)
                }
            }
        }
        walk(root, level: 0)
        return out
    }

    private var tocList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Contents")
                .font(.headline)
                .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tocEntries) { entry in
                        Button {
                            proxy.pdfView?.go(to: entry.destination)
                            showTOC = false
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.label)
                                    .font(entry.level == 0 ? .callout.weight(.medium) : .caption)
                                    .foregroundStyle(entry.level == 0 ? .primary : .secondary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .padding(.leading, CGFloat(entry.level) * 14)
                                Spacer(minLength: 6)
                                if !entry.pageLabel.isEmpty {
                                    Text(entry.pageLabel)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 320)
    }

    // MARK: - Highlights

    /// Every highlight annotation in the document, in page order. Reading
    /// `annotationsVersion` ties this to the proxy so add/remove refreshes
    /// the bar count and the popover list.
    private var highlights: [(pageIndex: Int, page: PDFPage, annotation: PDFAnnotation)] {
        _ = proxy.annotationsVersion
        _ = proxy.documentVersion
        guard let doc = proxy.pdfView?.document else { return [] }
        var out: [(Int, PDFPage, PDFAnnotation)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.type == "Highlight" {
                out.append((i, page, a))
            }
        }
        return out
    }

    private var highlightsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Highlights")
                .font(.headline)
                .padding(12)
            Divider()
            if highlights.isEmpty {
                Text("No highlights yet — select text in the PDF and press Highlight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(highlights.enumerated()), id: \.offset) { _, h in
                            highlightRow(h)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
    }

    private func highlightRow(
        _ h: (pageIndex: Int, page: PDFPage, annotation: PDFAnnotation)
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(nsColor: h.annotation.color))
                .frame(width: 8, height: 8)
                .padding(.top, 3)
            Button {
                jump(to: h)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text((h.annotation.contents?.isEmpty == false)
                         ? h.annotation.contents! : "(highlight)")
                        .font(.caption)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text("Page \(h.pageIndex + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                remove(h)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Remove this highlight")
        }
        .padding(10)
    }

    /// Highlight the current selection, one annotation per selected line
    /// (matches how Preview highlights multi-line selections).
    private func addHighlight(_ color: NSColor) {
        guard let pdfView = proxy.pdfView,
              let doc = pdfView.document,
              let sel = pdfView.currentSelection else { return }
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                let a = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                a.color = color
                a.contents = line.string ?? ""   // snippet for the list
                page.addAnnotation(a)
            }
        }
        pdfView.clearSelection()
        persist(doc)
    }

    private func remove(_ h: (pageIndex: Int, page: PDFPage, annotation: PDFAnnotation)) {
        guard let doc = proxy.pdfView?.document else { return }
        h.page.removeAnnotation(h.annotation)
        persist(doc)
    }

    private func jump(to h: (pageIndex: Int, page: PDFPage, annotation: PDFAnnotation)) {
        proxy.pdfView?.go(to: PDFDestination(
            page: h.page,
            at: CGPoint(x: h.annotation.bounds.minX, y: h.annotation.bounds.maxY)))
        showHighlights = false
    }

    /// Write annotations into paper.pdf itself. The iCloud file is canonical,
    /// so highlights sync with the library and show up in Preview and any
    /// other PDF reader too.
    private func persist(_ doc: PDFDocument) {
        let url = store.config.pdfURL(paperId)
        if !doc.write(to: url) {
            store.showToast("Couldn't save highlights to the PDF.")
        }
        proxy.annotationsVersion += 1
    }
}

/// Thin wrapper around PDFKit's PDFView. The coordinator wires selection
/// notifications into the proxy so SwiftUI can enable/disable the
/// Highlight control.
struct PDFKitView: NSViewRepresentable {
    let url: URL
    let proxy: PDFViewProxy

    func makeCoordinator() -> Coordinator { Coordinator(proxy: proxy) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        proxy.pdfView = view   // weak, non-published — safe during view update
        // Signal the document is attached so TOC/highlights recompute. Async
        // to avoid "Publishing changes from within view updates".
        DispatchQueue.main.async { proxy.documentVersion += 1 }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            DispatchQueue.main.async { proxy.documentVersion += 1 }
        }
    }

    final class Coordinator: NSObject {
        let proxy: PDFViewProxy
        init(proxy: PDFViewProxy) { self.proxy = proxy }

        @objc func selectionChanged(_ note: Notification) {
            let has = ((note.object as? PDFView)?.currentSelection?.string?.isEmpty == false)
            if proxy.hasSelection != has {
                proxy.hasSelection = has
            }
        }
    }
}

/// Chat panel: conversation history + input. State lives in LibraryStore
/// (`paperChats`) so a conversation survives closing and reopening the tab.
struct ReaderChatPanel: View {
    @EnvironmentObject var store: LibraryStore
    let paper: Paper

    @State private var draft: String = ""

    private var messages: [LLMTagger.ChatMessage] { store.paperChats[paper.id] ?? [] }
    private var inFlight: Bool { store.chatInFlight.contains(paper.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputRow
        }
        .background(.background)
    }

    private var header: some View {
        HStack {
            Label("Ask this paper", systemImage: "sparkles")
                .font(.callout.weight(.semibold))
            Spacer()
            if !messages.isEmpty {
                Button {
                    store.clearChat(paperId: paper.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear this conversation")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: readerHeaderHeight)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        emptyHint
                    }
                    ForEach(messages) { m in
                        bubble(m)
                    }
                    if inFlight {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading the paper…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id("in-flight")
                    }
                }
                .padding(12)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: inFlight) { _, now in
                if now {
                    withAnimation { proxy.scrollTo("in-flight", anchor: .bottom) }
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask anything about this paper — answers are grounded in the PDF's text.")
            Text("Try: \"What problem does this solve?\" · \"Summarize the method\" · \"What are the limitations?\"")
            if !store.llmProvider.isAvailable {
                Label("No LLM detected — configure one in Settings → Auto-tagging.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func bubble(_ m: LLMTagger.ChatMessage) -> some View {
        let isUser = m.role == .user
        // User messages: accent tint, right-aligned, inset from the left.
        // Assistant: neutral, left-aligned, inset from the right. The
        // asymmetry alone signals who's speaking, so no per-bubble label.
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 28) }
            Text(markdown(m.text))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    isUser ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12))
            if !isUser { Spacer(minLength: 28) }
        }
        .id(m.id)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this paper…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(send)
                .disabled(inFlight)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(inFlight || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Send (↩)")
        }
        .padding(10)
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !inFlight else { return }
        draft = ""
        store.askPaper(q, paperId: paper.id)
    }
}
