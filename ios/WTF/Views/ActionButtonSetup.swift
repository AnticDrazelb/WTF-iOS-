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
    /// iPhones and on the iPhone 15 and 15 Plus (iPhone15,4 and 15,5), which don't. Nor does an
    /// iPad or a Mac running WTF.
    static let hasActionButton: Bool = {
        guard let phone = iPhone else { return false }
        return phone.major >= 16
    }()

    /// The iPhone 14 Pro (iPhone15,2 and 15,3), the 15 (15,4 and 15,5) and later have a Dynamic
    /// Island, so a listening pill; the iPhone 16e and 17e (iPhone17,5 and 18,5) and older iPhones
    /// don't, and show only the Lock Screen card. An iPad or a Mac running WTF has none.
    static let hasDynamicIsland: Bool = {
        guard let phone = iPhone else { return false }
        if ["iPhone17,5", "iPhone18,5"].contains(phone.machine) { return false }
        return phone.major >= 16 || ["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5"].contains(phone.machine)
    }()

    /// The iPhone SE (2nd and 3rd generation, iPhone12,8 and 14,6) still has a Home button, so
    /// Control Center opens from the bottom edge, not the top-right corner.
    static let hasHomeButton: Bool = {
        guard let phone = iPhone else { return false }
        return ["iPhone12,8", "iPhone14,6"].contains(phone.machine)
    }()

    /// The model identifier ("iPhone17,1") and its first number, or nil if this isn't an iPhone. The
    /// Simulator says which iPhone it's pretending to be.
    private static let iPhone: (machine: String, major: Int)? = {
        #if targetEnvironment(simulator)
        let machine = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        #else
        var name = utsname()
        uname(&name)
        let machine = withUnsafeBytes(of: name.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        #endif
        guard machine.hasPrefix("iPhone"), let major = Int(machine.dropFirst(6).prefix(while: { $0.isNumber })) else { return nil }
        return (machine, major)
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
            if ActionButtonSetupView.hasDynamicIsland {
                way("capsule", "The Listening Pill", "Tap it to stop listening. Hold it for buttons: what came before, what you were saying, and stop.")
            } else {
                way("iphone", "The Lock Screen Card", "While listening, its buttons give what came before, what you were saying, and stop.")
            }
            way("list.bullet", "WTF Menu", ActionButtonSetupView.hasActionButton
                ? "Rather choose each time? In Settings › Action Button, pick WTF Menu instead of What Was I Saying?"
                : "Rather choose each time? Use WTF Menu for Back Tap instead of What Was I Saying?")
            way("lock", "Lock Screen", "Hold the Lock Screen, tap Customise, then swap the torch or camera for a WTF button.")
            way("switch.2", "Control Center", ActionButtonSetupView.hasHomeButton
                ? "Swipe up from the bottom edge, tap +, then Add a Control, and pick WTF."
                : "Swipe down from the top-right corner, tap +, then Add a Control, and pick WTF.")
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
