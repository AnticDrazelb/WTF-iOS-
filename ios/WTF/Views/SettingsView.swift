import SwiftData
import SwiftUI
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
                Section {
                    Toggle("Listen Continuously", isOn: Binding(get: { model.recording || model.isStarting }, set: { model.setListening($0) })).tint(.green)
                } footer: {
                    Text("Only speech is kept: silence and music are never stored, and audio is deleted once its conversation is over. iPhones stop apps that are swiped away, so leave WTF open in the background.")
                }

                Section("On This iPhone") {
                    LabeledContent("Speech Recognition") {
                        if downloading { ProgressView() }
                        else if speechReady == true { Text("Ready").foregroundStyle(.green) }
                        else if speechReady == false { Button("Download") { download() } }
                        else { ProgressView() }
                    }
                    LabeledContent("Apple Intelligence") {
                        Text(Brain.notReadyReason == nil ? "Ready" : "Not available").foregroundStyle(Brain.notReadyReason == nil ? .green : .orange)
                    }
                    if let speechProblem { Text(speechProblem).font(.footnote).foregroundStyle(.red) }
                    if let why = Brain.notReadyReason { Text(why).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    Toggle("Tell Voices Apart", isOn: $voicesOn).tint(.green)
                    if voicesOn {
                        LabeledContent("Voice Models") {
                            if voicesLoading { ProgressView() }
                            else if voicesDownloaded { Text("Ready").foregroundStyle(.green) }
                            else { Button(voicesFailed ? "Try Again" : "Download (22 MB)") { downloadVoices() } }
                        }
                        NavigationLink(value: "people") {
                            LabeledContent("People", value: people.isEmpty ? "None yet" : "\(people.count)")
                        }
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
                        LabeledContent("Words You\u{2019}ve Corrected", value: Learned.fixes.isEmpty ? "None yet" : "\(Learned.fixes.count)")
                    }
                    Toggle("Names from Contacts", isOn: Binding(get: { useContacts }, set: { on in allow(on, contacts: true) })).tint(.green)
                    Toggle("Use My Calendar", isOn: Binding(get: { useCalendar }, set: { on in allow(on, contacts: false) })).tint(.green)
                    if let accessProblem { Text(accessProblem).font(.footnote).foregroundStyle(.red) }
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
                    Picker("Keep Transcripts", selection: $keepDays) {
                        ForEach([1, 3, 7, 14, 30, 90, 365], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                    }
                } header: { Text("Conversations") } footer: {
                    Text("Older conversations are deleted, with their recordings. Your lists and the things WTF knows are kept.")
                }

                Section {
                    NavigationLink("Set Up Action Button", value: "button")
                    NavigationLink(value: "voice") {
                        LabeledContent("Read-Aloud Voice", value: ReadAloud.voice?.name ?? "Default")
                    }
                    NavigationLink("More Ways to Use WTF", value: "ways")
                } header: {
                    Text("Action Button")
                } footer: {
                    Text("One press tells you what you were just on about, without unlocking.")
                }

                Section {
                    NavigationLink("Diagnostics", value: "diagnostics")
                    Link("Privacy Policy", destination: URL(string: "https://github.com/justmeclaude-ops/WTF-iphone/blob/main/PRIVACY.md")!)
                } footer: {
                    Text("If something's not working, share this so it can be fixed.")
                }

                Section {
                    Button("Delete All Data\u{2026}", role: .destructive) { confirmWipe = true }
                } footer: {
                    Text("Everything stays on this iPhone. Speech is transcribed and summarised on the device; nothing is uploaded.")
                }
            }
            .navigationTitle("Settings")
            .tint(.blue) // Settings keeps iOS's usual colours
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
            }
            .confirmationDialog("Delete everything WTF has?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) { Task { await model.deleteEverything() } }
            } message: {
                Text("Every conversation and recording, your lists (including what you added), the people and voices WTF knows, the things it knows, the words you\u{2019}ve corrected and Ask\u{2019}s history. This can\u{2019}t be undone.")
            }
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
                Button {
                    guard !p.isMe else { return }
                    typed = p.name
                    renaming = p
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: p.isMe ? "person.crop.circle.fill" : "person.circle")
                            .font(.title2).foregroundStyle(VoiceColor.of(p.voice.label))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.isMe ? "You" : p.name).foregroundStyle(.primary)
                            Text(heard(p.seconds)).font(.footnote).foregroundStyle(.secondary)
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

    private func heard(_ seconds: Double) -> String {
        seconds < 60 ? "Voice learnt from \(Int(seconds)) seconds of speech"
            : "Voice learnt from \(Int(seconds / 60)) min of speech"
    }
}
