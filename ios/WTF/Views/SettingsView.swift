import FoundationModels
import Network
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
    /// The language it transcribes in, by name, and the iPhone's own when that's a different one.
    @State private var speechLanguage: String?
    @State private var phoneLanguage: String?
    @State private var downloading = false
    @State private var confirmWipe = false
    @AppStorage("voices") private var voicesOn = true
    @AppStorage("voicesDownloaded") private var voicesDownloaded = false
    @State private var voicesLoading = false
    /// Why the voice models didn't download, so the row says more than "Try Again".
    @State private var voicesProblem: String?
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var facts: [Fact]
    @AppStorage("useContacts") private var useContacts = false
    @AppStorage("useCalendar") private var useCalendar = false
    @AppStorage("airPodsMic") private var airPodsMic = false
    @State private var accessProblem: String?
    /// Which access the note is about (true for Contacts), so coming back with it granted turns the switch on.
    @State private var accessFor: Bool?
    @AppStorage("parakeet") private var betterOn = false
    @AppStorage("parakeetDownloaded") private var betterDownloaded = false
    /// Why the Better Accuracy download didn't finish, so the row says more than "Try Again".
    @State private var betterProblem: String?
    /// Better Accuracy turned on over mobile data: the 440 MB is asked about first.
    @State private var confirmMobileData = false
    /// The Better Accuracy download under way. One started after a cancel has a newer one, so the
    /// old one's ending doesn't clear the new one's bar or show its error.
    @MainActor private static var betterRun: UUID?
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
                            // The Action button still starts it, by bringing WTF forward first; Control Center can't.
                            warning("Live Activities are off for WTF, so there\u{2019}s no listening pill or Lock Screen card, and Control Center can\u{2019}t start listening\(ActionButtonSetupView.hasActionButton ? "; the Action button opens WTF to start" : "").")
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

                Section {
                    LabeledContent("Speech Recognition") {
                        // A first start downloads it too: not offered twice meanwhile.
                        if let p = model.speechDownload, downloading || model.isStarting {
                            Text("Downloading\u{2026} \(Int(p * 100))%").foregroundStyle(.secondary).monospacedDigit()
                        } else if downloading || (model.isStarting && speechReady != true) { ProgressView() }
                        else if speechReady == true { Text("Ready").foregroundStyle(.secondary) }
                        else if speechReady == false { Button("Download") { download() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small) }
                        else { ProgressView() }
                    }
                    if let speechLanguage { LabeledContent("Language", value: speechLanguage) }
                    LabeledContent("Apple Intelligence") {
                        Text(Self.intelligenceStatus).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("On This iPhone")
                } footer: {
                    // Said under the card, as every other section does, rather than as rows in it.
                    // Left out when there's nothing to say, so an empty footer doesn't leave a gap.
                    if speechProblem != nil || (phoneLanguage != nil && speechLanguage != nil)
                        || SpeechEngine.usesDictation || Brain.notReadyReason != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if let speechProblem { Text(speechProblem).foregroundStyle(.red) }
                            if let phoneLanguage, let speechLanguage {
                                Text("Your iPhone\u{2019}s language is \(phoneLanguage), but WTF transcribes in \(speechLanguage), so speech in other languages comes out garbled.")
                            }
                            if SpeechEngine.usesDictation {
                                Text("This iPhone can\u{2019}t run Apple\u{2019}s newer speech model, so WTF uses the dictation one (the keyboard\u{2019}s microphone). It\u{2019}s a little less accurate on long conversations.")
                            }
                            if let why = Brain.notReadyReason { Text(why) }
                        }
                    }
                }

                // Still shown after a change of language while it's on, so the model can be deleted.
                if Parakeet.suitable || betterOn || betterDownloaded {
                    Section {
                        Toggle("Better Accuracy", isOn: Binding(get: { betterOn }, set: { on in
                            if on && !Parakeet.suitable { return }
                            setBetter(on)
                        })).tint(.green)
                        .confirmationDialog("Download 440 MB using mobile data?", isPresented: $confirmMobileData, titleVisibility: .visible) {
                            Button("Download") { downloadBetter(overMobileData: true) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("It\u{2019}s best on Wi-Fi.")
                        }
                        if betterOn && Parakeet.suitable {
                            LabeledContent("Parakeet Model") {
                                if let progress = model.betterProgress { betterDownloading(progress) }
                                else if betterDownloaded { Text("Ready").foregroundStyle(.secondary) }
                                else {
                                    Button(betterProblem == nil ? "Download (440 MB)" : "Try Again") { downloadBetter() }
                                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                                }
                            }
                        }
                    } header: {
                        Text("Transcription")
                    } footer: {
                        if !Parakeet.suitable {
                            Text("Better Accuracy only works when WTF transcribes in English. Turn it off to delete the 440 MB model.")
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                if betterOn, let betterProblem { Text(betterProblem) }
                                // Listening keeps WTF running in the background; otherwise iOS soon stops it.
                                if betterOn && model.betterProgress != nil && !model.recording {
                                    Text("Keep WTF open until it\u{2019}s done: iOS stops the download soon after you leave.")
                                }
                                Text("When a conversation ends, WTF transcribes it again with NVIDIA\u{2019}s Parakeet speech model before writing it up: fewer misheard words, most of all with background noise. English only. A one-off download of about 440 MB, best on Wi-Fi; it runs on this iPhone, and turning it off deletes it. Live transcription still uses Apple\u{2019}s.")
                            }
                        }
                    }
                }

                Section {
                    Toggle("Tell Voices Apart", isOn: $voicesOn).tint(.green)
                    if voicesOn {
                        LabeledContent("Voice Models") {
                            if voicesLoading { ProgressView() }
                            else if voicesDownloaded { Text("Ready").foregroundStyle(.secondary) }
                            else {
                                Button(voicesProblem == nil ? "Download (22 MB)" : "Try Again") { downloadVoices() }
                                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                            }
                        }
                    }
                    // Not hidden with the switch: voiceprints are kept, and this is where they're forgotten.
                    NavigationLink(value: "people") {
                        LabeledContent("People", value: people.isEmpty ? "None yet" : "\(people.count)")
                    }
                } header: {
                    Text("Voices")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if voicesOn, !voicesDownloaded, let voicesProblem { Text(voicesProblem) }
                        Text("Labels who said what. Tap a speaker in any transcript to say it\u{2019}s you or who they are, and WTF knows their voice from then on. Voiceprints stay on this iPhone.")
                    }
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
                        // Off the main thread: the audio route can take a moment to change over.
                        .onChange(of: airPodsMic) { Task.detached(priority: .userInitiated) { Recorder.shared.microphoneChanged() } }
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
                        Text("Conversations and Ask\u{2019}s history older than that are deleted. This can\u{2019}t be undone.")
                    }
                } header: { Text("Conversations") } footer: {
                    Text("Older conversations, their transcripts and Ask\u{2019}s history are deleted, as are list items ticked off or dismissed that long ago. What\u{2019}s still on your lists and the things WTF knows are kept.")
                }

                Section {
                    NavigationLink(value: "voice") {
                        LabeledContent("Read-Aloud Voice", value: chosenVoice.isEmpty ? "Automatic" : ReadAloud.voice?.name ?? "Automatic")
                    }
                } header: {
                    Text("Answers")
                } footer: {
                    Text("The voice that reads answers aloud.")
                }

                Section {
                    if ActionButtonSetupView.hasActionButton {
                        NavigationLink("Set Up Action Button", value: "button")
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
                    NavigationLink("Acknowledgements", value: "licences")
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
                case "licences": AcknowledgementsView()
                default: DiagnosticsView()
                }
            }
            .task {
                // Watched from now, so turning Better Accuracy on knows if it's on mobile data.
                MobileData.shared.watch()
                speechReady = await SpeechEngine.shared.isReady()
                await loadLanguage()
                // Access taken away in iOS Settings: the switch says so.
                if useContacts && !PersonalWords.contactsAllowed { useContacts = false }
                if useCalendar && !PersonalWords.calendarAllowed { useCalendar = false }
                fixesCount = Learned.fixes.count
                // Left behind (switched off as the app was stopped): there's no switch to delete it with.
                if !betterOn && betterDownloaded && model.betterProgress == nil {
                    await Parakeet.shared.remove()
                }
                // Restored from a backup, the flag can say it's downloaded when the model isn't here.
                betterDownloaded = Parakeet.downloaded
                await checkPermissions()
                followVoicesDownload()
            }
            // A start downloads the speech model too: the row catches up when it's done.
            .onChange(of: model.isStarting) {
                Task { speechReady = await SpeechEngine.shared.isReady() }
                followVoicesDownload()
            }
            // Back from iOS Settings, maybe with something turned on.
            .onChange(of: scenePhase) { if scenePhase == .active { Task { await checkPermissions() } } }
            // Back from Words You've Corrected.
            .onChange(of: model.settingsPath.count) { fixesCount = Learned.fixes.count }
            // The stop sheet can't show over a dialog: they close for it.
            .onChange(of: model.stopSheet) { _, on in if on { confirmMobileData = false; confirmWipe = false; pendingDays = nil } }
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
        // Access refused earlier, then given in iOS Settings: iOS doesn't relaunch the app for that.
        if let contacts = accessFor, contacts ? PersonalWords.contactsAllowed : PersonalWords.calendarAllowed {
            if contacts { useContacts = true } else { useCalendar = true }
            accessProblem = nil
            accessFor = nil
            PersonalWords.forget()
            model.processNow()
        }
    }

    /// Apple Intelligence in a word or two, matching the reason given under the card: still
    /// downloading or merely switched off isn't the same as this iPhone not supporting it.
    private static var intelligenceStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Ready"
        case .unavailable(.modelNotReady): return "Downloading\u{2026}"
        case .unavailable(.appleIntelligenceNotEnabled): return "Off"
        case .unavailable(.deviceNotEligible): return "Not supported"
        case .unavailable: return "Not available"
        }
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
        accessFor = nil
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
                accessFor = contacts
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
            Self.betterRun = nil
            model.betterProgress = nil
            Task {
                await Parakeet.shared.remove()
                betterDownloaded = Parakeet.downloaded
            }
        }
    }

    private func downloadBetter(overMobileData: Bool = false) {
        betterProblem = nil
        // Not started when it can't fit: it would fill the iPhone and fail near the end.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < 1_000_000_000 {
            betterProblem = Self.noSpace
            return
        }
        // 440 MB of a data plan isn't spent without asking. Cancel leaves the switch on, with Download.
        if !overMobileData && MobileData.shared.inUse {
            confirmMobileData = true
            return
        }
        // Kept on the model, so the bar survives the page being rebuilt.
        let model = self.model
        let run = UUID()
        Self.betterRun = run
        model.betterProgress = 0
        // Not listening, WTF is suspended soon after it's left, cutting the download off: a little
        // more time is asked for.
        let time = BackgroundTime("Better Accuracy download")
        Task {
            defer { time.end() }
            do {
                try await Parakeet.shared.prepare { fraction in
                    Task { @MainActor in if Self.betterRun == run, model.betterProgress != nil { model.betterProgress = fraction } }
                }
                // Only needed when a conversation ends: not held in memory meanwhile.
                await Parakeet.shared.unload()
            } catch {
                // Switched off (or started again) meanwhile: nothing to explain.
                if Self.betterRun == run, betterOn { betterProblem = Self.why(error) }
            }
            // A newer download, or none (switched off, which deletes it): that's in charge now.
            guard Self.betterRun == run else { return }
            Self.betterRun = nil
            betterDownloaded = Parakeet.downloaded
            model.betterProgress = nil
            // Switched off while it was downloading: it doesn't stay.
            if !betterOn, betterDownloaded {
                await Parakeet.shared.remove()
                betterDownloaded = false
            }
        }
    }

    private static let noSpace = "Not enough free space: it needs about 1 GB. Free some up (Settings › General › iPhone Storage), then try again."

    /// What stopped a model download, in words. [noSpace] is said when the iPhone is full, as each
    /// download needs a different amount.
    private static func why(_ error: Error, noSpace full: String = SettingsView.noSpace) -> String {
        let e = error as NSError
        let errors = [e] + [e.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        for e in errors {
            if e.domain == NSURLErrorDomain, [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed].contains(e.code) {
                return "No connection. Check Wi-Fi, then try again."
            }
            if (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError) || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC)) {
                return full
            }
        }
        return "The download didn\u{2019}t finish. Check Wi-Fi and free space, then try again."
    }

    /// Listening downloads the voice models by itself: joined here (prepare waits on the one under
    /// way), so the row shows it rather than offering Download, and says if it fails.
    private func followVoicesDownload() {
        guard voicesOn, !voicesDownloaded, !voicesLoading, model.recording, !model.isStarting else { return }
        downloadVoices()
    }

    private func downloadVoices() {
        voicesLoading = true
        voicesProblem = nil
        Task {
            do { try await VoiceEngine.shared.prepare() } catch { voicesProblem = Self.why(error, noSpace: "Not enough free space: it needs about 22 MB. Free some up (Settings › General › iPhone Storage), then try again.") }
            voicesDownloaded = VoiceEngine.downloaded
            voicesLoading = false
        }
    }

    private func download() {
        downloading = true
        model.speechDownload = 0
        Task {
            speechProblem = nil
            // A stalled download is given up on (it carries on in the system, for the next try),
            // so the row isn't left spinning with no way to try again.
            let fetched: Bool? = await withDeadline(180) { () -> Bool? in
                // A task of its own, so giving up on it doesn't cancel the download too.
                let fetch = Task {
                    try await SpeechEngine.shared.prepare { p in
                        Task { @MainActor in if AppModel.shared.speechDownload != nil { AppModel.shared.speechDownload = p } }
                    }
                }
                do {
                    try await fetch.value
                    return true
                } catch {
                    Log.error("Speech model download", error)
                    return false
                }
            }
            model.speechDownload = nil
            if fetched == nil {
                speechProblem = "Still downloading. Check Wi-Fi, then try again."
            } else if fetched == false {
                speechProblem = "The download didn\u{2019}t finish. Check Wi-Fi and free space, then try again."
            }
            speechReady = await SpeechEngine.shared.isReady()
            if speechReady == true {
                speechProblem = nil
            } else if speechProblem == nil {
                await loadLanguage()
                speechProblem = "iOS didn\u{2019}t install the speech model for \(speechLanguage ?? "this language"). Check Wi-Fi and free space (Settings › General › iPhone Storage), then try again."
            }
            downloading = false
        }
    }

    /// The language it transcribes in, by name ("English (United Kingdom)"), and the iPhone's own
    /// when that's a different one: speech in any other language comes out as nonsense.
    private func loadLanguage() async {
        let id = await SpeechEngine.shared.language()
        speechLanguage = Locale.current.localizedString(forIdentifier: id) ?? id
        let phone = Locale(identifier: Locale.preferredLanguages.first ?? id).language.languageCode
        if let phone, phone != Locale(identifier: id).language.languageCode {
            phoneLanguage = Locale.current.localizedString(forLanguageCode: phone.identifier) ?? phone.identifier
        } else {
            phoneLanguage = nil
        }
    }
}

