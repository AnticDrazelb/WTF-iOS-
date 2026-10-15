import AVFoundation

/// Reads an answer into your AirPods (or any headphones): for the Action button, so you hear
/// where you'd got to without looking at the phone.
///
/// The speech is made into sound first and then played by the app itself, rather than handed to
/// iOS's speech service to play: from the background the service would sometimes say nothing.
/// Played by the app, the sound keeps the app awake until it's finished. The Action button's
/// answer has its sound made in advance (see Standby), so a press only has to play it.
@MainActor
final class ReadAloud: NSObject {
    static let shared = ReadAloud()

    private var synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connected: AVAudioFormat?
    /// Each reading has a number, so a newer one takes over from an older one.
    private var reading = 0
    private var prepared: (key: String, sound: [AVAudioPCMBuffer])?

    override private init() {
        super.init()
        engine.attach(player)
    }

    /// Headphones of any kind are the way sound is going out now.
    static var headphonesOn: Bool {
        let quiet: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { quiet.contains($0.portType) }
    }

    private static var route: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", ")
    }

    /// For the Action button: starts reading [text] into the headphones and returns as soon as
    /// it's playing (false if there are no headphones, so nothing is played). The sound itself
    /// keeps the app awake until it's finished.
    func startIntoHeadphones(_ text: String) async -> Bool {
        let ownSession = prepareSession()
        guard Self.headphonesOn else {
            Log.info("Not read aloud: sound is going to \(Self.route), not headphones")
            if ownSession { releaseSession() }
            return false
        }
        await start(text, voice: Self.voice, speed: Self.speed, ownSession: ownSession)
        return true
    }

    /// The answer kept ready for the Action button: its sound made now, so a press just plays it.
    /// The sound made ready goes (what it says may have been deleted).
    func forget() { prepared = nil }

    func prepare(_ text: String) async {
        let key = Self.key(text, Self.voice, Self.speed)
        guard prepared?.key != key else { return }
        let before = reading
        let sound = await render(utterance(text, voice: Self.voice, speed: Self.speed))
        // A reading started meanwhile stops the synthesiser: what came back may be cut short.
        if !sound.isEmpty, before == reading { prepared = (key, sound) }
    }

    /// Settings › Read-Aloud Voice: a short sample in [voice] at [speed].
    func sample(_ voice: AVSpeechSynthesisVoice?, speed: Double) {
        Task {
            let ownSession = prepareSession()
            await start("You were telling them about booking the dentist for Thursday.", voice: voice, speed: speed, ownSession: ownSession)
        }
    }

    // MARK: - Sound

    /// While listening the session can already play (and record); otherwise it's set up just to
    /// play. True if it was set up here, so it's let go afterwards.
    private func prepareSession() -> Bool {
        guard !Recorder.shared.running else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            Log.error("Couldn't get the headphones ready to read the answer out", error)
        }
        return true
    }

    private func releaseSession() {
        guard !Recorder.shared.running else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func key(_ text: String, _ voice: AVSpeechSynthesisVoice?, _ speed: Double) -> String {
        "\(voice?.identifier ?? "")|\(speed)|\(text)"
    }

    private func utterance(_ text: String, voice: AVSpeechSynthesisVoice?, speed: Double) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text.replacingOccurrences(of: "\u{2026}", with: ", "))
        u.voice = voice
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed))
        return u
    }

    /// Starts saying [text]; returns once it's playing. When it's finished (unless a newer
    /// reading has taken over) the session's let go, if it was set up for this.
    private func start(_ text: String, voice: AVSpeechSynthesisVoice?, speed: Double, ownSession: Bool) async {
        reading += 1
        let mine = reading
        player.stop()
        synthesizer.stopSpeaking(at: .immediate)
        let key = Self.key(text, voice, speed)
        // Made into sound here (or already, if it's the answer kept ready), then played here; a
        // second go with a fresh synthesiser if the first came back empty.
        var sound: [AVAudioPCMBuffer]
        if let prepared, prepared.key == key {
            sound = prepared.sound
        } else {
            sound = await render(utterance(text, voice: voice, speed: speed))
        }
        if sound.isEmpty {
            Log.error("Speech came back silent; trying again")
            synthesizer = AVSpeechSynthesizer()
            sound = await render(utterance(text, voice: voice, speed: speed))
        }
        guard mine == reading else { return }
        if !sound.isEmpty, let heard = startPlaying(sound) {
            Log.info("Reading an answer aloud into \(Self.route)")
            Task {
                await heard()
                guard mine == self.reading else { return }
                Recorder.shared.speaking = false
                self.player.stop()
                self.engine.stop()
                if ownSession { self.releaseSession() }
            }
            return
        }
        // Last resort: let iOS's speech service say it.
        Log.error("Couldn't play the speech; handing it to iOS to say into \(Self.route)")
        synthesizer.speak(utterance(text, voice: voice, speed: speed))
    }

    /// The speech as sound, or nothing if the synthesiser didn't produce any within 6 s.
    private func render(_ utterance: AVSpeechUtterance) async -> [AVAudioPCMBuffer] {
        let collected = Collected()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            collected.wait(done)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    collected.finish()
                    return
                }
                if let copy = Self.floatCopy(pcm) { collected.add(copy) }
            }
            Task {
                try? await Task.sleep(for: .seconds(6))
                collected.finish()
            }
        }
        return collected.buffers
    }

    /// Starts playing [sound]; the returned wait ends once it's been heard (or should have been).
    /// Nil if it couldn't be played.
    private func startPlaying(_ sound: [AVAudioPCMBuffer]) -> (() async -> Void)? {
        guard let format = sound.first?.format else { return nil }
        if connected != format {
            engine.stop()
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connected = format
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.error("Couldn't start playing the speech", error)
            return nil
        }
        let seconds = sound.reduce(0.0) { $0 + Double($1.frameLength) / format.sampleRate }
        let heard = Collected()
        for (i, buffer) in sound.enumerated() {
            if i == sound.count - 1 {
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in heard.finish() }
            } else {
                player.scheduleBuffer(buffer, completionHandler: nil)
            }
        }
        Recorder.shared.speaking = true // what WTF says isn't recorded
        player.play()
        return {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                heard.wait(done)
                Task {
                    try? await Task.sleep(for: .seconds(seconds + 5))
                    heard.finish()
                }
            }
        }
    }

    /// The synthesiser hands over its own buffers (sometimes 16-bit); a float copy the player can take.
    private nonisolated static func floatCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength),
              let converter = AVAudioConverter(from: buffer.format, to: target) else { return nil }
        do { try converter.convert(to: out, from: buffer) } catch { return nil }
        return out
    }

    /// Sound as it arrives from the synthesiser, and a wait that ends exactly once: when it's
    /// all there (or heard), or it's taken too long. It can finish before anyone waits.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var _buffers: [AVAudioPCMBuffer] = []
        private var waiting: CheckedContinuation<Void, Never>?
        private var finished = false

        var buffers: [AVAudioPCMBuffer] { lock.lock(); defer { lock.unlock() }; return _buffers }

        func wait(_ c: CheckedContinuation<Void, Never>) {
            lock.lock()
            if finished { lock.unlock(); c.resume(); return }
            waiting = c
            lock.unlock()
        }

        func add(_ b: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            if !finished { _buffers.append(b) }
        }

        func finish() {
            lock.lock()
            finished = true
            let w = waiting
            waiting = nil
            lock.unlock()
            w?.resume()
        }
    }

    // MARK: - Voices

    nonisolated static let voiceKey = "readAloudVoice"
    nonisolated static let speedKey = "readAloudSpeed"

    /// Your pick from Settings, or the best English voice on the phone.
    static var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return defaultVoice
    }

    static var speed: Double { UserDefaults.standard.object(forKey: speedKey) as? Double ?? 1.0 }

    /// The best voice for the phone's English: a premium or enhanced British one if installed.
    static var defaultVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.identifier.hasPrefix("en_GB") || Locale.current.region?.identifier == "GB" ? "en-GB" : AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Every English voice on the phone, best first; the novelty ones (Bells, Bubbles…) left out.
    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }
}
