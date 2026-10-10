import Foundation

/// Aligns live speech-recognition output to the script.
/// Idempotent: feeding the same transcript twice never advances twice, which
/// matters because partial results restate the whole utterance every time.
struct ScriptMatcher {
    let words: [String]
    var lookAhead = 30
    var tail = 6

    init(tokens: ScriptTokens) {
        words = tokens.words.map(\.normalized)
    }

    /// Returns the new cursor (index of the next word to read), or nil to stay.
    func match(transcript: [String], cursor: Int) -> Int? {
        let spoken = transcript.map(ScriptTokens.normalize).filter { !$0.isEmpty }
        guard let last = spoken.last, !words.isEmpty else { return nil }
        let tailWords = Array(spoken.suffix(tail))
        let lo = max(cursor - 2, 0)
        let hi = min(cursor + lookAhead, words.count - 1)
        guard lo <= hi else { return nil }

        var best: (end: Int, score: Int)? = nil
        for e in lo...hi where Self.similar(words[e], last) {
            let score = alignmentScore(tailWords, endingAt: e)
            let distance = abs(e - cursor)
            // Short or common words need context; close-by matches need less.
            let needed: Int
            if distance <= 2 { needed = 1 }
            else if distance <= 8 { needed = min(2, tailWords.count) }
            else { needed = min(3, tailWords.count) }
            guard score >= needed else { continue }
            if let b = best {
                if score > b.score || (score == b.score && abs(e - cursor) < abs(b.end - cursor)) { best = (e, score) }
            } else {
                best = (e, score)
            }
        }
        guard let b = best else { return nil }
        let next = b.end + 1
        return next > cursor ? next : nil
    }

    /// LCS between the spoken tail and the script words ending at `end`.
    private func alignmentScore(_ spoken: [String], endingAt end: Int) -> Int {
        let start = max(end - spoken.count - 2, 0)
        let script = Array(words[start...end])
        let m = spoken.count, n = script.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if Self.similar(spoken[i - 1], script[j - 1]) {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        return dp[m][n]
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        let la = a.count, lb = b.count
        if min(la, lb) >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        if min(la, lb) >= 5 && abs(la - lb) <= 1 { return levenshtein(a, b) <= 1 }
        if min(la, lb) >= 8 && abs(la - lb) <= 2 { return levenshtein(a, b) <= 2 }
        return false
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Detects spoken voice commands in a transcript.
struct VoiceCommands {
    enum Command { case next, back, start, finish, nextSentence, previousSentence, mirror }

    var phrases: [(Command, [String])]

    init(settings s: PrompterSettings) {
        func split(_ p: String) -> [String] {
            p.split(separator: " ").map { ScriptTokens.normalize(String($0)) }.filter { !$0.isEmpty }
        }
        let all: [(Command, [String])] = [
            (.nextSentence, split(s.commandNextSentence)),
            (.previousSentence, split(s.commandPreviousSentence)),
            (.next, split(s.commandNext)),
            (.back, split(s.commandBack)),
            (.start, split(s.commandStart)),
            (.finish, split(s.commandFinish)),
            (.mirror, split(s.commandMirror)),
        ]
        phrases = all.filter { !$0.1.isEmpty }
    }

    /// Finds a command whose phrase ends at the end of `spoken` (normalized words).
    func detect(in spoken: [String]) -> Command? {
        for (cmd, phrase) in phrases where spoken.count >= phrase.count {
            if Array(spoken.suffix(phrase.count)) == phrase { return cmd }
        }
        return nil
    }
}
