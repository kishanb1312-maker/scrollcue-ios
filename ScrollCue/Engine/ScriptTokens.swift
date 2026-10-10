import Foundation

/// A script broken into words, with sentence boundaries. Shared by every layout.
struct ScriptTokens {
    struct Word {
        let range: NSRange      // UTF-16 range in `text`
        let normalized: String  // lowercased, no punctuation/diacritics
        let sentence: Int
    }

    let text: String
    let words: [Word]
    /// Index of the first word of each sentence.
    let sentenceStarts: [Int]

    init(text: String) {
        self.text = text
        let ns = text as NSString
        var words: [Word] = []
        var sentenceStarts: [Int] = []
        var sentence = 0
        var startNewSentence = true

        let regex = try? NSRegularExpression(pattern: "\\S+")
        regex?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let r = match?.range else { return }
            let raw = ns.substring(with: r)
            // A blank line between words also starts a new sentence (paragraph break).
            if let last = words.last {
                let gapStart = last.range.location + last.range.length
                let gap = ns.substring(with: NSRange(location: gapStart, length: r.location - gapStart))
                if gap.filter({ $0 == "\n" }).count >= 1 { startNewSentence = true }
            }
            if startNewSentence {
                if !words.isEmpty { sentence += 1 }
                sentenceStarts.append(words.count)
                startNewSentence = false
            }
            words.append(Word(range: r, normalized: ScriptTokens.normalize(raw), sentence: sentence))
            if let lastChar = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]»")).last,
               ".!?…。！？".contains(lastChar) {
                startNewSentence = true
            }
        }
        self.words = words
        self.sentenceStarts = sentenceStarts.isEmpty ? [0] : sentenceStarts
    }

    var count: Int { words.count }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Word index whose UTF-16 range contains or follows `location`.
    func wordIndex(atCharacter location: Int) -> Int {
        var lo = 0, hi = words.count - 1, ans = words.count
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = words[mid].range
            if r.location + r.length > location { ans = mid; hi = mid - 1 } else { lo = mid + 1 }
        }
        return min(ans, max(words.count - 1, 0))
    }

    func sentenceStart(containing index: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        let s = words[min(max(index, 0), words.count - 1)].sentence
        return sentenceStarts[min(s, sentenceStarts.count - 1)]
    }

    func nextSentenceStart(after index: Int) -> Int {
        sentenceStarts.first(where: { $0 > index }) ?? words.count
    }

    func previousSentenceStart(before index: Int) -> Int {
        let current = sentenceStart(containing: index)
        // If we're well into the sentence, go to its start; otherwise the one before.
        if index - current > 1 { return current }
        return sentenceStarts.last(where: { $0 < current }) ?? 0
    }
}
