import AVFoundation
import Foundation
import SherpaTTSABI
import SurfCore

/// Tier 1: the downloaded Kokoro voice, spoken through sherpa-onnx.
///
/// The runtime is `dlopen`'d from the voice directory and driven through
/// function pointers — nothing links at build time, so Surf without the
/// download is exactly Surf before this file existed. Struct layouts come
/// from `SherpaTTSABI`, pinned to the release `VoiceComponent` downloads.
///
/// No word timings: a neural voice reports none, so `onWordRange` never
/// fires and the lyric shows the sentence — which is why utterances *are*
/// sentences. Synthesis runs about twice realtime on Apple Silicon, and the
/// next sentence is synthesised while the current one plays, so the voice
/// doesn't breathe between sentences waiting for the model.
@MainActor
final class KokoroEngine: NarrationEngine {

    var onUtteranceStart: ((Int) -> Void)?
    var onWordRange: ((Int, NSRange) -> Void)?
    var onScriptFinish: (() -> Void)?

    private let synthesizer = KokoroSynthesizer.shared

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Speed lives here, not in the model. Synthesis is always 1× and this
    /// node stretches playback — which is what makes a rate change a knob
    /// turn instead of a resynthesis, and keeps the prefetched sentence
    /// valid across it.
    private let timePitch = AVAudioUnitTimePitch()
    /// Kokoro's native format; the engine resamples to the device from here.
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: 24000, channels: 1
    )!

    private var script = NarrationScript(utterances: [])
    private var rate = 1.0
    /// Bumped by every `speak`/`stop`; stale synthesis results and stale
    /// playback completions compare against it and drop themselves.
    private var generation = 0
    private var prefetch: (index: Int, buffer: AVAudioPCMBuffer)?
    private var prefetchTask: Task<Void, Never>?
    /// Which index `prefetchTask` is synthesising, so `advance` can wait for
    /// it instead of starting a duplicate. A long sentence synthesised twice
    /// in parallel doubled the very stall that made it noticeable.
    private var prefetchIndex: Int?

    init() {
        audioEngine.attach(player)
        audioEngine.attach(timePitch)
        audioEngine.connect(player, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
        if ProcessInfo.processInfo.environment["SURF_SILENT"] == "1" {
            audioEngine.mainMixerNode.outputVolume = 0
        }
    }

    func speak(_ script: NarrationScript, from index: Int, rate: Double) {
        stop()
        self.script = script
        self.rate = rate
        timePitch.rate = Float(rate)
        advance(to: max(0, min(index, script.utterances.count - 1)))
    }

    /// Live, mid-sentence, no gap — the whole reason `timePitch` exists.
    func applyRate(_ rate: Double) -> Bool {
        self.rate = rate
        timePitch.rate = Float(rate)
        return true
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func stop() {
        generation += 1
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchIndex = nil
        prefetch = nil
        player.stop()
        script = NarrationScript(utterances: [])
    }

    // MARK: - The loop

    private func advance(to index: Int) {
        guard script.utterances.indices.contains(index) else {
            player.stop()
            onScriptFinish?()
            return
        }
        let generation = generation
        Task { @MainActor in
            // In-flight prefetch of exactly this index: wait for it rather
            // than racing it with a second synthesis of the same text.
            if prefetchIndex == index, let task = prefetchTask {
                await task.value
            }
            guard generation == self.generation else { return }
            let buffer: AVAudioPCMBuffer?
            if let prefetch, prefetch.index == index {
                buffer = prefetch.buffer
            } else {
                buffer = await makeBuffer(for: index)
            }
            prefetch = nil
            guard generation == self.generation else { return }
            guard let buffer else {
                // One sentence the model can't say — all symbols, an
                // unsupported script — costs that sentence, not the reading.
                debugLog("voice: utterance \(index) produced no audio — skipped")
                advance(to: index + 1)
                return
            }

            if !audioEngine.isRunning {
                do { try audioEngine.start() } catch {
                    debugLog("voice: audio engine failed — \(error)")
                    onScriptFinish?()
                    return
                }
            }

            onUtteranceStart?(index)
            player.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.advance(to: index + 1)
                }
            }
            player.play()
            prefetchNext(after: index, generation: generation)
        }
    }

    /// The whole point of prefetching: at 2× realtime the model finishes the
    /// next sentence long before the voice finishes this one, so the join is
    /// silence-free — without it, every full stop would be a model's pause
    /// for thought.
    private func prefetchNext(after index: Int, generation: Int) {
        let next = index + 1
        guard script.utterances.indices.contains(next) else { return }
        prefetchIndex = next
        prefetchTask = Task { @MainActor in
            let buffer = await makeBuffer(for: next)
            defer { if prefetchIndex == next { prefetchIndex = nil } }
            guard generation == self.generation, let buffer else { return }
            prefetch = (next, buffer)
        }
    }

    private func makeBuffer(for index: Int) async -> AVAudioPCMBuffer? {
        let text = script.utterances[index].text
        let started = Date()
        // Always 1×: the user's speed is applied by `timePitch` at playback,
        // so a speed change never invalidates synthesised audio.
        guard let audio = await synthesizer.synthesize(
            text, speed: 1.0, speaker: VoiceComponent.defaultSpeaker
        ) else { return nil }
        let elapsed = Int(-started.timeIntervalSinceNow * 1000)
        if elapsed > 2000 {
            // The "it just stops" report is usually a sentence the phonemizer
            // chews on; this names the sentence so it can be reproduced.
            debugLog("""
                voice: slow synthesis — \(elapsed)ms for \(text.count) chars: \
                \"\(text.prefix(60))…\"
                """)
        }

        guard let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(audio.samples.count)
        ), let channel = buffer.floatChannelData
        else { return nil }

        audio.samples.withUnsafeBufferPointer { samples in
            channel[0].update(from: samples.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        return buffer
    }
}

