import Foundation

public enum SwitcherLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case russian = "ru"

    public var opposite: SwitcherLanguage {
        switch self {
        case .english: return .russian
        case .russian: return .english
        }
    }

    public var shortLabel: String {
        switch self {
        case .english: return "EN"
        case .russian: return "RU"
        }
    }
}

/// Physical keystroke descriptor (hardware keyCode + shift state).
public struct KeyStroke: Equatable, Hashable, Sendable {
    public let keyCode: UInt16
    public let shifted: Bool

    public init(keyCode: UInt16, shifted: Bool) {
        self.keyCode = keyCode
        self.shifted = shifted
    }
}

/// Bidirectional character & keyCode layout mapper between English (US QWERTY)
/// and Russian (Apple Mac Russian, Russian - PC, or live UCKeyTranslate layout).
public struct KeyboardLayoutMap: Sendable {
    public let enToRu: [Character: Character]
    public let ruToEn: [Character: Character]
    public let keyCodeToEn: [KeyStroke: Character]
    public let keyCodeToRu: [KeyStroke: Character]
    public let enCharToKey: [Character: KeyStroke]
    public let ruCharToKey: [Character: KeyStroke]

    /// Standard Apple macOS "Russian" layout (KeyboardLayout ID 19456) paired with "U.S." (ID 0).
    /// Key differences from Russian - PC:
    /// - keyCode 42 (\ / |) -> ё / Ё
    /// - keyCode 50 (` / ~) -> ] / [
    /// - keyCode 44 (/ / ?) -> . / ,
    /// - Shift+6 -> ,  Shift+7 -> .
    public static let macRussian = KeyboardLayoutMap.makeStatic(russianPC: false)

    /// Russian - PC layout ("RussianWin") paired with "U.S."
    /// - keyCode 50 (` / ~) -> ё / Ё
    /// - keyCode 42 (\ / |) -> \ / /
    /// - keyCode 44 (/ / ?) -> . / ,
    public static let russianPC = KeyboardLayoutMap.makeStatic(russianPC: true)

    public init(
        keyCodeToEn: [KeyStroke: Character],
        keyCodeToRu: [KeyStroke: Character]
    ) {
        self.keyCodeToEn = keyCodeToEn
        self.keyCodeToRu = keyCodeToRu

        var enToRu: [Character: Character] = [:]
        var ruToEn: [Character: Character] = [:]
        var enCharToKey: [Character: KeyStroke] = [:]
        var ruCharToKey: [Character: KeyStroke] = [:]

        // Process letter & core punctuation keycodes in deterministic order so
        // primary keys win over secondary duplicate punctuation symbols.
        let sortedKeys = keyCodeToEn.keys.sorted {
            if $0.keyCode != $1.keyCode { return $0.keyCode < $1.keyCode }
            return !$0.shifted && $1.shifted
        }

        for stroke in sortedKeys {
            guard let enChar = keyCodeToEn[stroke] else { continue }
            if enCharToKey[enChar] == nil {
                enCharToKey[enChar] = stroke
            }
            if let ruChar = keyCodeToRu[stroke] {
                if ruCharToKey[ruChar] == nil {
                    ruCharToKey[ruChar] = stroke
                }
                if enToRu[enChar] == nil {
                    enToRu[enChar] = ruChar
                }
                if ruToEn[ruChar] == nil {
                    ruToEn[ruChar] = enChar
                }
            }
        }

        // Ensure canonical letter mappings for punctuation keys that map to Russian letters
        // are never shadowed by shifted number row punctuation (e.g. Russian "." vs ",").
        let canonicalLetterPairs: [(Character, Character)] = [
            ("[", "х"), ("{", "Х"), ("]", "ъ"), ("}", "Ъ"),
            (";", "ж"), (":", "Ж"), ("'", "э"), ("\"", "Э"),
            (",", "б"), ("<", "Б"), (".", "ю"), (">", "Ю"),
        ]
        for (en, ru) in canonicalLetterPairs {
            enToRu[en] = ru
            ruToEn[ru] = en
        }

        self.enToRu = enToRu
        self.ruToEn = ruToEn
        self.enCharToKey = enCharToKey
        self.ruCharToKey = ruCharToKey
    }

