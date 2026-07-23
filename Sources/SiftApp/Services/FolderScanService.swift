import Foundation

/// A PDF discovered in one of the user's watched folders.
struct FoundPDF: Identifiable, Hashable, Sendable {
    let url: URL
    let sha256: String
    let fileSize: Int64
    let modified: Date?
    /// Non-nil when a paper with the same content hash is already in the
    /// library — the file is a duplicate of something Sift has.
    let libraryPaperId: String?

    var id: String { url.path }
    var isInLibrary: Bool { libraryPaperId != nil }
    var fileName: String { url.lastPathComponent }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

/// Scans watched folders for PDFs and matches them against the library by
/// content hash (SHA-256 — same identity the ingest path uses, so "already
/// in Sift" here means ingest would be a no-op).
enum FolderScanService {
    /// Recursively enumerate `folders` for PDFs. Anything under `excludeRoot`
    /// (the Sift library itself) is skipped — if a watched folder happens to
    /// contain the library, its paper.pdf files must never be reported as
    /// trashable duplicates.
    static func scan(
        folders: [URL],
        excluding excludeRoot: URL,
        knownHashes: [String: String]
    ) -> [FoundPDF] {
        let fm = FileManager.default
        let excludePath = excludeRoot.standardizedFileURL.path
        var seenPaths = Set<String>()   // dedupe overlapping/nested watched folders
        var out: [FoundPDF] = []

        for folder in folders {
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey,
                                             .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "pdf" else { continue }
                let std = url.standardizedFileURL
                if std.path == excludePath || std.path.hasPrefix(excludePath + "/") {
                    continue
                }
                guard seenPaths.insert(std.path).inserted else { continue }
                guard let vals = try? std.resourceValues(
                        forKeys: [.isRegularFileKey, .fileSizeKey,
                                  .contentModificationDateKey]),
                      vals.isRegularFile == true else { continue }
                // Unhashable file (permissions, still downloading) — skip
                // rather than reporting a bogus entry.
                guard let sha = try? IngestService.sha256(of: std) else { continue }

                out.append(FoundPDF(
                    url: std,
                    sha256: sha,
                    fileSize: Int64(vals.fileSize ?? 0),
                    modified: vals.contentModificationDate,
                    libraryPaperId: knownHashes[sha]))
            }
        }
        // Newest first — the PDF you just downloaded is the one you care about.
        return out.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
}
