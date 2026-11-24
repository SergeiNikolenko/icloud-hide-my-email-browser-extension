import Foundation
import SQLite3

struct CarambaImportedSettings: Sendable {
    let autoEnabled: Bool?
    let autocorrectOn: Bool?
    let yofikatorOn: Bool?
    let altEnabled: Bool?
    let singleShiftEnabled: Bool?
    let splitShiftEnabled: Bool?
    let soundsEnabled: Bool?
    let pastePlainTextShortcut: PastePlainTextShortcut?
}

struct CarambaImportSummary: Sendable {
    let words: [String]
    let appBundleIDs: [String]
    let sourcePath: String?
    let settings: CarambaImportedSettings?
    let plistPath: String?
}

/// Reads user word & app exceptions from Caramba.sqlite AND user preferences from
/// tech.caramba.switcher.plist (read-only).
enum CarambaImporter {
    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Containers/tech.caramba.switcher/Data/Library/Application Support/Caramba Switcher Pro/Caramba.sqlite",
            "\(home)/Library/Containers/tech.caramba.switcher/Data/Library/Application Support/Caramba Switcher/Caramba.sqlite",
            "\(home)/Library/Application Support/Caramba Switcher Pro/Caramba.sqlite",
            "\(home)/Library/Application Support/Caramba Switcher/Caramba.sqlite",
        ]
    }

    static var candidatePlistPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Containers/tech.caramba.switcher/Data/Library/Preferences/tech.caramba.switcher.plist",
            "\(home)/Library/Preferences/tech.caramba.switcher.plist",
        ]
    }

    static func findExistingDatabase() -> String? {
        candidatePaths.first { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
                return false
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            return size > 0
        }
    }

    static func findExistingPlist() -> String? {
        candidatePlistPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func importAll() -> CarambaImportSummary {
        importExceptions(from: nil)
    }

    static func importExceptions(from explicitPath: String? = nil) -> CarambaImportSummary {
        let plistPath = findExistingPlist()
        let settings = plistPath.flatMap(readPlistSettings(at:))
        var words: Set<String> = []
        var apps: Set<String> = []
        let path = explicitPath ?? findExistingDatabase()

        if let path {
            var db: OpaquePointer?
            if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
                defer { sqlite3_close(db) }

                var stmt: OpaquePointer?
                // Only import explicit/repeated visible rules (skip legacy ZADDITIONS = 0 auto-revert typos
                // and malformed noise like repeated letters or embedded punctuation).
                let wordQuery = "SELECT ZPATTERN FROM ZAUTOSWITCHEXCEPTION WHERE (ZDISABLED IS NULL OR ZDISABLED = 0) AND (ZVISIBLE IS NULL OR ZVISIBLE = 1) AND ZADDITIONS > 0 AND ZPATTERN IS NOT NULL"
                if sqlite3_prepare_v2(db, wordQuery, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let cStr = sqlite3_column_text(stmt, 0) {
                            let word = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            if isPlausibleExceptionWord(word) { words.insert(word) }
                        }
                    }
                    sqlite3_finalize(stmt)
                }

                stmt = nil
                let appQuery = "SELECT ZBUNDLEID FROM ZAPPEXCEPTION WHERE (ZENABLED IS NULL OR ZENABLED = 1) AND ZBUNDLEID IS NOT NULL"
                if sqlite3_prepare_v2(db, appQuery, -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let cStr = sqlite3_column_text(stmt, 0) {
                            let bid = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !bid.isEmpty { apps.insert(bid) }
                        }
                    }
                    sqlite3_finalize(stmt)
                }
            } else if let db {
                sqlite3_close(db)
            }
        }

        return CarambaImportSummary(
            words: words.sorted(),
            appBundleIDs: apps.sorted(),
            sourcePath: path,
            settings: settings,
            plistPath: plistPath
        )
    }

    /// Filters out accidental typo / key-repeat / punctuation junk from legacy Caramba databases.
    static func isPlausibleExceptionWord(_ word: String) -> Bool {
        guard word.count >= 2, word.count <= 40 else { return false }
        let scalars = Array(word.unicodeScalars)
        // Reject embedded punctuation spam (e.g. "рзюме!!и") — allow letters, digits, hyphen, apostrophe.
        for s in scalars {
            if CharacterSet.letters.contains(s) || CharacterSet.decimalDigits.contains(s) || s == "-" || s == "'" {
                continue
            }
            return false
        }
        // Reject key-mash repeats of 4+ identical characters (e.g. "фффффф").
        var run = 1
        for i in 1..<scalars.count {
            if scalars[i] == scalars[i - 1] {
                run += 1
                if run >= 4 { return false }
            } else {
                run = 1
            }
        }
        return true
    }

    private static func readPlistSettings(at path: String) -> CarambaImportedSettings? {
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        var pasteShortcut: PastePlainTextShortcut?
        if let jsonStr = dict["KeyboardShortcuts_tech.caramba.switcher.paste-no-format"] as? String,
           let jsonData = jsonStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let keyCode = obj["carbonKeyCode"] as? Int,
           let mods = obj["carbonModifiers"] as? Int,
           keyCode == 9 {
            // Carbon modifiers: cmdKey = 256, shiftKey = 512, optionKey = 2048
            if mods == 256 { pasteShortcut = .cmdV }
            else if mods == 768 { pasteShortcut = .cmdShiftV }
            else if mods == 2816 { pasteShortcut = .cmdOptionShiftV }
        }
        return CarambaImportedSettings(
            autoEnabled: dict["tech.caramba.switcher.auto-enabled"] as? Bool,
            autocorrectOn: dict["tech.caramba.switcher.autocorrect-on"] as? Bool,
            yofikatorOn: dict["tech.caramba.switcher.yofikator-on"] as? Bool,
            altEnabled: dict["tech.caramba.switcher.alt-enabled"] as? Bool,
            singleShiftEnabled: dict["tech.caramba.switcher.singleshift-enabled"] as? Bool,
            splitShiftEnabled: dict["tech.caramba.switcher.splitshift-enabled"] as? Bool,
            soundsEnabled: dict["tech.caramba.switcher.sounds.enabled"] as? Bool,
            pastePlainTextShortcut: pasteShortcut
        )
    }
}

