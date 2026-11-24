import Carbon
import Foundation
import LayoutSwitcherCore

struct KeyboardSourceInfo: Sendable {
    let id: String
    let localizedName: String
    let language: SwitcherLanguage?
}

/// Manages macOS keyboard input sources via Carbon HIToolbox (TIS) and builds live
/// UCKeyTranslate character maps for the user's actual installed EN and RU layouts.
@MainActor
final class InputSourceManager {
    private var englishSource: TISInputSource?
    private var russianSource: TISInputSource?
    private var allKeyboardSources: [TISInputSource] = []

    var onLayoutChanged: ((SwitcherLanguage, String) -> Void)?
    var onLayoutMapRebuilt: ((KeyboardLayoutMap) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        reloadSources()
        observeSystemNotifications()
    }

    private func observeSystemNotifications() {
        let dnc = DistributedNotificationCenter.default()
        let selectedObs = dnc.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let (lang, name) = self.currentLayoutSnapshot()
                self.onLayoutChanged?(lang, name)
            }
        }
        let enabledObs = dnc.addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadSources()
                let map = self.buildLiveLayoutMap()
                self.onLayoutMapRebuilt?(map)
                let (lang, name) = self.currentLayoutSnapshot()
                self.onLayoutChanged?(lang, name)
            }
        }
        observers = [selectedObs, enabledObs]
    }

    func reloadSources() {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue as Any,
            kTISPropertyInputSourceIsEnabled: kCFBooleanTrue as Any,
        ]
        guard let cfList = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return
        }

        allKeyboardSources = cfList
        englishSource = nil
        russianSource = nil

        for source in cfList {
            let sid = sourceID(source)
            let langs = sourceLanguages(source)
            if russianSource == nil,
               sid.localizedCaseInsensitiveContains("Russian") || langs.contains(where: { $0.hasPrefix("ru") }) {
                russianSource = source
            } else if englishSource == nil,
                      sid == "com.apple.keylayout.US" || sid == "com.apple.keylayout.ABC"
                        || langs.contains(where: { $0.hasPrefix("en") }) {
                englishSource = source
            }
        }

        // Prefer exact US/ABC if a non-US English layout came earlier.
        if let us = cfList.first(where: { sourceID($0) == "com.apple.keylayout.US" || sourceID($0) == "com.apple.keylayout.ABC" }) {
            englishSource = us
        }
    }

    func currentLayoutSnapshot() -> (language: SwitcherLanguage, name: String) {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return (.english, "U.S.")
        }
        let sid = sourceID(current)
        let name = sourceName(current)
        let langs = sourceLanguages(current)
        if sid.localizedCaseInsensitiveContains("Russian") || langs.contains(where: { $0.hasPrefix("ru") }) {
            return (.russian, name)
        }
        return (.english, name)
    }

    /// Single non-blocking layout selection attempt (safe to call from MainActor while sleeping
    /// between retries on a background queue).
    @discardableResult
    func selectOnce(language: SwitcherLanguage) -> Bool {
        if englishSource == nil || russianSource == nil {
            reloadSources()
        }
        guard let target = (language == .english ? englishSource : russianSource) else {
            return false
        }
        let targetID = sourceID(target)
        TISSelectInputSource(target)
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           sourceID(current) == targetID {
            let (lang, name) = currentLayoutSnapshot()
            onLayoutChanged?(lang, name)
            return true
        }
        let (lang, name) = currentLayoutSnapshot()
        onLayoutChanged?(lang, name)
        return lang == language
    }

    /// Switches macOS active keyboard layout to the target language using Caramba's
    /// verified retry loop (default: 2 retries, 25ms apart).
    @discardableResult
    func select(language: SwitcherLanguage, retries: Int = 2, retryDelayMs: Int = 25) -> Bool {
        for attempt in 0...max(0, retries) {
            if selectOnce(language: language) {
                return true
            }
            if attempt < retries {
                Thread.sleep(forTimeInterval: Double(retryDelayMs) / 1000.0)
            }
        }
        return currentLayoutSnapshot().language == language
    }

    /// Cycles to the next enabled keyboard layout (used by Single Shift) with retry verification.
    @discardableResult
    func cycleToNextLayout(retries: Int = 2, retryDelayMs: Int = 25) -> SwitcherLanguage {
        if allKeyboardSources.count < 2 {
            reloadSources()
        }
        guard allKeyboardSources.count >= 2,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            let next = currentLayoutSnapshot().language.opposite
            _ = select(language: next, retries: retries, retryDelayMs: retryDelayMs)
            return next
        }
        let currentID = sourceID(current)
        let idx = allKeyboardSources.firstIndex { sourceID($0) == currentID } ?? 0
        let nextSource = allKeyboardSources[(idx + 1) % allKeyboardSources.count]
        let nextID = sourceID(nextSource)
        for attempt in 0...max(0, retries) {
            TISSelectInputSource(nextSource)
            if let active = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
               sourceID(active) == nextID {
                break
            }
            if attempt < retries {
                Thread.sleep(forTimeInterval: Double(retryDelayMs) / 1000.0)
            }
        }
        let (lang, name) = currentLayoutSnapshot()
        onLayoutChanged?(lang, name)
        return lang
    }

    /// Builds a KeyboardLayoutMap directly from the live UCKeyboardLayout tables of the
    /// user's installed EN and RU input sources.
    func buildLiveLayoutMap() -> KeyboardLayoutMap {
        if englishSource == nil || russianSource == nil {
            reloadSources()
        }
        guard let enSrc = englishSource, let ruSrc = russianSource,
              let enTable = translateAllKeys(source: enSrc),
              let ruTable = translateAllKeys(source: ruSrc),
              !enTable.isEmpty, !ruTable.isEmpty else {
            return .macRussian
        }
        return KeyboardLayoutMap(keyCodeToEn: enTable, keyCodeToRu: ruTable)
    }

    private func translateAllKeys(source: TISInputSource) -> [KeyStroke: Character]? {
        guard let rawPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue()
        guard let bytesPtr = CFDataGetBytePtr(cfData) else { return nil }
        let layoutPtr = UnsafeRawPointer(bytesPtr).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())

        // Standard printable ANSI keyCodes (letters, numbers, punctuation).
        let printableKeyCodes: [UInt16] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
            18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
            30, 31, 32, 33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50,
        ]

        var table: [KeyStroke: Character] = [:]
        for keyCode in printableKeyCodes {
            for shifted in [false, true] {
                let modifiers: UInt32 = shifted ? UInt32(shiftKey >> 8) : 0
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var actualLength: Int = 0
                let status = UCKeyTranslate(
                    layoutPtr,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    modifiers,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &actualLength,
                    &chars
                )
                if status == noErr, actualLength == 1,
                   let scalar = UnicodeScalar(chars[0]),
                   scalar.value >= 0x20 {
                    table[KeyStroke(keyCode: keyCode, shifted: shifted)] = Character(scalar)
                }
            }
        }
        return table
    }

    private func sourceID(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func sourceName(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func sourceLanguages(_ source: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]) ?? []
    }
}

