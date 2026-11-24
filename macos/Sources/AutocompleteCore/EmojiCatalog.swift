import Foundation

public enum EmojiSkinTone: String, CaseIterable, Identifiable, Sendable {
    case none = ""
    case light = "\u{1F3FB}"
    case mediumLight = "\u{1F3FC}"
    case medium = "\u{1F3FD}"
    case mediumDark = "\u{1F3FE}"
    case dark = "\u{1F3FF}"

    public var id: String { rawValue }
}

public struct EmojiEntry: Equatable, Sendable {
    public let shortcode: String
    public let emoji: String
    public let aliases: [String]

    public init(shortcode: String, emoji: String, aliases: [String] = []) {
        self.shortcode = shortcode
        self.emoji = emoji
        self.aliases = aliases
    }
}

/// Lightweight, zero-bloat emoji shortcode & emoticon matcher modeled after Cotypist's
/// instant colon-trigger emoji suggestions (":joy", ":thumbsup", ":rocket", etc.).
public enum EmojiCatalog {
    public static let entries: [EmojiEntry] = [
        EmojiEntry(shortcode: "smile", emoji: "😄", aliases: ["happy", "grin", "улыбка"]),
        EmojiEntry(shortcode: "grinning", emoji: "😀", aliases: ["grin"]),
        EmojiEntry(shortcode: "joy", emoji: "😂", aliases: ["laugh", "lol", "haha", "смех"]),
        EmojiEntry(shortcode: "rofl", emoji: "🤣", aliases: ["lmao"]),
        EmojiEntry(shortcode: "blush", emoji: "😊", aliases: ["warm"]),
        EmojiEntry(shortcode: "slightly_smiling_face", emoji: "🙂", aliases: ["slight_smile"]),
        EmojiEntry(shortcode: "wink", emoji: "😉", aliases: ["подмиг"]),
        EmojiEntry(shortcode: "heart_eyes", emoji: "😍", aliases: ["love_eyes"]),
        EmojiEntry(shortcode: "smiling_face_with_3_hearts", emoji: "🥰", aliases: ["adore"]),
        EmojiEntry(shortcode: "kissing_heart", emoji: "😘", aliases: ["kiss"]),
        EmojiEntry(shortcode: "thinking", emoji: "🤔", aliases: ["think", "hmm", "думаю"]),
        EmojiEntry(shortcode: "sunglasses", emoji: "😎", aliases: ["cool", "круто"]),
        EmojiEntry(shortcode: "sweat_smile", emoji: "😅", aliases: ["phew", "nervous"]),
        EmojiEntry(shortcode: "upside_down_face", emoji: "🙃", aliases: ["sarcasm"]),
        EmojiEntry(shortcode: "neutral_face", emoji: "😐", aliases: ["meh"]),
        EmojiEntry(shortcode: "rolling_eyes", emoji: "🙄", aliases: ["eyeroll"]),
        EmojiEntry(shortcode: "grimacing", emoji: "😬", aliases: ["awkward"]),
        EmojiEntry(shortcode: "relieved", emoji: "😌", aliases: ["calm"]),
        EmojiEntry(shortcode: "pensive", emoji: "😔", aliases: ["sad"]),
        EmojiEntry(shortcode: "cry", emoji: "😢", aliases: ["tear", "грусть"]),
        EmojiEntry(shortcode: "sob", emoji: "😭", aliases: ["crying"]),
        EmojiEntry(shortcode: "angry", emoji: "😠", aliases: ["mad"]),
        EmojiEntry(shortcode: "exploding_head", emoji: "🤯", aliases: ["mindblown", "wow"]),
        EmojiEntry(shortcode: "flushed", emoji: "😳", aliases: ["shocked"]),
        EmojiEntry(shortcode: "scream", emoji: "😱", aliases: ["omg"]),
        EmojiEntry(shortcode: "shrug", emoji: "🤷", aliases: ["idk"]),
        EmojiEntry(shortcode: "facepalm", emoji: "🤦", aliases: ["ugh"]),
        EmojiEntry(shortcode: "saluting_face", emoji: "🫡", aliases: ["salute"]),
        EmojiEntry(shortcode: "melting_face", emoji: "🫠", aliases: ["melt"]),
        EmojiEntry(shortcode: "party", emoji: "🥳", aliases: ["celebrate"]),
        EmojiEntry(shortcode: "thumbsup", emoji: "👍", aliases: ["+1", "ok", "yes", "класс", "ок"]),
        EmojiEntry(shortcode: "thumbsdown", emoji: "👎", aliases: ["-1", "no"]),
        EmojiEntry(shortcode: "clap", emoji: "👏", aliases: ["applause", "bravo"]),
        EmojiEntry(shortcode: "wave", emoji: "👋", aliases: ["hello", "hi", "bye", "привет"]),
        EmojiEntry(shortcode: "pray", emoji: "🙏", aliases: ["thanks", "please", "спасибо"]),
        EmojiEntry(shortcode: "muscle", emoji: "💪", aliases: ["strong"]),
        EmojiEntry(shortcode: "ok_hand", emoji: "👌", aliases: ["perfect"]),
        EmojiEntry(shortcode: "raised_hands", emoji: "🙌", aliases: ["hooray"]),
        EmojiEntry(shortcode: "handshake", emoji: "🤝", aliases: ["deal", "agreed"]),
        EmojiEntry(shortcode: "point_right", emoji: "👉", aliases: ["arrow_right"]),
        EmojiEntry(shortcode: "point_down", emoji: "👇", aliases: ["arrow_down"]),
        EmojiEntry(shortcode: "eyes", emoji: "👀", aliases: ["look", "watching"]),
        EmojiEntry(shortcode: "brain", emoji: "🧠", aliases: ["smart"]),
        EmojiEntry(shortcode: "heart", emoji: "❤️", aliases: ["love", "сердце"]),
        EmojiEntry(shortcode: "blue_heart", emoji: "💙", aliases: []),
        EmojiEntry(shortcode: "green_heart", emoji: "💚", aliases: []),
        EmojiEntry(shortcode: "broken_heart", emoji: "💔", aliases: []),
        EmojiEntry(shortcode: "fire", emoji: "🔥", aliases: ["lit", "hot", "огонь"]),
        EmojiEntry(shortcode: "sparkles", emoji: "✨", aliases: ["magic", "shiny"]),
        EmojiEntry(shortcode: "star", emoji: "⭐", aliases: ["favorite"]),
        EmojiEntry(shortcode: "100", emoji: "💯", aliases: ["hundred"]),
        EmojiEntry(shortcode: "tada", emoji: "🎉", aliases: ["confetti", "congrats", "ура"]),
        EmojiEntry(shortcode: "rocket", emoji: "🚀", aliases: ["launch", "ship", "ракета"]),
        EmojiEntry(shortcode: "zap", emoji: "⚡", aliases: ["fast", "lightning"]),
        EmojiEntry(shortcode: "bulb", emoji: "💡", aliases: ["idea", "идея"]),
        EmojiEntry(shortcode: "check", emoji: "✅", aliases: ["done", "white_check_mark", "готово"]),
        EmojiEntry(shortcode: "cross", emoji: "❌", aliases: ["x", "wrong", "fail"]),
        EmojiEntry(shortcode: "warning", emoji: "⚠️", aliases: ["alert", "caution"]),
        EmojiEntry(shortcode: "question", emoji: "❓", aliases: ["ask"]),
        EmojiEntry(shortcode: "exclamation", emoji: "❗", aliases: ["important"]),
        EmojiEntry(shortcode: "pin", emoji: "📌", aliases: ["pushpin"]),
        EmojiEntry(shortcode: "memo", emoji: "📝", aliases: ["note", "write"]),
        EmojiEntry(shortcode: "calendar", emoji: "📅", aliases: ["date", "schedule"]),
        EmojiEntry(shortcode: "clock", emoji: "🕒", aliases: ["time"]),
        EmojiEntry(shortcode: "hourglass", emoji: "⏳", aliases: ["waiting"]),
        EmojiEntry(shortcode: "lock", emoji: "🔒", aliases: ["secure", "private"]),
        EmojiEntry(shortcode: "key", emoji: "🔑", aliases: ["password"]),
        EmojiEntry(shortcode: "email", emoji: "📧", aliases: ["mail", "envelope"]),
        EmojiEntry(shortcode: "inbox", emoji: "📥", aliases: []),
        EmojiEntry(shortcode: "link", emoji: "🔗", aliases: ["url"]),
        EmojiEntry(shortcode: "gear", emoji: "⚙️", aliases: ["settings", "config"]),
        EmojiEntry(shortcode: "wrench", emoji: "🔧", aliases: ["fix", "tool"]),
        EmojiEntry(shortcode: "bug", emoji: "🐛", aliases: ["issue"]),
        EmojiEntry(shortcode: "laptop", emoji: "💻", aliases: ["computer", "code", "mac"]),
        EmojiEntry(shortcode: "phone", emoji: "📱", aliases: ["mobile"]),
        EmojiEntry(shortcode: "coffee", emoji: "☕", aliases: ["кофе"]),
        EmojiEntry(shortcode: "pizza", emoji: "🍕", aliases: []),
        EmojiEntry(shortcode: "beer", emoji: "🍺", aliases: ["cheers"]),
        EmojiEntry(shortcode: "sun", emoji: "☀️", aliases: ["sunny"]),
        EmojiEntry(shortcode: "moon", emoji: "🌙", aliases: ["night"]),
        EmojiEntry(shortcode: "cloud", emoji: "☁️", aliases: []),
        EmojiEntry(shortcode: "rain", emoji: "🌧️", aliases: []),
        EmojiEntry(shortcode: "snowflake", emoji: "❄️", aliases: ["cold", "snow"]),
        EmojiEntry(shortcode: "checkered_flag", emoji: "🏁", aliases: ["finish"]),
        EmojiEntry(shortcode: "trophy", emoji: "🏆", aliases: ["win", "winner"]),
        EmojiEntry(shortcode: "target", emoji: "🎯", aliases: ["goal", "dart", "цель"]),
        EmojiEntry(shortcode: "chart", emoji: "📈", aliases: ["growth", "stonks"]),
        EmojiEntry(shortcode: "money", emoji: "💰", aliases: ["cash", "dollar"]),
        EmojiEntry(shortcode: "package", emoji: "📦", aliases: ["box", "release"]),
        EmojiEntry(shortcode: "magnifying_glass", emoji: "🔍", aliases: ["search", "find"]),
        EmojiEntry(shortcode: "bell", emoji: "🔔", aliases: ["notify", "reminder"]),
        EmojiEntry(shortcode: "bookmark", emoji: "🔖", aliases: ["save"]),
        EmojiEntry(shortcode: "trash", emoji: "🗑️", aliases: ["delete"]),
        EmojiEntry(shortcode: "sparkles_heart", emoji: "💖", aliases: ["sparkling_heart"]),
        EmojiEntry(shortcode: "cat", emoji: "🐱", aliases: ["kitty", "кот"]),
        EmojiEntry(shortcode: "dog", emoji: "🐶", aliases: ["puppy"]),
    ]

