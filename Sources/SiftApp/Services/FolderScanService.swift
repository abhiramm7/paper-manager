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

/// One remembered hash, keyed by file path. A file whose size and modification
/// date are unchanged is assumed to have unchanged content — the same
/// assumption every backup tool makes, and cheap to re-verify by touching the
/// file if it's ever wrong.
struct ScanCacheEntry: Codable, Sendable {
    let size: Int64
    let modified: Double
    let sha256: String
}

typealias ScanCache = [String: ScanCacheEntry]

/// Scans watched folders for PDFs and matches them against the library by
/// content hash (SHA-256 — same identity the ingest path uses, so "already
/// in Sift" here means ingest would be a no-op).
enum FolderScanService {
    /// Cap on remembered hashes, so watching a huge folder can't grow the
    /// stored cache without bound.
    static let maxCacheEntries = 20_000

    /// Recursively enumerate `folders` for PDFs. Anything under `excludeRoot`
    /// (the Sift library itself) is skipped — if a watched folder happens to
    /// contain the library, its paper.pdf files must never be reported as
    /// trashable duplicates.
    ///
    /// `cache` carries hashes forward from the previous scan: hashing is the
    /// entire cost of this walk, and rescans (launch, folder add/remove, post
    /// import) otherwise re-read every byte of every watched PDF. The returned
    /// cache holds only files seen this time, so deleted files fall out.
    static func scan(
        folders: [URL],
        excluding excludeRoot: URL,
        knownHashes: [String: String],
        cache: ScanCache = [:]
    ) -> (found: [FoundPDF], cache: ScanCache) {
        let fm = FileManager.default
        let excludePath = excludeRoot.standardizedFileURL.path
        var seenPaths = Set<String>()   // dedupe overlapping/nested watched folders
        var out: [FoundPDF] = []
        var nextCache: ScanCache = [:]

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

                let size = Int64(vals.fileSize ?? 0)
                let mtime = vals.contentModificationDate?.timeIntervalSince1970 ?? 0
                let sha: String
                if let hit = cache[std.path], hit.size == size, hit.modified == mtime {
                    sha = hit.sha256
                } else if let fresh = try? IngestService.sha256(of: std) {
                    sha = fresh
                } else {
                    // Unhashable file (permissions, still downloading) — skip
                    // rather than reporting a bogus entry.
                    continue
                }
                if nextCache.count < maxCacheEntries {
                    nextCache[std.path] = ScanCacheEntry(size: size, modified: mtime, sha256: sha)
                }

                out.append(FoundPDF(
                    url: std,
                    sha256: sha,
                    fileSize: size,
                    modified: vals.contentModificationDate,
                    libraryPaperId: knownHashes[sha]))
            }
        }
        // Newest first — the PDF you just downloaded is the one you care about.
        return (out.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) },
                nextCache)
    }
}
