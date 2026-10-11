import AppIntents

// Shortcut actions so the prompter can be steered while another app (like
// Camera) is in front: assign them to Back Tap (Settings › Accessibility ›
// Touch › Back Tap) or the Action Button. They run in the background without
// opening ScrollCue.

struct ScrollDownIntent: AppIntent {
    static let title: LocalizedStringResource = "Scroll Down"
    static let description = IntentDescription("Moves the ScrollCue prompter down.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PromptRemote.move(down: true)
        return .result()
    }
}

struct ScrollUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Scroll Up"
    static let description = IntentDescription("Moves the ScrollCue prompter up.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PromptRemote.move(down: false)
        return .result()
    }
}

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause Prompter"
    static let description = IntentDescription("Starts or pauses ScrollCue's scrolling.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PromptRemote.togglePlay()
        return .result()
    }
}

struct ScrollCueShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScrollDownIntent(),
                    phrases: ["Scroll down in \(.applicationName)"],
                    shortTitle: "Scroll Down", systemImageName: "chevron.down")
        AppShortcut(intent: ScrollUpIntent(),
                    phrases: ["Scroll up in \(.applicationName)"],
                    shortTitle: "Scroll Up", systemImageName: "chevron.up")
        AppShortcut(intent: PlayPauseIntent(),
                    phrases: ["Pause \(.applicationName)", "Play \(.applicationName)"],
                    shortTitle: "Play / Pause", systemImageName: "playpause")
    }
}

/// Bridges shortcut actions to whichever prompter is open.
enum PromptRemote {
    static func move(down: Bool) {
        guard let engine = PrompterEngine.current else { return }
        let step = max(engine.settings.pipStepLines, 1)
        engine.moveLines(down ? step : -step)
        PiPDiagnostics.shared.buttonPresses += 1
    }

    static func togglePlay() {
        PrompterEngine.current?.togglePlay()
    }
}
