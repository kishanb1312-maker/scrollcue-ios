import Foundation

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
