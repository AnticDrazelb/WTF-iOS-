import AVFoundation
import WTFCore

/// Always-on listener. Reads the mic, resamples to 16 kHz mono, and whenever speech is heard
/// writes a WAV "chunk" until it goes quiet (the same rules as the Android app: see ChunkRules).
/// Silence is never stored. Runs in the background thanks to the "audio" background mode, as
/// long as the app isn't swiped away.
final class Recorder: @unchecked Sendable {
    static let shared = Recorder()

    /// A finished chunk: its file and when its speech started and ended.
    var onChunk: ((URL, Date, Date) -> Void)?
    /// The speech being kept, as it's heard (for transcribing live): samples, the recording they
    /// belong to (its start), and where in it they go (in samples). Exact, unlike clock times.
    var onSpeech: (([Float], Date, Int) -> Void)?
    /// Something (a call, Siri, another app) took the mic; and when it's given back and listening resumes.
    var onInterrupted: (() -> Void)?
    var onResumed: (() -> Void)?
    /// The mic stopped by itself (a call took it, or the audio system restarted and it couldn't resume).
    var onStopped: (() -> Void)?

    /// A new one for every start (see freshEngine). Swapped only with [sessionLock] held, and
    /// under [infoLock] too, for [stalled] to read from anywhere.
    private var engine = AVAudioEngine()
    private var engineObserver: NSObjectProtocol?
    /// The engine before this one, kept a while: an engine mustn't be freed from inside its own
    /// notification handler (Apple: it can deadlock).
    private var retired: AVAudioEngine?
    private let queue = DispatchQueue(label: "wtf.recorder")
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private(set) var running = false
    /// WTF is reading an answer aloud: what the microphone hears meanwhile is dropped, so WTF
    /// doesn't transcribe (and act on) its own voice.
    var speaking = false {
        didSet { if speaking { speakingSince = Date() } }
    }
    private var speakingSince = Date.distantPast

