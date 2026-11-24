import AppKit
import Foundation

/// Multilingual typo detection, wrong-layout rescue (e.g. `lbrndrf` -> `диктовка`),
/// and Damerau-Levenshtein autocorrect using macOS's built-in NSSpellChecker.
public enum AutocorrectHelper {
    /// Checks the word right before the caret (either currently being finished or
    /// right before a single trailing space) and returns an autocorrect suggestion
    /// if there is a high-confidence spelling or wrong-layout fix.
    @MainActor
    public static func check(prefix: String) -> ActiveSuggestion? {
        guard !prefix.isEmpty else { return nil }

        let hadTrailingSpace = prefix.hasSuffix(" ")
        let working = hadTrailingSpace ? String(prefix.dropLast()) : prefix
        guard !working.isEmpty else { return nil }

        // Extract the trailing word (letters only — skip numbers, code identifiers, URLs).
        var start = working.endIndex
        while start > working.startIndex {
            let prev = working.index(before: start)
            if working[prev].isLetter {
                start = prev
            } else {
                break
            }
        }

        let word = String(working[start...])
        // Check words with >= 4 letters (or >= 3 letters once completed with space), skip ALL CAPS.
        let minLen = hadTrailingSpace ? 3 : 4
        guard word.count >= minLen, word.count <= 32 else { return nil }
        guard word != word.uppercased() else { return nil }

        // Skip if attached to code/punctuation like "foo_bar", "foo.bar", "user@domain", ":emoji".
        if start > working.startIndex {
            let boundary = working[working.index(before: start)]
            if !boundary.isWhitespace && !"([\"'«—–-".contains(boundary) {
                return nil
            }
        }

        let precedingText = String(working[..<start])

        // 1. Wrong-layout single-word rescue (e.g. "как виспер или lbrndrf" -> "диктовка").
        if let layoutFix = rescueWrongLayoutWord(word, precedingContext: precedingText) {
            let replacement = hadTrailingSpace ? "\(layoutFix) " : layoutFix
            let replaceLen = word.count + (hadTrailingSpace ? 1 : 0)
            return ActiveSuggestion(
                text: replacement,
                kind: .autocorrect(wordLength: replaceLen, original: word),
                anchorPrefix: prefix
            )
        }

        // 2. Explicit-language NSSpellChecker lookup using full-sentence context when available
        //    so contextual typos like "косяков в интерфесе" resolve to "интерфейсе" rather than "интересе".
        guard let best = bestSpellingCorrection(for: word, inContext: working, wordStart: start) else { return nil }

        let replacement = hadTrailingSpace ? "\(best) " : best
        let replaceLen = word.count + (hadTrailingSpace ? 1 : 0)
        return ActiveSuggestion(
            text: replacement,
            kind: .autocorrect(wordLength: replaceLen, original: word),
            anchorPrefix: prefix
        )
    }

    /// Common tech / AI / developer slang stems that macOS's Russian dictionary lacks
    /// and must never be mangled by automatic typo correction.
    private static let protectedTechWords: Set<String> = [
        "виспер", "виспером", "виспера", "виспере", "висперу",
        "кодекс", "кодексе", "кодексом", "кодекса", "кодексу",
        "субагент", "субагента", "субагентом", "субагентов", "субагенты",
        "кофолдинг", "кофолдинга", "кофолдинге", "кофолдингом",
        "ребейз", "ребейзи", "ребейзить", "пофикси", "пофиксить", "пофиксил", "фикс", "фиксит", "фиксить",
        "свитчер", "свитчере", "свитчера", "свитчером",
        "поповер", "поповере", "поповера", "автокоррект", "ёфикатор", "оверлей", "оверлея",
        "каретка", "каретки", "каретку", "кареткой",
        "виртуалка", "виртуалке", "виртуалку", "виртуалки",
        "фронтенд", "бэкенд", "датасет", "датасета", "датасетах", "датасеты",
        "сплит", "сплита", "сплитах", "сплиты", "эндпоинт", "эндпоинта", "эндпоинтов", "эндпоинты",
        "промпт", "промпта", "промпты", "промптом", "дебаг", "релиз", "релизный",
        "билд", "билда", "бандл", "бандла", "хоткей", "хоткеи", "хоткеев", "хоткеем",
        "кэш", "кэша", "кэше", "инференс", "токены", "токенов", "квантизация", "гпу",
        "скрины", "скриншот", "скриншоты", "скриншотов", "глоса", "глосу", "глосе",
        "рнп", "мультиап", "баг", "баги", "багов", "бага", "фича", "фичи", "фичу",
        "карамба", "карамбе", "карамбы", "карамбу", "карамбой", "опшн", "дефолт", "дефолтом", "дефолту",
        "синк", "синкать", "мерж", "мержить", "пуш", "пушить", "пулл", "коммит", "коммиты",
        "конфиг", "конфига", "конфиги", "плагин", "плагина", "плагины", "воркспейс", "таск", "таски",
        "автокомплит", "автокомплита", "автокомплите", "автокомплитом", "автоправка", "автоправки", "постфактум",
        "правились", "правилось", "правился", "правилась",
        // Everyday/tech words from user's chat history that macOS Russian NSSpellChecker falsely flags:
        "визуализация", "визуализаций", "визуализации", "визуализацию",
        "телеграм", "телеграме", "телеграма", "телеге",
        "гугл", "гугле", "яндекс", "яндексе", "орион", "орионе",
        "мердж", "револют", "амнезия", "амнезии", "амнезию", "антигравити",
        "всплывашки", "побайтно", "инсомния", "загран",
        "тинькофф", "тиньков", "тиньке", "авиасейлс", "айклауд", "айпи",
        "дипсик", "дипсика", "задеплой", "задеплоить", "линукс", "линуксе",
        "платёжку", "кофолдингами", "нейронка", "нейронки", "нейронок", "нейронку", "нейронками",
        "котайпист", "котопист", "котописта", "канари"
    ]

