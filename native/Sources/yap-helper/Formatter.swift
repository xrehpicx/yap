import Foundation

/// Cleans up Parakeet's output with plain text rules: spoken commands, filler words, stutters and
/// spoken lists. Parakeet already punctuates, capitalizes and writes numbers, so this only fixes
/// what it leaves verbatim. It runs in microseconds, where a language model pass would add
/// hundreds of milliseconds.
enum Formatter {
    static func format(_ input: String) -> String {
        var text = input
        text = retract(text)
        text = spokenPunctuation(text)
        text = lineBreaks(text)
        text = fillers.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: "")
        text = stutters.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: "$1")
        text = spokenNumbers(text)
        text = list(text)
        text = spokenSeries(text)
        return tidy(text)
    }

    // MARK: - Spoken commands

    private static let scratchThat = regex(#"[,;:]?\s*\b(?:scratch|strike) that\b[.,;:!?]?\s*"#)

    /// "Let's meet at 5, scratch that, let's meet at 6" → "Let's meet at 6". Drops the sentence
    /// (or the clause, when spoken mid-sentence) before the command.
    private static func retract(_ input: String) -> String {
        var text = input
        while let match = scratchThat.firstMatch(in: text, range: text.fullRange),
            let range = Range(match.range, in: text)
        {
            var before = text[..<range.lowerBound]
            // When "Scratch that." is its own sentence, it retracts the previous one.
            while let last = before.last, last.isWhitespace || ".!?".contains(last) { before.removeLast() }
            let cut = before.lastIndex { ".!?\n".contains($0) }.map { text.index(after: $0) } ?? text.startIndex
            let kept = String(text[..<cut])
            let rest = String(text[range.upperBound...])
            text = kept.isEmpty || rest.isEmpty ? kept + rest : kept + " " + rest
        }
        return text
    }

    private static let questionMark = regex(#"\s*,?\s*\bquestion mark\b[?.,!]?"#)
    private static let exclamationMark = regex(#"\s*,?\s*\bexclamation (?:mark|point)\b[!.,?]?"#)

    private static func spokenPunctuation(_ text: String) -> String {
        let text = questionMark.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: "?")
        return exclamationMark.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: "!")
    }

    private static let lineBreak = regex(#"\s*[,;:.]?\s*\bnew (line|paragraph)\b[,;:.]?\s*"#)

    /// "Dear team, new paragraph, the release slipped, new line, thanks" →
    /// "Dear team,\n\nThe release slipped.\nThanks". Short lines such as greetings and
    /// sign-offs end in a comma, longer ones in a period.
    private static func lineBreaks(_ input: String) -> String {
        var text = input
        for match in lineBreak.matches(in: input, range: input.fullRange).reversed() {
            guard let range = Range(match.range, in: text), let kind = Range(match.range(at: 1), in: text)
            else { continue }
            let breakText = text[kind].lowercased() == "paragraph" ? "\n\n" : "\n"
            let line = text[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            var ending = ""
            if let last = line.last, last.isLetter || last.isNumber {
                ending = line.split(separator: " ").count <= 3 ? "," : "."
            }
            text.replaceSubrange(range, with: ending + breakText)
        }
        return text
    }

    // MARK: - Disfluencies

    private static let fillers = regex(#"(?:,\s*)?(?<![\w'])(?:u+m+|u+h+m*|e+r+m+|h+m+)\b(?:[,.](?=\s|$))?"#)

    private static let stutters = regex(
        #"\b(i|the|a|an|to|and|but|so|we|it|in|of|for|on|my|you|they|this|with|at|if|or|i'm|it's)(?:\s+\1)+\b"#)

    // MARK: - Numbers

    private static let digitWords = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9,
    ]
    private static let teenWords = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tensWords = [
        "twenty": 2, "thirty": 3, "forty": 4, "fifty": 5, "sixty": 6, "seventy": 7, "eighty": 8, "ninety": 9,
    ]
    private static let numberWord = regex(
        #"\b(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\b"#)

    /// Numbers read out in pieces become digits: "seven two seven" → 727, "four oh four" → 404,
    /// "one twenty eight k" → 128k, "twenty twenty six" → 2026. Parakeet already writes ordinary
    /// numbers as digits; a single number word ("one of them") is left alone.
    private static func spokenNumbers(_ input: String) -> String {
        let matches = numberWord.matches(in: input, range: input.fullRange).compactMap { Range($0.range, in: input) }
        guard matches.count >= 2 else { return input }

        // Group number words separated only by a single space or hyphen.
        var runs: [[Range<String.Index>]] = []
        for range in matches {
            if let last = runs.last?.last, input[last.upperBound..<range.lowerBound] == " "
                || input[last.upperBound..<range.lowerBound] == "-"
            {
                runs[runs.count - 1].append(range)
            } else {
                runs.append([range])
            }
        }

        var text = input
        for run in runs.reversed() {
            var words = run.map { input[$0].lowercased() }
            var ranges = run
            // A leading "oh" is an interjection, not a zero.
            while words.first == "oh" {
                words.removeFirst()
                ranges.removeFirst()
            }
            guard let digits = digitString(words), let first = ranges.first, let last = ranges.last else { continue }
            var end = last.upperBound
            var replacement = digits
            // "one twenty eight k" → 128k
            if text[end...].hasPrefix(" k"), text[text.index(end, offsetBy: 2)...].first.map({ !$0.isLetter }) ?? true {
                replacement += "k"
                end = text.index(end, offsetBy: 2)
            }
            text.replaceSubrange(first.lowerBound..<end, with: replacement)
        }
        return text
    }

    /// Reads number words as a sequence of digit groups. Needs at least two groups, so a lone
    /// "seven" or "twenty eight" stays as written.
    private static func digitString(_ words: [String]) -> String? {
        var groups: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if let digit = digitWords[word] {
                groups.append(String(digit))
            } else if let teen = teenWords[word] {
                groups.append(String(teen))
            } else if let tens = tensWords[word] {
                if index + 1 < words.count, let unit = digitWords[words[index + 1]], unit > 0, words[index + 1] != "oh" {
                    groups.append("\(tens)\(unit)")
                    index += 1
                } else {
                    groups.append("\(tens)0")
                }
            } else {
                return nil
            }
            index += 1
        }
        return groups.count >= 2 ? groups.joined() : nil
    }

    // MARK: - Lists

    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    private static let ordinalWords = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10,
    ]

    /// Clause-initial list markers as Parakeet writes them: "1. Milk", "Number two, eggs",
    /// "and three: bread", "One milk, two eggs", "First, we refactor", "Secondly, ...".
    /// A bare number word counts only when it is not a quantity ("one of", "two days").
    private static let listMarker = regex(
        #"(?:^|(?<=[.!?:;,] )|(?<=\n))(?:(?:and|then|or) )?"#
            + #"(?:(\d{1,2})[.)](?=\s)"#
            + #"|number (\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten)\b[,.:]?"#
            + #"|(one|two|three|four|five|six|seven|eight|nine|ten)(?:[,.:]|\b(?!\s+"# + quantityWords + #"\b))(?=\s)"#
            + #"|(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:ly)?\b,?)\s*"#)
    private static let quantityWords =
        #"(?:of|or|and|to|more|less|hundred|thousand|million|billion|times|percent|point|half"#
        + #"|seconds?|minutes?|hours?|days?|weeks?|months?|years?)"#
    private static let itemTail = regex(#"[\s,;:.]*(?:\b(?:and|or|then)\b)?[\s,;:.]*$"#)
    private static let sentenceEnd = regex(#"[.!?](?=\s|$)|\n\n"#)

    private struct Marker {
        let range: Range<String.Index>
        let value: Int
        let ordinal: Bool
    }

    /// Turns a spoken enumeration of two or more items into a numbered list.
    private static func list(_ text: String) -> String {
        let markers: [Marker] = listMarker.matches(in: text, range: text.fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            for group in 1...4 {
                guard let captured = Range(match.range(at: group), in: text) else { continue }
                let word = text[captured].lowercased()
                let value = Int(word) ?? numberWords[word] ?? ordinalWords[word]
                return value.map { Marker(range: range, value: $0, ordinal: group == 4) }
            }
            return nil
        }

        // The first run that counts 1, 2, 3… with the same kind of marker.
        var run: [Marker] = []
        for marker in markers {
            if marker.value == 1 {
                if run.count >= 2 { break }
                run = [marker]
            } else if let last = run.last, marker.value == last.value + 1, marker.ordinal == last.ordinal {
                run.append(marker)
            }
        }
        guard run.count >= 2 else { return text }

        var items: [String] = []
        for (index, marker) in run.enumerated() {
            let end = index + 1 < run.count ? run[index + 1].range.lowerBound : text.endIndex
            items.append(String(text[marker.range.upperBound..<end]))
        }
        // The last item runs to the end of its sentence; anything after is a new paragraph.
        var rest = ""
        if let last = items.last, let stop = sentenceEnd.firstMatch(in: last, range: last.fullRange),
            let stopRange = Range(stop.range, in: last)
        {
            rest = String(last[stopRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            items[items.count - 1] = String(last[..<stopRange.upperBound])
        }
        items = items.map { item in
            let trimmed = itemTail.stringByReplacingMatches(in: item, range: item.fullRange, withTemplate: "")
            return capitalizedFirst(trimmed.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !items.contains(where: \.isEmpty) else { return text }

        var intro = String(text[..<run[0].range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = intro.last, ",;:.".contains(last) { intro.removeLast() }

        var lines = intro.isEmpty ? [] : [intro + ":"]
        lines += items.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return lines.joined(separator: "\n") + (rest.isEmpty ? "" : "\n\n" + rest)
    }

    // MARK: - Lists said naturally

    /// "Intro: a, b, c" within one sentence. Parakeet writes the colon when the speaker pauses
    /// before a list, which is what makes this safe to act on.
    private static let seriesSentence = regex(
        #"(?:^|(?<=[.!?] )|(?<=\n))([^\n:.!?]{2,200}): ([^\n.!?]+)([.!?]?)(?= |\n|$)"#)
    /// "three things", "2 options": the number of items the speaker announced.
    private static let announcedCount = regex(
        #"\b(\d{1,2}|two|three|four|five|six|seven|eight|nine|ten)\s+[a-z]+"#)
    private static let finalConjunction = regex(#"^(?:and|or) "#)
    /// Items that open like a clause mean the "list" is really a run-on sentence.
    private static let clauseStart = regex(
        #"^(?:then|so|but|because|which|that|we|i|you|they|he|she|it|this|there)\b"#)

    /// "I need three things from the store: milk, eggs and a loaf of bread." →
    /// "I need three things from the store:\n- Milk\n- Eggs\n- A loaf of bread".
    /// Needs three or more short items, or exactly as many as the intro announced.
    private static func spokenSeries(_ input: String) -> String {
        var text = input
        for match in seriesSentence.matches(in: input, range: input.fullRange).reversed() {
            guard let whole = Range(match.range, in: text), let introRange = Range(match.range(at: 1), in: text),
                let seriesRange = Range(match.range(at: 2), in: text)
            else { continue }
            let intro = String(text[introRange])
            guard let items = seriesItems(String(text[seriesRange]), announced: announcedItemCount(in: intro))
            else { continue }

            let bullets = items.map { "- " + capitalizedFirst($0) }.joined(separator: "\n")
            let after = text[whole.upperBound...].trimmingCharacters(in: .whitespaces)
            let replacement = intro + ":\n" + bullets + (after.isEmpty || after.hasPrefix("\n") ? "" : "\n\n")
            text.replaceSubrange(whole.lowerBound..<text.endIndex, with: replacement + after)
        }
        return text
    }

    private static func announcedItemCount(in intro: String) -> Int? {
        guard let match = announcedCount.firstMatch(in: intro, range: intro.fullRange),
            let range = Range(match.range(at: 1), in: intro)
        else { return nil }
        let word = intro[range].lowercased()
        return Int(word) ?? numberWords[word]
    }

    private static func seriesItems(_ series: String, announced: Int?) -> [String]? {
        var parts = series.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last else { return nil }
        // "…, and bread": the Oxford comma already separated the last item.
        parts[parts.count - 1] = finalConjunction.stringByReplacingMatches(
            in: last, range: last.fullRange, withTemplate: "")

        // "eggs and a loaf of bread" may be two items or one ("salt and pepper").
        var split = parts
        let tail = parts[parts.count - 1]
        if let range = tail.range(of: " and ", options: .backwards) ?? tail.range(of: " or ", options: .backwards) {
            split.removeLast()
            split += [String(tail[..<range.lowerBound]), String(tail[range.upperBound...])]
        }

        let candidates = split.count == parts.count ? [parts] : [split, parts]
        let chosen: [String]?
        if let announced {
            chosen = candidates.first { $0.count == announced && announced >= 2 }
        } else {
            chosen = candidates.first { $0.count >= 3 }
        }
        // An announced count is strong evidence, so it allows longer items.
        let maxWords = announced == nil ? 6 : 8
        guard let items = chosen,
            items.allSatisfy({ item in
                !item.isEmpty && item.split(separator: " ").count <= maxWords
                    && clauseStart.firstMatch(in: item, range: item.fullRange) == nil
            })
        else { return nil }
        return items
    }

    // MARK: - Tidy

    private static let tidyRules: [(NSRegularExpression, String)] = [
        (regex(#"[ \t]+"#), " "),
        (regex(#" *\n *"#), "\n"),
        (regex(#"\n{3,}"#), "\n\n"),
        (regex(#"(?m)^[,;:.]+ *"#), ""),
        (regex(#" +([,.;:!?])"#), "$1"),
        (regex(#",(?: *,)+"#), ","),
        (regex(#"[,;:]([.!?])"#), "$1"),
        (regex(#"([.!?]),"#), "$1"),
        (regex(#"\?{2,}"#), "?"),
        (regex(#"!{2,}"#), "!"),
    ]

    /// Sentence starts that the edits above may have left lowercase.
    private static let sentenceStart = regex(#"(?:^|[.!?] +|\n)(\p{Ll}+)(?=[\s,.;:!?']|$)"#, caseSensitive: true)

    private static func tidy(_ input: String) -> String {
        var text = input
        for (pattern, template) in tidyRules {
            text = pattern.stringByReplacingMatches(in: text, range: text.fullRange, withTemplate: template)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for match in sentenceStart.matches(in: text, range: text.fullRange).reversed() {
            guard let word = Range(match.range(at: 1), in: text) else { continue }
            text.replaceSubrange(word, with: capitalizedFirst(String(text[word])))
        }
        return text
    }

    // MARK: - Helpers

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func regex(_ pattern: String, caseSensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }
}

extension String {
    fileprivate var fullRange: NSRange { NSRange(startIndex..., in: self) }
}
