import AVFoundation
import Foundation
import Observation
import SurfCore

/// What any text-to-speech backend owes the narrator.
///
/// One conformance today — the system synthesiser below. The downloadable
/// model planned for later slots in here: same script, same callbacks, so the
/// lens and the controls never learn which engine is speaking.
@MainActor
protocol NarrationEngine: AnyObject {
    /// Fired as each utterance begins, with its index into the script.
    var onUtteranceStart: ((Int) -> Void)? { get set }
    /// Fired as speech crosses word boundaries: utterance index plus the
    /// UTF-16 range of the word about to be spoken, in that utterance's text.
    var onWordRange: ((Int, NSRange) -> Void)? { get set }
    /// The whole script finished on its own — distinct from being stopped.
    var onScriptFinish: (() -> Void)? { get set }

    /// - Parameter rate: a multiplier around normal speed, 1.0 = normal.
    func speak(_ script: NarrationScript, from index: Int, rate: Double)
    /// Change speed mid-playback without interruption, where the engine can.
    /// Returns false when it can't — the caller restarts the current
    /// utterance at the new rate instead.
    func applyRate(_ rate: Double) -> Bool
    func pause()
    func resume()
    func stop()
}

/// Tier 0: `AVSpeechSynthesizer`, which every Mac has.
///
/// Chosen first not as a stopgap but because it is the only engine whose word
/// boundaries are free — `willSpeakRangeOfSpeechString` is exactly the lyric
/// sync, with no forced alignment anywhere. A better-sounding model can take
/// over later behind the same protocol.
@MainActor
final class AVSpeechEngine: NSObject, NarrationEngine {

    var onUtteranceStart: ((Int) -> Void)?
    var onWordRange: ((Int, NSRange) -> Void)?
    var onScriptFinish: (() -> Void)?

    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()

    private var script = NarrationScript(utterances: [])
    private var index = 0
    private var rate = 1.0
    /// The utterance currently in the synthesiser, for telling its callbacks
    /// apart from a stopped one's: `stopSpeaking` still delivers a cancel,
    /// and a stale finish must not advance a script that was replaced.
    private var current: AVSpeechUtterance?

    /// The best installed voice for the system language, dearest first —
    /// the premium and enhanced voices are the ones people download, and
    /// falling back below them silently would waste that.
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
            switch quality {
            case .premium: return 2
            case .enhanced: return 1
            default: return 0
            }
        }
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted { rank($0.quality) > rank($1.quality) }
        return candidates.first ?? AVSpeechSynthesisVoice(language: language)
    }()

    func speak(_ script: NarrationScript, from index: Int, rate: Double) {
        stop()
        self.script = script
        self.index = max(0, min(index, script.utterances.count - 1))
        self.rate = rate
        speakCurrent()
    }

    /// The platform synthesiser can't retime an utterance in flight; the
    /// caller restarts the sentence, which at sentence granularity is a
    /// barely-audible rewind.
    func applyRate(_ rate: Double) -> Bool { false }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        current = nil
        script = NarrationScript(utterances: [])
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// One utterance in the synthesiser at a time, advanced from `didFinish`.
    /// Queueing them all up front would be simpler, but then a seek means
    /// stopping the queue and rebuilding it — this way the index is the one
    /// piece of state and every jump is the same move.
    private func speakCurrent() {
        guard script.utterances.indices.contains(index) else {
            onScriptFinish?()
            return
        }
        let utterance = AVSpeechUtterance(string: script.utterances[index].text)
        if let voice = Self.voice { utterance.voice = voice }
        utterance.rate = Self.platformRate(for: rate)
        // Dev affordance: `SURF_SILENT=1` exercises the whole pipeline —
        // callbacks, highlights, advancement — without the room hearing it.
        if ProcessInfo.processInfo.environment["SURF_SILENT"] == "1" {
            utterance.volume = 0
        }
        current = utterance
        onUtteranceStart?(index)
        synthesizer.speak(utterance)
    }

    /// Maps a perceived-speed multiplier onto the platform's rate scale.
    ///
    /// That scale is 0…1 around a 0.5 default, and it is nothing like linear:
    /// 1.0 is not "twice normal", it is closer to four-times-and-garbled.
    /// Multiplying the default — the obvious spelling, and the first one this
    /// shipped with — saturated the scale at 2× and read as a bug, because it
    /// was one. The top half of the scale is compressed to a third instead,
    /// which puts 2× perceived near platform 0.67 — about where speech
    /// actually doubles — and leaves headroom rather than a cliff.
    static func platformRate(for multiplier: Double) -> Float {
        let base = AVSpeechUtteranceDefaultSpeechRate
        if multiplier >= 1 {
            return min(1, base + (1 - base) * Float(multiplier - 1) / 3)
        }
        // Below normal the scale behaves closer to proportionally.
        return max(AVSpeechUtteranceMinimumSpeechRate, base * Float(multiplier))
    }
}

