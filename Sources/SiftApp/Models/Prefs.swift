import Foundation

struct PrefsEntry: Codable, Hashable {
    var rating: Int?
    var saved: Bool = false
    var hidden: Bool = false
    var read: Bool = false
    /// Actively being read — pins the paper to the "Currently reading" section
    /// at the top of the list. Set when you open the reader, cleared when you
    /// mark the paper read; also togglable by hand.
    var reading: Bool = false
    var updated_at: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rating = try? c.decodeIfPresent(Int.self, forKey: .rating)
        saved = (try? c.decode(Bool.self, forKey: .saved)) ?? false
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
        read = (try? c.decode(Bool.self, forKey: .read)) ?? false
        reading = (try? c.decode(Bool.self, forKey: .reading)) ?? false
        updated_at = try? c.decodeIfPresent(String.self, forKey: .updated_at)
    }

    init() {}

    /// Always emit every key, with `null` for a missing rating/updated_at, so
    /// prefs.json keeps a stable shape. Older files without `reading` decode
    /// fine (it defaults to false) and gain the key on the next write.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rating, forKey: .rating)
        try c.encode(saved, forKey: .saved)
        try c.encode(hidden, forKey: .hidden)
        try c.encode(read, forKey: .read)
        try c.encode(reading, forKey: .reading)
        try c.encode(updated_at, forKey: .updated_at)
    }

    enum CodingKeys: String, CodingKey {
        case rating, saved, hidden, read, reading, updated_at
    }
}

typealias PrefsMap = [String: PrefsEntry]