    // Chunking state, only touched on [queue].
    private static let frame = 480 // 30 ms
    private static let frameMs = 30
    private var pending: [Float] = []
    private var vad = EnergyVad()
    private var recent: [Bool] = []
    private var preRoll: [[Float]] = []
    private var writer: AVAudioFile?
    private var writerURL: URL?
    private var chunkStart = Date()
    private var lastSpeech = Date()
    private var speechFrames = 0
    private var cutAt = Date.distantPast
    private var continuing = false
    /// Speech written since the last hand-over to [onSpeech], and when it started.
    private var liveBatch: [Float] = []
    private var liveOffset = 0
    /// Samples written to the recording being made.
    private var chunkSamples = 0

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, self.running,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                Log.info("Microphone taken (a call or another app)")
                self.queue.async { self.closeChunk(cut: false) }
                self.onInterrupted?()
                return
            }
            // After a phone call: carry on listening.
            self.queue.async { self.closeChunk(cut: false) }
            self.resume(why: "after an interruption")
        }
        // iOS restarted its sound system (it's rare): the audio's all made again, and listening carries on.
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, self.running else { return }
            Log.info("iOS restarted its sound system")
            self.queue.async { self.closeChunk(cut: false) }
            self.resume(why: "after iOS restarted its sound system")
        }
    }

    static var audioDirectory: URL {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Recordings never go into iCloud or computer backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// One start, restart or stop at a time: the audio route can change from several places at
    /// once (a setting, AirPods going in, a call ending), and two taps on the microphone crash.
    private let sessionLock = NSLock()

    func start() throws {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard !running else { return }
        SpeechGate.shared.start()
        do {
            try configureSession()
            freshEngine()
            try installTap()
        } catch {
            // Nothing left half-started, and the microphone let go, so it isn't shown as in use.
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        running = true
    }

    /// A new engine, made once iOS has given WTF the microphone. One made while it couldn't have
    /// it (in the background, say), or left over from a start that failed, can be stuck unable to
    /// record until WTF's closed, so none is kept from one start to the next. With [sessionLock] held.
    private func freshEngine() {
        engine.stop()
        let new = AVAudioEngine()
        let center = NotificationCenter.default
        if let engineObserver { center.removeObserver(engineObserver) }
        engineObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: new, queue: nil) { [weak self] _ in
            // Off the engine's own thread: restarting makes a new engine and lets this one go.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let self, self.running else { return }
                self.resume(why: "after the audio route changed")
            }
        }
        retired = engine
        infoLock.lock(); engine = new; infoLock.unlock()
    }

    /// Settings › Use AirPods Microphone.
    static var airPodsMic: Bool { UserDefaults.standard.bool(forKey: "airPodsMic") }
    private static let base: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
    /// What it's recording through, for Diagnostics (no device names: they're usually someone's).
    var microphone: String {
        infoLock.lock(); defer { infoLock.unlock() }
        return _microphone
    }
    private let infoLock = NSLock()
    private var _microphone = "iPhone"
    private func setMicrophone(_ m: String) { infoLock.lock(); _microphone = m; infoLock.unlock() }
    /// Headphones found not to record in high quality: not tried again (until the setting's turned
    /// off and on, or different headphones are used), or switching to them and back would go
    /// round in circles, and car kits that only do calls would keep switching into a call.
    private var callQualityOnly: String?

    /// The audio session, set up to record through the iPhone's microphones, or (if that's turned
    /// on) through AirPods that can record in high quality. Never through headphones in call
    /// quality: that would make everything else they play sound like a phone call too.
    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        let headphones = session.currentRoute.outputs.first { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }?.portName
        let worthTrying = callQualityOnly == nil || (headphones != nil && headphones != callQualityOnly)
        if Self.airPodsMic, worthTrying {
            var options = Self.base.union([.allowBluetoothHFP, .bluetoothHighQualityRecording])
            if #available(iOS 26.2, *) { options.insert(.farFieldInput) }
            do {
                try use(options)
                try session.setActive(true)
                guard let port = session.currentRoute.inputs.first else { return }
                if let mic = port.bluetoothMicrophoneExtension {
                    if mic.highQualityRecording.isEnabled || mic.farFieldCapture.isEnabled {
                        callQualityOnly = nil
                        setMicrophone(mic.farFieldCapture.isEnabled ? "Headphones (high quality, far field)" : "Headphones (high quality)")
                        Log.info("Recording through the headphones in high quality")
                        return
                    }
                    Log.info("The headphones can't record in high quality, so the iPhone's microphone is used")
                    callQualityOnly = port.portName
                } else if port.portType != .bluetoothHFP {
                    // No headphones in: the iPhone's microphone, ready to switch when they're put in.
                    setMicrophone("iPhone")
                    return
                } else {
                    Log.info("The Bluetooth device only records in call quality, so the iPhone's microphone is used")
                    callQualityOnly = port.portName
                }
            } catch {
                Log.error("Couldn't record through the headphones", error)
            }
        }
        try use(Self.base)
        try session.setActive(true)
        setMicrophone("iPhone")
    }

    private func use(_ options: AVAudioSession.CategoryOptions) throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord || session.mode != .default || session.categoryOptions != options else { return }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
    }

    /// The microphone setting changed: listening carries on through the right one.
    func microphoneChanged() {
        guard running else { return }
        sessionLock.lock(); callQualityOnly = nil; sessionLock.unlock()
        resume(why: "on the new microphone setting")
    }

    func stop() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { closeChunk(cut: false) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Listening is on, but the mic isn't actually running (iOS didn't say the interruption ended).
    var stalled: Bool {
        infoLock.lock(); defer { infoLock.unlock() }
        return running && !engine.isRunning
    }

    /// Starts the mic again after something took it. Safe to call any time listening is on.
    func resume(why: String) {
        guard running else { return }
        do {
            try restart()
            Log.info("Listening resumed \(why)")
            onResumed?()
        } catch {
            Log.error("Couldn't resume listening \(why)", error)
        }
    }

    /// Ends the chunk being recorded now, so a question includes the last few seconds.
    func flush() {
        guard running else { return }
        queue.sync { closeChunk(cut: true) }
    }

    private func restart() throws {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard running else { return }
        SpeechGate.shared.start() // in case it stopped
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            // AirPods put in or taken out: the right microphone for the new route, on a new engine.
            try configureSession()
            freshEngine()
            try installTap()
        } catch {
            // A call or Siri has the microphone: still listening, just stalled; it comes back when
            // the interruption ends (or WTF's opened again), rather than stopping for good.
            let code = (error as NSError).code
            if [MicTrouble.code("!pri"), MicTrouble.code("siri"), MicTrouble.code("!int")].contains(code) {
                Log.info("The microphone's busy (a call or Siri); listening carries on when it's free")
                throw error
            }
            running = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            onStopped?()
            throw error
        }
    }

    private func installTap() throws {
        let input = engine.inputNode
        // Mid-switch (AirPods going in or out) the microphone can briefly have no format at all:
        // a tap then would crash, so wait a moment for it. The hardware's format is what says.
        var hardware = input.inputFormat(forBus: 0)
        for _ in 0..<10 where !Self.usable(hardware) {
            Thread.sleep(forTimeInterval: 0.1)
            hardware = input.inputFormat(forBus: 0)
        }
        guard Self.usable(hardware) else { throw NoMicrophone() }
        // A tap at any other rate than the hardware's crashes.
        let given = input.outputFormat(forBus: 0)
        let format = Self.usable(given) && given.sampleRate == hardware.sampleRate ? given : hardware
        converter = AVAudioConverter(from: format, to: target)
        // A tenth of a second at a time: few wake-ups, all day.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [weak self] buffer, _ in
            guard let self, let samples = self.resample(buffer) else { return }
            let heard = Date()
            self.queue.async { self.consume(samples, at: heard) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private static func usable(_ format: AVAudioFormat) -> Bool { format.sampleRate > 0 && format.channelCount > 0 }

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    private func consume(_ samples: [Float], at heard: Date) {
        // (At most two minutes, in case the end of a reading is never heard.)
        if speaking, heard.timeIntervalSince(speakingSince) < 120 { return }
        pending.append(contentsOf: samples)
        let frames = pending.count / Self.frame
        guard frames > 0 else { return }
        for f in 0..<frames {
            let frame = Array(pending[(f * Self.frame)..<((f + 1) * Self.frame)])
            onFrame(frame, at: heard.addingTimeInterval(-Double(frames - 1 - f) * 0.03))
        }
        pending.removeFirst(frames * Self.frame)
        if !liveBatch.isEmpty {
            onSpeech?(liveBatch, chunkStart, liveOffset)
            liveBatch.removeAll(keepingCapacity: true)
        }
    }

    private func onFrame(_ frame: [Float], at now: Date) {
        // The neural detector when it's ready; loudness otherwise (it keeps its noise floor either way).
        let loud = vad.isSpeech(frame)
        SpeechGate.shared.feed(frame)
        let speech = SpeechGate.shared.isSpeech(recording: writer != nil) ?? loud
        recent.append(speech)
        if recent.count > 10 { recent.removeFirst() }

        guard let w = writer else {
            preRoll.append(frame)
            if preRoll.count > 1000 / Self.frameMs { preRoll.removeFirst() }
            // A few speech frames in the last 300 ms, to ignore clicks.
            if recent.filter({ $0 }).count >= 3 { open(now) }
            return
        }
        write(frame, to: w)
        if speech {
            lastSpeech = now
            speechFrames += 1
        }
        let length = Int(now.timeIntervalSince(chunkStart) * 1000)
        let quiet = Int(now.timeIntervalSince(lastSpeech) * 1000)
        switch ChunkRules.end(lengthMs: length, quietMs: quiet) {
        case .quiet: closeChunk(cut: false)
        case .cut: closeChunk(cut: true, at: now)
        case nil: break
        }
    }

    private func open(_ now: Date) {
        let url = Self.audioDirectory.appendingPathComponent("chunk_\(Int(now.timeIntervalSince1970 * 1000)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
        chunkStart = now.addingTimeInterval(-Double(preRoll.count) * 0.03)
        chunkSamples = 0
        for f in preRoll { write(f, to: file) }
        preRoll.removeAll()
        writer = file
        writerURL = url
        lastSpeech = now
        speechFrames = 0
        continuing = now.timeIntervalSince(cutAt) * 1000 < Double(ChunkRules.silenceToCloseMs)
    }

    private func write(_ frame: [Float], to file: AVAudioFile) {
        if liveBatch.isEmpty { liveOffset = chunkSamples }
        liveBatch += frame
        chunkSamples += frame.count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frame.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(frame.count)
        frame.withUnsafeBufferPointer { src in buffer.floatChannelData![0].update(from: src.baseAddress!, count: frame.count) }
        try? file.write(from: buffer)
    }

    private func closeChunk(cut: Bool, at now: Date = Date()) {
        guard writer != nil, let url = writerURL else { return }
        writer = nil // closes the file
        writerURL = nil
        if !liveBatch.isEmpty {
            onSpeech?(liveBatch, chunkStart, liveOffset)
            liveBatch.removeAll(keepingCapacity: true)
        }
        let end = lastSpeech.addingTimeInterval(0.5)
        // Hardly any speech is a cough or a door, except right after a cut: then it's the end of a sentence.
        if speechFrames * Self.frameMs < ChunkRules.minSpeechMs && !continuing {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if cut { cutAt = now }
        onChunk?(url, chunkStart, end)
    }
}

/// The microphone had no usable format (it was switching, or something else had it).
struct NoMicrophone: LocalizedError {
    var errorDescription: String? { "The microphone isn't available right now" }
}
