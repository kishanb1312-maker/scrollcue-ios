// Logic test for voice tracking. Compiled on CI with:
//   swiftc ScrollCue/Engine/ScriptTokens.swift ScrollCue/Engine/ScriptMatcher.swift Tests/MatcherTest.swift
import Foundation

let script = """
Welcome to ScrollCue. This is your personal teleprompter, and right now it is listening to you.

Read this out loud. As you speak, the script follows your voice word by word. If you go off script, it simply waits for you to come back.

Tap any word to jump straight to it. Drag the text with your finger to move around by hand. The quick brown fox jumps over the lazy dog, and the dog does not care at all.
"""

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { failures += 1; print("FAIL: \(msg)") } else { print("ok: \(msg)") }
}

let tokens = ScriptTokens(text: script)
let matcher = ScriptMatcher(tokens: tokens)
let words = tokens.words.map { (script as NSString).substring(with: $0.range) }
print("words: \(words.count), sentences: \(tokens.sentenceStarts.count)")

/// Simulates the recognizer: partial results grow word by word; a new
/// segment starts every `segment` words. `mutate` lets us inject errors.
func simulate(segment: Int, mutate: (Int, String) -> [String]) -> (cursor: Int, maxLead: Int, regressions: Int) {
    var cursor = 0
    var transcript: [String] = []
    var maxLead = 0
    var regressions = 0
    for (i, w) in words.enumerated() {
        if i > 0 && i % segment == 0 { transcript = [] }
        transcript += mutate(i, w)
        // Recognizers often report a partial last word first.
        if let last = transcript.last, last.count > 5 {
            var partial = transcript
            partial[partial.count - 1] = String(last.prefix(3))
            if let n = matcher.match(transcript: partial, cursor: cursor) { if n < cursor { regressions += 1 }; cursor = n }
        }
        if let n = matcher.match(transcript: transcript, cursor: cursor) { if n < cursor { regressions += 1 }; cursor = n }
        // Feeding the same transcript again must not advance (idempotent).
        let again = matcher.match(transcript: transcript, cursor: cursor)
        if again != nil { regressions += 1 }
        maxLead = max(maxLead, cursor - (i + 1))
    }
    return (cursor, maxLead, regressions)
}

// 1. Perfect reading.
let perfect = simulate(segment: 1000) { _, w in [w] }
check(perfect.cursor == words.count, "perfect reading reaches the end (\(perfect.cursor)/\(words.count))")
check(perfect.maxLead <= 0, "never runs ahead of the speaker (lead \(perfect.maxLead))")
check(perfect.regressions == 0, "idempotent, never moves backwards")

// 2. Recognizer restarts every 12 words.
let segmented = simulate(segment: 12) { _, w in [w] }
check(segmented.cursor >= words.count - 1, "survives recognizer restarts (\(segmented.cursor)/\(words.count))")

// 3. Misrecognised words (every 7th word wrong).
let noisy = simulate(segment: 25) { i, w in i % 7 == 3 ? ["banana"] : [w] }
check(noisy.cursor >= words.count - 2, "tolerates misrecognitions (\(noisy.cursor)/\(words.count))")

// 4. Off-script ad-libs: cursor must not move during them, then resume.
var cursor = 0
var t: [String] = []
for w in words.prefix(10) { t.append(w); if let n = matcher.match(transcript: t, cursor: cursor) { cursor = n } }
let before = cursor
for w in ["um", "so", "basically", "what", "I", "wanted", "to", "mention", "honestly"] {
    t.append(w); if let n = matcher.match(transcript: t, cursor: cursor) { cursor = n }
}
check(cursor - before <= 1, "waits while going off-script (moved \(cursor - before))")
for w in words.dropFirst(10).prefix(10) { t.append(w); if let n = matcher.match(transcript: t, cursor: cursor) { cursor = n } }
check(cursor >= 19, "resumes after coming back to the script (\(cursor))")

// 5. Skipping a sentence ahead re-syncs.
cursor = 0
t = []
let jumpTo = tokens.sentenceStarts[3]
for w in words[jumpTo..<(jumpTo + 6)] { t.append(w); if let n = matcher.match(transcript: t, cursor: cursor) { cursor = n } }
check(cursor >= jumpTo + 5 || jumpTo > 30, "re-syncs after skipping ahead (\(cursor) vs \(jumpTo + 6))")

// 6. Fuzzy matching.
check(ScriptMatcher.similar("teleprompter", "teleprompters"), "plural matches")
check(ScriptMatcher.similar("scrollcue", "scrollcu"), "partial word matches")
check(!ScriptMatcher.similar("the", "a"), "short different words don't match")

// 7. Sentence navigation.
check(tokens.nextSentenceStart(after: 0) == tokens.sentenceStarts[1], "next sentence")
check(tokens.previousSentenceStart(before: tokens.sentenceStarts[2]) == tokens.sentenceStarts[1], "previous sentence")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
