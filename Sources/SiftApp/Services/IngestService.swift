import Foundation
import PDFKit
import CryptoKit
import AppKit

/// Pure-Swift ingest: copy a PDF into library/<id>/, extract metadata via PDFKit,
/// write metadata.json. Mirrors the on-disk schema the Python CLI produces, minus
/// the LLM-derived auto.* block and embeddings.
enum IngestError: LocalizedError {
    case notAPDF(URL)
    case unreadable(URL)
    case writeFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAPDF(let u): return "Not a readable PDF: \(u.lastPathComponent)"
        case .unreadable(let u): return "Cannot read file: \(u.path)"
        case .writeFailed(let m): return "Write failed: \(m)"
        case .downloadFailed(let m): return "Download failed: \(m)"
        }
    }
}

struct IngestResult {
    let paperId: String
    let alreadyExisted: Bool
}

@MainActor
final class IngestService {
    let config: AppConfig
    init(config: AppConfig) { self.config = config }

    /// Ingest a local PDF file. Returns the resulting paper id.
    /// `tags` is a comma-separated string.
    func addLocalPDF(at source: URL, tags: String = "") async throws -> IngestResult {
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw IngestError.unreadable(source)
        }
        guard let doc = PDFDocument(url: source) else {
            throw IngestError.notAPDF(source)
        }

        // Hash + id
        let sha = try Self.sha256(of: source)
        let id = String(sha.prefix(12))