    /// High-confidence direct typo map mined from real fast-typing Russian sessions
    /// (especially cases where macOS NSSpellChecker guesses the wrong word, e.g. `привт -> приват`
    /// instead of `привет`, `смалйики -> сомалийки` instead of `смайлики`, `выгдит -> выудит`).
    private static let directTypoFixes: [String: String] = [
        // Top recurring verbs & action words
        "рабоает": "работает", "рбаоает": "работает", "рабоать": "работать",
        "рабоают": "работают", "рабоатют": "работают", "рабоатло": "работало",
        "давйа": "давай", "жавай": "давай",
        "првоерь": "проверь", "перпрвоерь": "перепроверь", "пеерповерь": "перепроверь",
        "сжделай": "сделай", "заполнилть": "заполнить",
        "подклчил": "подключил", "переподклчил": "переподключил", "подклчается": "подключается",
        "мождешь": "можешь", "можшет": "может",
        "напистаь": "написать", "написла": "написала", "напислаа": "написала", "писла": "писала",
        "спрси": "спроси", "спраишвали": "спрашивали",
        "отправть": "отправить", "оптравляй": "отправляй",
        "достаь": "достать", "вщял": "взял", "вазял": "взял", "открл": "открыл",
        "псотмри": "посмотри", "выгдит": "выглядит", "выгдеть": "выглядеть",
        "использвоать": "использовать", "испольваоть": "использовать", "испольдуй": "используй",
        "разебри": "разбери", "ознакмиться": "ознакомиться", "запуститьь": "запустить",
        "реомендуешь": "рекомендуешь", "настаривали": "настраивали", "ооворил": "говорил",
        "максмизировать": "максимизировать", "макмизхировать": "максимизировать",
        "рензхюмериуй": "резюмируй", "видишью": "видишь", "просиили": "просили",
        "поялвется": "появляется", "редакриртовать": "редактировать", "перелкючил": "переключил",
        "вклчюиттть": "включить", "проудмай": "продумай", "извелкать": "извлекать", "продложай": "продолжай",
        // Top recurring short/common words & adjacent-key misses
        "привт": "привет", "конекчно": "конечно", "тоде": "тоже", "своб": "свою",
        "нало": "надо", "чоень": "очень", "нужы": "нужны", "вообе": "вообще",
        "сраду": "сразу", "тепкерь": "теперь", "этього": "этого", "потомоу": "потому",
        "потмов": "потом", "недвано": "недавно", "котоыре": "которые", "именро": "именно",
        "понтяно": "понятно", "получще": "получше", "готтово": "готово", "логичне": "логичнее",
        "остальнео": "остальное", "оснвоне": "основное", "локальнео": "локальное",
        "отедльной": "отдельной", "желателньо": "желательно", "немногго": "немного",
        "акуратно": "аккуратно", "коректно": "корректно", "следущие": "следующие",
        "иногдбюа": "иногда", "бять": "быть", "безщ": "без",
        // Nouns & IT / product terms
        "автокомлпикт": "автокомплит", "функцинал": "функционал", "функицнал": "функционал",
        "прилоежние": "приложение", "прилоенжие": "приложение", "прилежние": "приложение",
        "прилежение": "приложение", "приложание": "приложение", "приложние": "приложение", "прилжение": "приложение",
        "видое": "видео",
        "нейорнками": "нейронками", "интерфесе": "интерфейсе", "моудль": "модуль",
        "дефотом": "дефолтом", "коексе": "кодексе", "караммбе": "карамбе",
        "дообучени": "дообучение", "смалйики": "смайлики", "акуант": "аккаунт",
        "пробелма": "проблема", "пробелмы": "проблемы", "хадача": "задача",
        "собщение": "сообщение", "собения": "сообщения", "сообщених": "сообщениях",
        "предложкеные": "предложенные", "поселдненее": "последнее",
        "ажрес": "адрес", "паспотр": "паспорт", "вложенич": "вложения", "документц": "документы",
        "наследоство": "наследство", "электричевто": "электричество", "посоольство": "посольство",
        "раотадателя": "работодателя", "вопросво": "вопросов", "календраь": "календарь",
        "арзхива": "архива", "бущуем": "будущем", "различине": "различие",
        "комплесная": "комплексная", "готовсти": "готовности", "граматикой": "грамматикой",
        "фиксировнный": "фиксированный", "обновенный": "обновлённый", "решервный": "резервный",
        "содседние": "соседние", "сосденем": "соседнем", "компактизшацией": "компактизацией",
        "анигравитии": "антигравити", "тфайла": "файла", "ошибко": "ошибку",
        "достверность": "достоверность", "накадвыаюстя": "накладываются", "криов": "криво"
    ]

