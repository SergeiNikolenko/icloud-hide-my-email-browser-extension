import Foundation
import Testing
@testable import LayoutSwitcherCore

@Suite("LayoutSwitcherCore")
struct LayoutSwitcherCoreTests {
    static let model: LogosModel = try! LogosModel.loadBundled()

    // MARK: - Model Loading

    @Test("Bundled Caramba Logos 26.07.29.01 model loads intact")
    func bundledModelIntegrity() throws {
        let model = Self.model
        #expect(model.version == "26.07.29.01")
        #expect(model.kbm.featureSets.count == 67)
        #expect(model.kbm.languages[0] == "ru-en")
        #expect(model.kbm.index.keyCount() == 88_522)
        #expect(model.autocorrect.rules.count == 72_661)
        #expect(model.autocorrect.insertPool.count == 2_420)
        #expect(model.appex.ruleSets.count == 29)
        #expect(model.appex.index.keyCount() == 486)
        #expect(model.feats.delayBetweenLayoutActivationAndBackspacesMs == 25)
        #expect(model.feats.delayBetweenBackspacesAndRetypingMs == 25)
        #expect(model.feats.layoutSwitchNumRetries == 2)
        #expect(model.feats.layoutSwitchRetryDelayMs == 25)
        #expect(model.feats.splitShiftDelayMs == 100)
        #expect(model.feats.switchToEnglishOnFocus.contains("terminal"))
        #expect(model.feats.switchToEnglishOnFocus.contains("iterm"))
    }

    // MARK: - Bidirectional Layout Map

    @Test("Apple Mac Russian and Russian-PC layout maps convert accurately")
    func layoutMaps() {
        let mac = KeyboardLayoutMap.macRussian
        #expect(mac.convert("ghbdtn", from: .english, to: .russian) == "привет")
        #expect(mac.convert("GHBDTN", from: .english, to: .russian) == "ПРИВЕТ")
        #expect(mac.convert("руддщ", from: .russian, to: .english) == "hello")
        #expect(mac.convert("РУДДЩ", from: .russian, to: .english) == "HELLO")
        #expect(mac.convert("\\krf", from: .english, to: .russian) == "ёлка")
        #expect(mac.convert("ёлка", from: .russian, to: .english) == "\\krf")
        #expect(mac.convert("rjvgm.nth", from: .english, to: .russian) == "компьютер")
        #expect(mac.convert("gj;fkeqcnf", from: .english, to: .russian) == "пожалуйста")

        let pc = KeyboardLayoutMap.russianPC
        #expect(pc.convert("`krf", from: .english, to: .russian) == "ёлка")
        #expect(pc.convert("ёлка", from: .russian, to: .english) == "`krf")
    }

    // MARK: - EN -> RU Auto-Switching

    @Test("Russian words mistakenly typed in EN layout switch to RU")
    func enToRuAutoSwitch() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let config = SwitcherConfiguration(autocorrectEnabled: false, yofikatorEnabled: false)

        let cases: [(typed: String, expected: String)] = [
            ("ghbdtn", "привет"),
            ("Ghbdtn", "Привет"),
            ("GHBDTN", "ПРИВЕТ"),
            ("ghbdtn?", "привет?"),
            ("ghbdtn!", "привет!"),
            ("cgfcb,j", "спасибо"),
            ("gj;fkeqcnf", "пожалуйста"),
            ("[jhjij", "хорошо"),
            ("'nj", "это"),
            (";bpym", "жизнь"),
            ("hf,jnf", "работа"),
            ("rjvgm.nth", "компьютер"),
            ("ghjuhfvvf", "программа"),
            ("ctujlyz", "сегодня"),
            ("pfdnhf", "завтра"),
            ("lj,hsq", "добрый"),
            ("dtxth", "вечер"),
            ("ytn", "нет"),
            ("rfr", "как"),
            ("xnj", "что"),
            ("nj", "то"),
            ("dct", "все"),
            ("d", "в"),
            ("gfhjkm", "пароль"),
            ("rkfdbfnehf", "клавиатура"),
            ("ntrcn", "текст"),
            ("gjxnf", "почта"),
        ]