// MARK: - The synthesiser

/// The blocking half, off the main actor: model load takes most of a second
/// and each sentence takes a large fraction of one.
///
/// One for the whole app, not one per tab. The loaded model holds hundreds
/// of megabytes, and a per-tab copy meant every tab that ever narrated paid
/// its own load and kept its own model — the "takes a while to start"
/// complaint was every tab's first Listen paying that bill again.
actor KokoroSynthesizer {

    static let shared = KokoroSynthesizer(
        library: VoiceInstaller.runtimeLibrary,
        modelDirectory: VoiceInstaller.modelDirectory
    )

    struct Audio {
        var samples: [Float]
        var sampleRate: Int
    }

    private let library: URL
    private let modelDirectory: URL

    private struct API {
        let create: @convention(c) (
            UnsafePointer<SherpaOnnxOfflineTtsConfig>?
        ) -> OpaquePointer?
        let generate: @convention(c) (
            OpaquePointer?, UnsafePointer<CChar>?, Int32, Float
        ) -> UnsafeMutablePointer<SherpaOnnxGeneratedAudio>?
        let destroyAudio: @convention(c) (
            UnsafeMutablePointer<SherpaOnnxGeneratedAudio>?
        ) -> Void
    }

    private var api: API?
    private var tts: OpaquePointer?
    /// One failed load shouldn't be re-attempted per sentence: the model is
    /// missing or the dylib refused, and neither changes mid-article.
    private var loadFailed = false

    init(library: URL, modelDirectory: URL) {
        self.library = library
        self.modelDirectory = modelDirectory
    }

    /// Pays the model load ahead of the first sentence. Fired when Focus
    /// opens, so by the time Listen is tapped the model is already hot and
    /// the wait is one short sentence's synthesis.
    func warmUp() {
        _ = ensureLoaded()
    }

    /// A failed load is sticky so a missing model isn't retried per sentence
    /// — but installing the voice mid-session changes the facts, so the
    /// installer calls this after a successful install.
    func retryAfterInstall() {
        loadFailed = false
    }

    func synthesize(_ text: String, speed: Double, speaker: Int32) -> Audio? {
        guard ensureLoaded(), let api, let tts else { return nil }
        guard let raw = text.withCString({
            api.generate(tts, $0, speaker, Float(speed))
        }) else { return nil }
        defer { api.destroyAudio(raw) }

        let audio = raw.pointee
        guard audio.n > 0, audio.sample_rate > 0, let samples = audio.samples
        else { return nil }
        return Audio(
            samples: Array(UnsafeBufferPointer(start: samples, count: Int(audio.n))),
            sampleRate: Int(audio.sample_rate)
        )
    }

    private func ensureLoaded() -> Bool {
        if tts != nil { return true }
        guard !loadFailed else { return false }

        guard let handle = dlopen(library.path, RTLD_NOW) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            voiceLog("dlopen failed — \(reason)")
            loadFailed = true
            return false
        }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard
            let create = symbol(
                "SherpaOnnxCreateOfflineTts",
                as: (@convention(c) (UnsafePointer<SherpaOnnxOfflineTtsConfig>?) -> OpaquePointer?).self
            ),
            let generate = symbol(
                "SherpaOnnxOfflineTtsGenerate",
                as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, Float)
                    -> UnsafeMutablePointer<SherpaOnnxGeneratedAudio>?).self
            ),
            let destroyAudio = symbol(
                "SherpaOnnxDestroyOfflineTtsGeneratedAudio",
                as: (@convention(c) (UnsafeMutablePointer<SherpaOnnxGeneratedAudio>?) -> Void).self
            )
        else {
            voiceLog("runtime is missing expected symbols")
            loadFailed = true
            return false
        }
        api = API(create: create, generate: generate, destroyAudio: destroyAudio)

        // The strings are strdup'd and deliberately never freed: one set per
        // process, alive for as long as the synthesiser they configure.
        func keep(_ path: String) -> UnsafePointer<CChar>? {
            UnsafePointer(strdup(path))
        }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.num_threads = 4
        config.model.provider = keep("cpu")
        config.model.kokoro.model = keep(modelDirectory.appendingPathComponent("model.onnx").path)
        config.model.kokoro.voices = keep(modelDirectory.appendingPathComponent("voices.bin").path)
        config.model.kokoro.tokens = keep(modelDirectory.appendingPathComponent("tokens.txt").path)
        config.model.kokoro.data_dir = keep(modelDirectory.appendingPathComponent("espeak-ng-data").path)
        config.model.kokoro.length_scale = 1
        // Sentences arrive one per call already; don't let the runtime
        // re-batch them.
        config.max_num_sentences = 1

        let started = Date()
        tts = withUnsafePointer(to: &config) { create($0) }
        guard tts != nil else {
            voiceLog("model failed to load")
            loadFailed = true
            return false
        }
        voiceLog("model loaded in \(Int(-started.timeIntervalSinceNow * 1000))ms")
        return true
    }
}

/// The actor can't call the main-actor `debugLog`; same gate, same stream.
private func voiceLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["SURF_URL"] != nil else { return }
    FileHandle.standardError.write(Data("[surf] voice: \(message)\n".utf8))
}
