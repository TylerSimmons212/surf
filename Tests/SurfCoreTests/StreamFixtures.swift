import Foundation

/// Manifests to parse, as they actually arrive.
///
/// The one deliberate exception to a file per subject: these are shared by the
/// HLS tests, the planner's tests and the schedule's, and three copies of a
/// playlist would drift from each other in exactly the places that matter.
///
/// Swift literals rather than files in a bundle, because `Tests/` contains no
/// non-Swift files and giving it some means declaring resources in a
/// `Package.swift` whose single dependency carries a paragraph about earning its
/// exception. A playlist is text; text is cheap to hold in a string.
///
/// Each one is here because it is a place a parser breaks, not for coverage.
enum StreamFixtures {

    static let base = URL(string: "https://cdn.example.com/hls/master.m3u8")!

    /// The ordinary modern case. Note the comma inside CODECS, which is the
    /// classic misparse.
    static let fmp4Master = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-STREAM-INF:BANDWIDTH=2149280,AVERAGE-BANDWIDTH=2001000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",FRAME-RATE=30.000
    720/stream.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=6221600,AVERAGE-BANDWIDTH=5942000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=30.000
    1080/stream.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=730000,AVERAGE-BANDWIDTH=700000,RESOLUTION=640x360,CODECS="avc1.64001e,mp4a.40.2",FRAME-RATE=30.000
    360/stream.m3u8
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=186000,RESOLUTION=1920x1080,CODECS="avc1.640028",URI="iframe/stream.m3u8"
    """

    /// Video-only variants with their sound in a separate group. This is what
    /// makes a muxer necessary, and it is how most premium streams are packaged.
    static let separateAudioMaster = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac-128k",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio/en/128k.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac-128k",NAME="Français",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio/fr/128k.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=NO,URI="subs/en.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.64001f",AUDIO="aac-128k",SUBTITLES="subs"
    video/720/stream.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=5800000,RESOLUTION=1920x1080,CODECS="avc1.640028",AUDIO="aac-128k",SUBTITLES="subs"
    video/1080/stream.m3u8
    """

    /// Seven fMP4 segments with an init segment, ended. 28 seconds in total,
    /// matching the clip the muxing was proven against.
    static let fmp4Media = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:4
    #EXT-X-MEDIA-SEQUENCE:1
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:4.000,
    seg-1.m4s
    #EXTINF:4.000,
    seg-2.m4s
    #EXTINF:4.000,
    seg-3.m4s
    #EXTINF:4.000,
    seg-4.m4s
    #EXTINF:4.000,
    seg-5.m4s
    #EXTINF:4.000,
    seg-6.m4s
    #EXTINF:4.000,
    seg-7.m4s
    #EXT-X-ENDLIST
    """

    /// The soundtrack for a video-only variant. Same duration, different segment
    /// count, which is normal: audio and video segment on their own boundaries.
    static let audioMedia = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:7
    #EXT-X-MEDIA-SEQUENCE:1
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="a-init.mp4"
    #EXTINF:7.000,
    a-1.m4a
    #EXTINF:7.000,
    a-2.m4a
    #EXTINF:7.000,
    a-3.m4a
    #EXTINF:7.000,
    a-4.m4a
    #EXT-X-ENDLIST
    """

    /// A key anyone may fetch. Not DRM, and the distinction a naive reading gets
    /// wrong.
    static let aes128Media = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:10
    #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k/1",IV=0x9c7db8778570d05c3f4c0bbd8c8e48c6
    #EXTINF:9.009,
    seg-1.ts
    #EXTINF:9.009,
    seg-2.ts
    #EXT-X-ENDLIST
    """

    /// FairPlay. There is no key to fetch and the samples arrive encrypted.
    static let sampleAESMedia = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:6
    #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://a7b3c9",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:6.000,
    seg-1.m4s
    #EXTINF:6.000,
    seg-2.m4s
    #EXT-X-ENDLIST
    """

    /// No `#EXT-X-ENDLIST`, which is the only thing that says a stream has an
    /// end. There is no whole file to produce from this.
    static let liveMedia = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:4
    #EXT-X-MEDIA-SEQUENCE:26812
    #EXTINF:4.000,
    seg-26812.ts
    #EXTINF:4.000,
    seg-26813.ts
    #EXTINF:4.000,
    seg-26814.ts
    """

    /// The legacy container. AVFoundation will not read it, so this has to be
    /// recognised rather than attempted.
    static let mpegTSMedia = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:10
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXTINF:9.009,
    fileSequence0.ts
    #EXTINF:9.009,
    fileSequence1.ts
    #EXTINF:3.003,
    fileSequence2.ts
    #EXT-X-ENDLIST
    """

    /// Several segments inside one file. The second range carries no offset, so
    /// it continues from where the first ended, and forgetting that makes every
    /// segment after the first silently wrong.
    static let byteRangeMedia = """
    #EXTM3U
    #EXT-X-VERSION:4
    #EXT-X-TARGETDURATION:10
    #EXT-X-MAP:URI="whole.mp4",BYTERANGE="1012@0"
    #EXTINF:10.000,
    #EXT-X-BYTERANGE:75232@1012
    whole.mp4
    #EXTINF:10.000,
    #EXT-X-BYTERANGE:82112
    whole.mp4
    #EXTINF:10.000,
    #EXT-X-BYTERANGE:69864
    whole.mp4
    #EXT-X-ENDLIST
    """

    /// Absolute segment URLs on a different host from the playlist, which is an
    /// ordinary CDN arrangement and also the shape a hostile manifest would take.
    static let absoluteURLMedia = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:4
    #EXT-X-MAP:URI="https://seg.example.net/v/init.mp4"
    #EXTINF:4.000,
    https://seg.example.net/v/1.m4s
    #EXTINF:4.000,
    https://seg.example.net/v/2.m4s
    #EXT-X-ENDLIST
    """

    /// Not a playlist. A 200 with an error page in it parses to the same nothing
    /// as an empty playlist unless the first line is checked.
    static let notAPlaylist = """
    <!DOCTYPE html>
    <html><body><h1>403 Forbidden</h1></body></html>
    """
}
