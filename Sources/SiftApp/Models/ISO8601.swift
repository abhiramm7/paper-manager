import Foundation

/// Shared ISO-8601 formatter. Building an `ISO8601DateFormatter` costs far more
/// than the parse it performs, and `Paper.addedDate` sits on the list's sort
/// path — the old per-call formatter meant one allocation per comparison.
/// Configured once and never mutated, so it's safe to share.
enum ISO8601 {
    /// `2026-06-01T12:00:00Z` — the shape every timestamp in the library uses
    /// (metadata.json `added_at`, prefs.json `updated_at`, tags.json `first_seen`).
    static let internetDateTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Now, stamped the way every writer in the app stamps it. (The old Python
    /// CLI wrote "+00:00" instead of "Z" — same instant, and both decode.)
    static func now() -> String {
        internetDateTime.string(from: Date())
    }
}
