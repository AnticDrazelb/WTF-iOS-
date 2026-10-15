import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WTFWidgets: WidgetBundle {
    var body: some Widget {
        ListeningLiveActivity()
        AskControl()
        ListeningControl()
        ListControl()
    }
}

// Controls: for Control Center, the two Lock Screen buttons (instead of the torch or camera), or
// the Action button. Each works without opening WTF.

struct AskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.wtf.ios.control.ask") {
            ControlWidgetButton(action: WTFAskControlIntent()) {
                Label("What Was I Saying?", systemImage: "questionmark.bubble")
            }
        }
        .displayName("What Was I Saying?")
        .description("Hear what you were just on about. Press again for what came before.")
    }
}

struct ListeningControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.wtf.ios.control.listening") {
            ControlWidgetButton(action: WTFListeningControlIntent()) {
                Label("WTF Listening", systemImage: "waveform")
            }
        }
        .displayName("Start or Stop Listening")
        .description("Turn WTF's listening on or off.")
    }
}

struct ListControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.wtf.ios.control.list") {
            ControlWidgetButton(action: WTFListControlIntent()) {
                Label("Read My List", systemImage: "checklist")
            }
        }
        .displayName("Read My List")
        .description("What's coming up, what to do and what to buy, read out.")
    }
}

/// The card and the pill look like the app: grey glass, white and grey text, the waveform and
/// "Listening" from its own Listen button, and capsule buttons like the stop sheet's. No red: iOS's
/// own orange dot already says the microphone's on.
enum Look {
    static let glass = Color(white: 0.16).opacity(0.72)
    static let secondary = Color.white.opacity(0.6)
    static let button = Color.white.opacity(0.14)
    static let prominent = Color.white.opacity(0.24)
}

/// Under the card's heading, and in the pill when it's held open: the answer to the last press
/// while it's fresh, otherwise the trail; then the buttons.
struct CardBody: View {
    let state: ListeningAttributes.ContentState
    /// In the pill there's no room for the trail (iOS clips anything over 160 points).
    var inIsland = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let answer = state.answer {
                // Four smaller lines: enough for a spoken recap, within iOS's 160 points.
                Text(answer)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if state.earlier {
                        CapsuleButton(intent: WTFBeforeControlIntent(), icon: "backward.fill", label: "Before that")
                    }
                    CapsuleButton(intent: WTFStopControlIntent(), icon: "stop.fill", label: "Stop")
                }
            } else {
                if state.trail.count > 1 && !inIsland { Trail(steps: state.trail) }
                PillControls(state: state)
            }
        }
    }
}

/// The controls when you hold the listening pill (and on the Lock Screen card): back a step,
/// what was I saying, stop, as a row of capsules. Each works without opening WTF. Only those
/// with something to do show: nothing to recap before anything's been heard, nothing to go back
/// to before there's an earlier topic.
struct PillControls: View {
    let state: ListeningAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if state.earlier {
                CapsuleButton(intent: WTFBeforeControlIntent(), icon: "backward.fill", label: "Before")
            }
            if state.heard {
                CapsuleButton(intent: WTFAskControlIntent(), icon: "questionmark", label: "What was I saying?", prominent: true)
                    .layoutPriority(1)
            }
            CapsuleButton(intent: WTFStopControlIntent(), icon: "stop.fill", label: "Stop")
        }
    }
}

/// A button like the app's: icon and words on a grey capsule. [prominent]: the one you'll want most.
struct CapsuleButton<I: AppIntent>: View {
    let intent: I
    let icon: String
    let label: String
    var prominent = false

    var body: some View {
        Button(intent: intent) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: prominent ? .infinity : nil, minHeight: 34)
                .background(Capsule().fill(prominent ? Look.prominent : Look.button))
        }
        .buttonStyle(.plain)
    }
}

struct ListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningAttributes.self) { context in
            Group {
                if context.isStale {
                    // WTF stopped updating it (closed, or crashed): it isn't listening.
                    Label("Not listening. Open WTF to carry on.", systemImage: "mic.slash")
                        .font(.headline).foregroundStyle(.white).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LockScreenCard(state: context.state)
                }
            }
                .activityBackgroundTint(Look.glass)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "wtf://ask"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Listening", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(since: s.since, font: .subheadline).frame(width: 60, alignment: .trailing).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    // With an answer showing, the topic gives it its line: no empty line left either.
                    if context.isStale {
                        Text("Not listening").font(.headline).lineLimit(1)
                    } else if s.answer == nil, let topic = s.topic {
                        Text(topic).font(.headline).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CardBody(state: s, inIsland: true).padding(.top, 4)
                }
            } compactLeading: {
                ListeningMark(font: .caption).padding(.leading, 2)
            } compactTrailing: {
                // A fixed width: a running time left to size itself fills the whole island.
                Elapsed(since: s.since, font: .caption2, alignment: .center).frame(width: 40)
            } minimal: {
                ListeningMark(font: .caption)
            }
            // A tap on the pill opens WTF to stop listening; holding it shows the buttons.
            .widgetURL(URL(string: "wtf://listening"))
            .keylineTint(.gray)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The waveform from WTF's own Listen button, wherever the card or the pill shows.
struct ListeningMark: View {
    var font: Font = .subheadline

    var body: some View {
        Image(systemName: "waveform")
            .font(font.weight(.semibold))
            .foregroundStyle(.white)
    }
}

/// How long it's been listening, in grey like the stop sheet's "Since…". Always given a width: a
/// running time takes all the room it's offered.
struct Elapsed: View {
    let since: Date
    let font: Font
    var alignment: TextAlignment = .trailing

    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .font(font.monospacedDigit())
            .foregroundStyle(Look.secondary)
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

struct LockScreenCard: View {
    @Environment(\.activityFamily) private var family
    let state: ListeningAttributes.ContentState

    var body: some View {
        if family == .small {
            // Apple Watch Smart Stack: just the topic and what's hanging.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) { ListeningMark(font: .caption2); Elapsed(since: state.since, font: .caption2, alignment: .leading).frame(width: 44, alignment: .leading) }
                Text(state.topic ?? "Listening").font(.headline).lineLimit(2)
                if state.hanging > 0 {
                    Text("\(state.hanging) left hanging").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } else {
            // Kept under iOS's 160 points: heading, then the trail and the buttons, or an answer
            // (which takes the topic's place) and its buttons: 12 + 22 + 8 + 64 + 8 + 34 + 12 at most.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ListeningMark()
                    Text(state.answer == nil ? (state.topic ?? "Listening") : "WTF")
                        .font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Elapsed(since: state.since, font: .subheadline).frame(width: 72, alignment: .trailing)
                }
                CardBody(state: state)
            }
            .padding(12)
        }
    }
}

/// Mum's birthday › The MOT › That video: hanging topics glow orange, the current one is bold.
struct Trail: View {
    let steps: [ListeningAttributes.Step]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                Text(step.title)
                    .font(.caption.weight(step.current ? .semibold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(step.current ? 0.18 : 0.08)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).opacity(step.hanging ? 1 : 0))
                    .foregroundStyle(.white)
            }
        }
    }
}
