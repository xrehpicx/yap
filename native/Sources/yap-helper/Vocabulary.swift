import Foundation
import NaturalLanguage

/// Chooses words worth listening for (names, products, identifiers) from text on screen, and
/// spots transcripts that might contain a misheard one.
enum Vocabulary {
    /// FluidAudio tightens its matching above 100 terms; stay under it.
    static let maxTerms = 100

    /// Everyday English, from the word embedding that ships with macOS (57,000 words, including
    /// inflections such as "running" or "commits"). Loading takes a moment, so warm it early.
    private static let english = NLEmbedding.wordEmbedding(for: .english)

    static func warmUp() {
        _ = english?.contains("warm")
    }

    private static let token = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9]*(?:[.+#-][A-Za-z0-9]+)*"#)
    private static let noise: Set<String> = ["http", "https", "www", "com", "org", "net", "html", "localhost"]

    /// Terms from the given text, most frequent first, after any the user always wants.
    static func terms(in texts: [String], always: [String] = []) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for text in texts {
            for match in token.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let word = String(text[range])
                guard isTerm(word) else { continue }
                if firstSeen[word] == nil { firstSeen[word] = firstSeen.count }
                counts[word, default: 0] += 1
            }
        }
        let ranked = counts.keys.sorted { (counts[$0]!, -firstSeen[$0]!) > (counts[$1]!, -firstSeen[$1]!) }
        var result: [String] = []
        for term in always + ranked where !result.contains(term) && result.count < maxTerms {
            result.append(term)
        }
        return result
    }

    /// Whether a word from the screen is unusual enough to be worth listening for.
    static func isTerm(_ word: String) -> Bool {
        guard (3...30).contains(word.count), !noise.contains(word.lowercased()) else { return false }
        // Mostly letters: skips hashes, versions and IDs.
        let letters = word.filter(\.isLetter).count
        guard letters * 10 >= word.count * 7 else { return false }

        let lower = word.lowercased()
        let everyday = english?.contains(lower) == true
        // "TypeScript", "iPhone", "tRPC": casing that no ordinary word has.
        let innerCapital = word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
        if innerCapital { return true }
        // Acronyms such as ANE or JSON, but not shouted ordinary words.
        if word.allSatisfy({ $0.isUppercase || $0.isNumber }) { return word.count <= 6 && !everyday }
        return !everyday
    }

    // MARK: - Identifiers

    /// Ticket and issue keys such as RE-727, ENG-4521 or PR42.
    private static let identifier = try! NSRegularExpression(pattern: #"\b[A-Za-z]{2,10}[-_]?[0-9]{1,7}\b"#)
    /// Runs of letters or digits: "Re", "727".
    private static let alphanumeric = try! NSRegularExpression(pattern: #"[A-Za-z0-9]+"#)

    /// Identifiers on screen, most frequent first. Spoken as "re seven two seven", they are
    /// matched by their letters and digits rather than by sound.
    static func identifiers(in texts: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for text in texts {
            for match in identifier.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                counts[String(text[range]), default: 0] += 1
            }
        }
        return counts.keys.sorted { counts[$0]! > counts[$1]! }.prefix(200).map { $0 }
    }

    /// Replaces words whose letters and digits exactly match a screen term but are written
    /// differently: "Re 727" → RE-727, "Fluid Audio" → FluidAudio. Identifiers are matched
    /// regardless of case; plain words only when the spacing differs, never for case alone.
    /// Needs no audio check, so it costs nothing.
    static func snap(_ text: String, to terms: [String]) -> String {
        var targets: [[UInt8]: String] = [:]
        for term in terms {
            let key = normalized(term)
            if key.count >= 3, targets[key] == nil { targets[key] = term }
        }
        guard !targets.isEmpty else { return text }

        let tokens = alphanumeric.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text)
        }
        var output = ""
        var cursor = text.startIndex
        var index = 0
        while index < tokens.count {
            var matched = false
            // Prefer the longest span: "Re 727" over "Re".
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let span = tokens[index..<(index + length)]
                // Only words separated by spaces or hyphens belong together.
                let range = span.first!.lowerBound..<span.last!.upperBound
                let surface = String(text[range])
                guard length == 1 || surface.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" })
                else { continue }
                guard let term = targets[normalized(surface)], surface != term else { continue }
                let isIdentifier = term.contains(where: \.isNumber)
                guard isIdentifier || length > 1 || (surface.lowercased() != term.lowercased() && surface.count != term.count)
                else { continue }
                output += text[cursor..<range.lowerBound] + term
                cursor = range.upperBound
                index += length
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        return output + text[cursor...]
    }

    // MARK: - Near misses

    static func isEveryday(_ word: String) -> Bool {
        let letters = word.lowercased().filter { $0.isLetter }
        return !letters.isEmpty && english?.contains(letters) == true
    }

    /// Transcript words that look like a mishearing of a vocabulary term. See `looksLikeMishearing`.
    static func nearMisses(in text: String, terms: [String]) -> [String] {
        let words = Array(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).prefix(300))
        let targets: [(term: String, key: [UInt8], letters: [Int], words: Int)] = terms.compactMap { term in
            let key = normalized(term)
            guard key.count >= 4 else { return nil }
            return (term, key, letterCounts(key), max(1, term.split(separator: " ").count))
        }
        guard !words.isEmpty, !targets.isEmpty else { return [] }

        // Every run of one to four words, with its letters run together.
        let wordKeys = words.map(normalized)
        let wordEveryday = words.map(isEveryday)
        var spans: [Span] = []
        for start in words.indices {
            for length in 1...4 where start + length <= words.count {
                let range = start..<(start + length)
                let key = Array(wordKeys[range].joined())
                spans.append(
                    Span(
                        key: key, letters: letterCounts(key), wordKeys: Array(wordKeys[range]),
                        everyday: length == 1 && wordEveryday[start],
                        text: words[range].joined(separator: " ")))
            }
        }

        var found: [String] = []
        var scratch = DistanceScratch()
        for target in targets {
            for span in spans where span.wordKeys.count <= target.words + 2 {
                // Exact letters written differently ("RE727", "Fluid Audio") are fixed by `snap`
                // for free; no need to wait for the audio check.
                if span.key == target.key { continue }
                let longest = max(span.key.count, target.key.count)
                guard couldBeSimilar(span.letters, target.letters, longest: longest) else { continue }
                if matches(span, term: target.term, termKey: target.key, scratch: &scratch) {
                    found.append(target.term)
                    break
                }
            }
        }
        return found
    }

    private struct Span {
        let key: [UInt8]
        let letters: [Int]
        let wordKeys: [[UInt8]]
        let everyday: Bool
        let text: String
    }

    /// Whether `heard` is plausibly `term` misheard. The more ordinary the heard words, the
    /// closer they must be:
    /// - the same letters spaced or joined differently: "Fluid Audio" for FluidAudio;
    /// - an unusual word, loosely: "superbase" for Supabase, "Shaden" for shadcn;
    /// - several words run together, closely: "change lock" for changelog, "super base" for Supabase;
    /// - a single everyday word, only if nearly identical, so "refactor" never becomes React.
    /// Case-only differences never count.
    static func looksLikeMishearing(_ heard: String, of term: String) -> Bool {
        var scratch = DistanceScratch()
        return looksLikeMishearing(heard, of: term, scratch: &scratch)
    }

    static func looksLikeMishearing(_ heard: String, of term: String, scratch: inout DistanceScratch) -> Bool {
        let wordKeys = heard.split(separator: " ").map { normalized(String($0)) }
        let key = Array(wordKeys.joined())
        let span = Span(
            key: key, letters: letterCounts(key), wordKeys: wordKeys,
            everyday: wordKeys.count == 1 && isEveryday(heard), text: heard)
        return matches(span, term: term, termKey: normalized(term), scratch: &scratch)
    }

    private static func matches(_ span: Span, term: String, termKey: [UInt8], scratch: inout DistanceScratch) -> Bool {
        guard termKey.count >= 4, !span.key.isEmpty else { return false }
        if span.key == termKey { return span.text.lowercased() != term.lowercased() }

        let score = similarity(span.key, termKey, scratch: &scratch)
        if span.wordKeys.count > 1 {
            guard score >= 0.75 else { return false }
            // The term with a neighbouring word ("a React", "the Supabase") is not a mishearing.
            return !span.wordKeys.contains { similarity($0, termKey, scratch: &scratch) >= 0.8 }
        }
        return score >= (span.everyday ? 0.85 : 0.6)
    }

    /// Whether to accept the audio check's suggestion to replace `heard` with `term`.
    static func acceptsReplacement(of heard: String, with term: String) -> Bool {
        looksLikeMishearing(heard, of: term)
    }

    /// Applies accepted replacements to the transcript, keeping its punctuation.
    static func apply(_ replacements: [(heard: String, term: String)], to text: String) -> (text: String, count: Int) {
        var text = text
        var count = 0
        for (heard, term) in replacements where acceptsReplacement(of: heard, with: term) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range, in: text)
            else { continue }
            text.replaceSubrange(range, with: term)
            count += 1
        }
        return (text, count)
    }

    /// How often each letter and digit appears.
    private static func letterCounts(_ key: [UInt8]) -> [Int] {
        var counts = [Int](repeating: 0, count: 36)
        for byte in key { counts[byte >= 97 ? Int(byte) - 97 : Int(byte) - 48 + 26] += 1 }
        return counts
    }

    /// Half the difference in letter counts never exceeds the edit distance, so this rules out
    /// most pairs without running the full comparison.
    private static func couldBeSimilar(_ a: [Int], _ b: [Int], longest: Int) -> Bool {
        var difference = 0
        for index in 0..<36 { difference += abs(a[index] - b[index]) }
        return Double(difference) / 2 <= 0.4 * Double(longest)
    }

    /// Reused buffers, so comparing hundreds of words does not allocate for each pair.
    struct DistanceScratch {
        var previous: [Int] = []
        var current: [Int] = []
    }

    private static func normalized(_ text: String) -> [UInt8] {
        Array(text.lowercased().utf8.filter { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) })
    }

    /// 1 minus the edit distance over the longer length.
    static func similarity(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var scratch = DistanceScratch()
        return similarity(a, b, scratch: &scratch)
    }

    static func similarity(_ a: [UInt8], _ b: [UInt8], scratch: inout DistanceScratch) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        // Too different in length to reach the threshold; skip the full comparison.
        if Double(abs(a.count - b.count)) / Double(longest) > 0.4 { return 0 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if scratch.previous.count < b.count + 1 {
            scratch.previous = [Int](repeating: 0, count: b.count + 1)
            scratch.current = [Int](repeating: 0, count: b.count + 1)
        }
        for j in 0...b.count { scratch.previous[j] = j }
        for i in 1...a.count {
            scratch.current[0] = i
            for j in 1...b.count {
                let substitution = scratch.previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                scratch.current[j] = min(substitution, scratch.previous[j] + 1, scratch.current[j - 1] + 1)
            }
            swap(&scratch.previous, &scratch.current)
        }
        return 1 - Double(scratch.previous[b.count]) / Double(longest)
    }
}
