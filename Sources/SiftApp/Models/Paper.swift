import Foundation

struct CodeLink: Codable, Hashable {
    var url: String
    var host: String?
}

struct AutoMeta: Codable, Hashable {
    var tags: [String]?
    var topics: [String]?
    var application_areas: [String]?
    var methods: [String]?
    var datasets: [String]?
    var claims: [String]?
    var key_terms: [String]?
    var code_links: [CodeLink]?
    /// LLM-picked subject-area folder. Single human-readable name (e.g.
    /// "Machine Learning"). Reuses an existing folder when one fits; the LLM
    /// only invents a new folder when none does.
    var folder: String?
}

enum PaperKind: String, Codable, CaseIterable, Hashable {
    case paper
    case book
    case report
    case poster

    var symbol: String {
        switch self {
        case .paper: return "doc.text"
        case .book: return "book"
        case .report: return "chart.bar.doc.horizontal"
        case .poster: return "rectangle.portrait"
        }
    }

    var label: String {
        switch self {
        case .paper: return "Paper"
        case .book: return "Book"
        case .report: return "Report"
        case .poster: return "Poster"
        }
    }
}

struct Paper: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var authors: [String]
    var year: Int?
    var venue: String?
    var doi: String?
    var arxiv_id: String?
    var added_at: String
    var sha256: String
    var source: String
    var kind: PaperKind = .paper
    var pages: Int?
    var user_tags: [String] = []
    /// User-set folder. Takes precedence over `auto.folder` when non-nil. nil
    /// means "use the LLM's suggestion." Stored at the top level (not in
    /// AutoMeta) so the LLM's tagging pass never clobbers it.
    var user_folder: String?
    var auto: AutoMeta?

    /// The folder this paper effectively belongs to: user override if set,
    /// otherwise the LLM's auto-assigned folder.
    var effectiveFolder: String? {
        if let uf = user_folder?.trimmingCharacters(in: .whitespacesAndNewlines), !uf.isEmpty {
            return uf
        }
        return auto?.folder
    }

    enum CodingKeys: String, CodingKey {
        case id, title, authors, year, venue, doi, arxiv_id, added_at,
             sha256, source, kind, pages, user_tags, user_folder, auto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        authors = (try? c.decode([String].self, forKey: .authors)) ?? []
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        venue = try? c.decodeIfPresent(String.self, forKey: .venue)
        doi = try? c.decodeIfPresent(String.self, forKey: .doi)
        arxiv_id = try? c.decodeIfPresent(String.self, forKey: .arxiv_id)
        added_at = (try? c.decode(String.self, forKey: .added_at)) ?? ""
        sha256 = (try? c.decode(String.self, forKey: .sha256)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? "manual"
        if let raw = try? c.decode(String.self, forKey: .kind),
           let k = PaperKind(rawValue: raw) {
            kind = k
        } else {
            kind = .paper
        }
        pages = try? c.decodeIfPresent(Int.self, forKey: .pages)
        user_tags = (try? c.decode([String].self, forKey: .user_tags)) ?? []
        user_folder = try? c.decodeIfPresent(String.self, forKey: .user_folder)
        auto = try? c.decodeIfPresent(AutoMeta.self, forKey: .auto)
    }

    /// Union of every tag-like field, lowercased & deduplicated. This is what
    /// search and the sidebar tag filter match against, so adding a tag here
    /// makes it findable everywhere.
    var allTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        let combined = user_tags
            + (auto?.tags ?? [])
            + (auto?.topics ?? [])
            + (auto?.application_areas ?? [])
            + (auto?.methods ?? [])
        for t in combined {
            let k = t.lowercased()
            if !seen.contains(k) {
                seen.insert(k)
                out.append(t)
            }
        }
        return out
    }

    var addedDate: Date? {
        ISO8601.internetDateTime.date(from: added_at)
    }

    /// Canonical web links for the paper, built in one place — the list's
    /// context menu and the detail action row both offer them.
    var arxivURL: URL? {
        guard let id = arxiv_id, !id.isEmpty else { return nil }
        return URL(string: "https://arxiv.org/abs/\(id)")
    }

    var doiURL: URL? {
        guard let doi, !doi.isEmpty else { return nil }
        return URL(string: "https://doi.org/\(doi)")
    }

    var authorsShort: String {
        if authors.isEmpty { return "" }
        if authors.count == 1 { return authors[0] }
        return "\(authors[0]) et al."
    }

    // Non-optional sort keys for SwiftUI's KeyPathComparator (which requires Comparable).
    var yearSort: Int { year ?? Int.min }
    var addedSort: Date { addedDate ?? .distantPast }
    var titleSort: String { title.lowercased() }
}

enum SortPreset: String, CaseIterable, Identifiable, Hashable {
    case recent
    case oldest
    case ratingHighest    // applied in LibraryStore-aware code; comparators=[]
    case titleAZ
    case titleZA
    case yearNewest
    case yearOldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent:        return "Recently added"
        case .oldest:        return "Added (oldest first)"
        case .ratingHighest: return "Rating (high → low)"
        case .titleAZ:       return "Title (A → Z)"
        case .titleZA:       return "Title (Z → A)"
        case .yearNewest:    return "Year (newest first)"
        case .yearOldest:    return "Year (oldest first)"
        }
    }

    var symbol: String {
        switch self {
        case .recent, .yearNewest:        return "arrow.down"
        case .oldest, .yearOldest:        return "arrow.up"
        case .ratingHighest:              return "star.fill"
        case .titleAZ:                    return "textformat.abc"
        case .titleZA:                    return "textformat.abc.dottedunderline"
        }
    }

    var comparators: [KeyPathComparator<Paper>] {
        switch self {
        case .recent:        return [KeyPathComparator(\Paper.addedSort, order: .reverse)]
        case .oldest:        return [KeyPathComparator(\Paper.addedSort, order: .forward)]
        case .ratingHighest: return []  // handled by caller using prefs
        case .titleAZ:       return [KeyPathComparator(\Paper.titleSort, order: .forward)]
        case .titleZA:       return [KeyPathComparator(\Paper.titleSort, order: .reverse)]
        case .yearNewest:    return [KeyPathComparator(\Paper.yearSort, order: .reverse),
                                     KeyPathComparator(\Paper.addedSort, order: .reverse)]
        case .yearOldest:    return [KeyPathComparator(\Paper.yearSort, order: .forward),
                                     KeyPathComparator(\Paper.addedSort, order: .reverse)]
        }
    }
}
