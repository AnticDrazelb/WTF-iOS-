import SwiftData
import SwiftUI
import UIKit
import UserNotifications
import WTFCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("gapMinutes") private var gapMinutes = 5
    @AppStorage("keepDays") private var keepDays = 7
    @State private var speechReady: Bool?
    @State private var speechProblem: String?
    @State private var downloading = false
    @State private var confirmWipe = false
    @AppStorage("voices") private var voicesOn = true
    @AppStorage("voicesDownloaded") private var voicesDownloaded = false
    @State private var voicesLoading = false
    @State private var voicesFailed = false
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var facts: [Fact]
    @AppStorage("useContacts") private var useContacts = false
    @AppStorage("useCalendar") private var useCalendar = false
    @AppStorage("airPodsMic") private var airPodsMic = false
    @State private var accessProblem: String?
    @AppStorage("parakeet") private var betterOn = false
    @AppStorage("parakeetDownloaded") private var betterDownloaded = false
    /// How far the Better Accuracy download has got (0–1), while it's going.
    @State private var betterProgress: Double?
    /// Why the Better Accuracy download didn't finish, so the row says more than "Try Again".
    @State private var betterProblem: String?
    /// A shorter Keep Transcripts, waiting to be confirmed: it deletes conversations for good.
    @State private var pendingDays: Int?
    /// Read so the Read-Aloud Voice row changes when one's picked.
    @AppStorage(ReadAloud.voiceKey) private var chosenVoice = ""
    /// Corrections are kept in a file, not the settings: counted again on coming back.
    @State private var fixesCount = 0
    @State private var notificationsOff = false
    @State private var activitiesOff = false
    @Environment(\.scenePhase) private var scenePhase

    /// One address for the policy, wherever it's linked from.
    static let privacyPolicy = URL(string: "https://github.com/AnticDrazelb/WTF-iOS-/blob/main/PRIVACY.md")!

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.settingsPath) {
            Form {
                if !ListeningActivity.drawable {
                    Section {
                        Label {
                            Text("The listening pill, the Lock Screen card and WTF\u{2019}s Control Center buttons can\u{2019}t show: the part of WTF that draws them isn\u{2019}t installed on this iPhone. Reinstall WTF, and if AltStore asks about app extensions, keep them.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.footnote)
                    }
                }
                // Turned off in iOS Settings, these stop parts of WTF without a word: said here.
                if activitiesOff || notificationsOff {
                    Section {
                        if activitiesOff {
                            warning("Live Activities are off for WTF, so there\u{2019}s no listening pill or Lock Screen card, and the Action button and Control Center can\u{2019}t start listening.")
                        }
                        if notificationsOff {
                            warning("Notifications are off for WTF, so you\u{2019}re not told when it stops listening, and answers from Control Center or the Lock Screen don\u{2019}t show while WTF is closed.")
                        }
                        Button("Open Settings") { openSettings() }
                    }
                }
                Section {
                    Toggle("Listen Continuously", isOn: Binding(get: { model.recording || model.isStarting }, set: { model.setListening($0) })).tint(.green)
                } footer: {
                    Text("Only speech is kept: silence and music are never stored, and audio is deleted once its conversation is over. iPhones stop apps that are swiped away, so leave WTF open in the background.")
                }

                Section("On This iPhone") {
                    LabeledContent("Speech Recognition") {
                        // A first start downloads it too: not offered twice meanwhile.
                        if downloading || (model.isStarting && speechReady != true) { ProgressView() }
                        else if speechReady == true { Text("Ready").foregroundStyle(.green) }
                        else if speechReady == false { Button("Download") { download() } }
                        else { ProgressView() }
                    }
                    LabeledContent("Apple Intelligence") {
                        Text(Brain.notReadyReason == nil ? "Ready" : "Not available").foregroundStyle(Brain.notReadyReason == nil ? .green : .orange)
                    }
                    if SpeechEngine.usesDictation {
                        Text("This iPhone can\u{2019}t run Apple\u{2019}s newer speech model, so WTF uses the dictation one (the keyboard\u{2019}s microphone). It\u{2019}s a little less accurate on long conversations.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let speechProblem { Text(speechProblem).font(.footnote).foregroundStyle(.red) }
                    if let why = Brain.notReadyReason { Text(why).font(.footnote).foregroundStyle(.secondary) }
                }

                // Still shown after a change of language while it's on, so the model can be deleted.
                if Parakeet.suitable || betterOn || betterDownloaded {
                    Section {
                        Toggle("Better Accuracy", isOn: Binding(get: { betterOn }, set: { on in
                            if on && !Parakeet.suitable { return }
                            setBetter(on)
                        })).tint(.green)
                        if betterOn && Parakeet.suitable {
                            LabeledContent("Parakeet Model") {
                                if let betterProgress { betterDownloading(betterProgress) }
                                else if betterDownloaded { Text("Ready").foregroundStyle(.green) }
                                else { Button(betterProblem == nil ? "Download (440 MB)" : "Try Again") { downloadBetter() } }
                            }
                            if let betterProblem { Text(betterProblem).font(.footnote).foregroundStyle(.secondary) }
                        }
                    } header: {
                        Text("Transcription")
                    } footer: {
                        if !Parakeet.suitable {
                            Text("Better Accuracy only works when your iPhone\u{2019}s language is English. Turn it off to delete the 440 MB model.")
                        } else {
                            Text("When a conversation ends, WTF transcribes it again with NVIDIA\u{2019}s Parakeet speech model before writing it up: fewer misheard words, most of all with background noise. English only. A one-off download of about 440 MB, best on Wi-Fi; it runs on this iPhone, and turning it off deletes it. Live transcription still uses Apple\u{2019}s.")
                        }
                    }
                }

                Section {
                    Toggle("Tell Voices Apart", isOn: $voicesOn).tint(.green)
                    if voicesOn {
                        LabeledContent("Voice Models") {
                            if voicesLoading { ProgressView() }
                            else if voicesDownloaded { Text("Ready").foregroundStyle(.green) }
                            else { Button(voicesFailed ? "Try Again" : "Download (22 MB)") { downloadVoices() } }
                        }
                    }
                    // Not hidden with the switch: voiceprints are kept, and this is where they're forgotten.
                    NavigationLink(value: "people") {
                        LabeledContent("People", value: people.isEmpty ? "None yet" : "\(people.count)")
                    }
                } header: {
                    Text("Voices")
                } footer: {
                    Text("Labels who said what. Tap a speaker in any transcript to say it\u{2019}s you or who they are, and WTF knows their voice from then on. Voiceprints stay on this iPhone.")
                }

                Section {
                    NavigationLink(value: "facts") {
                        LabeledContent("Things WTF Knows", value: facts.isEmpty ? "None yet" : "\(facts.count)")
                    }
                    NavigationLink(value: "fixes") {
                        LabeledContent("Words You\u{2019}ve Corrected", value: fixesCount == 0 ? "None yet" : "\(fixesCount)")
                    }
                    Toggle("Names from Contacts", isOn: Binding(get: { useContacts }, set: { on in allow(on, contacts: true) })).tint(.green)
                    Toggle("Use My Calendar", isOn: Binding(get: { useCalendar }, set: { on in allow(on, contacts: false) })).tint(.green)
                    if let accessProblem {
                        Text(accessProblem).font(.footnote).foregroundStyle(.secondary)
                        Button("Open Settings") { openSettings() }
                    }
                } header: {
                    Text("Understanding You")
                } footer: {
                    Text("Your contacts\u{2019} names and the names and places in your calendar help it hear them right, and appointments it hears are checked against your calendar. Fix a word in any transcript by holding it, and the same mistake is caught next time. All of it stays on this iPhone.")
                }

                Section {
                    Toggle("Use AirPods Microphone", isOn: $airPodsMic).tint(.green)
                        .onChange(of: airPodsMic) { Recorder.shared.microphoneChanged() }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("With newer AirPods in, record through them in high quality: your own voice comes through much clearer, people further away a little quieter. AirPods that can\u{2019}t record in high quality aren\u{2019}t used, so music doesn\u{2019}t drop to call quality.")
                }

                Section {
                    Stepper("New conversation after \(gapMinutes) min quiet", value: $gapMinutes, in: 1...30)
                    // Shorter deletes for good, so it's asked first; longer just changes.
                    Picker("Keep Transcripts", selection: Binding(get: { keepDays }, set: { days in
                        if days < keepDays { pendingDays = days } else { keepDays = days }
                    })) {
                        ForEach([1, 3, 7, 14, 30, 90, 365], id: \.self) { Text(Self.days($0)).tag($0) }
                    }
                    .confirmationDialog("Delete conversations older than \(Self.days(pendingDays ?? keepDays))?",
                                        isPresented: Binding(get: { pendingDays != nil }, set: { if !$0 { pendingDays = nil } }),
                                        titleVisibility: .visible, presenting: pendingDays) { days in
                        Button("Delete Older Conversations", role: .destructive) {
                            keepDays = days
                            Task { await model.expireOld() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { _ in
                        Text("This can\u{2019}t be undone.")
                    }
                } header: { Text("Conversations") } footer: {
                    Text("Older conversations and their transcripts are deleted. Your lists and the things WTF knows are kept.")
                }

                Section {
                    if ActionButtonSetupView.hasActionButton {
                        NavigationLink("Set Up Action Button", value: "button")
                    }
                    NavigationLink(value: "voice") {
                        LabeledContent("Read-Aloud Voice", value: chosenVoice.isEmpty ? "Automatic" : ReadAloud.voice?.name ?? "Automatic")
                    }
                    NavigationLink("More Ways to Use WTF", value: "ways")
                } header: {
                    Text(ActionButtonSetupView.hasActionButton ? "Action Button" : "Shortcuts")
                } footer: {
                    Text(ActionButtonSetupView.hasActionButton
                         ? "One press tells you what you were just on about, without unlocking."
                         : "This iPhone has no Action button: use Back Tap or Control Center instead.")
                }

                Section {
                    NavigationLink("Diagnostics", value: "diagnostics")
                } footer: {
                    Text("If something\u{2019}s not working, share this so it can be fixed.")
                }

                Section {
                    Link("Privacy Policy", destination: Self.privacyPolicy)
                    Button("Delete All Data\u{2026}", role: .destructive) { confirmWipe = true }
                } footer: {
                    Text("Everything stays on this iPhone. Speech is transcribed and summarised on the device; nothing is uploaded.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: String.self) { page in
                switch page {
                case "people": PeopleView()
                case "voice": VoicePicker()
                case "facts": FactsView()
                case "button": ActionButtonSetupView()
                case "ways": MoreWaysView()
                case "fixes": FixesView()
                default: DiagnosticsView()
                }
            }
            .task {
                speechReady = await SpeechEngine.shared.isReady()
                // Access taken away in iOS Settings: the switch says so.
                if useContacts && !PersonalWords.contactsAllowed { useContacts = false }
                if useCalendar && !PersonalWords.calendarAllowed { useCalendar = false }
                fixesCount = Learned.fixes.count
                await checkPermissions()
            }
            // A start downloads the speech model too: the row catches up when it's done.
            .onChange(of: model.isStarting) { Task { speechReady = await SpeechEngine.shared.isReady() } }
            // Back from iOS Settings, maybe with something turned on.
            .onChange(of: scenePhase) { if scenePhase == .active { Task { await checkPermissions() } } }
            // Back from Words You've Corrected.
            .onChange(of: model.settingsPath.count) { fixesCount = Learned.fixes.count }
            .confirmationDialog("Delete everything WTF has?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    Task {
                        await model.deleteEverything()
                        fixesCount = Learned.fixes.count
                    }
                }
            } message: {
                Text("Every conversation and recording, your lists (including what you added), the people and voices WTF knows, the things it knows, the words you\u{2019}ve corrected and Ask\u{2019}s history. This can\u{2019}t be undone.")
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.footnote)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// Live Activities and notifications only off when turned off: not yet asked isn't a problem.
    private func checkPermissions() async {
        activitiesOff = !ListeningActivity.allowed
        notificationsOff = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    private static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    /// The download's progress, then a note while it's made ready for the Neural Engine (which
    /// reports nothing, and can take a minute), with a way to stop it.
    private func betterDownloading(_ fraction: Double) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 4) {
                if fraction < 1 { ProgressView(value: fraction).frame(width: 120) } else { ProgressView() }
                Text(fraction < 1 ? "Downloading\u{2026} \(Int(fraction * 100))%" : "Preparing\u{2026}")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Cancel", systemImage: "xmark.circle.fill") { setBetter(false) }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
        }
    }

    /// Turning Contacts or Calendar on asks iOS for access first.
    private func allow(_ on: Bool, contacts: Bool) {
        accessProblem = nil
        guard on else {
            if contacts { useContacts = false } else { useCalendar = false }
            PersonalWords.forget()
            return
        }
        Task {
            let granted = contacts ? await PersonalWords.askForContacts() : await PersonalWords.askForCalendar()
            if contacts { useContacts = granted } else { useCalendar = granted }
            PersonalWords.forget()
            if !granted {
                accessProblem = "WTF wasn\u{2019}t given access. Turn it on in Settings › Privacy & Security › \(contacts ? "Contacts" : "Calendars") › WTF."
            }
            model.processNow()
        }
    }

    /// Better Accuracy on: the model downloads. Off: it's deleted, to give the space back.
    private func setBetter(_ on: Bool) {
        betterOn = on
        if on {
            if !betterDownloaded { downloadBetter() }
        } else {
            betterProgress = nil
            Task {
                await Parakeet.shared.remove()
                betterDownloaded = Parakeet.downloaded
            }
        }
    }

    private func downloadBetter() {
        betterProblem = nil
        // Not started when it can't fit: it would fill the iPhone and fail near the end.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < 1_000_000_000 {
            betterProblem = Self.noSpace
            return
        }
        betterProgress = 0
        Task {
            do {
                try await Parakeet.shared.prepare { fraction in
                    Task { @MainActor in if betterProgress != nil { betterProgress = fraction } }
                }
                // Only needed when a conversation ends: not held in memory meanwhile.
                await Parakeet.shared.unload()
            } catch {
                // Switched off meanwhile: nothing to explain.
                if betterOn { betterProblem = Self.why(error) }
            }
            betterDownloaded = Parakeet.downloaded
            betterProgress = nil
            // Switched off while it was downloading: it doesn't stay.
            if !betterOn, betterDownloaded {
                await Parakeet.shared.remove()
                betterDownloaded = false
            }
        }
    }

    private static let noSpace = "Not enough free space: it needs about 1 GB. Free some up (Settings › General › iPhone Storage), then try again."

    /// What stopped the Better Accuracy download, in words.
    private static func why(_ error: Error) -> String {
        let e = error as NSError
        let errors = [e] + [e.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        for e in errors {
            if e.domain == NSURLErrorDomain, [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed].contains(e.code) {
                return "No connection. Check Wi-Fi, then try again."
            }
            if (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError) || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC)) {
                return noSpace
            }
        }
        return "The download didn\u{2019}t finish. Check Wi-Fi and free space, then try again."
    }

    private func downloadVoices() {
        voicesLoading = true
        voicesFailed = false
        Task {
            do { try await VoiceEngine.shared.prepare() } catch { voicesFailed = true }
            voicesDownloaded = VoiceEngine.downloaded
            voicesLoading = false
        }
    }

    private func download() {
        downloading = true
        Task {
            speechProblem = nil
            do {
                try await SpeechEngine.shared.prepare()
            } catch {
                Log.error("Speech model download", error)
                speechProblem = "The download didn\u{2019}t finish. Check Wi-Fi and free space, then try again."
            }
            speechReady = await SpeechEngine.shared.isReady()
            if speechReady == false && speechProblem == nil {
                let language = await SpeechEngine.shared.language()
                speechProblem = "iOS didn't install the speech model for \(language). Check Wi-Fi and free space (Settings › General › iPhone Storage), then try again."
            }
            downloading = false
        }
    }
}

/// The people WTF knows by voice: rename them, or forget them.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Person.name) private var people: [Person]
    @State private var renaming: Person?
    @State private var typed = ""

    var body: some View {
        List {
            ForEach(people) { p in
                // You can't be renamed, so your row isn't a button.
                Group {
                    if p.isMe {
                        row(p)
                    } else {
                        Button {
                            typed = p.name
                            renaming = p
                        } label: {
                            row(p)
                        }
                    }
                }
                .swipeActions {
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        model.forgetPerson(p)
                    }
                }
            }
        }
        .overlay {
            if people.isEmpty {
                ContentUnavailableView("No One Yet", systemImage: "person.2.wave.2",
                                       description: Text("Tap a speaker\u{2019}s name in a transcript to say who they are."))
            }
        }
        .navigationTitle("People")
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $typed).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let p = renaming { Task { await model.pipeline.renamePerson(p.id, to: typed) } }
            }
        } message: {
            Text("Their lines in every conversation change too.")
        }
    }

    private func row(_ p: Person) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.isMe ? "person.crop.circle.fill" : "person.circle")
                .font(.title2).foregroundStyle(VoiceColor.of(p.voice.label))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.isMe ? "You" : p.name).foregroundStyle(.primary)
                Text(heard(p.seconds)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func heard(_ seconds: Double) -> String {
        seconds < 60 ? "Voice learnt from \(Int(seconds)) seconds of speech"
            : "Voice learnt from \(Int(seconds / 60)) min of speech"
    }
}