extension AVSpeechEngine: AVSpeechSynthesizerDelegate {

    // The utterance itself is not Sendable, so it can't cross into the main
    // actor — its identity can, and identity is all the staleness check needs.

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let spoken = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let current, ObjectIdentifier(current) == spoken else { return }
            onWordRange?(index, characterRange)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let finished = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let current, ObjectIdentifier(current) == finished else { return }
            index += 1
            speakCurrent()
        }
    }
}

/// Playback state and lyric position for one tab's narration.
///
/// The lens renders from this and the controls drive it; the engine behind it
/// is an implementation detail. Lives on the tab rather than in a view so
/// switching tabs doesn't stop the reading.
@MainActor
@Observable
final class Narrator {

    enum PlaybackState: Equatable {
        case idle
        case speaking
        case paused
    }

    private(set) var state: PlaybackState = .idle
    private(set) var script = NarrationScript(utterances: [])
    private(set) var utteranceIndex = 0

    /// True from a play or seek until its audio actually starts — the window
    /// the transport shows a spinner in place of the pause button, so a
    /// model still synthesising reads as working rather than stuck.
    private(set) var isPreparing = false

    /// What the lens lights up, in three grains: the block being spoken, the
    /// sentence within it (known at every utterance start), and — from
    /// engines that report word timings — the word. A neural voice never
    /// fills the third, and the lyric degrades to the sentence, not to dark.
    private(set) var speakingBlockID: Int?
    private(set) var speakingSentenceRange: Range<Int>?
    private(set) var speakingRange: Range<Int>?

    /// Called just before audio actually starts, so the tab can quiet a page
    /// that is already playing something.
    @ObservationIgnored var onWillBeginAudio: (@MainActor () -> Void)?

    /// Built on first use: a synthesiser per tab up front would be fifty
    /// synthesisers for a session that narrates nothing.
    @ObservationIgnored private var liveEngine: NarrationEngine?
    @ObservationIgnored private var liveEngineKind: EngineKind = .system

    private enum EngineKind { case system, enhanced }

    /// The downloaded voice when it's installed and wanted; the system's
    /// otherwise. Consulted between readings, never during one — swapping the
    /// engine out from under its own playback would orphan the audio.
    private var desiredEngineKind: EngineKind {
        VoiceInstaller.shared.isReady
            && UserDefaults.standard.bool(forKey: PreferenceKeys.focusEnhancedVoice)
            ? .enhanced : .system
    }

    private var engine: NarrationEngine {
        if let liveEngine,
           state != .idle || liveEngineKind == desiredEngineKind {
            return liveEngine
        }
        liveEngine?.stop()
        let kind = desiredEngineKind
        let engine: NarrationEngine =
            kind == .enhanced ? KokoroEngine() : AVSpeechEngine()
        wire(engine)
        liveEngine = engine
        liveEngineKind = kind
        return engine
    }

