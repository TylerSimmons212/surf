import Foundation
import Testing
@testable import SurfCore

@Suite("Download options")
struct DownloadOptionTests {

    private func video(
        _ id: String, _ height: Int, _ codecs: String, _ bitrate: Int = 1_000_000
    ) -> DownloadOption {
        DownloadOption(id: id, height: height, bitrate: bitrate, codecs: codecs)
    }

    private func audio(_ id: String, _ codecs: String, _ bitrate: Int) -> DownloadOption {
        DownloadOption(id: id, bitrate: bitrate, codecs: codecs, isAudioOnly: true)
    }

    // MARK: - What a row says

    @Test("A video row is named by its height")
    func videoTitle() {
        #expect(video("401", 2160, "av01.0.13M.08").title == "2160p")
        #expect(video("299", 1080, "avc1.64002a").title == "1080p")
    }

    @Test("Sound is named as sound")
    func audioTitle() {
        #expect(audio("258", "mp4a.40.2", 388_000).title == "Audio only")
    }

    @Test("A video that declares no height is still a row")
    func unknownHeight() {
        // Plenty of single-rendition streams declare nothing. "Video" is honest;
        // "0p" is not.
        #expect(DownloadOption(id: "x").title == "Video")
        #expect(DownloadOption(id: "x", height: 0).title == "Video")
    }

    @Test("Codec strings become names people recognise", arguments: [
        ("av01.0.13M.08", "AV1"),
        ("avc1.64002a", "H.264"),
        ("avc3.640028", "H.264"),
        ("hvc1.2.4.L153.B0", "HEVC"),
        ("hev1.1.6.L93.B0", "HEVC"),
        ("vp09.00.50.08", "VP9"),
        ("vp9", "VP9"),
        ("mp4a.40.2", "AAC"),
        ("opus", "Opus"),
        ("ec-3", "Dolby"),
        ("video/mp4; codecs=\"avc1.64002a\"", "H.264"),
    ])
    func codecNames(_ codecs: String, _ expected: String) {
        // `avc1.64002a` means nothing to anyone choosing. The question being
        // asked is "will this play on my machine", which is about H.264 and AV1.
        #expect(DownloadOption.codecName(codecs) == expected)
    }

    @Test("An unrecognised codec is left out rather than guessed at")
    func unknownCodec() {
        #expect(DownloadOption.codecName("something-new.1") == "")
        #expect(DownloadOption.codecName("") == "")
        // And the detail line simply omits it.
        let option = DownloadOption(id: "x", bitrate: 1_000_000, codecs: "mystery")
        #expect(option.detail(duration: 100) == "~12.5 MB")
    }

    // MARK: - The size, which is the number being compared

    @Test("A size is estimated from bitrate and duration")
    func estimate() {
        // 388 kbps across 634.6 seconds is about 30MB, which is what the real
        // audio track of that video weighs.
        let option = audio("258", "mp4a.40.2", 388_000)
        let bytes = option.estimatedBytes(duration: 634.6)
        #expect(bytes != nil)
        #expect(abs((bytes ?? 0) - 30_777_410) < 100_000)
    }

    @Test("Nothing to estimate from gives no number", arguments: [
        (Int?.none, Double?.some(100)),
        (0, 100),
        (1_000_000, nil),
        (1_000_000, 0),
        (1_000_000, Double.infinity),
    ])
    func unestimable(_ bitrate: Int?, _ duration: Double?) {
        // Nil rather than zero, so a row shows no size instead of a confident
        // "0 bytes" next to a gigabyte of video.
        let option = DownloadOption(id: "x", bitrate: bitrate, codecs: "avc1")
        #expect(option.estimatedBytes(duration: duration) == nil)
    }

    @Test("The detail line carries whichever halves are known")
    func detailLine() {
        #expect(video("401", 2160, "av01.0.13M.08", 6_800_000).detail(duration: 634.6)
            .hasPrefix("AV1 · ~"))
        // No duration, so no size — but the codec still says something.
        #expect(video("401", 2160, "av01.0.13M.08").detail(duration: nil) == "AV1")
        // Neither.
        #expect(DownloadOption(id: "x").detail(duration: nil) == "")
    }

    // MARK: - Which rows a menu shows

    @Test("One row per height, tallest first")
    func oneRowPerHeight() {
        // YouTube lists 1080p in H.264, VP9 and AV1, and more than one bitrate of
        // each. Six rows all saying 1080p is a worse menu than three saying
        // different things.
        let rows = DownloadOptions.video(from: [
            video("401", 2160, "av01"), video("315", 2160, "vp09"),
            video("299", 1080, "avc1"), video("303", 1080, "vp09"),
            video("136", 720, "avc1"),
        ])
        #expect(rows.map(\.height) == [2160, 1080, 720])
    }

    @Test("The most playable encoding represents its height")
    func mostPlayableWins() {
        // Given the same picture twice, the row offers the one most things can
        // open. Taking a taller rendition is still a click away; being unable to
        // play what you chose is not.
        let rows = DownloadOptions.video(from: [
            video("303", 1080, "vp09.00.50.08"),
            video("299", 1080, "avc1.64002a"),
            video("400", 1080, "av01.0.08M.08"),
        ])
        #expect(rows.count == 1)
        #expect(rows.first?.id == "299")
    }

    @Test("A height offered only as AV1 is still offered")
    func onlyAV1() {
        // YouTube has no H.264 above 1080p, so preferring it must not mean
        // hiding 2160p — which is exactly the mistake that capped downloads
        // before this menu existed.
        let rows = DownloadOptions.video(from: [
            video("401", 2160, "av01.0.13M.08"),
            video("299", 1080, "avc1.64002a"),
        ])
        #expect(rows.map(\.height) == [2160, 1080])
        #expect(rows.first?.id == "401")
    }

    @Test("Sound is not a video row")
    func audioExcluded() {
        let rows = DownloadOptions.video(from: [
            video("299", 1080, "avc1"), audio("258", "mp4a.40.2", 388_000),
        ])
        #expect(rows.count == 1)
        #expect(rows.first?.isAudioOnly == false)
    }

    @Test("A video with no height is not a row either")
    func heightlessExcluded() {
        // It cannot be named or compared, so a menu row for it would say
        // "Video" next to "1080p" and mean nothing.
        let rows = DownloadOptions.video(from: [
            DownloadOption(id: "mystery", codecs: "avc1"), video("299", 1080, "avc1"),
        ])
        #expect(rows.map(\.id) == ["299"])
    }

    @Test("Nothing on offer is an empty menu, not a crash")
    func empty() {
        #expect(DownloadOptions.video(from: []).isEmpty)
        #expect(DownloadOptions.audio(from: []) == nil)
    }

    // MARK: - Sound

    @Test("The best soundtrack is the only one offered")
    func bestAudio() {
        // Audio is a fraction of a video's size, so there is nothing to save by
        // taking less, and nobody wants to compare two bitrates of the same
        // soundtrack in a menu.
        let chosen = DownloadOptions.audio(from: [
            audio("139", "mp4a.40.5", 49_000),
            audio("258", "mp4a.40.2", 388_000),
            audio("140", "mp4a.40.2", 129_000),
        ])
        #expect(chosen?.id == "258")
    }

    @Test("A video is never offered as the soundtrack")
    func audioIgnoresVideo() {
        #expect(DownloadOptions.audio(from: [video("299", 1080, "avc1", 9_000_000)]) == nil)
    }
}