        let destDir = config.paperDir(id)
        let destPDF = config.pdfURL(id)
        let metaURL = config.metadataURL(id)
        let alreadyExisted = FileManager.default.fileExists(atPath: metaURL.path)

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destPDF.path) {
            try FileManager.default.copyItem(at: source, to: destPDF)
        }

        // Metadata via PDFKit attributes + page-count heuristic
        let attrs = doc.documentAttributes ?? [:]
        let pdfTitle = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pdfAuthor = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date

        let title: String = {
            if let t = pdfTitle, !t.isEmpty { return t }
            return source.deletingPathExtension().lastPathComponent
        }()
        let authors: [String] = pdfAuthor.flatMap(Self.parseAuthors) ?? []
        let year: Int? = creationDate.flatMap { Calendar(identifier: .gregorian)
            .component(.year, from: $0) }
        let pages = doc.pageCount
        let kind: PaperKind = {
            if pages > 80 { return .book }
            if title.lowercased().contains("report") { return .report }
            return .paper
        }()

        let tagList = tags.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        try writeMetadata(id: id, title: title, authors: authors,
                          year: year, pages: pages, kind: kind,
                          sha256: sha, source: "drop", userTags: tagList,
                          arxivID: nil, doi: nil, venue: nil)
        return IngestResult(paperId: id, alreadyExisted: alreadyExisted)
    }

    /// arXiv URL or bare ID. Downloads the PDF, runs through local ingest.
    func addArxivURL(_ raw: String, tags: String = "") async throws -> IngestResult {
        let id = Self.extractArxivID(from: raw)
        let urlString: String
        if let id {
            urlString = "https://arxiv.org/pdf/\(id).pdf"
        } else if raw.lowercased().hasSuffix(".pdf") {
            urlString = raw
        } else {
            throw IngestError.downloadFailed("Not an arXiv URL/ID or direct PDF: \(raw)")
        }
        guard let url = URL(string: urlString) else {
            throw IngestError.downloadFailed("Invalid URL: \(urlString)")
        }

        let tmp = try await downloadToTemp(url)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await addLocalPDF(at: tmp, tags: tags)
        if let arxivID = id {
            try updateMetadata(paperId: result.paperId) { meta in
                meta["arxiv_id"] = arxivID
                meta["source"] = "arxiv"
            }
        } else {
            // Direct PDF URL — record where it came from.
            try updateMetadata(paperId: result.paperId) { meta in
                meta["source"] = "url"
            }
        }
        return result
    }

    // MARK: - Helpers

    private func writeMetadata(
        id: String, title: String, authors: [String],
        year: Int?, pages: Int, kind: PaperKind, sha256: String,
        source: String, userTags: [String],
        arxivID: String?, doi: String?, venue: String?
    ) throws {
        var meta: [String: Any] = [
            "id": id,
            "title": title,
            "authors": authors,
            "year": year as Any? ?? NSNull(),
            "venue": venue as Any? ?? NSNull(),
            "doi": doi as Any? ?? NSNull(),
            "arxiv_id": arxivID as Any? ?? NSNull(),
            "added_at": ISO8601.now(),
            "sha256": sha256,
            "source": source,
            "kind": kind.rawValue,
            "pages": pages,
            "user_tags": userTags,
            "auto": [String: Any](),  // empty — LLM block not produced yet
        ]
        // If metadata already exists (re-ingest of same hash), preserve user_tags
        // and the original added_at.
        let url = config.metadataURL(id)
        if let existing = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            if let existingTags = parsed["user_tags"] as? [String], !existingTags.isEmpty {
                // Union, not replace: re-adding a known PDF with new tags used
                // to silently drop them.
                var merged = existingTags
                var seen = Set(existingTags.map { $0.lowercased() })
                for t in userTags where seen.insert(t.lowercased()).inserted {
                    merged.append(t)
                }
                meta["user_tags"] = merged
            }
            if let existingAddedAt = parsed["added_at"] as? String, !existingAddedAt.isEmpty {
                meta["added_at"] = existingAddedAt
            }
            if let existingAuto = parsed["auto"] {
                meta["auto"] = existingAuto
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Read-modify-write a metadata.json by mutating its dictionary in place.
    private func updateMetadata(paperId: String, mutate: (inout [String: Any]) -> Void) throws {
        let url = config.metadataURL(paperId)
        let data = try Data(contentsOf: url)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IngestError.writeFailed("metadata.json malformed")
        }
        mutate(&obj)
        let out = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    private func downloadToTemp(_ url: URL) async throws -> URL {
        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw IngestError.downloadFailed("HTTP \(http.statusCode) from \(url.host ?? "?")")
        }
        // Rename so PDFKit recognizes it (URLSession gives a generic temp name).
        let renamed = tmpURL
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try FileManager.default.moveItem(at: tmpURL, to: renamed)
        return renamed
    }

    // MARK: - Static helpers

    /// nonisolated so FolderScanService can hash candidate files off the main
    /// actor — it's a pure function over the file's bytes.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "Smith, John; Doe, Jane" or "John Smith and Jane Doe" → ["John Smith", "Jane Doe"]
    /// Strips trailing "et al." from each entry and drops entries that ARE the
    /// "et al." marker — PDFKit happily emits "Smith et al." as the authors
    /// field, which we'd otherwise carry through as a literal author entry.
    static func parseAuthors(_ raw: String) -> [String] {
        let separators: [String] = [";", " and ", "&", ","]
        var parts: [String] = [raw]
        for sep in separators {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        let sized = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count < 200 }
        return LLMTagger.cleanAuthorList(sized)
    }

    /// Recognize: 2401.12345, https://arxiv.org/abs/2401.12345v2, /pdf/2401.12345.pdf,
    /// old-style hep-th/0101001.
    static func extractArxivID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Modern style: YYMM.NNNNN (with optional vN suffix)
        if let r = trimmed.range(of: #"(\d{4}\.\d{4,5})(v\d+)?"#,
                                  options: .regularExpression) {
            // strip vN suffix
            let id = String(trimmed[r])
            if let mainRange = id.range(of: #"\d{4}\.\d{4,5}"#,
                                         options: .regularExpression) {
                return String(id[mainRange])
            }
            return id
        }

        // Old style: e.g. "hep-th/0101001"
        if let r = trimmed.range(of: #"[a-z\-]+/\d{7}"#,
                                  options: .regularExpression) {
            return String(trimmed[r])
        }
        return nil
    }
}
