import Foundation

/// Exact port of Caramba Core's word boundary helpers and 18 built-in regex filters
/// (0x1002e35bc / 0x1002e3c28 / 0x100430f29..0x100431140).
public enum WordFilters {
    /// Word boundary characters matching bitmask 0x0000200100002600 (\t, \n, \r, ' ', '-').
    public static let boundaryScalars: Set<Unicode.Scalar> = ["\t", "\n", "\r", " ", "-"]

    /// Trailing punctuation stripped on fallback lookup, matching bitmask 0x20000000c00057a9.
    public static let trailingTrimScalars: Set<Unicode.Scalar> = [
        "!", "$", "&", "(", ")", "*", "+", "-", "/", "?", "@", "^"
    ]

    public static func isBoundary(_ scalar: Unicode.Scalar) -> Bool {
        boundaryScalars.contains(scalar)
    }

    public static func endsWithBoundary(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last else { return false }
        return boundaryScalars.contains(last)
    }

    public static func trimmingTrailingBoundaries(_ word: String) -> String {
        var scalars = word.unicodeScalars[...]
        while let last = scalars.last, boundaryScalars.contains(last) {
            scalars = scalars.dropLast()
        }
        return String(scalars)
    }

    public static func trimmingTrailingPunctuation(_ word: String) -> String {
        var scalars = word.unicodeScalars[...]
        while let last = scalars.last, trailingTrimScalars.contains(last) {
            scalars = scalars.dropLast()
        }
        return String(scalars)
    }

    private static func compile(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let reDigitLettersDigit = compile(#"[0-9]+([a-zA-Z]+)[0-9]+"#)
    private static let reLettersDigitsLetters = compile(#"^([a-zA-Z]+)[0-9]{2,}([a-zA-Z]+)"#)
    private static let reHasDigit = compile(#"\d+"#)
    private static let reHasPunct = compile(#"[[:punct:]]+"#)
    private static let reHasLower = compile(#"[a-z]+"#)
    private static let reHasUpper = compile(#"[A-Z]+"#)
    private static let reInitialsEnSlash = compile(#"^[A-Z]/[A-Z]/[A-Z][a-z\[\];',.]+$"#)
    private static let reOneCharThenUpper = compile(#"^.{1}[A-Z]{1}"#)
    private static let reAddressAbbrev = compile(#"^([A-Za-z<]|ek|gun|gth|ghjcg|Ek|Gth|Ghjcg)/[A-Z][a-z\[\];',.]+$"#)
    private static let reCamelCase = compile(#"^.{2,}[A-Z]+"#)
    private static let reAllCapsRussianInEn = compile(#"^[QWERTYUIOP{}ASDFGHJKL":|ZXCVBNM<>?]+[!?/]*$"#)
    private static let reEnLettersExclam = compile(#"^[a-zA-Z]+[!?]+$"#)

    private static let reRussianLicensePlates: [NSRegularExpression] = [
        compile(#"(?i)^[АВЕКМНОРСТУХ]{1}\d{3}[АВЕКМНОРСТУХ]{2}"#),
        compile(#"(?i)^[АВЕКМНОРСТУХ]{2}\d{3}[АВЕКМНОРСТУХ]{1}"#),
        compile(#"(?i)^\d{4}[АВЕКМНОРСТУХ]{2}"#),
        compile(#"(?i)^[АВЕКМНОРСТУХ]{2}\d{3}"#),
        compile(#"(?i)^[АВЕКМНОРСТУХ]{2}\d{4}"#),
    ]

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Returns true if the typed token looks like a password, license plate,
    /// camelCase identifier, or alphanumeric technical token that should NEVER be auto-switched.
    public static func shouldSkipAutoSwitch(typedWord: String, convertedWord: String) -> Bool {
        let core = trimmingTrailingBoundaries(typedWord)
        guard !core.isEmpty else { return true }

        let convertedCore = trimmingTrailingBoundaries(convertedWord)
        let hasAnyLetter = core.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        let convertedHasLetter = convertedCore.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if !hasAnyLetter && !convertedHasLetter {
            return true
        }

        // Never auto-switch URLs, emails, paths, or mixed Latin+Cyrillic tokens.
        if core.contains("://") || core.contains("@") || core.hasPrefix("http") || core.hasPrefix("www.") {
            return true
        }

        let hasLatin = core.unicodeScalars.contains {
            ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
        }
        let hasCyrillic = core.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        if hasLatin && hasCyrillic {
            return true
        }

        // Russian car license plates (both typed directly and converted).
        for plate in reRussianLicensePlates {
            if matches(plate, core) || matches(plate, convertedCore) {
                return true
            }
        }

        // Explicit Russian address / initials typed in EN layout (e.g. ek/Ktybyf, A/C/Pushkin):
        // Caramba explicitly allows switching these.
        if matches(reInitialsEnSlash, core) || matches(reAddressAbbrev, core) {
            return false
        }

        // ALL CAPS Russian typed in EN layout (e.g. GHBDTN, GHBDTN!) MUST be allowed to switch.
        let isAllCapsEn = matches(reAllCapsRussianInEn, core)

        // Password detector (0x1002e35bc): length >= 8 with >= 3 character classes
        // (digits, punctuation, lowercase, uppercase) — unless it's a normal word with trailing !/?
        if core.count >= 8 && !isAllCapsEn && !matches(reEnLettersExclam, core) {
            var classes = 0
            if matches(reHasDigit, core) { classes += 1 }
            if matches(reHasPunct, core) { classes += 1 }
            if matches(reHasLower, core) { classes += 1 }
            if matches(reHasUpper, core) { classes += 1 }
            if classes >= 3 {
                return true
            }
        }

        // Alphanumeric technical codes: 123abc456, foo12bar
        if matches(reDigitLettersDigit, core) || matches(reLettersDigitsLetters, core) {
            return true
        }

        // camelCase / brand names like iPhone, iOS, macOS, myVariable (unless ALL CAPS).
        if !isAllCapsEn {
            if matches(reCamelCase, core) {
                if !isDoubleCapsShape(core) {
                    return true
                }
            }
            if matches(reOneCharThenUpper, core) {
                let chars = Array(core)
                if chars.count >= 2, chars[0].isLowercase, chars[1].isUppercase {
                    return true
                }
            }
        }

        return false
    }

    /// Matches Double-Caps shape: length >= 3, first two characters uppercase, third character lowercase
    /// (e.g. ПРивет, HEllo).
    public static func isDoubleCapsShape(_ word: String) -> Bool {
        let core = trimmingTrailingBoundaries(word)
        let chars = Array(core)
        guard chars.count >= 3 else { return false }
        return chars[0].isLetter && chars[0].isUppercase
            && chars[1].isLetter && chars[1].isUppercase
            && chars[2].isLetter && chars[2].isLowercase
    }
}