    /// Physical adjacent key pairs on Russian ЙЦУКЕН and English QWERTY keyboards
    /// used to rank adjacent-key hits (e.g. `тоде -> тоже`, `нало -> надо`, `жавай -> давай`).
    private static let keyboardNeighbors: [Character: Set<Character>] = {
        let rows: [[Character]] = [
            // Russian ЙЦУКЕН
            Array("йцукенгшщзхъ"),
            Array("фывапролджэ"),
            Array("ячсмитьбю"),
            // English QWERTY
            Array("qwertyuiop"),
            Array("asdfghjkl"),
            Array("zxcvbnm"),
        ]
        var map: [Character: Set<Character>] = [:]
        for group in [rows[0...2], rows[3...5]] {
            let r = Array(group)
            for rowIdx in 0..<r.count {
                for colIdx in 0..<r[rowIdx].count {
                    let ch = r[rowIdx][colIdx]
                    var set = map[ch] ?? []
                    if colIdx > 0 { set.insert(r[rowIdx][colIdx - 1]) }
                    if colIdx + 1 < r[rowIdx].count { set.insert(r[rowIdx][colIdx + 1]) }
                    if rowIdx > 0 {
                        for dc in -1...1 {
                            let c = colIdx + dc
                            if c >= 0 && c < r[rowIdx - 1].count { set.insert(r[rowIdx - 1][c]) }
                        }
                    }
                    if rowIdx + 1 < r.count {
                        for dc in -1...1 {
                            let c = colIdx + dc
                            if c >= 0 && c < r[rowIdx + 1].count { set.insert(r[rowIdx + 1][c]) }
                        }
                    }
                    map[ch] = set
                }
            }
        }
        return map
    }()

    private static func areAdjacentKeys(_ a: Character, _ b: Character) -> Bool {
        keyboardNeighbors[a]?.contains(b) == true
    }

    private static func isSingleAdjacentKeySubstitution(_ a: [Character], _ b: [Character]) -> Bool {
        guard a.count == b.count else { return false }
        var diffIdx: Int?
        for i in 0..<a.count where a[i] != b[i] {
            if diffIdx != nil { return false }
            diffIdx = i
        }
        guard let idx = diffIdx else { return false }
        return areAdjacentKeys(a[idx], b[idx])
    }

    /// Modern Russian/tech words missing from macOS's built-in dictionary (or frequently
    /// mangled beyond Apple spellcheck's single-edit guess window) so typos like
    /// `автокомлпикт → автокомплит`, `функцинал → функционал`, `сьезают → съезжают`,
    /// `накадвыаюстя → накладываются` are fixed automatically on Space and before polish.
    private static let customCorrectionVocabulary: [String] = [
        "автокомплит", "автокомплита", "автокомплите", "автокомплитом",
        "автокоррект", "автодополнение", "автодополнения", "автоправка", "автоправки",
        "функционал", "функционала", "интерфейс", "интерфейсе", "интерфейса",
        "приложение", "приложения", "приложении", "перепроверь",
        "сообщения", "сообщений", "съезжают", "накладываются",
        "подсказки", "подсказок", "подсказку", "контекст", "контекста",
        "скриншот", "скриншоты", "дефолтом", "виртуалке", "свитчер",
        "репозиторий", "деплой", "стейджинг", "пайплайн", "промпт",
        "пофиксить", "постфактум", "дообучение", "синонимы", "адаптер",
        "раскладка", "раскладку", "раскладки", "исправлять", "добавлялись"
    ]

