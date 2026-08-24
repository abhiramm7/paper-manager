import Foundation
import PDFKit

/// Generates categorized topical tags (topics, application areas, methods) for
/// a paper using whichever LLM is available locally. Preference:
/// Claude CLI > Ollama chat model > none. Both are optional — if neither is
/// present, ingest still works; tags are just empty.
enum LLMTagger {

    /// Default cap on PDF text. ~200k chars ≈ 50k tokens, well within Claude's
    /// 200k-token context. See `maxCharsForProvider(_:)` for per-provider caps.
    static let maxPromptChars = 200_000

    /// Char cap per provider. Claude can swallow whole papers; small local Ollama
    /// models choke on long contexts (and run slow). We trim to ~3k tokens for
    /// Ollama — enough for title page + abstract + first sections.
    static func maxCharsForProvider(_ p: Provider) -> Int {
        switch p {
        case .claude: return maxPromptChars              // ~200k chars / ~50k tokens
        case .ollama: return 12_000                       // ~12k chars / ~3k tokens
        case .unavailable: return 0
        }
    }

    enum Provider: Equatable {
        case claude(binary: URL, model: String?)  // model = nil ⇒ CLI default
        case ollama(model: String)
        case unavailable

        var label: String {
            switch self {
            case .claude(_, let m): return "Claude CLI (\(m ?? "default model"))"
            case .ollama(let m): return "Ollama (\(m))"
            case .unavailable: return "no LLM detected"
            }
        }

        var isAvailable: Bool {
            if case .unavailable = self { return false }
            return true
        }

        /// What every greyed-out AI control says. Six views had six slightly
        /// different sentences for the same state; this is the one.
        static let missingHint =
            "No LLM detected — connect Claude or Ollama in Settings → Auto-tagging."

    }

    /// LLM-extracted info: title, authors, summary, categorized tags, folder.
    struct ExtractedInfo: Equatable {
        var title: String?           // human-readable, NOT kebab-case
        var authors: [String]?       // ["First Last", "Other Person", ...]
        var summary: String?         // markdown — written to summary.md
        var topics: [String]
        var applicationAreas: [String]
        var methods: [String]
        var folder: String?          // human-readable subject area, e.g. "Machine Learning"

        /// Flat union of tags, deduped — for `auto.tags` (legacy/search).
        var union: [String] {
            var seen = Set<String>()
            var out: [String] = []
            for t in topics + applicationAreas + methods {
                if seen.insert(t).inserted { out.append(t) }
            }
            return out
        }

        var isEmpty: Bool {
            (title?.isEmpty ?? true)
                && (authors?.isEmpty ?? true)
                && (summary?.isEmpty ?? true)
                && topics.isEmpty && applicationAreas.isEmpty && methods.isEmpty
                && (folder?.isEmpty ?? true)
        }
    }

    /// Claude model aliases users can pick from in Settings.
    static let claudeModelChoices = ["default", "haiku", "sonnet", "opus"]

    /// LLM verdict on whether a found PDF belongs in the library.
    /// Advisory only — the user always makes the final call in the review sheet.
    struct ImportAssessment: Equatable, Hashable, Sendable {
        var shouldImport: Bool
        var kind: PaperKind?     // best-guess kind when shouldImport
        var title: String?       // real title if the LLM spotted one
        var reason: String       // short rationale, shown as a tooltip
    }

    /// One proposed tag merge from the consolidate-tags pass.
    /// `from` are the tags to be replaced (could be 1 or more); `into` is the
    /// canonical tag they all become. `reason` is a short LLM rationale.
    struct TagMergeProposal: Identifiable, Hashable {
        let id = UUID()
        var from: [String]
        var into: String
        var reason: String
    }

    /// One proposed author-name merge from the consolidate-authors pass.
    /// Same shape as TagMergeProposal but kept as a separate type because
    /// authors are case-sensitive (we don't lowercase "John Smith") and the
    /// data semantics differ.
    struct AuthorMergeProposal: Identifiable, Hashable {
        let id = UUID()
        var from: [String]
        var into: String
        var reason: String
    }

