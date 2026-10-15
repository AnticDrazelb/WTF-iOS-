import SwiftUI
import UIKit

/// What's working and what went wrong, to share when something's off. Never includes what was said.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var report = ""

    var body: some View {
        List {
            Section {
                ShareLink(item: report, subject: Text("WTF diagnostics")) {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                }
                .disabled(report.isEmpty)
            } footer: {
                Text("Versions, what's ready, counts and the error log. No transcripts, names or recordings.")
            }
            Section("Report") {
                Text(report.isEmpty ? "Gathering\u{2026}" : report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Diagnostics")
        .task { report = await Self.build(model) }
        .refreshable { report = await Self.build(model) }
    }

    @MainActor
    static func build(_ model: AppModel) async -> String {
        var name = utsname()
        uname(&name)
        let device = withUnsafeBytes(of: name.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let info = Bundle.main.infoDictionary ?? [:]
        let speech = await SpeechEngine.shared.isReady()
        let health = await model.pipeline.health()
        return """
            WTF \(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))
            \(device), iOS \(UIDevice.current.systemVersion)
            Generated \(Date().formatted(date: .abbreviated, time: .standard))

            Listening: \(model.recording ? "on" : "off")\(Recorder.shared.stalled ? " (mic stalled)" : "")
            Live transcription: \(LiveTranscriber.shared.running ? "running" : "off")
            Speech detector: \(SpeechGate.shared.isReady ? "neural" : "loudness only")
            Microphone: \(Recorder.shared.microphone)
            Pill, Lock Screen card and controls: \(ListeningActivity.drawable ? "installed" : "MISSING (reinstall WTF and keep its app extension)"), Live Activities \(ListeningActivity.allowed ? "allowed" : "turned off"), showing: \(ListeningActivity.states)
            Contacts: \(PersonalWords.useContacts && PersonalWords.contactsAllowed ? "used" : "not used"), calendar: \(PersonalWords.useCalendar && PersonalWords.calendarAllowed ? "used" : "not used")
            Corrections learnt: \(Learned.fixes.count)
            Speech model: \(speech ? "ready" : "not installed")
            Apple Intelligence: \(Brain.notReadyReason ?? "ready")
            Voices: \(VoiceEngine.enabled ? "on" : "off"), models \(VoiceEngine.downloaded ? "downloaded" : "not downloaded")
            \(health)

            Log (newest last):
            \(Log.tail())
            """
    }
}
