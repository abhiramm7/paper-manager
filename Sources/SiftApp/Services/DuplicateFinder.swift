import Foundation

/// Finds papers that are almost certainly the same work but slipped in as
/// separate entries — the arXiv PDF and the journal PDF, v1 and v2, a
/// re-download from a different source. Ingest dedupe only catches
/// byte-identical files (same SHA-256); this catches the rest.
///
/// Deterministic, no LLM. Conservative by design: the cost of a false merge
/// (hiding two genuinely different papers behind one) is higher than the cost
/// of missing one, so a pair only groups on strong evidence.
enum DuplicateFinder {

    /// Groups of ≥2 papers that look like the same work, most-recently-added
    /// group first. A paper appears in at most one group.
    static func findDuplicates(in papers: [Paper]) -> [[Paper]] {
        guard papers.count > 1 else { return [] }

        // Union-find over paper indices.
        var parent = Array(0..<papers.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb }
        }

        // Bucket by strong exact keys — arXiv base id and DOI. Anything sharing
        // one of these is the same work, full stop.
        var arxivBuckets: [String: [Int]] = [:]
        var doiBuckets: [String: [Int]] = [:]
        // Precompute normalized titles + token sets for the fuzzy pass.
        var normTitles: [String] = []
        var tokenSets: [Set<String>] = []
        normTitles.reserveCapacity(papers.count)
        tokenSets.reserveCapacity(papers.count)

        for (i, p) in papers.enumerated() {
            if let a = arxivBase(p.arxiv_id), !a.isEmpty {
                arxivBuckets[a, default: []].append(i)
            }
            if let d = normalizeDOI(p.doi), !d.isEmpty {
                doiBuckets[d, default: []].append(i)
            }
            let nt = normalizeTitle(p.title)
            normTitles.append(nt)
            tokenSets.append(Set(nt.split(separator: " ").map(String.init)))
        }
        for (_, idxs) in arxivBuckets where idxs.count > 1 {
            for j in 1..<idxs.count { union(idxs[0], idxs[j]) }
        }
        for (_, idxs) in doiBuckets where idxs.count > 1 {
            for j in 1..<idxs.count { union(idxs[0], idxs[j]) }
        }

        // Title pass. Exact normalized-title match is enough; otherwise require
        // high token overlap (Jaccard ≥ 0.85) AND compatible years so short,
        // generic titles don't collapse unrelated papers. O(n²) — fine for a
        // personal library; guarded by a title-length floor.
        for i in 0..<papers.count {
            let ti = normTitles[i]
            guard ti.count >= 8 else { continue }   // skip junk/empty titles
            for j in (i + 1)..<papers.count {
                if find(i) == find(j) { continue }
                let tj = normTitles[j]
                guard tj.count >= 8 else { continue }
                if ti == tj {
                    union(i, j)
                } else if yearsCompatible(papers[i].year, papers[j].year),
                          jaccard(tokenSets[i], tokenSets[j]) >= 0.85 {
                    union(i, j)
                }
            }
        }

        // Collect groups.
        var groups: [Int: [Paper]] = [:]
        for i in 0..<papers.count {
            groups[find(i), default: []].append(papers[i])
        }
        return groups.values
            .filter { $0.count > 1 }
            .map { cluster in
                cluster.sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
            }
            .sorted { ($0.first?.addedDate ?? .distantPast) > ($1.first?.addedDate ?? .distantPast) }
    }

    // MARK: - Normalization

    /// arXiv id without version suffix: "2401.12345v2" → "2401.12345",
    /// "hep-th/0101001" → "hep-th/0101001". nil/empty when absent.
    static func arxivBase(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if let r = lower.range(of: #"\d{4}\.\d{4,5}"#, options: .regularExpression) {
            return String(lower[r])
        }
        if let r = lower.range(of: #"[a-z\-]+/\d{7}"#, options: .regularExpression) {
            return String(lower[r])
        }
        return lower
    }

    static func normalizeDOI(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.lowercased()
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")
            .replacingOccurrences(of: "doi:", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lowercase, strip accents + punctuation, collapse whitespace. Makes
    /// "Attention Is All You Need." and "attention is all you need" equal.
    static func normalizeTitle(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                 locale: .current)
        let scalars = folded.unicodeScalars.map { s -> Character in
            (CharacterSet.alphanumerics.contains(s) || s == " ") ? Character(s) : " "
        }
        return String(scalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Similarity

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let inter = a.intersection(b).count
        let uni = a.union(b).count
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    /// Years are compatible if either is missing, they're equal, or they're
    /// within one year (preprint vs published often differ by a year).
    static func yearsCompatible(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= 1
    }
}