    private static func bestCustomVocabularyMatch(forLowerWord lower: String, collapsedWord: String) -> String? {
        guard lower.count >= 6 else { return nil }
        let inputChars = Array(lower)
        let sortedInput = lower.sorted()
        var best: (word: String, dist: Int)?

        for candidate in customCorrectionVocabulary {
            guard abs(candidate.count - lower.count) <= 2 else { continue }
            let candChars = Array(candidate)
            let firstMatches = inputChars[0] == candChars[0]
            let firstTwoSwapped = inputChars.count >= 2 && candChars.count >= 2
                && inputChars[0] == candChars[1] && inputChars[1] == candChars[0]
            guard firstMatches || firstTwoSwapped else { continue }

            let d1 = editDistance(lower, candidate)
            let d2 = collapsedWord != lower ? editDistance(collapsedWord, candidate) : d1
            let dist = min(d1, d2)

            let isCloseAnagram = candidate.count == lower.count && candidate.sorted() == sortedInput
            let maxAllowed: Int
            if isCloseAnagram && lower.count >= 6 {
                maxAllowed = 2
            } else if lower.count >= 11 && inputChars.prefix(2).elementsEqual(candChars.prefix(2)) {
                // Allows severe fast-typing garbles like "накадвыаюстя" -> "накладываются" (dist 3)
                maxAllowed = 3
            } else if lower.count >= 7 {
                maxAllowed = 2
            } else {
                maxAllowed = 1
            }

            guard dist > 0 && dist <= maxAllowed else { continue }
            if best == nil || dist < best!.dist {
                best = (candidate, dist)
            }
        }
        return best?.word
    }