/// Whether the connection's mobile data (or a hotspot), watched from when Settings first opens.
private final class MobileData: @unchecked Sendable {
    static let shared = MobileData()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var started = false
    private var expensive = false

    func watch() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.expensive = path.isExpensive
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "wtf.mobiledata"))
    }

    var inUse: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expensive
    }
}

/// A little more time to finish something once WTF's left (iOS gives about 30 seconds).
@MainActor
private final class BackgroundTime {
    private var task = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Out of time: let go, or iOS closes WTF.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

/// Settings › Acknowledgements: what WTF is built on, and the licences it's used under.
struct AcknowledgementsView: View {
    private struct Credit: Identifiable {
        let name: String
        let use: String
        let licence: String
        let link: URL
        /// A licence whose own words must go with the app, shown in full.
        var notice: String? = nil
        var id: String { name }
    }

    private static let credits = [
        Credit(name: "FluidAudio", use: "Runs the Better Accuracy and voice models on the Neural Engine. \u{00A9} FluidInference.",
               licence: "Apache License 2.0", link: URL(string: "https://github.com/FluidInference/FluidAudio")!),
        Credit(name: "NVIDIA Parakeet TDT 0.6B v2", use: "The Better Accuracy speech model, converted for Core ML by FluidInference.",
               licence: "CC BY 4.0", link: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2")!),
        Credit(name: "pyannote speaker-diarization-community-1", use: "Finds where each voice speaks, for Tell Voices Apart, converted for Core ML by FluidInference.",
               licence: "CC BY 4.0", link: URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!),
        Credit(name: "WeSpeaker ResNet34", use: "Tells one voice from another, for Tell Voices Apart.",
               licence: "CC BY 4.0", link: URL(string: "https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM")!),
        Credit(name: "VBx", use: "Sorts what was said into voices, for Tell Voices Apart. \u{00A9} Brno University of Technology.",
               licence: "Apache License 2.0", link: URL(string: "https://github.com/BUTSpeechFIT/VBx")!),
        Credit(name: "fastcluster", use: "Groups similar voices, for Tell Voices Apart.",
               licence: "BSD 2-Clause", link: URL(string: "https://github.com/fastcluster/fastcluster")!,
               notice: fastclusterNotice),
        Credit(name: "Silero VAD", use: "Tells speech from other sounds while WTF listens, converted for Core ML by FluidInference.",
               licence: "MIT License", link: URL(string: "https://github.com/snakers4/silero-vad")!,
               notice: sileroNotice),
    ]

    /// Its licence asks for the notice to be reproduced with the app, so it's here word for word.
    private static let fastclusterNotice = """
        Copyright:
          * Until package version 1.1.23: \u{00A9} 2011 Daniel M\u{00FC}llner <https://danifold.net>
          * All changes from version 1.1.24 on: \u{00A9} Google Inc. <https://www.google.com>
        All rights reserved.

        Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

          * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
          * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """

    /// The MIT licence also asks for its notice to go with the app.
    private static let sileroNotice = """
        Copyright (c) 2020-present Silero Team

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """

    var body: some View {
        List {
            ForEach(Self.credits) { c in
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.name).font(.headline)
                        Text(c.use).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    LabeledContent("Licence", value: c.licence)
                    Link("View Source and Licence", destination: c.link)
                    if let notice = c.notice {
                        Text(notice).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section {
                Link("Apache License 2.0", destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
                Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                Link("BSD 2-Clause", destination: URL(string: "https://opensource.org/license/bsd-2-clause")!)
                Link("MIT License", destination: URL(string: "https://opensource.org/license/mit")!)
            } header: {
                Text("Licences")
            } footer: {
                Text("The models are used unchanged apart from conversion to Core ML.")
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

/// The people WTF knows by voice: rename them, or forget them.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Person.name) private var people: [Person]
    @State private var renaming: Person?
    @State private var typed = ""
    /// Why a name typed in Rename wasn't used, so the alert doesn't just close.
    @State private var refused: String?

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
            Button("Save") { save() }
        } message: {
            Text("Their lines in every conversation change too.")
        }
        .alert(refused ?? "", isPresented: Binding(get: { refused != nil }, set: { if !$0 { refused = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if refused == Self.unusable { Text("Use a name of up to 30 letters, not a number or \u{201C}\(Labels.me)\u{201D}.") }
            else { Text("Two people with one name can\u{2019}t be told apart in transcripts again.") }
        }
        .onChange(of: model.stopSheet) { _, on in if on { renaming = nil; refused = nil } }
    }

    private static let unusable = "That Name Can\u{2019}t Be Used"

    /// A name someone else already has would merge the two in every transcript, for good: refused.
    private func save() {
        guard let p = renaming else { return }
        guard let name = Labels.cleanName(typed), name != Labels.me else {
            refused = Self.unusable
            return
        }
        if people.contains(where: { $0.id != p.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            refused = "Someone\u{2019}s Already Called \(name)"
            return
        }
        Task { await model.pipeline.renamePerson(p.id, to: typed) }
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