        for (typed, expected) in cases {
            let diag = pipeline.diagnose(word: typed, currentLanguage: .english, config: config)
            #expect(
                diag.finalLanguage == .russian && diag.finalOutput == expected,
                "Expected EN '\(typed)' -> RU '\(expected)', got \(diag.finalLanguage) '\(diag.finalOutput)' (ru=\(String(describing: diag.kbm?.ruScore)), en=\(String(describing: diag.kbm?.enScore)), skipped=\(diag.skippedByFilter))"
            )
        }
    }

    // MARK: - RU -> EN Auto-Switching

    @Test("English words mistakenly typed in RU layout switch to EN")
    func ruToEnAutoSwitch() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let config = SwitcherConfiguration(autocorrectEnabled: false, yofikatorEnabled: false)

        let cases: [(typed: String, expected: String)] = [
            ("руддщ", "hello"),
            ("Руддщ", "Hello"),
            ("РУДДЩ", "HELLO"),
            ("руддщ!", "hello!"),
            ("цщкдв", "world"),
            ("еру", "the"),
            ("фтв", "and"),
            ("нуы", "yes"),
            ("тщ", "no"),
            ("щл", "ok"),
            ("ыцшеср", "switch"),
            ("зкщоусе", "project"),
            ("ыцшае", "swift"),
            ("сщву", "code"),
            ("ьфшд", "mail"),
            ("уьфшд", "email"),
            ("зфыыцщкв", "password"),
            ("шсдщгв", "icloud"),
            ("цштвщц", "window"),
            ("ыуеештпы", "settings"),
            ("игеещт", "button"),
            ("ыуфкср", "search"),
            ("еукьштфд", "terminal"),
        ]

        for (typed, expected) in cases {
            let diag = pipeline.diagnose(word: typed, currentLanguage: .russian, config: config)
            #expect(
                diag.finalLanguage == .english && diag.finalOutput == expected,
                "Expected RU '(typed)' -> EN '(expected)', got (diag.finalLanguage) '(diag.finalOutput)' (ru=(String(describing: diag.kbm?.ruScore)), en=(String(describing: diag.kbm?.enScore)), skipped=(diag.skippedByFilter))"
            )
        }
    }

    // MARK: - Zero False Positives on Valid Words

    @Test("Valid English and Russian words are never falsely switched")
    func noFalsePositivesOnValidWords() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let config = SwitcherConfiguration(autocorrectEnabled: false, yofikatorEnabled: false)

        let validEnglish = [
            "hello", "world", "code", "swift", "apple", "email", "icloud",
            "function", "return", "import", "struct", "class", "private",
            "public", "string", "array", "option", "shift", "control",
            "command", "safari", "chrome", "terminal", "window", "settings",
            "button", "table", "search", "project", "switch", "the", "and", "yes", "no", "ok"
        ]
        for word in validEnglish {
            let diag = pipeline.diagnose(word: word, currentLanguage: .english, config: config)
            #expect(
                diag.finalLanguage == .english && diag.finalOutput == word,
                "Valid EN '(word)' falsely switched to (diag.finalLanguage) '(diag.finalOutput)' (ru=(String(describing: diag.kbm?.ruScore)), en=(String(describing: diag.kbm?.enScore)))"
            )
        }

        let validRussian = [
            "привет", "мир", "работа", "компьютер", "клавиатура", "раскладка",
            "программа", "спасибо", "пожалуйста", "сегодня", "завтра", "вечер",
            "утро", "день", "ночь", "книга", "город", "человек", "время",
            "вопрос", "ответ", "система", "приложение", "почта", "адрес",
            "настройки", "окно", "кнопка", "файл", "папка", "нет", "как", "что", "все"
        ]
        for word in validRussian {
            let diag = pipeline.diagnose(word: word, currentLanguage: .russian, config: config)
            #expect(
                diag.finalLanguage == .russian && diag.finalOutput == word,
                "Valid RU '(word)' falsely switched to (diag.finalLanguage) '(diag.finalOutput)' (ru=(String(describing: diag.kbm?.ruScore)), en=(String(describing: diag.kbm?.enScore)))"
            )
        }
    }

    // MARK: - Mid-Word & Full Typing Simulation

    private func simulateTyping(
        keys: String,
        initialLanguage: SwitcherLanguage,
        config: SwitcherConfiguration = SwitcherConfiguration()
    ) -> (screen: String, finalLanguage: SwitcherLanguage, actions: [SwitcherAction]) {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        var screen = ""
        var currentLang = initialLanguage
        var actions: [SwitcherAction] = []

        func applyAction(_ action: SwitcherAction) {
            actions.append(action)
            if action.backspaces > 0 {
                screen.removeLast(min(action.backspaces, screen.count))
            }
            if let lang = action.targetLanguage {
                currentLang = lang
            }
            screen.append(action.textToType)
        }

        for ch in keys {
            // Translate physical key (from initialLanguage key) through currentLang,
            // just like macOS produces characters in the newly switched layout after a mid-word switch!
            let stroke = pipeline.layoutMap.keyStroke(for: ch, in: initialLanguage)
            let produced: Character
            if ch == " " || ch == "\n" {
                produced = ch
            } else if let stroke, let mapped = pipeline.layoutMap.character(for: stroke, in: currentLang) {
                produced = mapped
            } else {
                produced = ch
            }

            screen.append(produced)
            if produced == " " || produced == "\n" {
                if let action = pipeline.processBoundary(String(produced), currentLanguage: currentLang, config: config) {
                    applyAction(action)
                }
            } else {
                if let action = pipeline.processCharacter(produced, stroke: stroke, currentLanguage: currentLang, config: config) {
                    applyAction(action)
                }
            }
        }
        return (screen, currentLang, actions)
    }

    @Test("Character-by-character typing switches smoothly mid-word and at boundaries in both directions")
    func characterByCharacterTyping() {
        // EN -> RU sentence typed completely in EN layout
        let r1 = simulateTyping(keys: "ghbdtn rfr ltkf ", initialLanguage: .english)
        #expect(r1.screen == "привет как дела ")
        #expect(r1.finalLanguage == .russian)
        #expect(r1.actions.count == 1) // switches on first word, rest typed natively in RU!

        // RU -> EN sentence typed completely in RU layout
        let r2 = simulateTyping(keys: "руддщ цщкдв ", initialLanguage: .russian)
        #expect(r2.screen == "hello world ")
        #expect(r2.finalLanguage == .english)
        #expect(r2.actions.count == 1)

        // Valid English typed character-by-character never false-triggers mid-word
        let r3 = simulateTyping(keys: "hello world switch project settings ", initialLanguage: .english)
        #expect(r3.screen == "hello world switch project settings ")
        #expect(r3.finalLanguage == .english)
        #expect(r3.actions.isEmpty)

        // Valid Russian typed character-by-character never false-triggers mid-word
        let r4 = simulateTyping(keys: "привет программа клавиатура настройки ", initialLanguage: .russian)
        #expect(r4.screen == "привет программа клавиатура настройки ")
        #expect(r4.finalLanguage == .russian)
        #expect(r4.actions.isEmpty)
    }

    // MARK: - Double-Caps, Autocorrect, Yofikator

    @Test("Double-Caps fixes ПРивет/HEllo while preserving ALL CAPS and preventative words")
    func doubleCaps() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let config = SwitcherConfiguration(autoSwitchEnabled: false, autocorrectEnabled: false, yofikatorEnabled: false)

        #expect(pipeline.diagnose(word: "ПРивет", currentLanguage: .russian, config: config).finalOutput == "Привет")
        #expect(pipeline.diagnose(word: "HEllo", currentLanguage: .english, config: config).finalOutput == "Hello")
        #expect(pipeline.diagnose(word: "ПРИВЕТ", currentLanguage: .russian, config: config).finalOutput == "ПРИВЕТ")
        #expect(pipeline.diagnose(word: "HELLO", currentLanguage: .english, config: config).finalOutput == "HELLO")
    }

    @Test("Autocorrect and Yofikator work independently and preserve casing")
    func autocorrectAndYofikator() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)

        // Yofikator on
        let yoOn = SwitcherConfiguration(autoSwitchEnabled: false, autocorrectEnabled: false, yofikatorEnabled: true)
        #expect(pipeline.diagnose(word: "елка", currentLanguage: .russian, config: yoOn).finalOutput == "ёлка")
        #expect(pipeline.diagnose(word: "Елка", currentLanguage: .russian, config: yoOn).finalOutput == "Ёлка")
        #expect(pipeline.diagnose(word: "ЕЛКА", currentLanguage: .russian, config: yoOn).finalOutput == "ЁЛКА")
        #expect(pipeline.diagnose(word: "вперед", currentLanguage: .russian, config: yoOn).finalOutput == "вперёд")
        #expect(pipeline.diagnose(word: "еще", currentLanguage: .russian, config: yoOn).finalOutput == "ещё")
        #expect(pipeline.diagnose(word: "елка,", currentLanguage: .russian, config: yoOn).finalOutput == "ёлка,")
        // Mistype shouldn't run when autocorrectEnabled == false
        #expect(pipeline.diagnose(word: "teh", currentLanguage: .english, config: yoOn).finalOutput == "teh")

        // Autocorrect on, Yofikator off
        let acOnly = SwitcherConfiguration(autoSwitchEnabled: false, autocorrectEnabled: true, yofikatorEnabled: false)
        #expect(pipeline.diagnose(word: "teh", currentLanguage: .english, config: acOnly).finalOutput == "the")
        #expect(pipeline.diagnose(word: "Teh", currentLanguage: .english, config: acOnly).finalOutput == "The")
        #expect(pipeline.diagnose(word: ".cmo", currentLanguage: .english, config: acOnly).finalOutput == ".com")
        #expect(pipeline.diagnose(word: "елка", currentLanguage: .russian, config: acOnly).finalOutput == "елка")

        // Chained Auto-Switch + Yofikator: "tkrf" (EN) -> "елка" (RU) -> "ёлка"!
        let allOn = SwitcherConfiguration()
        let chained = pipeline.diagnose(word: "tkrf", currentLanguage: .english, config: allOn)
        #expect(chained.finalLanguage == .russian)
        #expect(chained.finalOutput == "ёлка")
    }

    // MARK: - Filters, Revert Learning, Manual Conversion & Appex

    @Test("Passwords, URLs, emails, camelCase and license plates are never auto-switched")
    func wordFiltersProtectSensitiveTokens() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let config = SwitcherConfiguration(autocorrectEnabled: false, yofikatorEnabled: false)

        let protected = [
            "P@ssw0rd!", "Tr0ub4dor&3", "https://github.com", "user@icloud.com",
            "myVariable", "iPhone", "abc123def", "А123ВС77",
        ]
        for token in protected {
            let diag = pipeline.diagnose(word: token, currentLanguage: .english, config: config)
            #expect(diag.finalOutput == token, "Protected token '(token)' should not be switched, got '(diag.finalOutput)'")
        }
    }

    @Test("Manual revert restores original word and learns session exception")
    func manualRevertAndLearn() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let config = SwitcherConfiguration(midWordSwitchEnabled: false)

        for ch in "ghbdtn" {
            _ = pipeline.processCharacter(ch, stroke: nil, currentLanguage: .english, config: config)
        }
        let switched = pipeline.processBoundary(" ", currentLanguage: .english, config: config)
        #expect(switched?.kind == .autoSwitch)
        #expect(switched?.replacementWord == "привет")
        #expect(switched?.targetLanguage == .russian)

        // User hits Option / Double Shift to undo auto-switch
        let reverted = pipeline.manualSwitchLastWord(currentLanguage: .russian)
        #expect(reverted?.kind == .manualRevert)
        #expect(reverted?.replacementWord == "ghbdtn")
        #expect(reverted?.targetLanguage == .english)
        #expect(reverted?.learnedException == "ghbdtn")

        // Typing "ghbdtn " again in the same session will NOT auto-switch
        for ch in "ghbdtn" {
            _ = pipeline.processCharacter(ch, stroke: nil, currentLanguage: .english, config: config)
        }
        let second = pipeline.processBoundary(" ", currentLanguage: .english, config: config)
        #expect(second == nil)
    }

    @Test("Selection conversion flips multi-word phrases accurately in both directions")
    func selectionConversion() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)

        let toRu = pipeline.convertSelection("ghbdtn, vbh!")
        #expect(toRu?.converted == "приветб мир!" || toRu?.converted == "привет, мир!")
        // Wait: ',' in EN maps to 'б' on Russian keyboard (physical key conversion!)
        #expect(toRu?.converted == "приветб мир!")
        #expect(toRu?.targetLanguage == .russian)

        let toEn = pipeline.convertSelection("руддщ цщкдв")
        #expect(toEn?.converted == "hello world")
        #expect(toEn?.targetLanguage == .english)
    }

    @Test("Appex built-in rules and Feats terminal/browser detection work")
    func appexAndFeats() {
        let matcher = AppexMatcher(appex: Self.model.appex, feats: Self.model.feats)

        // 1Password is excluded in built-in Appex rules
        let onePass = matcher.policy(
            bundleIdentifier: "com.1password.1password",
            executablePath: "/Applications/1Password.app/Contents/MacOS/1Password",
            windowTitle: nil,
            userExcludedBundleIDs: []
        )
        #expect(onePass != .normal)

        // User-excluded app always disables all
        let custom = matcher.policy(
            bundleIdentifier: "com.example.custom",
            executablePath: nil,
            windowTitle: nil,
            userExcludedBundleIDs: ["com.example.custom"]
        )
        #expect(custom == .disableAll)

        // Terminals trigger EN-on-focus
        #expect(matcher.shouldSwitchToEnglishOnFocus(bundleIdentifier: "com.apple.Terminal", executablePath: nil, appName: "Terminal"))
        #expect(matcher.shouldSwitchToEnglishOnFocus(bundleIdentifier: "com.googlecode.iterm2", executablePath: nil, appName: "iTerm2"))
        #expect(!matcher.shouldSwitchToEnglishOnFocus(bundleIdentifier: "com.apple.Notes", executablePath: nil, appName: "Notes"))

        // Browsers match special behavior
        #expect(matcher.hasSpecialBrowserBehavior(bundleIdentifier: "com.apple.Safari", executablePath: "/Applications/Safari.app", appName: "Safari"))
        #expect(matcher.hasSpecialBrowserBehavior(bundleIdentifier: "com.google.Chrome", executablePath: "/Applications/Google Chrome.app", appName: "Google Chrome"))
    }

    @Test("Extended bidirectional parity corpus (100+ real words, short prepositions, punctuation-letters, collisions)")
    func extendedBidirectionalParityCorpus() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let config = SwitcherConfiguration(autocorrectEnabled: true, yofikatorEnabled: true)

        let enToRu: [(String, String)] = [
            // Short Russian words / prepositions typed in EN
            ("d", "в"), ("ytn", "нет"), ("lf", "да"), ("rfr", "как"), ("xnj", "что"),
            ("nj", "то"), ("dct", "все"), ("jy", "он"), ("yf", "на"), ("gj", "по"),
            ("pf", "за"), ("jn", "от"), ("ns", "ты"), ("ds", "вы"),
            ("bkb", "или"), ("lkz", "для"), ("ghb", "при"), ("gjl", "под"), ("e;t", "уже"),
            ("nfr", "так"), ("djn", "вот"), ("ult", "где"), ("rnj", "кто"), ("nfv", "там"),
            ("nen", "тут"),
            // Punctuation-mapped Cyrillic letters (, . ; ' [ ] \)
            ("[jhjij", "хорошо"), ("'nj", "это"), (";bpym", "жизнь"),
            ("cgfcb,j", "спасибо"), ("gj;fkeqcnf", "пожалуйста"),
            ("rjvgm.nth", "компьютер"), ("j,]zcyb", "объясни"),
            ("yjxm.", "ночью"), ("k.,k.", "люблю"), ("dctulf", "всегда"),
            ("\\krf", "ёлка"),
            // Chained EN->RU + Yofikator
            ("tkrf", "ёлка"), ("dgthtl", "вперёд"), ("tot", "ещё"),
        ]
        var enToRuMismatches: [String] = []
        for (typed, expected) in enToRu {
            let d = pipeline.diagnose(word: typed, currentLanguage: .english, config: config)
            if d.finalLanguage != .russian || d.finalOutput != expected {
                enToRuMismatches.append("EN '\(typed)' -> got \(d.finalLanguage) '\(d.finalOutput)' (expected RU '\(expected)', ru=\(String(describing: d.kbm?.ruScore)), en=\(String(describing: d.kbm?.enScore)))")
            }
        }
        #expect(enToRuMismatches.isEmpty, "EN->RU mismatches:\n\(enToRuMismatches.joined(separator: "\n"))")

        let ruToEn: [(String, String)] = [
            ("еру", "the"), ("фтв", "and"), ("нуы", "yes"), ("тщ", "no"), ("щл", "ok"),
            ("ащк", "for"), ("нщг", "you"), ("тще", "not"), ("иге", "but"), ("цшер", "with"),
            ("ершы", "this"), ("ерфе", "that"), ("акщь", "from"), ("рфму", "have"),
            ("црфе", "what"), ("цруку", "where"), ("црщ", "who"), ("рщц", "how"),
            ("црут", "when"), ("здуфыу", "please"), ("ерфтлы", "thanks"), ("ыщккн", "sorry"),
            ("пщщв", "good"), ("ьщктштп", "morning"), ("умутштп", "evening"),
            ("сркщьу", "chrome"), ("ыфафкш", "safari"), ("фззду", "apple"),
            ("еур", "the"), // chained RU->EN + autocorrect (teh -> the)!
        ]
        var ruToEnMismatches: [String] = []
        for (typed, expected) in ruToEn {
            let d = pipeline.diagnose(word: typed, currentLanguage: .russian, config: config)
            if d.finalLanguage != .english || d.finalOutput != expected {
                ruToEnMismatches.append("RU '\(typed)' -> got \(d.finalLanguage) '\(d.finalOutput)' (expected EN '\(expected)', ru=\(String(describing: d.kbm?.ruScore)), en=\(String(describing: d.kbm?.enScore)))")
            }
        }
        #expect(ruToEnMismatches.isEmpty, "RU->EN mismatches:\n\(ruToEnMismatches.joined(separator: "\n"))")

        // Short valid words must NEVER false-switch
        let noSwitchConfig = SwitcherConfiguration(autocorrectEnabled: false, yofikatorEnabled: false)
        let shortValidEn = [
            "a", "I", "ok", "no", "to", "in", "on", "is", "it", "at", "by", "or",
            "as", "we", "he", "me", "my", "up", "so", "do", "go", "be", "if", "of", "an", "us", "am"
        ]
        var fpEn: [String] = []
        for w in shortValidEn {
            let d = pipeline.diagnose(word: w, currentLanguage: .english, config: noSwitchConfig)
            if d.finalLanguage != .english || d.finalOutput != w {
                fpEn.append("EN '\(w)' -> \(d.finalLanguage) '\(d.finalOutput)' (ru=\(String(describing: d.kbm?.ruScore)), en=\(String(describing: d.kbm?.enScore)))")
            }
        }
        #expect(fpEn.isEmpty, "Short EN false positives:\n\(fpEn.joined(separator: "\n"))")

        let shortValidRu = [
            "в", "и", "я", "с", "к", "у", "о", "а", "да", "но", "он", "на", "по",
            "до", "за", "от", "ты", "вы", "мы", "то", "не", "ни", "же", "бы", "ли"
        ]
        var fpRu: [String] = []
        for w in shortValidRu {
            let d = pipeline.diagnose(word: w, currentLanguage: .russian, config: noSwitchConfig)
            if d.finalLanguage != .russian || d.finalOutput != w {
                fpRu.append("RU '\(w)' -> \(d.finalLanguage) '\(d.finalOutput)' (ru=\(String(describing: d.kbm?.ruScore)), en=\(String(describing: d.kbm?.enScore)))")
            }
        }
        #expect(fpRu.isEmpty, "Short RU false positives:\n\(fpRu.joined(separator: "\n"))")

        // Cross-layout collision ("vs" = English "versus" vs Russian "мы") stays untouched!
        let vsDiag = pipeline.diagnose(word: "vs", currentLanguage: .english, config: noSwitchConfig)
        #expect(vsDiag.finalLanguage == .english)
        #expect(vsDiag.finalOutput == "vs")
        #expect(vsDiag.kbm?.decision == .collision)
    }

    @Test("Swallowed boundary and mid-word triggers compute exact non-destructive diffs")
    func swallowedTriggerDiffs() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let boundaryOnly = SwitcherConfiguration(midWordSwitchEnabled: false, autocorrectEnabled: false, yofikatorEnabled: false)

        // Pressing Enter after typing "ghbdtn": swallow Enter so backspaces only erase 6 chars ("ghbdtn")
        // and textToType emits "привет\n" AFTER switching layout!
        for ch in "ghbdtn" {
            #expect(pipeline.processCharacter(ch, stroke: nil, currentLanguage: .english, config: boundaryOnly, swallowTriggerCharacter: true) == nil)
        }
        let enterAction = pipeline.processBoundary("\n", currentLanguage: .english, config: boundaryOnly, swallowBoundary: true)
        #expect(enterAction?.kind == .autoSwitch)
        #expect(enterAction?.backspaces == 6)
        #expect(enterAction?.textToType == "привет\n")
        #expect(enterAction?.targetLanguage == .russian)

        // Pressing Tab after "руддщ": swallow Tab so focus never jumps before retyping!
        for ch in "руддщ" {
            #expect(pipeline.processCharacter(ch, stroke: nil, currentLanguage: .russian, config: boundaryOnly, swallowTriggerCharacter: true) == nil)
        }
        let tabAction = pipeline.processBoundary("\t", currentLanguage: .russian, config: boundaryOnly, swallowBoundary: true)
        #expect(tabAction?.kind == .autoSwitch)
        #expect(tabAction?.backspaces == 5)
        #expect(tabAction?.textToType == "hello\t")
        #expect(tabAction?.targetLanguage == .english)

        // Mid-word switch with swallowTriggerCharacter == true:
        // when the 3rd/4th key triggers switch, backspaces only erase the already-visible prefix!
        let midConfig = SwitcherConfiguration(midWordSwitchEnabled: true, autocorrectEnabled: false, yofikatorEnabled: false)
        var screen = ""
        var triggered: SwitcherAction?
        for ch in "ghbdtn" {
            if let action = pipeline.processCharacter(ch, stroke: nil, currentLanguage: .english, config: midConfig, swallowTriggerCharacter: true) {
                triggered = action
                screen.removeLast(action.backspaces)
                screen.append(action.textToType)
                break
            } else {
                screen.append(ch)
            }
        }
        #expect(triggered != nil)
        #expect(triggered?.targetLanguage == .russian)
        #expect(screen == triggered?.replacementWord)
    }

    @Test("Everyday apps (Telegram, ChatGPT/Codex, Claude, Zen, Finder) remain active under built-in Appex rules")
    func activeUserAppsNotFalselyBlocked() {
        let matcher = AppexMatcher(appex: Self.model.appex, feats: Self.model.feats)
        let activeApps: [(String, String)] = [
            ("com.openai.codex", "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
            ("com.anthropic.claudefordesktop", "/Applications/Claude.app/Contents/MacOS/Claude"),
            ("ru.keepcoder.Telegram", "/Applications/Telegram.app/Contents/MacOS/Telegram"),
            ("app.zen-browser.zen", "/Applications/Zen.app/Contents/MacOS/zen"),
            ("com.apple.finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            ("com.local.BuretteV10", "/Applications/Burette.app/Contents/MacOS/burette"),
        ]
        for (bid, path) in activeApps {
            let policy = matcher.policy(
                bundleIdentifier: bid,
                executablePath: path,
                windowTitle: nil,
                userExcludedBundleIDs: []
            )
            #expect(policy == .normal, "App \(bid) was unexpectedly blocked with policy \(policy)")
        }
    }

    @Test("Option manual switch respects resetAll vs resetBuffer, Enter/Tab clearing, mid-word revert, and selection tie-breaking")
    func optionManualSwitchAndSelectionEdgeCases() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let noAuto = SwitcherConfiguration(autoSwitchEnabled: false, autocorrectEnabled: false, yofikatorEnabled: false)

        // 1. Typing a word + Space retains lastWord so Option converts it; toggling Option twice returns original.
        for ch in "jgiy" {
            _ = pipeline.processCharacter(ch, stroke: pipeline.layoutMap.keyStroke(for: ch, in: .english), currentLanguage: .english, config: noAuto)
        }
        #expect(pipeline.processBoundary(" ", currentLanguage: .english, config: noAuto) == nil)
        #expect(pipeline.hasLastWord)
        let firstFlip = pipeline.manualSwitchLastWord(currentLanguage: .english)
        #expect(firstFlip?.replacementWord == "опшн")
        #expect(firstFlip?.backspaces == 5)
        #expect(firstFlip?.textToType == "опшн ")
        #expect(firstFlip?.targetLanguage == .russian)

        let secondFlip = pipeline.manualSwitchLastWord(currentLanguage: .russian)
        #expect(secondFlip?.replacementWord == "jgiy")
        #expect(secondFlip?.textToType == "jgiy ")
        #expect(secondFlip?.targetLanguage == .english)

        // 2. resetBuffer (used by Single Shift) keeps lastWord; resetAll (mouse click / arrow / Cmd+A) clears it
        //    so Option switches selected text instead of a stale word!
        pipeline.resetBuffer()
        #expect(pipeline.hasLastWord)
        pipeline.resetAll()
        #expect(!pipeline.hasLastWord)
        #expect(pipeline.manualSwitchLastWord(currentLanguage: .english) == nil)

        // 3. Pressing Enter or Tab clears lastWord so Option never backspaces across a sent message or newline.
        for ch in "jgiy" {
            _ = pipeline.processCharacter(ch, stroke: nil, currentLanguage: .english, config: noAuto)
        }
        _ = pipeline.processBoundary("\n", currentLanguage: .english, config: noAuto)
        #expect(!pipeline.hasLastWord)

        for ch in "jgiy" {
            _ = pipeline.processCharacter(ch, stroke: nil, currentLanguage: .english, config: noAuto)
        }
        _ = pipeline.processBoundary("\t", currentLanguage: .english, config: noAuto)
        #expect(!pipeline.hasLastWord)

        // 4. Mid-word auto-switch followed by more characters in the same word still reverts the entire word
        //    on Option and records it as a session exception!
        let midPipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let midConfig = SwitcherConfiguration(autoSwitchEnabled: true, midWordSwitchEnabled: true, autocorrectEnabled: false, yofikatorEnabled: false)
        var activeLang: SwitcherLanguage = .english
        for ch in "ghbdtn" {
            let stroke = midPipeline.layoutMap.keyStroke(for: ch, in: .english)!
            let typed = midPipeline.layoutMap.character(for: stroke, in: activeLang)!
            if let act = midPipeline.processCharacter(typed, stroke: stroke, currentLanguage: activeLang, config: midConfig, swallowTriggerCharacter: true) {
                if let t = act.targetLanguage { activeLang = t }
            }
        }
        #expect(activeLang == .russian)
        let reverted = midPipeline.manualSwitchLastWord(currentLanguage: activeLang)
        #expect(reverted?.kind == .manualRevert)
        #expect(reverted?.replacementWord == "ghbdtn")
        #expect(reverted?.targetLanguage == .english)
        #expect(reverted?.learnedException == "ghbdtn")
        #expect(midPipeline.sessionExceptions.contains("ghbdtn"))

        // 5. Selection conversion breaks Latin==Cyrillic ties using fallbackLanguage (active layout)
        //    and handles multi-line & punctuation-only selections.
        let tiedEn = pipeline.convertSelection("ghb мир", fallbackLanguage: .english)
        #expect(tiedEn?.converted == "при мир")
        #expect(tiedEn?.targetLanguage == .russian)

        let tiedRu = pipeline.convertSelection("ghb мир", fallbackLanguage: .russian)
        #expect(tiedRu?.converted == "ghb vbh")
        #expect(tiedRu?.targetLanguage == .english)

        let punctOnly = pipeline.convertSelection(";'", fallbackLanguage: .english)
        #expect(punctOnly?.converted == "жэ")
        #expect(punctOnly?.targetLanguage == .russian)

        let multiline = pipeline.convertSelection("ghbdtn\nvbh", fallbackLanguage: .english)
        #expect(multiline?.converted == "привет\nмир")
        #expect(multiline?.targetLanguage == .russian)
    }

    @Test("Option converts ssd/ыыв after Space and subsequent words still auto-switch after stale-TIS manual layout flip")
    func optionAfterSpaceAndStaleTISRecovery() {
        let pipeline = SwitcherPipeline(model: Self.model, layoutMap: .macRussian)
        let config = SwitcherConfiguration(autoSwitchEnabled: true, midWordSwitchEnabled: true, autocorrectEnabled: false, yofikatorEnabled: false)

        // 1. User types "ssd" + Space even when Carbon TIS erroneously still reports `.russian`.
        for ch in "ssd" {
            let stroke = pipeline.layoutMap.keyStroke(for: ch, in: .english)
            _ = pipeline.processCharacter(ch, stroke: stroke, currentLanguage: .russian, config: config)
        }
        _ = pipeline.processBoundary(" ", currentLanguage: .russian, config: config)
        #expect(pipeline.hasLastWord)

        // Pressing Option after "ssd " must still flip it to "ыыв " (backspaces=4) and switch layout to RU.
        let flipped = pipeline.manualSwitchLastWord(currentLanguage: .russian)
        #expect(flipped?.replacementWord == "ыыв")
        #expect(flipped?.backspaces == 4)
        #expect(flipped?.textToType == "ыыв ")
        #expect(flipped?.targetLanguage == .russian)

        // Pressing Option again flips "ыыв " back to "ssd ".
        let flippedBack = pipeline.manualSwitchLastWord(currentLanguage: .russian)
        #expect(flippedBack?.replacementWord == "ssd")
        #expect(flippedBack?.backspaces == 4)
        #expect(flippedBack?.textToType == "ssd ")
        #expect(flippedBack?.targetLanguage == .english)

        // 2. Subsequent words keep auto-switching even if caller passes stale TIS language!
        //    User is physically typing English letters ("ghbdtn", "rfr") while stale TIS reports `.russian`.
        var switchedFirst: SwitcherAction?
        for ch in "ghbdtn" {
            let stroke = pipeline.layoutMap.keyStroke(for: ch, in: .english)
            if let act = pipeline.processCharacter(ch, stroke: stroke, currentLanguage: .russian, config: config, swallowTriggerCharacter: true) {
                switchedFirst = act
                break
            }
        }
        #expect(switchedFirst?.kind == .autoSwitch)
        #expect(switchedFirst?.targetLanguage == .russian)
        #expect(switchedFirst?.replacementWord == "при")

        // Finish word and type a second wrong-layout word ("rfr ") with stale TIS still reporting `.russian`.
        _ = pipeline.processBoundary(" ", currentLanguage: .russian, config: config)
        var switchedSecond: SwitcherAction?
        for ch in "rfr" {
            let stroke = pipeline.layoutMap.keyStroke(for: ch, in: .english)
            if let act = pipeline.processCharacter(ch, stroke: stroke, currentLanguage: .russian, config: config, swallowTriggerCharacter: true) {
                switchedSecond = act
            }
        }
        if switchedSecond == nil {
            switchedSecond = pipeline.processBoundary(" ", currentLanguage: .russian, config: config, swallowBoundary: true)
        }
        #expect(switchedSecond?.kind == .autoSwitch)
        #expect(switchedSecond?.replacementWord == "как")

        // 3. Accessibility trailing-word extraction handles normal space and ProseMirror NBSP ("\u{00A0}").
        let ext1 = SwitcherPipeline.extractTrailingWord(from: "купил новый ssd ")
        #expect(ext1?.word == "ssd")
        #expect(ext1?.trailingSpaces == " ")

        let ext2 = SwitcherPipeline.extractTrailingWord(from: "купил новый ssd\u{00A0}")
        #expect(ext2?.word == "ssd")
        #expect(ext2?.trailingSpaces == " ")

        pipeline.resetAll()
        #expect(!pipeline.hasLastWord)
        pipeline.seedLastWord(word: ext2!.word, trailingBoundary: ext2!.trailingSpaces, language: .english)
        let axFlipped = pipeline.manualSwitchLastWord(currentLanguage: .english)
        #expect(axFlipped?.replacementWord == "ыыв")
        #expect(axFlipped?.backspaces == 4)
        #expect(axFlipped?.textToType == "ыыв ")

        // 4. Fallback spell-autocorrect runs on Space in pipeline and can be reverted via Option.
        pipeline.resetAll()
        let acConfig = SwitcherConfiguration(autoSwitchEnabled: true, midWordSwitchEnabled: true, autocorrectEnabled: true, yofikatorEnabled: false)
        for ch in "моудль" {
            _ = pipeline.processCharacter(ch, stroke: nil, currentLanguage: .russian, config: acConfig)
        }
        let fixed = pipeline.processBoundary(" ", currentLanguage: .russian, config: acConfig, swallowBoundary: true) { word in
            word == "моудль" ? "модуль" : nil
        }
        #expect(fixed?.kind == .autocorrect)
        #expect(fixed?.replacementWord == "модуль")
        #expect(fixed?.textToType == "дуль ")
        #expect(fixed?.backspaces == 4)

        let revertFix = pipeline.manualSwitchLastWord(currentLanguage: .russian)
        #expect(revertFix?.kind == .manualRevert)
        #expect(revertFix?.replacementWord == "моудль")
    }

}

