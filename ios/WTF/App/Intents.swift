import AppIntents

/// "WTF?" from the Action button (or a Shortcut): without opening the app or unlocking. With
/// AirPods or headphones in, the answer is read into your ears; otherwise it shows at the top
/// of the screen. Either way it's waiting in Ask when you next open WTF. The same as What Was I
/// Saying?, so it's no longer offered; kept for Action buttons already set to it.
struct AskWTFIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Ask WTF"
    static let description = IntentDescription("What you were just on about: read aloud if AirPods are in, shown on screen if not. Press again for what came before.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.answerFromShortcut()
        return .result(dialog: await answerDialog(answer))
    }
}

// Audio-playback intents: iOS lets them start speaking straight away from the background,
// rather than holding the sound back until the button's pressed again. The ones that can start
// listening are audio-recording and Live Activity intents too, as iOS asks; but it won't let WTF
// switch the microphone on from the background anyway, so WTF comes forward to start it (see comeForward).

/// "What was I saying?" from the Action button, Siri or a Shortcut, without opening the app:
/// read into your ears if AirPods or headphones are in, shown at the top of the screen if not.
/// Always an answer, even with listening off; pressed again soon after one, it goes a step
/// further back (see AppModel.answerFromShortcut).
struct WhatWasISayingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "What Was I Saying?"
    static let description = IntentDescription("What you were just on about, read into your AirPods if they're in. Press again for what came before.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.answerFromShortcut()
        return .result(dialog: await answerDialog(answer))
    }
}

/// Listening on or off without opening the app.
struct ToggleListeningIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start or Stop Listening"
    static let description = IntentDescription("Listening on if it's off, off if it's on.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.toggleListeningFromShortcut(forward: { await comeForward() }, recordingIntent: true)
        return .result(dialog: "\(answer)")
    }
}

struct StartListeningIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Listening"
    static let description = IntentDescription("Switch WTF's listening on. If iOS won't allow it from the background, WTF opens to start it.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.buttonPressedAt = Date()
        let started = await AppModel.shared.startListeningFromShortcut(forward: { await comeForward() }, recordingIntent: true)
        let answer = started ? "WTF is listening." : AppModel.shared.problem ?? "Couldn't start listening."
        return .result(dialog: "\(answer)")
    }
}

/// Not an audio-recording intent: it never records, and it ends every card.
struct StopListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Listening"
    static let description = IntentDescription("Stop listening and remove the Lock Screen card.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.buttonPressedAt = Date()
        AppModel.shared.setListening(false) // even if WTF thinks it isn't: the setting and any card go too
        return .result(dialog: "WTF has stopped listening.")
    }
}

/// What's coming up, to do and to buy: read out if headphones are in, shown if not.
struct ReadMyListIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Read My List"
    static let description = IntentDescription("What's coming up, what to do and what to buy, from what WTF heard and you kept.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.listFromShortcut()
        return .result(dialog: await answerDialog(answer))
    }
}

/// The choices in the WTF Menu.
enum WTFChoice: String, AppEnum {
    case saying, before, listening, list

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "WTF"
    static let caseDisplayRepresentations: [WTFChoice: DisplayRepresentation] = [
        .saying: DisplayRepresentation(title: "What was I saying?", image: .init(systemName: "questionmark.bubble")),
        .before: DisplayRepresentation(title: "What came before that?", image: .init(systemName: "arrow.uturn.backward")),
        .listening: DisplayRepresentation(title: "Start or stop listening", image: .init(systemName: "waveform")),
        .list: DisplayRepresentation(title: "Read my list", image: .init(systemName: "checklist")),
    ]
}

/// A menu: for the Action button (or Back Tap) if you'd rather choose each time than have one
/// press do the most likely thing. Set a choice when assigning it and it does that straight away.
struct WTFMenuIntent: AudioPlaybackIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "WTF Menu"
    static let description = IntentDescription("Choose: what you were saying, what came before, listening on or off, or your list.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Choice", requestValueDialog: "What do you need?")
    var choice: WTFChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let pick: WTFChoice
        if let choice { pick = choice } else { pick = try await $choice.requestValue("What do you need?") }
        let answer: String
        // Only the answers are read aloud; on or off isn't.
        var read = true
        switch pick {
        case .saying: answer = await AppModel.shared.answerFromShortcut()
        case .before: answer = await AppModel.shared.beforeThatFromShortcut()
        case .listening:
            answer = await AppModel.shared.toggleListeningFromShortcut(forward: { await comeForward() })
            read = false
        case .list: answer = await AppModel.shared.listFromShortcut()
        }
        if read { return .result(dialog: await answerDialog(answer)) }
        return .result(dialog: "\(answer)")
    }
}

extension AppIntent {
    /// What Siri says or shows for an answer. With headphones in, WTF's already reading it into
    /// them: Siri saying it as well would talk over it, and even its short line would cut into
    /// the reading, so that waits until the reading's about done.
    @MainActor
    func answerDialog(_ answer: String) async -> IntentDialog {
        guard ReadAloud.headphonesOn else { return "\(answer)" }
        // About three words a second at normal speed, as ReadAloud reckons; capped well short of
        // iOS's limit, as working out the answer has already used some of it.
        let words = Double(answer.split(whereSeparator: \.isWhitespace).count)
        let seconds = min(words / (3 * max(ReadAloud.speed, 0.1)) + 0.5, 15)
        try? await Task.sleep(for: .seconds(seconds))
        return "Reading it into your headphones."
    }

    /// iOS won't let WTF switch the microphone on from the background: bring WTF forward, where
    /// it can (after unlocking, if the iPhone's locked). For intents with `.foreground(.dynamic)`
    /// in their supported modes. True if WTF's now in front.
    @MainActor
    func comeForward() async -> Bool {
        let mode = systemContext.currentMode
        guard mode == .background, mode.canContinueInForeground else {
            Log.info("WTF can't come forward from here to start listening")
            return false
        }
        do {
            try await continueInForeground("Open WTF to start listening?", alwaysConfirm: false)
            Log.info("WTF came forward to start listening")
            return true
        } catch {
            Log.error("WTF couldn't come forward to start listening", error)
            return false
        }
    }
}

struct WTFShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatWasISayingIntent(),
                    phrases: ["\(.applicationName) was I saying", "What was I saying in \(.applicationName)",
                              "\(.applicationName), what was I on about", "\(.applicationName) was I on about",
                              "Ask \(.applicationName)"],
                    shortTitle: "What Was I Saying?", systemImageName: "questionmark.bubble")
        AppShortcut(intent: WTFMenuIntent(), phrases: ["\(.applicationName) menu", "Show the \(.applicationName) menu"],
                    shortTitle: "WTF Menu", systemImageName: "list.bullet")
        AppShortcut(intent: ReadMyListIntent(), phrases: ["Read my \(.applicationName) list", "What's on my \(.applicationName) list"],
                    shortTitle: "Read My List", systemImageName: "checklist")
        AppShortcut(intent: StartListeningIntent(), phrases: ["Start \(.applicationName)", "Start \(.applicationName) listening"],
                    shortTitle: "Start Listening", systemImageName: "waveform")
        AppShortcut(intent: StopListeningIntent(), phrases: ["Stop \(.applicationName)", "Stop \(.applicationName) listening"],
                    shortTitle: "Stop Listening", systemImageName: "stop.fill")
        AppShortcut(intent: ToggleListeningIntent(), phrases: ["Toggle \(.applicationName) listening"],
                    shortTitle: "Start or Stop Listening", systemImageName: "waveform")
    }
}
