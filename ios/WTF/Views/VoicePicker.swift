import AVFoundation
import SwiftUI

/// Settings › Read-Aloud Voice: which voice reads answers into your AirPods, and how fast.
struct VoicePicker: View {
    @AppStorage(ReadAloud.voiceKey) private var chosen = ""
    @AppStorage(ReadAloud.speedKey) private var speed = 1.0
    private let voices = ReadAloud.englishVoices

    var body: some View {
        List {
            Section {
                Picker("Speed", selection: $speed) {
                    Text("Slower").tag(0.85)
                    Text("Normal").tag(1.0)
                    Text("Faster").tag(1.15)
                    Text("Fastest").tag(1.3)
                }
                .onChange(of: speed) { ReadAloud.shared.sample(ReadAloud.voice, speed: speed) }
            }
            Section {
                row(name: "Automatic", detail: ReadAloud.defaultVoice.map { "Currently \($0.name)" } ?? "", id: "")
                ForEach(voices, id: \.identifier) { v in
                    row(name: v.name, detail: Self.describe(v), id: v.identifier)
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Tap a voice to hear it. Apple keeps Siri\u{2019}s own voices for Siri; the most natural ones it lets apps use are the Premium voices. Download them in the iPhone\u{2019}s Settings › Accessibility › Read & Speak › Voices › English (Zoe, Ava, Jamie and Serena are good), then come back here.")
            }
        }
        .navigationTitle("Read-Aloud Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(name: String, detail: String, id: String) -> some View {
        Button {
            chosen = id
            ReadAloud.shared.sample(id.isEmpty ? ReadAloud.defaultVoice : AVSpeechSynthesisVoice(identifier: id), speed: speed)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if chosen == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    /// "British · Premium"
    private static func describe(_ v: AVSpeechSynthesisVoice) -> String {
        let accent = Locale.current.localizedString(forRegionCode: String(v.language.split(separator: "-").last ?? "")) ?? v.language
        let quality: String
        switch v.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default: quality = "Standard"
        }
        return "\(accent) · \(quality)"
    }
}