    /// User preference for which provider to use.
    enum Preference: String, CaseIterable, Identifiable {
        case auto
        case claude
        case ollama
        case off

        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto (prefer Claude)"
            case .claude: return "Claude CLI only"
            case .ollama: return "Ollama only"
            case .off: return "Off"
            }
        }
    }

    enum TaggerError: LocalizedError {
        case noProvider
        case llmFailed(String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "No LLM available. Install Claude Code, or run Ollama with a chat model (e.g. `ollama pull llama3.2:3b`)."
            case .llmFailed(let m): return "LLM call failed: \(m)"
            case .badResponse(let m): return "LLM returned bad response: \(m)"
            }
        }
    }

    static let claudeCandidatePaths = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
    ]

    /// Chat models we'd prefer for tagging, in priority order. ≥3B parameters
    /// is the practical floor — smaller models can't reliably emit the 6-key
    /// JSON schema. MLX variants are faster on Apple Silicon.
    static let ollamaModelPreference = [
        "qwen3.5:4b-mlx",
        "qwen3.5:4b",
        "qwen2.5:3b",
        "qwen2.5",
        "llama3.2:3b",
        "llama3.2",
        "llama3.1:8b",
        "llama3.1",
        "mistral",
        "phi3",
    ]

    /// Resolve the best provider given a preference and optional per-provider
    /// model overrides. Quick — does not invoke the LLM.
    static func detectProvider(
        _ pref: Preference = .auto,
        claudeModel: String? = nil,
        ollamaModel: String? = nil
    ) async -> (Provider, diagnostic: String?) {
        switch pref {
        case .off:
            return (.unavailable, "Auto-tagging is turned off in Settings.")

        case .claude:
            if let bin = resolveClaudeBinary() {
                return (.claude(binary: bin, model: normalizeClaudeModel(claudeModel)), nil)
            }
            return (.unavailable, "Claude CLI not found. Install Claude Code (https://claude.com/claude-code).")

        case .ollama:
            if let model = await resolveOllamaModel(preferred: ollamaModel) {
                return (.ollama(model: model), nil)
            }
            if await ollamaIsRunning() {
                return (.unavailable, "Ollama is running but no chat model is installed. Run `ollama pull llama3.2:3b`.")
            }
            return (.unavailable, "Ollama isn't responding at localhost:11434. Start it with `brew services start ollama`.")

        case .auto:
            if let bin = resolveClaudeBinary() {
                return (.claude(binary: bin, model: normalizeClaudeModel(claudeModel)), nil)
            }
            if let model = await resolveOllamaModel(preferred: ollamaModel) {
                return (.ollama(model: model), nil)
            }
            if await ollamaIsRunning() {
                return (.unavailable, "Ollama is running but no chat model is installed. Run `ollama pull llama3.2:3b` in Terminal — that's all you need for tagging.")
            }
            return (.unavailable, "Install Claude Code, or start Ollama with a chat model:  `ollama pull llama3.2:3b && brew services start ollama`.")
        }
    }

    /// Treat "default"/"" as nil so we don't pass --model.
    static func normalizeClaudeModel(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !r.isEmpty, r.lowercased() != "default" else { return nil }
        return r
    }

    static func ollamaIsRunning() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Detection

    static func resolveClaudeBinary() -> URL? {
        let fm = FileManager.default
        for p in claudeCandidatePaths where fm.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["claude"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0,
               let data = try? pipe.fileHandleForReading.readToEnd(),
               let s = String(data: data, encoding: .utf8) {
                let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        } catch {
            // ignore
        }
        return nil
    }

    static func resolveOllamaModel(preferred: String? = nil) async -> String? {
        let names = await listOllamaModels()
        guard !names.isEmpty else { return nil }
        // User-pinned model wins if it's actually installed.
        if let p = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            if let exact = names.first(where: { $0 == p || $0.hasPrefix("\(p):") }) {
                return exact
            }
            // user-pinned but not installed — fall through to auto.
        }
        for pref in ollamaModelPreference {
            if let match = names.first(where: { $0 == pref || $0.hasPrefix("\(pref):") }) {
                return match
            }
        }
        return names.first(where: { !isEmbedderModel($0) })
    }

    /// All installed Ollama models. Empty if Ollama isn't running.
    static func listOllamaModels() async -> [String] {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        } catch {
            return []
        }
    }

    /// Only chat-suitable Ollama models (filters out embedders).
    static func listOllamaChatModels() async -> [String] {
        await listOllamaModels().filter { !isEmbedderModel($0) }
    }

    static func isEmbedderModel(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("embed") || n.contains("bge-") || n.contains("nomic-embed")
    }

    // MARK: - Text extraction

    /// Extract text from a PDF, bounded by EITHER a page limit or a char cap
    /// (whichever hits first). Walks pages sequentially; handles missing pages.
    static func extractText(from pdf: URL, maxChars: Int = maxPromptChars, maxPages: Int = .max) -> String {
        guard let doc = PDFDocument(url: pdf) else { return "" }
        var out = ""
        out.reserveCapacity(min(maxChars, 32_768))
        // Track the length as we go: `String.count` is O(n), so testing it once
        // per page turned a long book into a quadratic scan.
        var length = 0
        let pageLimit = min(doc.pageCount, maxPages)
        for i in 0..<pageLimit {
            if length >= maxChars { break }
            guard let page = doc.page(at: i), let s = page.string else { continue }
            out += s
            out += "\n"
            length += s.count + 1
        }
        if length > maxChars {
            return String(out.prefix(maxChars))
        }
        return out
    }

    // MARK: - Public API

    /// Extract title + summary + categorized tags + folder. Throws if no provider is available.
    /// `vocabulary` (optional) is a pre-rendered string of existing library tags
    /// that the LLM is told to prefer over inventing new ones.
    /// `existingFolders` (optional) is the library's current folder list. The LLM
    /// is told to reuse one of them when it fits and only invent a new folder
    /// when none does.
    static func extractInfo(
        currentTitle: String,
        text: String,
        vocabulary: String = "",
        existingFolders: [String] = [],
        using provider: Provider
    ) async throws -> ExtractedInfo {
        let prompt = buildPrompt(
            currentTitle: currentTitle,
            text: text,
            vocabulary: vocabulary,
            existingFolders: existingFolders)
        let raw = try await complete(prompt: prompt, using: provider)
        return parseExtractedInfo(from: raw)
    }

    // MARK: - Prompt

    static func buildPrompt(
        currentTitle: String,
        text: String,
        vocabulary: String = "",
        existingFolders: [String] = []
    ) -> String {
        let vocabSection: String
        if vocabulary.isEmpty {
            vocabSection = ""
        } else {
            vocabSection = """


            EXISTING LIBRARY VOCABULARY
            Prefer these tags when they fit the paper. Invent a new tag ONLY when no existing tag captures the concept. If you use a new tag, follow the same kebab-case style.

            \(vocabulary)
            """
        }
        let folderSection: String
        if existingFolders.isEmpty {
            folderSection = """


            EXISTING FOLDERS
            None yet. Choose a broad subject-area name for the "folder" field.
            """
        } else {
            folderSection = """


            EXISTING FOLDERS
            Reuse one of these folders when it fits the paper. Only invent a new folder when none of them is a reasonable fit. New folders follow the same Title-Case human-readable style.

            \(existingFolders.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
        return """
        You extract structured info from academic documents for a personal library.

        Given the existing-title hint and the full text of a paper, book, or report, output a JSON object with SEVEN keys:

        - "title": the document's actual title, as a human-readable string. Look at the first page text and extract the real title. If the existing-title hint already looks like a real title, return it unchanged. If it looks like an arXiv ID (e.g. "2401.12345"), a filename, "Untitled", or otherwise junky, replace it with the title you find in the text. If you cannot find a confident title, return null.
        - "authors": array of human author names in the order they appear ("First Last", e.g. "Ashish Vaswani"). Exclude affiliations, emails, "et al.", and obvious non-people like "Microsoft Word", "LaTeX". Return an empty array if you cannot identify the authors confidently.
        - "summary": a short Markdown summary of the document. Use this exact structure: a "## TL;DR" section with 2 to 4 sentences explaining what the work is and why someone should care, followed by a "## Key contributions" section with 3 to 5 short bullet points. Keep total length under 200 words. Use ordinary English, not jargon. If you cannot summarize confidently, return null.
        - "topics": general subject areas the document fits into (3 to 5 tags). Examples: "machine-learning", "computer-vision", "hydrology", "climate-science", "operating-systems".
        - "application_areas": real-world problems or domains the work targets (1 to 4 tags). Examples: "drug-discovery", "machine-translation", "flood-forecasting", "autonomous-driving". Empty array if the work is purely theoretical.
        - "methods": specific techniques, algorithms, or model classes used or proposed (2 to 6 tags). Examples: "transformers", "graph-neural-networks", "monte-carlo", "kalman-filter", "diffusion-models".
        - "folder": a single Title-Case subject-area folder name for this paper, e.g. "Machine Learning", "Hydrology", "Robotics", "Climate Science". See the EXISTING FOLDERS list below — reuse one of those when it fits; only invent a new folder when none of them fits.

        Rules:
        - Output ONLY a JSON object. No prose before or after, no markdown code fences around the JSON itself.
        - The "title", "authors", "summary", and "folder" values are normal human-readable strings (NOT kebab-case). Tags are lowercase kebab-case, ASCII letters/digits/hyphens only.
        - No author names, no years, no venue or publisher names in the tags.
        - No generic tags like "research", "study", "analysis", "paper", "method".
        - If a category does not apply, return an empty array — never omit the key.
        - The "folder" must be a single string, not an array.\(vocabSection)\(folderSection)

        Existing title hint: \(currentTitle.isEmpty ? "(none)" : currentTitle)

        Text:
        \(text)
        """
    }

    // MARK: - Reader Q&A

    /// One turn in a reader conversation about a paper.
    struct ChatMessage: Identifiable, Equatable, Sendable {
        enum Role: String, Sendable { case user, assistant }
        let id: UUID
        var role: Role
        var text: String
        init(role: Role, text: String) {
            self.id = UUID()
            self.role = role
            self.text = text
        }
    }

    static func buildQuestionPrompt(
        title: String,
        documentText: String,
        history: [ChatMessage],
        question: String
    ) -> String {
        let convo: String
        if history.isEmpty {
            convo = ""
        } else {
            convo = "\n\nConversation so far:\n" + history.map { m in
                "\(m.role == .user ? "Q" : "A"): \(m.text)"
            }.joined(separator: "\n")
        }
        return """
        You are a careful reading assistant for a document in a personal research library. Answer the user's question about the document below.

        Rules:
        - Ground every answer in the document text. If the document doesn't contain the answer, say so plainly instead of guessing.
        - Be concise: a few sentences for simple questions, short Markdown bullet points for multi-part ones.
        - Quote short key phrases from the document where it helps, and name the section they come from when identifiable.
        - Output plain Markdown. No preamble like "Based on the document".

        Document title: \(title)

        Document text:
        \(documentText)\(convo)

        Q: \(question)
        A:
        """
    }

    /// Answer a question about a document, grounded in its extracted text.
    /// Free-form Markdown response (`.text` — no JSON mode). Throws when no
    /// provider is available or the call fails.
    static func answerQuestion(
        title: String,
        documentText: String,
        history: [ChatMessage],
        question: String,
        using provider: Provider
    ) async throws -> String {
        let prompt = buildQuestionPrompt(
            title: title, documentText: documentText,
            history: history, question: question)
        let raw = try await complete(prompt: prompt, using: provider, expecting: .text)
        let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            throw TaggerError.badResponse("empty answer")
        }
        return answer
    }

    // MARK: - Title/author verification (multi-pass)

    /// A title+authors proposal from one extraction pass.
    struct TitleAuthorsProposal: Equatable, Sendable {
        var title: String?
        var authors: [String]?
    }

    /// Cheapest usable variant of a provider, for high-volume verification
    /// passes where a frontier model is overkill: Claude drops to haiku;
    /// Ollama models are small already so they pass through unchanged.
    static func cheapVariant(of provider: Provider) -> Provider {
        switch provider {
        case .claude(let bin, _): return .claude(binary: bin, model: "haiku")
        case .ollama, .unavailable: return provider
        }
    }

    static func buildTitleAuthorsPrompt(text: String) -> String {
        """
        Extract the title and authors of this academic document from the text of its first pages.

        Output ONLY a JSON object in this exact shape — no prose, no code fences:

        {"title": "The Document's Real Title", "authors": ["First Last", "Other Person"]}

        Rules:
        - "title": the document's actual title as printed on the title page, as a human-readable string. NOT the journal or venue name, NOT a running header or section heading, NOT a filename or arXiv id. Return null if you cannot identify it confidently.
        - "authors": the human authors in the order printed. Exclude affiliations, emails, "et al.", journal and publisher names, and software tool names. Return an empty array if you cannot identify them confidently.

        Text:
        \(text)
        """
    }

    /// One focused title/authors extraction pass.
    static func extractTitleAuthors(
        text: String,
        using provider: Provider
    ) async throws -> TitleAuthorsProposal {
        let prompt = buildTitleAuthorsPrompt(text: text)
        let raw = try await complete(prompt: prompt, using: provider)
        // parseExtractedInfo tolerates the missing keys — only title/authors
        // are present in this response.
        let info = parseExtractedInfo(from: raw)
        return TitleAuthorsProposal(title: info.title, authors: info.authors)
    }

    /// Multi-pass attribution: run up to `maxExtraPasses` extra cheap passes
    /// and majority-vote title and authors independently. The seed (the main
    /// tagging pass's proposal) counts as one vote; a value wins with 2+
    /// agreeing votes. Fields stay nil when no consensus emerges — callers
    /// fall back to their single-shot behavior. Stops early once both fields
    /// have a winner, so the happy path costs a single extra cheap call.
    static func consensusTitleAuthors(
        text: String,
        seed: TitleAuthorsProposal,
        maxExtraPasses: Int = 2,
        using provider: Provider
    ) async -> TitleAuthorsProposal {
        guard provider.isAvailable,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TitleAuthorsProposal(title: nil, authors: nil)
        }
        var titleVotes: [String: (count: Int, display: String)] = [:]
        var authorVotes: [String: (count: Int, display: [String])] = [:]

        func addVote(_ p: TitleAuthorsProposal) {
            if let t = p.title, isPlausibleTitle(t), let key = titleVoteKey(t) {
                titleVotes[key, default: (0, t)].count += 1
            }
            if let a = p.authors {
                let cleaned = cleanAuthorList(a)
                if arePlausibleAuthors(cleaned), let key = authorsVoteKey(cleaned) {
                    authorVotes[key, default: (0, cleaned)].count += 1
                }
            }
        }
        // Most-voted candidate wins, ties broken by key so the result doesn't
        // depend on dictionary iteration order.
        func titleWinner() -> String? {
            titleVotes
                .filter { $0.value.count >= 2 }
                .max { a, b in
                    a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key
                }?.value.display
        }
        func authorsWinner() -> [String]? {
            authorVotes
                .filter { $0.value.count >= 2 }
                .max { a, b in
                    a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key
                }?.value.display
        }

        addVote(seed)
        for _ in 0..<max(maxExtraPasses, 0) {
            if titleWinner() != nil, authorsWinner() != nil { break }
            guard let pass = try? await extractTitleAuthors(text: text, using: provider) else {
                continue
            }
            addVote(pass)
        }
        return TitleAuthorsProposal(title: titleWinner(), authors: authorsWinner())
    }

    /// Normalized comparison key for title votes — case/whitespace/trailing-
    /// punctuation insensitive so trivially different spellings agree.
    static func titleVoteKey(_ t: String) -> String? {
        let key = t.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        return key.isEmpty ? nil : key
    }

    /// Normalized comparison key for author-list votes. Order-sensitive —
    /// author order is meaningful in academic attribution.
    static func authorsVoteKey(_ authors: [String]) -> String? {
        guard !authors.isEmpty else { return nil }
        return authors.map { $0.lowercased() }.joined(separator: "|")
    }

    // MARK: - Import assessment

    /// Ask the LLM whether a found PDF belongs in the library. Throws if no
    /// provider is available; parse failures return a conservative "review
    /// manually" verdict rather than throwing.
    static func assessImport(
        fileName: String,
        text: String,
        using provider: Provider
    ) async throws -> ImportAssessment {
        let prompt = buildAssessPrompt(fileName: fileName, text: text)
        let raw = try await complete(prompt: prompt, using: provider)
        return parseAssessment(from: raw)
            ?? ImportAssessment(shouldImport: false, kind: nil, title: nil,
                                reason: "Couldn't parse LLM verdict — review manually")
    }

    static func buildAssessPrompt(fileName: String, text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You triage PDFs for a personal research library (academic papers, books, technical reports, posters). Given a PDF's filename and the text of its first pages, decide whether it belongs in the library.

        IMPORT (true): academic papers, preprints, journal articles, conference papers, textbooks, technical books, theses, dissertations, technical reports, whitepapers, standards documents, in-depth lecture notes, research posters.
        SKIP (false): invoices, receipts, order confirmations, sales documents, contracts, legal agreements, bank or pay statements, tax forms, tickets, boarding passes, insurance or medical paperwork, product manuals, brochures, marketing material, maps, certificates, resumes, meeting slides, event programs, personal correspondence.

        Output ONLY a JSON object in this exact shape — no prose, no code fences:

        {"import": true, "kind": "paper", "title": "The Document's Real Title", "reason": "peer-reviewed journal article"}

        Rules:
        - "kind": one of "paper", "book", "report", "poster" when "import" is true; null when false.
        - "title": the document's real title as a human-readable string, or null if you can't identify one.
        - "reason": under 12 words, plain English.
        - If the text is empty or unreadable (e.g. a scanned document), judge from the filename alone; if still unsure, return "import": false with reason "unreadable — review manually".

        Filename: \(fileName)

        Text:
        \(body.isEmpty ? "(no extractable text)" : body)
        """
    }

    /// Parse the assessment response. Tolerant of code fences and stray prose,
    /// same as the other parsers. Returns nil when no JSON object is found.
    static func parseAssessment(from raw: String) -> ImportAssessment? {
        guard let obj = jsonObject(from: raw),
              let shouldImport = obj["import"] as? Bool else { return nil }

        let kind: PaperKind? = {
            guard shouldImport, let raw = obj["kind"] as? String else { return nil }
            return PaperKind(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
        }()
        let title: String? = {
            guard let t = obj["title"] as? String else { return nil }
            let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }()
        let reason = ((obj["reason"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ImportAssessment(shouldImport: shouldImport, kind: kind,
                                title: title, reason: reason)
    }

    // MARK: - Consolidate tags

    /// Build the prompt that asks the LLM to spot redundant / near-synonym tags
    /// in the library vocabulary and propose merges.
    static func buildConsolidatePrompt(vocabulary: [TagEntry]) -> String {
        let lines = vocabulary.map { e -> String in
            if let d = e.description, !d.isEmpty {
                return "- \(e.name) (\(e.count)): \(d)"
            }
            return "- \(e.name) (\(e.count))"
        }
        return """
        You are consolidating tags in a personal research-paper library. Below is the current vocabulary, each line as `- <name> (<paper-count>)`. Find groups of tags that mean the same thing or are near-synonyms and propose merges.

        Rules — be conservative:
        - Only merge tags that are semantically equivalent or where one is a clear plural/variant of another. Do NOT merge tags that are merely related but distinct ("machine-learning" and "deep-learning" stay separate; "transformer-architecture" merging into "transformers" is fine; "computer-vision" and "image-classification" stay separate).
        - For each merge, pick the most common / most-canonical-looking tag as the "into" target.
        - Never merge tags whose meanings are genuinely different.
        - Return at most 15 merges. Prefer the highest-impact ones (where the duplicates have non-trivial counts).
        - If you find no clear duplicates, return an empty merges array. That is the correct answer when the vocabulary is already clean.

        Output ONLY a JSON object in this exact shape — no prose, no code fences:

        {
          "merges": [
            { "from": ["transformer-architecture"], "into": "transformers", "reason": "variant of the same concept" }
          ]
        }

        Vocabulary:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Parse the LLM response into TagMergeProposal items. Tolerant of code
    /// fences and trailing prose, same as `parseExtractedInfo`.
    static func parseMerges(from raw: String) -> [TagMergeProposal] {
        parseMergeItems(from: raw, lowercased: true).map {
            TagMergeProposal(from: $0.from, into: $0.into, reason: $0.reason)
        }
    }

    /// Both consolidation passes answer in the same shape —
    /// `{"merges": [{"from": [...], "into": "...", "reason": "..."}]}` — so
    /// they share one parser. Tags are a lowercase vocabulary; author names
    /// keep whatever casing the model returned. Entries that merge into
    /// themselves are dropped either way.
    private static func parseMergeItems(
        from raw: String,
        lowercased: Bool
    ) -> [(from: [String], into: String, reason: String)] {
        guard let obj = jsonObject(from: raw),
              let arr = obj["merges"] as? [[String: Any]] else { return [] }
        func clean(_ s: String) -> String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return lowercased ? trimmed.lowercased() : trimmed
        }
        var out: [(from: [String], into: String, reason: String)] = []
        for item in arr {
            let from = stringArray(from: item["from"]).map(clean).filter { !$0.isEmpty }
            let into = clean((item["into"] as? String) ?? "")
            guard !into.isEmpty, !from.isEmpty else { continue }
            let filtered = from.filter { $0.lowercased() != into.lowercased() }
            guard !filtered.isEmpty else { continue }
            out.append((filtered, into, (item["reason"] as? String) ?? ""))
        }
        return out
    }

    // MARK: - Consolidate authors

    /// Prompt asking the LLM to find author-name duplicates ("J. Smith" vs
    /// "John Smith", "Smith, John" vs "John Smith", diacritic variants) and
    /// propose merges. Conservative — middle initials and full names that
    /// don't share a clear abbreviation/reorder relationship stay separate.
    static func buildAuthorConsolidatePrompt(authors: [(name: String, count: Int)]) -> String {
        let lines = authors.map { "- \($0.name) (\($0.count))" }
        return """
        You are consolidating author names in a personal research-paper library. Below is the current author list with paper counts. Find names that are clearly the same person written in different forms and propose merges.

        Rules — be conservative. The cost of a wrong merge (combining two different people) is much higher than the cost of a missed merge.
        - Only merge when one form is a clear variant of another: abbreviation ("J. Smith" → "John Smith"), reordered surname-first ("Smith, John" → "John Smith"), diacritic or spelling variants of the same name ("José García" / "Jose Garcia"), or trivial capitalisation/punctuation differences.
        - DO NOT merge two complete names that share only a surname.
        - DO NOT merge names that differ in middle initial ("John A. Smith" vs "John B. Smith" are different people).
        - DO NOT collapse "Smith" with "John Smith" — a bare surname could be anyone.
        - For the "into" target, prefer the most complete spelling (full first name; middle initial if it appears in any variant) and the form that appears most often.
        - Return at most 15 merges. Prefer high-impact ones (where the duplicates have non-trivial counts).
        - If you find no clear duplicates, return an empty merges array. That is the correct answer when the list is already clean.

        Output ONLY a JSON object in this exact shape — no prose, no code fences. Names in "from" and "into" must be in their original case (do NOT lowercase):

        {
          "merges": [
            { "from": ["J. Smith"], "into": "John Smith", "reason": "abbreviated form" }
          ]
        }

        Authors:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Parse the LLM response into AuthorMergeProposal items. Unlike
    /// `parseMerges` for tags, this preserves the original case of every
    /// name — "John Smith" stays "John Smith", not "john smith".
    static func parseAuthorMerges(from raw: String) -> [AuthorMergeProposal] {
        parseMergeItems(from: raw, lowercased: false).map {
            AuthorMergeProposal(from: $0.from, into: $0.into, reason: $0.reason)
        }
    }

    /// Ask the LLM to propose author merges. Throws if no provider is available.
    static func proposeAuthorMerges(authors: [(name: String, count: Int)], using provider: Provider) async throws -> [AuthorMergeProposal] {
        // Cap at top 150 by count to keep the prompt small. Long-tail single-
        // paper authors are rarely worth merging anyway — drop them.
        let capped = Array(authors
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
            .prefix(150))
        let prompt = buildAuthorConsolidatePrompt(authors: capped)
        let raw = try await complete(prompt: prompt, using: provider)
        return parseAuthorMerges(from: raw)
    }

    /// Ask the LLM to propose tag merges. Throws if no provider is available.
    static func proposeMerges(vocabulary: [TagEntry], using provider: Provider) async throws -> [TagMergeProposal] {
        // Cap to top 100 by count to keep prompt manageable.
        let capped = Array(vocabulary
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
            .prefix(100))
        let prompt = buildConsolidatePrompt(vocabulary: capped)
        let raw = try await complete(prompt: prompt, using: provider)
        return parseMerges(from: raw)
    }

    // MARK: - LLM plumbing (single dispatch + shared JSON parsing)

    /// What shape of response an operation expects. `.json` turns on Ollama's
    /// JSON mode and a tight output cap; `.text` allows free-form Markdown
    /// (reader Q&A). Claude CLI ignores this — prompts carry the format rules.
    enum ResponseFormat {
        case json, text
    }

    /// Single chokepoint for every LLM call: routes a prompt to the active
    /// provider and returns the raw response. All feature-level operations
    /// (tagging, merges, import triage, attribution passes, reader Q&A) go
    /// through here — add new LLM features by calling this, never
    /// runClaude/runOllama directly.
    static func complete(
        prompt: String,
        using provider: Provider,
        expecting format: ResponseFormat = .json
    ) async throws -> String {
        switch provider {
        case .claude(let bin, let model):
            return try await runClaude(bin: bin, model: model, prompt: prompt)
        case .ollama(let model):
            return try await runOllama(model: model, prompt: prompt, format: format)
        case .unavailable:
            throw TaggerError.noProvider
        }
    }

    /// Shared response cleanup: strip markdown code fences and stray prose,
    /// then parse the first JSON object. Every response parser goes through
    /// here. Returns nil when no JSON object can be recovered.
    static func jsonObject(from raw: String) -> [String: Any]? {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if working.hasPrefix("```") {
            working = String(working.dropFirst(3))
            if let nl = working.firstIndex(of: "\n") {
                let lang = working[..<nl].trimmingCharacters(in: .whitespaces).lowercased()
                if ["json", ""].contains(lang) {
                    working = String(working[working.index(after: nl)...])
                }
            }
            if let end = working.range(of: "```") {
                working = String(working[..<end.lowerBound])
            }
        }
        // Slice from first `{` to last `}` if there's leading/trailing prose.
        if let first = working.firstIndex(of: "{"),
           let last = working.lastIndex(of: "}"),
           first < last {
            working = String(working[first...last])
        }
        guard let data = working.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    // MARK: - Claude CLI

    /// Holder for a running Process so a cancellation handler can terminate it.
    /// Locked: the cancellation handler runs on an arbitrary thread and can
    /// fire before — or during — the child's launch. Recording the cancel lets
    /// a late `attach` refuse to start a subprocess nobody is waiting for.
    private final class ProcessHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var proc: Process?
        private var cancelled = false

        /// Register the process. Returns false if cancellation already fired,
        /// in which case the caller must not run it.
        func attach(_ p: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            proc = p
            return true
        }

        func terminate() {
            lock.lock()
            cancelled = true
            let p = proc
            lock.unlock()
            p?.terminate()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// Thread-safe byte sink for draining a child's pipe off the main flow.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func set(_ d: Data) { lock.lock(); storage = d; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Invoke `claude -p` with the prompt piped via stdin. argv has a length
    /// limit; stdin is unbounded. Cancels the subprocess if the task is cancelled.
    ///
    /// stdin, stdout and stderr are all pumped on background queues *before*
    /// waiting on the child. Doing any of them inline deadlocks as soon as the
    /// data exceeds the ~64 KB pipe buffer: the child blocks writing its answer
    /// while we block waiting for it to exit (or vice versa for a long prompt).
    static func runClaude(bin: URL, model: String?, prompt: String) async throws -> String {
        let holder = ProcessHolder()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try runClaudeBlocking(bin: bin, model: model, prompt: prompt, holder: holder)
            }.value
        } onCancel: {
            holder.terminate()
        }
    }

    /// The blocking half of `runClaude`, kept synchronous so it can wait on the
    /// pipe pumps. Always called from a detached task.
    private static func runClaudeBlocking(
        bin: URL, model: String?, prompt: String, holder: ProcessHolder
    ) throws -> String {
        let proc = Process()
        proc.executableURL = bin
        var args = ["-p", "--no-session-persistence"]
        if let m = model, !m.isEmpty {
            args.append(contentsOf: ["--model", m])
        }
        proc.arguments = args

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        guard holder.attach(proc) else { throw CancellationError() }

        do {
            try proc.run()
        } catch {
            throw TaggerError.llmFailed("could not launch claude: \(error.localizedDescription)")
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let pumps = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(group: pumps) {
            outBox.set((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
        }
        queue.async(group: pumps) {
            errBox.set((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())
        }
        let promptData = Data(prompt.utf8)
        queue.async(group: pumps) {
            let handle = inPipe.fileHandleForWriting
            try? handle.write(contentsOf: promptData)
            try? handle.close()
        }

        proc.waitUntilExit()
        pumps.wait()

        if holder.isCancelled { throw CancellationError() }

        if proc.terminationStatus != 0 {
            let msg = String(data: errBox.value, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw TaggerError.llmFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outBox.value, encoding: .utf8) ?? ""
    }

    // MARK: - Ollama

    static func runOllama(
        model: String,
        prompt: String,
        format: ResponseFormat = .json
    ) async throws -> String {
        // Use /api/chat (not /api/generate) so `think: false` works — critical for
        // reasoning models like qwen3.5 that otherwise burn the entire output
        // budget on hidden thinking tokens.
        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else {
            throw TaggerError.llmFailed("invalid ollama URL")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "think": false,                  // disable reasoning — qwen3.5 default-thinks for minutes otherwise
            "options": [
                "temperature": 0.1,
                // Hard safety cap. JSON ops need ~750 tokens; free-form
                // reader answers get more headroom.
                "num_predict": format == .json ? 1000 : 1600,
            ],
        ]
        if format == .json {
            body["format"] = "json"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw TaggerError.llmFailed("ollama HTTP \(http.statusCode)")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TaggerError.badResponse("not JSON")
            }
            // /api/chat shape: {"message":{"role":"assistant","content":"..."}}
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? String {
                return content
            }
            // Fall back to /api/generate shape just in case.
            if let response = obj["response"] as? String {
                return response
            }
            throw TaggerError.badResponse("missing message.content")
        } catch let err as TaggerError {
            throw err
        } catch {
            throw TaggerError.llmFailed(error.localizedDescription)
        }
    }

    // MARK: - Parsing

    /// Parse the LLM response into ExtractedInfo. Tolerant of code fences,
    /// leading prose, or alternative key spellings.
    static func parseExtractedInfo(from raw: String) -> ExtractedInfo {
        guard let obj = jsonObject(from: raw) else {
            return ExtractedInfo(title: nil, summary: nil, topics: [], applicationAreas: [], methods: [])
        }

        let title: String? = {
            guard let t = obj["title"] as? String else { return nil }
            let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }()
        let authors: [String]? = {
            // Accept either ["A","B"] (preferred) or "A, B" (LLM goof).
            var raw: [String] = stringArray(from: obj["authors"])
            if raw.isEmpty, let single = obj["authors"] as? String {
                raw = single
                    .components(separatedBy: CharacterSet(charactersIn: ",;&"))
                    .flatMap { $0.components(separatedBy: " and ") }
            }
            // Strip "et al." from any entry the LLM emits as a literal author.
            let sized = raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 120 }
            let cleaned = cleanAuthorList(sized)
            return cleaned.isEmpty ? nil : Array(cleaned.prefix(20))
        }()
        let summary: String? = {
            guard let s = obj["summary"] as? String else { return nil }
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }()
        let topics = stringArray(from: obj["topics"])
        let apps = stringArray(from: obj["application_areas"] ?? obj["applications"] ?? obj["application areas"])
        let methods = stringArray(from: obj["methods"])
        let folder: String? = {
            // Accept "folder": "Machine Learning" — or, if the LLM goofed and
            // returned an array, take the first element.
            if let s = obj["folder"] as? String {
                return normalizeFolder(s)
            }
            if let arr = obj["folder"] as? [Any], let first = arr.first as? String {
                return normalizeFolder(first)
            }
            return nil
        }()

        return ExtractedInfo(
            title: title,
            authors: authors,
            summary: summary,
            topics: normalize(topics, max: 5),
            applicationAreas: normalize(apps, max: 4),
            methods: normalize(methods, max: 6),
            folder: folder)
    }

    /// Clean an LLM-proposed folder name: trim, collapse whitespace, drop empties.
    /// Does NOT force Title Case — the LLM is asked for it, and snapping to an
    /// existing folder happens in `canonicalizeFolder(_:against:)`.
    static func normalizeFolder(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard trimmed.count >= 2, trimmed.count <= 60 else { return nil }
        let lower = trimmed.lowercased()
        if ["none", "n/a", "unknown", "uncategorized", "other", "miscellaneous"].contains(lower) {
            return nil
        }
        return trimmed
    }

    /// Snap an LLM-proposed folder to an existing one if it's a case-insensitive
    /// match — keeps the library from accumulating "Machine Learning" /
    /// "machine learning" / "Machine learning" as three separate folders.
    static func canonicalizeFolder(_ proposed: String, against existing: [String]) -> String {
        let key = proposed.lowercased()
        if let match = existing.first(where: { $0.lowercased() == key }) {
            return match
        }
        return proposed
    }

    // MARK: - Author heuristic

    private static let nonAuthorMarkers: Set<String> = [
        "microsoft word", "microsoft office", "latex", "pdflatex", "tex output",
        "adobe acrobat", "preview", "author", "authors", "unknown", "anonymous",
        "untitled", "pdfcreator", "pdftk", "lualatex", "xelatex", "ghostscript",
    ]

    /// "et al." and friends — these slip through PDFKit metadata as literal
    /// author entries ("Smith et al."), and the LLM occasionally emits one too.
    /// Lower-cased, punctuation-stripped form so the matcher is robust.
    private static let etAlMarkers: Set<String> = [
        "et al", "et. al", "et alia", "et alii", "and others", "others",
    ]

    /// True if this entry is an "et al." marker rather than a real person's name.
    /// Used to drop the entry entirely.
    static func isJunkAuthorEntry(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let normalized = trimmed
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return etAlMarkers.contains(normalized)
    }

    /// Strip a trailing "et al." suffix from a name and return the cleaned form.
    /// Returns nil if the result is empty, junk, or the original was just a
    /// marker like "et al." on its own.
    /// Examples:
    ///   "John Smith et al." → "John Smith"
    ///   "John Smith, et al" → "John Smith"
    ///   "et al."            → nil
    static func cleanAuthorName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Strip trailing variants in one regex pass: optional `,` or `;`,
        // optional whitespace, then "et al" / "et. al" / "and others"
        // / "et alia" / "et alii", with optional trailing period.
        let suffixes = [
            #"[,;]?\s*et\.?\s*al(ia|ii)?\.?$"#,
            #"[,;]?\s*and\s+others\.?$"#,
        ]
        for pattern in suffixes {
            if let range = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                s = String(s[..<range.lowerBound])
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || isJunkAuthorEntry(s) { return nil }
        return s
    }

    /// Clean a list of author names: strip "et al." junk, drop empties, dedup
    /// case-insensitively while preserving first-seen casing.
    static func cleanAuthorList(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in raw {
            guard let cleaned = cleanAuthorName(name) else { continue }
            if seen.insert(cleaned.lowercased()).inserted {
                out.append(cleaned)
            }
        }
        return out
    }

    /// True if the existing authors list looks like PDFKit metadata garbage
    /// (compile-tool names, single fragment, all numbers, etc.) and should be
    /// replaced by an LLM-extracted list.
    static func areLikelyBadAuthors(_ authors: [String]) -> Bool {
        if authors.isEmpty { return true }
        // All entries are junk → bad.
        for a in authors {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return true }
            let lower = t.lowercased()
            if nonAuthorMarkers.contains(where: { lower.contains($0) }) { return true }
            // Mostly non-letters
            let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            if Double(letters) / Double(t.count) < 0.5 { return true }
            // Single-token author with no spaces and not capitalised → suspicious
            if !t.contains(" ") && t.count < 4 { return true }
        }
        return false
    }

    /// True if the LLM's proposed authors look plausible (at least one entry,
    /// no obvious junk).
    static func arePlausibleAuthors(_ proposed: [String]) -> Bool {
        guard !proposed.isEmpty else { return false }
        return !areLikelyBadAuthors(proposed)
    }

    // MARK: - Title heuristic

    /// PDFKit often returns the authoring-tool name in the title attribute
    /// instead of the real title. These markers trigger an LLM rescue.
    private static let nonTitleMarkers: [String] = [
        "microsoft word", "microsoft office", "microsoft powerpoint",
        "latex", "pdflatex", "lualatex", "xelatex", "tex output",
        "adobe acrobat", "adobe indesign", "adobe illustrator",
        "preview.app", "pdfcreator", "pdftk", "ghostscript",
        "openoffice", "libreoffice",
    ]

    /// True if the current title looks like junk (filename / arxiv id / empty /
    /// "Untitled" / compile-tool name) and should be replaced by an LLM-extracted title.
    static func isLikelyBadTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.count < 5 { return true }
        let lower = t.lowercased()
        if lower == "untitled" || lower == "no title" { return true }
        if lower.hasSuffix(".pdf") { return true }
        // "Untitled1", "Untitled-2", "Untitled document" — Word/Pages default names.
        if lower.range(of: #"^untitled[\s\-_]*\d*$"#, options: .regularExpression) != nil { return true }
        if lower.hasPrefix("untitled document") { return true }
        // Compile-tool names PDFKit happily returns as the "title".
        for marker in nonTitleMarkers where lower.contains(marker) { return true }

        // arXiv-id-ish: 2401.12345, 1706.03762v2, hep-th/0101001, plus optional vN
        if t.range(of: #"^\d{4}\.\d{4,5}(v\d+)?$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^[a-z\-]+/\d{7}$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }

        // Mostly non-letters — likely a filename or compile artifact.
        let letterCount = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if Double(letterCount) / Double(t.count) < 0.5 { return true }

        // Filename-ish underscores between digits
        if t.range(of: #"\d_|\b_\d|^_|_$"#, options: .regularExpression) != nil { return true }

        return false
    }

    /// True if `proposed` is a sensible-looking replacement title (not generic,
    /// not itself junky, has at least 2 letters and one space or 8+ chars).
    static func isPlausibleTitle(_ proposed: String) -> Bool {
        let t = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || isLikelyBadTitle(t) { return false }
        if t.count >= 8 { return true }
        if t.contains(" ") { return true }
        return false
    }

    private static func stringArray(from any: Any?) -> [String] {
        guard let arr = any as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    static func normalize(_ tags: [String], max: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for t in tags {
            var cleaned = t
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            cleaned = String(cleaned.unicodeScalars.filter { allowed.contains($0) })
            cleaned = cleaned.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard cleaned.count >= 2, cleaned.count <= 40 else { continue }
            if bannedTags.contains(cleaned) { continue }
            if seen.insert(cleaned).inserted {
                out.append(cleaned)
            }
            if out.count >= max { break }
        }
        return out
    }

    static let bannedTags: Set<String> = [
        "research", "study", "analysis", "paper", "papers", "method", "methods",
        "results", "introduction", "conclusion", "abstract", "report", "book",
        "document", "documents", "topic", "topics", "tag", "tags",
    ]
}
