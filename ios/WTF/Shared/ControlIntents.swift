import AppIntents

// The actions behind the controls (Control Center, the Lock Screen's corners, the Action button)
// and the buttons on the Lock Screen card. They're in the app and its widget extension; as Live
// Activity intents, iOS runs them in the app, which doesn't open. In the extension they're only
// there to be named, so their bodies there do nothing. They can't show anything themselves, so
// the answer goes on the card and the pill (or in a notification when WTF isn't listening).

/// What you were just saying (press again for what came before).
struct WTFAskControlIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "What Was I Saying?"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        let answer = await AppModel.shared.answerFromShortcut()
        await AppModel.shared.showAnswer(answer)
        #endif
        return .result()
    }
}

/// Listening on or off.
struct WTFListeningControlIntent: LiveActivityIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start or Stop Listening"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        let result = await AppModel.shared.toggleListeningFromShortcut()
        await AppModel.shared.showAnswer(result)
        #endif
        return .result()
    }
}

/// Stop, from the card and the pill: only ever stops (a card left from before WTF was closed
/// mustn't turn listening on), and ends every card.
struct WTFStopControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Listening"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await AppModel.shared.setListening(false)
        #endif
        return .result()
    }
}

/// Your list, read out.
struct WTFListControlIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Read My List"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        let answer = await AppModel.shared.listFromShortcut()
        await AppModel.shared.showAnswer(answer)
        #endif
        return .result()
    }
}

/// What came before that: a step further back each time (the topic left hanging, then the one
/// before). Like "previous track" on the music controls.
struct WTFBeforeControlIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "What Came Before That?"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        let answer = await AppModel.shared.beforeThatFromShortcut()
        await AppModel.shared.showAnswer(answer)
        #endif
        return .result()
    }
}
