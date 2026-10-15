import AppIntents
import SwiftUI
import UIKit
import UserNotifications

@main
struct WTFApp: App {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(model.container)
                .task {
                    // Carry on listening if it was on when the app last ran.
                    Log.info("App started (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    if !ListeningActivity.drawable { Log.error("WTF's widget extension isn't installed: no pill, Lock Screen card or controls") }
                    await model.tidyUp()
                    // A card left from before WTF was closed would still say "Recording".
                    if !model.recording { ListeningActivity.shared.stop() }
                    model.resumeIfNeeded()
                    model.processNow()
                }
                // Tapping the Lock Screen card: "what was I saying?". Tapping the listening pill in
                // the Dynamic Island: a sheet to stop (iOS opens the app for a tap on the pill;
                // holding it shows the Pause button without opening anything).
                .onOpenURL { url in
                    if url.host == "ask" { model.askFromShortcut() }
                    if url.host == "listening", model.recording { model.stopSheet = true }
                }
        }
        .onChange(of: phase) { _, now in
            if now == .active {
                model.resumeIfNeeded()
                model.processNow()
                Task { await model.expireOld() }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("welcomed") private var welcomed = false

    var body: some View {
        if model.wiping {
            // Settings › Delete All Recordings, under way: no screen is left reading what's going.
            VStack(spacing: 14) {
                ProgressView()
                Text("Deleting everything\u{2026}").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.tab) {
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right", value: 0) { AskView().modifier(TabSwipe()) }
            Tab("Timeline", systemImage: "clock", value: 1) { TimelineView().modifier(TabSwipe()) }
            Tab("Lists", systemImage: "checklist", value: 2) { ListsView() } // no tab swipe: rows swipe to delete
            Tab("Settings", systemImage: "gear", value: 3) { SettingsView().modifier(TabSwipe()) }
        }
        // Black and white throughout; colour only where it means something (Settings, deleting).
        .tint(.primary)
        .sensoryFeedback(.selection, trigger: model.tab)
        .sheet(isPresented: Binding(get: { !welcomed }, set: { if !$0 { welcomed = true } })) {
            WelcomeSheet { welcomed = true }
                .interactiveDismissDisabled()
        }
        .alert("Couldn\u{2019}t start listening", isPresented: Binding(get: { model.startFailed != nil }, set: { if !$0 { model.startFailed = nil } })) {
            if model.startFailed?.contains("microphone:") == true {
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.startFailed ?? "")
        }
        .sheet(isPresented: $model.stopSheet) {
            StopListeningSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

/// From a tap on the listening pill: stop with one more tap, or carry on.
struct StopListeningSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .medium))
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .padding(.top, 28)
            VStack(spacing: 4) {
                Text("WTF is listening").font(.title2.bold())
                if let since = model.listeningSince {
                    Text("Since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 10) {
                Button {
                    model.setListening(false)
                    dismiss()
                } label: {
                    // Black on white (white on black in light mode): the app's tint is white, and
                    // a filled button's own text would be white on white.
                    Label("Stop Listening", systemImage: "stop.fill")
                        .font(.headline)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(Color.primary))
                }
                .buttonStyle(.plain)
                if model.hasHeard {
                    Button("What Was I Saying?") {
                        dismiss()
                        model.askFromShortcut()
                    }
                    .frame(maxWidth: .infinity)
                }
                Button("Keep Listening") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .tint(.primary)
        .sensoryFeedback(.impact, trigger: model.recording)
    }
}

/// Swipe left or right anywhere on a screen to go to the next or previous tab, as well as tapping
/// the tab bar. Not while a page is open on top (swiping right goes back there), not from the
/// screen's edge, and not when the swipe was scrolling something sideways (the thread trail).
struct TabSwipe: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Set by anything that scrolls sideways itself, so its swipes don't change tab.
    nonisolated(unsafe) static var sidewaysScrollUntil = Date.distantPast

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .global).onEnded { drag in
                guard model.pathIsEmpty(for: model.tab), Date() > Self.sidewaysScrollUntil else { return }
                let dx = drag.translation.width, dy = drag.translation.height
                let width = UIScreen.main.bounds.width
                guard abs(dx) > abs(dy) * 2,
                      abs(dx) > 80 || abs(drag.predictedEndTranslation.width) > 200,
                      drag.startLocation.x > 24, drag.startLocation.x < width - 24 else { return }
                let next = model.tab + (dx < 0 ? 1 : -1)
                guard (0...3).contains(next) else { return }
                withAnimation(.snappy) { model.tab = next }
            }
        )
    }
}

/// Listening on or off, in words, in the app's quiet black and white: "Listen" with a mic when
/// it's off, a moving waveform and "Listening" when it's on (tap to pause).
struct ListeningButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.setListening(!model.recording) } label: {
            HStack(spacing: 6) {
                if model.recording {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: "mic")
                }
                Text(model.recording ? "Listening" : model.isStarting ? "Starting\u{2026}" : "Listen").font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
        }
        .accessibilityHint(model.recording ? "Pauses listening" : "Starts listening")
        .sensoryFeedback(.impact(weight: .medium), trigger: model.recording)
    }
}

/// The first time WTF opens: what it does with what it hears, before it's asked for the microphone.
struct WelcomeSheet: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Before WTF listens").font(.largeTitle.bold()).padding(.top, 36)
            point("ear", "It listens for speech around you while it's on: yours and other people's. Silence and music aren't kept.")
            point("iphone", "Everything's transcribed and summarised on this iPhone. Nothing is uploaded, and it isn't in your backups.")
            point("clock.arrow.circlepath", "Conversations are deleted after the time you choose in Settings (a week to start with). Delete any of it, or all of it, whenever you like.")
            point("person.2", "Let people know when WTF is listening, and follow the law where you are on recording others.")
            Spacer()
            Button(action: done) {
                Text("Continue").font(.headline)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Color.primary))
            }
            .buttonStyle(.plain)
            Link("Privacy Policy", destination: URL(string: "https://github.com/justmeclaude-ops/WTF-iphone/blob/main/PRIVACY.md")!)
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 28).padding(.bottom, 20)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        Label { Text(text).foregroundStyle(.secondary) } icon: { Image(systemName: icon).foregroundStyle(.primary) }
    }
}
