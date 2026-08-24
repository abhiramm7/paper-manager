import Foundation

/// One entry in the library's tag vocabulary. Stored in `<library>/tags.json`.
struct TagEntry: Codable, Hashable {
    var name: String                  // canonical kebab-case form
    var count: Int                    // # of papers currently using this tag
    var firstSeen: String             // ISO-8601 timestamp
    var description: String?          // optional one-line semantic description

    enum CodingKeys: String, CodingKey {
        case name, count, description
        case firstSeen = "first_seen"
    }
}

/// Library-wide tag vocabulary. Persisted at `<library>/tags.json` and kept in
/// sync with the actual papers via `rebuildFromPapers(_:)`. Used to:
///   1. Steer the LLM toward existing tags (`promptVocabulary(maxTags:)`)
///   2. Canonicalize LLM-proposed tags against existing ones (`canonicalize(_:)`)
@MainActor
final class TagStore: ObservableObject {
    @Published var vocabulary: [String: TagEntry] = [:]

    private let storeURL: URL

    init(libraryRoot: URL) {
        self.storeURL = libraryRoot.appendingPathComponent("tags.json")
        load()
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: TagEntry].self, from: data) else {
            vocabulary = [:]
            return
        }
        vocabulary = decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(vocabulary) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    var fileURL: URL { storeURL }

    // MARK: - Sync with papers

    /// Recompute counts from the full paper list. Preserves descriptions and
    /// first-seen timestamps for existing entries; drops zero-count entries
    /// only if they have no description (so user-curated knowledge sticks).
    func rebuildFromPapers(_ papers: [Paper]) {
        var counts: [String: Int] = [:]
        for p in papers {
            for t in p.allTags {
                let canon = t.lowercased()
                counts[canon, default: 0] += 1
            }
        }
        let now = ISO8601.now()
        var next: [String: TagEntry] = [:]
        for (name, count) in counts {
            let existing = vocabulary[name]
            next[name] = TagEntry(
                name: name,
                count: count,
                firstSeen: existing?.firstSeen ?? now,
                description: existing?.description)
        }
        // Preserve zero-count entries that have a user-written description.
        for (name, entry) in vocabulary where counts[name] == nil {
            if let desc = entry.description, !desc.isEmpty {
                next[name] = TagEntry(name: name, count: 0, firstSeen: entry.firstSeen, description: desc)
            }
        }
        vocabulary = next
        save()
    }

    /// After a paper gets re-tagged, fold its new tag list into the vocabulary.
    /// Increments counts for tags the paper now has; doesn't decrement old ones
    /// (rebuildFromPapers handles that on next rescan).
    func recordUsage(_ tags: [String]) {
        let now = ISO8601.now()
        for t in tags {
            let name = t.lowercased()
            if var entry = vocabulary[name] {
                entry.count += 1
                vocabulary[name] = entry
            } else {
                vocabulary[name] = TagEntry(name: name, count: 1, firstSeen: now, description: nil)
            }
        }
        save()
    }

    // MARK: - Canonicalization

    /// Map an LLM-proposed tag to an existing vocabulary tag if a close match
    /// exists; otherwise return the normalized form (which becomes a new tag).
    ///
    /// Match order: exact → lowercased → underscore→hyphen → singular↔plural.
    /// "Closeness" stops there — we don't do Levenshtein because it produces
    /// silent merges that confuse users (e.g. `lora` and `lloyd` are close).
    func canonicalize(_ proposed: String) -> String {
        let lower = proposed.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return lower }

        if vocabulary[lower] != nil { return lower }

        let dehyphen = lower.replacingOccurrences(of: "_", with: "-")
        if vocabulary[dehyphen] != nil { return dehyphen }

        if dehyphen.hasSuffix("s") {
            let singular = String(dehyphen.dropLast())
            if vocabulary[singular] != nil { return singular }
        } else {
            let plural = dehyphen + "s"
            if vocabulary[plural] != nil { return plural }
        }

        // No existing tag matched — keep the normalized form as a new tag.
        return dehyphen
    }

    func canonicalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in tags {
            let c = canonicalize(t)
            if !c.isEmpty, seen.insert(c).inserted { out.append(c) }
        }
        return out
    }

    // MARK: - Prompt context

    /// Top N tags by count, alphabetized within each tier. Used to ground the
    /// LLM prompt so it prefers existing tags over inventing new ones.
    func topTags(_ n: Int = 80) -> [TagEntry] {
        vocabulary.values
            .filter { $0.count > 0 }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name < rhs.name
            }
            .prefix(n)
            .map { $0 }
    }

    /// Render the top N tags as a prompt-ready string. Includes descriptions
    /// when available. Empty string if the vocabulary is empty (cold start).
    func promptVocabulary(maxTags: Int = 80) -> String {
        let top = topTags(maxTags)
        guard !top.isEmpty else { return "" }
        let withDesc = top.compactMap { e -> String? in
            guard let d = e.description, !d.isEmpty else { return nil }
            return "- \(e.name): \(d)"
        }
        let plain = top
            .filter { ($0.description ?? "").isEmpty }
            .map { $0.name }
        var lines: [String] = []
        if !withDesc.isEmpty {
            lines.append("Tags with descriptions:")
            lines.append(contentsOf: withDesc)
        }
        if !plain.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Other existing tags:")
            lines.append(plain.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers
}