    private static let skinToneCapable: Set<String> = [
        "👍", "👎", "👏", "👋", "🙏", "💪", "👌", "🙌", "👉", "👇", "🤷", "🤦"
    ]

    /// Matches a trailing `:query` or `:query:` shortcode at the end of `prefix`.
    public static func match(prefix: String, skinTone: EmojiSkinTone = .none) -> ActiveSuggestion? {
        guard !prefix.isEmpty else { return nil }

        // Look back up to 32 characters for a ':' that starts a shortcode token.
        let tail = String(prefix.suffix(32))
        let hasClosingColon = tail.hasSuffix(":") && tail.count >= 4
        let searchRange = hasClosingColon ? tail.startIndex..<tail.index(before: tail.endIndex) : tail.startIndex..<tail.endIndex
        guard let colonIndex = tail[searchRange].lastIndex(of: ":") else { return nil }

        // Must be at start of text or immediately preceded by whitespace.
        if colonIndex > tail.startIndex {
            let before = tail[tail.index(before: colonIndex)]
            if !before.isWhitespace { return nil }
        }

        let rawAfterColon = String(tail[tail.index(after: colonIndex)...])
        let query = (hasClosingColon ? String(rawAfterColon.dropLast()) : rawAfterColon).lowercased()

        // Require at least 2 characters (e.g. ":ok", ":jo", ":ro") so normal colons in prose never fire.
        guard query.count >= 2 else { return nil }
        guard query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "+" }) else {
            return nil
        }

        // Exact shortcode/alias match first, then prefix match.
        let matched: EmojiEntry? =
            entries.first(where: { $0.shortcode == query || $0.aliases.contains(query) })
            ?? entries.first(where: { $0.shortcode.hasPrefix(query) || $0.aliases.contains(where: { $0.hasPrefix(query) }) })

        guard let entry = matched else { return nil }
        let renderedEmoji: String
        if skinTone != .none, skinToneCapable.contains(entry.emoji) {
            renderedEmoji = entry.emoji + skinTone.rawValue
        } else {
            renderedEmoji = entry.emoji
        }
        let triggerLen = tail.distance(from: colonIndex, to: tail.endIndex)
        return ActiveSuggestion(
            text: renderedEmoji,
            kind: .emoji(triggerLength: triggerLen, shortcode: ":\(entry.shortcode):"),
            anchorPrefix: prefix
        )
    }
}