    private static func makeStatic(russianPC: Bool) -> KeyboardLayoutMap {
        // (macOS virtual keyCode, EN unshifted, EN shifted, RU unshifted, RU shifted)
        var table: [(UInt16, Character, Character, Character, Character)] = [
            // Row 1 (letters)
            (12, "q", "Q", "й", "Й"),
            (13, "w", "W", "ц", "Ц"),
            (14, "e", "E", "у", "У"),
            (15, "r", "R", "к", "К"),
            (17, "t", "T", "е", "Е"),
            (16, "y", "Y", "н", "Н"),
            (32, "u", "U", "г", "Г"),
            (34, "i", "I", "ш", "Ш"),
            (31, "o", "O", "щ", "Щ"),
            (35, "p", "P", "з", "З"),
            (33, "[", "{", "х", "Х"),
            (30, "]", "}", "ъ", "Ъ"),
            // Row 2 (letters)
            (0,  "a", "A", "ф", "Ф"),
            (1,  "s", "S", "ы", "Ы"),
            (2,  "d", "D", "в", "В"),
            (3,  "f", "F", "а", "А"),
            (5,  "g", "G", "п", "П"),
            (4,  "h", "H", "р", "Р"),
            (38, "j", "J", "о", "О"),
            (40, "k", "K", "л", "Л"),
            (37, "l", "L", "д", "Д"),
            (41, ";", ":", "ж", "Ж"),
            (39, "'", "\"", "э", "Э"),
            // Row 3 (letters)
            (6,  "z", "Z", "я", "Я"),
            (7,  "x", "X", "ч", "Ч"),
            (8,  "c", "C", "с", "С"),
            (9,  "v", "V", "м", "М"),
            (11, "b", "B", "и", "И"),
            (45, "n", "N", "т", "Т"),
            (46, "m", "M", "ь", "Ь"),
            (43, ",", "<", "б", "Б"),
            (47, ".", ">", "ю", "Ю"),
        ]

        if russianPC {
            table.append(contentsOf: [
                (50, "`", "~", "ё", "Ё"),
                (44, "/", "?", ".", ","),
                (42, "\\", "|", "\\", "/"),
                (18, "1", "!", "1", "!"),
                (19, "2", "@", "2", "\""),
                (20, "3", "#", "3", "№"),
                (21, "4", "$", "4", ";"),
                (23, "5", "%", "5", "%"),
                (22, "6", "^", "6", ":"),
                (26, "7", "&", "7", "?"),
                (28, "8", "*", "8", "*"),
                (25, "9", "(", "9", "("),
                (29, "0", ")", "0", ")"),
                (27, "-", "_", "-", "_"),
                (24, "=", "+", "=", "+"),
            ])
        } else {
            // Apple macOS "Russian" layout
            table.append(contentsOf: [
                (42, "\\", "|", "ё", "Ё"),
                (50, "`", "~", "]", "["),
                (44, "/", "?", "/", "?"),
                (18, "1", "!", "1", "!"),
                (19, "2", "@", "2", "\""),
                (20, "3", "#", "3", "№"),
                (21, "4", "$", "4", "%"),
                (23, "5", "%", "5", ":"),
                (22, "6", "^", "6", ","),
                (26, "7", "&", "7", "."),
                (28, "8", "*", "8", ";"),
                (25, "9", "(", "9", "("),
                (29, "0", ")", "0", ")"),
                (27, "-", "_", "-", "_"),
                (24, "=", "+", "=", "+"),
            ])
        }

        var kcEn: [KeyStroke: Character] = [:]
        var kcRu: [KeyStroke: Character] = [:]
        for (kc, enL, enU, ruL, ruU) in table {
            kcEn[KeyStroke(keyCode: kc, shifted: false)] = enL
            kcEn[KeyStroke(keyCode: kc, shifted: true)] = enU
            kcRu[KeyStroke(keyCode: kc, shifted: false)] = ruL
            kcRu[KeyStroke(keyCode: kc, shifted: true)] = ruU
        }
        return KeyboardLayoutMap(keyCodeToEn: kcEn, keyCodeToRu: kcRu)
    }

    public func character(for stroke: KeyStroke, in language: SwitcherLanguage) -> Character? {
        switch language {
        case .english: return keyCodeToEn[stroke]
        case .russian: return keyCodeToRu[stroke]
        }
    }

    public func keyStroke(for character: Character, in language: SwitcherLanguage) -> KeyStroke? {
        switch language {
        case .english: return enCharToKey[character]
        case .russian: return ruCharToKey[character]
        }
    }

    /// Converts a string character-by-character from one layout to the other.
    public func convert(_ text: String, from source: SwitcherLanguage, to target: SwitcherLanguage) -> String {
        guard source != target else { return text }
        let map = (source == .english) ? enToRu : ruToEn
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            if let mapped = map[ch] {
                result.append(mapped)
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// Detects the likely source layout of an arbitrary text snippet (for converting selections).
    /// When Latin and Cyrillic counts are equal (including punctuation-only selections), falls back
    /// to `fallback` (typically the active keyboard layout).
    public func detectDominantLanguage(
        _ text: String,
        fallback: SwitcherLanguage = .english
    ) -> SwitcherLanguage {
        var latin = 0
        var cyrillic = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) {
                latin += 1
            } else if (v >= 0x0400 && v <= 0x04FF) {
                cyrillic += 1
            }
        }
        if cyrillic > latin { return .russian }
        if latin > cyrillic { return .english }
        return fallback
    }
}