    /// High-confidence automatic typo fixer invoked on word boundaries (Space/Enter)
    /// so fast-typing transpositions, missing letters, and repeated letters like
    /// `моудль -> модуль`, `криов -> криво`, `дефотом -> дефолтом`, `прилоенжие -> приложение`,
    /// `вклчюиттть -> включить` are fixed automatically by default.
    @MainActor
    public static func autoCorrectTypedWord(_ word: String) -> String? {
        guard word.count >= 4, word.count <= 32 else { return nil }
        guard word != word.uppercased() else { return nil }
        // Letters only (skip numbers, paths, snake_case, camelCase, URLs).
        guard word.allSatisfy(\.isLetter) else { return nil }
        let lower = word.lowercased()
        guard !protectedTechWords.contains(lower) else { return nil }
        if let direct = directTypoFixes[lower] {
            return matchCasing(from: word, to: direct)
        }

        // Skip mixed Latin + Cyrillic tokens.
        let hasCyr = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let hasLat = word.unicodeScalars.contains { (0x0041...0x005A).contains($0.value) || (0x0061...0x007A).contains($0.value) }
        guard hasCyr != hasLat else { return nil }

        // Skip internal camelCase like "myWord" or "iPhone".
        let chars = Array(word)
        if chars.dropFirst().contains(where: \.isUppercase) { return nil }

        let lang = hasCyr ? "ru" : "en"
        let checker = NSSpellChecker.shared
        let misspelled = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: lang,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        guard misspelled.location == 0 && misspelled.length == word.utf16.count else {
            return nil
        }

        // Collapse 3+ consecutive identical letters (e.g. "вклчюиттть" -> "вклчюить") as an
        // auxiliary lookup form so severe key-hold typos still find exact dictionary matches.
        let collapsed = collapseTripleLetters(lower)
        var rawGuesses = checker.guesses(
            forWordRange: NSRange(location: 0, length: word.utf16.count),
            in: word,
            language: lang,
            inSpellDocumentWithTag: 0
        ) ?? []
        if collapsed != lower {
            let collapsedRange = NSRange(location: 0, length: collapsed.utf16.count)
            let collapsedMis = checker.checkSpelling(
                of: collapsed,
                startingAt: 0,
                language: lang,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            if collapsedMis.location == NSNotFound {
                rawGuesses.insert(collapsed, at: 0)
            } else {
                let extra = checker.guesses(
                    forWordRange: collapsedRange,
                    in: collapsed,
                    language: lang,
                    inSpellDocumentWithTag: 0
                ) ?? []
                rawGuesses.append(contentsOf: extra)
            }
        }

        let inputStartsUpper = word.first?.isUppercase == true
        let ranked = selectBestGuess(
            from: rawGuesses,
            forLowerWord: lower,
            collapsedWord: collapsed,
            inputStartsUpper: inputStartsUpper,
            strictAutoMode: true
        ) ?? bestCustomVocabularyMatch(forLowerWord: lower, collapsedWord: collapsed)
        guard let chosen = ranked else { return nil }
        return matchCasing(from: word, to: chosen)
    }

    private static func collapseTripleLetters(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var last: Character?
        var run = 0
        for ch in s {
            if ch == last {
                run += 1
                if run <= 2 { out.append(ch) }
            } else {
                last = ch
                run = 1
                out.append(ch)
            }
        }
        // Also collapse double-letter runs when original had 3+ of the same letter (e.g. "ттт" -> "т").
        if out != s {
            var single = ""
            single.reserveCapacity(out.count)
            var prev: Character?
            var runOrig = 0
            var origPrev: Character?
            var tripleChars = Set<Character>()
            for ch in s {
                if ch == origPrev {
                    runOrig += 1
                    if runOrig >= 3 { tripleChars.insert(ch) }
                } else {
                    origPrev = ch
                    runOrig = 1
                }
            }
            for ch in out {
                if ch == prev && tripleChars.contains(ch) {
                    continue
                }
                single.append(ch)
                prev = ch
            }
            return single
        }
        return out
    }

    private static func selectBestGuess(
        from guesses: [String],
        forLowerWord lowerWord: String,
        collapsedWord: String,
        inputStartsUpper: Bool,
        strictAutoMode: Bool
    ) -> String? {
        let lowerChars = Array(lowerWord)
        let sortedInput = lowerWord.sorted()
        let maxDist = strictAutoMode
            ? (lowerWord.count >= 6 ? 2 : 1)
            : (lowerWord.count >= 7 ? 3 : 2)

        var seen = Set<String>()
        var best: (candidate: String, score: Int)?

        for (rank, candidate) in guesses.prefix(10).enumerated() {
            guard !candidate.contains(" ") else { continue }
            let lowerCand = candidate.lowercased()
            guard lowerCand != lowerWord else { continue }
            guard seen.insert(lowerCand).inserted else { continue }

            // Never auto-replace a lowercase common word with a proper noun (e.g. "криов" -> "Киров").
            let candStartsUpper = candidate.first?.isUppercase == true
            if !inputStartsUpper && candStartsUpper {
                continue
            }

            let distOrig = editDistance(lowerWord, lowerCand)
            let distCollapsed = collapsedWord != lowerWord ? editDistance(collapsedWord, lowerCand) : distOrig
            let dist = min(distOrig, distCollapsed)

            let isAnagram = (lowerCand.count == lowerWord.count && lowerCand.sorted() == sortedInput)
            let effectiveMaxDist = (isAnagram && lowerWord.count >= 5) ? max(maxDist, 2) : maxDist
            guard dist <= effectiveMaxDist else { continue }

            let candChars = Array(lowerCand)
            let adjacentSub = dist == 1 && isSingleAdjacentKeySubstitution(lowerChars, candChars)

            if strictAutoMode {
                guard let f1 = lowerChars.first, let f2 = candChars.first else { continue }
                let firstMatches = (f1 == f2)
                let firstTwoSwapped = (lowerChars.count >= 2 && candChars.count >= 2 && lowerChars[0] == candChars[1] && lowerChars[1] == candChars[0])
                let firstDeleted = (lowerChars.count >= 2 && lowerChars[1] == f2) || (candChars.count >= 2 && candChars[1] == f1)
                let firstAdjacent = areAdjacentKeys(f1, f2)
                // Prevent jumping to an unrelated word with a different initial letter at dist >= 2.
                if dist >= 2 && !firstMatches && !firstTwoSwapped {
                    continue
                }
                if dist == 1 && !firstMatches && !firstTwoSwapped && !firstDeleted && !firstAdjacent {
                    continue
                }
            } else if dist == 3 && abs(lowerWord.count - lowerCand.count) > 2 {
                continue
            }

            // Lower score is better: edit distance dominates, with strong bonuses for exact
            // letter-set permutations and physically adjacent keyboard-key slips.
            let score = dist * 100 - (isAnagram ? 45 : 0) - (adjacentSub ? 35 : 0) + rank * 6
            if best == nil || score < best!.score {
                best = (candidate, score)
            }
        }

        return best?.candidate
    }

    /// Pre-cleans obvious single-word wrong-layout mistakes and unambiguous typos
    /// across a full message before LLM polish (so `lbrndrf` becomes `диктовка`
    /// even for small local models).
    @MainActor
    public static func preCleanForPolish(_ text: String) -> String {
        let dominantLang = detectScriptLanguage(text)
        guard dominantLang == "ru" || dominantLang == "en" else { return text }

        // Tokenize preserving exact whitespace and punctuation.
        var out = ""
        out.reserveCapacity(text.count)
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].isLetter {
                let wordStart = idx
                while idx < text.endIndex && text[idx].isLetter {
                    idx = text.index(after: idx)
                }
                let word = String(text[wordStart..<idx])

                // Skip tokens adjacent to code/path symbols (/, _, ., @, :)
                let prevChar: Character? = wordStart > text.startIndex ? text[text.index(before: wordStart)] : nil
                let nextChar: Character? = idx < text.endIndex ? text[idx] : nil
                let isCodeAdjacent = (prevChar.map { "/_.@:#\\".contains($0) } ?? false)
                    || (nextChar.map { "/_.@:#\\".contains($0) } ?? false)

                if !isCodeAdjacent && word.count >= 4 && word != word.uppercased() && !protectedTechWords.contains(word.lowercased()) {
                    if dominantLang == "ru", let rescued = rescueWrongLayoutWord(word, precedingContext: "пример ") {
                        out.append(rescued)
                        continue
                    }
                    if dominantLang == "en", let rescued = rescueWrongLayoutWord(word, precedingContext: "example ") {
                        out.append(rescued)
                        continue
                    }
                    // Fix unambiguous dictionary typos in the dominant language before LLM polish
                    // using strictAutoMode so real words like "правились" are never turned into "нравились".
                    if let wordLang = detectScriptLanguage(word), wordLang == dominantLang,
                       let fixed = autoCorrectTypedWord(word) {
                        out.append(fixed)
                        continue
                    }
                }
                out.append(word)
            } else {
                out.append(text[idx])
                idx = text.index(after: idx)
            }
        }
        return out
    }

    /// Fast heuristic to reject source code, shell commands, URLs, and file paths
    /// so automatic post-factum polish never alters technical input.
    public static func looksLikeCodeOrCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("./")
            || trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("```") || trimmed.hasPrefix("$ ") || trimmed.hasPrefix("> ") {
            return true
        }
        let codeSignals = ["=>", "::", "&&", "||", "==", "!=", "${", "func ", "class ", "struct ", "import ", "const ", "let ", "var ", "return ", "def ", "SELECT ", "git ", "cd ", "npm ", "swift ", "python"]
        for signal in codeSignals where trimmed.contains(signal) {
            return true
        }
        let braceCount = trimmed.filter { "{}[]();<>`\\".contains($0) }.count
        if braceCount >= 3 && Double(braceCount) / Double(max(trimmed.count, 1)) > 0.04 {
            return true
        }
        return false
    }

    /// Deterministic instant prose cleanup (capitalization, double spaces, `что бы` -> `чтобы`,
    /// safe commas before Russian subordinate clauses, plus single-word typo/layout pre-clean).
    @MainActor
    public static func deterministicQuickPolish(_ text: String) -> String {
        guard !looksLikeCodeOrCommand(text) else { return text }

        // 1. Fix obvious dictionary/custom-vocab typos and wrong-layout words.
        var out = preCleanForPolish(text)

        // 2. Collapse accidental repeated spaces inside lines (without touching newlines).
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }

        // 3. Safe Russian phrase fixes ("что бы" -> "чтобы", "так же" -> "также" when not followed by "как").
        if let regex = try? NSRegularExpression(
            pattern: "(?i)\\bчто\\s+бы\\b(?!\\s+(?:ни|было|ты|вы|он|она|они|мы|я|это|ещё|еще)\\b)",
            options: []
        ) {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "чтобы")
        }
        if let regex = try? NSRegularExpression(
            pattern: "(?i)\\bтак\\s+же\\b(?!\\s*,?\\s*(?:как|само|самое)\\b)",
            options: []
        ) {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "также")
        }

        // 4. Insert missing comma before common Russian conjunctions when preceded by a content word.
        let clausePattern = "(?i)(?<=[А-Яа-яЁё0-9])\\s+(?=(?:чтобы|потому\\s+что|так\\s+как|поэтому|хотя|однако|если|когда|но|который|которая|которое|которые|которого|которой|которых)\\b)"
        if let regex = try? NSRegularExpression(pattern: clausePattern, options: []) {
            // Avoid putting a comma right after coordinating particles like "и чтобы", "а чтобы", "но чтобы".
            let matches = regex.matches(in: out, options: [], range: NSRange(out.startIndex..., in: out))
            for match in matches.reversed() {
                guard let swiftRange = Range(match.range, in: out) else { continue }
                let before = out[..<swiftRange.lowerBound]
                let prevWord = before.split(whereSeparator: { !$0.isLetter }).last.map { String($0).lowercased() } ?? ""
                let skipAfter: Set<String> = ["и", "а", "но", "или", "даже", "лишь", "только", "ведь", "просто"]
                if !skipAfter.contains(prevWord) && !prevWord.isEmpty {
                    out.replaceSubrange(swiftRange, with: ", ")
                }
            }
        }

        // 5. Capitalize the first letter of the message and after sentence-ending punctuation (. ! ?).
        var chars = Array(out)
        var shouldCap = true
        for i in 0..<chars.count {
            let ch = chars[i]
            if shouldCap {
                if ch.isLetter {
                    if ch.isLowercase {
                        chars[i] = Character(String(ch).uppercased())
                    }
                    shouldCap = false
                } else if !ch.isWhitespace && !"\"'«([".contains(ch) {
                    shouldCap = false
                }
            } else if ".!?".contains(ch) {
                // Only capitalize after punctuation followed by whitespace (avoid "v1.2" or "foo.bar").
                if i + 1 < chars.count && chars[i + 1].isWhitespace {
                    shouldCap = true
                }
            } else if ch == "\n" {
                shouldCap = true
            }
        }
        return String(chars)
    }

    /// Returns true if `text` is natural prose that would visibly benefit from automatic
    /// post-factum fixing (missing start capitalization, double spaces, typos, wrong layout,
    /// `что бы`, or a long unpunctuated run without commas).
    @MainActor
    public static func needsPostFactumPolish(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 14, trimmed.count <= 600 else { return false }
        guard !looksLikeCodeOrCommand(trimmed) else { return false }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 3 else { return false }

        // 1. Starts with lowercase letter.
        if let firstLetter = trimmed.first(where: \.isLetter), firstLetter.isLowercase {
            return true
        }
        // 2. Accidental double spaces.
        if trimmed.contains("  ") {
            return true
        }
        // 3. Lowercase letter after sentence-ending punctuation (". привет").
        if trimmed.range(of: "[.!?]\\s+[a-zа-яё]", options: .regularExpression) != nil {
            return true
        }
        // 4. Common Russian missing-comma / split-conjunction triggers.
        if trimmed.range(of: "(?i)\\b(?:что\\s+бы|так\\s+же)\\b", options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: "(?i)[А-Яа-яЁё0-9]\\s+(?:чтобы|потому\\s+что|так\\s+как|поэтому|который|которая|которое|которые|хотя|однако|но)\\b", options: .regularExpression) != nil {
            return true
        }
        // 5. Long unpunctuated prose run (7+ words with zero commas/periods/question/exclamation marks).
        let hasClausePunctuation = trimmed.contains(where: { ",.;:!?—–".contains($0) })
        if words.count >= 7 && !hasClausePunctuation {
            return true
        }
        // 6. Any misspelled word or wrong-layout word in the dominant language.
        let cleaned = preCleanForPolish(trimmed)
        if cleaned != trimmed {
            return true
        }
        return false
    }

    /// Computes the minimal suffix edit (delete N trailing chars, insert replacement)
    /// when `updated` shares a long unchanged prefix with `original`.
    public static func minimalTailReplacement(from original: String, to updated: String) -> (deleteCount: Int, insertText: String)? {
        guard original != updated else { return nil }
        let origChars = Array(original)
        let newChars = Array(updated)
        var common = 0
        let limit = min(origChars.count, newChars.count)
        while common < limit && origChars[common] == newChars[common] {
            common += 1
        }
        // Only use incremental tail replacement when a real prefix is shared and tail deletion is compact.
        guard common > 0 else { return nil }
        let deleteCount = origChars.count - common
        guard deleteCount <= 42 else { return nil }
        let insertText = String(newChars[common...])
        return (deleteCount, insertText)
    }

    /// Returns true if the text has a low ratio of misspelled words and is safe
    /// to store as a clean writing-style example for LLM autocomplete.
    @MainActor
    public static func isCleanForStyleHistory(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let checkable = words.filter { $0.count >= 4 && $0 != $0.uppercased() }
        guard checkable.count >= 3 else { return true }

        let checker = NSSpellChecker.shared
        var misspelledCount = 0
        for word in checkable {
            guard let lang = detectScriptLanguage(word) else { continue }
            let range = checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: lang,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            if range.location != NSNotFound && range.length > 0 {
                misspelledCount += 1
            }
        }
        // Reject snippets where >= 25% of words are typos (or >= 3 typos in a short snippet).
        let ratio = Double(misspelledCount) / Double(checkable.count)
        return misspelledCount < 3 && ratio < 0.25
    }

    /// Best spelling correction for a single word using explicit script language + Damerau-Levenshtein.
    @MainActor
    public static func bestSpellingCorrection(
        for word: String,
        inContext fullText: String? = nil,
        wordStart: String.Index? = nil
    ) -> String? {
        let lowerInput = word.lowercased()
        if protectedTechWords.contains(lowerInput) { return nil }
        if let direct = directTypoFixes[lowerInput] {
            return matchCasing(from: word, to: direct)
        }
        guard let lang = detectScriptLanguage(word) else { return nil }
        let checker = NSSpellChecker.shared

        let misspelled = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: lang,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        guard misspelled.location == 0 && misspelled.length == word.utf16.count else {
            return nil
        }

        // Pass the surrounding sentence to NSSpellChecker when available so macOS's
        // language model can rank context-appropriate guesses first.
        let guesses: [String]
        if let fullText, let wordStart, fullText.count > word.count {
            let tailWindowStart = fullText.index(wordStart, offsetBy: -min(120, fullText.distance(from: fullText.startIndex, to: wordStart)))
            let contextSlice = String(fullText[tailWindowStart...])
            let offsetInSlice = fullText[tailWindowStart..<wordStart].utf16.count
            let nsRange = NSRange(location: offsetInSlice, length: word.utf16.count)
            guesses = checker.guesses(forWordRange: nsRange, in: contextSlice, language: lang, inSpellDocumentWithTag: 0) ?? []
        } else {
            let nsRange = NSRange(location: 0, length: word.utf16.count)
            guesses = checker.guesses(forWordRange: nsRange, in: word, language: lang, inSpellDocumentWithTag: 0) ?? []
        }
        let lowerWord = word.lowercased()
        let collapsed = collapseTripleLetters(lowerWord)
        let inputStartsUpper = word.first?.isUppercase == true
        guard let chosen = selectBestGuess(
            from: guesses,
            forLowerWord: lowerWord,
            collapsedWord: collapsed,
            inputStartsUpper: inputStartsUpper,
            strictAutoMode: false
        ) ?? bestCustomVocabularyMatch(forLowerWord: lowerWord, collapsedWord: collapsed) else { return nil }
        return matchCasing(from: word, to: chosen)
    }

    /// Detects a word accidentally typed in the opposite EN/RU keyboard layout
    /// (e.g., `lbrndrf` inside Russian text -> `диктовка`).
    @MainActor
    public static func rescueWrongLayoutWord(_ word: String, precedingContext: String) -> String? {
        guard word.count >= 4, let wordLang = detectScriptLanguage(word) else { return nil }
        let contextLang = detectScriptLanguage(precedingContext)
        guard let contextLang, contextLang != wordLang else { return nil }

        let checker = NSSpellChecker.shared
        // Only rescue if the typed word is NOT valid in its own script language.
        let ownCheck = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: wordLang,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        guard ownCheck.location != NSNotFound && ownCheck.length > 0 else { return nil }

        let mapped = wordLang == "en" ? mapEnToRu(word) : mapRuToEn(word)
        let targetLang = wordLang == "en" ? "ru" : "en"

        // 1. Direct layout match is a valid dictionary word (e.g. "ghbdtn" -> "привет").
        let directCheck = checker.checkSpelling(
            of: mapped,
            startingAt: 0,
            language: targetLang,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        if directCheck.location == NSNotFound {
            return matchCasing(from: word, to: mapped)
        }

        // 2. Layout match + 1 typo (e.g. "lbrndrf" -> "диктвка" -> "диктовка").
        let nsRange = NSRange(location: 0, length: mapped.utf16.count)
        let guesses = checker.guesses(forWordRange: nsRange, in: mapped, language: targetLang, inSpellDocumentWithTag: 0) ?? []
        if let first = guesses.first,
           !first.contains(" "),
           editDistance(mapped.lowercased(), first.lowercased()) <= 1 {
            return matchCasing(from: word, to: first)
        }

        return nil
    }

    /// Returns true if a single-word or two-word synonym candidate passes macOS spellcheck
    /// in its script language (filtering out rare small-LLM typo hallucinations like "быстко").
    @MainActor
    public static func isValidDictionaryPhrase(_ phrase: String) -> Bool {
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return false }
        let checker = NSSpellChecker.shared
        for word in words {
            let clean = word.trimmingCharacters(in: CharacterSet.letters.inverted)
            guard clean.count >= 2, let lang = detectScriptLanguage(clean) else { continue }
            let range = checker.checkSpelling(
                of: clean,
                startingAt: 0,
                language: lang,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            if range.location != NSNotFound && range.length > 0 {
                return false
            }
        }
        return true
    }

    public static func detectScriptLanguage(_ text: String) -> String? {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                cyrillic += 1
            } else if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                latin += 1
            }
        }
        if cyrillic == 0 && latin == 0 { return nil }
        return cyrillic >= latin ? "ru" : "en"
    }

    private static func matchCasing(from original: String, to replacement: String) -> String {
        guard let firstOrig = original.first, let firstRep = replacement.first else { return replacement }
        if firstOrig.isUppercase {
            return String(firstRep).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    private static let enToRuMap: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з",
        "[": "х", "]": "ъ", "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л",
        "l": "д", ";": "ж", "'": "э", "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь",
        ",": "б", ".": "ю",
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н", "U": "Г", "I": "Ш", "O": "Щ", "P": "З",
        "{": "Х", "}": "Ъ", "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П", "H": "Р", "J": "О", "K": "Л",
        "L": "Д", ":": "Ж", "\"": "Э", "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И", "N": "Т", "M": "Ь",
        "<": "Б", ">": "Ю",
    ]

    private static let ruToEnMap: [Character: Character] = Dictionary(uniqueKeysWithValues: enToRuMap.map { ($1, $0) })

    private static func mapEnToRu(_ text: String) -> String {
        String(text.map { enToRuMap[$0] ?? $0 })
    }

    private static func mapRuToEn(_ text: String) -> String {
        String(text.map { ruToEnMap[$0] ?? $0 })
    }

    /// Optimal String Alignment (Damerau-Levenshtein) distance where adjacent transpositions
    /// like `моудль` -> `модуль` or `recieve` -> `receive` count as a single edit.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                var best = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
                if i > 1 && j > 1 && aChars[i - 1] == bChars[j - 2] && aChars[i - 2] == bChars[j - 1] {
                    best = min(best, dp[i - 2][j - 2] + 1)
                }
                dp[i][j] = best
            }
        }
        return dp[m][n]
    }
}