    private func wire(_ engine: NarrationEngine) {
        engine.onUtteranceStart = { [weak self] index in
            guard let self else { return }
            isPreparing = false
            utteranceIndex = index
            speakingBlockID = script.utterances[index].blockID
            speakingSentenceRange = script.sentenceHighlight(utterance: index)?.range
            speakingRange = nil
            debugLog("""
                narrate: \(index + 1)/\(script.utterances.count) \
                block \(script.utterances[index].blockID)
                """)
        }
        engine.onWordRange = { [weak self] index, range in
            guard let self else { return }
            guard let hit = script.highlight(
                utterance: index, location: range.location, length: range.length
            ) else { return }
            if speakingRange == nil {
                // Once per utterance, so the log shows the lyric sync is
                // alive without narrating the narration.
                debugLog("narrate: highlighting block \(hit.blockID) from word \(hit.range)")
            }
            speakingBlockID = hit.blockID
            speakingRange = hit.range
        }
        engine.onScriptFinish = { [weak self] in
            self?.clear()
        }
    }

    /// The reading speed, held across articles and relaunches.
    ///
    /// A stored property mirrored to defaults rather than a computed read of
    /// them: observation tracks stored state, and a label rendered from a
    /// defaults read only refreshed when something *else* changed — the menu
    /// showed the old speed while the audio already spoke the new one.
    private var rateValue: Double = {
        let stored = UserDefaults.standard.double(forKey: PreferenceKeys.focusSpeechRate)
        return stored == 0 ? 1.0 : stored
    }()

    var rate: Double {
        get { rateValue }
        set {
            rateValue = newValue
            UserDefaults.standard.set(newValue, forKey: PreferenceKeys.focusSpeechRate)
            guard state != .idle else { return }
            // A rate is a property of the voice, not of the utterance it
            // happened to land on — so it applies now, not from the next one.
            // Seamlessly where the engine can retime playback; by restarting
            // the current sentence where it can't.
            if liveEngine?.applyRate(newValue) != true {
                startSpeaking(from: utteranceIndex)
            }
        }
    }

    static let rateChoices: [Double] = [0.8, 1.0, 1.2, 1.5, 2.0]

    var progressLabel: String {
        guard state != .idle, !script.isEmpty else { return "" }
        return "\(utteranceIndex + 1) / \(script.utterances.count)"
    }

    // MARK: - Controls

    /// Play from where it left off, pause, or resume — the one button.
    func toggle(reading article: FocusArticle) {
        switch state {
        case .idle:
            script = NarrationScript.build(from: article)
            guard !script.isEmpty else { return }
            debugLog("narrate: reading \(script.utterances.count) utterances")
            startSpeaking(from: 0)
        case .speaking:
            engine.pause()
            state = .paused
        case .paused:
            engine.resume()
            state = .speaking
        }
    }

    func skip(_ delta: Int) {
        guard state != .idle else { return }
        let target = utteranceIndex + delta
        guard script.utterances.indices.contains(target) else { return }
        startSpeaking(from: target)
    }

    /// Tap-to-seek from the lens. Only while already reading: a tap on a
    /// paragraph shouldn't start audio out of nowhere.
    func jump(toBlock blockID: Int) {
        guard state != .idle else { return }
        guard let index = script.utteranceIndex(forBlock: blockID) else { return }
        startSpeaking(from: index)
    }

    /// "Read from Here": starts (or moves) the reading at a chosen passage.
    /// The deliberate counterpart to `jump` — reached through a context menu,
    /// so starting audio is unmistakably what was asked for.
    func read(_ article: FocusArticle, fromBlock blockID: Int) {
        if state == .idle {
            script = NarrationScript.build(from: article)
        }
        guard let index = script.utteranceIndex(forBlock: blockID) else { return }
        startSpeaking(from: index)
    }

    func stop() {
        guard state != .idle else { return }
        engine.stop()
        clear()
    }

    /// Pays the enhanced voice's model load before anyone taps Listen.
    /// Called when Focus opens; a no-op for the system voice, and cheap when
    /// the model is already resident.
    func warmUp() {
        guard desiredEngineKind == .enhanced else { return }
        Task.detached(priority: .utility) {
            await KokoroSynthesizer.shared.warmUp()
        }
    }

    private func startSpeaking(from index: Int) {
        onWillBeginAudio?()
        state = .speaking
        isPreparing = true
        engine.speak(script, from: index, rate: rate)
    }

    private func clear() {
        state = .idle
        isPreparing = false
        utteranceIndex = 0
        speakingBlockID = nil
        speakingSentenceRange = nil
        speakingRange = nil
    }
}
