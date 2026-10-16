import SwiftUI

/// Settings › Set Up Action Button: where to go in Settings, in three short steps, then a press to
/// check it works. Apple gives apps no way to open the Action Button page for you (only an app's
/// own page in Settings, and App Review rejects the unofficial links), so the steps say where it is.
struct ActionButtonSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var since = Date()

    var body: some View {
        List {
            Section {
                step(1, "Open the **Settings** app and tap **Action Button**, just below Accessibility.")
                step(2, "Swipe across to **Shortcut**.")
                step(3, "Tap **Choose a Shortcut**, then **WTF**, then **What Was I Saying?**")
            } footer: {
                Text("Rather choose each time? Pick **WTF Menu** instead.")
            }

            Section {
                if works {
                    Label {
                        Text("It works")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Label("Press the Action button now", systemImage: "button.vertical.left.press")
                }
            } header: {
                Text("Try It")
            } footer: {
                Text(works ? "Press it any time, even with the screen off." : "WTF answers in your AirPods, or at the top of the screen.")
            }
        }
        .navigationTitle("Action Button")
        .animation(.default, value: works)
        .sensoryFeedback(.success, trigger: works) { _, now in now }
    }

    /// iPhone 15 Pro and later (iPhone16,1 on) have an Action button; iOS 26 also runs on older
    /// iPhones and on the iPhone 15 and 15 Plus (iPhone15,4 and 15,5), which don't. Anything that
    /// isn't an iPhone (the Simulator) is taken to have one.
    static let hasActionButton: Bool = {
        var name = utsname()
        uname(&name)
        let machine = withUnsafeBytes(of: name.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        guard machine.hasPrefix("iPhone"), let major = Int(machine.dropFirst(6).prefix(while: { $0.isNumber })) else { return true }
        return major >= 16
    }()

    /// A WTF press since this page opened.
    private var works: Bool { (model.buttonPressedAt ?? .distantPast) > since }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle")
        }
        .padding(.vertical, 2)
    }
}

/// Settings › More Ways to Use WTF: everything beyond the one press, briefly.
struct MoreWaysView: View {
    var body: some View {
        List {
            way("arrow.uturn.backward", "Press Again", "Within 20 seconds, for what came before: the topic you left hanging, then the one before.")
            way("capsule", "The Listening Pill", "Tap it to stop listening. Hold it for buttons: what came before, what you were saying, and stop.")
            way("list.bullet", "WTF Menu", ActionButtonSetupView.hasActionButton
                ? "Rather choose each time? In Settings › Action Button, pick WTF Menu instead of What Was I Saying?"
                : "Rather choose each time? Use WTF Menu for Back Tap instead of What Was I Saying?")
            way("lock", "Lock Screen", "Hold the Lock Screen, tap Customise, then swap the torch or camera for a WTF button.")
            way("switch.2", "Control Center", "Swipe down from the top-right corner, tap +, then Add a Control, and pick WTF.")
            // Back Tap only lists shortcuts in your Shortcuts library, not the ones apps offer.
            way("hand.tap", "Back Tap", "Double- or triple-tap the back of the iPhone. In the Shortcuts app, add What Was I Saying? (or WTF Menu) to your shortcuts, then pick it in Settings › Accessibility › Touch › Back Tap.")
        }
        .navigationTitle("More Ways")
    }

    private func way(_ icon: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
        .padding(.vertical, 4)
    }
}
