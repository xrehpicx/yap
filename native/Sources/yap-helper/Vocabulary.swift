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

    // MARK: - Near misses

    /// Everyday English words are taken as heard: "refactor" is never a mishearing of "React".
    static func isEveryday(_ word: String) -> Bool {
        let letters = word.lowercased().filter { $0.isLetter }
        return !letters.isEmpty && english?.contains(letters) == true
    }

    /// Transcript words that look like a vocabulary term but are not written the same way:
    /// "superbase" for Supabase, "Fluid Audio" for FluidAudio. Case-only differences do not count.
    static func nearMisses(in text: String, terms: [String]) -> [String] {
        let words = Array(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).prefix(300))
        let targets: [(term: String, key: [UInt8], letters: [Int], words: Int)] = terms.compactMap { term in
            let key = normalized(term)
            guard key.count >= 4 else { return nil }
            return (term, key, letterCounts(key), max(1, term.split(separator: " ").count))
        }
        guard !words.isEmpty, !targets.isEmpty else { return [] }

        // Every run of one to three words, with its letters run together.
        var spans: [(key: [UInt8], letters: [Int], words: Int, text: String)] = []
        for start in words.indices {
            for length in 1...3 where start + length <= words.count {
                let span = words[start..<(start + length)]
                let key = normalized(span.joined())
                spans.append((key, letterCounts(key), length, span.joined(separator: " ")))
            }
        }

        var found: [String] = []
        var scratch = DistanceScratch()
        for target in targets where !found.contains(target.term) {
            for span in spans {
                if span.words == target.words + 1 {
                    // A one-word term split in two ("Fluid Audio"): only the exact letters count.
                    if span.key == target.key {
                        found.append(target.term)
                        break
                    }
                } else if span.words <= target.words {
                    if span.key == target.key {
                        // Same letters; a near miss only if the spacing differs.
                        if span.text.lowercased() != target.term.lowercased() {
                            found.append(target.term)
                            break
                        }
                    } else if acceptsFuzzy(span.text), couldBeSimilar(span.letters, target.letters, longest: max(span.key.count, target.key.count)),
                        similarity(span.key, target.key, scratch: &scratch) >= 0.6
                    {
                        found.append(target.term)
                        break
                    }
                }
            }
        }
        return found
    }

    /// Whether heard words may be swapped for a similar-sounding term: only when none of them is
    /// everyday English.
    private static func acceptsFuzzy(_ heard: String) -> Bool {
        !heard.split(separator: " ").contains { isEveryday(String($0)) }
    }

    /// Whether to accept the audio check's suggestion to replace `heard` with `term`: the same
    /// letters spaced differently ("Fluid Audio" → FluidAudio), or an unusual word that is close
    /// to the term ("superbase" → Supabase). Everyday words are never replaced.
    static func acceptsReplacement(of heard: String, with term: String) -> Bool {
        let heardKey = normalized(heard)
        let termKey = normalized(term)
        if heardKey == termKey { return heard.lowercased() != term.lowercased() }
        return acceptsFuzzy(heard) && similarity(heardKey, termKey) >= 0.6
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
